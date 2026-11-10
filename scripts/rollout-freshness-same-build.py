#!/usr/bin/env python3
"""rollout-freshness-same-build.py [--push] [--file <workflow>] [repo ...]

An index pushed again over the same linux/amd64 build is not digest drift.

WHY. Every template's pin check resolves each pinned tag and compares the
digest it names now with the one in the compose file, and any difference was
reported as drift. A multi-platform tag names an index, and an index can be
pushed again over the very same images: a platform added or dropped, an
attestation rewritten. On 2026-11-09 alpine:3.22, nextcloud:35.0.2,
joomla:6.2.0 and wordpress:7.1.4 all moved that way, and fifteen templates
went red for images nobody had rebuilt. The triage has read two such digests
as one image since 2026-11-08 (`same_build` in fleet-triage.sh) and rightly
moves no pin for them, so nothing would ever have turned those checks green.

WHAT THIS CHANGES. In every run block that reports `digest drift` under the
plain comparison

    if [ "$pinned_digest" != "$current_digest" ]; then

the comparison also asks whether the linux/amd64 build under the two digests
moved, through two small functions inserted once at the top of that block.
The same build passes with a notice naming both digests; a new build fails
with the same error text as before, so nothing that reads it changes. A
digest whose build cannot be read is still drift: the check fails closed.
The CHANGELOG gets a line under [Unreleased]; it ships with the template's
next release and never causes one.

Nothing is written unless every drift line in the file is a shape this knows,
and nothing is pushed unless actionlint finds nothing new in the edited file.
Without --push the edits are made in a scratch clone and reported, not sent.

--file <workflow> transforms one local file in place and prints what it did
(exit 0 changed, 1 already right, 2 shape not recognised, 3 nothing to do):
the test suite uses it, and so can a person checking one template by hand.
"""
import io
import os
import re
import subprocess
import sys
import tempfile

OWNER = os.environ.get("FLEET_OWNER", "heyvaldemar")
AUTHOR = ["-c", "user.name=%s" % os.environ.get("GIT_AUTHOR", "Vladimir Mikhalev"),
          "-c", "user.email=%s" % os.environ.get(
              "GIT_EMAIL", "10498744+heyvaldemar@users.noreply.github.com")]
ACTIONLINT = "rhysd/actionlint:1.7.12"

RUN = re.compile(r"^(\s*)(?:-\s+)?run:\s*\|[-+]?\s*$")
COND = re.compile(r'^(\s*)(if|elif) \[ "\$pinned_digest" != "\$current_digest" \]; then\s*$')
DRIFT = re.compile(r"::error::.*digest drift")
HANDLED = re.compile(r'\b(new_build|drifted) "\$')
REF = re.compile(r'\bref="\$\{pin%%@\*\}"')
OTHER_SHELL = re.compile(r"^\s*shell:\s*(?!bash\b)\S", re.M)

HELPER = r'''# A NEW INDEX OVER THE SAME BUILD IS NOT DRIFT. A multi-platform tag
# names an index, and an index can be pushed again over the very same
# images: a platform added or dropped, an attestation rewritten. What
# runs here, and what CI proves, is the linux/amd64 build, so a moved
# digest is drift only when the linux/amd64 build under it moved too.
# The fleet's triage reads it the same way and moves no pin for a
# re-pushed index, so failing here would keep this check red for an
# image nobody rebuilt. A build that cannot be read is still drift.
amd64_build() { # amd64_build <name:tag@digest> -> its linux/amd64 build; nothing if unreadable
  local raw
  raw="$(docker buildx imagetools inspect --raw "$1" 2>/dev/null)" || return 0
  if jq -e '(.manifests? | type) == "array"' <<<"$raw" >/dev/null 2>&1; then
    jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64" and ((.platform.variant // "") == ""))][0].digest // empty' <<<"$raw" 2>/dev/null || true
  elif jq -e '.config? != null' <<<"$raw" >/dev/null 2>&1; then
    printf '%s\n' "${1##*@}"
  fi
}
new_build() { # new_build <name:tag> <pinned digest> <current digest> -> 0 unless both carry one linux/amd64 build
  local was now
  was="$(amd64_build "$1@$2")"; now="$(amd64_build "$1@$3")"
  if [ -n "$was" ] && [ "$was" = "$now" ]; then
    echo "::notice::$1 index moved from $2 to $3 over the same linux/amd64 build $was: the image did not change and the pin stays"
    return 1
  fi
  return 0
}'''.split("\n")

