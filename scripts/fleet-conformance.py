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
import base64, json, os, re, subprocess, sys, urllib.error, urllib.request

OWNER = os.environ.get("FLEET_OWNER", "heyvaldemar")
LOCAL = os.environ.get("FLEET_LOCAL_DIR")  # test mode: read from disk instead
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

NOT_APPLICABLE = ["__not-a-compose-template__"]

STATEFUL = re.compile(r"image:.*?\b(postgres|mysql|mariadb|mongo|redis|valkey)\b", re.I)
SKIP_SVC = re.compile(r"backup", re.I)

# Fleet stacks whose names do not end in -docker-compose or -docker. The filter
# below is a name rule, so a repository named for what it does rather than for
# how it is deployed is never checked, and nothing fails to say so.
EXTRA_FLEET_REPOS = ("chatops-privilege-wall",)


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


def changelog_claims(repo):
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
        return ["CHANGELOG has no released version at the top"]
    tags = repo.tags()
    missing = [v for v in claimed if "v%s" % v not in tags]
    if not missing:
        return []
    if len(missing) == 1:
        return ["CHANGELOG says %s shipped and there is no v%s tag" % (missing[0], missing[0])]
    return ["CHANGELOG says %d versions shipped that have no tag: %s"
            % (len(missing), ", ".join(missing))]


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
    return bad


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


def check(repo, exempt=None):
    """Returns a list of failures. An empty list means the repo conforms.
    Declared exemptions are appended to `exempt`, never to the failures."""
    bad = []
    if exempt is None:
        exempt = []
    names = repo.listing()
    if not names:
        return ["repository listing is empty or unreadable"]

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
        claims = changelog_claims(repo) + workflow_claims(repo)
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
    defines_loop = bool(re.search(r"(pg_dump|mysqldump|mariadb-dump|mongodump|tar -[a-z]*c)", searchable))
    if re.search(r"^  backups?:", compose, re.M) and defines_loop:
        # Both syntaxes: $$VAR in a compose command, ${VAR} in a shell script.
        wrote = set(re.findall(r'> "\$[\$\{]?([A-Z_]+)\}?\.partial"', searchable)) \
            | set(re.findall(r'--archive="\$[\$\{]?([A-Z_]+)\}?\.partial"', searchable)) \
            | set(re.findall(r'tar [^"]*"\$[\$\{]?([A-Z_]+)\}?\.partial"', searchable))
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
    # none; nine had them under nine different names. A timeout the operator
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

    bad += workflow_claims(repo)
    bad += changelog_claims(repo)
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
