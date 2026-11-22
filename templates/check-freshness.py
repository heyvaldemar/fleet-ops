#!/usr/bin/env python3
"""Report every pin in this repository that upstream has moved past.

    GH_TOKEN=... scripts/check-freshness.py
    scripts/check-freshness.py selftest   no network: a registry that keeps
                                          answering 429, versions with release
                                          candidates, and releases on both
                                          sides of the release-age grace

Pins are what make a green build mean something, and they are also what goes
stale without a sound. This compares each pin with upstream and prints a
GitHub annotation per pin that fell behind; it changes nothing. These
repositories are outside fleet triage: fleet heartbeat takes a failed run to
a person, and the bump is made by hand, with the new hash checked against the
publisher's, and has to pass the same checks as any other change.

ONE FILE FOR EVERY KUBERNETES REPOSITORY. fleet-ops keeps it as
templates/check-freshness.py and each repository carries a byte-for-byte copy
as scripts/check-freshness.py, which fleet conformance holds to the template.
What differs between repositories (which checks run, which files hold pins,
which upstream a pin follows) is in freshness.json at the repository root,
never in the copy. Until 15 November 2026 there were five copies, each a
little different, and a fix made in one reached none of the others.

A RELEASE YOUNGER THAN THREE DAYS IS A WARNING, NOT A FAILURE. The fleet's
release-age rule keeps a version off main until it is three days old, long
enough for a compromised release to be noticed and pulled. This check used to
fail the moment upstream published, so every release turned these
repositories red for three days in which nobody was allowed to act on it:
helm v4.3.2, published on 13 November at 04:53Z, failed
kubernetes-supply-chain-admission at once (run 43680156929). Now a version
newer than the pin is judged by when it was released:

  younger than three days   ::warning:: naming the moment it becomes a failure
  three days or older       ::error::, as before
  release date unreadable   ::error::: a release of unknown age gets no grace

The date is the release's published_at on GitHub, `created` in a chart
repository's index, published_at in the Terraform registry, and the release
date endoflife.date gives an EKS version. When the pin is behind several
releases, the newest one past the grace is the one it fails on. A tag that
now resolves to a different digest is not a new release and gets no grace;
neither does a pin this check cannot order.

The checks, each listed by name in freshness.json's "checks":

  charts          each `helm upgrade --install <release> <chart> --repo <url>
                  --version "$VAR"` in scripts/*.sh, VAR set in the same file,
                  against the chart repository's index
  charts_lock     each line of a tracked charts.lock (name version repository
                  sha256) against its repository's index
  appset_charts   the charts the ApplicationSets in "appsets" install, against
                  a Helm index or, for an OCI chart, its project's releases
  images          every image pinned as name:tag@sha256, inline or split into
                  registry, repository (or repo) and tag in values, against
                  what the tag resolves to now: a moved tag is a rebuilt image
                  nobody here has run. A pin on one platform's manifest is current while
                  that manifest is still in the index the tag points to
  chart_images    each chart rendered with and without the repository's image
                  pins ("render"), so a chart bump that moves an image's
                  default tag while the pin stays behind is caught here
  tools           each lock file in "tool_locks" against each tool's newest
                  release; kubectl against the newest patch of its minor
  ci_images       ci-images.pins, as images
  gvisor          gvisor.lock against gVisor's newest release
  providers       each Terraform provider pinned in a tracked .tf file
                  against the registry
  terraform_lock  each provider locked in a "terraform_locks" file against
                  the registry
  kubernetes      the minor the platform targets against EKS's newest, and its
                  standard support end, and the kind node image and Terraform
                  default against that target

A pin named in "stable" follows that project's stable release (GitHub's
"latest") instead of its newest version: Coder's chart and CLI, whose newer
mainline is not followed (kubernetes-coder-agent-workspaces, ADR 1).

A registry that keeps refusing is not a pin behind and not a pin current.
ECR Public throttles anonymous requests by source address, and GitHub's shared
runners share theirs. A refusal is tried three times over three minutes; after
that the pin is reported as not checked, which fails the run as a pin behind
does, and the summary never counts it as current.

freshness.json keys (a key this file does not know fails the run, because a
misspelt key would switch a check off without a word):

  checks           the checks above, in the order they run (required)
  skip_files       tracked files that hold no pins (default: the planted-
                   violation table, tests/static/plants.tsv)
  skip_dirs        directories that hold no pins (images a test plants on
                   purpose, for admission to refuse)
  skip_suffixes    file endings that hold no pins (.cast recordings of past
                   runs quote digests and pin nothing)
  image_paths      glob patterns for the files images are read from, instead
                   of every tracked file
  image_values     "lines" (default) reads registry/repository/tag splits line
                   by line; "yaml" walks the documents and also reads
                   repository/tag/digest (needs PyYAML)
  tool_locks       the lock files of "tools" (default ["tools.lock"])
  tools            {name: [owner/repo, tag pattern]} beyond the known tools
  stable           {name: owner/repo}: a chart or tool on a stable channel
  appsets          a glob for "appset_charts" (needs PyYAML)
  oci_charts       {chart: [owner/repo, tag pattern]} beyond the known ones
  render           {"script": path, "envs": [...]} for "chart_images"
  kubernetes       {"target", "kind_node", "terraform"}: the files that hold
                   the targeted minor, the kind node image, the Terraform default
  terraform_locks  the lock files of "terraform_lock"

A check that is listed needs the files it reads by name (a lock file, the CI
image pins): one that is missing fails the run. A file that holds pins for a
check that is not listed fails it too, so adding gvisor.lock without listing
"gvisor" cannot leave it unwatched.

Standard library only, except where freshness.json asks for YAML: the
repository that does installs PyYAML before it runs this.
"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
UTC = datetime.timezone.utc
GRACE_DAYS = 3
GRACE = datetime.timedelta(days=GRACE_DAYS)

# Every tool any of these repositories pins; freshness.json "tools" adds more.
TOOL_RELEASES = {
    "kind": ("kubernetes-sigs/kind", r"(v\d+\.\d+\.\d+)"),
    "oras": ("oras-project/oras", r"(v\d+\.\d+\.\d+)"),
    "cosign": ("sigstore/cosign", r"(v\d+\.\d+\.\d+)"),
    "helm": ("helm/helm", r"(v\d+\.\d+\.\d+)"),
    "kubeconform": ("yannh/kubeconform", r"(v\d+\.\d+\.\d+)"),
    "cloudflared": ("cloudflare/cloudflared", r"(\d+\.\d+\.\d+)"),
    "kube-linter": ("stackrox/kube-linter", r"(v\d+\.\d+\.\d+)"),
    "kyverno": ("kyverno/kyverno", r"(v\d+\.\d+\.\d+)"),
    "pluto": ("FairwindsOps/pluto", r"(v\d+\.\d+\.\d+)"),
    "promtool": ("prometheus/prometheus", r"(v\d+\.\d+\.\d+)"),
}
# OCI charts have no index to read; their projects tag releases instead.
OCI_RELEASES = {
    "gateway-helm": ("envoyproxy/gateway", r"(v\d+\.\d+\.\d+)"),
    "karpenter": ("aws/karpenter-provider-aws", r"v(\d+\.\d+\.\d+)"),
}
REF = re.compile(r"([\w.-]+(?:/[\w.-]+)+:[\w.-]+@sha256:[0-9a-f]{64})")

CHECK_NAMES = ("charts", "charts_lock", "appset_charts", "images", "chart_images", "tools", "ci_images",
               "gvisor", "providers", "terraform_lock", "kubernetes")
DEFAULTS = {
    "skip_files": ["tests/static/plants.tsv"],
    "skip_dirs": [],
    "skip_suffixes": [],
    "image_paths": None,
    "image_values": "lines",
    "tool_locks": ["tools.lock"],
    "tools": {},
    "stable": {},
    "appsets": None,
    "oci_charts": {},
    "render": None,
    "kubernetes": None,
    "terraform_locks": [],
}
CONFIG = dict(DEFAULTS, checks=[])

problems = []
not_checked = []
graced_pins = []


class ConfigError(Exception):
    """freshness.json cannot be trusted to say what this repository pins."""


class Unchecked(Exception):
    """A registry refused to answer: the pin is neither current nor behind."""


def behind(what, detail):
    problems.append(what)
    print("::error::%s: %s" % (what, detail))


def unchecked(what, detail):
    not_checked.append(what)
    print("::error::%s: %s" % (what, detail))


def graced(what, detail):
    graced_pins.append(what)
    print("::warning::%s: %s" % (what, detail))


def ok(what, detail):
    print("ok  %-52s %s" % (what, detail))


def get(url, gh=False):
    req = urllib.request.Request(url, headers={"User-Agent": "check-freshness"})
    if gh and TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def gh_json(path):
    return json.loads(get("https://api.github.com/" + path, gh=True))


# --- Versions -------------------------------------------------------------------

def semver(v):
    """A sort key for X.Y.Z or vX.Y.Z with an optional pre-release (-rc.3):
    a pre-release sorts below its own release and above the one before it,
    its numeric identifiers as numbers, as SemVer orders them. None for
    anything else. Kyverno 1.20's release candidates, pinned on a branch on
    8 November, made the old X.Y.Z-only key return None and the comparison
    raise, which ended the chart and tool checks at the first such pin."""
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$", str(v))
    if not m:
        return None
    major, minor, patch, pre = m.groups()
    if pre is None:
        return (int(major), int(minor), int(patch), (1,))
    return (int(major), int(minor), int(patch),
            (0,) + tuple((0, int(i), "") if i.isdigit() else (1, 0, i) for i in pre.split(".")))


def stable(v):
    k = semver(v)
    return k is not None and k[3] == (1,)


def newest(versions):
    """The newest release, never a pre-release: a release candidate is not
    something to move a pin to, though a pin may sit on one."""
    vs = [v for v in versions if stable(v)]
    return max(vs, key=semver) if vs else None


def verdict(pinned, latest, key=semver):
    """'behind', 'ok', or 'unordered' when the pin is not a version this
    check can order (reported, never raised, so the next pin is still read)."""
    if key(pinned) is None:
        return "unordered"
    return "behind" if key(latest) > key(pinned) else "ok"


# --- The release-age grace ------------------------------------------------------

def now():
    return datetime.datetime.now(UTC)


def parse_when(value):
    """When something was released, as an aware UTC datetime, from the forms
    upstream feeds use; None when it cannot be read. A bare date is read as
    the last moment of that day in UTC, so a grace counted from it never ends
    before the release is really three days old."""
    if not isinstance(value, str):
        return None
    s = value.strip().strip("'\"")
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", s)
    if m:
        try:
            return datetime.datetime(*map(int, m.groups()), tzinfo=UTC) + datetime.timedelta(days=1)
        except ValueError:
            return None
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})", s)
    if not m:
        return None
    try:
        t = datetime.datetime(*map(int, m.groups()[:6]), tzinfo=UTC)
    except ValueError:
        return None
    zone = m.group(7)
    if zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        t -= sign * datetime.timedelta(hours=int(zone[1:3]), minutes=int(zone[-2:]))
    return t


def when(t):
    return t.strftime("%Y-%m-%dT%H:%MZ")


def against(what, pinned, latest, versions, released, head="pinned %s, latest is %s", current=None,
            key=semver, release=stable):
    """Judge one pin against upstream.

    latest is upstream's newest release; versions every release it lists,
    so a pin behind more than one is judged by the newest it could already
    move to; released(v) says when v came out, or None. A pin behind only
    releases younger than the grace is a warning that names the moment the
    first of them turns three days old."""
    if key(latest) is None:
        behind(what, "upstream named %r as its newest, which is not a version this check can order; the pin %s is unchanged"
               % (latest, pinned))
        return
    v = verdict(pinned, latest, key)
    if v == "unordered":
        behind(what, "pinned %s, which this check cannot order; latest is %s" % (pinned, latest))
        return
    if v == "ok":
        ok(what, current or pinned)
        return
    text = head % (pinned, latest)
    newer = {x for x in versions if key(x) is not None and release(x) and key(pinned) < key(x) <= key(latest)}
    dates = {}
    for x in sorted(newer | {latest}, key=key, reverse=True):
        t = released(x)
        if t is None:
            behind(what, "%s; when %s was released could not be read, so it gets no release-age grace" % (text, x))
            return
        if now() - t >= GRACE:
            if x == latest:
                behind(what, "%s, released %s" % (text, when(t)))
            else:
                behind(what, "%s, released %s and still inside the %d-day release-age grace; %s, released %s, is past it"
                       % (text, when(dates[latest]), GRACE_DAYS, x, when(t)))
            return
        dates[x] = t
    graced(what, "%s, released %s: inside the %d-day release-age grace, a failure from %s"
           % (text, when(dates[latest]), GRACE_DAYS, when(min(dates.values()) + GRACE)))


def gh_releases(repo, pattern):
    """{version: published_at} for each release that is neither a draft nor a
    pre-release and whose tag matches pattern."""
    out = {}
    for r in gh_json("repos/%s/releases?per_page=100" % repo):
        if r.get("prerelease") or r.get("draft"):
            continue
        m = re.fullmatch(pattern, r["tag_name"])
        if m:
            out.setdefault(m.group(1), r.get("published_at"))
    return out


def against_releases(what, pinned, repo, pattern, none_found=None):
    rel = gh_releases(repo, pattern)
    latest = newest(rel)
    if latest is None:
        behind(what, none_found or "%s lists no release this check can read; the pin %s is unchanged" % (repo, pinned))
        return
    against(what, pinned, latest, rel, lambda v: parse_when(rel.get(v)))


def against_stable(what, pinned, project):
    """A pin on a stable channel follows the project's GitHub "latest", not its
    newest version. Only that one release is known to have been stable, so
    it alone is judged."""
    r = gh_json("repos/%s/releases/latest" % project)
    against(what, pinned, r["tag_name"], [r["tag_name"]], lambda v: parse_when(r.get("published_at")),
            head="pinned %%s, the stable release of %s is %%s" % project,
            current="%s (the stable release of %s)" % (pinned, project))


# --- Files ----------------------------------------------------------------------

def tracked():
    out = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True, check=True).stdout
    skip_dirs = tuple(CONFIG["skip_dirs"])
    return [p for p in out.splitlines()
            if p not in CONFIG["skip_files"] and not (skip_dirs and p.startswith(skip_dirs))]


def path_of(rel):
    return os.path.join(ROOT, rel)


def read(rel):
    with open(path_of(rel), encoding="utf-8") as f:
        return f.read()


def yaml_module():
    import yaml
    return yaml


# --- Charts ---------------------------------------------------------------------

def index_entries(text, chart):
    """{version: created} for one chart in a Helm repository index, read
    without a YAML parser. Only an entry's own keys count: a dependency's
    version under an entry is not a release of the chart."""
    out, inside, dash, cur = {}, False, None, None

    def flush():
        if cur and cur.get("version"):
            out.setdefault(cur["version"], cur.get("created"))

    for line in text.splitlines():
        m = re.match(r"^  (\S+):\s*$", line)
        if m:
            flush()
            cur, dash, inside = None, None, m.group(1) == chart
            continue
        if re.match(r"^\S", line):
            flush()
            cur, inside = None, False
            continue
        if not inside:
            continue
        d = re.match(r"^( *)- (.*)$", line)
        if d and (dash is None or len(d.group(1)) == dash):
            flush()
            dash, cur = len(d.group(1)), {}
            line = " " * (dash + 2) + d.group(2)
        if cur is not None:
            kv = re.match(r"^ {%d}(version|created):\s*(.*?)\s*$" % (dash + 2), line)
            if kv:
                cur[kv.group(1)] = kv.group(2).strip("'\"")
    flush()
    return out


indexes = {}


def chart_index(repo):
    if repo not in indexes:
        indexes[repo] = get(repo.rstrip("/") + "/index.yaml").decode("utf-8", "replace")
    return indexes[repo]


def against_index(what, pinned, repo, chart):
    entries = index_entries(chart_index(repo), chart)
    latest = newest(entries)
    if latest is None:
        behind(what, "%s lists no release of it; the pin %s is unchanged" % (repo, pinned))
        return
    against(what, pinned, latest, entries, lambda v: parse_when(entries.get(v)))


def check_charts():
    for path in sorted(p for p in tracked() if p.startswith("scripts/") and p.endswith(".sh")):
        text = read(path)
        joined = re.sub(r"\\\n\s*", " ", text)
        for chart, repo, var in re.findall(
                r"helm upgrade --install \S+ (\S+) --repo (\S+)[^\n]*?--version \"?\$\{?(\w+)\}?\"?", joined):
            m = re.search(r"^%s=['\"]?([^'\"\s]+)" % re.escape(var), text, re.M)
            if not m:
                behind("chart %s" % chart, "%s names $%s and does not set it" % (path, var))
                continue
            what = "chart %s" % chart
            if chart in CONFIG["stable"]:
                against_stable(what, m.group(1), CONFIG["stable"][chart])
            else:
                against_index(what, m.group(1), repo, chart)


def check_charts_lock():
    for path in sorted(p for p in tracked() if p.endswith("charts.lock")):
        for line in read(path).splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            chart, pinned, repo = line.split()[:3]
            what = "chart %s (%s)" % (chart, path)
            if chart in CONFIG["stable"]:
                against_stable(what, pinned, CONFIG["stable"][chart])
            else:
                against_index(what, pinned, repo, chart)


def check_appset_charts():
    yaml = yaml_module()
    paths = sorted(glob.glob(path_of(CONFIG["appsets"])))
    if not paths:
        behind("charts", "no file matches %s, so no chart was checked" % CONFIG["appsets"])
        return
    oci = dict(OCI_RELEASES, **{k: tuple(v) for k, v in CONFIG["oci_charts"].items()})
    for path in paths:
        for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
            if not doc or doc.get("kind") != "ApplicationSet":
                continue
            for src in doc["spec"]["template"]["spec"].get("sources") or []:
                if not src.get("chart"):
                    continue
                chart, repo, pinned = src["chart"], src["repoURL"], str(src["targetRevision"])
                what = "chart %s" % chart
                if chart in CONFIG["stable"]:
                    against_stable(what, pinned, CONFIG["stable"][chart])
                elif repo.startswith("http"):
                    against_index(what, pinned, repo, chart)
                elif chart in oci:
                    against_releases(what, pinned, *oci[chart],
                                     none_found="could not find any release upstream; the pin %s is unchanged" % pinned)
                else:
                    behind(what, "an OCI chart with no known upstream; add it to oci_charts in freshness.json")


# --- Images ---------------------------------------------------------------------

THROTTLED = re.compile(r"\b429\b|toomanyrequests", re.I)
WAITS = (60, 120)  # before the second and the third try
throttled_hosts = {}


def image_registry(ref):
    """The registry host of an image reference, and what to call it."""
    first = ref.split("/", 1)[0]
    host = first if "/" in ref and ("." in first or ":" in first) else "docker.io"
    return host, ("ECR Public" if host == "public.ecr.aws" else host)


def last_line(text):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    return lines[-1][:300] if lines else "no message"


def imagetools(ref, raw=False):
    return subprocess.run(["docker", "buildx", "imagetools", "inspect"] + (["--raw"] if raw else []) + [ref],
                          capture_output=True, text=True)


def digest_of(ref):
    """The digest the tag resolves to now; None if it does not resolve.
    Raises Unchecked when the registry is still throttling after three tries,
    or already did earlier in this run."""
    host, name = image_registry(ref)
    if host in throttled_hosts:
        raise Unchecked("could not check: %s throttled earlier in this run (%s)" % (name, throttled_hosts[host]))
    throttled = None
    for attempt in range(3):
        if attempt and throttled:
            time.sleep(WAITS[attempt - 1])
        r = imagetools(ref)
        m = re.search(r"^Digest:\s+(sha256:[0-9a-f]{64})", r.stdout, re.M)
        if m:
            return m.group(1)
        out = r.stdout + r.stderr
        throttled = last_line(out) if THROTTLED.search(out) else None
    if throttled:
        throttled_hosts[host] = throttled
        raise Unchecked("could not check: %s throttled, three tries over %d seconds (%s)" % (name, sum(WAITS), throttled))
    return None


def platform_manifests(ref):
    """The digests of the per-platform manifests in the index a tag points to."""
    r = imagetools(ref, raw=True)
    try:
        return {m["digest"] for m in json.loads(r.stdout).get("manifests", [])}
    except (ValueError, AttributeError, KeyError, TypeError):
        return set()


def compare(what, ref):
    name, _, pinned = ref.partition("@")
    try:
        current = digest_of(name)
    except Unchecked as e:
        unchecked(what, str(e))
        return
    if current is None:
        behind(what, "%s did not resolve; the registry did not answer or the tag is gone" % name)
    elif current == pinned:
        ok(what, pinned[:19])
    elif pinned in platform_manifests(name):
        # Pinned to one platform's manifest on purpose (the flagship's GPU
        # images, its ADR 19): current while it is still in the index the
        # tag points to.
        ok(what, "%s, a platform manifest in %s" % (pinned[:19], current[:19]))
    else:
        behind(what, "pinned %s, %s now points at %s" % (pinned[:19], name, current[:19]))


def values_refs(text):
    """name:tag@sha256 for values that split an image into registry, repository
    (or repo, as Coder's chart calls it) and tag."""
    refs, seen = [], {}
    for line in text.splitlines():
        m = re.match(r"^(\s*)(registry|repository|repo|tag):\s*['\"]?([^'\"\s#]+)", line)
        if not m:
            continue
        indent, key, value = len(m.group(1)), m.group(2), m.group(3)
        key = "repository" if key == "repo" else key
        seen = {k: v for k, v in seen.items() if v[0] == indent}
        seen[key] = (indent, value)
        if key == "tag" and "@sha256:" in value and "repository" in seen:
            reg = seen.get("registry", (0, ""))[1]
            refs.append("%s%s:%s" % (reg + "/" if reg else "", seen["repository"][1], value))
    return refs


def yaml_refs(text):
    """name:tag@sha256 for values that split an image into registry,
    repository, tag and digest (or sha), read by walking the documents."""
    refs = set()

    def walk(n):
        if isinstance(n, dict):
            repo, tag = n.get("repository") or n.get("repo"), str(n.get("tag", ""))
            digest = n.get("digest") or (("sha256:" + n["sha"]) if n.get("sha") and not str(n["sha"]).startswith("sha256:")
                                         else n.get("sha"))
            reg = n.get("registry")
            if repo and tag and digest and "@" not in tag:
                refs.add("%s%s:%s@%s" % (reg + "/" if reg else "", repo, tag, digest))
            elif repo and "@sha256:" in tag:
                refs.add("%s%s:%s" % (reg + "/" if reg else "", repo, tag))
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    for doc in yaml_module().safe_load_all(text):
        walk(doc)
    return refs


def image_files():
    if CONFIG["image_paths"] is None:
        return tracked()
    found = set()
    for pattern in CONFIG["image_paths"]:
        found.update(os.path.relpath(p, ROOT) for p in glob.glob(path_of(pattern), recursive=True))
    skip_dirs = tuple(CONFIG["skip_dirs"])
    return sorted(p for p in found if p not in CONFIG["skip_files"] and not (skip_dirs and p.startswith(skip_dirs)))


def check_images():
    refs = set()
    suffixes = tuple(CONFIG["skip_suffixes"])
    for path in image_files():
        if path == "ci-images.pins" or (suffixes and path.endswith(suffixes)):
            continue
        try:
            text = read(path)
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        refs.update(REF.findall(text))
        if path.endswith((".yaml", ".yml")):
            refs.update(yaml_refs(text) if CONFIG["image_values"] == "yaml" else values_refs(text))
    for ref in sorted(refs):
        compare("image %s" % ref.partition("@")[0], ref)


def check_ci_images():
    if not os.path.isfile(path_of("ci-images.pins")):
        return  # reported once, by config_findings
    for line in read("ci-images.pins").splitlines():
        m = re.match(r"^([A-Z_]+)=(.+@sha256:[0-9a-f]{64})$", line.strip())
        if m:
            compare("ci image %s" % m.group(1), m.group(2))


def rendered_images(script, env, out, default_images):
    environ = dict(os.environ, RENDER_CHART_DEFAULT_IMAGES="1" if default_images else "0")
    r = subprocess.run([sys.executable, path_of(script), env, out], capture_output=True, text=True, env=environ)
    if r.returncode != 0:
        # The render script tries a throttled chart pull three times itself.
        if THROTTLED.search(r.stderr):
            raise Unchecked("could not check: the %s render was throttled pulling a chart (%s)" % (env, last_line(r.stderr)))
        raise RuntimeError("%s %s exited %d: %s" % (script, env, r.returncode, last_line(r.stderr)))
    refs = set()
    for f in glob.glob(os.path.join(out, "*.yaml")):
        refs.update(re.findall(r"image: \"?([\w.-]+(?:/[\w.-]+)+:[\w.-]+)(?:@sha256:[0-9a-f]{64})?",
                               open(f, encoding="utf-8").read()))
    return {r.rsplit(":", 1)[0]: r.rsplit(":", 1)[1] for r in refs}


def check_chart_images():
    import tempfile
    render = CONFIG["render"]
    with tempfile.TemporaryDirectory() as tmp:
        for env in render["envs"]:
            pinned = rendered_images(render["script"], env, os.path.join(tmp, env + "-pinned"), False)
            default = rendered_images(render["script"], env, os.path.join(tmp, env + "-default"), True)
            for repo, tag in sorted(default.items()):
                if repo in pinned and pinned[repo] != tag:
                    what = "chart image %s (%s)" % (repo, env)
                    # A pin newer than the chart's default is a deliberate patch
                    # (velero v1.18.4 over the chart's 1.18.2); only older is behind.
                    # A chart that defaults to "latest" names no version to be
                    # behind (kyverno's readiness-checker); the pin is the version.
                    if tag == "latest":
                        ok(what, "pinned %s; the chart's default is latest" % pinned[repo])
                    elif semver(pinned[repo]) and semver(tag) and semver(pinned[repo]) > semver(tag):
                        ok(what, "pinned %s, newer than the chart's %s" % (pinned[repo], tag))
                    else:
                        behind(what, "the pins say %s, the chart now defaults to %s" % (pinned[repo], tag))


# --- Tools and runtimes ---------------------------------------------------------

def kubectl_release(v):
    try:
        return parse_when(gh_json("repos/kubernetes/kubernetes/releases/tags/%s" % v).get("published_at"))
    except Exception:
        return None


def check_tools():
    seen = {}
    for lock in CONFIG["tool_locks"]:
        if not os.path.isfile(path_of(lock)):
            continue  # reported once, by config_findings
        for line in read(lock).splitlines():
            if line.strip() and not line.startswith("#"):
                name, version = line.split()[:2]
                seen[name] = version
    known = dict(TOOL_RELEASES, **{k: tuple(v) for k, v in CONFIG["tools"].items()})
    for name, pinned in sorted(seen.items()):
        what = "tool %s" % name
        if name == "kubectl":
            # kubectl follows the targeted Kubernetes minor, not the newest one.
            minor = ".".join(pinned.lstrip("v").split(".")[:2])
            latest = get("https://dl.k8s.io/release/stable-%s.txt" % minor).decode().strip()
            k = semver(pinned)
            patches = ["v%s.%d" % (minor, p) for p in range(k[2] + 1, semver(latest)[2] + 1)] if k and semver(latest) else []
            against(what, pinned, latest, patches, kubectl_release)
        elif name in CONFIG["stable"]:
            against_stable(what, pinned, CONFIG["stable"][name])
        elif name in known:
            against_releases(what, pinned, *known[name])
        else:
            behind(what, "no upstream is known for it; add it to tools in freshness.json")


def gvisor_key(v):
    return (int(v),) if re.fullmatch(r"\d{8}", str(v)) else None


def check_gvisor():
    if not os.path.isfile(path_of("gvisor.lock")):
        return  # reported once, by config_findings
    pinned = next((l.split()[0] for l in read("gvisor.lock").splitlines() if l.strip() and not l.startswith("#")), None)
    if pinned is None:
        behind("gvisor", "gvisor.lock names no release")
        return
    tags = gh_json("repos/google/gvisor/tags?per_page=20")
    days = [m.group(1) for t in tags for m in [re.fullmatch(r"release-(\d{8})\.\d+", t["name"])] if m]
    if not days:
        behind("gvisor", "google/gvisor has no release-YYYYMMDD.N tag among its newest; the pin %s is unchanged" % pinned)
        return
    latest = max(days)
    published = {}
    if latest > pinned:
        # A tag's day is when it was cut, not when it was released: release-
        # 20261109.0 was published on GitHub two days after its name.
        for r in gh_json("repos/google/gvisor/releases?per_page=100"):
            m = re.fullmatch(r"release-(\d{8})\.\d+", r.get("tag_name", ""))
            t = parse_when(r.get("published_at")) if m and not r.get("draft") else None
            if t and (m.group(1) not in published or t < published[m.group(1)]):
                published[m.group(1)] = t
    against("gvisor", pinned, latest, days, published.get, key=gvisor_key, release=lambda v: True)


def provider_release(source, data):
    def released(v):
        if v == data.get("version"):
            return parse_when(data.get("published_at"))
        try:
            return parse_when(json.loads(get("https://registry.terraform.io/v1/providers/%s/%s" % (source, v))).get("published_at"))
        except Exception:
            return None
    return released


def against_registry(what, source, pinned, verb):
    data = json.loads(get("https://registry.terraform.io/v1/providers/%s" % source))
    # The registry's "version" is the last one published, a pre-release
    # included: coder/coder 2.20.1-pre0, published on 17 November 2026, made a
    # pin on 2.20.0 a finding. A pre-release is not something to move a pin
    # to, so the newest stable version is the one compared, as everywhere else.
    versions = list(data.get("versions") or []) + ([data["version"]] if data.get("version") else [])
    latest = newest(versions)
    if latest is None:
        behind(what, "the registry lists no stable release of %s; the pin %s is unchanged" % (source, pinned))
        return
    against(what, pinned, latest, versions, provider_release(source, data),
            head=verb + " %s, latest is %s")


def check_providers():
    seen = set()
    for path in sorted(p for p in tracked() if p.endswith(".tf")):
        for source, pinned in re.findall(r'source\s+=\s+"([^"]+)"\s+version\s+=\s+"([^"]+)"', read(path)):
            if (source, pinned) in seen:
                continue
            seen.add((source, pinned))
            against_registry("provider %s" % source, source, pinned, "pinned")


def check_terraform_lock():
    locks = CONFIG["terraform_locks"]
    for lock in locks:
        for source, pinned in re.findall(r'provider "registry\.terraform\.io/([^"]+)" \{\s*version\s*=\s*"([^"]+)"', read(lock)):
            # With more than one lock file the same provider is locked in
            # each (the flagship's gke/ and gke/bootstrap/), so the line
            # names its file, as a charts.lock line does.
            what = "provider %s" % source if len(locks) == 1 else "provider %s (%s)" % (source, lock)
            against_registry(what, source, pinned, "locked")


def minor_key(v):
    return tuple(int(x) for x in v.split(".")) if re.fullmatch(r"\d+\.\d+", str(v)) else None


def check_kubernetes():
    files = CONFIG["kubernetes"]
    target = re.search(r"^KUBE_VERSION=(\d+\.\d+)", read(files["target"]), re.M).group(1)
    node = re.search(r"kindest/node:v(\d+\.\d+)\.\d+@", read(files["kind_node"])).group(1)
    tf = re.search(r'variable "kubernetes_version".*?default\s*=\s*"([\d.]+)"', read(files["terraform"]), re.S).group(1)
    for what, v in (("kind node image", node), ("terraform kubernetes_version", tf)):
        if v != target:
            behind(what, "is %s, the platform targets %s" % (v, target))
        else:
            ok(what, v)
    cycles = json.loads(get("https://endoflife.date/api/amazon-eks.json"))
    by_cycle = {c["cycle"]: c for c in cycles if minor_key(c.get("cycle"))}
    newest_minor = max(by_cycle, key=minor_key)
    against("kubernetes", target, newest_minor, by_cycle, lambda c: parse_when(by_cycle[c].get("releaseDate")),
            head="the platform targets %s, EKS offers %s", current="%s is EKS's newest" % target,
            key=minor_key, release=lambda c: True)
    ours = by_cycle.get(target)
    if ours and isinstance(ours.get("eol"), str):
        left = (datetime.date.fromisoformat(ours["eol"]) - now().date()).days
        if left < 90:
            behind("kubernetes %s support" % target, "standard support ends %s, in %d days" % (ours["eol"], left))


CHECKS = {name: globals()["check_" + name] for name in CHECK_NAMES}


# --- freshness.json -------------------------------------------------------------

def named_inputs(check):
    """The files a check reads by name, which must exist when it is listed."""
    return {
        "tools": CONFIG["tool_locks"],
        "ci_images": ["ci-images.pins"],
        "gvisor": ["gvisor.lock"],
        "terraform_lock": CONFIG["terraform_locks"],
        "chart_images": [CONFIG["render"]["script"]] if CONFIG["render"] else [],
        "kubernetes": [CONFIG["kubernetes"][k] for k in ("target", "kind_node", "terraform")] if CONFIG["kubernetes"] else [],
    }.get(check, [])


def load_config():
    path = path_of("freshness.json")
    if not os.path.exists(path):
        raise ConfigError("no freshness.json at the repository root, so this copy cannot know which checks the repository needs")
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except ValueError as e:
        raise ConfigError("freshness.json is not JSON: %s" % e)
    return validate_config(cfg)


def validate_config(cfg):
    """freshness.json as this check will use it, or ConfigError. Fleet
    conformance calls this too, so a repository hears about a bad
    freshness.json from the daily sweep, not only from its weekly run."""
    if not isinstance(cfg, dict):
        raise ConfigError("freshness.json is not an object")
    unknown = sorted(set(cfg) - set(DEFAULTS) - {"checks"})
    if unknown:
        raise ConfigError("freshness.json has key(s) this check does not know: %s; a misspelt key would switch a check off without a word"
                          % ", ".join(unknown))
    checks = cfg.get("checks")
    if not isinstance(checks, list) or not checks or not all(isinstance(c, str) for c in checks):
        raise ConfigError("freshness.json lists no checks")
    strange = [c for c in checks if c not in CHECKS]
    if strange or len(set(checks)) != len(checks):
        raise ConfigError("freshness.json checks %s: each must be one of %s, listed once" % (checks, ", ".join(CHECK_NAMES)))
    shapes = {"skip_files": list, "skip_dirs": list, "skip_suffixes": list, "image_paths": (list, type(None)),
              "image_values": str, "tool_locks": list, "tools": dict, "stable": dict, "appsets": (str, type(None)),
              "oci_charts": dict, "render": (dict, type(None)), "kubernetes": (dict, type(None)), "terraform_locks": list}
    for key, shape in shapes.items():
        if key in cfg and not isinstance(cfg[key], shape):
            raise ConfigError("freshness.json %s has the wrong shape" % key)
    if cfg.get("image_values", "lines") not in ("lines", "yaml"):
        raise ConfigError("freshness.json image_values must be \"lines\" or \"yaml\"")
    for key in ("tools", "oci_charts"):
        if not all(isinstance(v, list) and len(v) == 2 for v in cfg.get(key, {}).values()):
            raise ConfigError("freshness.json %s maps each name to [owner/repo, tag pattern]" % key)
    needs = {"appset_charts": "appsets", "chart_images": "render", "kubernetes": "kubernetes", "terraform_lock": "terraform_locks"}
    for check, key in needs.items():
        if check in checks and not cfg.get(key):
            raise ConfigError("freshness.json lists %s without %s" % (check, key))
    if cfg.get("render") and not (isinstance(cfg["render"].get("script"), str) and isinstance(cfg["render"].get("envs"), list)):
        raise ConfigError("freshness.json render needs a script and its envs")
    if cfg.get("kubernetes") and not all(isinstance(cfg["kubernetes"].get(k), str) for k in ("target", "kind_node", "terraform")):
        raise ConfigError("freshness.json kubernetes needs target, kind_node and terraform")
    merged = dict(DEFAULTS)
    merged.update(cfg)
    return merged


def config_findings():
    """A listed check whose input is missing, and pins no listed check reads."""
    checks = CONFIG["checks"]
    for check in checks:
        for f in named_inputs(check):
            if not os.path.isfile(path_of(f)):
                behind("freshness.json", "lists the %s check, and %s, which it reads, is missing" % (check, f))
    unlisted = {"tools": [f for f in CONFIG["tool_locks"] if os.path.isfile(path_of(f))],
                "ci_images": [f for f in ("ci-images.pins",) if os.path.isfile(path_of(f))],
                "gvisor": [f for f in ("gvisor.lock",) if os.path.isfile(path_of(f))],
                "charts_lock": [p for p in tracked() if p.endswith("charts.lock")]}
    for check, files in unlisted.items():
        if files and check not in checks:
            behind("freshness.json", "%s holds pins, and the %s check that reads it is not listed" % (files[0], check))


# --- The run --------------------------------------------------------------------

def summary():
    grace = ("; %d newer release(s) inside the %d-day release-age grace" % (len(graced_pins), GRACE_DAYS)
             if graced_pins else "")
    if not_checked:
        print("%d pin(s) could not be checked, so how many are behind is not known; "
              "%d behind among the rest%s" % (len(not_checked), len(problems), grace))
    else:
        print("%d pin(s) behind upstream%s" % (len(problems), grace))
    return 1 if problems or not_checked else 0


def main(checks=None):
    if checks is None:
        try:
            CONFIG.update(load_config())
            config_findings()
        except ConfigError as e:
            behind("freshness.json", str(e))
            return summary()
        except Exception as e:
            behind("freshness.json", "could not be read against the repository: %s" % e)
            return summary()
        checks = [CHECKS[name] for name in CONFIG["checks"]]
    for check in checks:
        try:
            check()
        except Unchecked as e:
            unchecked(check.__name__, str(e))
        except Exception as e:  # one unreachable upstream must not hide the others
            behind(check.__name__, "could not complete: %s" % e)
    return summary()


def reset():
    del problems[:], not_checked[:], graced_pins[:]
    throttled_hosts.clear()


def selftest():
    """A registry that answers 429 every time must fail the run as not
    checked, after three tries, and stop asking that host; one that answers
    must still be checked. Versions with release candidates must order.
    Releases must land on the right side of the grace, and a registry that
    names a pre-release as its last version must not count it."""
    global imagetools, WAITS, now, get
    import contextlib
    import io
    calls = []

    def fake(ref, raw=False):
        calls.append(ref)
        if ref.startswith("public.ecr.aws/"):
            return subprocess.CompletedProcess([], 1, "", "ERROR: unexpected status from HEAD request to "
                                               "https://public.ecr.aws/v2/x/manifests/1: 429 Too Many Requests\n"
                                               "toomanyrequests: Data limit exceeded\n")
        return subprocess.CompletedProcess([], 0, "Name: %s\nDigest: sha256:%s\n" % (ref, "a" * 64), "")

    saved = imagetools, WAITS, now
    imagetools, WAITS = fake, (0, 0)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(checks=(lambda: [digest_of("public.ecr.aws/eks/a:1"), None],
                            lambda: [digest_of("public.ecr.aws/docker/library/b:2"), None],
                            lambda: digest_of("quay.io/c/d:3") == "sha256:" + "a" * 64 or behind("control", "an answering registry was not read")))
    text = out.getvalue()
    # What the simulated run printed is shown indented, never as it was: a
    # line that starts with ::error:: is a workflow command, and the two this
    # part provokes on purpose would mark a passing selftest's run with errors.
    shown = "".join("  | %s\n" % line for line in text.splitlines())
    throttle_ok = (code == 1 and calls.count("public.ecr.aws/eks/a:1") == 3 and "public.ecr.aws/docker/library/b:2" not in calls
                   and "quay.io/c/d:3" in calls and len(not_checked) == 2 and not problems
                   and "could not check: ECR Public throttled" in text and "0 pin(s) behind upstream" not in text)
    print(shown, end="")
    print("selftest: %s (exit %d, %d tries on the throttled host, %d not checked, %d behind)"
          % ("ok" if throttle_ok else "FAILED", code, len([c for c in calls if c.startswith("public.ecr.aws/")]),
             len(not_checked), len(problems)))
    reset()

    # Versions: a release candidate orders between the release before it and
    # its own release, and a pin on one is compared, not crashed on.
    order = ["3.9.2", "3.10.0-alpha.1", "3.10.0-beta.2", "3.10.0-rc.3", "3.10.0-rc.10", "3.10.0", "v3.10.1"]
    cases = [("3.10.0-rc.3", "3.9.2", "ok"),         # a candidate pinned ahead of the newest release
             ("3.10.0-rc.3", "3.10.0", "behind"),    # its release is out
             ("v1.37.1", "v1.37.2", "behind"), ("v1.37.2", "v1.37.2", "ok"),
             ("latest", "1.0.0", "unordered")]
    try:
        keys = [semver(v) for v in order]
        ordered = all(a is not None and b is not None and a < b for a, b in zip(keys, keys[1:]))
        got = [verdict(p, l) for p, l, _ in cases]
        newest_ok = newest(["3.9.2", "3.10.0-rc.3", "nightly"]) == "3.9.2"
        versions_ok = ordered and got == [w for _, _, w in cases] and newest_ok
        detail = "%d in order: %s, verdicts %s, newest of a list with a candidate %s" % (
            len(order), "yes" if ordered else "no", got, newest(["3.9.2", "3.10.0-rc.3", "nightly"]))
    except Exception as e:  # the old comparison raised here
        versions_ok, detail = False, "%s: %s" % (type(e).__name__, e)
    print("selftest versions: %s (%s)" % ("ok" if versions_ok else "FAILED", detail))

    # The grace: what each release's age makes of a pin behind it.
    t0 = datetime.datetime(2026, 11, 15, 12, 0, tzinfo=UTC)
    now = lambda: t0  # noqa: E731
    ago = lambda days, hours=0: t0 - datetime.timedelta(days=days, hours=hours)  # noqa: E731
    grace_cases = [
        # name, pinned, {version: released}, expected, text the line must carry
        ("a day old", "v1.0.0", {"v1.0.1": ago(1)}, "warning", "a failure from 2026-11-17T12:00Z"),
        ("four days old", "v1.0.0", {"v1.0.1": ago(4)}, "error", "released 2026-11-11T12:00Z"),
        ("exactly three days", "v1.0.0", {"v1.0.1": ago(3)}, "error", "released 2026-11-12T12:00Z"),
        ("just under three days", "v1.0.0", {"v1.0.1": ago(2, 23)}, "warning", "a failure from 2026-11-15T13:00Z"),
        ("date unreadable", "v1.0.0", {"v1.0.1": None}, "error", "could not be read"),
        ("young newest over an old one", "v1.0.0", {"v1.0.1": ago(5), "v1.0.2": ago(1)}, "error", "v1.0.1, released 2026-11-10T12:00Z, is past it"),
        ("two young", "v1.0.0", {"v1.0.1": ago(2), "v1.0.2": ago(1)}, "warning", "a failure from 2026-11-16T12:00Z"),
        ("young newest over an unreadable one", "v1.0.0", {"v1.0.1": None, "v1.0.2": ago(1)}, "error", "when v1.0.1 was released"),
        ("current", "v1.0.2", {"v1.0.1": ago(9), "v1.0.2": ago(1)}, "ok", "v1.0.2"),
        ("a candidate's release, young", "v1.1.0-rc.1", {"v1.1.0": ago(1)}, "warning", "a failure from"),
    ]
    failures = []
    for name, pinned, rel, want, carries in grace_cases:
        reset()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            against("tool t", pinned, newest(rel), rel, rel.get)
        line = out.getvalue()
        got = "error" if problems else "warning" if graced_pins else "ok" if line.startswith("ok") else "nothing"
        if got != want or carries not in line:
            failures.append("%s: wanted %s carrying %r, got %s: %s" % (name, want, carries, got, line.strip()))
    reset()
    dates_ok = (parse_when("2026-11-13T04:53:21Z") == datetime.datetime(2026, 11, 13, 4, 53, 21, tzinfo=UTC)
                and parse_when("2026-11-13T04:53:21.123456789-05:00") == datetime.datetime(2026, 11, 13, 9, 53, 21, tzinfo=UTC)
                and parse_when("2026-10-01") == datetime.datetime(2026, 10, 2, tzinfo=UTC)
                and parse_when("") is None and parse_when(None) is None and parse_when("13 Nov 2026") is None
                and parse_when("2026-11-13T04:53:21") is None)
    if not dates_ok:
        failures.append("release dates are not read as they should be")
    entries = index_entries("apiVersion: v1\nentries:\n  a:\n  - created: \"2026-11-01T00:00:00Z\"\n    dependencies:\n"
                            "    - name: b\n      version: 9.9.9\n    version: 1.2.3\n  - version: '1.2.4'\n"
                            "    created: 2026-11-14T00:00:00.5+00:00\n  c:\n  - version: 5.0.0\ngenerated: x\n", "a")
    if entries != {"1.2.3": "2026-11-01T00:00:00Z", "1.2.4": "2026-11-14T00:00:00.5+00:00"}:
        failures.append("a chart index was read as %s" % entries)

    # The Terraform registry names the last version published, a pre-release
    # included (coder/coder 2.20.1-pre0, 17 November 2026); the pin is judged
    # against the newest stable one.
    base = "https://registry.terraform.io/v1/providers/coder/coder"
    registry = {}
    saved_get = get
    get = lambda url, gh=False: json.dumps(registry[url]).encode()  # noqa: E731
    registry_cases = [
        # name, the registry's answer, per-version answers, expected, text the line must carry
        ("a pre-release published last", {"version": "2.20.1-pre0", "versions": ["2.19.0", "2.20.0", "2.20.1-pre0"],
                                          "published_at": "2026-11-14T12:00:00Z"}, {}, "ok", "2.20.0"),
        ("a stable release under a later pre-release", {"version": "2.21.0-pre0", "versions": ["2.20.0", "2.20.1", "2.21.0-pre0"],
                                                         "published_at": "2026-11-14T12:00:00Z"},
         {base + "/2.20.1": {"published_at": "2026-11-10T12:00:00Z"}}, "error", "latest is 2.20.1"),
        ("nothing stable at all", {"version": "3.0.0-pre0", "versions": ["3.0.0-pre0"]}, {}, "error", "no stable release"),
    ]
    for name, data, more, want, carries in registry_cases:
        reset()
        registry.clear()
        registry[base] = data
        registry.update(more)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            against_registry("provider coder/coder", "coder/coder", "2.20.0", "pinned")
        line = out.getvalue()
        got = "error" if problems else "warning" if graced_pins else "ok" if line.startswith("ok") else "nothing"
        if got != want or carries not in line:
            failures.append("registry, %s: wanted %s carrying %r, got %s: %s" % (name, want, carries, got, line.strip()))
    get = saved_get
    reset()
    grace_ok = not failures
    print("selftest grace: %s (%d cases%s)" % ("ok" if grace_ok else "FAILED", len(grace_cases) + len(registry_cases),
                                               "".join("\n  " + f for f in failures)))
    imagetools, WAITS, now = saved
    return 0 if throttle_ok and versions_ok and grace_ok else 1


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["selftest"] else main())
