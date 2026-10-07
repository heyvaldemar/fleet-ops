#!/bin/bash
# The heartbeat is the last thing watching the machinery, so its own
# classification has to be shown a violation rather than trusted.
#
# It answers two different questions and they must not be confused. "Did this
# schedule FIRE" is right for the fleet, where a red freshness job is the
# designed alarm. "Did this job RUN AND FAIL" is right for the machinery here,
# where a crash produces no findings, opens no issue and — since the Actions
# failure emails were switched off — reaches nobody at all.
#
# The runs below are fabricated, so the cases that matter can be produced on
# demand instead of waited for.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import datetime
import io
import os
import tempfile
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hb", "scripts/fleet-heartbeat.py")
hb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hb)

now = datetime.datetime.now(datetime.timezone.utc)
def ago(h):
    return (now - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")

passed = failed = 0
def check(what, got, want):
    global passed, failed
    if got == want:
        print("  PASS: %s" % what); passed += 1
    else:
        print("  FAIL: %s\n        got %r, wanted %r" % (what, got, want)); failed += 1

SCENARIOS = {
    # name -> the scheduled runs GitHub would return, newest first
    "green":      [{"conclusion": "success", "created_at": ago(2)}],
    "flaked":     [{"conclusion": "failure", "created_at": ago(1)},
                   {"conclusion": "success", "created_at": ago(5)}],
    "failing":    [{"conclusion": "failure", "created_at": ago(1)},
                   {"conclusion": "failure", "created_at": ago(26)},
                   {"conclusion": "success", "created_at": ago(80)}],
    "nevergreen": [{"conclusion": "failure", "created_at": ago(1)}],
    "running":    [{"conclusion": None, "created_at": ago(1)}],
    "cancelled":  [{"conclusion": "cancelled", "created_at": ago(1)}],
}

def fake_gh(path):
    if path.endswith("/actions/workflows?per_page=100"):
        return {"workflows": [{"path": ".github/workflows/%s.yml" % n, "state": "active", "id": i}
                              for i, n in enumerate(SCENARIOS)]}
    wid = int(path.split("/workflows/")[1].split("/")[0])
    return {"workflow_runs": list(SCENARIOS.values())[wid]}

hb.gh = fake_gh
hb.scheduled_workflows = lambda root: [("%s.yml" % n, 24.0, ["0 6 * * *"]) for n in SCENARIOS]

findings, rows = hb.failing_here("owner/repo", 2.0, now)
state = {n: s for n, s, _ in rows}
named = " ".join(findings)

print("=== which of these is the machinery being broken ===")
check("a green job is not a finding",                      state["green.yml"], "ok")
check("one failure with a recent green is a flake, not a finding", state["flaked.yml"], "flaked")
check("failing since before its own interval is a finding", state["failing.yml"], "FAILING")
check("a job that has never been green is a finding",      state["nevergreen.yml"], "FAILING")
check("a run still going is not judged",                   state["running.yml"], "ok")
check("a cancelled run is not a failure",                  state["cancelled.yml"], "ok")
check("exactly the two broken ones are named",             len(findings), 2)
check("and the flake is not among them",                   "flaked.yml" in named, False)
check("the finding says how long since it was green",      "hours ago" in named, True)

print()
print("=== the two gaps the Actions mail used to cover ===")
# Triage walks -docker-compose, -docker and -terraform. Everything else has no
# report of its own, so a red run there reaches nobody now.
check("a template repository is triage's to report",  bool(hb.TRIAGED.search("zammad-traefik-letsencrypt-docker-compose")), True)
check("so is a terraform pipeline",                   bool(hb.TRIAGED.search("amazon-rds-pipeline-terraform")), True)
check("an operations tool is nobody's",               bool(hb.TRIAGED.search("deadman-switch")), False)
check("and neither is the profile repository",        bool(hb.TRIAGED.search("heyvaldemar")), False)

# A pull request nobody merged. Three repositories have no automerge workflow
# at all, so theirs wait for a human who is no longer being told.
def fake_prs(full):
    if full.endswith("stuck"):
        return [{"user": {"login": "dependabot[bot]"}, "number": 59,
                 "created_at": ago(36), "title": "ci: bump an action"}], None
    if full.endswith("fresh"):
        return [{"user": {"login": "dependabot[bot]"}, "number": 60,
                 "created_at": ago(2), "title": "ci: bump an action"}], None
    if full.endswith("human"):
        return [{"user": {"login": "heyvaldemar"}, "number": 61,
                 "created_at": ago(200), "title": "a change of my own"}], None
    if full.endswith("unreadable"):
        return [], "HTTP 500"
    return [], None

hb.open_prs = fake_prs
out = hb.stuck_dependabot("o", ["o/stuck", "o/fresh", "o/human", "o/unreadable"], now)
# Two findings from four repositories: the stuck pull request and the one that
# could not be read. The fresh one and the human's are not findings.
check("a Dependabot pull request open for 36 hours is a finding",
      len([o for o in out if "#59" in o]), 1)
check("and exactly two of the four repositories produce one", len(out), 2)
check("and it names the repository and the age",     "o/stuck#59" in out[0] and "36 hours" in out[0], True)
check("one opened two hours ago is not",             "fresh" in " ".join(out), False)
check("and a human's long-open pull request is not", "human" in " ".join(out), False)
# A repository whose pull requests cannot be read is not a repository with
# none. Silence there would mean nothing is watching it and nothing says so.
check("a repository that could not be read is reported, not skipped",
      any("unreadable" in o and "cannot read" in o for o in out), True)

print()
print("=== the watch list drifting back ===")
# GitHub subscribes the creator of a repository and there is no setting to opt
# out: the checkbox the documentation used to describe is gone from the
# notification page and from the documentation. So the policy is asserted here
# rather than remembered.
def subs(*names):
    return lambda path: [{"full_name": n, "owner": {"login": n.split("/")[0]}} for n in names]

hb.gh = subs("heyvaldemar/fleet-ops")
check("watching only fleet-ops is the intended state", hb.watch_drift(), [])

hb.gh = subs("heyvaldemar/fleet-ops", "aerabi/docker-security-book")
check("somebody else's repository is a decision, not drift", hb.watch_drift(), [])

hb.gh = subs("heyvaldemar/fleet-ops", "heyvaldemar/a-new-tool")
out = hb.watch_drift()
check("one of his own beyond fleet-ops is drift", len(out), 1)
check("and it is named",  "heyvaldemar/a-new-tool" in out[0], True)
hb.gh = subs("heyvaldemar/fleet-ops", "heyvaldemar/fleet-ops-private")
check("the house copy is watched on purpose, not drift", hb.watch_drift(), [])

print()
print("=== the order GitHub returns runs in is not a contract ===")
# On 2026-09-15 at 18:03 a request for the single most recent scheduled run of
# sops-env-git's tests.yml came back with the run from three days earlier, and
# this file reported a workflow that had run that morning as having stopped 81
# hours ago. Ten minutes later the same request answered correctly. Every
# scenario above hands its runs over already sorted, so not one of them could
# have caught it. These hand them over shuffled.
OUT_OF_ORDER = {
    # The success is oldest but arrives first, which is exactly the shape that
    # produced the false alarm.
    "shuffled": [{"conclusion": "success", "created_at": ago(80)},
                 {"conclusion": "failure", "created_at": ago(1)},
                 {"conclusion": "failure", "created_at": ago(26)}],
}

def shuffled_gh(path):
    if path.endswith("/actions/workflows?per_page=100"):
        return {"workflows": [{"path": ".github/workflows/%s.yml" % n, "state": "active", "id": i}
                              for i, n in enumerate(OUT_OF_ORDER)]}
    wid = int(path.split("/workflows/")[1].split("/")[0])
    return {"workflow_runs": list(OUT_OF_ORDER.values())[wid]}

hb.gh = shuffled_gh
hb.scheduled_workflows = lambda root: [("%s.yml" % n, 24.0, ["0 6 * * *"]) for n in OUT_OF_ORDER]
sh_findings, sh_rows = hb.failing_here("owner/repo", 2.0, now)
check("a failing job whose runs arrive out of order is still a finding",
      {n: st for n, st, _ in sh_rows}["shuffled.yml"], "FAILING")

# And the same question for "when did it last fire", which is the one that
# actually went wrong: the newest run by date, not whichever came back first.
hb.gh = lambda path: {"workflow_runs": [{"conclusion": "success", "created_at": ago(81)},
                                        {"conclusion": "success", "created_at": ago(8)}]}
fired_age = (now - hb.last_fired("owner/repo", 1)).total_seconds() / 3600
check("last fired reads the newest run, not the first one returned",
      round(fired_age), 8)

# THE PAGE ITSELF CAN BE WRONG, not merely its order. On 2026-09-16 a request
# for the ten most recent scheduled runs of keycloak's verification came back
# holding a run from 13 July, and the heartbeat reported a workflow that had
# fired ninety minutes earlier as having stopped 1564 hours ago. Sorting ten
# records cannot rescue a page that holds the wrong ten, so the question is
# asked with a date window and the server decides what is inside it.
def windowed(path):
    if "created=" in path:
        return {"workflow_runs": [{"conclusion": "success", "created_at": ago(2)}]}
    return {"workflow_runs": [{"conclusion": "success", "created_at": ago(1564)}]}
hb.gh = windowed
fired_age = (now - hb.last_fired("owner/repo", 1)).total_seconds() / 3600
check("a page holding an ancient run cannot invent a stopped schedule",
      round(fired_age), 2)

# ...and a schedule that really has stopped must still be found, which is the
# half a date window can quietly break.
hb.gh = lambda path: ({"workflow_runs": []} if "created=" in path
                      else {"workflow_runs": [{"conclusion": "success", "created_at": ago(1564)}]})
fired_age = (now - hb.last_fired("owner/repo", 1)).total_seconds() / 3600
check("nothing inside the window still reports the old run, not silence",
      round(fired_age), 1564)

hb.gh = lambda path: {"workflow_runs": []}
check("a workflow that never fired on a schedule stays None",
      hb.last_fired("owner/repo", 1), None)

print()
print("=== the three files every repository here is supposed to carry ===")
# There was no rule for this anywhere. chatops-privilege-wall had been live for
# four days with none of the three, the conformance check walks it by name and
# has nothing to say about these files, and nothing else looks. The gap was not
# a check that failed; it was a question nobody had asked, which is the kind
# that survives any number of green runs.
FULL = {"scorecard.yml", "dependabot-automerge.yml", "deployment-verification.yml"}
check("a repository carrying all three is not a finding",
      hb.missing_standard_files(FULL, True), [])
check("a missing Scorecard workflow is named",
      hb.missing_standard_files(FULL - {"scorecard.yml"}, True), ["scorecard.yml"])
check("so is a missing automerge",
      hb.missing_standard_files(FULL - {"dependabot-automerge.yml"}, True),
      ["dependabot-automerge.yml"])
check("so is a missing Dependabot config, which is a file and not a workflow",
      hb.missing_standard_files(FULL, False), [".github/dependabot.yml"])
check("and a repository with none of them names all three",
      len(hb.missing_standard_files({"deployment-verification.yml"}, False)), 3)
# A repository's own verification is not on the list: it is called different
# things in different repositories here, and a rule that insisted on one name
# would fail eighty-seven of them for spelling.
check("the repository's own verification is not required to have one name",
      hb.missing_standard_files({"scorecard.yml", "dependabot-automerge.yml"}, True), [])
# 2026-09-24: nine public repositories had no SECURITY.md and 91 had no rule
# on main, both read off OpenSSF Scorecard, and nothing here had asked.
check("a missing security policy is named",
      hb.missing_standard_files(FULL, True, False), ["SECURITY.md"])
check("and a repository with everything but the policy names only that",
      hb.missing_standard_files(FULL, True, True), [])
check("main with both rules is not a finding",
      hb.missing_branch_rules({"non_fast_forward", "deletion", "pull_request"}), [])
check("main that can be force-pushed is",
      hb.missing_branch_rules({"deletion"}), ["non_fast_forward"])
check("main with no rules at all names both",
      hb.missing_branch_rules(set()), ["non_fast_forward", "deletion"])
# A repository that publishes releases signs them; one that has none is not
# asked to.
check("a repository with releases and no release workflow is named",
      hb.missing_standard_files(FULL, True, True, True), ["release-assets.yml"])
check("one that carries it is not",
      hb.missing_standard_files(FULL | {"release-assets.yml"}, True, True, True), [])
check("and one with no release is not asked for it",
      hb.missing_standard_files(FULL, True, True, False), [])
# A policy that sends a reporter to a 404 has no channel (2026-09-25: every
# SECURITY.md in the fleet did, since April).
check("every URL in a policy is read, trailing punctuation dropped",
      hb.policy_links("Send to https://a.example/x. Or (https://b.example/y), see https://c.example/z;"),
      ["https://a.example/x", "https://b.example/y", "https://c.example/z"])
check("a URL inside a code fence or a code span is an argument, not a link",
      hb.policy_links("Verify:\n```\ncosign verify --certificate-identity-regexp \"https://github.com/o/r/.*\" \\\n  --certificate-oidc-issuer \"https://token.actions.githubusercontent.com\"\n```\nThen `curl https://in.code/` and see https://real.example/page."),
      ["https://real.example/page"])
check("a URL that answers 200 is not a finding",
      hb.dead_links(["https://ok.example/"], fetch=lambda u: 200, cache={}), [])
check("a redirect is an answer",
      hb.dead_links(["https://moved.example/"], fetch=lambda u: 301, cache={}), [])
check("a 404 is",
      hb.dead_links(["https://gone.example/", "https://ok.example/"], fetch=lambda u: 404 if "gone" in u else 200, sleep=lambda s: None, cache={}),
      ["https://gone.example/"])
check("and so is a host that does not answer at all",
      hb.dead_links(["https://down.example/"], fetch=lambda u: 0, sleep=lambda s: None, cache={}), ["https://down.example/"])
# 2026-09-26: one of ninety-seven identical requests went unanswered and a
# page that answered 200 before and after was reported dead.
answers = iter([0, 200])
check("one missed answer, then 200, is not a dead link",
      hb.dead_links(["https://flaky.example/"], fetch=lambda u: next(answers), sleep=lambda s: None, cache={}), [])
asked = []
shared = {}
for _ in range(97):
    hb.dead_links(["https://same.example/security/"], fetch=lambda u: asked.append(u) or 200, sleep=lambda s: None, cache=shared)
check("the same URL in ninety-seven policies is asked once", len(asked), 1)
check("and a dead one stays dead on the second asking",
      hb.dead_links(["https://gone2.example/"], fetch=lambda u: 404, sleep=lambda s: None, cache={}), ["https://gone2.example/"])

print()
print("=== the list of watchers may only change on purpose ===")
# 2026-09-24: a commit from a broken clone deleted six workflows and the
# heartbeat watched the shorter list without a word.

_d = tempfile.mkdtemp(); os.makedirs(os.path.join(_d, ".github/workflows"))
for _n in ("a.yml", "b.yml"):
    open(os.path.join(_d, ".github/workflows", _n), "w").write("on: push\n")
_m = os.path.join(_d, "expected.txt"); open(_m, "w").write("# comment\na.yml\nb.yml\n")
check("a checkout that matches its manifest is not a finding", hb.manifest_drift(_d, _m), [])
os.remove(os.path.join(_d, ".github/workflows/b.yml"))
check("a workflow named and missing is", hb.manifest_drift(_d, _m),
      ["b.yml is named in scripts/expected-workflows.txt and is not in the checkout"])
open(os.path.join(_d, ".github/workflows/c.yml"), "w").write("on: push\n")
check("and one present and unnamed is too", len(hb.manifest_drift(_d, _m)), 2)
check("the real manifest matches the real checkout", hb.manifest_drift(os.path.join(os.path.dirname(os.path.abspath("scripts/fleet-heartbeat.py")), "..")), [])

print()
print("=== a head nothing has verified ===")
# A merge pushed with GITHUB_TOKEN triggers no workflow. The automerge now
# dispatches the verification itself; this is the check on that, because if
# the dispatch ever stops working nothing else will say so.
def head_gh(path):
    if "/check-runs" in path:
        return {"total_count": 0 if "/bare" in path else 1}
    repo = path.split("/commits/")[0].split("repos/")[1]
    sha = "bare0000" if repo.endswith("unverified") else "seen0000"
    if repo.endswith("fresh"):
        return {"sha": "bare0000fresh", "commit": {"committer": {"date": ago(1)}}}
    return {"sha": sha + "old", "commit": {"committer": {"date": ago(30)}}}
hb.gh = lambda path: head_gh(path.replace("/commits/bare0000old/", "/commits/bare/").replace("/commits/bare0000fresh/", "/commits/bare/"))
hb.DEFAULT_BRANCH.clear()
heads = hb.unverified_heads("o", ["o/unverified", "o/verified", "o/fresh"], now)
check("a day-old head with no check on it is a finding", len([h for h in heads if "o/unverified" in h]), 1)
check("a head that carries a check is not",            len([h for h in heads if "o/verified" in h]), 0)
check("a head an hour old is given time to be checked", len([h for h in heads if "o/fresh" in h]), 0)
check("and nothing else was invented",                  len(heads), 1)

print()
print("=== a token that cannot read is one finding, not one per repository ===")
# Widening the listing to private repositories found eleven of them the PAT
# cannot reach, and the first version reported eleven lines for one fact —
# the shape this file already refuses elsewhere.
hb.open_prs = lambda full: (None, "gh: Resource not accessible by personal access token (HTTP 403)")
blind = hb.stuck_dependabot("o", ["o/a", "o/b", "o/c"], now)
check("three unreadable repositories are one line", len(blind), 1)
check("and it names all three", all(n in blind[0] for n in ("a", "b", "c")), True)
check("and it says what to do about it", "Widen the fine-grained PAT" in blind[0], True)
hb.open_prs = lambda full: ([], None)
check("nothing unreadable, nothing said", hb.stuck_dependabot("o", ["o/a"], now), [])

print()
print("=== a gap somebody accepted, against one nobody has ===")
# The heartbeat ran red twice a day from 2026-09-18 for one reason: eleven
# repositories its token cannot read, which is a decision only the account's
# owner can make. Red every day cannot also mean "a watcher died last night",
# so an accepted gap is reported without turning the run red. The whole risk
# of that is a gap sliding in unnoticed, so it is the growth that gets tested.
hb.open_prs = lambda full: (None, "gh: Resource not accessible by personal access token (HTTP 403)")
hb.known_gaps = lambda: {"a", "b"}

accepted = hb.stuck_dependabot("o", ["o/a", "o/b"], now)
check("a gap named in known-gaps.txt is still reported", len(accepted), 1)
check("and it is marked standing",            hb.is_standing(accepted[0]), True)
check("and standing does not turn a run red", hb.report(accepted), 0)

grown = hb.stuck_dependabot("o", ["o/a", "o/b", "o/c"], now)
check("one repository more than the list is NOT standing", hb.is_standing(grown[0]), False)
check("and it names the one nobody accepted",  "Nobody has accepted this: c" in grown[0], True)
check("and it turns the run red",              hb.report(grown), 1)

# Mixed: the accepted gap must not drag a real finding down with it, and a
# real finding must not drag the accepted one up.
mixed = ["o/x#1 has been open 40 hours: something"] + accepted
check("one real finding beside a standing one is still red", hb.report(mixed), 1)

# An absent baseline means nothing has been accepted. Reading it as "all
# accepted" would turn a deleted file into a permanently green heartbeat.
hb.known_gaps = lambda: set()
check("with no list at all, nothing is standing",
      hb.is_standing(hb.stuck_dependabot("o", ["o/a"], now)[0]), False)

# A NAME THAT NO LONGER EARNS ITS PLACE. The day the token's access is widened
# every accepted name stops being a gap, and a list that keeps accepting them
# would wave the same repository through if it ever fell out of reach again.
hb.known_gaps = lambda: {"a", "b"}
hb.open_prs = lambda full: ([], None)
hb.known_gaps = lambda: {"a", "b", "c"}   # c is not in this run at all
settled = hb.stuck_dependabot("o", ["o/a", "o/b"], now)
check("a repository that became readable is reported", len(settled), 1)
check("and it names the lines to delete",  bool(settled) and "a, b" in settled[0], True)
# Asserting `"c" not in text` would pass or fail on the letter c in "scripts"
# and "reach". The count is the claim: two of the three names were read.
check("a name it never managed to read is not called stale",
      settled[0].split("unwatched: ")[1].split(".")[0] if settled else "<no such finding>", "a, b")
check("and the count agrees with the names", bool(settled) and "read 2 repository(ies)" in settled[0], True)
check("and it is not standing — it is one edit away", bool(settled) and hb.is_standing(settled[0]), False)

# Half readable, half not: each half is said in its own terms, and only the
# still-unreadable half is the accepted one.
def half(full):
    return ([], None) if full.endswith("a") else (None, "HTTP 403")
hb.open_prs = half
mixed = hb.stuck_dependabot("o", ["o/a", "o/b"], now)
check("both halves are reported", len(mixed), 2)
stale = [m for m in mixed if "still accepts as unwatched" in m]
check("exactly one of them is the stale-list finding", len(stale), 1)
check("and it names only the readable half",
      stale[0].split("unwatched: ")[1].split(".")[0] if stale else "<no such finding>", "a")
check("the unreadable one is still standing",
      [hb.is_standing(m) for m in mixed].count(True), 1)

# Nothing accepted, nothing readable to complain about.
hb.known_gaps = lambda: set()
hb.open_prs = lambda full: ([], None)
check("an empty list produces no stale-line finding", hb.stuck_dependabot("o", ["o/a"], now), [])

# The file that ships must actually name what the fleet is accepting today,
# or the comment above describes a list that is not there.
import importlib.util as _il
spec2 = _il.spec_from_file_location("hb2", "scripts/fleet-heartbeat.py")
hb2 = _il.module_from_spec(spec2); spec2.loader.exec_module(hb2)
shipped = hb2.known_gaps()
# NOT "the list is not empty": empty is the healthy state, and it is empty
# today. What has to hold whatever is in it is that every entry is a bare
# repository name — an owner/name pair or a stray comment would silently
# accept nothing while looking like an acceptance.
check("every accepted entry is a bare repository name",
      all("/" not in n and not n.startswith("#") for n in shipped), True)
check("and none of them is blank",     all(n.strip() for n in shipped), True)

print()
print("=== a windowed answer that is older than the truth ===")
# On 2026-09-22 the date-filtered query answered for one repository's daily
# verification with nothing newer than the 18th, while runs from the 19th,
# 20th, 21st and 22nd sat in the same repository — the last of them two hours
# before the run that asked. The report said a daily schedule had been silent
# for ninety-eight hours. That is the one alarm here that has to be believed,
# and a false one costs more than a missed one.
#
# A run that EXISTS proves the schedule fired; an absent one proves nothing.
# So a stale-looking windowed answer is confirmed against an unwindowed query
# and the newer of the two is kept.
def runs_at(*stamps):
    return {"workflow_runs": [{"created_at": s, "run_started_at": s} for s in stamps]}

def paged(windowed, unwindowed):
    def g(path):
        return runs_at(*windowed) if "created=" in path else runs_at(*unwindowed)
    return g

old = ago(98)
fresh = ago(3)
hb.gh = paged([old], [fresh, old])
got = hb.last_fired("o/r", 1)
check("a stale window is corrected by the second ask",
      abs((now - got).total_seconds() / 3600 - 3) < 0.2, True)

# The confirm must not be able to make an answer OLDER.
hb.gh = paged([fresh], [old])
got = hb.last_fired("o/r", 1)
check("and a fresh answer is never dragged backwards",
      abs((now - got).total_seconds() / 3600 - 3) < 0.2, True)

# A genuinely stopped schedule must still be reported: both asks agree.
hb.gh = paged([ago(200)], [ago(200)])
got = hb.last_fired("o/r", 1)
check("a schedule that really stopped is still old",
      (now - got).total_seconds() / 3600 > 100, True)

# The second ask costs a request, so it is only made when it could change the
# answer. A fresh windowed result must not trigger it.
asked = []
def counting(path):
    asked.append(path)
    return runs_at(fresh) if "created=" in path else runs_at(ago(1))
hb.gh = counting
hb.last_fired("o/r", 1)
check("a fresh answer is not confirmed twice", len(asked), 1)

# 2026-10-07 14:27: both event=schedule asks were stale, the windowed one at
# the 4th and the unwindowed one, an hour later, at July, while the plain list
# of the workflow's runs held a scheduled run from ninety minutes before.
def three(windowed, by_event, plain):
    def g(path):
        if "created=" in path:
            return runs_at(*windowed)
        if "event=" in path:
            return runs_at(*by_event)
        return {"workflow_runs": plain}
    return g

hb.gh = three([ago(74)], [ago(2000)], [{"created_at": ago(1), "event": "push"},
                                       {"created_at": ago(1.5), "event": "schedule"},
                                       {"created_at": ago(74), "event": "schedule"}])
got = hb.last_fired("o/r", 1)
check("a stale event filter is corrected by the plain list",
      abs((now - got).total_seconds() / 3600 - 1.5) < 0.2, True)

hb.gh = three([ago(74)], [ago(74)], [{"created_at": ago(1), "event": "push"}])
got = hb.last_fired("o/r", 1)
check("a fresh push is not taken for a fired schedule",
      abs((now - got).total_seconds() / 3600 - 74) < 0.2, True)

hb.gh = three([], [], [{"created_at": ago(2), "event": "schedule"}])
got = hb.last_fired("o/r", 1)
check("an empty window is answered by the plain list as well",
      got is not None and abs((now - got).total_seconds() / 3600 - 2) < 0.2, True)

# The same stale filter, deciding whether this repository's own workflows
# are red: last week's failure must not read as the current state when the
# plain list holds a newer success.
def two(filtered, plain):
    def g(path):
        return {"workflow_runs": filtered if "event=" in path else plain}
    return g

hb.gh = two([{"id": 1, "created_at": ago(150), "event": "schedule", "conclusion": "failure"}],
            [{"id": 2, "created_at": ago(3), "event": "schedule", "conclusion": "success"},
             {"id": 1, "created_at": ago(150), "event": "schedule", "conclusion": "failure"}])
runs = hb.runs_of("o/r", 1, "schedule")
check("the newest run from either list is the latest", (runs[0]["id"], runs[0]["conclusion"]), (2, "success"))
check("and a run both lists hold is counted once", len(runs), 2)

hb.gh = two([], [{"id": 5, "created_at": ago(1), "event": "push", "head_branch": "dependabot/x", "conclusion": "failure"},
                 {"id": 4, "created_at": ago(2), "event": "push", "head_branch": "main", "conclusion": "success"}])
runs = hb.runs_of("o/r", 1, "push", branch="main", n=1)
check("a push on another branch is not main's state", [r["id"] for r in runs], [4])

print()
print("=== the listing that decides what gets checked at all ===")
# Two Dependabot pull requests sat on heyvaldemar-com, the live website, for
# four and seven days on 2026-09-18, one green and mergeable the whole time.
# No check failed. The listing simply never handed that repository over,
# because /users/OWNER/repos is public-only whatever the token can see.
PAGES = [[{"full_name": "o/pub", "archived": False, "fork": False, "private": False, "default_branch": "main"},
          {"full_name": "o/priv", "archived": False, "fork": False, "private": True, "default_branch": "main"},
          {"full_name": "o/old", "archived": True, "fork": False, "private": False, "default_branch": "main"},
          {"full_name": "o/theirs", "archived": False, "fork": True, "private": False, "default_branch": "main"}]]
seen = []
def listing_gh(path):
    seen.append(path)
    return PAGES[0] if "page=1" in path else []
hb.gh = listing_gh
check("the public sweep leaves private repositories out", hb.list_owned(False), ["o/pub"])
check("the stuck-pull-request check takes them in",       sorted(hb.list_owned(True)), ["o/priv", "o/pub"])
check("archived and forked are out of both",              [r for r in hb.list_owned(True) if r in ("o/old", "o/theirs")], [])
check("and it asks the endpoint that can see them at all",
      all("user/repos?affiliation=owner" in p for p in seen), True)

print()
print("=== looked at nothing, or found nothing ===")
# A 45-hour-old Dependabot pull request on gaseous-server sat through a run
# that reported the fleet clean on 2026-09-20, and nothing in the output could
# say whether the check had examined that repository at all. The two answers
# must never print the same way.
hb.open_prs = lambda full: ([{"user": {"login": "dependabot[bot]"},
                              "number": 1, "created_at": ago(45),
                              "title": "bump"}], None)
st = {}
found = hb.stuck_dependabot("o", ["o/a", "o/b"], now, stats=st)
check("it says how many it was given",      st["given"], 2)
check("and how many it managed to read",    st["read"], 2)
check("and how many pull requests it saw",  st["prs"], 2)
check("and the stuck ones are findings",    len(found), 2)

hb.open_prs = lambda full: (None, "HTTP 403")
st = {}
hb.stuck_dependabot("o", ["o/a", "o/b"], now, stats=st)
check("a run that read nothing says so in the count", (st["read"], st["prs"]), (0, 0))

# A listing that hands over nothing leaves this check with nothing to report
# and no way to tell that apart from a quiet fleet. Every other blindness here
# is already named; this one had no voice at all.
check("being handed no repositories is itself a finding",
      len(hb.stuck_dependabot("o", [], now)), 1)
check("and it blames the listing, not the fleet",
      "listing being broken" in hb.stuck_dependabot("o", [], now)[0], True)

print()
print("=== the second credential, for the one check that only reads ===")
# Widening the token the fleet already runs on would hand every job that
# writes the same reach into the home-lab config and the live website. This
# check needs Pull requests: read and nothing else, so it may be answered by a
# separate read-only token — and must behave exactly as before when there is
# none, which is the state on the day this shipped.
check("a read-only token is used when there is one",
      hb.pr_env({"GH_TOKEN": "main", "FLEET_READ_TOKEN": "ro"})["GH_TOKEN"], "ro")
check("and gh is left nothing else to prefer",
      "GITHUB_TOKEN" in hb.pr_env({"GH_TOKEN": "m", "GITHUB_TOKEN": "g", "FLEET_READ_TOKEN": "ro"}), False)
check("with none, the environment is untouched",
      hb.pr_env({"GH_TOKEN": "main"})["GH_TOKEN"], "main")
check("an empty one counts as none rather than as a token",
      hb.pr_env({"GH_TOKEN": "main", "FLEET_READ_TOKEN": ""})["GH_TOKEN"], "main")
# The token must not travel anywhere but the environment. Read from the file:
# earlier cases replace open_prs with a stub, and inspect cannot show source
# for that — the assertion would fail on the stub rather than on the code.
src = io.open("scripts/fleet-heartbeat.py", encoding="utf-8").read()
seam = src.split("def pr_env(")[1].split("\ndef unverified_heads")[0]
check("nothing in the token seam prints", "print(" in seam, False)
check("and the read token is only ever moved into an environment",
      seam.count("READ_TOKEN"), 2)

print()
print("=== this job going red is not news about this job ===")
# It fails on purpose whenever it finds something, so its own red run arrived
# as a second finding underneath the first, saying only that the report above
# exists. A crash is different and has to stay loud.
#
# The first version of this asked whether a report was open, which loops: that
# report would hold nothing but this finding, close for having nothing to say,
# and reopen on the next run. What separates the two is WHICH STEP failed.
import json as _json
import subprocess as _real_sub

class _Sub:
    # Stands in for the module, so it carries what the code reads off it.
    PIPE = _real_sub.PIPE
    CalledProcessError = _real_sub.CalledProcessError
    def __init__(self, answer): self.answer, self.env = answer, None
    def check_output(self, argv, stderr=None, env=None):
        self.env = env
        if self.answer is None:
            raise _real_sub.CalledProcessError(1, "gh")
        return _json.dumps(self.answer).encode()

def jobs_with(*failed_steps):
    return {"jobs": [{"steps": [{"name": n, "conclusion": "failure"} for n in failed_steps]
                      + [{"name": "Checkout repository", "conclusion": "success"}]}]}

real_sub = hb.subprocess

hb.subprocess = _Sub(jobs_with(hb.REPORT_STEP))
own = hb.explained(hb.OWN_WORKFLOW, "fleet-heartbeat.yml last succeeded 53 hours ago", 99)
check("the reporting step failing is this job finding something", hb.is_standing(own), True)
check("and it says which step that was", "reporting step" in own, True)

hb.subprocess = _Sub(jobs_with("Every public repository's schedules"))
check("any other step failing is a crash and stays loud",
      hb.is_standing(hb.explained(hb.OWN_WORKFLOW, "x", 99)), False)

hb.subprocess = _Sub(jobs_with(hb.REPORT_STEP, "Every public repository's schedules"))
check("the reporting step plus a crash is still a crash",
      hb.is_standing(hb.explained(hb.OWN_WORKFLOW, "x", 99)), False)

hb.subprocess = _Sub({"jobs": [{"steps": [{"name": "a", "conclusion": "success"}]}]})
check("a red run with no failing step is not explained away",
      hb.is_standing(hb.explained(hb.OWN_WORKFLOW, "x", 99)), False)

hb.subprocess = _Sub(None)
check("and a lookup that fails stays loud rather than quiet",
      hb.is_standing(hb.explained(hb.OWN_WORKFLOW, "x", 99)), False)

hb.subprocess = _Sub(jobs_with(hb.REPORT_STEP))
check("another workflow's failure is never explained away",
      hb.explained("verify.yml", "verify.yml has failed", 99), "verify.yml has failed")
check("and with no run to look at, nothing is explained away",
      hb.explained(hb.OWN_WORKFLOW, "x"), "x")

# A STEP NAME IS A STRING IN TWO FILES. Rename the step in the workflow and
# this rule silently stops matching: every red run becomes a crash again, and
# the noise comes back with no test to notice.
wf = io.open(".github/workflows/fleet-heartbeat.yml", encoding="utf-8").read()
check("the step this rule names still exists in the workflow",
      ("- name: %s" % hb.REPORT_STEP) in wf, True)

# THE LOOKUP HAS TO BE ASKED WITH A TOKEN THAT CAN ANSWER. This step runs on
# the fleet credential, which is scoped to the repositories it maintains and
# cannot read this one.
seen = _Sub(jobs_with(hb.REPORT_STEP))
hb.subprocess = seen
os.environ["GH_TOKEN"] = "fleet"
os.environ[hb.SELF_TOKEN] = "own"
hb.explained(hb.OWN_WORKFLOW, "x", 99)
check("the repository's own token asks about its own run", seen.env["GH_TOKEN"], "own")
del os.environ[hb.SELF_TOKEN]
seen.env = None
hb.explained(hb.OWN_WORKFLOW, "x", 99)
check("with none supplied it falls back to whatever the job runs on", seen.env["GH_TOKEN"], "fleet")
hb.subprocess = real_sub

print()
print("=== 404 is not an answer about pull requests ===")
# 105 of 105 repositories read, 0 open pull requests seen, clean report — while
# a 45-hour-old Dependabot pull request sat on gaseous-server. GitHub answers
# 404 rather than 403 when a credential may not know a repository exists, and
# this read it as "there are none". The credential loop made it worse by
# returning on the first 404 instead of trying the next one.
import importlib.util as _il2, subprocess as _sp
spec3 = _il2.spec_from_file_location("hb3", "scripts/fleet-heartbeat.py")
hb3 = _il2.module_from_spec(spec3); spec3.loader.exec_module(hb3)

class Boom(_sp.CalledProcessError):
    def __init__(self, text):
        _sp.CalledProcessError.__init__(self, 1, "gh", stderr=text.encode())

def fake_gh(answers):
    """answers: path fragment -> either a JSON string or an error text."""
    calls = []
    def run(argv, stderr=None, env=None):
        path = argv[2]
        calls.append((path, (env or {}).get("GH_TOKEN")))
        a = answers(path, (env or {}).get("GH_TOKEN"))
        if isinstance(a, str) and a.startswith("ERR:"):
            raise Boom(a[4:])
        return a.encode()
    return run, calls

os.environ["GH_TOKEN"] = "main"
os.environ[hb3.READ_TOKEN] = "ro"

# The read token 404s, the ambient one can answer: the answer must be used.
run, calls = fake_gh(lambda path, tok: "ERR:HTTP 404: Not Found" if tok == "ro" else '[{"n": 1}]')
hb3.subprocess.check_output = run
prs, err = hb3.open_prs("o/r")
check("a 404 from one credential does not end the question", (len(prs), err), (1, None))
check("and the second credential was actually tried", len(calls) >= 2, True)

# Every credential 404s while the repository itself reads. That is TWO facts
# wearing one status code, and this file has now been wrong about it in both
# directions. A pull request is an issue on GitHub, so turning Issues off takes
# the pull request endpoint with it and the repository answers 404 to anyone.
# The other cause is a credential without the Pull requests permission, which
# GitHub also reports as 404 rather than 403 here.
#
# Measured across all 105 repositories on the account: issues on, the endpoint
# answered 103 of 103; issues off, it refused 2 of 2. No exceptions.
run, _ = fake_gh(lambda path, tok: '{"name": "r", "has_issues": true}' if path == "repos/o/r" else "ERR:HTTP 404: Not Found")
hb3.subprocess.check_output = run
check("issues on and the list refused is the permission missing",
      hb3.open_prs("o/r"), ([], hb3.NO_PR_PERMISSION))

run, _ = fake_gh(lambda path, tok: '{"name": "r", "has_issues": false}' if path == "repos/o/r" else "ERR:HTTP 404: Not Found")
hb3.subprocess.check_output = run
check("issues off is its own answer, not the permission and not silence",
      hb3.open_prs("o/r"), ([], hb3.NO_PR_FEATURE))

# DEPENDABOT DOES NOT KNOW EITHER, and that is the part that costs something.
# It clones, finds an update, pushes a branch, and fails to open the pull
# request that would deliver it — quietly, on a schedule. Two repositories here
# carried one from 2026-09-06 holding action digest bumps with nowhere to go.
real3 = hb3.open_prs          # put back below: the cases after this call it
hb3.open_prs = lambda full: ([], hb3.NO_PR_FEATURE)
hb3.dependabot_branches = lambda full: ["dependabot/github_actions/group-abc"]
stranded = hb3.stuck_dependabot("o", ["o/a"], now)
check("a branch that can never become a pull request is a finding", len(stranded), 1)
check("and it names the branch",  "dependabot/github_actions/group-abc" in stranded[0], True)
check("and it says why, not just what", "a pull request is an issue" in stranded[0], True)
check("and it offers the ways out", "Merge the branch" in stranded[0], True)

hb3.dependabot_branches = lambda full: []
check("issues off with no stranded branch says nothing at all",
      hb3.stuck_dependabot("o", ["o/a"], now), [])
hb3.open_prs = real3

# And it is collapsed into one line that names the fix, not one per repository.
# The real function is put back afterwards: the cases below call it, and a stub
# left in place makes them assert against the stub instead.
real_open_prs = hb3.open_prs
hb3.open_prs = lambda full: ([], hb3.NO_PR_PERMISSION)
st3 = {}
refused = hb3.stuck_dependabot("o", ["o/a", "o/b", "o/c"], now, stats=st3)
check("three refusals are one finding", len(refused), 1)
check("and it counts them",             st3["denied"], 3)
check("and none of them counts as read", st3["read"], 0)
check("and it names the permission to grant",
      "Pull requests: Read-only" in refused[0], True)
check("and the secret to grant it on",  "FLEET_READ_PAT" in refused[0], True)
hb3.open_prs = real_open_prs

# Nothing can see it at all: that is an error, and the old code called it "none".
run, _ = fake_gh(lambda path, tok: "ERR:HTTP 404: Not Found")
hb3.subprocess.check_output = run
prs, err = hb3.open_prs("o/r")
check("a repository nothing can see is reported", bool(err), True)
check("and it says what it could not do", "cannot see the repository" in (err or ""), True)
del os.environ[hb3.READ_TOKEN]

print()
print("=== the credential everything depends on ===")
# An absent expiry header is not a finding: a classic token has none. It has to
# be SAID, though, or "checked and fine" and "could not check" look identical.
exp, note = hb.token_expiry()
check("an unreadable or absent expiry is reported rather than assumed", isinstance(note, str) and note != "", True)

print()
print()
print("=== the private half's schedules ===")
# heyvaldemar-com, the live website, carries the daily job that copies the
# fleet's numbers into its HTML. The schedule checks were public-only, so a
# private repository's schedule could be switched off after sixty quiet days
# and nothing here would say so.
import importlib.util as _il5, datetime as _dt5, subprocess as _sp5
spec5 = _il5.spec_from_file_location("hb5", "scripts/fleet-heartbeat.py")
hb5 = _il5.module_from_spec(spec5); spec5.loader.exec_module(hb5)
now5 = _dt5.datetime(2026, 9, 24, 12, 0, tzinfo=_dt5.timezone.utc)
wfs = {
    "o/pub": [],
    "o/site": [{"id": 1, "path": ".github/workflows/fleet-numbers.yml", "state": "disabled_inactivity"},
               {"id": 2, "path": ".github/workflows/late.yml", "state": "active"},
               {"id": 3, "path": ".github/workflows/fine.yml", "state": "active"}],
}
def gh5(path):
    for full, w in wfs.items():
        if path == "repos/%s/actions/workflows?per_page=100" % full:
            return {"workflows": w}
    return None                                   # the unreadable one: 403/404
hb5.gh = gh5
hb5.gh_or_none = gh5
hb5.last_changed = lambda full, path: None
hb5.list_owned = lambda include_private: ["o/pub"] + (["o/site", "o/secret"] if include_private else [])
hb5.stuck_dependabot = lambda owner, repos, now, stats=None: []
hb5.unverified_heads = lambda owner, repos, now: []
hb5.missing_standard_files = lambda *a: []
hb5.gh_exists = lambda path: True
hb5.last_fired = lambda full, ident: {2: now5 - _dt5.timedelta(hours=80), 3: now5 - _dt5.timedelta(hours=5)}.get(ident)
hb5.declared_period = lambda full, path: 24.0
found5, n5, checked5, disabled5, _ = hb5.fleet("o", 2.0, now5)
check("a disabled schedule in a private repository is a finding",
      any("o/site: fleet-numbers.yml is disabled_inactivity" in f for f in found5), True)
check("and one that stopped firing is too",
      any("o/site: late.yml last fired 80 hours ago" in f for f in found5), True)
check("a private repository this token cannot read is skipped, not a crash", n5, 1)
check("the public-only checks do not reach it",
      [f for f in found5 if "carries none of" in f or "is missing" in f], [])
check("its schedules are counted as checked", checked5, 2)

# A cron changed since the last run starts the clock again: weekly to daily at
# 15:41 is not "62 hours late" the next morning.
hb5.last_changed = lambda full, path: now5 - _dt5.timedelta(hours=10) if path.endswith("late.yml") else None
found6, _, _, _, _ = hb5.fleet("o", 2.0, now5)
check("a schedule changed since its last run is not late yet",
      any("late.yml" in f for f in found6), False)
hb5.last_changed = lambda full, path: now5 - _dt5.timedelta(hours=79)
found7, _, _, _, _ = hb5.fleet("o", 2.0, now5)
check("but a change long ago does not excuse a schedule that stopped",
      any("late.yml last fired 79 hours ago" in f for f in found7), True)

# gh() ends the run on any error. The private loop must not call it on a
# repository the token cannot read, or the watcher dies on the first one.
import types as _ty
def dying(path):
    raise SystemExit("cannot read " + path)
hb5.gh = lambda path: dying(path) if "o/secret" in path else gh5(path)
try:
    hb5.fleet("o", 2.0, now5)
    survived = True
except SystemExit:
    survived = False
check("an unreadable private repository does not end the run", survived, True)


print()
print("=== a push workflow red on main is the machinery being broken too ===")
# Verify was red for fourteen hours on 2026-09-24/25; every scheduled job was
# green, and the check above only ever looked at scheduled runs.
PUSH = {
    "verify":    [{"conclusion": "failure", "created_at": ago(14), "id": 9}],
    "greenpush": [{"conclusion": "success", "created_at": ago(1)}],
    "nopush":    [],
    "running":   [{"conclusion": None, "created_at": ago(1)}],
    "alsocron":  [{"conclusion": "failure", "created_at": ago(9)}],
}
def push_gh(path):
    if path.endswith("/actions/workflows?per_page=100"):
        return {"workflows": [{"path": ".github/workflows/%s.yml" % n, "state": "active", "id": i}
                              for i, n in enumerate(PUSH)]}
    if "event=push&branch=main" not in path:
        raise AssertionError("asked for something other than push runs on main: " + path)
    wid = int(path.split("/workflows/")[1].split("/")[0])
    return {"workflow_runs": list(PUSH.values())[wid]}
hb.gh = push_gh
keep_push = hb.push_workflows; hb.push_workflows = lambda root: ["%s.yml" % n for n in PUSH]
keep_sched = hb.scheduled_workflows; hb.scheduled_workflows = lambda root: [("alsocron.yml", 24.0, ["0 6 * * *"])]
pf, pr = hb.red_on_main("owner/repo")
hb.scheduled_workflows = keep_sched
check("the one red on main is a finding, nothing else is", [n for n, st, _ in pr if st == "FAILING"], ["verify.yml"])
check("exactly one finding", len(pf), 1)
check("and it says red on main, ending how", "verify.yml is red on main: its latest push run ended in failure" in pf[0], True)
check("a run still going is not judged", [st for n, st, _ in pr if n == "running.yml"], ["ok"])
check("a workflow that also runs on a schedule is left to the scheduled check, not named twice",
      [n for n, st, _ in pr if n == "alsocron.yml"], [])
hb.push_workflows = keep_push
d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, ".github/workflows"))
open(os.path.join(d, ".github/workflows/a.yml"), "w").write("on:\n  push:\n    branches: [main]\n  pull_request:\n")
open(os.path.join(d, ".github/workflows/b.yml"), "w").write("on: [push, pull_request]\n")
open(os.path.join(d, ".github/workflows/c.yml"), "w").write("on:\n  schedule:\n    - cron: '0 6 * * *'\n  workflow_dispatch:\n")
open(os.path.join(d, ".github/workflows/d.yml"), "w").write("on:\n  pull_request:\n    paths: [push-notes.md]\n")
check("a workflow that runs on push is found in either spelling, and the others are not",
      hb.push_workflows(d), ["a.yml", "b.yml"])


