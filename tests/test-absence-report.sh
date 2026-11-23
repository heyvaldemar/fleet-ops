#!/usr/bin/env bash
# test-absence-report.sh - the absence report, shown what it counts.
#
# A report that can only say "nothing happened" would pass every test that
# ran it on a quiet day, so each number is first shown the thing it counts,
# planted: a cron time nobody answered, a red streak a scheduled run closed
# and one a re-run from the automation closed, a green run created after the
# window's end (it must not close anything), a push by the owner that no
# automation run explains, an outsider's question answered only after the
# window. Then November's recorded sweep goes through the same code and the
# numbers that survive leaving the private repositories out must still be the
# fact file's. The collector is run against a stand-in for `gh` that answers
# for a private repository as well, to show it never asks for one and stops
# if one comes back.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/absence-report.py"
FIX="$ROOT/tests/fixtures/absence-2026-11"
BASE="$FIX/summary.json"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', expected '$3')"; fi; }
field() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if k.isdigit() else d[k]
print(d)' "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- the cron reader, on crons whose fire times are known
python3 - "$S" <<'PY' > "$WORK/cron.out" 2>&1
import importlib.util, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("ar", sys.argv[1])
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)
U = timezone.utc
def f(expr, a, b):
    return [t.strftime("%a %d %H:%M") for t in ar.cron_fires(expr, datetime(*a, tzinfo=U), datetime(*b, tzinfo=U))]
# 2027-01-15 is a Friday, 2027-01-18 a Monday
print("daily", f("0 6 * * *", (2027,1,15,0,0), (2027,1,17,23,59)))
print("monday", f("37 5 * * 1", (2027,1,15,0,0), (2027,1,18,23,59)))
print("sixhours", f("17 */6 * * *", (2027,1,15,0,0), (2027,1,15,23,59)))
print("mon+wed", f("0 9 * * 1,3", (2027,1,15,0,0), (2027,1,20,23,59)))
print("sunday7", f("0 22 * * 7", (2027,1,15,0,0), (2027,1,18,0,0)))
print("sunday0", f("0 22 * * 0", (2027,1,15,0,0), (2027,1,18,0,0)))
print("dom-or-dow", f("0 0 16 * 1", (2027,1,15,0,0), (2027,1,19,0,0)))
print("outside", f("0 6 * * *", (2027,1,15,7,0), (2027,1,15,23,0)))
try:
    ar.cron_fires("0 6 * *", datetime(2027,1,15,tzinfo=U), datetime(2027,1,16,tzinfo=U))
    print("bad", "accepted")
except ValueError:
    print("bad", "refused")
PY
check "a daily cron fires once a day" "$(grep '^daily' "$WORK/cron.out")" "daily ['Fri 15 06:00', 'Sat 16 06:00', 'Sun 17 06:00']"
check "a Monday cron has no fire between Friday and Monday 00:00" "$(grep '^monday' "$WORK/cron.out")" "monday ['Mon 18 05:37']"
check "a */6 hour cron fires four times a day" "$(grep '^sixhours' "$WORK/cron.out")" "sixhours ['Fri 15 00:17', 'Fri 15 06:17', 'Fri 15 12:17', 'Fri 15 18:17']"
check "a list of weekdays fires on each" "$(grep '^mon+wed' "$WORK/cron.out")" "mon+wed ['Mon 18 09:00', 'Wed 20 09:00']"
check "weekday 7 and weekday 0 are both Sunday" "$(grep '^sunday7' "$WORK/cron.out")" "$(grep '^sunday0' "$WORK/cron.out" | sed 's/^sunday0/sunday7/')"
check "a day matching either day of month or weekday fires" "$(grep '^dom-or-dow' "$WORK/cron.out")" "dom-or-dow ['Sat 16 00:00', 'Mon 18 00:00']"
check "a cron time before the window's start is not counted" "$(grep '^outside' "$WORK/cron.out")" "outside []"
check "a cron with four fields is refused" "$(grep '^bad' "$WORK/cron.out")" "bad refused"

# ---- the planted window: Friday 2027-01-15 00:00Z to Monday 2027-01-18 00:00Z
P="$WORK/plant"
mkdir -p "$P"
python3 - "$P" <<'PY'
import json, sys, os
d = sys.argv[1]
def w(name, rows):
    with open(os.path.join(d, name), "w") as fh:
        for r in rows: fh.write(json.dumps(r) + "\n")
