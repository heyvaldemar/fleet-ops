#!/usr/bin/env python3
"""Assert that every template in the fleet still meets the fleet standard.

WHY THIS EXISTS. The standard was rolled out by scripts, one wave at a time,
and nothing ever asked afterwards whether every repository had actually
received it. On 2026-09-04 one had not: gaseous-server carried the digest pins
and the CI the standard also asks for, so it looked done from the outside,
while four services had no hardening and its backup loop was two generations
old — running under sh without pipefail, so a failed dump exited zero and left
a file that looked like a backup. It had been that way for two months and was
found by accident.

A wave applied is not a wave verified. This is the verification.

DESIGN RULES, each of which cost something to learn:

  * A check that cannot fail is not a check. Every rule below is exercised
    against a deliberately broken copy in tests/test-conformance.sh before it
    is trusted; a rule that stays green there is a bug in the rule.
  * Absence is not success. A file that cannot be read is a FAIL, never a
    pass — the empty-listing fail-fast in fleet-triage.sh exists because a
    silent empty result once produced a green run that had checked nothing.
  * "Not applicable" and "passes" are different words and must stay different.
    A repository with no database is not a repository whose database is
    configured correctly.
"""
import base64, datetime, json, os, re, subprocess, sys, urllib.error, urllib.parse, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_kind  # noqa: E402  (the one place fleet repositories are classified)

OWNER = os.environ.get("FLEET_OWNER", "heyvaldemar")
LOCAL = os.environ.get("FLEET_LOCAL_DIR")  # test mode: read from disk instead
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

NOT_APPLICABLE = ["__not-a-compose-template__"]

STATEFUL = re.compile(r"image:.*?\b(postgres|mysql|mariadb|mongo|redis|valkey)\b", re.I)
SKIP_SVC = re.compile(r"backup", re.I)



def api(path):
    req = urllib.request.Request(f"https://api.github.com/{path}")
    req.add_header("Accept", "application/vnd.github+json")
    if TOKEN:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


class Repo:
    """Reads a repository's files, from disk in test mode or from the API."""

    def __init__(self, name):
        self.name = name
        self._listing = None

    def listing(self):
        if self._listing is None:
            if LOCAL:
                d = os.path.join(LOCAL, self.name)
                self._listing = sorted(os.listdir(d)) if os.path.isdir(d) else []
            else:
                try:
                    self._listing = [e["name"] for e in api(f"repos/{OWNER}/{self.name}/contents/")]
                except urllib.error.HTTPError:
                    self._listing = []
        return self._listing

    def workflows(self):
        """The workflow file names, from the directory rather than from a list
        kept here: a list by hand falls behind the files it describes, and the
        rule that reads it then passes the file nobody remembered to add."""
        if LOCAL:
            d = os.path.join(LOCAL, self.name, ".github", "workflows")
            return sorted(n for n in os.listdir(d)) if os.path.isdir(d) else []
        try:
            return sorted(e["name"] for e in api(f"repos/{OWNER}/{self.name}/contents/.github/workflows"))
        except urllib.error.HTTPError:
            return []

    def names_in(self, path):
        """The file names in one directory of the repository; [] when there is
        no such directory."""
        if LOCAL:
            d = os.path.join(LOCAL, self.name, path)
            return sorted(os.listdir(d)) if os.path.isdir(d) else []
        try:
            return sorted(e["name"] for e in api(f"repos/{OWNER}/{self.name}/contents/{path}"))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return []
            raise

    def read(self, path):
        """Returns the file's text, or None when it does not exist.
        Raises on anything else: a transport failure must never read as absent.
        Remembered per path: several rules read the same workflow files, and
        the daily run has a rate limit to stay under."""
        if not hasattr(self, "_reads"):
            self._reads = {}
        if path not in self._reads:
            self._reads[path] = self._read(path)
        return self._reads[path]

    def _read(self, path):
        if LOCAL:
            p = os.path.join(LOCAL, self.name, path)
            if not os.path.isfile(p):
                return None
            with open(p, encoding="utf-8", errors="replace") as f:
                return f.read()
        try:
            d = api(f"repos/{OWNER}/{self.name}/contents/{path}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise
        return base64.b64decode(d["content"]).decode("utf-8", "replace")

    def tree(self):
        """Every file path in the repository, recursively."""
        if LOCAL:
            root = os.path.join(LOCAL, self.name)
            out = []
            for d, dirs, files in os.walk(root):
                dirs[:] = [x for x in dirs if x != ".git"]
                out += [os.path.relpath(os.path.join(d, f), root) for f in files]
            return sorted(out)
        data = api(f"repos/{OWNER}/{self.name}/git/trees/HEAD?recursive=1")
        return sorted(e["path"] for e in data.get("tree", []) if e.get("type") == "blob")

    def blobs(self):
        """(path, size) for every file in the repository, recursively. One API
        call: the size lets a rule skip a vendored installer without fetching it."""
        if LOCAL:
            root = os.path.join(LOCAL, self.name)
            return [(p, os.path.getsize(os.path.join(root, p))) for p in self.tree()]
        data = api(f"repos/{OWNER}/{self.name}/git/trees/HEAD?recursive=1")
        return sorted((e["path"], e.get("size", 0)) for e in data.get("tree", []) if e.get("type") == "blob")

    def tags(self):
        if LOCAL:
            out = subprocess.run(["git", "-C", os.path.join(LOCAL, self.name), "tag"],
                                 capture_output=True, text=True)
            return set(out.stdout.split())
        try:
            return {t["name"] for t in api(f"repos/{OWNER}/{self.name}/tags?per_page=100")}
        except urllib.error.HTTPError:
            return set()


def uncommented(block):
    """Structural checks must not be satisfied by a commented-out example.
    ollama carries a commented `deploy:` block for an nvidia device, which
    would otherwise read as a service that has resource limits."""
    return "\n".join(l for l in block.split("\n") if not l.strip().startswith("#"))


def services(compose):
    """Split a compose file into (name, block) for each service.

    The block ENDS at the next top-level key. Without that boundary the
    entries under `volumes:` and `networks:` are read as services, and a
    named volume is then reported for having no resource limits and no
    security_opt - findings against something that cannot carry either.
    cs2-server-data and game-data are the cases this was written for."""
    lines = compose.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.rstrip() == "services:")
    except StopIteration:
        return []
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^[A-Za-z0-9_-]+:", lines[i]):
            end = i
            break
    heads = [i for i in range(start + 1, end)
             if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])] + [end]
    return [(lines[h].strip().rstrip(":"), "\n".join(lines[h:n]))
            for h, n in zip(heads, heads[1:])]


# BEFORE THE FIRST RELEASE. A repository can be public before its first release:
# a new Docker Hub image goes public, then waits a week for the one-image-a-week
# pace. Failing it for that week did worse than fail it: conformance stayed red on
# the one known gap, and the heartbeat, already saying "conformance fails", had no
# way to tell anyone about a new failure elsewhere (minio-client-docker, 2026-11-04).
# So the changelog may declare the date, with a reason, in a comment the reader
# meets under [Unreleased]; it is reported as declared until that date and fails
# again the day after, so the door cannot be left open.
FIRST_RELEASE = re.compile(
    r"<!--\s*conformance:\s*first release not before (\d{4}-\d{2}-\d{2})\s*[-\u2014]\s*(.*?)\s*-->")


def changelog_claims(repo, exempt=None):
    """Every version this repository's changelog says it released, against the
    tags that exist.

    A changelog is a promise in public: a dated section under a version number
    says that version shipped. `self-host-repo-hardening-runbook` announced
    1.3.0, 1.3.1 and 1.3.2 and carried none of those tags, so anything
    following releases — update.sh included — still saw 1.2.0 as the newest
    while three sections of the document said otherwise.

    EVERY section, not only the newest. The first version of this rule read
    the top one alone, which passes the moment somebody tags the latest and
    leaves the two behind it untagged.
    """
    ch = repo.read("CHANGELOG.md")
    if ch is None:
        return []
    claimed = re.findall(r"^## \[(\d+\.\d+\.\d+)\]", ch, re.M)
    if not claimed:
        m = FIRST_RELEASE.search(ch)
        if not m:
            return ["CHANGELOG has no released version at the top"]
        due, why = m.group(1), m.group(2)
        today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
        if today > due:
            return [f"CHANGELOG has no released version at the top, and the first release it declared for {due} has not happened"]
        if exempt is not None:
            exempt.append(f"no released version yet, declared: first release not before {due} - {why}")
        return []
    tags = repo.tags()
    missing = [v for v in claimed if "v%s" % v not in tags]
    if not missing:
        return []
    if len(missing) == 1:
        return ["CHANGELOG says %s shipped and there is no v%s tag" % (missing[0], missing[0])]
    return ["CHANGELOG says %d versions shipped that have no tag: %s"
            % (len(missing), ", ".join(missing))]


_SIZE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*([kmgtKMGT])?[bB]?\s*$")


def default_of(expr):
    """The value a ${VAR:-default} expression has when nothing is set: the
    innermost default, or None when the variable is required or has none."""
    expr = expr.strip().strip("'\"")
    while True:
        m = re.search(r"\$\{[A-Za-z0-9_]+:-([^${}]*)\}", expr)
        if not m:
            break
        expr = expr[:m.start()] + m.group(1) + expr[m.end():]
    return None if "${" in expr else expr


def size_bytes(text):
    """'2g', '2560m', '12G' as bytes; None when it is not a size."""
    m = _SIZE.match(text or "")
    if not m:
        return None
    unit = (m.group(2) or "").lower()
    return float(m.group(1)) * {"": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30, "t": 1 << 40}[unit]


def jvm_heap(block, compose):
    """The largest maximum heap a service gives a JVM, as (bytes, text), or None.

    Atlassian images read JVM_MAXIMUM_MEMORY; itzg's Minecraft images read
    MAX_MEMORY, else MEMORY, for both -Xms and -Xmx; anything else passes -Xmx
    in a *_JAVA_OPTS variable. MEMORY is only a heap on an itzg image, so the
    service's image (often an x-images anchor) is resolved first."""
    found = []
    for key, val in re.findall(r"^\s*-?\s*(JVM_MAXIMUM_MEMORY|MAX_MEMORY|MEMORY)\s*[:=]\s*(\S+)", block, re.M):
        if key != "JVM_MAXIMUM_MEMORY":
            img = re.search(r"^\s*image:\s*(\S+)", block, re.M)
            ref = img.group(1) if img else ""
            if ref.startswith("*"):
                a = re.search(r"&%s\s+(\S+)" % re.escape(ref[1:]), compose)
                ref = a.group(1) if a else ""
            if "itzg/" not in ref:
                continue
            if key == "MEMORY" and re.search(r"^\s*-?\s*MAX_MEMORY\s*[:=]", block, re.M):
                continue
        d = default_of(val)
        b = size_bytes(d)
        if b:
            found.append((b, d))
    for d in re.findall(r"-Xmx([0-9.]+[kKmMgG])", block):
        found.append((size_bytes(d), d))
    return max(found) if found else None


def memory_limit(block):
    """The default memory limit of a service, as (bytes, text), or None."""
    m = (re.search(r"limits:\s*\n(?:\s+cpus:[^\n]*\n)?\s+memory:\s*(\S+)", block)
         or re.search(r"^\s*mem_limit:\s*(\S+)", block, re.M))
    if not m:
        return None
    d = default_of(m.group(1))
    b = size_bytes(d)
    return (b, d) if b else None


def required_env(text):
    """Variables the compose file cannot do without: every ${VAR} occurrence
    that carries no default of its own.

    PER OCCURRENCE, NOT PER NAME. A variable written once as ${V:-x} and once
    as ${V} still renders empty at the second one, and it is the second one
    that reaches a user.

    Parsed rather than matched, because ${A:-${B:-c}} has cost this fleet an
    afternoon before, and full-line comments are dropped first: jira names a
    variable only inside a sentence explaining a redirect, and a scan that
    counted it reported a defect that was a comment.
    """
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    out, i = set(), 0
    while True:
        i = body.find("${", i)
        if i < 0:
            return out
        if i and body[i-1] == "$":        # $${...} is for the container, not compose
            i += 2
            continue
        depth, j = 1, i + 2
        while j < len(body) and depth:
            if body.startswith("${", j):
                depth += 1; j += 2; continue
            if body[j] == "}":
                depth -= 1; j += 1; continue
            j += 1
        inner = body[i+2:j-1]
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", inner)
        if m:
            rest = inner[m.end():]
            if not (rest.startswith(":-") or rest.startswith("-")):
                out.add(m.group(1))
            out |= required_env(rest)
        i = j


