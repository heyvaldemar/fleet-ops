#!/usr/bin/env bash
# templates/check-freshness.py, the freshness check every Kubernetes repository
# carries a copy of, shown each case it has to tell apart. No network: every
# upstream answers from the stubs below, and the clock is fixed at
# 2026-11-15T06:00Z.
#
# The grace is what this file is for. A release younger than three days is a
# ::warning:: that names the moment it becomes a failure, three days or older
# is an ::error::, and a release whose date cannot be read is an ::error::.
# Each of the three is shown on every kind of date the check reads: a GitHub
# release, a chart index's `created`, the Terraform registry, Coder's stable
# release, a Kubernetes patch, a gVisor release, an EKS version.
#
# Then three proofs that the cases test something:
#   - the copy from before the canon (tests/fixtures/check-freshness/
#     before-canon.py, the base copy every focused repository carried until
#     15 November 2026) fails the young-release cases: it failed on any newer
#     release, which is the bug;
#   - mutations of the canon (no grace, a thirty-day grace, an unreadable date
#     taken as young, only the newest release looked at, and more) are each
#     caught;
#   - the canon's own selftest passes.
#
#   ./tests/test-check-freshness.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
CANON="$ROOT/templates/check-freshness.py"
BEFORE="$ROOT/tests/fixtures/check-freshness/before-canon.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: PyYAML is needed for the cases that read YAML (appset_charts, image_values yaml)"; exit 1; }