json.dump({"owner": "acme", "start": "2027-01-15T00:00:00Z", "end": "2027-01-18T00:00:00Z",
           "read_from": "2027-01-14T00:00:00Z", "read_to": "2027-01-18T04:00:00Z", "collected_at": "2027-01-18T04:00:00Z"},
          open(os.path.join(d, "meta.json"), "w"))
json.dump([{"name": "alpha", "end_oid": None}, {"name": "fleet-ops", "end_oid": None}], open(os.path.join(d, "repos.json"), "w"))
def wf(repo, path, crons, fresh=False): return {"repo": repo, "path": ".github/workflows/" + path, "crons": crons, "check_freshness": fresh}
w("workflows.jsonl", [
    wf("alpha", "daily.yml", ["0 6 * * *"]), wf("alpha", "build.yml", ["0 7 * * *"]), wf("alpha", "ci.yml", []),
    wf("alpha", "freshness.yml", ["0 6 * * *"]), wf("alpha", "k8s-fresh.yml", ["37 5 * * 1"], True),
    wf("alpha", "scan.yml", []), wf("alpha", "release.yml", []),
    wf("fleet-ops", "fleet-triage.yml", ["45 6 * * *", "30 19 * * *"])])
def run(i, repo, name, path, event, concl, created, updated, trig="owner", attempt=1):
    return {"id": i, "repo": repo, "name": name, "path": ".github/workflows/" + path, "event": event, "status": "completed",
            "conclusion": concl, "created_at": created, "updated_at": updated, "run_started_at": created,
            "run_attempt": attempt, "sha": "abc1234", "actor": "owner", "trig": trig}
runs = [
    run(1, "alpha", "Daily", "daily.yml", "schedule", "success", "2027-01-14T15:00:00Z", "2027-01-14T15:02:00Z"),
    run(2, "alpha", "Daily", "daily.yml", "schedule", "success", "2027-01-15T15:12:00Z", "2027-01-15T15:14:00Z"),
    run(3, "alpha", "Daily", "daily.yml", "schedule", "failure", "2027-01-17T15:00:00Z", "2027-01-17T15:02:00Z"),
    run(4, "alpha", "CI", "ci.yml", "push", "failure", "2027-01-15T10:00:00Z", "2027-01-15T10:05:00Z"),
    run(5, "alpha", "CI", "ci.yml", "push", "failure", "2027-01-15T11:00:00Z", "2027-01-15T11:05:00Z"),
    run(6, "alpha", "CI", "ci.yml", "workflow_dispatch", "success", "2027-01-16T09:00:00Z", "2027-01-16T09:03:00Z", attempt=2),
    run(7, "fleet-ops", "Fleet Triage", "fleet-triage.yml", "schedule", "success", "2027-01-16T08:50:00Z", "2027-01-16T09:05:00Z"),
    run(8, "alpha", "Pin Freshness", "freshness.yml", "schedule", "failure", "2027-01-17T15:30:00Z", "2027-01-17T15:31:00Z"),
    run(9, "alpha", "Pin Freshness", "freshness.yml", "schedule", "success", "2027-01-18T02:00:00Z", "2027-01-18T02:01:00Z"),
    run(10, "alpha", "Build", "build.yml", "pull_request", "failure", "2027-01-15T14:00:00Z", "2027-01-15T14:01:00Z", trig="dependabot[bot]"),
    run(11, "alpha", "Build", "build.yml", "pull_request", "skipped", "2027-01-15T15:00:00Z", "2027-01-15T15:00:00Z", trig="dependabot[bot]"),
    run(12, "alpha", "Build", "build.yml", "schedule", "success", "2027-01-16T16:00:00Z", "2027-01-16T16:01:00Z"),
    run(13, "alpha", "Release Assets", "release.yml", "release", "success", "2027-01-16T08:58:00Z", "2027-01-16T09:02:00Z"),
    run(14, "alpha", "Scan", "scan.yml", "workflow_run", "skipped", "2027-01-15T16:00:00Z", "2027-01-15T16:00:00Z"),
    run(15, "alpha", "Docs", "docs.yml", "pull_request", "cancelled", "2027-01-15T17:00:00Z", "2027-01-15T17:01:00Z", trig="dependabot[bot]"),
    # a streak that began and ended in the lookback, before the window: not the window's
    run(16, "alpha", "Old", "old.yml", "push", "failure", "2027-01-14T10:00:00Z", "2027-01-14T10:01:00Z", trig="dependabot[bot]"),
    run(17, "alpha", "Old", "old.yml", "push", "success", "2027-01-14T12:00:00Z", "2027-01-14T12:01:00Z", trig="dependabot[bot]"),
]
w("runs.jsonl", runs)
def c(sha, when, head, author="owner"): return {"repo": "alpha", "sha": sha, "committed_at": when, "headline": head, "author": author}
w("commits.jsonl", [
    c("1111111", "2027-01-14T18:00:00Z", "chore(release): v0.9"),
    c("2222222", "2027-01-16T08:55:00Z", "chore(release): v1.2.3"),
    c("3333333", "2027-01-16T08:56:00Z", "fix(security): refresh pins"),
    c("4444444", "2027-01-16T09:04:00Z", 'Revert "fix(security): refresh pins"'),
    c("5555555", "2027-01-16T13:00:00Z", "docs: reword"),
    c("6666666", "2027-01-17T03:00:00Z", "build(deps): bump x", "dependabot[bot]"),
    c("7777777", "2027-01-18T00:00:00Z", "chore(release): v1.3.0")])