def workflow_claims(repo):
    """What a repository's workflows promise, whatever the repository is.

    A ONE-SHOT ROLLOUT IS A POINT IN TIME, NOT A RULE. Five waves in this fleet
    each fixed something everywhere it looked on the day it ran, and nothing
    looked again. Measured on 2026-09-23: the daily-cron wave had run before
    three templates received the CI it was meant to change, so they stayed
    weekly for three weeks under a security policy that said daily; the wave
    that stopped hiding failed Trivy scans walked the compose templates, so the
    one pipeline that PUBLISHES an image kept the flag. Each rule a wave
    established belongs here, where it is asked every day of every repository.
    """
    bad = []
    # A WORKFLOW THAT WAITS FOR ANOTHER ONE BY NAME WAITS FOREVER FOR ONE THAT
    # IS NOT THERE, and says nothing: workflow_run on a name no workflow
    # carries never fires. On 2026-10-13 the agent sandbox and the supply
    # chain repository had been given the platform's dependabot-automerge.yml,
    # which waits for "kind e2e" and reads verification.yml; neither
    # repository has either, so their update pull requests would have stayed
    # open with every check green.
    files = [n for n in repo.workflows() if n.endswith((".yml", ".yaml"))]
    bodies = {n: repo.read(f".github/workflows/{n}") or "" for n in files}
    titles = set()
    for body in bodies.values():
        m = re.search(r"^name:\s*(.+?)\s*$", body, re.M)
        if m:
            titles.add(m.group(1).strip("\"'"))
    for name, body in bodies.items():
        m = re.search(r"^\s+workflow_run:\s*\n\s+workflows:\s*\[([^\]]*)\]", body, re.M)
        for wanted in ([w.strip().strip("\"'") for w in m.group(1).split(",")] if m else []):
            if wanted and wanted not in titles:
                bad.append(f"{name} waits for a workflow named \"{wanted}\", and no workflow here has that name")
        for ref in sorted(set(re.findall(r"actions/workflows/([A-Za-z0-9_.-]+\.ya?ml)", body) +
                              re.findall(r"gh workflow run ([A-Za-z0-9_.-]+\.ya?ml)", body))):
            if ref not in bodies:
                bad.append(f"{name} reads or dispatches {ref}, which this repository does not have")
    # 8. A WRITE GRANT AT THE TOP OF A WORKFLOW APPLIES TO EVERY JOB IN IT,
    # including the ones somebody adds next year. The standard this fleet
    # advertises says "per-job permissions", and on 2026-09-14 OpenSSF
    # Scorecard scored Token-Permissions 0/10 on 83 of 94 public repositories
    # here — every one of them because dependabot-automerge.yml granted
    # contents: write and pull-requests: write at the file level. A public
    # scanner disagreeing with a public claim is the cheapest kind of finding
    # to lose and the most expensive to be caught on.
    for name in repo.workflows():
        if not name.endswith((".yml", ".yaml")):
            continue
        body = repo.read(f".github/workflows/{name}")
        if body is None:
            continue
        m = re.search(r"^permissions:\s*(?:#[^\n]*)?\n((?:[ \t]+\S[^\n]*\n)+)", body, re.M)
        top = m.group(1) if m else ""
        if re.search(r"^permissions:\s*write-all\s*$", body, re.M) or re.search(r":\s*write\b", top):
            granted = ", ".join(sorted(set(re.findall(r"^\s*([a-z-]+):\s*write\b", top, re.M)))) or "write-all"
            bad.append(f"{name} grants {granted} at the top of the file, where it applies to every job in it")
        # A TRIVY SCAN THAT CANNOT FINISH MUST FAIL THE RUN. The action exits 0
        # on findings, so continue-on-error hides only a scan that did not
        # complete - and the SARIF upload after it is skipped as well, leaving
        # nothing in the Security tab and a green run.
        jobs = body.split("\njobs:\n", 1)[1] if "\njobs:\n" in body else ""
        for chunk in re.split(r"(?m)^(?=  [A-Za-z0-9_-]+:\s*$)", jobs):
            m = re.match(r"  ([A-Za-z0-9_-]+):", chunk)
            if not m or "trivy" not in chunk.lower():
                continue
            if re.search(r"(?m)^    continue-on-error:\s*true\b", chunk):
                bad.append(f"{name}: job {m.group(1)} runs Trivy with continue-on-error, so a scan that "
                           f"cannot finish reads as success")
                continue
            for step in re.split(r"(?m)^(?=      - )", chunk):
                if "trivy" in step.lower() and re.search(r"(?m)^\s+continue-on-error:\s*true\b", step):
                    bad.append(f"{name}: a Trivy step in job {m.group(1)} carries continue-on-error, so a "
                               f"scan that cannot finish reads as success")
        # A NEW INDEX OVER THE SAME BUILD IS NOT DRIFT. A pin check that fails
        # on any difference between the pinned digest and the one the tag's
        # index names now goes red when a publisher pushes the index again
        # over the very same images. On 2026-11-09 fifteen templates did, for
        # alpine:3.22, nextcloud, joomla and wordpress, and the triage, which
        # compares the linux/amd64 build, rightly moved no pin to turn them
        # green. The comparison asks about the build too:
        # scripts/rollout-freshness-same-build.py is what puts it in.
        lines = body.split("\n")
        for k, line in enumerate(lines):
            if k and DRIFT_ERROR.search(line) and BARE_DIGEST_COMPARE.match(lines[k - 1]):
                bad.append(f"{name}: line {k + 1} reports digest drift for any new index, including one "
                           f"pushed again over the same linux/amd64 build")
    return bad


DRIFT_ERROR = re.compile(r"::error::.*digest drift")
BARE_DIGEST_COMPARE = re.compile(r'^\s*(?:el)?if \[ "\$\{?\w+\}?" != "\$\{?\w+\}?" \]; then\s*$')


# Templates whose restore scripts CI does not run yet. THIS LIST ONLY SHRINKS:
# a repository on it that now runs its scripts is a finding until it is taken
# off, and a repository not on it that ships a script CI does not run fails.
# Measured on 2026-09-23, when the rule was written: of the 47 templates
# shipping restore scripts, none had CI run them, and the conversion found them
# wrong in ways no run could see - Bitnami paths on non-Bitnami images, one that
# refused to run at all, one that signed in with the wrong account, restores
# that merged instead of replacing, and Outline's backup, which had been
# archiving a volume nothing wrote to. The same day all 47 were converted and
# the list emptied. It stays, empty, as the door for a template that cannot be
# converted in the change that adds it - with the reason in that change.
RESTORE_NOT_YET_RUN = set()

# Test mode only: the fixture repository is not called by any name on the list.
if LOCAL and os.environ.get("FLEET_RESTORE_NOT_YET_RUN"):
    RESTORE_NOT_YET_RUN = set(os.environ["FLEET_RESTORE_NOT_YET_RUN"].split(","))


def unrun_restore_scripts(repo, names):
    """(scripts shipped, scripts CI never invokes, where it looked) - or None for
    the second when nothing could be read. An invocation is ./<script>, or a
    path ending in /<script> such as "$ROOT/<script>", on a line that is not a
    comment and not something printed: a test that only mentions the script's
    name is exactly the test that let them drift. The path form is there
    because restore-drill's test runs its script as "$ROOT/restore-drill.sh",
    and the first version of this counted that as never run."""
    scripts = sorted(n for n in names if re.fullmatch(r"[A-Za-z0-9_.-]*restore[A-Za-z0-9_.-]*\.sh", n))
    if not scripts:
        return [], [], []
    paths = [f"tests/{n}" for n in repo.names_in("tests") if n.endswith(".sh")]
    paths += [f".github/workflows/{n}" for n in repo.workflows()]
    lines = []
    for path in paths:
        for line in (repo.read(path) or "").splitlines():
            t = line.strip()
            if not t or t.startswith(("#", "echo ", "note ", "printf ", "ok ", "bad ", "fail ")):
                continue
            lines.append(t)
    if not lines:
        return scripts, None, paths
    body = "\n".join(lines)
    unrun = [sc for sc in scripts if not re.search(r"(?:(?<![\w/.-])\./|/)" + re.escape(sc) + r"(?![\w.-])", body)]
    return scripts, unrun, paths


# --- Kubernetes repositories --------------------------------------------------
#
# The same standard, in the shape a Kubernetes platform takes: the checks run
# on what Argo CD would apply, each is shown its violation, a kind cluster
# proves the platform every day, and nothing claims more than CI proves. Each
# rule below is broken on a copy of a real Kubernetes repository in
# tests/test-conformance-kubernetes.sh before it is trusted.

K8S_CHECKS = ("images", "kubeconform", "kube-linter", "pluto", "argocd", "policy-tests", "kyverno")
RUNBOOKS = ("upgrade", "rollback", "restore", "incident")
# A reference architecture describes; it does not claim. These need a person's
# say-so in .github/claims-allowlist, one phrase per line with its reason.
CLAIMS = re.compile(r"\b(in production at|used in production|runs in production|production[- ]proven|"
                    r"battle[- ]tested|trusted by|certified)\b", re.I)
CLOUD_LOGIN = re.compile(r"configure-aws-credentials|role-to-assume|azure/login|google-github-actions/auth")
# The delete-only identity a sweeper logs in as, one per cloud, and the
# creation identity or apply that would make a run anything but delete-only.
SWEEP_IDENTITY = re.compile(r"(role-to-assume|service_account|client-id):\s*\$\{\{\s*vars\."
                            r"(AWS_SWEEP_ROLE_ARN|GKE_SWEEP_SERVICE_ACCOUNT|AZURE_SWEEP_CLIENT_ID)\s*\}\}")
CREATE_IDENTITY = re.compile(r"vars\.(AWS_CREATE_ROLE_ARN|GKE_CREATE_SERVICE_ACCOUNT|AZURE_CREATE_CLIENT_ID)"
                             r"|terraform[^\n]*\bapply\b|eks-up")


def claim_findings(repo, paths):
    bad = []
    allow = (repo.read(".github/claims-allowlist") or "").lower()
    for path in paths:
        for m in CLAIMS.finditer(repo.read(path) or ""):
            if m.group(0).lower() not in allow:
                bad.append(f"{path} claims \"{m.group(0)}\": not allowed unless listed in .github/claims-allowlist with a reason")
                break
    return bad


def weekly_or_rarer(cron):
    """True when a five-field cron fires at most once a week: one minute, one
    hour, and either one day of the week or one day of the month."""
    f = cron.split()
    if len(f) != 5 or not all(re.fullmatch(r"\d{1,2}", x) for x in f[:2]):
        return False
    dom, dow = f[2], f[4]
    one_dow = re.fullmatch(r"[0-7]|(?i:sun|mon|tue|wed|thu|fri|sat)", dow)
    return (dom == "*" and bool(one_dow)) or (bool(re.fullmatch(r"\d{1,2}", dom)) and dow == "*")


def jobs_of(text):
    """{job id: its text} for a workflow's jobs, read by indentation: a job is
    a two-space key under the top-level jobs: key."""
    m = re.search(r"^jobs:\s*$", text, re.M)
    if not m:
        return {}
    jobs, name, lines = {}, None, []
    for line in text[m.end():].splitlines():
        head = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if head or (line and not line.startswith(" ") and not line.startswith("#")):
            if name:
                jobs[name] = "\n".join(lines)
            if not head:
                break
            name, lines = head.group(1), []
        elif name:
            lines.append(line)
    if name:
        jobs[name] = "\n".join(lines)
    return jobs


def branch_only_push(text):
    """True when the workflow's push trigger ignores main and every job that
    logs in to a cloud runs on main only: a push to any other branch can then
    start nothing that logs in. The flagship's GKE run (ADR 22) uses this to
    prove from a branch that the federation refuses it."""
    on = re.search(r"^on:\s*$(.*?)^(?=\S)", text, re.M | re.S)
    if not on or re.search(r"^\s+pull_request(_target)?:", on.group(1), re.M):
        return False
    push = re.search(r"^  push:\s*$((?:\n(?:    .*|\s*))*)", on.group(1), re.M)
    if not push or not re.search(r"branches-ignore:\s*(\[\s*['\"]?main['\"]?\s*\]|\n\s+-\s*['\"]?main['\"]?\s*$)",
                                 push.group(1), re.M):
        return False
    cloud_jobs = [j for j in jobs_of(text).values() if CLOUD_LOGIN.search(j)]
    main_only = re.compile(r"^    if:.*github\.ref\s*==\s*'refs/heads/main'", re.M)
    return bool(cloud_jobs) and all(main_only.search(j) for j in cloud_jobs)