# cases <script> <work dir> [case ...]: one line per case, "PASS name" or
# "FAIL name — why"; exit 0 only when every case asked for passed.
cases() {
  python3 - "$@" <<'PY'
import contextlib, importlib.util, io, json, os, subprocess, sys, types, urllib.error

script, work = sys.argv[1], sys.argv[2]
only = set(sys.argv[3:])
# LOOSE=1: judge the exit code and which pin got which kind of line, not the
# wording, for a copy that words its lines differently (the one from before
# the canon prints no release dates).
LOOSE = os.environ.get("LOOSE") == "1"
NOW = "2026-11-15T06:00:00Z"
YOUNG = "2026-11-14T10:00:00Z"   # 20 hours old: a failure from 2026-11-17T10:00Z
OLD = "2026-11-10T10:00:00Z"     # five days old
D = lambda c: "sha256:" + c * 64  # noqa: E731


def rel(tag, published, pre=False):
    return {"tag_name": tag, "published_at": published, "prerelease": pre, "draft": False}


def index(chart, entries):
    out = ["apiVersion: v1", "entries:", "  %s:" % chart]
    # The entry's own version before its dependencies, as an index may order
    # them: only the indent tells the two apart.
    for version, created in entries:
        out += ["  - apiVersion: v2"] + (['    created: "%s"' % created] if created else []) + [
                "    version: %s" % version, "    dependencies:", "    - name: sub", "      version: 99.0.0"]
    return "\n".join(out + ['generated: "2026-11-15T00:00:00Z"']) + "\n"


def case(name, files, config, net=None, images=None, raw=None):
    return {"name": name, "files": files, "config": config, "net": net or {}, "images": images or {}, "raw": raw or {}}


helm = lambda published: {"https://api.github.com/repos/helm/helm/releases?per_page=100":  # noqa: E731
                          [rel("v4.3.2", published), rel("v4.3.1", "2026-10-01T00:00:00Z"), rel("v4.4.0-rc.1", YOUNG, pre=True)]}
tools = {"tools.lock": "# tool version sha256\nhelm v4.3.1 " + "a" * 64 + "\n"}
T = {"checks": ["tools"]}
C = {"checks": ["charts_lock"]}
chart_lock = {"charts.lock": "kyverno 3.9.2 https://charts.example.test " + "b" * 64 + "\n"}
IDX = "https://charts.example.test/index.yaml"
tf = {"main.tf": 'terraform {\n  required_providers {\n    aws = {\n      source  = "hashicorp/aws"\n      version = "6.72.0"\n    }\n  }\n}\n'}
REG = "https://registry.terraform.io/v1/providers/hashicorp/aws"
coder = lambda published: {"https://api.github.com/repos/coder/coder/releases/latest": rel("v2.38.7", published),  # noqa: E731
                           "https://api.github.com/repos/coder/coder/releases?per_page=100": [rel("v2.40.0", OLD)]}
gv_lock = {"gvisor.lock": "# release arch sha512\n20261012 x86_64 " + "c" * 128 + "\n"}
gv_tags = {"https://api.github.com/repos/google/gvisor/tags?per_page=20": [{"name": "release-20261113.0"}, {"name": "release-20261012.0"}]}
eks_files = {"scripts/validate.sh": "KUBE_VERSION=1.36.0\n", "kind/cluster.yaml": "image: kindest/node:v1.36.2@" + D("d") + "\n",
             "terraform/variables.tf": 'variable "kubernetes_version" {\n  default = "1.36"\n}\n'}
EKS = {"checks": ["kubernetes"], "kubernetes": {"target": "scripts/validate.sh", "kind_node": "kind/cluster.yaml", "terraform": "terraform/variables.tf"}}
eol = lambda newest_release, eol36="2027-08-02": {"https://endoflife.date/api/amazon-eks.json": [  # noqa: E731
    {"cycle": "1.37", "releaseDate": newest_release, "eol": "2027-12-01"}, {"cycle": "1.36", "releaseDate": "2026-06-02", "eol": eol36}]}
lockfile = {"terraform/.terraform.lock.hcl": 'provider "registry.terraform.io/hashicorp/aws" {\n  version     = "6.72.0"\n  hashes = []\n}\n'}
appset = {"platform/appsets/a.yaml": "apiVersion: argoproj.io/v1alpha1\nkind: ApplicationSet\nspec:\n  template:\n    spec:\n      sources:\n"
          "      - chart: kyverno\n        repoURL: https://charts.example.test\n        targetRevision: 3.9.2\n"
          "      - chart: gateway-helm\n        repoURL: docker.io/envoyproxy\n        targetRevision: v1.6.0\n"}
APPSET = {"checks": ["appset_charts"], "appsets": "platform/appsets/*.yaml"}
envoy = lambda published: {"https://api.github.com/repos/envoyproxy/gateway/releases?per_page=100": [rel("v1.6.1", published), rel("v1.6.0", OLD)]}  # noqa: E731
img_files = {"manifests/app.yaml": "image: ghcr.io/x/app:1.0@" + D("1") + "\n"}
I = {"checks": ["images"]}

CASES = [
    # The three grace cases, on a GitHub release.
    case("tool, released 20 hours ago: a warning naming 2026-11-17T10:00Z", tools, T, helm(YOUNG)),
    case("tool, released five days ago: an error", tools, T, helm(OLD)),
    case("tool, release date unreadable: an error", tools, T, helm(None)),
    case("tool, released exactly three days ago: an error", tools, T, helm("2026-11-12T06:00:00Z")),
    case("tool, young newest over a release past the grace: an error naming the older one", tools, T,
         {"https://api.github.com/repos/helm/helm/releases?per_page=100":
          [rel("v4.3.3", YOUNG), rel("v4.3.2", OLD), rel("v4.3.1", "2026-10-01T00:00:00Z")]}),
    case("tool, current: ok", {"tools.lock": "helm v4.3.2 x\n"}, T, helm(OLD)),
    case("tool, a release candidate pinned, its release five days old: an error", {"tools.lock": "helm v4.3.2-rc.1 x\n"}, T, helm(OLD)),
    case("tool, no release upstream at all: an error", tools, T, {"https://api.github.com/repos/helm/helm/releases?per_page=100": []}),
    case("tool, unknown upstream: an error", {"tools.lock": "mystery v1.0.0 x\n"}, T),
    case("tool, extra tool from freshness.json, young: a warning", {"tools.lock": "thing 1.0.0 x\n"},
         {"checks": ["tools"], "tools": {"thing": ["example/thing", r"(\d+\.\d+\.\d+)"]}},
         {"https://api.github.com/repos/example/thing/releases?per_page=100": [rel("1.0.1", YOUNG)]}),
    case("tool, a second lock file from freshness.json: read", {"tools.lock": "", "tunnel.lock": "helm v4.3.1 x\n"},
         {"checks": ["tools"], "tool_locks": ["tools.lock", "tunnel.lock"]}, helm(OLD)),
    # Kubernetes patch: the date is the patch's GitHub release.
    case("kubectl, newest patch young: a warning", {"tools.lock": "kubectl v1.34.2 x\n"}, T,
         {"https://dl.k8s.io/release/stable-1.34.txt": "v1.34.3\n",
          "https://api.github.com/repos/kubernetes/kubernetes/releases/tags/v1.34.3": rel("v1.34.3", YOUNG)}),
    case("kubectl, newest patch's release missing: an error", {"tools.lock": "kubectl v1.34.2 x\n"}, T,
         {"https://dl.k8s.io/release/stable-1.34.txt": "v1.34.3\n"}),
    # A chart index's `created`.
    case("chart, created 20 hours ago: a warning", chart_lock, C, {IDX: index("kyverno", [("3.10.0", YOUNG), ("3.9.2", OLD)])}),
    case("chart, created five days ago: an error", chart_lock, C, {IDX: index("kyverno", [("3.10.0", OLD), ("3.9.2", OLD)])}),
    case("chart, no created: an error", chart_lock, C, {IDX: index("kyverno", [("3.10.0", None), ("3.9.2", OLD)])}),
    case("chart, a dependency's version is not a release of the chart: ok", chart_lock, C, {IDX: index("kyverno", [("3.9.2", OLD)])}),
    case("chart in a script's helm line, young: a warning",
         {"scripts/install.sh": 'KYVERNO_VERSION=3.9.2\nhelm upgrade --install kyverno kyverno --repo https://charts.example.test \\\n  --version "$KYVERNO_VERSION"\n'},
         {"checks": ["charts"]}, {IDX: index("kyverno", [("3.10.0", YOUNG), ("3.9.2", OLD)])}),
    # Coder's stable channel: GitHub's latest, not the newest mainline.
    case("stable channel, released 20 hours ago: a warning, mainline ignored",
         {"charts.lock": "coder 2.38.6 https://helm.coder.com/v2 x\n"}, {"checks": ["charts_lock"], "stable": {"coder": "coder/coder"}},
         dict(coder(YOUNG), **{"https://helm.coder.com/v2/index.yaml": index("coder", [("2.40.0", OLD)])})),
    case("stable channel, released five days ago: an error",
         {"tools.lock": "coder v2.38.6 x\n"}, {"checks": ["tools"], "stable": {"coder": "coder/coder"}}, coder(OLD)),
    # The Terraform registry.
    case("provider in a .tf file, young: a warning", tf, {"checks": ["providers"]},
         {REG: {"version": "6.73.0", "published_at": YOUNG, "versions": ["6.71.0", "6.72.0", "6.73.0"]}}),
    case("provider in a .tf file, old: an error", tf, {"checks": ["providers"]},
         {REG: {"version": "6.73.0", "published_at": OLD, "versions": ["6.72.0", "6.73.0"]}}),
    case("provider, young newest over an old one in between: an error", tf, {"checks": ["providers"]},
         {REG: {"version": "6.74.0", "published_at": YOUNG, "versions": ["6.72.0", "6.73.0", "6.74.0"]},
          REG + "/6.73.0": {"version": "6.73.0", "published_at": OLD}}),
    case("provider in a lock file, date unreadable: an error", lockfile, {"checks": ["terraform_lock"], "terraform_locks": ["terraform/.terraform.lock.hcl"]},
         {REG: {"version": "6.73.0", "versions": ["6.72.0", "6.73.0"]}}),
    case("provider in a lock file, young: a warning", lockfile, {"checks": ["terraform_lock"], "terraform_locks": ["terraform/.terraform.lock.hcl"]},
         {REG: {"version": "6.73.0", "published_at": YOUNG, "versions": ["6.72.0", "6.73.0"]}}),
    case("provider in two lock files: each line names its file",
         {"gke/.terraform.lock.hcl": 'provider "registry.terraform.io/hashicorp/google" {\n  version     = "8.8.1"\n}\n',
          "gke/bootstrap/.terraform.lock.hcl": 'provider "registry.terraform.io/hashicorp/google" {\n  version     = "8.11.0"\n}\n'},
         {"checks": ["terraform_lock"], "terraform_locks": ["gke/.terraform.lock.hcl", "gke/bootstrap/.terraform.lock.hcl"]},
         {"https://registry.terraform.io/v1/providers/hashicorp/google": {"version": "8.11.0", "published_at": OLD, "versions": ["8.8.1", "8.11.0"]}}),
    # gVisor: the tag names the day it was cut, GitHub says when it was released.
    case("gvisor, released 20 hours ago: a warning", gv_lock, {"checks": ["gvisor"]},
         dict(gv_tags, **{"https://api.github.com/repos/google/gvisor/releases?per_page=100": [rel("release-20261113.0", YOUNG), rel("release-20261012.0", OLD)]})),
    case("gvisor, tag with no release yet: an error", gv_lock, {"checks": ["gvisor"]},
         dict(gv_tags, **{"https://api.github.com/repos/google/gvisor/releases?per_page=100": [rel("release-20261012.0", OLD)]})),
    case("gvisor, released five days ago: an error", gv_lock, {"checks": ["gvisor"]},
         dict(gv_tags, **{"https://api.github.com/repos/google/gvisor/releases?per_page=100": [rel("release-20261113.0", OLD)]})),
    # EKS: endoflife.date gives a day, read as its last moment.
    case("EKS version released yesterday: a warning", eks_files, EKS, eol("2026-11-14")),
    case("EKS version released long ago: an error", eks_files, EKS, eol("2026-10-01")),
    case("EKS support ending within 90 days: an error, no grace", eks_files, EKS, eol("2026-11-14", eol36="2026-12-01")),
    # Charts through Argo CD, a Helm index and an OCI chart's releases.
    case("appset charts, both young: warnings", appset, APPSET,
         dict(envoy(YOUNG), **{IDX: index("kyverno", [("3.10.0", YOUNG), ("3.9.2", OLD)])})),
    case("appset charts, OCI chart old: an error", appset, APPSET,
         dict(envoy(OLD), **{IDX: index("kyverno", [("3.9.2", OLD)])})),
    # Images: a moved tag is not a release, so no grace.
    case("image, tag moved: an error, never a warning", img_files, I, images={"ghcr.io/x/app:1.0": D("2")}),
    case("image, current: ok", img_files, I, images={"ghcr.io/x/app:1.0": D("1")}),
    case("image, pinned to a platform manifest still in the index: ok", img_files, I,
         images={"ghcr.io/x/app:1.0": D("3")}, raw={"ghcr.io/x/app:1.0": {"manifests": [{"digest": D("1")}, {"digest": D("4")}]}}),
    case("image, split into repository/tag/digest, read with image_values yaml", {"values/images.yaml": "a:\n  image:\n    repository: ghcr.io/x/app\n    tag: \"1.0\"\n    digest: " + D("1") + "\n"},
         {"checks": ["images"], "image_paths": ["values/*.yaml"], "image_values": "yaml"}, images={"ghcr.io/x/app:1.0": D("2")}),
    case("image, split into repo/tag in values, as Coder's chart names it: read", {"helm/values.yaml": "coder:\n  image:\n    repo: ghcr.io/coder/coder\n    tag: \"v2.38.6@" + D("1") + "\"\n"},
         I, images={"ghcr.io/coder/coder:v2.38.6": D("2")}),
    case("image, under a skipped directory and in a .cast: not read", {"tests/e2e/plants/p.yaml": "image: ghcr.io/x/app:1.0@" + D("1") + "\n",
                                                                     "docs/demo/e2e.cast": "ghcr.io/x/app:1.0@" + D("1") + "\n"},
         {"checks": ["images"], "skip_dirs": ["tests/e2e/plants/"], "skip_suffixes": [".cast"]}, images={"ghcr.io/x/app:1.0": D("2")}),
    # freshness.json says what the repository pins, or the run fails.
    case("no freshness.json: an error", tools, None, helm(OLD)),
    case("freshness.json with a misspelt key: an error", tools, {"checks": ["tools"], "tool_lock": ["tools.lock"]}, helm(OLD)),
    case("a listed check whose lock file is missing: an error", {}, T),
    case("a pin file whose check is not listed: an error", dict(tools, **gv_lock), T, helm(OLD)),
]

EXPECT = {
    "tool, released 20 hours ago: a warning naming 2026-11-17T10:00Z": (0, [("warning", "tool helm", "a failure from 2026-11-17T10:00Z")]),
    "tool, released five days ago: an error": (1, [("error", "tool helm", "released 2026-11-10T10:00Z")]),
    "tool, release date unreadable: an error": (1, [("error", "tool helm", "could not be read")]),
    "tool, released exactly three days ago: an error": (1, [("error", "tool helm", "released 2026-11-12T06:00Z")]),
    "tool, young newest over a release past the grace: an error naming the older one": (1, [("error", "tool helm", "v4.3.2, released 2026-11-10T10:00Z, is past it")]),
    "tool, current: ok": (0, [("ok", "tool helm", "v4.3.2")]),
    "tool, a release candidate pinned, its release five days old: an error": (1, [("error", "tool helm", "latest is v4.3.2")]),
    "tool, no release upstream at all: an error": (1, [("error", "tool helm", "no release")]),
    "tool, unknown upstream: an error": (1, [("error", "tool mystery", "no upstream is known")]),
    "tool, extra tool from freshness.json, young: a warning": (0, [("warning", "tool thing", "a failure from 2026-11-17T10:00Z")]),
    "tool, a second lock file from freshness.json: read": (1, [("error", "tool helm", "latest is v4.3.2")]),
    "kubectl, newest patch young: a warning": (0, [("warning", "tool kubectl", "a failure from 2026-11-17T10:00Z")]),
    "kubectl, newest patch's release missing: an error": (1, [("error", "tool kubectl", "could not be read")]),
    "chart, created 20 hours ago: a warning": (0, [("warning", "chart kyverno (charts.lock)", "a failure from 2026-11-17T10:00Z")]),
    "chart, created five days ago: an error": (1, [("error", "chart kyverno (charts.lock)", "latest is 3.10.0")]),
    "chart, no created: an error": (1, [("error", "chart kyverno (charts.lock)", "could not be read")]),
    "chart, a dependency's version is not a release of the chart: ok": (0, [("ok", "chart kyverno (charts.lock)", "3.9.2")]),
    "chart in a script's helm line, young: a warning": (0, [("warning", "chart kyverno", "a failure from 2026-11-17T10:00Z")]),
    "stable channel, released 20 hours ago: a warning, mainline ignored": (0, [("warning", "chart coder (charts.lock)", "stable release of coder/coder is v2.38.7")]),
    "stable channel, released five days ago: an error": (1, [("error", "tool coder", "v2.38.7")]),
    "provider in a .tf file, young: a warning": (0, [("warning", "provider hashicorp/aws", "a failure from 2026-11-17T10:00Z")]),
    "provider in a .tf file, old: an error": (1, [("error", "provider hashicorp/aws", "latest is 6.73.0")]),
    "provider, young newest over an old one in between: an error": (1, [("error", "provider hashicorp/aws", "6.73.0, released 2026-11-10T10:00Z, is past it")]),
    "provider in a lock file, date unreadable: an error": (1, [("error", "provider hashicorp/aws", "could not be read")]),
    "provider in a lock file, young: a warning": (0, [("warning", "provider hashicorp/aws", "locked 6.72.0, latest is 6.73.0")]),
    "provider in two lock files: each line names its file": (1, [("error", "provider hashicorp/google (gke/.terraform.lock.hcl)", "locked 8.8.1"),
                                                                ("ok", "provider hashicorp/google (gke/bootstrap/.terraform.lock.hcl)", "8.11.0")]),
    "gvisor, released 20 hours ago: a warning": (0, [("warning", "gvisor", "a failure from 2026-11-17T10:00Z")]),
    "gvisor, tag with no release yet: an error": (1, [("error", "gvisor", "could not be read")]),
    "gvisor, released five days ago: an error": (1, [("error", "gvisor", "latest is 20261113")]),
    "EKS version released yesterday: a warning": (0, [("warning", "kubernetes", "a failure from 2026-11-18T00:00Z"), ("ok", "kind node image", "1.36")]),
    "EKS version released long ago: an error": (1, [("error", "kubernetes", "EKS offers 1.37")]),
    "EKS support ending within 90 days: an error, no grace": (1, [("error", "kubernetes 1.36 support", "standard support ends 2026-12-01"),
                                                                  ("warning", "kubernetes", "a failure from")]),
    "appset charts, both young: warnings": (0, [("warning", "chart kyverno", "a failure from"), ("warning", "chart gateway-helm", "a failure from")]),
    "appset charts, OCI chart old: an error": (1, [("error", "chart gateway-helm", "latest is v1.6.1"), ("ok", "chart kyverno", "3.9.2")]),
    "image, tag moved: an error, never a warning": (1, [("error", "image ghcr.io/x/app:1.0", "now points at")]),
    "image, current: ok": (0, [("ok", "image ghcr.io/x/app:1.0", "sha256:111111111111")]),
    "image, pinned to a platform manifest still in the index: ok": (0, [("ok", "image ghcr.io/x/app:1.0", "a platform manifest")]),
    "image, split into repository/tag/digest, read with image_values yaml": (1, [("error", "image ghcr.io/x/app:1.0", "now points at")]),
    "image, split into repo/tag in values, as Coder's chart names it: read": (1, [("error", "image ghcr.io/coder/coder:v2.38.6", "now points at")]),
    "image, under a skipped directory and in a .cast: not read": (0, []),
    "no freshness.json: an error": (1, [("error", "freshness.json", "no freshness.json")]),
    "freshness.json with a misspelt key: an error": (1, [("error", "freshness.json", "tool_lock")]),
    "a listed check whose lock file is missing: an error": (1, [("error", "freshness.json", "tools.lock, which it reads, is missing")]),
    "a pin file whose check is not listed: an error": (1, [("error", "freshness.json", "gvisor.lock holds pins")]),
}
assert set(EXPECT) == {c["name"] for c in CASES}, set(EXPECT) ^ {c["name"] for c in CASES}


def git(d, *args):
    subprocess.run(["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + list(args),
                   check=True, capture_output=True)


def run_case(n, c):
    d = os.path.join(work, "case%02d" % n)
    os.makedirs(d)
    for path, text in c["files"].items():
        os.makedirs(os.path.dirname(os.path.join(d, path)) or d, exist_ok=True)
        with open(os.path.join(d, path), "w") as f:
            f.write(text)
    if c["config"] is not None:
        with open(os.path.join(d, "freshness.json"), "w") as f:
            json.dump(c["config"], f)
    git(d, "init", "-q")
    git(d, "add", "-A")
    git(d, "commit", "-qm", "case", "--allow-empty")

    spec = importlib.util.spec_from_file_location("check_freshness_%d" % n, script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.ROOT = d

    def get(url, gh=False):
        if url not in c["net"]:
            raise urllib.error.HTTPError(url, 404, "Not Found (stub)", {}, None)
        v = c["net"][url]
        return (v if isinstance(v, str) else json.dumps(v)).encode()

    def run(args, **kw):
        if args[:4] == ["docker", "buildx", "imagetools", "inspect"]:
            ref = args[-1]
            if "--raw" in args:
                return subprocess.CompletedProcess(args, 0, json.dumps(c["raw"].get(ref, {"manifests": []})), "")
            if ref in c["images"]:
                return subprocess.CompletedProcess(args, 0, "Name: %s\nDigest: %s\n" % (ref, c["images"][ref]), "")
            return subprocess.CompletedProcess(args, 1, "", "ERROR: not found\n")
        return subprocess.run(args, **kw)

    import datetime
    mod.get = get
    mod.subprocess = types.SimpleNamespace(run=run, CompletedProcess=subprocess.CompletedProcess)
    if hasattr(mod, "now"):
        mod.now = lambda: datetime.datetime(2026, 11, 15, 6, 0, tzinfo=datetime.timezone.utc)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = mod.main()
    text = out.getvalue()
    lines = []
    for line in text.splitlines():
        for prefix, kind in (("::error::", "error"), ("::warning::", "warning")):
            if line.startswith(prefix):
                what, _, detail = line[len(prefix):].partition(": ")
                lines.append((kind, what, detail))
        if line.startswith("ok  "):
            lines.append(("ok", line[4:], line))
    want_code, wants = EXPECT[c["name"]]
    why = []
    if code != want_code:
        why.append("exit %s, wanted %s" % (code, want_code))
    for kind, what, carries in wants:
        if not any(k == kind and named(kind, w, what) and (LOOSE or carries in det) for k, w, det in lines):
            why.append("no %s for %r carrying %r" % (kind, what, carries))
    if not wants and any(k in ("error", "warning") for k, _, _ in lines):
        why.append("wanted no finding")
    if code == 0 and any(k == "error" for k, _, _ in lines):
        why.append("an ::error:: with exit 0")
    return why, text


def named(kind, field, what):
    """An ok line pads its pin's name to 52 characters, or follows a longer
    one with a single space; an annotation's name is exact."""
    if kind != "ok":
        return field == what
    if len(what) < 52:
        return field[:52].rstrip() == what
    return field.startswith(what + " ")


failed = 0
for n, c in enumerate(CASES):
    if only and c["name"] not in only:
        continue
    try:
        why, text = run_case(n, c)
    except Exception as e:
        why, text = ["raised %s: %s" % (type(e).__name__, e)], ""
    if why:
        failed += 1
        print("FAIL %s — %s" % (c["name"], "; ".join(why)))
        for line in text.splitlines()[:8]:
            print("       | " + line)
    else:
        print("PASS %s" % c["name"])
sys.exit(1 if failed else 0)
PY
}

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok    $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }

echo "== the canon on every case"
out="$(cases "$CANON" "$WORK/canon" 2>&1)"; code=$?
printf '%s\n' "$out" | sed 's/^/  /'
pass=$((pass + $(printf '%s\n' "$out" | grep -c '^PASS')))
fail=$((fail + $(printf '%s\n' "$out" | grep -c '^FAIL')))
[ "$code" -eq 0 ] || [ "$(printf '%s\n' "$out" | grep -c '^FAIL')" -gt 0 ] || no "the case runner exited $code with no failing case"

echo "== the copy from before the canon fails the young releases"
YOUNG_CASES=("tool, released 20 hours ago: a warning naming 2026-11-17T10:00Z"
             "chart, created 20 hours ago: a warning"
             "chart in a script's helm line, young: a warning"
             "kubectl, newest patch young: a warning"
             "gvisor, released 20 hours ago: a warning")
for c in "${YOUNG_CASES[@]}"; do
  if LOOSE=1 cases "$BEFORE" "$WORK/before-$RANDOM" "$c" >/dev/null 2>&1; then
    no "before the canon passed [$c]: the case does not catch the bug"
  else
    ok "before the canon fails [$c]"
  fi
done
# The old and unreadable cases describe what the old copy already did right.
for c in "tool, released five days ago: an error" "tool, release date unreadable: an error" "image, tag moved: an error, never a warning"; do
  if LOOSE=1 cases "$BEFORE" "$WORK/before-$RANDOM" "$c" >/dev/null 2>&1; then
    ok "before the canon already passes [$c]"
  else
    no "before the canon fails [$c], which it handled"
  fi
done

echo "== each mutation of the canon is caught"
mutant() {           # mutant <name> <python replace: old> <new> <case that must fail>
  local m="$WORK/mutant-$RANDOM.py"
  python3 - "$CANON" "$m" "$2" "$3" <<'PY' || { no "$1: the mutation did not apply"; return; }
import sys
s = open(sys.argv[1]).read()
assert sys.argv[3] in s, "the text to mutate is gone"
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))
PY
  if cases "$m" "$WORK/m-$RANDOM" "$4" >/dev/null 2>&1; then
    no "$1 survived [$4]"
  else
    ok "$1 is caught by [$4]"
  fi
}
mutant "no grace at all" 'graced(what, "%s, released' 'behind(what, "%s, released' "tool, released 20 hours ago: a warning naming 2026-11-17T10:00Z"
mutant "a thirty-day grace" 'GRACE_DAYS = 3' 'GRACE_DAYS = 30' "tool, released five days ago: an error"
mutant "an unreadable date taken as young" '        if t is None:
            behind(' '        if t is None and False:
            behind(' "tool, release date unreadable: an error"
mutant "only the newest release looked at" 'for x in sorted(newer | {latest}, key=key, reverse=True):' 'for x in [latest]:' \
  "tool, young newest over a release past the grace: an error naming the older one"
mutant "a bare date read as its first moment" 'tzinfo=UTC) + datetime.timedelta(days=1)' 'tzinfo=UTC)' "EKS version released yesterday: a warning"
mutant "a dependency's version read as the chart's" '(version|created):\s*(.*?)\s*$" % (dash + 2)' '(version|created):\s*(.*?)\s*$" % (dash + 2) if False else r"^\s+(version|created):\s*(.*?)\s*$"' \
  "chart, a dependency's version is not a release of the chart: ok"
mutant "a values repo: key not read" 'key = "repository" if key == "repo" else key' 'pass' \
  "image, split into repo/tag in values, as Coder's chart names it: read"
mutant "two lock files named alike" 'if len(locks) == 1 else' 'if True else' "provider in two lock files: each line names its file"
mutant "an unknown key in freshness.json allowed" 'unknown = sorted(set(cfg) - set(DEFAULTS) - {"checks"})' 'unknown = []' \
  "freshness.json with a misspelt key: an error"

echo "== the canon's own selftest"
if python3 "$CANON" selftest >"$WORK/selftest.out" 2>&1; then
  ok "selftest: $(grep -c ': ok' "$WORK/selftest.out") parts ok"
else
  no "selftest failed:"; sed 's/^/        /' "$WORK/selftest.out" | tail -8
fi
# A line that starts with :: is a workflow command: a passing selftest must
# not mark the run it is part of with errors.
if grep -q '^::' "$WORK/selftest.out"; then
  no "selftest prints a workflow command: $(grep -m1 '^::' "$WORK/selftest.out" | cut -c1-80)"
else
  ok "selftest prints no workflow command"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