def o(n, kind, created, closed, owner=(), outside=()):
    return {"repo": "alpha", "number": n, "kind": kind, "created_at": created, "closed_at": closed,
            "owner_comments": list(owner), "outside_comments": list(outside)}
w("outside.jsonl", [
    o(1, "issue", "2027-01-14T12:00:00Z", None),
    o(2, "pull", "2027-01-15T10:00:00Z", None, ["2027-01-15T12:00:00Z"], ["2027-01-16T10:00:00Z"]),
    o(3, "issue", "2027-01-05T10:00:00Z", "2027-01-12T10:00:00Z"),
    o(4, "issue", "2027-01-15T20:00:00Z", None, ["2027-01-18T02:00:00Z"]),
    o(5, "issue", "2027-01-17T00:00:00Z", "2027-01-17T06:00:00Z", ["2027-01-17T05:00:00Z"])])
def m(day, n): return {"date": day, "repo": "alpha", "sku": "Actions Linux", "minutes": n}
w("minutes.jsonl", [m("2027-01-12", 100), m("2027-01-13", 100), m("2027-01-14", 100),
                    m("2027-01-15", 30), m("2027-01-16", 20), m("2027-01-17", 10), m("2027-01-18", 500)])
PY
python3 "$S" report "$P" --json "$WORK/plant.json" > "$WORK/plant.md"
check "report ran on the planted window" "$?" 0
check "runs: 13 created inside; the one before and the one after the window are not counted" "$(field "$WORK/plant.json" runs.all)" 13
check "runs by result: 5 success" "$(field "$WORK/plant.json" runs.success)" 5
check "runs by result: 5 failure" "$(field "$WORK/plant.json" runs.failure)" 5
check "runs by result: 2 skipped" "$(field "$WORK/plant.json" runs.skipped)" 2
check "runs by result: 1 cancelled" "$(field "$WORK/plant.json" runs.cancelled)" 1
check "a run re-run once is counted" "$(field "$WORK/plant.json" runs.rerun)" 1
check "scheduled: 5, of them 3 green and 2 red" "$(field "$WORK/plant.json" scheduled.all)/$(field "$WORK/plant.json" scheduled.green)/$(field "$WORK/plant.json" scheduled.red)" "5/3/2"
check "lateness: four daily runs answer, the two-a-day one does not" "$(field "$WORK/plant.json" lateness_hours.n)" 4
check "lateness median" "$(field "$WORK/plant.json" lateness_hours.median)" 9.2
check "lateness max" "$(field "$WORK/plant.json" lateness_hours.max)" 9.5
check "cron times counted: 10, answered 3" "$(field "$WORK/plant.json" cron_times.expected)/$(field "$WORK/plant.json" cron_times.answered)" "10/3"
check "daily cron times with no run: 4 of 6" "$(field "$WORK/plant.json" cron_times.daily_missing)/$(field "$WORK/plant.json" cron_times.daily_expected)" "4/6"
check "streaks: 4, five red runs (a streak that ended before the window is not one of them)" "$(field "$WORK/plant.json" red_streaks.all)/$(field "$WORK/plant.json" red_streaks.red_runs)" "4/5"
check "streaks: two turned green, two still red" "$(field "$WORK/plant.json" red_streaks.closed)/$(field "$WORK/plant.json" red_streaks.still_red)" "2/2"
check "a green run created after the end closes nothing" "$(grep -c '| Pin Freshness |.*still red at the window' "$WORK/plant.md")" 1
check "a re-run dispatched inside a Fleet Triage run is the automation's" "$(field "$WORK/plant.json" 'red_streaks.ended_by.re-run dispatched by the automation')" 1
check "a skipped run between red and green is passed over" "$(field "$WORK/plant.json" 'red_streaks.ended_by.the next scheduled run')" 1
check "red for, median hours" "$(field "$WORK/plant.json" red_streaks.red_hours.median)" 26.0
check "release commits: the one before the window and the one at its end are not counted" "$(field "$WORK/plant.json" releases.release_commits)" 1
check "pin refresh commits" "$(field "$WORK/plant.json" releases.pin_refresh_commits)" 1
check "reverts" "$(field "$WORK/plant.json" releases.reverts)" 1
check "runs started by a release" "$(field "$WORK/plant.json" releases.release_event_runs)" 1
check "freshness: one workflow calls check-freshness.py" "$(field "$WORK/plant.json" k8s_freshness.workflows)" 1
check "freshness: a Monday check has no cron time in a Friday-to-Monday window, so it did not run" "$(field "$WORK/plant.json" k8s_freshness.ran_in_window)" 0
check "freshness: the table says it has 0 cron times in the window" "$(grep -c 'k8s-fresh.yml.*| 0 | 0 |' "$WORK/plant.md")" 1
check "unexplained: the two owner pushes outside any automation run" "$(field "$WORK/plant.json" unexplained.runs)" 2
check "unexplained: the one owner commit outside any automation run" "$(field "$WORK/plant.json" unexplained.commits)" 1
check "outside: four items open at some point in the window" "$(field "$WORK/plant.json" outside.open_in_window)" 4
check "outside: three waiting at the end (an answer after the end is no answer)" "$(field "$WORK/plant.json" outside.waiting_at_end)" 3
check "outside: the longest wait" "$(field "$WORK/plant.json" outside.longest_wait_h)" 84.0
check "outside: answered in the window" "$(field "$WORK/plant.json" outside.answered_in_window)" 2
check "minutes a day in the window" "$(field "$WORK/plant.json" minutes.window_per_day)" 20
check "minutes a day before the window" "$(field "$WORK/plant.json" minutes.before_per_day)" 100
check "minutes: the 18th is outside both" "$(field "$WORK/plant.json" minutes.window_total)" 60
check "the fleet's own jobs: one Fleet Triage run" "$(field "$WORK/plant.json" fleet_jobs.Fleet\ Triage.runs)" 1

