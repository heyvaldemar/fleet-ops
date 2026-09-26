#!/usr/bin/env python3
"""rollout-split-freshness.py [--push] <repo> [<repo> ...]

Moves each template's freshness job into .github/workflows/freshness.yml with
split-freshness.py, and brings every sentence that describes it in line with
where it now runs. Without --push it works in a scratch clone and reports.

WHAT ELSE IT FIXES, AND WHY HERE. The survey before this rollout found the
sentences about this job wrong in more ways than the move itself:
- sixty-two SECURITY.md files say "re-resolves every pin daily", and three of
  those templates ran weekly, with nothing recorded about why;
- keycloak's says "every Monday at 06:00 UTC" and its cron is daily;
- two workflows say "Weekly rebuild" above a daily cron.
A rollout that moves the job and leaves those sentences is a rollout that
publishes sixty-four fresh claims, some of them false on the day they ship.
"""
import io
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SPLIT = os.path.join(HERE, "split-freshness.py")
OWNER = "heyvaldemar"
AUTHOR = ["-c", "user.name=Vladimir Mikhalev",
          "-c", "user.email=10498744+heyvaldemar@users.noreply.github.com"]

OLD_COMMON = ("The Deployment Verification workflow re-resolves every pin daily and boots the full "
              "stack on every change; drift or breakage fails the run and notifies the maintainer.")
NEW_COMMON = ("The Pin Freshness workflow re-resolves every pin daily and fails when one has drifted; "
              "the Deployment Verification workflow boots the full stack on every change and fails "
              "when it breaks. Either one notifies the maintainer.")
SPECIAL = {
    "keycloak-traefik-letsencrypt-docker-compose": [(
        "CI's Deployment Verification workflow stands up the full compose stack on every push and "
        "every Monday at 06:00 UTC, catching upstream drift before it reaches users.",
        NEW_COMMON)],
    "quake3-server-docker-compose": [
        ("Deployment Verification rebuilds the image on every push and daily, scans it with Trivy, "
         "checks that the pin still matches the latest published build, and boots the stack.",
         "Deployment Verification rebuilds the image on every push and daily, scans it with Trivy "
         "and boots the stack; Pin Freshness checks daily that the pin still matches the latest "
         "published build."),
        ("Deployment Verification rebuilds the image from the checkout on every push and daily, "
         "scans the build with Trivy, and the daily `check-pin-freshness` job fails if the pin no "
         "longer matches the latest published build.",
         "Deployment Verification rebuilds the image from the checkout on every push and daily and "
         "scans the build with Trivy; the daily `check-pin-freshness` job, in its own Pin Freshness "
         "workflow, fails if the pin no longer matches the latest published build."),
    ],
}

LINE_SPLIT = ("- **The freshness check has its own workflow, Pin Freshness.** It ran inside "
              "Deployment Verification, whose badge is the one at the top of this README. Across the "
              "fleet, nine red runs in ten were a pin one version behind - which the fleet's triage "
              "moves within the day - and a reader cannot tell that from a stack that does not boot. "
              "The badge now says whether the stack boots. The job itself is unchanged.")
LINE_DAILY = ("- **Checked daily, as the security policy already said.** This template's schedule "
              "was weekly while its SECURITY.md said the pins are re-resolved daily, and nothing "
              "recorded a reason for the difference. It now runs daily like the rest of the fleet.")