print()
print("=== a workflow's age runs from the last time it appeared ===")
# scorecard.yml in the private copy: added 2026-09-05, deleted the same
# evening, added again 2026-09-25, and called 482 hours old for it.
P = ".github/workflows/scorecard.yml"
HIST = [
    {"sha": "re", "commit": {"author": {"date": "2026-09-25T23:15:36Z"}}},
    {"sha": "rm", "commit": {"author": {"date": "2026-09-06T01:55:05Z"}}},
    {"sha": "add", "commit": {"author": {"date": "2026-09-06T01:48:11Z"}}},
]
DETAIL = {"re": [{"filename": P, "status": "added"}], "rm": [{"filename": P, "status": "removed"}],
          "add": [{"filename": P, "status": "added"}], "mod": [{"filename": P, "status": "modified"}]}
def born_gh(hist):
    def g(path):
        if "/commits?path=" in path:
            return hist
        return {"files": DETAIL[path.rsplit("/", 1)[1]]}
    return g
t_now = datetime.datetime(2026, 9, 26, 4, 0, tzinfo=datetime.timezone.utc)
keep_gh = hb.gh
hb.gh = born_gh(HIST)
check("a file deleted and added again is as old as its last add",
      hb.workflow_born("o/r", "scorecard.yml", t_now).isoformat(), "2026-09-25T23:15:36+00:00")