# ---- a repository that is not in repos.json never reaches a count, even if its rows are in the data
python3 - "$P" "$WORK/leak" <<'PY'
import json, sys, os, shutil
src, dst = sys.argv[1:]
shutil.copytree(src, dst)
with open(os.path.join(dst, "runs.jsonl"), "a") as fh:
    fh.write(json.dumps({"id": 99, "repo": "hidden", "name": "X", "path": ".github/workflows/x.yml", "event": "push",
                         "status": "completed", "conclusion": "failure", "created_at": "2027-01-16T10:00:00Z",
                         "updated_at": "2027-01-16T10:01:00Z", "run_started_at": "2027-01-16T10:00:00Z", "run_attempt": 1,
                         "sha": "abc", "actor": "owner", "trig": "owner"}) + "\n")
PY
python3 "$S" report "$WORK/leak" --json "$WORK/leak.json" > "$WORK/leak.md"
check "a run in a repository outside repos.json is not counted" "$(field "$WORK/leak.json" runs.all)" 13
check "and its name is not printed" "$(grep -c hidden "$WORK/leak.md")" 0

# ---- compare: two windows side by side, per 24 hours
python3 "$S" compare "$WORK/plant.json" "$WORK/plant.json" > "$WORK/cmp.md"
check "compare prints a header and a row per measure" "$(grep -c '^| ' "$WORK/cmp.md" | awk '{ print ($1 > 20) ? "many" : "few" }')" many
check "compare gives the rate per 24 hours (13 runs in 72 h)" "$(grep '^| runs |' "$WORK/cmp.md" | cut -d'|' -f4 | tr -d ' ')" 4.3