def cloud_run_findings(workflows):
    """A workflow that logs in to a cloud is a workflow that spends money."""
    bad = []
    for w, text in sorted(workflows.items()):
        if not CLOUD_LOGIN.search(text):
            continue
        # A delete-only sweeper (below) makes nothing, so it has nothing to
        # tear down; every other cloud run needs its teardown.
        delete_only = bool(SWEEP_IDENTITY.search(text)) and not CREATE_IDENTITY.search(text)
        if re.search(r"secrets\.(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY)|aws-access-key-id:", text):
            bad.append(f"{w}: a cloud run with a stored access key instead of OIDC")
        if not re.search(r"^\s+timeout-minutes:", text, re.M):
            bad.append(f"{w}: a cloud run without a job timeout")
        if "if: always()" not in text and not delete_only:
            bad.append(f"{w}: a cloud run without a teardown that runs if: always()")
        if not re.search(r"^concurrency:", text, re.M):
            bad.append(f"{w}: a cloud run that two pushes could start twice (no concurrency group)")
        # A CLOUD RUN THAT STARTS ON ITS OWN IS BOUNDED. ADR 10 in
        # aws-eks-reference-platform asks for a daily sweeper that removes
        # what a run left behind; it spends nothing, and waiting for a person
        # is how leftovers keep billing. It is allowed on a schedule when it
        # assumes the delete-only role (whose own tests show it can create
        # nothing) and never applies. A run that applies may start on a
        # schedule at most once a week, and only behind a repository variable
        # the owner sets, so switching it off needs no commit; the account's
        # kill-switch bounds what a month of them can cost. A push or a pull
        # request never starts one, except a push to a branch other than main
        # into a workflow whose cloud jobs run on main only (branch_only_push).
        if re.search(r"^\s+schedule:|^\s+push:|^\s+pull_request:", text, re.M):
            on_push = re.search(r"^\s+(push|pull_request):", text, re.M) and not branch_only_push(text)
            crons = re.findall(r"^\s+-\s*cron:\s*[\"']([^\"']+)[\"']", text, re.M)
            weekly = (crons and all(weekly_or_rarer(c) for c in crons)
                      and re.search(r"github\.event_name\s*==\s*'schedule'\s*&&\s*vars\.[A-Z0-9_]+\s*==\s*'true'", text))
            scheduled = re.search(r"^\s+schedule:", text, re.M)
            if on_push or (scheduled and not (delete_only or weekly)):
                bad.append(f"{w}: a cloud run that starts on its own; it must be workflow_dispatch only, "
                           "a delete-only sweeper, or an apply at most weekly behind a repository variable")
    return bad


def kubernetes_rules(repo, names):
    bad = []
    files_kind = fleet_kind.kind_from_files(names)
    if files_kind != "kubernetes":
        bad.append(f"named as a Kubernetes repository, but its files say {files_kind or 'nothing recognisable'}")

    for f in ("LICENSE", "SECURITY.md"):
        if f not in names:
            bad.append(f"missing {f}")

    validate = repo.read("scripts/validate.sh")
    if validate is None:
        bad.append("no scripts/validate.sh: the static checks have no single entry point")
    else:
        for c in K8S_CHECKS:
            if f"check_{c.replace('-', '_')}()" not in validate:
                bad.append(f"scripts/validate.sh has no {c} check")

    plants = repo.read("tests/static/plants.tsv")
    if plants is None:
        bad.append("no tests/static/plants.tsv: no static check is ever shown a violation")
    else:
        planted = set()
        for line in plants.splitlines():
            fields = line.split("\t")
            if line.strip() and not line.startswith("#") and len(fields) >= 4:
                try:
                    planted.add(json.loads(fields[3]))
                except ValueError:
                    bad.append("tests/static/plants.tsv has a line that is not JSON fields")
        for c in K8S_CHECKS:
            if c not in planted:
                bad.append(f"no planted violation for the {c} check")

    workflows = {w: repo.read(f".github/workflows/{w}") or "" for w in repo.workflows()}
    every = "\n".join(workflows.values())
    if "scripts/validate.sh" not in every:
        bad.append("no workflow runs scripts/validate.sh")
    if "tests/static/plant_violations.py" not in every:
        bad.append("no workflow shows the static checks their planted violations")
    e2e = [t for t in workflows.values() if "tests/e2e/run.sh" in t and "kind create cluster" in t]
    if not e2e:
        bad.append("no workflow runs tests/e2e/run.sh on a kind cluster")
    else:
        if not any(re.search(r"^\s+schedule:", t, re.M) for t in e2e):
            bad.append("the kind e2e workflow has no schedule: nothing proves the platform daily")
        if not any("upgrade-marker.sh check" in t for t in e2e):
            bad.append("the kind e2e workflow has no upgrade drill from the previous release")
    bad += cloud_run_findings(workflows)

    if "terraform" in names:
        tests = repo.names_in("terraform/tests")
        if not any(n.endswith(".tftest.hcl") for n in tests):
            bad.append("terraform/ has no terraform test")
        if "plants.tsv" not in tests or not re.search(r"(working-directory: terraform[\s\S]*?|terraform/)tests/plant_violations\.py|python3 tests/plant_violations\.py", every):
            bad.append("the Terraform test is never shown a violation in CI")

    for f in repo.names_in("platform/appsets"):
        text = repo.read(f"platform/appsets/{f}") or ""
        # targetRevision for sources, revision for a Git generator: both name
        # the commit a cluster reads, and neither may be a branch.
        for m in re.finditer(r"(targetRevision|\brevision):[ \t]*(.+?)[ \t]*$", text, re.M):
            key, rev = m.group(1), m.group(2).strip("'\"")
            if rev.startswith("{{"):
                if "platform_revision" not in rev:
                    bad.append(f"platform/appsets/{f}: a Git source at {rev}, not the cluster's platform_revision")
            elif not re.fullmatch(r"v?\d+\.\d+\.\d+([-+][\w.]+)?", rev):
                bad.append(f"platform/appsets/{f}: {key} {rev} is not one exact version")

    tree = repo.tree()
    bad += image_findings(repo, tree)

    for path in tree:
        if not (path.startswith("policies/") and path.count("/") == 1 and path.endswith(".yaml")):
            continue
        text = repo.read(path) or ""
        if "kind: ValidatingPolicy" not in text:
            continue
        name = re.search(r"^  name:\s*(\S+)", text, re.M)
        name = name.group(1) if name else path
        if not re.search(r"validatingAdmissionPolicy:\s*\n\s+enabled:\s*true", text):
            bad.append(f"policy {name} is enforced only through Kyverno's webhook; it must compile to a ValidatingAdmissionPolicy")
        test = repo.read(f"policies/tests/{name}/kyverno-test.yaml") or ""
        if "result: fail" not in test:
            bad.append(f"policy {name} has no test that shows it a violation")

    bad += readme_findings(repo, runbooks=True)
    return bad


def image_findings(repo, tree):
    """Every image a manifest names is pinned by digest."""
    bad = []
    for path in tree:
        if path.startswith(("apps/", "manifests/")) and path.endswith((".yaml", ".yml")):
            for line in (repo.read(path) or "").splitlines():
                m = re.match(r"\s*-?\s*image:\s*(\S+)", line)
                if m and "@sha256:" not in m.group(1):
                    bad.append(f"{path}: image {m.group(1)} is not pinned by digest")
    return bad


def readme_findings(repo, runbooks):
    """What a reader needs before trusting it: a diagram, a way to run it and
    tear it down, its cost, the decisions behind it, and no claim CI cannot
    back. A platform also owes its operators runbooks; a focused repository
    has no state to restore."""
    bad = []
    readme = repo.read("README.md") or ""
    if "```mermaid" not in readme:
        bad.append("README has no architecture diagram")
    if not re.search(r"^#+ .*quickstart", readme, re.I | re.M):
        bad.append("README has no quickstart")
    if not re.search(r"^#+ .*cost", readme, re.I | re.M):
        bad.append("README says nothing about what it costs")
    if "make down" not in readme and "teardown" not in readme.lower():
        bad.append("README does not say how to tear it down")
    adrs = [n for n in repo.names_in("docs/decisions") if re.match(r"\d{4}-.*\.md$", n)]
    if len(adrs) < 3:
        bad.append(f"docs/decisions holds {len(adrs)} decision records; the standard asks for at least 3")
    if runbooks:
        held = repo.names_in("docs/runbooks")
        for rb in RUNBOOKS:
            if f"{rb}.md" not in held:
                bad.append(f"no {rb} runbook in docs/runbooks")
    bad += claim_findings(repo, ["README.md"] + [f"docs/decisions/{n}" for n in adrs])
    return bad


# --- Planted manifests, a repository's own or its flagship's --------------------
#
# A focused repository proves its refusals with planted manifests in
# tests/e2e/plants, each saying what it expects, and a control that must be
# admitted. kubernetes-oscal-evidence plants nothing of its own on purpose:
# what it turns into evidence are the flagship's own planted pods, read from
# the flagship's signed release, and a copy here could drift from the release
# the evidence names. So the rule is met there by the flagship's plants, and
# conformance checks each link rather than taking flagship.lock's word for it:
#
#   1. flagship.lock names a fleet repository of this owner, at a tag that is
#      a published release of it (a tag of the local copy in test mode);
#   2. that repository's tests/e2e/plants, at that tag, meets the rule itself;
#   3. the e2e run reads them from where it unpacks that release: a script
#      tests/e2e/run.sh runs downloads what flagship.lock names into a .cache
#      directory, and every line of the scripts it runs that names a
#      tests/e2e/plants path names that directory, or a variable holding it.
# Each is broken on a copy of the repository in
# tests/test-conformance-flagship-plants.sh.

PLANTS_MISSING = "no planted manifests in tests/e2e/plants: no refusal is ever tried"


def plants_rule(names, read, where="tests/e2e/plants"):
    """The findings of the planted-manifest rule over one directory, or None
    when it holds no manifest at all."""
    expects = [(n, re.search(r"^# expect: (.+)$", read(n) or "", re.M))
               for n in names if n.endswith((".yaml", ".yml"))]
    if not expects:
        return None
    bad = [f"{where}/{n} does not say what it expects (# expect: ...)" for n, m in expects if not m]
    if not any(m and m.group(1).strip() == "admitted" for _, m in expects):
        bad.append("no planted manifest expects to be admitted: refusals without a control prove nothing")
    return bad


# --- Planted variants of a template, where a refusal goes through a provisioner --
#
# kubernetes-coder-agent-workspaces cannot plant manifests. What it proves
# refused is a Coder template edited to step outside, and a template reaches
# the cluster only through Coder's provisioner, so a manifest applied with
# kubectl would prove a different thing. Its plants are the variants of one
# tampered template (tests/e2e/tampered/), and tests/e2e/variants.tsv is the
# table of what each must get from the cluster: the text of the refusal,
# "admitted" for the control, or "measured" for a finding reported rather than
# gated. The rule is the same one in that form: every variant says what it
# expects, one of them must be refused and one admitted, and the e2e reads the
# table. Each part is broken in tests/test-conformance.sh.

VARIANTS = "tests/e2e/variants.tsv"