hb.gh = born_gh([{"sha": "mod", "commit": {"author": {"date": "2026-09-20T00:00:00Z"}}}] + HIST[2:])
check("a file only ever modified since its add is as old as that add",
      hb.workflow_born("o/r", "scorecard.yml", t_now).isoformat(), "2026-09-06T01:48:11+00:00")
hb.gh = born_gh([])
check("a file with no history at all is new", hb.workflow_born("o/r", "scorecard.yml", t_now), t_now)
hb.gh = keep_gh

print()
print("=== a person outside the fleet, waiting for an answer ===")
# Keycloak #45 sat three days with no reply because nothing here read the
# issue trackers. Each shape below is one the rule must tell apart.
def item(n, login, hours, comments=0, pr=False, bot=False):
    return {"number": n, "user": {"login": login, "type": "Bot" if bot else "User"},
            "created_at": ago(hours), "comments": comments,
            "repository_url": "https://api.github.com/repos/o/a",
            "html_url": "https://github.com/o/a/issues/%d" % n,
            **({"pull_request": {}} if pr else {})}
THREADS = {2: [{"user": {"login": "stranger"}}, {"user": {"login": "o"}}],
           3: [{"user": {"login": "o"}}, {"user": {"login": "stranger"}}]}
def wait_gh(path):
    if path.startswith("search/issues"):
        # The search API refuses a query that names neither kind (HTTP 422),
        # so the fake refuses it too, and answers each kind with its own.
        if "is%3Aissue" in path:
            return {"items": [item(1, "stranger", 72), item(2, "stranger", 72, 2), item(3, "stranger", 72, 2),
                              item(4, "stranger", 10), item(5, "dependabot[bot]", 100, bot=True)]}
        if "is%3Apull-request" in path:
            return {"items": [item(6, "stranger", 50, pr=True)]}
        raise SystemExit("cannot read %s: gh: Query must include 'is:issue' or 'is:pull-request' (HTTP 422)" % path)
    return THREADS[int(path.split("/issues/")[1].split("/")[0])]
keep_gh = hb.gh
hb.gh = wait_gh
waiting = hb.waiting_on_us("o", now)
hb.gh = keep_gh
check("an issue with no reply after three days is a finding", len([w for w in waiting if w.startswith("o/a#1:") and "no reply at all" in w]), 1)
check("one the owner answered last is not",                   len([w for w in waiting if w.startswith("o/a#2:")]), 0)
check("one where the asker spoke last is",                    len([w for w in waiting if w.startswith("o/a#3:") and "last word is stranger's" in w]), 1)
check("one ten hours old is given time",                      len([w for w in waiting if w.startswith("o/a#4:")]), 0)
check("a bot is not a person waiting",                        len([w for w in waiting if w.startswith("o/a#5:")]), 0)
check("a pull request from outside counts too",               len([w for w in waiting if w.startswith("o/a#6:") and "pull request" in w]), 1)
check("and nothing else was invented",                        len(waiting), 3)

print("passed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