# ---- the collector, against a stand-in for gh
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as fh:
    fh.write(json.dumps(args) + "\n")
mode = os.environ.get("FAKE_MODE", "")
a = args[1:]
def out(x): print(json.dumps(x)); sys.exit(0)
def wf(text): return {"object": {"text": text}}
if a[0] == "graphql":
    query = [x for x in a if x.startswith("query=")][0][6:]
    if "repositories(first: 40" in query:
        nodes = [
            {"name": "alpha", "isFork": False, "isArchived": False, "isPrivate": False, "defaultBranchRef": {"target": {
                "atEnd": {"nodes": [{"oid": "a" * 40}]},
                "inRange": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [
                    {"oid": "1" * 40, "committedDate": "2026-11-12T10:00:00Z", "messageHeadline": "chore(release): v1", "author": {"user": {"login": "acme"}}},
                    {"oid": "2" * 40, "committedDate": "2026-11-13T00:00:00Z", "messageHeadline": "chore(release): v2", "author": {"user": {"login": "acme"}}}]}}}},
            {"name": "forky", "isFork": True, "isArchived": False, "isPrivate": False, "defaultBranchRef": None},
            {"name": "old", "isFork": False, "isArchived": True, "isPrivate": False, "defaultBranchRef": None}]
        if mode == "private":
            nodes.append({"name": "secret-private", "isFork": False, "isArchived": False, "isPrivate": True, "defaultBranchRef": None})
        out({"data": {"user": {"repositories": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}})
    if "entries" in query:
        out({"data": {"r0": {"object": {"entries": [
            {"name": "daily.yml", "type": "blob", "object": {"text": "on:\n  schedule:\n    - cron: \"0 6 * * *\"  # daily\n"}},
            {"name": "fresh.yml", "type": "blob", "object": {"text": "on:\n  schedule:\n    - cron: '37 5 * * 1'\njobs:\n  x:\n    steps:\n      - run: python3 scripts/check-freshness.py\n"}},
            {"name": "README", "type": "blob", "object": {"text": "not a workflow"}},
            {"name": "sub", "type": "tree", "object": None}]}}}})
    if "object(expression" in query:
        out({"data": {"r0": {"object": {"text": "on:\n  schedule:\n    - cron: \"0 3 * * *\"\n"}}}})
    print("fake gh: unexpected graphql", file=sys.stderr); sys.exit(1)
path = a[-1]
if "/actions/runs?" in path:
    def r(i, name, p, event, created, trig, sha):
        return {"id": i, "name": name, "path": ".github/workflows/" + p, "event": event, "status": "completed", "conclusion": "success",
                "created_at": created, "updated_at": created, "run_started_at": created, "run_attempt": 1, "head_sha": sha * 40,
                "actor": {"login": "acme"}, "triggering_actor": {"login": trig}}
    runs = [r(101, "Daily", "daily.yml", "schedule", "2026-11-11T15:00:00Z", "acme", "a"),
            r(102, "Gone", "gone.yml", "schedule", "2026-11-11T14:00:00Z", "acme", "b"),
            r(103, "CI", "ci.yml", "push", "2026-11-11T16:00:00Z", "stranger", "c")]
    out({"total_count": 3, "workflow_runs": runs})
if path.startswith("search/issues"):
    out({"total_count": 3, "items": [
        {"number": 7, "repository_url": "https://api.github.com/repos/acme/alpha", "user": {"login": "someone", "type": "User"},
         "created_at": "2026-11-09T10:00:00Z", "closed_at": None},
        {"number": 8, "repository_url": "https://api.github.com/repos/acme/alpha", "user": {"login": "robot[bot]", "type": "Bot"},
         "created_at": "2026-11-09T10:00:00Z", "closed_at": None},
        {"number": 9, "repository_url": "https://api.github.com/repos/acme/hidden", "user": {"login": "someone", "type": "User"},
         "created_at": "2026-11-09T10:00:00Z", "closed_at": None}]})
if "/issues/7/comments" in path:
    out([{"user": {"login": "acme"}, "created_at": "2026-11-10T09:00:00Z"}, {"user": {"login": "someone"}, "created_at": "2026-11-10T20:00:00Z"}])
if path.startswith("users/acme/settings/billing/usage"):
    def u(day, repo, n): return {"date": day + "T00:00:00Z", "product": "actions", "sku": "Actions Linux", "unitType": "Minutes", "quantity": n, "repositoryName": repo}
    out({"usageItems": [u("2026-11-09", "alpha", 50), u("2026-11-10", "alpha", 10), u("2026-11-11", "alpha", 20), u("2026-11-12", "alpha", 30),
                        u("2026-11-11", "hidden", 999), {"date": "2026-11-11T00:00:00Z", "product": "actions", "sku": "Actions storage",
                                                         "unitType": "GigabyteHours", "quantity": 7, "repositoryName": "alpha"}]})
print("fake gh: unexpected path " + path, file=sys.stderr)
sys.exit(1)
PY
chmod +x "$WORK/bin/gh"
export FAKE_LOG="$WORK/gh.log"
: > "$FAKE_LOG"
PATH="$WORK/bin:$PATH" python3 "$S" collect --owner acme --start 2026-11-10T00:00:00Z --end 2026-11-13T00:00:00Z --out "$WORK/got" 2> "$WORK/collect.err"
check "collect ran against the stand-in" "$?" 0
check "the repository query asks for public repositories only" "$(grep -c 'privacy: PUBLIC' "$FAKE_LOG")" 1
check "a fork and an archive are left out" "$(python3 -c 'import json,sys; print(",".join(r["name"] for r in json.load(open(sys.argv[1]))))' "$WORK/got/repos.json")" alpha
check "a commit at the window's end is not kept" "$(wc -l < "$WORK/got/commits.jsonl" | tr -d ' ')" 1
check "a workflow's cron is read through its comment and quotes" "$(python3 -c '
import json,sys
w = {x["path"]: x for x in map(json.loads, open(sys.argv[1]))}
print(w[".github/workflows/daily.yml"]["crons"], w[".github/workflows/fresh.yml"]["crons"], w[".github/workflows/fresh.yml"]["check_freshness"])' "$WORK/got/workflows.jsonl")" "['0 6 * * *'] ['37 5 * * 1'] True"
check "a file that is not a workflow is not read as one" "$(grep -c README "$WORK/got/workflows.jsonl")" 0
check "a scheduled run whose file is gone is read at the commit the run used" "$(grep gone.yml "$WORK/got/workflows.jsonl" | python3 -c 'import json,sys; x = json.loads(sys.stdin.read()); print(x["crons"], x["read_at"])')" "['0 3 * * *'] bbbbbbb"
check "three runs are kept" "$(wc -l < "$WORK/got/runs.jsonl" | tr -d ' ')" 3
check "a login that is neither the owner's nor a bot's is written as outside" "$(grep -c '"trig": "outside"' "$WORK/got/runs.jsonl")" 1
check "no outsider's login is written anywhere" "$(grep -rl -E 'someone|stranger' "$WORK/got" | wc -l | tr -d ' ')" 0
check "one outside issue kept: not the bot's, not the other repository's" "$(wc -l < "$WORK/got/outside.jsonl" | tr -d ' ')" 1
check "minutes: only the public repository's Actions minutes in the days read" "$(python3 -c '
import json,sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(len(rows), sum(r["minutes"] for r in rows), ",".join(sorted({r["repo"] for r in rows})))' "$WORK/got/minutes.jsonl")" "4 110 alpha"
check "no file written by collect names the private repository" "$(grep -rl -E 'hidden|secret-private' "$WORK/got" | wc -l | tr -d ' ')" 0
python3 "$S" report "$WORK/got" --json "$WORK/got.json" > "$WORK/got.md"
check "what collect wrote can be reported on" "$?" 0
check "the report counts the three runs" "$(field "$WORK/got.json" runs.all)" 3
check "the outsider's question is waiting at the end" "$(field "$WORK/got.json" outside.waiting_at_end)" 1

: > "$FAKE_LOG"
FAKE_MODE=private PATH="$WORK/bin:$PATH" python3 "$S" collect --owner acme --start 2026-11-10T00:00:00Z --end 2026-11-13T00:00:00Z --out "$WORK/priv" 2> "$WORK/priv.err"
check "a private repository coming back from the query stops the collection" "$?" 1
check "and says why, without naming it" "$(grep -c 'private repository came back' "$WORK/priv.err")/$(grep -c secret-private "$WORK/priv.err")" "1/0"
check "nothing was written" "$(ls "$WORK/priv" 2>/dev/null | wc -l | tr -d ' ')" 0
python3 "$S" collect --owner acme --start 2026-11-10T00:00:00Z --end 2099-01-01T00:00:00Z --out "$WORK/future" 2> "$WORK/future.err"
check "a window that has not ended is refused" "$?" 1

# ---- November, through the same code
python3 "$S" report "$FIX" --json "$WORK/nov.json" > "$WORK/nov.md"
check "the report runs on November's recorded sweep" "$?" 0
# The fact file counted 126 repositories, private ones included; these are the
# public 122, so the totals are lower by the private repositories' runs.
check "November: 2,784 runs in the public repositories (the fact file's 2,851 less 67 in private ones)" "$(field "$WORK/nov.json" runs.all)" 2784
check "November: 1,134 scheduled runs" "$(field "$WORK/nov.json" scheduled.all)" 1134
check "November: lateness median 9.0 h" "$(field "$WORK/nov.json" lateness_hours.median)" 9.0
check "November: lateness p90 9.6 h" "$(field "$WORK/nov.json" lateness_hours.p90)" 9.6
check "November: lateness max 9.9 h" "$(field "$WORK/nov.json" lateness_hours.max)" 9.9
check "November: no daily cron time without a run" "$(field "$WORK/nov.json" cron_times.daily_missing)" 0
check "November: 52 streaks ended by a re-run the automation dispatched, as the fact file says" "$(field "$WORK/nov.json" 'red_streaks.ended_by.re-run dispatched by the automation')" 52
check "November: 80 release commits in 48 repositories" "$(field "$WORK/nov.json" releases.release_commits)/$(field "$WORK/nov.json" releases.release_repos)" "80/48"
check "November: 81 pin refreshes and one revert" "$(field "$WORK/nov.json" releases.pin_refresh_commits)/$(field "$WORK/nov.json" releases.reverts)" "81/1"
check "November: no Kubernetes freshness check had a cron time in the window" "$(field "$WORK/nov.json" k8s_freshness.workflows)" 0
check "November: the five runs and the commit of the release that opened the window are the only ones no automation explains" "$(field "$WORK/nov.json" unexplained.runs)/$(field "$WORK/nov.json" unexplained.commits)" "4/1"
check "November: two users waiting at the end, the longest 144.3 h" "$(field "$WORK/nov.json" outside.waiting_at_end)/$(field "$WORK/nov.json" outside.longest_wait_h)" "2/144.3"
check "November: 2,423 Actions minutes a day while stopped, against 10,663 the five days before" "$(field "$WORK/nov.json" minutes.window_per_day)/$(field "$WORK/nov.json" minutes.before_per_day)" "2423/10663"
if [ -f "$BASE" ]; then
  if cmp -s "$BASE" "$WORK/nov.json"; then ok "tests/fixtures/absence-2026-11/summary.json is what the script says about the fixture"
  else no "tests/fixtures/absence-2026-11/summary.json differs from the script's output on the fixture: regenerate it with: scripts/absence-report.py report tests/fixtures/absence-2026-11 --json tests/fixtures/absence-2026-11/summary.json"; fi
else
  no "tests/fixtures/absence-2026-11/summary.json is missing"
fi

# ---- nothing private is in what is committed
if grep -rq -i -E 'secret-private|hidden' "$FIX"; then no "the fixture names a repository that is not public"; else ok "the fixture names no private repository"; fi
check "the fixture holds no e-mail address" "$(grep -rl -E '[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' "$FIX" | wc -l | tr -d ' ')" 0
check "the fixture keeps no login except the owner's kind: owner, outside or a bot" "$(python3 - "$FIX/runs.jsonl" <<'PY'
import json, sys
kinds = set()
for l in open(sys.argv[1]):
    r = json.loads(l)
    kinds |= {r["actor"], r["trig"]}
print(",".join(sorted(k for k in kinds if k not in ("owner", "outside", "unknown") and not k.endswith("[bot]"))))
PY
)" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