CHANGELOG_LINE = (
    "- **An index pushed again over the same build is no longer reported as drift.** "
    "The daily pin check compared each pin with the digest the tag's index has now and "
    "failed on any difference, so a publisher re-pushing the index over the very same "
    "images (a platform added, an attestation rewritten) turned it red for an image nobody "
    "rebuilt, and no pin would ever move to turn it green. It now also compares the "
    "linux/amd64 build under both digests, the one CI runs and proves: the same build "
    "passes with a notice naming both digests, a new build fails as drift exactly as "
    "before, and a build that cannot be read still fails.")

COMMIT = """fix(ci): an index pushed again over the same build is not digest drift

The pin check compared each pinned digest with the digest the tag's index
names now and failed on any difference. An index can be pushed again over
the very same images, a platform added or an attestation rewritten, and
the check then went red for an image nobody rebuilt; nothing would move
the pin to turn it green.

It now also compares the linux/amd64 build under both digests, the one CI
runs and proves. The same build passes with a notice naming both digests.
A new build fails with the same drift error as before, and a build that
cannot be read still fails."""


def transform(text):
    """-> (new text, sites changed, why-refused or None)."""
    if OTHER_SHELL.search(text):
        return text, 0, "a step declares a shell other than bash"
    lines = text.split("\n")
    out, i, sites = [], 0, 0
    while i < len(lines):
        m = RUN.match(lines[i])
        out.append(lines[i])
        if not m:
            i += 1
            continue
        key = len(m.group(1)) + (2 if lines[i].lstrip().startswith("- ") else 0)
        j = i + 1
        while j < len(lines) and (lines[j].strip() == "" or len(lines[j]) - len(lines[j].lstrip()) > key):
            j += 1
        body = lines[i + 1:j]
        while body and body[-1].strip() == "":       # trailing blanks belong to what follows
            body.pop()
            j -= 1
        hits = [k for k, l in enumerate(body) if k and DRIFT.search(l) and COND.match(body[k - 1])]
        if hits:
            if any(HANDLED.search(l) for l in body):
                return text, 0, "a block that is half converted"
            if not any(REF.search(l) for l in body[:hits[0]]):
                return text, 0, "a drift check whose image reference is not $ref"
            for k in hits:
                c = COND.match(body[k - 1])
                body[k - 1] = ('%s%s [ "$pinned_digest" != "$current_digest" ] '
                               '&& new_build "$ref" "$pinned_digest" "$current_digest"; then'
                               % (c.group(1), c.group(2)))
            pad = next(l for l in body if l.strip())
            pad = pad[:len(pad) - len(pad.lstrip())]
            body = [pad + h if h else "" for h in HELPER] + body
            sites += len(hits)
        out.extend(body)
        i = j
    new = "\n".join(out)
    # Every drift line must now sit under a comparison that asks about the build.
    nl = new.split("\n")
    for k, l in enumerate(nl):
        if DRIFT.search(l) and not (k and HANDLED.search(nl[k - 1])):
            return text, 0, "a drift line under a comparison this does not know: %s" % l.strip()[:90]
    return new, sites, None


def transform_file(path):
    text = io.open(path, encoding="utf-8").read()
    if not DRIFT.search(text):
        return 3, "no digest drift check"
    new, sites, why = transform(text)
    if why:
        return 2, why
    if not sites:
        return 1, "already compares the build"
    io.open(path, "w", encoding="utf-8").write(new)
    return 0, "%d site%s" % (sites, "" if sites == 1 else "s")


