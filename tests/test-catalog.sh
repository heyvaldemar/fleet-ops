#!/usr/bin/env bash
# The catalogue page, and the one sentence on it that was not true.
#
# The page said "every four hours" for weeks after it stopped being true. The
# sentence was a constant in the generator, the schedule was a line in a
# workflow, and nothing compared them — on the page whose whole argument is
# that a claim with nothing checking it is worth nothing.
#
# So the cadence is derived from the cron now, and these are the shapes it has
# to get right, including the one the first version got wrong.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import importlib.util, io, json, os, sys, tempfile

spec = importlib.util.spec_from_file_location("cat", "scripts/fleet-catalog.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0
def check(what, got, want):
    global passed, failed
    if got == want:
        print("  PASS: %s" % what); passed += 1
    else:
        print("  FAIL: %s\n        got %r, wanted %r" % (what, got, want)); failed += 1

d = tempfile.mkdtemp()
def with_cron(text):
    p = os.path.join(d, "w.yml")
    io.open(p, "w", encoding="utf-8").write("on:\n  schedule:\n    - cron: \"%s\"\n" % text)
    return m.cadence(p)

print("=== the sentence is read off the schedule ===")
check("one hour named is once a day", with_cron("20 6 * * *"), "once a day")
check("two hours named is twice a day", with_cron("20 6,18 * * *"), "twice a day")
check("four hours named is every six", with_cron("0 0,6,12,18 * * *"), "every 6 hours")
# THE SHAPE THE FIRST VERSION GOT WRONG. It counted the characters between the
# commas, so a step expression read as a single run a day.
check("a step expression is expanded, not counted", with_cron("0 */4 * * *"), "every 4 hours")
check("a range with a step too", with_cron("0 0-23/3 * * *"), "every 3 hours")
check("five a day does not become a false 'every N hours'", with_cron("0 1,2,3,4,5 * * *"), "5 times a day")
check("a day-of-week cron is weekly", with_cron("0 9 * * 1"), "weekly")
check("a day-of-month cron is monthly", with_cron("0 3 15 * *"), "monthly")

print()
print("=== and when it cannot be read, it says so rather than inventing one ===")
check("an hour field it does not understand", with_cron("0 bogus * * *"),
      "on a schedule this file could not read")
p = os.path.join(d, "none.yml")
io.open(p, "w", encoding="utf-8").write("on:\n  workflow_dispatch:\n")
check("a workflow with no schedule", m.cadence(p), "when something asks it to")
check("a workflow that is not there", m.cadence(os.path.join(d, "nope.yml")),
      "on a schedule this file could not read")

print()
print("=== the shipped page says what the shipped workflow does ===")
# Not a fixed string: the point is that the two agree, whatever they are.
said = m.cadence()
check("the generator can read its own workflow", said.startswith("on a schedule"), False)
# Built the way collect() builds it: every group label present, one row in it.
rows = dict((label, []) for label, _, _, _ in m.GROUPS)
rows[m.GROUPS[0][0]] = [("T", "t", "v1", "b")]
page = m.render_catalog(rows)
check("and the page carries that phrase", said in page, True)
check("and the old constant is gone from the page", "every four hours" in page, False)
summary = m.render_summary(rows)
check("the profile line carries it too", said in summary, True)
check("and not the old constant", "every four hours" in summary, False)

print()
print("=== and the badge says what it measures ===")
# The badge was Deployment Verification's while that workflow also ran the
# freshness alarm: nine red runs in ten were a pin one version behind. The job
# moved to its own workflow on 2026-09-23, and the sentence has to say so.
check("the page says the badge is about booting", "whether each one boots" in page, True)
check("and that pin currency is a separate check", "separate daily check" in page, True)

print()
print("=== the latest release is the highest version, not the flag ===")
# A release created late for an old version took GitHub's Latest flag, and this
# page showed nextcloud-onlyoffice at v1.3.0 while v2.0.4 was out.
keep = m.gh
def fake(path):
    if path.endswith("/releases?per_page=100"):
        return [{"tag_name": "v1.3.0", "published_at": "2026-09-22T15:33:00Z"},
                {"tag_name": "v2.0.4", "published_at": "2026-09-21T18:30:00Z"},
                {"tag_name": "v2.1.0-rc1", "published_at": "2026-09-23T10:00:00Z", "prerelease": True},
                {"tag_name": "v3.0.0", "published_at": "2026-09-24T10:00:00Z", "draft": True}]
    if path.endswith("/releases/latest"):
        return {"tag_name": "v1.3.0", "published_at": "2026-09-22T15:33:00Z"}
m.gh = fake
check("the highest published version wins over the flag", m.latest_release("x")[0], "v2.0.4")
check("and carries its own date", m.latest_release("x")[1], "2026-09-21")
def fake2(path):
    if path.endswith("/releases?per_page=100"):
        return [{"tag_name": "nightly", "published_at": "2026-09-22T00:00:00Z"}]
    return {"tag_name": "nightly", "published_at": "2026-09-22T00:00:00Z"}
m.gh = fake2
check("with no parsable version, the flag is the answer", m.latest_release("x")[0], "nightly")
m.gh = keep

print()
print("=== the evidence line counts what runs, and says what it could not read ===")
import base64, subprocess as sp
def fake_repo(files):
    """files: {repo: {path: text}}; a repo mapped to None cannot be read."""
    def fake(path):
        parts = path.split("/", 4)          # repos, owner, repo, contents|tags, rest
        repo, kind = parts[2], parts[3].split("?")[0]
        tree = files.get(repo)
        if tree is None:
            raise sp.CalledProcessError(1, "gh")
        if kind == "tags":
            return [{}] * tree.get("__tags__", 0) if "page=1" in path else []
        sub = parts[4] if len(parts) > 4 else ""
        if sub in tree:
            return {"content": base64.b64encode(tree[sub].encode()).decode()}
        prefix = (sub + "/") if sub else ""
        names = sorted({k[len(prefix):].split("/")[0] for k in tree if k.startswith(prefix) and k != "__tags__"})
        if not names:
            raise sp.CalledProcessError(1, "gh")
        return [{"name": n} for n in names]
    return fake
keep = m.gh
m.gh = fake_repo({
    "a": {"a-restore-database.sh": "", "tests/e2e.sh": "./a-restore-database.sh x\n", "__tags__": 3},
    "b": {"b-restore-data.sh": "", "tests/e2e.sh": "# ./b-restore-data.sh\necho ./b-restore-data.sh\n", "__tags__": 2},
    "c": {"c-restore.sh": "", "tests/e2e.sh": 'D="$ROOT/c-restore.sh"\n"$D" x\n', "__tags__": 1},
    "d": None,
})
ev = m.collect_evidence(["a", "b", "c", "d"])
check("every shipped script is counted", ev["scripts"], 3)
check("./script and a path to it count as run; a comment and an echo do not", ev["run"], 2)
check("a repository it cannot read is named, not counted", ev["unread"], ["d"])
check("tags are summed", ev["tags"], 6)
line = m.render_evidence(ev)
check("the line does not claim every script runs when one does not", "every one of them" in line, False)
check("it says how many run", "CI runs 2 of them" in line, True)
check("it says what it could not read", "1 repository could not be read" in line, True)
ev_all = {"scripts": 5, "templates": 3, "run": 5, "unread": [], "tags": 9}
check("when all run, it says so", "every one of them run by CI" in m.render_evidence(ev_all), True)
check("the line sits between its markers",
      m.render_evidence(ev_all).startswith(m.EVI_START) and m.render_evidence(ev_all).rstrip().endswith(m.EVI_END), True)
m.gh = keep

print()
print("=== fleet.json: the timestamp alone does not rewrite it, a failed drill is not a time ===")
import tempfile as _tf, os as _os
jd = _tf.mkdtemp(); jp = _os.path.join(jd, "fleet.json")
rows0 = {g[0]: [] for g in m.GROUPS}; rows0[m.GROUPS[0][0]] = [["A", "a", "-", "-"]]
ev0 = {"scripts": 2, "templates": 1, "run": 2, "unread": [], "tags": 5}
check("a new file is written", m.write_json(jp, m.fleet_json(rows0, ev0, [])), "updated")
real_stamp = m.stamp
m.stamp = lambda: "2099-01-01 00:00"
check("the same numbers an hour later are not a change", m.write_json(jp, m.fleet_json(rows0, ev0, [])), "unchanged")
ev1 = dict(ev0, run=1)
check("a script that stops running is", m.write_json(jp, m.fleet_json(rows0, ev1, [])), "updated")
m.stamp = real_stamp
def fake_dr(path):
    if "/actions/workflows/dr-drill.yml/runs" in path:
        return {"workflow_runs": [{"id": 7, "conclusion": "failure", "html_url": "https://x/7", "updated_at": "2026-09-24T00:00:00Z"}]}
    raise AssertionError("a failed drill must not be read further: " + path)
keep2 = m.gh; m.gh = fake_dr
r = m.dr_result("x")
check("a failed drill is listed as failing", r["ok"], False)
check("and carries no restore time", "seconds_total" in r, False)
m.gh = keep2

print()
print("=== the recovery point is read from the file people copy ===")
def fake_env(path):
    if path.endswith("/contents/.env.example"):
        repo = path.split("/")[2]
        body = {"c": "# BACKUP_INTERVAL=24h\n", "u": "BACKUP_INTERVAL=12h\n", "n": "OTHER=1\n", "w": "BACKUP_INTERVAL=${X}\n", "k": "KEYCLOAK_BACKUP_INTERVAL=12h\n"}.get(repo)
        if body is None:
            raise sp.CalledProcessError(1, "gh")
        return {"content": base64.b64encode(body.encode()).decode()}
    raise sp.CalledProcessError(1, "gh")
keep3 = m.gh; m.gh = fake_env
check("a commented default is the shipped interval", m.backup_interval("c"), "24h")
check("so is an uncommented one", m.backup_interval("u"), "12h")
check("a file without it answers None, not a guess", m.backup_interval("n"), None)
check("a value that is not a duration is not read", m.backup_interval("w"), None)
check("a prefixed name, as Keycloak writes it, is read", m.backup_interval("k"), "12h")
check("a repository it cannot read answers None", m.backup_interval("gone"), None)
d = m.with_rpo({"repository": "c"})
check("the drill row carries the interval and its hours", (d["backup_interval"], d["rpo_hours"]), ("24h", 24))
m.gh = keep3
check("hours: 1d is 24", m.hours("1d"), 24)
check("hours: 30m is a half", m.hours("30m"), 0.5)
check("hours: nonsense is None", m.hours("soon"), None)

print()
print("=== the scorecard is repeated, not awarded ===")
fake_sc = {
    "a": {"score": 7.8, "date": "2026-09-24", "checks": {"Code-Review": 0, "Signed-Releases": -1, "License": 10}},
    "b": {"score": 6.0, "date": "2026-09-23", "checks": {"Code-Review": 0, "License": 5}},
    "c": {"score": 9.0, "date": "2026-09-22", "checks": {"Code-Review": 10, "License": 10}},
    "d": {"score": 5.7, "date": "2026-09-20", "checks": {}},
}
keep4 = m.scorecard; m.scorecard = lambda n: fake_sc.get(n)
sc = m.collect_scorecard(["a", "b", "c", "d", "e"])
check("every answered repository is counted", sc["scored"], 4)
check("the median of an even count is the mean of the middle two", sc["median"], 6.9)
check("the lowest is named", (sc["lowest"], sc["lowest_repository"]), (5.7, "d"))
check("a check below ten is counted per repository", sc["below_ten"]["Code-Review"], 2)
check("a mark of -1 is not applicable and is not a low mark", "Signed-Releases" in sc["below_ten"], False)
check("a partial mark counts", sc["below_ten"]["License"], 1)
check("a repository with no score is named", sc["unscored"], ["e"])
check("the date is the newest result", sc["date"], "2026-09-24")
check("nothing scored is said plainly", m.collect_scorecard(["e"])["scored"], 0)
m.scorecard = keep4
line = m.render_evidence(ev_all, [{"ok": True, "seconds_total": 45}, {"ok": True, "seconds_total": 139}, {"ok": False}], sc)
check("the profile line says how many drills passed of how many", "2 of 3 templates restored" in line, True)
check("and quotes the fastest", "the fastest in 45 s" in line, True)
check("and repeats the median, saying whose it is", "run by OpenSSF and not by me, puts the median at 6.9 across 4" in line, True)
bare = m.render_evidence(ev_all)
check("with no drills and no scorecard the line says nothing about either", "restored" in bare or "Scorecard" in bare, False)
j = json.loads(m.fleet_json(rows0, ev0, [], sc))
check("fleet.json carries the scorecard", j["scorecard"]["median"], 6.9)
check("and an empty one when nothing was scored", json.loads(m.fleet_json(rows0, ev0, []))["scorecard"]["scored"], 0)


print()
print("=== the badge is repeated, the short ones by name ===")
fake_bp = {
    "a": {"id": 1, "level": "passing", "percent": 100, "date": "2026-09-25"},
    "b": {"id": 2, "level": "in_progress", "percent": 96, "date": "2026-09-24"},
    "c": {"id": 3, "level": "gold", "percent": 100, "date": "2026-09-20"},
    "d": False,
}
keep5 = m.bestpractices; m.bestpractices = lambda n, sleep=None: fake_bp.get(n)
naps = []
bp = m.collect_bestpractices(["a", "b", "c", "d", "e"], sleep=naps.append)
check("the site is asked at a pace, one pause between every two names", naps, [m.BP_PACE] * 4)
check("every registered repository is counted", bp["registered"], 3)
check("passing counts every level from passing up", bp["passing"], 2)
check("the short one is named with its percent", bp["short"], {"b": 96})
check("a repository the site never heard of is unregistered", bp["unregistered"], ["d"])
check("a repository the site could not be asked about is unread, not unregistered", bp["unread"], ["e"])
check("the ids are kept so a badge can be linked", bp["ids"]["c"], 3)
check("the date is the newest answer", bp["date"], "2026-09-25")
check("nothing registered is said plainly", m.collect_bestpractices(["d"])["registered"], 0)
m.bestpractices = keep5
# The badge site answers 429 to a burst; the first sweep read 24 of 97 and called the rest unread.
answers = iter([(429, ""), (429, ""), (200, '[{"id": 7, "badge_level": "passing", "badge_percentage_0": 100, "updated_at": "2026-09-25T04:00:00Z"}]')])
waits = []
got = m.bestpractices("x", fetch=lambda u: next(answers), sleep=waits.append)
check("a 429 is waited out and asked again, longer each time", waits, [m.BP_RETRY_WAIT, m.BP_RETRY_WAIT * 2])
check("and the answer that then comes is read", (got["id"], got["level"]), (7, "passing"))
check("a 429 that never lifts is unread, not unregistered",
      m.bestpractices("x", fetch=lambda u: (429, ""), sleep=lambda s: None), None)
check("an empty list is unregistered", m.bestpractices("x", fetch=lambda u: (200, "[]")), False)
check("a page that is not JSON is unread", m.bestpractices("x", fetch=lambda u: (200, "<html>")), None)
check("no answer at all is unread", m.bestpractices("x", fetch=lambda u: (0, "")), None)
check("the profile line says how many could not be read",
      "passing on 1 of 2 registered repositories; 3 could not be read today" in m.render_evidence(
          ev_all, [], None, {"registered": 2, "passing": 1, "unread": ["p", "q", "r"]}), True)
line = m.render_evidence(ev_all, [], None, bp)
check("the profile line says passing of registered, and whose answers they are", "a questionnaire I answered and OpenSSF publishes with every answer, is passing on 2 of 3 registered" in line, True)
check("with nothing registered the line says nothing about the badge", "Best Practices" in m.render_evidence(ev_all, [], None, m.collect_bestpractices([])), False)
j = json.loads(m.fleet_json(rows0, ev0, [], None, bp))
check("fleet.json carries the badge", (j["bestpractices"]["passing"], j["bestpractices"]["short"]), (2, {"b": 96}))
check("and an empty one when nothing was read", json.loads(m.fleet_json(rows0, ev0, []))["bestpractices"]["registered"], 0)

print("\npassed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