def variants_rule(repo):
    """The findings of the plants rule over a table of template variants, or
    None when the repository keeps no such table beside a tampered template."""
    table = repo.read(VARIANTS)
    if table is None or not repo.names_in("tests/e2e/tampered"):
        return None
    rows = [l.split("\t") for l in table.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    bad = [f"{VARIANTS}: variant {r[0].strip()!r} does not say what it expects"
           for r in rows if len(r) < 2 or not r[1].strip()]
    expects = [r[1].strip() for r in rows if len(r) >= 2 and r[1].strip()]
    if "admitted" not in expects:
        bad.append("no template variant expects to be admitted: refusals without a control prove nothing")
    if not any(e not in ("admitted", "measured") for e in expects):
        bad.append(f"{VARIANTS} names no variant that must be refused: no refusal is ever tried")
    run = "\n".join(l for l in (repo.read("tests/e2e/run.sh") or "").splitlines() if not l.lstrip().startswith("#"))
    if "variants.tsv" not in run:
        bad.append(f"tests/e2e/run.sh never reads {VARIANTS}: the table is not what the e2e checks")
    return bad


def names_at(name, path, ref):
    """The entries of one directory of a fleet repository at a tag."""
    if LOCAL:
        out = subprocess.run(["git", "-C", os.path.join(LOCAL, name), "ls-tree", "--name-only", f"{ref}:{path}"],
                             capture_output=True, text=True)
        return sorted(out.stdout.split()) if out.returncode == 0 else []
    try:
        return sorted(e["name"] for e in api(f"repos/{OWNER}/{name}/contents/{path}?ref={urllib.parse.quote(ref)}"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise


def read_at(name, path, ref):
    """One file of a fleet repository at a tag, or None."""
    if LOCAL:
        out = subprocess.run(["git", "-C", os.path.join(LOCAL, name), "show", f"{ref}:{path}"],
                             capture_output=True, text=True)
        return out.stdout if out.returncode == 0 else None
    try:
        d = api(f"repos/{OWNER}/{name}/contents/{path}?ref={urllib.parse.quote(ref)}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    return base64.b64decode(d["content"]).decode("utf-8", "replace")


def released(name, tag):
    """True when the tag is a published release of the repository."""
    if LOCAL:
        return tag in Repo(name).tags()
    try:
        api(f"repos/{OWNER}/{name}/releases/tags/{urllib.parse.quote(tag)}")
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


DOWNLOADS = re.compile(r"\bcurl\b|\bwget\b|gh release download|urlopen|requests\.get")


def flagship_plants(repo):
    """The plants rule for a repository with no planted manifests of its own:
    [] when its flagship's plants stand in for them (see above)."""
    lock = repo.read("flagship.lock")
    if lock is None:
        return [PLANTS_MISSING]
    line = next((l.split() for l in lock.splitlines() if l.strip() and not l.lstrip().startswith("#")), [])
    if len(line) < 2 or "/" not in line[0]:
        return [PLANTS_MISSING + "; flagship.lock names no repository and tag"]
    (owner, _, name), tag = line[0].partition("/"), line[1]
    if owner != OWNER or not fleet_kind.kind_of(name):
        return [PLANTS_MISSING + f"; flagship.lock names {line[0]}, which is not a fleet repository"]
    if not released(name, tag):
        return [PLANTS_MISSING + f"; flagship.lock names {name} at {tag}, which is not a release of it"]
    theirs = plants_rule(names_at(name, "tests/e2e/plants", tag),
                         lambda n: read_at(name, f"tests/e2e/plants/{n}", tag), f"{name}@{tag}:tests/e2e/plants")
    if theirs is None:
        return [PLANTS_MISSING + f"; flagship.lock names {name} {tag}, which plants nothing either"]
    if theirs:
        return [f"flagship.lock names {name} {tag}, whose plants fall short: {b}" for b in theirs]

    # What tests/e2e/run.sh runs, and what those scripts say. Paths written as
    # os.path.join(ROOT, ".cache", "flagship") read as .cache/flagship.
    run = repo.read("tests/e2e/run.sh") or ""
    code = lambda t: "\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#"))
    joined = lambda t: re.sub(r"""["']\s*,\s*["']""", "/", t)
    scripts = {p: joined(repo.read(p) or "") for p in sorted(set(re.findall(r"scripts/[\w.-]+\.(?:sh|py)", code(run))))}
    dirs = {d.rstrip(".") for t in scripts.values() if "flagship.lock" in t and DOWNLOADS.search(t)
            for d in re.findall(r"\.cache/[\w.-]+", code(t))}
    if not dirs:
        return [PLANTS_MISSING + "; tests/e2e/run.sh never downloads the release flagship.lock names"]
    held = {v for t in scripts.values() for v in re.findall(
        r"^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_]\w*)\s*=.*(?:%s)" % "|".join(map(re.escape, dirs)), t, re.M)}
    places = [re.escape(d) for d in dirs] + [r"\b%s\b" % re.escape(v) for v in held]
    uses = [(p, l) for p, t in scripts.items() for l in code(t).splitlines() if re.search(r"""["'/]tests/e2e/plants""", l)]
    if not uses:
        return [PLANTS_MISSING + f"; tests/e2e/run.sh never reads {name}'s tests/e2e/plants"]
    elsewhere = [p for p, l in uses if not any(re.search(pat, l) for pat in places)]
    if elsewhere:
        return [PLANTS_MISSING + f"; {', '.join(sorted(set(elsewhere)))} reads tests/e2e/plants from somewhere "
                f"other than where {name}'s release is unpacked ({', '.join(sorted(dirs))})"]
    return []


# --- Focused Kubernetes repositories -------------------------------------------
#
# Kubernetes, but not a platform: one question answered on kind (what an
# untrusted agent can reach; which images a cluster will run), no Argo CD and
# no state to back up.
# What stays from the standard: every static check it has is shown its
# violation, a kind cluster proves it every day, every refusal it claims is a
# planted manifest with the reason it must be refused for and a control that
# must be admitted, and nothing claims more than CI proves. Each rule is
# broken on a copy of the agent sandbox in tests/test-conformance-sandbox.sh.

def static_check_findings(repo, validate):
    """Every static check has one entry point and is shown a violation."""
    bad = []
    checks = re.findall(r"^check_([a-z0-9_]+)\(\)", validate or "", re.M)
    if validate is None:
        bad.append("no scripts/validate.sh: the static checks have no single entry point")
    elif not checks:
        bad.append("scripts/validate.sh defines no check")
    plants = repo.read("tests/static/plants.tsv")
    if plants is None:
        bad.append("no tests/static/plants.tsv: no static check is ever shown a violation")
    else:
        planted = set()
        for line in plants.splitlines():
            fields = line.split("\t")
            if line.strip() and not line.startswith("#") and len(fields) >= 4:
                try:
                    planted.add(json.loads(fields[3]))
                except ValueError:
                    bad.append("tests/static/plants.tsv has a line that is not JSON fields")
        for c in checks:
            if c.replace("_", "-") not in planted and c not in planted:
                bad.append(f"no planted violation for the {c} check")
    return bad


def focused_rules(repo, names):
    bad = []
    files_kind = fleet_kind.kind_from_files(names)
    if files_kind != "focused":
        bad.append(f"named as a focused Kubernetes repository, but its files say {files_kind or 'nothing recognisable'}")
    for f in ("LICENSE", "SECURITY.md"):
        if f not in names:
            bad.append(f"missing {f}")

    bad += static_check_findings(repo, repo.read("scripts/validate.sh"))

    workflows = {w: repo.read(f".github/workflows/{w}") or "" for w in repo.workflows()}
    every = "\n".join(workflows.values())
    if "scripts/validate.sh" not in every:
        bad.append("no workflow runs scripts/validate.sh")
    if "tests/static/plant_violations.py" not in every:
        bad.append("no workflow shows the static checks their planted violations")
    e2e = [t for t in workflows.values() if "tests/e2e/run.sh" in t and "kind create cluster" in t]
    if not e2e:
        bad.append("no workflow runs tests/e2e/run.sh on a kind cluster")
    elif not any(re.search(r"^\s+schedule:", t, re.M) for t in e2e):
        bad.append("the e2e workflow has no schedule: nothing proves it daily")
    bad += cloud_run_findings(workflows)

    planted = plants_rule(repo.names_in("tests/e2e/plants"), lambda n: repo.read(f"tests/e2e/plants/{n}"))
    if planted is None:
        planted = variants_rule(repo)
    if planted is None:
        bad += flagship_plants(repo)
    else:
        bad += planted

    bad += image_findings(repo, repo.tree())
    bad += readme_findings(repo, runbooks=False)
    return bad


# --- Measured Kubernetes repositories ------------------------------------------
#
# Kubernetes on kind again, but the claim is a number: one way of running a
# workload measured against another under the same load (the llm-d router
# against round-robin, on the same model servers). No Argo CD, no state, and
# no refusals to plant: what stays from the standard is that a kind cluster
# measures again every day, every check the measurement makes is shown the
# breaks it exists for, every image is pinned by digest, and the README says
# what it costs, how to run and tear it down, and claims no more than the run
# shows. Each rule is broken on a copy of the inference gateway in
# tests/test-conformance-measured.sh.

def measured_rules(repo, names):
    bad = []
    files_kind = fleet_kind.kind_from_files(names)
    if files_kind != "measured":
        bad.append(f"named as a measured Kubernetes repository, but its files say {files_kind or 'nothing recognisable'}")
    for f in ("LICENSE", "SECURITY.md"):
        if f not in names:
            bad.append(f"missing {f}")

    workflows = {w: repo.read(f".github/workflows/{w}") or "" for w in repo.workflows()}
    # The kind run is the workflow that installs kind and runs tests/e2e.sh.
    # Other workflows may run the same test elsewhere (a weekly GPU leg on
    # EKS) or plant breaks of their own (failure scenarios); neither stands
    # in for the daily kind run's schedule or its plants.
    e2e = [t for t in workflows.values() if "tests/e2e.sh" in t and "kubernetes-sigs/kind/releases" in t]
    if not e2e:
        bad.append("no workflow runs tests/e2e.sh on a kind cluster")
    else:
        if not any(re.search(r"^\s+schedule:", t, re.M) for t in e2e):
            bad.append("the e2e workflow has no schedule: nothing measures it again daily")
        if not any(re.search(r"plant-violations\.py.*tests/e2e\.sh", t) for t in e2e):
            bad.append("no workflow shows the measurement its planted breaks")
    rows = [l for l in (repo.read("tests/plants.tsv") or "").splitlines() if l.strip() and not l.startswith("#")]
    if not rows:
        bad.append("no planted breaks in tests/plants.tsv: the measurement is never shown what it must catch")

    # KIND'S OWN IMAGES ARE PINNED BY THE NODE THAT CARRIES THEM. kind runs its
    # control plane, CoreDNS, kube-proxy, kindnet and the storage provisioner
    # from copies preloaded in its node image, so a lock names them by the tag
    # their pods show, for the image check to accept, and the node's digest
    # fixes their bytes (kubernetes-llm-inference-gateway 662efcf). They count
    # as pinned only while KIND_NODE_IMAGE itself carries a digest.
    lock = repo.read("images.lock") or ""
    node_pinned = re.search(r"^KIND_NODE_IMAGE=\S*@sha256:[0-9a-f]{64}$", lock, re.M)
    for m in re.finditer(r"^([A-Z0-9_]+_IMAGE)=(\S*)$", lock, re.M):
        carried = node_pinned and m.group(1).startswith("KIND_") and m.group(1) != "KIND_NODE_IMAGE"
        if "@sha256:" not in m.group(2) and not carried:
            bad.append(f"images.lock: {m.group(1)} is not pinned by digest")
    for path in repo.tree():
        if path.startswith("deploy/") and path.endswith((".yaml", ".yml")):
            for line in (repo.read(path) or "").splitlines():
                m = re.match(r"\s*-?\s*image:\s*(\S+)", line)
                if m and "@sha256:" not in m.group(1):
                    bad.append(f"{path}: image {m.group(1)} is not pinned by digest")

    bad += cloud_run_findings(workflows)
    bad += readme_findings(repo, runbooks=False)
    return bad


# --- Evidence repositories -----------------------------------------------------
#
# No cluster and no cloud account of its own: the repository reads another
# one's scheduled cloud runs from their signed records and turns each into
# OSCAL evidence (cloud-evidence-pack reads the flagship's). So the daily kind
# run of a focused repository has nothing to stand on here. What stands in for
# it: the packs come from named runs and never from a cluster or a cloud login
# of the repository's own; the builder is shown every run it must refuse; every
# rule of the gate is switched off in turn and the tests must notice; and a
# release is verified for one exact signing identity, then shown a changed byte.
# What carries over from focused unchanged: the static checks and their planted
# violations, pinned images, and a README that claims no more than CI shows.
# Each rule is broken on a copy of cloud-evidence-pack in
# tests/test-conformance-evidence.sh.

EVIDENCE_REFUSALS = ("by-hand", "branch", "red-run", "forged-results", "forged-findings")


def evidence_rules(repo, names):
    bad = []
    files_kind = fleet_kind.kind_from_files(names)
    if files_kind != "evidence":
        bad.append(f"named as an evidence repository, but its files say {files_kind or 'nothing recognisable'}")
    for f in ("LICENSE", "SECURITY.md"):
        if f not in names:
            bad.append(f"missing {f}")

    validate = repo.read("scripts/validate.sh")
    bad += static_check_findings(repo, validate)

    workflows = {w: repo.read(f".github/workflows/{w}") or "" for w in repo.workflows()}
    every = "\n".join(workflows.values())
    if "scripts/validate.sh" not in every:
        bad.append("no workflow runs scripts/validate.sh")
    if "tests/static/plant_violations.py" not in every:
        bad.append("no workflow shows the static checks their planted violations")
    builds = [t for t in workflows.values() if "scripts/packs.sh" in t or "tests/e2e/run.sh" in t]
    if not builds:
        bad.append("no workflow builds the packs (scripts/packs.sh or tests/e2e/run.sh)")
    elif not any(re.search(r"^\s+schedule:", t, re.M) for t in builds):
        bad.append("the workflow that builds the packs has no schedule: a new run is never turned into evidence")
    for w, text in sorted(workflows.items()):
        if "kind create cluster" in text:
            bad.append(f"{w}: creates a kind cluster; evidence comes only from the runs it reads")
        if CLOUD_LOGIN.search(text):
            bad.append(f"{w}: logs in to a cloud; evidence comes only from the runs it reads")
    if not re.search(r"actions/runs/\d+", repo.read("README.md") or ""):
        bad.append("the README links no run: nothing it reports can be traced to the run it came from")

    # The builder refuses whatever is not a scheduled run that passed, and is
    # shown each such run. The plants name the refusals; the static checks run
    # them.
    plant = repo.read("scripts/plant.py") or ""
    missing = [p for p in EVIDENCE_REFUSALS if f'"{p}"' not in plant]
    if not plant:
        bad.append("no scripts/plant.py: the builder is never shown a run it must refuse")
    elif missing:
        bad.append(f"scripts/plant.py plants no {', '.join(missing)} run: the builder is never shown it")
    checks = re.findall(r"^check_([a-z0-9_]+)\(\)\s*\{(.*?)^\}", validate or "", re.M | re.S)
    bodies = {name: body for name, body in checks}
    one_line = dict(re.findall(r"^check_([a-z0-9_]+)\(\)\s*\{([^\n]*)\}\s*$", validate or "", re.M))
    bodies.update(one_line)
    if "tests/e2e/plants.sh" not in bodies.get("plants", ""):
        bad.append("scripts/validate.sh has no check_plants that runs tests/e2e/plants.sh")
    if "scripts/mutate.py" not in bodies.get("mutations", ""):
        bad.append("scripts/validate.sh has no check_mutations that runs scripts/mutate.py")

    plants_sh = repo.read("tests/e2e/plants.sh")
    if plants_sh is None:
        bad.append("no tests/e2e/plants.sh: no recorded run is ever planted")
    elif "plant.py all" not in plants_sh:
        bad.append("tests/e2e/plants.sh does not take its plants from scripts/plant.py all: a new plant would never run")
    rows = [l for l in (repo.read("tests/plants.tsv") or "").splitlines() if l.strip() and not l.startswith("#")]
    if not rows:
        bad.append("no lines in tests/plants.tsv: no rule of the gate is ever switched off")

    mapping = repo.read("mapping/controls.yaml") or ""
    block = re.search(r"^clouds:\n((?:[ \t]+.*\n|\s*\n|#.*\n)+)", mapping, re.M)
    clouds = re.findall(r"^  ([a-z0-9-]+):", block.group(1), re.M) if block else []
    if not clouds:
        bad.append("mapping/controls.yaml names no clouds: there is nothing to read runs from")
    if not re.search(r"tests/e2e/plants\b", mapping):
        bad.append("mapping/controls.yaml never names the flagship's tests/e2e/plants: no planted pod is checked against the release")
    recorded = repo.names_in("tests/fixtures/runs") or []
    for cloud in clouds:
        runs = [d for d in recorded if re.fullmatch(rf"{re.escape(cloud)}-\d+", d)]
        if not runs:
            bad.append(f"no recorded {cloud} run in tests/fixtures/runs: the {cloud} leg is never planted")
            continue
        whole = [d for d in runs
                 if {"run.json", "artifact.json"} <= set(repo.names_in(f"tests/fixtures/runs/{d}") or [])
                 and any(n.endswith(".zip") for n in repo.names_in(f"tests/fixtures/runs/{d}") or [])]
        if not whole:
            bad.append(f"tests/fixtures/runs: no {cloud} run with its run.json, artifact.json and archive")

    # A release is verified as a stranger would: one exact identity, the
    # provenance, and a changed byte that both must refuse.
    pack = workflows.get("pack.yml", "")
    if "cosign sign-blob" not in pack:
        bad.append("pack.yml signs nothing: a pack cannot be told from one anyone made")
    # The release check is the file that names pack.yml's identity on a tag:
    # pack.yml itself or a script it runs. The provenance and the changed byte
    # must be in that same file, since another script can verify something
    # else with slsa-verifier (the flagship's archive, in scripts/flagship.sh).
    named = sorted(set(re.findall(r"scripts/[A-Za-z0-9_.-]+\.sh", pack)))
    candidates = [pack] + [repo.read(n) or "" for n in named]
    exact = re.compile(r'--certificate-identity[ =]"?[^"\s]*/\.github/workflows/pack\.yml@refs/tags/')
    release = [t for t in candidates if exact.search(t)]
    if not release:
        bad.append("no release check verifies the packs for the exact identity of pack.yml on a tag")
    else:
        if not any("slsa-verifier verify-artifact" in t for t in release):
            bad.append("no release check verifies the packs' provenance with slsa-verifier")
        if not any(re.search(r"printf 'x' ?>>", t) for t in release):
            bad.append("no release check shows the verification a changed byte")

    bad += image_findings(repo, repo.tree())
    bad += readme_findings(repo, runbooks=False)
    return bad


def terraform_rules(repo, names):
    """A chart installed by Terraform is a pin like any other. Its version sits
    in a helm_release block, where no Dependabot ecosystem and no image check
    looks: amazon-eks-cluster-pipeline-terraform held the EBS CSI chart at
    2.18.0 while upstream reached 2.66.1 (found 2026-10-11)."""
    bad = []
    if not any(re.search(r'resource\s+"helm_release"', repo.read(n) or "") for n in names if n.endswith(".tf")):
        return bad
    workflows = {w: repo.read(f".github/workflows/{w}") or "" for w in repo.workflows()}
    if not any("helm_release" in t and "index.yaml" in t for t in workflows.values()):
        bad.append("installs charts with helm_release and no workflow compares their versions with the chart repository")
    return bad


# DEPENDABOT'S COOLDOWN STAYS ON. Since 2026-07-14 Dependabot opens a version
# update only once the release has been on its registry for three days, the
# window in which most compromised releases are caught and pulled; security
# updates are exempt and open at once. The fleet merges an update minutes
# after its verification passes, so those three days are the only time a bad
# release has to be noticed before it reaches main. The default needs no
# configuration, which is also why nothing would notice a dependabot.yml
# that turns it down or off: this does. Read from raw.githubusercontent.com,
# which costs the sweep's API quota nothing.
COOLDOWN_FLOOR = 3


def raw_read(repo, path):
    if LOCAL:
        return repo.read(path)
    try:
        with urllib.request.urlopen("https://raw.githubusercontent.com/%s/%s/HEAD/%s" % (OWNER, repo.name, path), timeout=30) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def cooldown_findings(text):
    """What in a dependabot.yml shortens or switches off the cooldown."""
    bad, lines = [], (text or "").splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)cooldown:\s*(#.*)?$", line)
        if not m:
            continue
        indent = len(m.group(1))
        for sub in lines[i + 1:]:
            if sub.strip() and not sub.lstrip().startswith("#") and len(sub) - len(sub.lstrip()) <= indent:
                break
            d = re.match(r"^\s*(default-days|semver-major-days|semver-minor-days|semver-patch-days):\s*(\d+)", sub)
            if d and int(d.group(2)) < COOLDOWN_FLOOR:
                bad.append(f".github/dependabot.yml sets {d.group(1)}: {d.group(2)}, below the {COOLDOWN_FLOOR}-day cooldown that keeps a release too new to trust off main")
            if re.match(r"^\s*exclude:", sub):
                bad.append(".github/dependabot.yml excludes dependencies from the cooldown; an update without it can merge minutes after a compromised release")
    return bad


# A PASSWORD ON A COMMAND LINE IS PUBLISHED TO THE WHOLE HOST. Every process's
# argv sits in /proc/<pid>/cmdline, mode 0444: any user on the machine, and any
# container sharing its PID namespace, reads it with `ps`, and the host sees
# every container's processes too. The environment of the same process is
# /proc/<pid>/environ, mode 0400, its owner's alone. On 2026-11-08 the home lab
# was found passing a restic password as `docker run -e RESTIC_PASSWORD="$RP"`
# and a database password as `-p...`; the same shapes were in this fleet's
# templates: nine backup sidecars dumping with `-p"$$X_DB_PASSWORD"`, eight
# restore scripts handing the password to `docker exec -e MYSQL_PWD="$X"`, a
# Source server holding its RCON password in its own argv for as long as it
# ran, a Garage admin token in a curl header.
#
# Two levels, both failures: a shipped file runs on somebody's host; a test
# runs on a CI runner, and is also where the next shipped line gets copied
# from. Workflow files are not read: a GitHub-hosted runner is the job's own.
# A line may declare an exemption the way resource limits do, with a reason:
#   # conformance: allow-argv-secret - <why>
ARGV_SECRET_NAME = r"[A-Za-z0-9_]*(?:PASS|PWD|SECRET|TOKEN|KEY|CRED)[A-Za-z0-9_]*"
Q = r"\\?[\"']?"  # an optional quote, escaped or not: -P \"$$X\" inside a compose string
ARGV_SECRET_PATTERNS = [
    # mysql -p"$X", mariadb-dump -p$$X: the client blanks its own copy once it
    # has parsed it, after it was readable, and after the length leaked
    (re.compile(r"(?<![\w-])-p" + Q + r"\$"), re.compile(
        r"\b(mysql|mariadb|mysqldump|mariadb-dump|mysqladmin|mariadb-admin|mysqlcheck|mariadb-check|mysqlimport|mariadb-import)\b"),
     "a MySQL/MariaDB client given its password as -p"),
    (re.compile(r"(?<![\w-])-p" + Q + r"\$\$?\{?" + ARGV_SECRET_NAME), None, "a password given as -p"),
    (re.compile(r"(?<![\w-])--password[= ]" + Q + r"\$"), None, "a password given as --password"),
    # docker run/exec -e NAME="$VALUE": the value is in the docker CLI's argv;
    # -e NAME alone takes it from the caller's environment and is the fix
    (re.compile(r"(?:^|\s)(?:-e|--env)[ =][\"']?(" + ARGV_SECRET_NAME + r")=" + Q + r"\$"), None,
     "a secret handed to -e NAME=value, which puts the value in docker's argv"),
    # ...and any other name, when the value is expanded from a variable, a
    # positional argument or a command: the name says nothing about what it
    # carries. Found 2026-11-08: a README handing an RCON password over as
    # -e PW="$(grep ...)", and a test logging in with -e P="$2". A value that
    # is not a secret passes by taking the same fix, NAME=... then -e NAME,
    # or by declaring the line.
    (re.compile(r"(?:^|\s)(?:-e|--env)[ =][\"']?([A-Za-z_][A-Za-z0-9_]*)=" + Q + r"(?:\$|`)"), None,
     "a value expanded into -e NAME=value, which puts it in docker's argv whatever the name"),
    # env NAME=value cmd, sudo NAME=value cmd: env and sudo are programs, so the
    # assignment is in their argv; a bare NAME=value prefix in a shell is not
    (re.compile(r"\b(?:env|sudo)\s+(?:-\S+\s+)*(" + ARGV_SECRET_NAME + r")=" + Q + r"\$"), None,
     "a secret set through env/sudo NAME=value, which is in that program's argv"),
    (re.compile(r"\bsqlcmd\b[^|;]*\s-P\s*" + Q + r"\$"), None, "sqlcmd given its password as -P"),
    (re.compile(r"Authorization:\s*(?:Bearer|Basic|token|Token)\s+" + Q + r"\$"), None,
     "an Authorization header built from a variable, which reaches curl's argv as -H"),
    (re.compile(r"\balias\s+set\b.*\$\{?" + ARGV_SECRET_NAME), None, "mc alias set given its secret key as an argument"),
    # any delimiter: a sed expression is usually written s|a|b|
    (re.compile(r"\bsed\b.*\$\$?\{?" + ARGV_SECRET_NAME), None, "a secret written into a file through sed's arguments"),
    # a crontab line runs as sh -c '<the line>': the expanded value is in sh's argv
    (re.compile(r"(?:^|[\"'\s])(?:[\d*/,-]+\s+){4}[\d*/,-]+\s+.*\b(" + ARGV_SECRET_NAME + r")=" + Q + r"\$"), None,
     "a secret in a crontab line, which cron runs as sh -c with the value in its arguments"),
    (re.compile(r"\+(?:rcon_password|sv_password|sv_setsteamaccount)\b[\"']?\s+" + Q + r"\$"), None,
     "a game server given a secret on its own command line, readable for as long as it runs"),
]
ARGV_SECRET_KEEP = re.compile(r"_(?:FILE|PATH|DIR)$")
ARGV_SECRET_ALLOW = re.compile(r"#\s*conformance:\s*allow-argv-secret\s*[-—]\s*(\S.*)")
ARGV_SECRET_FILES = re.compile(r"(\.(sh|bash|tpl)$|(^|/)Dockerfile[^/]*$|(^|/)[^/]*entrypoint[^/]*$|^[^/]*compose[^/]*\.ya?ml$)")
# A command in a README is run by whoever reads it, on their own host: the
# jediacademy README carried a docker run that put the RCON password in argv
# until v1.3.0 (2026-11-08), and no file this rule read had it. Only the shell
# code fences of README.md and docs/ are read; prose and other languages' blocks
# are not commands.
ARGV_SECRET_DOCS = re.compile(r"((^|/)README\.md$|^docs/.+\.md$)", re.I)
MD_FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*([\w+-]*)")
MD_SHELL = re.compile(r"^(bash|sh|shell|zsh|console|shell-session)$", re.I)


def shell_fences(lines):
    """A Markdown file's lines with everything outside a shell code fence
    blanked, so a finding keeps the file's own line number."""
    out, close, shell = [], None, False
    for line in lines:
        if close is None:
            m = MD_FENCE.match(line)
            if m:
                close, shell = re.compile(r"^\s*" + re.escape(m.group(1)[0]) + "{%d,}\\s*$" % len(m.group(1))), bool(MD_SHELL.match(m.group(2)))
            out.append("")
        elif close.match(line):
            close, shell = None, False
            out.append("")
        else:
            out.append(line if shell else "")
    return out
# A compose interpolation, ${NAME} or $NAME with one dollar, inside command: or
# entrypoint: is resolved by compose before the container starts: the value is
# the process's argument for as long as it runs (sftp's users, a Source
# server's +rcon_password). $$NAME is the container's shell expanding it at run
# time and is judged by the patterns above. redis-server is let through, by
# measurement: it overwrites its own arguments with its process title as it
# starts (/proc/1/cmdline reads "redis-server *:6379" on redis 7.4, 2026-11-08).
ARGV_SECRET_INTERP = re.compile(r"(?<!\$)\$\{?(" + ARGV_SECRET_NAME + r")\b")
ARGV_SECRET_SELF_HIDING = re.compile(r"\bredis-server\b")


def compose_command_secrets(path, lines, exempt):
    """Secrets compose interpolates into a service's command: or entrypoint:."""
    bad, i = [], 0
    while i < len(lines):
        m = re.match(r"^(\s+)(command|entrypoint):(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent, block = len(m.group(1)), [(i, lines[i])]
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > indent
                                  or re.match(r"^\s*-", lines[j]) and len(lines[j]) - len(lines[j].lstrip()) == indent):
            block.append((j, lines[j]))
            j += 1
        code = [(n, l) for n, l in block if not l.lstrip().startswith("#")]
        if not ARGV_SECRET_SELF_HIDING.search("\n".join(l for _, l in code)):
            for n, l in code:
                hit = ARGV_SECRET_INTERP.search(l)
                if not hit or ARGV_SECRET_KEEP.search(hit.group(1)):
                    continue
                allow = ARGV_SECRET_ALLOW.search(l) or (n and ARGV_SECRET_ALLOW.search(lines[n - 1]))
                what = f"{path}:{n + 1} {hit.group(1)} interpolated by compose into the container's {m.group(2)}"
                if allow:
                    exempt.append(f"{what}, declared: {allow.group(1).strip()}")
                else:
                    bad.append(f"{what} (\"{l.strip()[:90]}\"): the value is the process's argument for as long as it "
                               f"runs, readable by every user on the host with ps; hand it over in environment: or a file")
                break
        i = j
    return bad


def argv_secret_findings(repo, exempt):
    """Secrets handed to a program as arguments, in the files this repository
    ships and in its tests. Read from raw.githubusercontent.com: no API quota
    beyond the one tree listing."""
    bad = []
    try:
        blobs = repo.blobs()
    except urllib.error.HTTPError as e:
        return [f"could not list files to look for secrets on command lines: HTTP {e.code}"]
    for path, size in blobs:
        doc = bool(ARGV_SECRET_DOCS.search(path))
        if path.startswith(".github/") or not (doc or ARGV_SECRET_FILES.search(path)) or size > 512 * 1024:
            continue
        text = raw_read(repo, path)
        if text is None:
            continue
        where = "in a test, on the CI runner: " if re.match(r"(.*/)?tests?/", path) else ""
        lines = text.splitlines()
        if doc:
            where, lines = "in documentation, run by whoever reads it: ", shell_fences(lines)
        elif re.search(r"\.ya?ml$", path):
            bad += compose_command_secrets(path, lines, exempt)
        for i, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            # a compose list item `- +rcon_password` with its value on the next item
            probe = line
            if re.search(r"^\s*-\s*[\"']?\+(rcon_password|sv_password|sv_setsteamaccount)[\"']?\s*$", line) and i + 1 < len(lines):
                probe = line.rstrip() + " " + re.sub(r"^\s*-\s*", "", lines[i + 1])
            for pat, ctx, what in ARGV_SECRET_PATTERNS:
                m = pat.search(probe)
                if not m or (ctx is not None and not ctx.search(probe)):
                    continue
                if m.groups() and m.group(1) and ARGV_SECRET_KEEP.search(m.group(1)):
                    continue
                # the door sits on the line, or above the command it belongs
                # to: a command continued with \ has no room for a comment
                # between its lines
                start = i
                while start and lines[start - 1].rstrip().endswith("\\"):
                    start -= 1
                allow = ARGV_SECRET_ALLOW.search(line) or (start and ARGV_SECRET_ALLOW.search(lines[start - 1]))
                if allow:
                    exempt.append(f"{path}:{i + 1} {what}, declared: {allow.group(1).strip()}")
                else:
                    bad.append(f"{where}{path}:{i + 1} {what} (\"{line.strip()[:90]}\"): every user on the host "
                               f"reads a process's arguments with ps; pass it in the environment by name or in a file")
                break
    return bad


def check(repo, exempt=None):
    """check_repo, and the rules that hold for every kind of repository: the
    Dependabot cooldown, and no secret on a command line."""
    if exempt is None:
        exempt = []
    found = check_repo(repo, exempt)
    if found == ["repository listing is empty or unreadable"]:
        return found
    extra = cooldown_findings(raw_read(repo, ".github/dependabot.yml")) + argv_secret_findings(repo, exempt)
    if not extra:
        return found
    return extra if (found is NOT_APPLICABLE or found == NOT_APPLICABLE) else list(found) + extra


def check_repo(repo, exempt=None):
    """Returns a list of failures. An empty list means the repo conforms.
    Declared exemptions are appended to `exempt`, never to the failures."""
    bad = []
    if exempt is None:
        exempt = []
    names = repo.listing()
    if not names:
        return ["repository listing is empty or unreadable"]

    kind = fleet_kind.kind_of(repo.name)
    if kind == "kubernetes":
        return kubernetes_rules(repo, names) + workflow_claims(repo) + changelog_claims(repo, exempt)
    if fleet_kind.kind_from_files(names) == "kubernetes":
        return ["its files are a Kubernetes platform, but its name puts it outside the Kubernetes rules (scripts/fleet_kind.py)"]
    if kind == "focused":
        return focused_rules(repo, names) + workflow_claims(repo) + changelog_claims(repo, exempt)
    if fleet_kind.kind_from_files(names) == "focused":
        return ["its files are a focused Kubernetes repository, but its name puts it outside those rules (scripts/fleet_kind.py)"]
    if kind == "measured":
        return measured_rules(repo, names) + workflow_claims(repo) + changelog_claims(repo, exempt)
    if fleet_kind.kind_from_files(names) == "measured":
        return ["its files are a measured Kubernetes repository, but its name puts it outside those rules (scripts/fleet_kind.py)"]
    if kind == "evidence":
        return evidence_rules(repo, names) + workflow_claims(repo) + changelog_claims(repo, exempt)
    if fleet_kind.kind_from_files(names) == "evidence":
        return ["its files are an evidence repository, but its name puts it outside those rules (scripts/fleet_kind.py)"]

    compose_name = next((n for n in names if n.endswith(".yml") and "compose" in n), None)
    if not compose_name:
        compose_name = next((n for n in names if n.endswith(".yml")), None)
    if not compose_name:
        # Not every repository whose name ends in -docker is a compose
        # template: two are shell tooling. Saying so is not the same as saying
        # they pass, and it is not the same as saying they fail.
        #
        # BUT A CHANGELOG IS A CLAIM WHATEVER THE REPOSITORY IS. Returning
        # here meant a documentation repository could announce three releases
        # it had never tagged and never be asked about it, because the rule
        # that would have caught it sat behind a compose file it does not have.
        claims = changelog_claims(repo, exempt) + workflow_claims(repo)
        if kind == "terraform":
            claims += terraform_rules(repo, names)
        return claims if claims else NOT_APPLICABLE
    compose = repo.read(compose_name)
    if compose is None:
        return [f"{compose_name} is listed but could not be read"]

    # 1. pins
    if "x-images:" not in compose:
        bad.append("no x-images block: the pins are not in one place")
    elif "@sha256:" not in compose:
        # A digest is only meaningful for an image that is PULLED. modernuo
        # builds its own from a pinned upstream revision, so there is no
        # published digest to pin and demanding one is a finding nobody can
        # act on — the same shape as asking a compose file with no backup loop
        # in it for an atomic write.
        pulls = any("build:" not in b for _, b in services(compose)
                    if re.search(r"^\s+image:", b, re.M))
        if pulls:
            bad.append("x-images carries no digest pin for an image it pulls")

    svcs = services(compose)
    if not svcs:
        bad.append("no services parsed out of the compose file")

    for name, block in svcs:
        raw, block = block, uncommented(block)
        if "no-new-privileges" not in block:
            bad.append(f"{name}: no security_opt no-new-privileges")
        # Either form counts. `deploy.resources.limits` is the swarm-shaped
        # one; `mem_limit` is what a single-host compose file uses, and it
        # is the form the relay stack ships. Demanding only the first
        # reported services that are bounded as if they were not.
        has_limits = ("deploy:" in block and "limits:" in block) or "mem_limit:" in block
        if not has_limits:
            # An exemption has to be declared in the file, with a reason, on a
            # line the reader will meet before the service starts. A rule
            # everyone quietly works around is worse than one with a door in
            # it: the door leaves the reason where the next person will find
            # it. ollama is the case this was written for - the working set of
            # an LLM server is whichever model the operator loads, so any
            # number shipped here is a guess that becomes an OOM kill in the
            # middle of somebody's generation.
            # searched in the RAW block: the declaration is a comment, and the
            # comment stripping above would eat the thing being looked for.
            m = re.search(r"#\s*conformance:\s*allow-no-limits\s*[-\u2014]\s*(\S.*)", raw)
            if m:
                exempt.append(f"{name}: no resource limits, declared: {m.group(1).strip()}")
            else:
                bad.append(f"{name}: no resource limits")
        if STATEFUL.search(block) and not SKIP_SVC.search(name) and "stop_grace_period" not in block:
            bad.append(f"{name}: data-owning service with no stop_grace_period")
        # A HEAP THE CONTAINER CANNOT HOLD. The resource-limits rollout of
        # 2026-09-02 set every service's memory limit without reading the heap
        # the same file gives its JVM: Confluence got 2g under an 8G minimum
        # and 12G maximum heap, Jira 2g under 8G, Bitbucket 2g under 4G, the
        # Minecraft proxy 1g under 2G. The kernel counts everything in the
        # container and a JVM keeps memory outside its heap, so each was an OOM
        # kill waiting for real load; CI runs small heaps with no load and
        # never saw one. The image documentation asks for a quarter on top
        # (itzg's in so many words), and that is the bar here.
        heap = jvm_heap(block, compose)
        limit = memory_limit(block) if heap else None
        if heap and limit and limit[0] < heap[0] * 1.25:
            bad.append(f"{name}: memory limit {limit[1]} cannot hold the {heap[1]} JVM heap it is given "
                       f"and a quarter more for what the JVM keeps outside it")

    # 2. the backup loop writes somewhere else first and renames on success
    #
    # ONLY when this file defines the loop. minecraft-server uses itzg/mc-backup
    # and zammad calls Zammad's own zammad-backup: the writing happens inside a
    # purpose-built image, and demanding a .partial rename of a compose file
    # that contains no loop is a finding nobody can act on. A rule that produces
    # those is how a report stops being read.
    #
    # What still applies to them is the end-to-end test, below: whoever writes
    # the archive, somebody has to prove one restores.
    # The loop is not always in the compose file. zammad keeps it in
    # scripts/backup.sh, and looking only at the compose meant this check
    # reported that repository as fine while it still wrote dumps straight to
    # their final name - the one defect the check was written to catch, missed
    # because of where the code lives rather than what it does.
    scripts = ""
    for cand in ("scripts/backup.sh", "backup.sh"):
        s = repo.read(cand)
        if s:
            scripts += s
    searchable = compose + scripts
    # What counts as a loop that writes a backup. It used to be a list of dump
    # tools and `tar -<flags>c`, and that missed `tar -C /data ... -zcpf`: the
    # directory flag comes first and is upper case. Ten templates write their
    # archive that way, or dump with sqlcmd or Python's sqlite3, and every rule
    # below skipped them: the check reported them clean without reading their
    # loops (found 2026-10-20 while checking a blog post's claim about them).
    # Any write to a .partial name is a backup loop too, whatever the tool.
    defines_loop = bool(re.search(
        r'(pg_dump|mysqldump|mariadb-dump|mongodump|sqlcmd|sqlite3'
        r'|\btar\b[^\n]*\s-[A-Za-z]*c[A-Za-z]*f\b|\.partial")', searchable))
    if re.search(r"^  backups?:", compose, re.M) and defines_loop:
        # Both syntaxes: $$VAR in a compose command, ${VAR} in a shell script.
        # And SQL Server's own: BACKUP DATABASE ... TO DISK = N'$$FILE.partial'
        # is the server writing the file, and the same rules hold for it.
        wrote = set(re.findall(r'> "\$[\$\{]?([A-Z_]+)\}?\.partial"', searchable)) \
            | set(re.findall(r'--archive="\$[\$\{]?([A-Z_]+)\}?\.partial"', searchable)) \
            | set(re.findall(r'tar [^"]*"\$[\$\{]?([A-Z_]+)\}?\.partial"', searchable)) \
            | set(re.findall(r"TO DISK = N?'\$[\$\{]?([A-Z_]+)\}?\.partial'", searchable))
        if not wrote:
            bad.append("backup sidecar writes straight to the final name")
        for v in wrote:
            if not any(m in searchable for m in (
                    f'mv "$${v}.partial" "$${v}";',
                    f'mv "${{{v}}}.partial" "${{{v}}}"')):
                bad.append(f"{v}: written as .partial and never renamed on success")
            if not any(m in searchable for m in (
                    f'mv "$${v}.partial" "$${v}.failed"',
                    f'mv "${{{v}}}.partial" "${{{v}}}.failed"')):
                bad.append(f"{v}: no .failed rename on the failure branch")
            # The success condition must not test a name that does not exist
            # yet. This is positional on purpose: the same expression AFTER the
            # rename is correct, and a rule that flagged it everywhere would
            # fail the loops that verify the archive properly. Five repositories
            # shipped with exactly this defect on 2026-09-05 - the check kept
            # looking at the final name after the write moved to .partial, so
            # every cycle reported FAILED - and CI caught it, not a rule.
            lines = searchable.split("\n")
            w = next((i for i, l in enumerate(lines)
                      if f'"$${v}.partial"' in l and "mv " not in l), None)
            m = next((i for i, l in enumerate(lines)
                      if f'mv "$${v}.partial" "$${v}";' in l), None)
            if w is not None and m is not None:
                # up to and including whatever sits to the LEFT of the rename on
                # its own line: `[ -f "$$F" ] && mv "$$F.partial" "$$F"` is the
                # same defect written on one line.
                head = lines[m].split('mv "')[0]
                window = "\n".join(lines[w:m] + [head])
                if re.search(r'(-f|-s|gzip -t|tar -tzf) "\$\$%s"' % v, window):
                    bad.append(f"{v}: the success condition tests the final name, "
                               f"which does not exist until after the rename")
                # A tar archive is read back before it is named a backup.
                #
                # Scoped to tar deliberately. A dump written as `pg_dump | gzip
                # > f.partial` under `set -o pipefail` already has a
                # trustworthy exit status: if either end of that pipe fails,
                # including a full disk, the pipeline fails and nothing is
                # renamed. Demanding `gzip -t` there too would flag twenty
                # repositories for something that is not broken, and a report
                # nobody can act on is a report nobody reads.
                #
                # tar is different, and in two ways. BusyBox tar - what an
                # alpine sidecar runs - returns 1 both for "a file changed
                # while I read it" and for "I could not write the output at
                # all", so the exit code cannot tell an archive from an empty
                # file. And on any tar, an exit code has never been a statement
                # about whether the file it produced opens. Reading it back is.
                if w is not None and "tar -" in lines[w] and not re.search(
                        r'tar -t[a-z]*f "\$\$%s\.partial"' % v, window or ""):
                    bad.append(f"{v}: a tar archive renamed on the exit code alone - "
                               f"never read back before it is called a backup")
    if re.search(r"^  backups?:", compose, re.M) and "tests" not in names:
        bad.append("a backup sidecar with no end-to-end test")

    # 3. the surrounding repository
    for f in ("README.md", "CHANGELOG.md", "LICENSE", "SECURITY.md", ".env.example", ".gitignore"):
        if f not in names:
            bad.append(f"missing {f}")

    # EVERY SERVICE SAYS WHAT HAPPENS WHEN IT STOPS.
    #
    # A service with no restart policy stays down after a host reboot while the
    # rest of the stack comes back. Measured on 2026-09-23: dashy's application,
    # and the cron sidecar of both Nextcloud templates - so after a reboot the
    # Nextcloud UI worked and every background job silently did not. A template
    # built from dashy that day inherited it. A one-shot service is right not to
    # restart, and says so with restart: "no": explicit is how intent differs
    # from something forgotten.
    for cname in [n for n in names if n.endswith((".yml", ".yaml")) and "compose" in n] or [compose_name]:
        ctext = repo.read(cname) or ""
        parts = re.split(r"(?m)^services:\n", ctext, maxsplit=1)
        if len(parts) < 2:
            continue
        body = re.split(r"(?m)^\S", parts[1], maxsplit=1)[0]
        for svc, block in re.findall(r"(?ms)^  ([A-Za-z0-9_.-]+):\n(.*?)(?=^  [A-Za-z0-9_.-]+:\n|\Z)", body):
            if re.search(r"(?m)^    (image|build):", block) and not re.search(r"(?m)^    restart:", block):
                bad.append(f"service {svc} in {cname} has no restart policy: after a host reboot it stays "
                           f"down (a one-shot service says restart: \"no\")")

    # A RESTORE SCRIPT CI DOES NOT RUN IS A GUESS.
    #
    # The tests restored with their own copy of the commands, so the script a
    # person runs on the day they need it was never the one that passed. See
    # RESTORE_NOT_YET_RUN for what that let through.
    scripts, unrun, looked = unrun_restore_scripts(repo, names)
    if scripts:
        if unrun is None:
            bad.append(f"ships {', '.join(scripts)}, and nothing under tests/ or .github/workflows/ could be "
                       f"read to see whether CI runs them (looked in: {', '.join(looked) or 'nothing found'})")
        elif repo.name in RESTORE_NOT_YET_RUN:
            if unrun:
                exempt.append(f"restore scripts CI does not run yet, listed in RESTORE_NOT_YET_RUN: {', '.join(unrun)}")
            else:
                bad.append("CI runs every restore script now: take it off RESTORE_NOT_YET_RUN, "
                           "so a regression here fails instead of being excused")
        elif unrun:
            bad.append(f"CI never runs {', '.join(unrun)}: a restore script that no test invokes can be "
                       f"wrong for its stack while every run is green")

    # A RESTORE MUST NOT COPY A DIRECTORY OVER THE DATA ROOT. `cp -a <dir>/.
    # <root>/` copies <dir>'s own owner and mode onto <root>. Seven templates
    # put their kept paths back that way; the data root became root-owned and
    # the restored database, given the root's owner, did too. AnythingLLM runs
    # as uid 1000 and came back from its first restore test (2026-10-19)
    # reading everything and writing nothing. The six others ran as root or
    # chowned on start, which is luck, not design. Comments are not code.
    for sc in scripts:
        for line in (repo.read(sc) or "").splitlines():
            if line.lstrip().startswith("#"):
                continue
            if re.search(r"\bcp\s+-[A-Za-z]*a[A-Za-z]*\s+\S*/\.['\"]?\s", line):
                bad.append(f"{sc} copies a directory over the data root with cp -a <dir>/. "
                           f"(\"{line.strip()[:80]}\"): that copies the directory's owner onto the root, "
                           f"and an unprivileged application cannot write after the restore; move kept paths back one by one")
                break

    # A PRUNE THAT IS ONLY INTENDED IS NOT A PRUNE.
    #
    # A backup sidecar that prunes old archives is one line of find; whether
    # that line ever deletes anything, and whether it stops at the recent
    # archives, is what fills a disk or empties one. Thirteen templates had
    # no test exercising it until 2026-09-25, and one of them (Zammad) had
    # never asked. A compose file that prunes needs a test under tests/ that
    # says so on a line that is not a comment.
    composes = [n for n in names if re.search(r"\.ya?ml$", n) and "compose" in n] or [compose_name]
    prunes = [n for n in composes if re.search(r"PRUNE_DAYS|HOLD_DAYS|-mtime", repo.read(n) or "")]
    if prunes:
        tests = [f"tests/{n}" for n in repo.names_in("tests") if n.endswith(".sh")]
        exercised = any(re.search(r"(?im)^(?!\s*#).*prun", repo.read(t) or "") for t in tests)
        if tests and not exercised:
            bad.append(f"{', '.join(prunes)} prunes old backups and no test under tests/ exercises the prune: "
                       f"a prune that is only intended fills the disk, and one that takes everything is a backup "
                       f"that is not there on the day")

    # EVERY VARIABLE THE STACK CANNOT DO WITHOUT, IN THE FILE PEOPLE COPY.
    #
    # The README says to copy .env.example and edit it. Nothing checked that
    # the file it tells you to copy carries what the compose file needs. On
    # 2026-09-22 two stacks did not: wordpress referenced the apex domain from
    # its www-redirect router, which rendered as Host(``) — accepted by
    # Traefik, given a load balancer, and then dropped with one line at debug
    # level — and outline rendered an empty upload ceiling. Both were green in
    # every check this fleet runs, because the deployment CI boots is built
    # from a list inside the workflow rather than from the documented file.
    example = repo.read(".env.example")
    if example is not None:
        declared = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", example, re.M))
        composes = [n for n in names if re.search(r"\.ya?ml$", n) and "compose" in n] or [compose_name]
        needed = set()
        for n in composes:
            body = repo.read(n)
            if body:
                needed |= required_env(body)
        undocumented = sorted(v for v in needed if v not in declared)
        if undocumented:
            bad.append(".env.example does not declare %s, and the compose file has no "
                       "default for it: a deployment made the documented way gets an "
                       "empty value" % ", ".join(undocumented))

    # A TRAEFIK THE OPERATOR CANNOT TUNE WITHOUT FORKING THE FILE.
    #
    # Traefik reads its static configuration from one source, and in these
    # stacks that source is the command list in the compose file. A compose
    # override cannot append to that list, only replace it whole, and whoever
    # replaces it stops taking the template's updates with it. On 2026-09-23 a
    # Keycloak user asked for exactly this (keycloak #45): the entry point's
    # timeouts, and no way to set them. Forty of fifty Traefik stacks had
    # none, nine had them under nine different names, and one had only the
    # read timeout. A timeout the operator
    # may need, for a slow upload or a long stream, is a variable with
    # Traefik's own default, so leaving it unset changes nothing.
    for cname in [n for n in names if n.endswith((".yml", ".yaml")) and "compose" in n] or [compose_name]:
        ctext = repo.read(cname) or ""
        if "--providers.docker" not in ctext or "--entrypoints.websecure.address" not in ctext:
            continue
        # One name everywhere, so the answer to "how do I tune this" is the same
        # in every README: a stack's own older name may sit nested inside it.
        unset = [t for t in ("readTimeout", "writeTimeout", "idleTimeout")
                 if not re.search(r"--entrypoints\.websecure\.transport\.respondingTimeouts\.%s="
                                  r"\$\{TRAEFIK_%s_TIMEOUT:-" % (t, t[:-7].upper()), ctext)]
        if unset:
            bad.append(f"Traefik's {', '.join(unset)} on the HTTPS entry point in {cname} is not set "
                       f"from TRAEFIK_READ_TIMEOUT, TRAEFIK_WRITE_TIMEOUT and TRAEFIK_IDLE_TIMEOUT: "
                       f"an operator can change it only by replacing the whole command, and then "
                       f"stops taking updates")

    gi = repo.read(".gitignore")
    if gi is not None and not re.search(r"^\.env\s*$", gi, re.M):
        bad.append(".gitignore does not exclude .env")

    wf = repo.read(".github/workflows/deployment-verification.yml")
    # THE FRESHNESS JOB MAY LIVE IN ITS OWN FILE. It moved out so the badge a
    # visitor reads says whether the stack boots, not whether a pin is one
    # version behind; nine red badges in ten were the latter. The rules below
    # are about what the repository checks, so they read both files as one.
    fresh = repo.read(".github/workflows/freshness.yml")
    if wf is None:
        bad.append("no Deployment Verification workflow")
    else:
        if fresh is not None:
            wf = wf + "\n" + fresh
        # Ask what the workflow DOES, not what its jobs are called. quake3
        # builds its own image, so one build-and-test job covers the scan and
        # the boot that the rest of the fleet splits across two; judging it by
        # job name reported three failures against a workflow that does more
        # than the ones that passed.
        # CHECKED DAILY, BECAUSE EVERY PUBLISHED SENTENCE SAYS SO. The profile
        # says every template boots in CI daily and each SECURITY.md says the
        # pins are re-resolved daily. Three templates ran weekly for three
        # weeks under those sentences: they received their CI after the wave
        # that made the schedule daily had already run.
        for cron in re.findall(r"cron:\s*['\"]([^'\"]+)['\"]", wf):
            f = cron.split()
            if len(f) == 5 and (f[2] not in ("*", "?") or f[4] not in ("*", "?")):
                bad.append(f"the verification runs on cron \"{cron}\", which is not daily, "
                           f"while every published claim about it says daily")
        for what, present in (
            ("lint anything", "lint" in wf.lower()),
            ("scan an image with Trivy", "trivy" in wf.lower()),
            ("check the pins for drift", "freshness" in wf.lower()),
            ("actually start the stack", "docker compose" in wf and " up" in wf),
        ):
            if not present:
                bad.append(f"the workflow does not {what}")

        # The freshness job can be watching a pin that is not there.
        # cs2-server was published with MINECRAFT_SERVER_IMAGE_TAG and
        # MINECRAFT_SERVER_BACKUP_IMAGE_TAG in its digest loop, carried over
        # from the template it was adapted from. Neither exists in that compose
        # file, so the job failed every night on two variables that were never
        # there while the pin it exists to watch was never compared against the
        # registry at all. An empty pin then fell through to the image lookup
        # and reported "did not resolve", which points at Docker Hub - the
        # failure described the wrong system, which is why it survived being
        # looked at. A green freshness job proves the pins are current; a job
        # naming absent variables proves nothing and says nothing.
        declared = set()
        pinned = set()
        for n in names:
            if n.endswith((".yml", ".yaml")):
                text = repo.read(n) or ""
                declared |= set(re.findall(r"\$\{([A-Z0-9_]+_IMAGE_TAG):-", text))
                # folded to `${VAR:-repo:tag@sha256:...}` so a nested
                # _IMAGE_VERSION default does not hide the digest
                flat = text
                for _ in range(4):
                    flat = re.sub(r"(\$\{[A-Z0-9_]+_IMAGE_TAG:-[^{}]*)"
                                  r"\$\{[A-Z0-9_]+:-([^{}]*)\}", r"\1\2", flat)
                pinned |= set(re.findall(r"\$\{([A-Z0-9_]+_IMAGE_TAG):-[^{}]*@sha256:", flat))
        named = set(re.findall(r"\b[A-Z0-9_]+_IMAGE_TAG\b", wf))
        for v in sorted(named - declared):
            bad.append(f"the workflow checks {v}, which no compose file defines")
        # And the other direction. A digest pin the freshness job does not
        # name is never compared against anything: the tag can be repushed
        # under the same version and every run stays green while saying
        # nothing about it. mailu had six such pins out of fourteen, one of
        # them following apache/tika:latest-full - a tag that moves by design,
        # frozen at a digest nobody was checking. Only DIGEST pins count here:
        # rathena builds two of its images from source, and there is nothing
        # in a registry to compare those to.
        # A job that enumerates the pins out of the compose file names none of
        # them and watches all of them. Reading it the same way as a
        # hand-written list would report every pin in the stack as unwatched -
        # the rule would fire hardest on the repositories that fixed the
        # problem properly.
        enumerates = bool(re.search(r"grep[^\n]*\[A-Z0-9_\]\+_IMAGE_TAG", wf))
        if not enumerates:
            for v in sorted(pinned - named):
                bad.append(f"{v} is pinned by digest and no freshness job watches it")

    # 4. the upgrade path. update.sh moves between release tags and names any
    # variable that became required since the deployed version; without it a
    # deployed host learns about a new required variable from `docker compose
    # up` failing after the checkout. And the deploy job that starts the
    # stack must start the PREVIOUS RELEASE first on the same volumes: a fresh
    # stack proves the image starts and nothing about the data a deployed
    # host already has. Only judged where the job has a start-up step to
    # anchor on; the game templates boot nothing in CI by design.
    up = repo.read("update.sh")
    if up is None:
        bad.append("no update.sh: a deployed host has no release-tag updater")
    elif "NEW VARIABLES SINCE YOUR VERSION" not in up:
        bad.append("update.sh does not name variables that became required since the deployed version")
    if up is not None:
        # Both found on 2026-10-05, both silent. An env file read with
        # 2>/dev/null made every value in it look unset when this user could
        # not read it, and with nothing new to check the checkout went ahead
        # and the stack failed afterwards on the permission. And the
        # ${VAR:?} search, under pipefail in a command substitution, ended
        # the script with status 1 whenever no compose file required
        # anything. tests/test-update-sh.sh runs both against a real script.
        if "is not readable by" not in up or "! -r" not in up:
            bad.append("update.sh does not stop on an env file it cannot read")
        if re.search(r"_required=.*\| tr '\\n' ' '\)\"", up):
            bad.append("update.sh ends with no message when no compose file requires a variable (the ${VAR:?} search needs '|| true' under pipefail)")
    if wf is not None and "Start up services using Docker Compose" in wf and "Upgrade drill" not in wf:
        # Declared in the workflow, with a reason, the way a missing resource
        # limit is declared in the compose file. An image built from the tree
        # has no previous release to start: it would be a rebuild of the same
        # sources.
        m = re.search(r"#\s*conformance:\s*allow-no-drill\s*[-—]\s*(\S.*)", wf)
        if m:
            exempt.append("no upgrade drill, declared: " + m.group(1).strip())
        else:
            bad.append("the deploy job starts a fresh stack and never the previous release on the same volumes")
    # An image's declared VOLUME that no mount covers is an anonymous volume:
    # data the backups never see and a down/up replaces. GLPI's lived in one
    # from 2026-08-31 to 2026-10-11 under a named volume mounted where the
    # image never reads, with every check green. The deploy job inspects every
    # container it starts for one; a workflow regenerated without that step
    # would quietly stop asking.
    if wf is not None and "Start up services using Docker Compose" in wf \
            and "Every volume an image declares is one this stack names" not in wf:
        bad.append("the deploy job never checks its containers for anonymous volumes")

    # 5. the README quotes the version the compose file pins. Triage moves a
    # pin and cuts a release; the "what success looks like" block keeps the
    # version before it, and the reader checks a healthy deployment against a
    # version it does not run. Only the two shapes the fleet uses to name a
    # running version are read, so a kernel range in prose is never mistaken
    # for one.
    readme = repo.read("README.md")
    if readme is not None:
        pinned = set()
        for n in names:
            if not n.endswith((".yml", ".yaml")) or n.startswith("."):
                continue
            text = repo.read(n) or ""
            block = re.search(r"^x-images:\n(.*?)(?=^\S)", text, re.S | re.M)
            if not block:
                continue
            for line in block.group(1).splitlines():
                m = re.search(r":-\s*[A-Za-z0-9][A-Za-z0-9./_-]*:\$\{[A-Z0-9_]+:-([^@}\s]+)", line)
                if m:
                    # A leading v is a tag convention, not part of the version:
                    # immich pins v3.1.0 and its README says 3.1.0, and reading
                    # those as different values reported a correct README as
                    # wrong while leaving every v-prefixed pin unchecked.
                    pinned.add(re.split(r"[-_+]", m.group(1).lstrip("v"), maxsplit=1)[0])
        # Capture the version, not the sentence around it: outline says
        # "latest stable (1.10 line)", and taking everything to the closing
        # bracket compared "1.10 line" against a pin of 1.10.0 and called a
        # correct README wrong.
        quoted = [(m.group(1).rstrip("."), "latest stable (...)")
                  for m in re.finditer(r"latest stable \(v?([0-9][0-9.]*)", readme)]
        for line in readme.splitlines():
            if line.lstrip().startswith("# Expected:"):
                quoted += [(m.group(1), "the Expected line")
                           for m in re.finditer(r'"version"\s*:\s*"([^"]+)"', line)]
        for v, where in quoted:
            base = re.split(r"[-_+]", v, maxsplit=1)[0]
            if pinned and not any(base == q or q.startswith(base + ".") or base.startswith(q + ".")
                                  for q in pinned):
                bad.append(f"README names {v} in {where} and no compose file pins that version")

    # 6. the .env.example names the version the compose file pins. Each pin
    # is ${X_IMAGE_TAG:-repo:${X_IMAGE_VERSION:-tag@digest}} and the example
    # shows "# X_IMAGE_VERSION=tag" as the default to override. Triage moved
    # the pin and cut the release; the example kept the version it was
    # written with. On 2026-09-30 fifty-four such lines across forty-two
    # templates named an older release, and a reader uncommenting one would
    # have pinned the past. Placeholders (<version>@sha256:<digest>, ...)
    # are a deliberate shape and are not read.
    example = repo.read(".env.example")
    if example is not None:
        declared = {}
        for line in example.splitlines():
            m = re.match(r"#?\s*([A-Z0-9_]+_IMAGE_VERSION)=(\S+)", line)
            if m and "<" not in m.group(2) and "..." not in m.group(2):
                declared.setdefault(m.group(1), m.group(2))
        for n in names:
            if not n.endswith((".yml", ".yaml")) or n.startswith("."):
                continue
            text = repo.read(n) or ""
            block = re.search(r"^x-images:\n(.*?)(?=^\S)", text, re.S | re.M)
            if not block:
                continue
            for line in block.group(1).splitlines():
                m = re.search(r":-\s*[A-Za-z0-9][A-Za-z0-9./_-]*:\$\{([A-Z0-9_]+):-([^@}\s]+)", line)
                if not m:
                    continue
                var, tag = m.group(1), m.group(2)
                if var in declared and declared[var] != tag:
                    bad.append(f".env.example names {declared[var]} for {var} and the compose file pins {tag}")

    bad += workflow_claims(repo)
    bad += changelog_claims(repo, exempt)
    return bad


def main():
    # WHAT IS UNDER THE STANDARD IS NOT A NAME SUFFIX.
    #
    # This selected repositories whose name ends in docker-compose or docker,
    # plus one written in by hand. Measured on 2026-09-22: of the 87 public
    # repositories carrying a changelog, **21 fell outside that pattern and
    # were never checked at all** — every Terraform pipeline, and every tool
    # this fleet publishes that is not a container. One of them had announced
    # three releases it never tagged, for four months, with a rule for exactly
    # that sitting in this file.
    #
    # A changelog is what a repository under this standard has. It is also the
    # thing the rules below judge, so it is the honest way to decide who is
    # being judged.
    if LOCAL:
        repos = sorted(n for n in os.listdir(LOCAL)
                       if os.path.isdir(os.path.join(LOCAL, n, ".git"))
                       and os.path.exists(os.path.join(LOCAL, n, "CHANGELOG.md")))
    else:
        names = []
        page = 1
        while True:
            batch = api(f"users/{OWNER}/repos?per_page=100&page={page}")
            if not batch:
                break
            names += [r["name"] for r in batch if not r["archived"] and not r["fork"]]
            page += 1
        repos = sorted(n for n in names if Repo(n).read("CHANGELOG.md") is not None)

    if not repos:
        print("::error::repository listing came back empty — refusing to report a false green")
        return 2

    failures, checked, skipped, exemptions = {}, 0, [], {}
    for name in repos:
        try:
            ex = []
            bad = check(Repo(name), ex)
            if ex:
                exemptions[name] = ex
        except Exception as e:                      # a transport failure is not a pass
            bad = [f"could not be checked: {e.__class__.__name__}: {e}"]
        if bad is NOT_APPLICABLE or bad == NOT_APPLICABLE:
            skipped.append(name)
            continue
        checked += 1
        if bad:
            failures[name] = bad

    print(f"## Fleet conformance — {checked} repositories checked\n")
    if skipped:
        print(f"_Not compose templates, so not judged as ones: {', '.join(skipped)}._\n")
    if exemptions:
        print("### Declared exemptions\n")
        for n in sorted(exemptions):
            for e in exemptions[n]:
                print(f"- **{n}** {e}")
        print()
    if not failures:
        print("Every repository meets the standard.")
        return 0
    print(f"**{len(failures)} of {checked} do not meet the standard.**\n")
    for name in sorted(failures):
        print(f"### {name}")
        for b in failures[name]:
            print(f"- {b}")
        print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
