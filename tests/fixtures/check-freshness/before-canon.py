#!/usr/bin/env python3
"""Report every pin in this repository that upstream has moved past.

    GH_TOKEN=... scripts/check-freshness.py

Pins are what make a green build mean something, and they are also what goes
stale without a sound: Dependabot here watches the workflows' actions and
nothing else. This compares each pin with upstream and prints a GitHub error
annotation per pin that fell behind; it changes nothing. Fleet triage reads
the failed run and opens the bump, which then has to pass the same checks as
any other change. The same file runs in each focused reference architecture;
aws-eks-reference-platform has its own, which also renders its charts.

  charts     each `helm upgrade --install <release> <chart> --repo <url>
             --version "$VAR"` in scripts/*.sh, VAR set in the same file,
             and each line of a charts.lock (name version repository
             sha256), against the chart repository's index
  images     every image pinned as name:tag@sha256 in the tracked files,
             inline or as registry/repository/tag in values, against what
             the tag resolves to now: a moved tag is a rebuilt image nobody
             here has run. The planted-violation table is left out; its rows
             are deliberate edits
  tools      tools.lock against each tool's newest release; kubectl against
             the newest patch of the minor it targets
  ci images  ci-images.pins, as images
  gvisor     gvisor.lock, where there is one, against gVisor's newest release

Standard library only, so it runs on any runner without an install step.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
SKIP_FILES = {"tests/static/plants.tsv"}
TOOL_RELEASES = {
    "kind": ("kubernetes-sigs/kind", r"(v\d+\.\d+\.\d+)"),
    "oras": ("oras-project/oras", r"(v\d+\.\d+\.\d+)"),
    "cosign": ("sigstore/cosign", r"(v\d+\.\d+\.\d+)"),
    "helm": ("helm/helm", r"(v\d+\.\d+\.\d+)"),
    "kubeconform": ("yannh/kubeconform", r"(v\d+\.\d+\.\d+)"),
}
REF = re.compile(r"([\w.-]+(?:/[\w.-]+)+:[\w.-]+@sha256:[0-9a-f]{64})")

problems = []


def behind(what, detail):
    problems.append(what)
    print("::error::%s: %s" % (what, detail))


def ok(what, detail):
    print("ok  %-52s %s" % (what, detail))


def get(url, gh=False):
    req = urllib.request.Request(url, headers={"User-Agent": "check-freshness"})
    if gh and TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def semver(v):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)$", v or "")
    return tuple(int(x) for x in m.groups()) if m else None


def newest(versions):
    vs = [v for v in versions if semver(v)]
    return max(vs, key=semver) if vs else None


def gh_releases(repo, pattern):
    data = json.loads(get("https://api.github.com/repos/%s/releases?per_page=100" % repo, gh=True))
    return [m.group(1) for r in data if not r.get("prerelease") and not r.get("draft")
            for m in [re.fullmatch(pattern, r["tag_name"])] if m]


def tracked():
    out = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True, check=True).stdout
    return [p for p in out.splitlines() if p not in SKIP_FILES]


def index_versions(text, chart):
    """The versions a Helm repository index lists for one chart, read without a YAML parser."""
    versions, inside = [], False
    for line in text.splitlines():
        m = re.match(r"^  (\S+):\s*$", line)
        if m:
            inside = m.group(1) == chart
            continue
        if re.match(r"^\S", line):
            inside = False
        if inside:
            v = re.match(r"^\s+version:\s*['\"]?([^'\"\s]+)", line)
            if v:
                versions.append(v.group(1))
    return versions


def check_charts():
    indexes = {}
    for path in sorted(p for p in tracked() if p.startswith("scripts/") and p.endswith(".sh")):
        text = open(os.path.join(ROOT, path), encoding="utf-8").read()
        joined = re.sub(r"\\\n\s*", " ", text)
        for chart, repo, var in re.findall(
                r"helm upgrade --install \S+ (\S+) --repo (\S+)[^\n]*?--version \"?\$\{?(\w+)\}?\"?", joined):
            m = re.search(r"^%s=['\"]?([^'\"\s]+)" % re.escape(var), text, re.M)
            if not m:
                behind("chart %s" % chart, "%s names $%s and does not set it" % (path, var))
                continue
            pinned = m.group(1)
            if repo not in indexes:
                indexes[repo] = get(repo.rstrip("/") + "/index.yaml").decode("utf-8", "replace")
            latest = newest(index_versions(indexes[repo], chart))
            what = "chart %s" % chart
            if latest is None:
                behind(what, "%s lists no release of it; the pin %s is unchanged" % (repo, pinned))
            elif semver(latest) > semver(pinned):
                behind(what, "pinned %s, latest is %s" % (pinned, latest))
            else:
                ok(what, pinned)


def check_charts_lock():
    indexes = {}
    for path in sorted(p for p in tracked() if p.endswith("charts.lock")):
        for line in open(os.path.join(ROOT, path), encoding="utf-8"):
            if not line.strip() or line.startswith("#"):
                continue
            chart, pinned, repo = line.split()[:3]
            if repo not in indexes:
                indexes[repo] = get(repo.rstrip("/") + "/index.yaml").decode("utf-8", "replace")
            latest = newest(index_versions(indexes[repo], chart))
            what = "chart %s (%s)" % (chart, path)
            if latest is None:
                behind(what, "%s lists no release of it; the pin %s is unchanged" % (repo, pinned))
            elif semver(latest) > semver(pinned):
                behind(what, "pinned %s, latest is %s" % (pinned, latest))
            else:
                ok(what, pinned)


def values_refs(text):
    """name:tag@sha256 for values that split an image into registry, repository and tag."""
    refs, seen = [], {}
    for line in text.splitlines():
        m = re.match(r"^(\s*)(registry|repository|tag):\s*['\"]?([^'\"\s#]+)", line)
        if not m:
            continue
        indent, key, value = len(m.group(1)), m.group(2), m.group(3)
        seen = {k: v for k, v in seen.items() if v[0] == indent}
        seen[key] = (indent, value)
        if key == "tag" and "@sha256:" in value and "repository" in seen:
            reg = seen.get("registry", (0, ""))[1]
            refs.append("%s%s:%s" % (reg + "/" if reg else "", seen["repository"][1], value))
    return refs


def digest_of(ref):
    for _ in range(3):
        r = subprocess.run(["docker", "buildx", "imagetools", "inspect", ref], capture_output=True, text=True)
        m = re.search(r"^Digest:\s+(sha256:[0-9a-f]{64})", r.stdout, re.M)
        if m:
            return m.group(1)
    return None


def compare(what, ref):
    name, _, pinned = ref.partition("@")
    now = digest_of(name)
    if now is None:
        behind(what, "%s did not resolve; the registry did not answer or the tag is gone" % name)
    elif now != pinned:
        behind(what, "pinned %s, %s now points at %s" % (pinned[:19], name, now[:19]))
    else:
        ok(what, pinned[:19])


def check_images():
    refs = set()
    for path in tracked():
        if path == "ci-images.pins":
            continue
        try:
            text = open(os.path.join(ROOT, path), encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        refs.update(REF.findall(text))
        if path.endswith((".yaml", ".yml")):
            refs.update(values_refs(text))
    for ref in sorted(refs):
        compare("image %s" % ref.partition("@")[0], ref)


def check_ci_images():
    path = os.path.join(ROOT, "ci-images.pins")
    if not os.path.exists(path):
        return
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^([A-Z_]+)=(.+@sha256:[0-9a-f]{64})$", line.strip())
        if m:
            compare("ci image %s" % m.group(1), m.group(2))


def check_tools():
    path = os.path.join(ROOT, "tools.lock")
    if not os.path.exists(path):
        return
    seen = {}
    for line in open(path, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            name, version = line.split()[:2]
            seen[name] = version
    for name, pinned in sorted(seen.items()):
        if name == "kubectl":
            # kubectl follows the targeted Kubernetes minor, not the newest one.
            minor = ".".join(pinned.lstrip("v").split(".")[:2])
            latest = get("https://dl.k8s.io/release/stable-%s.txt" % minor).decode().strip()
        elif name in TOOL_RELEASES:
            latest = newest(gh_releases(*TOOL_RELEASES[name]))
        else:
            behind("tool %s" % name, "no upstream is known for it; add it to TOOL_RELEASES")
            continue
        if latest and semver(latest) > semver(pinned):
            behind("tool %s" % name, "pinned %s, latest is %s" % (pinned, latest))
        else:
            ok("tool %s" % name, pinned)


def check_gvisor():
    path = os.path.join(ROOT, "gvisor.lock")
    if not os.path.exists(path):
        return
    pinned = next((l.split()[0] for l in open(path, encoding="utf-8") if l.strip() and not l.startswith("#")), None)
    tags = json.loads(get("https://api.github.com/repos/google/gvisor/tags?per_page=20", gh=True))
    latest = max((m.group(1) for t in tags for m in [re.fullmatch(r"release-(\d{8})\.\d+", t["name"])] if m), default=None)
    if latest and pinned and latest > pinned:
        behind("gvisor", "pinned %s, latest is %s" % (pinned, latest))
    else:
        ok("gvisor", pinned or "?")


def main():
    for check in (check_charts, check_charts_lock, check_images, check_tools, check_ci_images, check_gvisor):
        try:
            check()
        except Exception as e:  # one unreachable upstream must not hide the others
            behind(check.__name__, "could not complete: %s" % e)
    print("%d pin(s) behind upstream" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
