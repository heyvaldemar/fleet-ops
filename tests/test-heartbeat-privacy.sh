#!/bin/bash
# The heartbeat runs in two copies, and only one of them may say a private
# repository's name. The public heyvaldemar/fleet-ops prints its findings into
# a public run log, a public step summary and a public issue; the private
# copy (FLEET_ROLE=house) prints into its own. A stuck Dependabot pull request
# on a private repository carries that repository's name and the title of the
# update, and the public sweep used to report both.
#
# Nothing had leaked when this was written, which is exactly when a leak is
# cheap to prevent and impossible to see coming: the first private pull request
# left open for a day would have published it. So the whole script is run here,
# end to end, against a fake gh that serves one public repository and one
# private one with every finding the private half can produce planted in it,
# and the public output is searched for the planted name and title.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import base64
import datetime
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

now = datetime.datetime.now(datetime.timezone.utc)
def ago(h):
    return (now - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
def b64(text):
    return base64.b64encode(text.encode()).decode()

passed = failed = 0
def check(what, got, want):
    global passed, failed
    if got == want:
        print("  PASS: %s" % what); passed += 1
    else:
        print("  FAIL: %s\n        got %r, wanted %r" % (what, got, want)); failed += 1

# Invented names: this file is published with the rest of the public copy.
PRIVATE, TITLE = "hidden-ledger", "Bump planted-title-7f3a from 1.0 to 2.0"
PUB, PRIV = "o/open-tool", "o/" + PRIVATE

def issue(full, n):
    return {"number": n, "user": {"login": "stranger", "type": "User"},
            "created_at": ago(72), "comments": 0,
            "repository_url": "https://api.github.com/repos/%s" % full,
            "html_url": "https://github.com/%s/issues/%d" % (full, n)}

# First match wins; anything unmatched answers 404, the way GitHub does.
RULES = [
    ["user/repos?affiliation=owner", [
        {"full_name": PUB, "archived": False, "fork": False, "private": False, "default_branch": "main"},
        {"full_name": PRIV, "archived": False, "fork": False, "private": True, "default_branch": "main"}]],
    ["search/issues?q=user%3Ao%20is%3Aopen%20is%3Aissue", {"items": [issue(PUB, 4), issue(PRIV, 3)]}],
    ["search/issues?", {"items": []}],
    # The public repository: healthy enough to be read all the way through.
    ["repos/%s/actions/workflows/1/runs" % PUB,
     {"workflow_runs": [{"id": 11, "event": "schedule", "conclusion": "success", "created_at": ago(2)}]}],
    ["repos/%s/actions/workflows?" % PUB,
     {"workflows": [{"id": 1, "path": ".github/workflows/daily.yml", "state": "active"}]}],
    ["repos/%s/contents/.github/dependabot.yml" % PUB, {}],
    ["repos/%s/contents/SECURITY.md" % PUB, {"content": b64("Report it privately.\n")}],
    ["repos/%s/rules/branches/main" % PUB, [{"type": "non_fast_forward"}, {"type": "deletion"}]],
    ["repos/%s/pulls" % PUB, []],
    ["repos/%s/commits/main" % PUB, {"sha": "a" * 40, "commit": {"committer": {"date": ago(1)}}}],
    # The private one: a Dependabot pull request two days old, a schedule
    # GitHub switched off, and one that stopped firing.
    ["repos/%s/pulls" % PRIV, [{"user": {"login": "dependabot[bot]"}, "number": 7,
                                "created_at": ago(50), "title": TITLE}]],
    ["repos/%s/actions/workflows/10/runs" % PRIV,
     {"workflow_runs": [{"id": 12, "event": "schedule", "conclusion": "success", "created_at": ago(400)}]}],
    ["repos/%s/actions/workflows?" % PRIV,
     {"workflows": [{"id": 9, "path": ".github/workflows/nightly.yml", "state": "disabled_inactivity"},
                    {"id": 10, "path": ".github/workflows/weekly.yml", "state": "active"}]}],
    ["repos/%s/contents/.github/workflows/weekly.yml" % PRIV,
     {"content": b64("on:\n  schedule:\n    - cron: '0 6 * * 1'\n")}],
    ["repos/%s/commits?path=" % PRIV, []],
]

work = tempfile.mkdtemp()
json.dump(RULES, open(os.path.join(work, "rules.json"), "w"))
fake = os.path.join(work, "gh")
open(fake, "w").write("""#!/usr/bin/env python3
import json, os, sys
path = sys.argv[2] if sys.argv[1:2] == ["api"] and len(sys.argv) > 2 else " ".join(sys.argv[1:])
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(path + "\\n")
for part, body in json.load(open(os.environ["FAKE_GH_RULES"])):
    if part in path:
        print(json.dumps(body))
        sys.exit(0)
sys.stderr.write("gh: Not Found (HTTP 404)\\n")
sys.exit(1)
""")
os.chmod(fake, 0o755)

def run(*args, role=None):
    """The script as a job runs it. (exit code, everything it printed and
    wrote, every path it asked gh for)."""
    log = os.path.join(work, "calls.log")
    out = os.path.join(work, "beat.json")
    for f in (log, out):
        if os.path.exists(f):
            os.remove(f)
    env = {k: v for k, v in os.environ.items()
           if k not in ("FLEET_ROLE", "FLEET_READ_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")}
    env.update(PATH=work + os.pathsep + env.get("PATH", ""), FAKE_GH_RULES=os.path.join(work, "rules.json"),
               FAKE_GH_LOG=log)
    if role:
        env["FLEET_ROLE"] = role
    p = subprocess.run([sys.executable, "scripts/fleet-heartbeat.py", "--owner", "o", "--json", out] + list(args),
                       capture_output=True, text=True, env=env)
    said = p.stdout + p.stderr + (open(out).read() if os.path.exists(out) else "")
    calls = open(log).read().splitlines() if os.path.exists(log) else []
    return p.returncode, said, calls

print("=== the public sweep says nothing a stranger may not read ===")
code, said, calls = run("--fleet")
check("it ran to the end, so the silence below means something",
      code in (0, 1) and "public repositories" in said and os.path.exists(os.path.join(work, "beat.json")), True)
check("the private repository's name is nowhere in what it printed or wrote", PRIVATE in said, False)
check("nor the title of its Dependabot pull request",                        "planted-title-7f3a" in said, False)
check("it never asked GitHub anything about that repository at all",
      [c for c in calls if PRIVATE in c], [])
check("a person waiting on a public repository is still reported",
      "%s#4: stranger opened this issue" % PUB in said, True)

print()
print("=== the house copy keeps the alarm, by name ===")
code, said, calls = run("--private", role="house")
check("it ran to the end", code in (0, 1) and os.path.exists(os.path.join(work, "beat.json")), True)
check("the stuck pull request is named, with its title",
      "%s#7 has been open 50 hours: %s" % (PRIV, TITLE) in said, True)
check("the schedule GitHub switched off is named",
      "%s: nightly.yml is disabled_inactivity" % PRIV in said, True)
check("and the one that stopped firing",
      "%s: weekly.yml last fired 400 hours ago" % PRIV in said, True)
check("a person waiting on a private repository is reported here",
      "%s#3: stranger opened this issue" % PRIV in said, True)
check("and the public half is left to the copy that sweeps it",
      ("%s#4" % PUB in said, [c for c in calls if c.startswith("repos/%s/" % PUB)]), (False, []))

print()
print("=== and only the house copy may ask ===")
code, said, calls = run("--private")
check("without FLEET_ROLE=house the private half refuses to run, and says why",
      (code != 0, "house copy" in said), (True, True))
check("before it has read or said anything private",
      (PRIVATE in said, [c for c in calls if PRIVATE in c]), (False, []))

print()
print("=== a watched private repository is counted, not named ===")
# GitHub subscribes the creator of every new repository, private ones too, and
# the public copy's own-jobs check lists the drift by name.
spec = importlib.util.spec_from_file_location("hb", "scripts/fleet-heartbeat.py")
hb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hb)
def sub(name, private):
    r = {"full_name": "heyvaldemar/" + name, "owner": {"login": "heyvaldemar"}}
    if private is not None:
        r["private"] = private
    return r
hb.gh = lambda path: [sub("fleet-ops", False), sub("open-tool", False), sub(PRIVATE, True),
                      sub("unlabelled", None)] if "page=1" in path else []
keep = os.environ.pop("FLEET_ROLE", None)
public = " ".join(hb.watch_drift())
check("the public copy names the public one",               "heyvaldemar/open-tool" in public, True)
check("and not the private one",                            PRIVATE in public, False)
check("nor one whose visibility the answer left out",       "unlabelled" in public, False)
check("but counts them, so the drift is still reported",    "2 private" in public, True)
os.environ["FLEET_ROLE"] = "house"
house = " ".join(hb.watch_drift())
check("the house copy names all three",
      all(n in house for n in ("open-tool", PRIVATE, "unlabelled")), True)
if keep is None:
    os.environ.pop("FLEET_ROLE", None)
else:
    os.environ["FLEET_ROLE"] = keep

print("passed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