def run(cmd, cwd=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode:
        raise RuntimeError("%s: %s" % (" ".join(cmd[:3]), (p.stderr or p.stdout).strip()[:300]))
    return p


def changelog(d, lines):
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
    add = "\n".join(lines) + "\n"
    if "### Changed\n" in body:
        i = body.index("### Changed\n") + len("### Changed\n")
        if body[i:i + 1] == "\n":
            i += 1
        body = body[:i] + add + body[i:]
    else:
        body = "\n### Changed\n\n" + add + body
    s = s[:m.end()] + body + s[end:]
    io.open(p, "w", encoding="utf-8").write(s)
    return True


def roll(repo, push, work):
    d = os.path.join(work, repo)
    run(["git", "clone", "-q", "--depth", "1", "https://github.com/%s/%s.git" % (OWNER, repo), d])
    notes, cl = [], [LINE_SPLIT]
    vpath = os.path.join(d, ".github", "workflows", "deployment-verification.yml")
    v = io.open(vpath, encoding="utf-8").read()
    # 1. a weekly schedule that the published sentence calls daily
    if re.search(r"cron:\s*\"0 6 \* \* 1\"", v):
        v = re.sub(r"cron:\s*\"0 6 \* \* 1\"", 'cron: "0 6 * * *"', v)
        cl.append(LINE_DAILY)
        notes.append("weekly -> daily")
    # 2. a comment that calls a daily schedule weekly
    if re.search(r"#\s*Weekly rebuild", v) and not re.search(r"cron:\s*\"[^\"]* [^*]\"", v):
        v = re.sub(r"#\s*Weekly rebuild", "# Daily rebuild", v)
        notes.append("comment says daily")
    io.open(vpath, "w", encoding="utf-8").write(v)
    # 3. the move itself, refused unless everything compares equal
    p = run([sys.executable, SPLIT, d], check=False)
    if p.returncode:
        return "REFUSED by the splitter: %s" % (p.stderr or p.stdout).strip()
    # 4. every sentence describing it
    changed = 0
    for f in ("SECURITY.md", "README.md"):
        fp = os.path.join(d, f)
        if not os.path.exists(fp):
            continue
        s = io.open(fp, encoding="utf-8").read()
        before = s
        s = s.replace(OLD_COMMON, NEW_COMMON)
        for old, new in SPECIAL.get(repo, []):
            s = s.replace(old, new)
        if s != before:
            io.open(fp, "w", encoding="utf-8").write(s)
            changed += 1
    left = run(["grep", "-rlE", "Deployment Verification workflow re-resolves|every Monday at 06:00 UTC, catching",
                "--include=*.md", "."], cwd=d, check=False).stdout.strip()
    if left:
        return "REFUSED: a sentence about the old layout survived in %s" % left.replace("\n", ", ")
    if changed == 0:
        return "REFUSED: no sentence describing the freshness check was found to update"
    changelog(d, cl)
    # 5. lint as CI will
    lint = run(["docker", "run", "--rm", "-v", "%s:/repo" % d, "-w", "/repo", "rhysd/actionlint:1.7.12"], check=False)
    if lint.returncode:
        return "REFUSED by actionlint: %s" % (lint.stdout or lint.stderr).strip()[:400]
    run(["git", "add", "-A"], cwd=d)
    msg = ("Give the freshness check its own workflow\n\n"
           "The badge at the top of the README is Deployment Verification's, and that workflow also "
           "ran the freshness check: a designed alarm that goes red when a pin is one version behind, "
           "which the fleet's triage moves within the day. Across the fleet, nine red runs in ten were "
           "that alarm and nothing else, and a reader cannot tell it from a stack that does not boot.\n\n"
           "The job moved verbatim to freshness.yml, under the same triggers, permissions and "
           "environment, and the sentences describing it now say where it runs."
           + ("\n\nThe schedule also moves from weekly to daily. SECURITY.md already said daily, and "
              "nothing recorded a reason for the difference." if LINE_DAILY in cl else ""))
    run(["git"] + AUTHOR + ["commit", "-q", "-m", msg], cwd=d)
    if push:
        run(["git", "push", "-q", "origin", "HEAD:main"], cwd=d)
    return "ok (%s%d doc file%s)%s" % (", ".join(notes) + "; " if notes else "", changed,
                                        "" if changed == 1 else "s", "" if push else " — not pushed")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    push = "--push" in sys.argv
    if not args:
        sys.exit(__doc__)
    work = tempfile.mkdtemp(prefix="split-freshness-")
    bad = 0
    for repo in args:
        try:
            r = roll(repo, push, work)
        except Exception as e:
            r = "REFUSED: %s" % e
        bad += r.startswith("REFUSED")
        print("%-58s %s" % (repo, r), flush=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