def run(cmd, cwd=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode:
        raise RuntimeError("%s: %s" % (" ".join(cmd[:3]), (p.stderr or p.stdout).strip()[:300]))
    return p


def changelog(d):
    p = os.path.join(d, "CHANGELOG.md")
    if not os.path.exists(p):
        return False
    s = io.open(p, encoding="utf-8").read()
    s = s.replace("## [Unreleased]\n\n_(no unreleased changes yet)_\n", "## [Unreleased]\n", 1)
    m = re.search(r"^## \[Unreleased\]\n", s, re.M)
    if not m:
        return False
    nxt = re.search(r"^## \[", s[m.end():], re.M)
    end = m.end() + (nxt.start() if nxt else len(s) - m.end())
    body = s[m.end():end]
    if "### Fixed\n" in body:
        k = body.index("### Fixed\n") + len("### Fixed\n")
        if body[k:k + 1] == "\n":
            k += 1
        body = body[:k] + CHANGELOG_LINE + "\n" + body[k:]
    else:
        body = "\n### Fixed\n\n" + CHANGELOG_LINE + "\n" + body
    io.open(p, "w", encoding="utf-8").write(s[:m.end()] + body + s[end:])
    return True


def lint(d):
    p = run(["docker", "run", "--rm", "-v", "%s:/repo" % d, "-w", "/repo", ACTIONLINT], check=False)
    if p.returncode not in (0, 1):     # 0 clean, 1 findings; anything else means it did not lint
        raise RuntimeError("actionlint did not run (exit %d): %s" % (p.returncode, (p.stderr or p.stdout).strip()[:200]))
    # positions move when lines are inserted, so findings are compared without them
    return {re.sub(r":\d+:\d+:", ":", l) for l in p.stdout.splitlines() if l.strip()}


def roll(repo, push, work):
    d = os.path.join(work, repo)
    run(["git", "clone", "-q", "--depth", "1", "https://github.com/%s/%s.git" % (OWNER, repo), d])
    wfdir = os.path.join(d, ".github", "workflows")
    if not os.path.isdir(wfdir):
        return "skip: no workflows"
    files = sorted(f for f in os.listdir(wfdir) if f.endswith((".yml", ".yaml")))
    before = None
    done, notes = [], []
    for f in files:
        path = os.path.join(wfdir, f)
        text = io.open(path, encoding="utf-8").read()
        if not DRIFT.search(text):
            continue
        if before is None:
            before = lint(d)
        rc, what = transform_file(path)
        if rc == 2:
            return "REFUSED: %s: %s" % (f, what)
        if rc == 0:
            done.append(f)
            notes.append("%s %s" % (f, what))
    if not done:
        return "already" if before is not None else "skip: no digest drift check"
    new = lint(d) - before
    if new:
        return "REFUSED by actionlint: %s" % "; ".join(sorted(new))[:400]
    if not changelog(d):
        notes.append("no [Unreleased] to note it in")
    run(["git", "add", "-A"], cwd=d)
    run(["git"] + AUTHOR + ["commit", "-q", "-m", COMMIT], cwd=d)
    sha = run(["git", "rev-parse", "HEAD"], cwd=d).stdout.strip()
    if push:
        if run(["git", "push", "-q", "origin", "HEAD:main"], cwd=d, check=False).returncode:
            # someone pushed in between: replay this one commit on top, once
            run(["git", "pull", "-q", "--rebase", "origin", "main"], cwd=d)
            run(["git", "push", "-q", "origin", "HEAD:main"], cwd=d)
            sha = run(["git", "rev-parse", "HEAD"], cwd=d).stdout.strip()
    return "ok %s (%s)%s" % (sha[:7], ", ".join(notes), "" if push else " — not pushed")


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["--file"]:
        if len(argv) != 2:
            sys.exit(__doc__)
        rc, what = transform_file(argv[1])
        print(what)
        return rc
    push = "--push" in argv
    repos = [a for a in argv if not a.startswith("--")]
    if not repos:
        repos = run(["gh", "repo", "list", OWNER, "--no-archived", "--source", "--visibility", "public",
                     "-L", "300", "--json", "name", "-q", ".[].name"]).stdout.split()
    work = tempfile.mkdtemp(prefix="freshness-same-build-")
    bad = 0
    for repo in sorted(repos):
        try:
            r = roll(repo, push, work)
        except Exception as e:  # noqa: BLE001 - one repository must not stop the rest
            r = "REFUSED: %s" % e
        bad += r.startswith("REFUSED")
        if not r.startswith("skip"):
            print("%-58s %s" % (repo, r), flush=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
