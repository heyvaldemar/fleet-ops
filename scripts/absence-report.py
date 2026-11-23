#!/usr/bin/env python3
"""absence-report.py — what the public fleet did while nobody operated it.

    absence-report.py collect --start ISO --end ISO --out DIR
                              [--owner heyvaldemar] [--lookback-hours 24]
                              [--parts repos,workflows,runs,outside,minutes]
    absence-report.py report DIR [--json FILE]
    absence-report.py compare BASELINE.json CURRENT.json

WHY. From 2026-11-16 23:06Z to 2026-11-22 03:00Z the account's weekly limit
stopped every Claude Code session and every routine, and the fleet ran on
GitHub alone. A fact file measured what it did. This is that measurement as a
script, so an announced absence (docs/drills/operator-absence.md) is measured
the same way and its numbers can stand next to November's.

SCOPE. The owner's public repositories, the public copy of fleet-ops among
them. Private repositories and forks are never asked about: the repository
query carries `privacy: PUBLIC` and drops forks and archives, so no private
name, run or commit reaches the data directory, and a data directory can be
committed as it is (tests/fixtures/absence-2026-11 is November's). A login
that is neither the owner's nor a bot's is written as "outside", and nothing
anyone wrote (issue text, comments) is kept, only times.

WHAT collect READS, in one serial pass, because the API quota is shared by
everything that runs as the owner:
  repos      GraphQL, 40 a page: the default branch's commit at the window's
             end, and its commits since --lookback-hours before the start
             (headline, author kind, time)
  workflows  GraphQL: every file under .github/workflows at that commit, kept
             as its cron lines and whether it calls check-freshness.py; a
             scheduled run whose file is gone by then is read at its own sha
  runs       REST actions/runs?created=FROM..END, every repository
  outside    search: issues and pull requests opened by someone outside, open
             at some point in the window, and the times of their comments
  minutes    billing usage: Actions minutes a day per repository, the window's
             whole days and as many days before it
About 4 GraphQL calls per 40 repositories and 1 REST call per repository per
100 runs: some 250 calls for a three-day window over 120 repositories.

WHAT report SAYS, about runs CREATED inside [start, end). Nothing created at
or after the end is read, so a run a person started after the window cannot
turn a red green in the report.
  A  runs by event
  B  scheduled runs: how late GitHub created each against its cron time
  B2 cron times with no run
  C  red streaks and what turned each green
  D  releases, pin refreshes and reverts the automation committed
  E  Kubernetes freshness: every scheduled workflow that calls
     check-freshness.py, and whether it ran
  F  who acted: every run and commit by the owner account that no fleet
     automation run explains
  G  people outside: who was waiting at the end, and for how long
  H  Actions minutes a day
  I  the fleet's own jobs (public fleet-ops)
  J  per repository
--json writes the headline numbers; compare puts two of those side by side,
in totals and per 24 hours, since two windows are never the same length.

THE RULES, the same as November's file:
- Lateness: run created_at minus the latest cron time at or before it. Exact
  for crons that fire once a day or less while delays stay under a day; for
  more frequent crons only the counts are given.
- Cron times counted against runs: from the first midnight in the window to
  the last midnight at least 24 hours before its end, so a late run for a
  counted cron time still lands inside the window.
- A red streak: one or more red runs of one workflow in one repository, in a
  row (skipped and cancelled runs are passed over), ended by its next green
  run. Counted when one of its red runs was created inside the window; ended
  only by a green run created before the window's end.
- Explained: a run started by the owner account counts as the automation's
  when it was created while a scheduled fleet-triage, fleet-catalog or
  fleet-lifecycle run in fleet-ops was running (until 5 minutes after it
  ended): those are the jobs that write to other repositories with the
  owner's token. A commit is judged the same way by its commit time. The
  rest is listed, because during an absence it is someone operating.
"""
import argparse
import bisect
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

UTC = timezone.utc
AUTOMATION_REPO = "fleet-ops"
AUTOMATION_PATHS = (
    ".github/workflows/fleet-triage.yml",
    ".github/workflows/fleet-catalog.yml",
    ".github/workflows/fleet-lifecycle.yml",
)
AUTOMATION_SLACK = timedelta(minutes=5)
RED = ("failure", "timed_out", "startup_failure")
GREEN = ("success",)
FRESHNESS_MARK = "check-freshness.py"
CRON_RE = re.compile(r"""^\s*-?\s*cron:\s*["']?([^"'#\n]+?)["']?\s*(?:#.*)?$""", re.M)


# ---------------------------------------------------------------- time
def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def iso(d):
    return d.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_when(s):
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if d.tzinfo is None:
        raise SystemExit("absence-report: give times with a zone, e.g. 2027-01-15T00:00:00Z: %s" % s)
    return d.astimezone(UTC).replace(microsecond=0)


def midnight_up(d):
    m = d.replace(hour=0, minute=0, second=0, microsecond=0)
    return m if m == d else m + timedelta(days=1)


def midnight_down(d):
    return d.replace(hour=0, minute=0, second=0, microsecond=0)


def hours(td):
    return td.total_seconds() / 3600


# ---------------------------------------------------------------- cron
def cron_field(spec, lo, hi):
    vals = set()
    for part in spec.split(","):
        step, stepped = 1, False
        if "/" in part:
            part, st = part.split("/", 1)
            step, stepped = int(st), True
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
        else:
            a = int(part)
            b = hi if stepped else a
        if not (lo <= a <= hi and lo <= b <= hi) or step < 1:
            raise ValueError(spec)
        vals.update(range(a, b + 1, step))
    return vals


def cron_fires(expr, start, end):
    """Every time `expr` fires in [start, end], UTC (GitHub reads crons in
    UTC). Day of month and day of week: when both are restricted a day
    matching either fires, as in cron itself."""
    f = expr.split()
    if len(f) != 5:
        raise ValueError(expr)
    m, h, dom, mon, dow = f
    mins, hrs = sorted(cron_field(m, 0, 59)), sorted(cron_field(h, 0, 23))
    days, months = cron_field(dom, 1, 31), cron_field(mon, 1, 12)
    wdays = {x % 7 for x in cron_field(dow, 0, 7)}
    dom_any, dow_any = dom.startswith("*"), dow.startswith("*")
    out = []
    day = midnight_down(start)
    while day <= end:
        wd = (day.weekday() + 1) % 7
        if dom_any and dow_any:
            ok = True
        elif dom_any:
            ok = wd in wdays
        elif dow_any:
            ok = day.day in days
        else:
            ok = day.day in days or wd in wdays
        if ok and day.month in months:
            for hh in hrs:
                for mm in mins:
                    t = day.replace(hour=hh, minute=mm)
                    if start <= t <= end:
                        out.append(t)
        day += timedelta(days=1)
    return out


def all_fires(crons, start, end):
    fires, bad = set(), []
    for c in crons:
        try:
            fires.update(cron_fires(c, start, end))
        except ValueError:
            bad.append(c)
    return sorted(fires), bad


def min_interval_h(fires):
    gaps = [hours(b - a) for a, b in zip(fires, fires[1:])]
    return min(gaps) if gaps else 9999.0


# ---------------------------------------------------------------- GitHub
class GitHub:
    """`gh api`, serial, with a few patient retries on GitHub's own errors.
    A rate limit stops the collection instead of waiting it out: the quota
    belongs to every job that runs as the owner."""

    def __init__(self):
        self.calls = Counter()

    def _run(self, args, kind):
        pauses = [5, 20, 60]
        while True:
            self.calls[kind] += 1
            p = subprocess.run(["gh", "api"] + args, capture_output=True)
            if p.returncode == 0:
                return json.loads(p.stdout or b"null")
            said = (p.stderr or b"").decode("utf-8", "replace").strip().splitlines()
            said = said[0][:200] if said else "gh api failed"
            if re.search(r"rate limit|secondary rate", said, re.I):
                raise SystemExit("absence-report: rate limited (%s); the quota is shared, so this stops here" % said)
            if pauses and re.search(r"HTTP 5\d\d|timeout|connection|EOF|something went wrong", said, re.I):
                time.sleep(pauses.pop(0))
                continue
            raise RuntimeError(said)

    def rest(self, path):
        return self._run(["-H", "Accept: application/vnd.github+json", path], "rest")

    def graphql(self, query):
        d = self._run(["graphql", "-f", "query=" + query], "graphql")
        if d and d.get("errors"):
            raise RuntimeError("graphql: %s" % d["errors"][0].get("message", "error")[:200])
        return (d or {}).get("data") or {}


def q(s):
    return json.dumps(s)


def login_kind(login, owner):
    if not login:
        return "unknown"
    if login == owner:
        return "owner"
    if login.endswith("[bot]"):
        return login
    return "outside"


def write_jsonl(path, rows):
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True) + "\n")


def read_jsonl(path):
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


HISTORY_NODES = "nodes { oid committedDate messageHeadline author { user { login } } }"


def collect_repos(gh, owner, read_from, end):
    repos, commits, skipped = [], [], Counter()
    cursor = None
    while True:
        after = (", after: %s" % q(cursor)) if cursor else ""
        data = gh.graphql(
            'query { user(login: %s) { repositories(first: 40%s, ownerAffiliations: OWNER, privacy: PUBLIC, '
            'orderBy: {field: NAME, direction: ASC}) { pageInfo { hasNextPage endCursor } nodes { name isFork '
            'isArchived isPrivate defaultBranchRef { target { ... on Commit { atEnd: history(first: 1, until: %s) '
            '{ nodes { oid } } inRange: history(first: 100, since: %s, until: %s) { pageInfo { hasNextPage '
            'endCursor } %s } } } } } } } }' % (q(owner), after, q(iso(end)), q(iso(read_from)), q(iso(end)), HISTORY_NODES))
        conn = data["user"]["repositories"]
        for n in conn["nodes"]:
            if n["isPrivate"]:
                raise SystemExit("absence-report: a private repository came back from a PUBLIC query; stopping")
            if n["isFork"] or n["isArchived"]:
                skipped["fork" if n["isFork"] else "archived"] += 1
                continue
            target = (n.get("defaultBranchRef") or {}).get("target") or {}
            head = ((target.get("atEnd") or {}).get("nodes") or [{}])
            oid = head[0].get("oid") if head else None
            repos.append({"name": n["name"], "end_oid": oid})
            hist = target.get("inRange") or {"nodes": [], "pageInfo": {"hasNextPage": False}}
            nodes = list(hist["nodes"])
            while hist["pageInfo"]["hasNextPage"]:
                more = gh.graphql(
                    'query { repository(owner: %s, name: %s) { defaultBranchRef { target { ... on Commit { '
                    'history(first: 100, after: %s, since: %s, until: %s) { pageInfo { hasNextPage endCursor } %s } '
                    '} } } } }' % (q(owner), q(n["name"]), q(hist["pageInfo"]["endCursor"]), q(iso(read_from)),
                                   q(iso(end)), HISTORY_NODES))
                hist = more["repository"]["defaultBranchRef"]["target"]["history"]
                nodes += hist["nodes"]
            for c in nodes:
                when = c["committedDate"].replace(".000", "")
                if not (iso(read_from) <= when < iso(end)):
                    continue
                commits.append({"repo": n["name"], "sha": c["oid"][:7], "committed_at": when,
                                "headline": c["messageHeadline"],
                                "author": login_kind(((c.get("author") or {}).get("user") or {}).get("login"), owner)})
        if not conn["pageInfo"]["hasNextPage"]:
            break
        cursor = conn["pageInfo"]["endCursor"]
    return repos, commits, skipped


def workflow_record(repo, path, text):
    return {"repo": repo, "path": path, "crons": [c.strip() for c in CRON_RE.findall(text or "")],
            "check_freshness": FRESHNESS_MARK in (text or "")}


def collect_workflows(gh, owner, repos, batch=15):
    out = []
    todo = [r for r in repos if r["end_oid"]]
    i = 0
    while i < len(todo):
        part = todo[i:i + batch]
        body = " ".join(
            'r%d: repository(owner: %s, name: %s) { object(expression: %s) { ... on Tree { entries { name type '
            'object { ... on Blob { text } } } } } }' % (k, q(owner), q(r["name"]), q(r["end_oid"] + ":.github/workflows"))
            for k, r in enumerate(part))
        try:
            data = gh.graphql("query { %s }" % body)
        except RuntimeError:
            if batch > 3:  # a page of large files can make GitHub answer 502; ask for fewer
                batch = max(3, batch // 2)
                continue
            raise
        for k, r in enumerate(part):
            tree = ((data.get("r%d" % k) or {}).get("object") or {}).get("entries") or []
            for e in tree:
                if e["type"] == "blob" and re.search(r"\.ya?ml$", e["name"]):
                    out.append(workflow_record(r["name"], ".github/workflows/" + e["name"],
                                               (e.get("object") or {}).get("text")))
        i += len(part)
    return out


def collect_missing_workflows(gh, owner, runs, known):
    """A scheduled run whose file is not at the end commit (renamed, deleted
    in the window): read the file at the commit the run itself used."""
    want = {}
    for r in runs:
        k = (r["repo"], r["path"])
        if r["event"] == "schedule" and k not in known and k not in want:
            want[k] = r["full_sha"]
    out, items = [], sorted(want.items())
    for i in range(0, len(items), 20):
        part = items[i:i + 20]
        body = " ".join('r%d: repository(owner: %s, name: %s) { object(expression: %s) { ... on Blob { text } } }'
                        % (k, q(owner), q(repo), q(sha + ":" + path)) for k, ((repo, path), sha) in enumerate(part))
        data = gh.graphql("query { %s }" % body)
        for k, ((repo, path), sha) in enumerate(part):
            text = ((data.get("r%d" % k) or {}).get("object") or {}).get("text")
            rec = workflow_record(repo, path, text)
            rec["read_at"] = sha[:7]
            out.append(rec)
    return out


def collect_runs(gh, owner, repo, read_from, end):
    def window(a, b):
        got, page, total = [], 1, None
        while True:
            d = gh.rest("repos/%s/%s/actions/runs?created=%s..%s&per_page=100&page=%d"
                        % (owner, repo, iso(a), iso(b), page))
            total = d.get("total_count", 0)
            if total > 1000 and page == 1 and b - a > timedelta(minutes=10):
                mid = a + (b - a) / 2
                return window(a, mid.replace(microsecond=0)) + window(mid.replace(microsecond=0) + timedelta(seconds=1), b)
            rows = d.get("workflow_runs") or []
            got += rows
            if not rows or len(got) >= total:
                return got
            page += 1
    seen, out = set(), []
    for r in window(read_from, end - timedelta(seconds=1)):
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        out.append({
            "id": r["id"], "repo": repo, "name": r.get("name") or "", "path": r.get("path") or "",
            "event": r["event"], "status": r["status"], "conclusion": r.get("conclusion"),
            "created_at": r["created_at"], "updated_at": r["updated_at"],
            "run_started_at": r.get("run_started_at"), "run_attempt": r.get("run_attempt") or 1,
            "sha": (r.get("head_sha") or "")[:7], "full_sha": r.get("head_sha") or "",
            "actor": login_kind((r.get("actor") or {}).get("login"), owner),
            "trig": login_kind((r.get("triggering_actor") or {}).get("login"), owner),
        })
    return out


def collect_outside(gh, owner, public, start, end):
    """Issues and pull requests opened by someone outside, open at some point
    in the window. Only times are kept: when it was opened and closed, when
    the owner commented, when people outside commented."""
    found = {}
    for kind in ("is:issue", "is:pull-request"):
        for state in ("is:open created:<%s" % iso(end), "is:closed created:<%s closed:>=%s" % (iso(end), iso(start))):
            query = "user:%s %s -author:%s %s" % (owner, kind, owner, state)
            page = 1
            while True:
                d = gh.rest("search/issues?q=%s&per_page=100&page=%d" % (urllib.parse.quote(query), page))
                items = d.get("items") or []
                for it in items:
                    repo = it["repository_url"].rsplit("/", 1)[1]
                    who = it.get("user") or {}
                    if repo not in public or who.get("type") == "Bot" or (who.get("login") or "").endswith("[bot]"):
                        continue
                    found[(repo, it["number"])] = it
                if len(items) < 100:
                    break
                page += 1
    out = []
    for (repo, number), it in sorted(found.items()):
        comments, page = [], 1
        while True:
            c = gh.rest("repos/%s/%s/issues/%d/comments?per_page=100&page=%d" % (owner, repo, number, page))
            comments += c or []
            if len(c or []) < 100:
                break
            page += 1
        owner_t, outside_t = [], []
        for c in comments:
            k = login_kind((c.get("user") or {}).get("login"), owner)
            if k == "owner":
                owner_t.append(c["created_at"])
            elif k == "outside":
                outside_t.append(c["created_at"])
        out.append({"repo": repo, "number": number, "kind": "pull" if it.get("pull_request") else "issue",
                    "created_at": it["created_at"], "closed_at": it.get("closed_at"),
                    "owner_comments": sorted(owner_t), "outside_comments": sorted(outside_t)})
    return out


def collect_minutes(gh, owner, public, first_day, last_day):
    months, y, m = [], first_day.year, first_day.month
    while (y, m) <= (last_day.year, last_day.month):
        months.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    rows = []
    for y, m in months:
        d = gh.rest("users/%s/settings/billing/usage?year=%d&month=%d" % (owner, y, m))
        for it in (d or {}).get("usageItems") or []:
            day = it.get("date", "")[:10]
            if (it.get("product") == "actions" and it.get("unitType") == "Minutes"
                    and it.get("repositoryName") in public
                    and first_day.strftime("%Y-%m-%d") <= day <= last_day.strftime("%Y-%m-%d")):
                rows.append({"date": day, "repo": it["repositoryName"], "sku": it.get("sku", ""),
                             "minutes": it.get("quantity", 0)})
    rows.sort(key=lambda r: (r["date"], r["repo"], r["sku"]))
    return rows


def window_days(start, end):
    a, b = midnight_up(start), midnight_down(end)
    days = []
    while a + timedelta(days=1) <= b:
        days.append(a)
        a += timedelta(days=1)
    return days


def cmd_collect(args):
    start, end = parse_when(args.start), parse_when(args.end)
    if end <= start:
        raise SystemExit("absence-report: the end comes before the start")
    if end > datetime.now(UTC):
        raise SystemExit("absence-report: the window has not ended yet; collect after %s" % iso(end))
    read_from = start - timedelta(hours=args.lookback_hours)
    parts = set(args.parts.split(","))
    os.makedirs(args.out, exist_ok=True)
    gh = GitHub()
    metap = os.path.join(args.out, "meta.json")
    meta = json.load(open(metap)) if os.path.exists(metap) else {}
    meta.update({"owner": args.owner, "start": iso(start), "end": iso(end), "read_from": iso(read_from),
                 "read_to": iso(end), "collected_at": iso(datetime.now(UTC)),
                 "scope": "public repositories of the owner, forks and archives left out"})
    if "repos" in parts:
        repos, commits, skipped = collect_repos(gh, args.owner, read_from, end)
        json.dump(repos, open(os.path.join(args.out, "repos.json"), "w"), indent=0, sort_keys=True)
        write_jsonl(os.path.join(args.out, "commits.jsonl"), sorted(commits, key=lambda c: (c["committed_at"], c["repo"])))
        meta["skipped"] = dict(skipped)
        print("repositories: %d public (%s left out)" % (len(repos), dict(skipped)), file=sys.stderr)
    repos = json.load(open(os.path.join(args.out, "repos.json")))
    public = {r["name"] if isinstance(r, dict) else r for r in repos}
    runs = None
    if "runs" in parts:
        runs = []
        for r in sorted(public):
            runs += collect_runs(gh, args.owner, r, read_from, end)
        print("runs: %d" % len(runs), file=sys.stderr)
    if "workflows" in parts:
        wf = collect_workflows(gh, args.owner, [r for r in repos if isinstance(r, dict)])
        if runs is not None:
            wf += collect_missing_workflows(gh, args.owner, runs, {(w["repo"], w["path"]) for w in wf})
        write_jsonl(os.path.join(args.out, "workflows.jsonl"), sorted(wf, key=lambda w: (w["repo"], w["path"])))
        print("workflow files: %d" % len(wf), file=sys.stderr)
    if runs is not None:
        for r in runs:
            r.pop("full_sha", None)
        write_jsonl(os.path.join(args.out, "runs.jsonl"), sorted(runs, key=lambda r: (r["created_at"], r["id"])))
    if "outside" in parts:
        out = collect_outside(gh, args.owner, public, start, end)
        write_jsonl(os.path.join(args.out, "outside.jsonl"), out)
        print("people outside: %d issues and pull requests" % len(out), file=sys.stderr)
    if "minutes" in parts:
        days = window_days(start, end)
        if days:
            first = days[0] - timedelta(days=len(days))
            try:
                rows = collect_minutes(gh, args.owner, public, first, days[-1])
                write_jsonl(os.path.join(args.out, "minutes.jsonl"), rows)
                meta["minutes"] = "billing usage API, Actions minutes, public repositories"
            except RuntimeError as e:
                meta["minutes"] = "not collected: %s" % str(e).split(":")[0][:80]
        else:
            meta["minutes"] = "not collected: the window holds no whole day"
    meta["api_calls"] = dict(gh.calls)
    json.dump(meta, open(metap, "w"), indent=1, sort_keys=True)
    print("api calls: %s" % dict(gh.calls), file=sys.stderr)


# ---------------------------------------------------------------- report
def load(d):
    meta = json.load(open(os.path.join(d, "meta.json")))
    repos = json.load(open(os.path.join(d, "repos.json")))
    public = {r["name"] if isinstance(r, dict) else r for r in repos}
    end = meta["end"]
    runs = [r for r in (read_jsonl(os.path.join(d, "runs.jsonl")) or [])
            if r["repo"] in public and r["created_at"] < end]
    wfs = {(w["repo"], w["path"]): w for w in (read_jsonl(os.path.join(d, "workflows.jsonl")) or [])
           if w["repo"] in public}
    commits = [c for c in (read_jsonl(os.path.join(d, "commits.jsonl")) or [])
               if c["repo"] in public and c["committed_at"] < end]
    outside = read_jsonl(os.path.join(d, "outside.jsonl"))
    minutes = read_jsonl(os.path.join(d, "minutes.jsonl"))
    if outside is not None:
        outside = [o for o in outside if o["repo"] in public]
    if minutes is not None:
        minutes = [m for m in minutes if m["repo"] in public]
    return meta, public, runs, wfs, commits, outside, minutes


def quant(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return None
    return {"n": n, "min": xs[0], "p10": xs[n // 10], "median": xs[n // 2], "p90": xs[(9 * n) // 10], "max": xs[-1]}


def h1(minutes):
    return round(minutes / 60, 1)


def lateness(runs, wfs, start, end):
    """For every scheduled run: the cron time it answers and how late."""
    out = {}
    by = defaultdict(list)
    for r in runs:
        if r["event"] == "schedule":
            by[(r["repo"], r["path"])].append(r)
    for k, rs in by.items():
        crons = (wfs.get(k) or {}).get("crons") or []
        fires, _ = all_fires(crons, start - timedelta(days=8), end)
        mi = min_interval_h(fires)
        for r in rs:
            c = ts(r["created_at"])
            i = bisect.bisect_right(fires, c)
            nominal = fires[i - 1] if i else None
            out[r["id"]] = {"nominal": iso(nominal) if nominal else None,
                            "late_min": round((c - nominal).total_seconds() / 60) if nominal else None,
                            "daily": mi >= 24}
    return out


def automation_intervals(runs):
    iv = []
    for r in runs:
        if r["repo"] == AUTOMATION_REPO and r["path"] in AUTOMATION_PATHS and r["event"] == "schedule":
            a = ts(r.get("run_started_at") or r["created_at"])
            iv.append((a, ts(r["updated_at"]) + AUTOMATION_SLACK, r["name"]))
    return sorted(iv)


def inside(iv, t):
    return next((n for a, b, n in iv if a <= t <= b), None)


def judge_run(r, iv):
    """Who made this run happen: ('github'|'bot'|'follows'|'outside'|'automation'|'unexplained', detail)."""
    if r["event"] in ("schedule", "dynamic"):
        return "github", r["event"]
    if r["event"] == "workflow_run":
        return "follows", "workflow_run"
    k = r.get("trig") if r.get("trig") not in (None, "unknown") else r.get("actor")
    if k in (None, "unknown"):
        return "unexplained", r["event"]
    if k == "owner":
        n = inside(iv, ts(r["created_at"]))
        return ("automation", n) if n else ("unexplained", r["event"])
    if k == "outside":
        return "outside", r["event"]
    return "bot", k


def streaks(runs, start, end):
    by = defaultdict(list)
    for r in runs:
        by[(r["repo"], r["path"] or r["name"])].append(r)
    out = []
    for k, rs in sorted(by.items()):
        rs = sorted((r for r in rs if r["conclusion"] in RED + GREEN), key=lambda r: (r["created_at"], r["id"]))
        cur = None
        for r in rs + [None]:
            if r is not None and r["conclusion"] in RED:
                cur = cur or []
                cur.append(r)
                continue
            if cur:
                if any(start <= x["created_at"] < end for x in cur):
                    out.append({"repo": k[0], "path": k[1], "name": cur[0]["name"], "fails": cur, "green": r})
                cur = None
    return out


def link(owner, repo, rid):
    return "[%s](https://github.com/%s/%s/actions/runs/%s)" % (rid, owner, repo, rid)


def report(d):
    meta, public, runs, wfs, commits, outside, minutes = load(d)
    owner = meta["owner"]
    S, E = meta["start"], meta["end"]
    start, end = ts(S), ts(E)
    span_h = hours(end - start)
    w = [r for r in runs if S <= r["created_at"] < E]
    late = lateness(runs, wfs, start, end)
    iv = automation_intervals(runs)
    L, J = [], {"window": {"start": S, "end": E, "hours": round(span_h, 2)}}
    P = L.append

    P("# Operator absence report: %s → %s" % (S, E))
    P("")
    P("Window %.1f h. Scope: %d public repositories of %s (forks and archives left out; private repositories are never "
      "read). Read from %s; nothing created at or after the end is counted. Collected %s."
      % (span_h, len(public), owner, meta["read_from"], meta.get("collected_at", "?")))

    # A
    by = defaultdict(Counter)
    for r in w:
        c = r["conclusion"] or r["status"]
        by[r["event"]][c if c in ("success", "failure", "skipped", "cancelled") else "other"] += 1
    tot = Counter()
    P("\n## A. Runs by event\n")
    P("| event | runs | success | failure | skipped | cancelled | other |")
    P("|---|---:|---:|---:|---:|---:|---:|")
    for e, c in sorted(by.items(), key=lambda x: (-sum(x[1].values()), x[0])):
        P("| %s | %d | %d | %d | %d | %d | %d |" % (e, sum(c.values()), c["success"], c["failure"], c["skipped"],
                                                 c["cancelled"], c["other"]))
        tot.update(c)
    P("| **all** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** |" % (
        sum(tot.values()), tot["success"], tot["failure"], tot["skipped"], tot["cancelled"], tot["other"]))
    reruns = [r for r in w if (r.get("run_attempt") or 1) > 1]
    P("\nRepositories with a run: %d. Runs re-run at least once (the table counts the last attempt): %d."
      % (len({r["repo"] for r in w}), len(reruns)))
    J["runs"] = {"all": sum(tot.values()), "success": tot["success"], "failure": tot["failure"],
                 "skipped": tot["skipped"], "cancelled": tot["cancelled"], "other": tot["other"],
                 "by_event": {e: sum(c.values()) for e, c in by.items()},
                 "repositories": len({r["repo"] for r in w}), "rerun": len(reruns)}

    # B
    sched = [r for r in w if r["event"] == "schedule"]
    P("\n## B. Scheduled runs, and how late GitHub created them\n")
    P("Late = `created_at` minus the cron time it answers. Medians only for crons that fire once a day or less.\n")
    P("| workflow | runs | green | red | skipped | late median, h | late min–max, h |")
    P("|---|---:|---:|---:|---:|---:|---:|")
    bn = defaultdict(list)
    for r in sched:
        bn[r["name"]].append(r)
    for n, rs in sorted(bn.items(), key=lambda x: (-len(x[1]), x[0])):
        c = Counter("red" if r["conclusion"] in RED else r["conclusion"] for r in rs)
        lm = [late[r["id"]]["late_min"] for r in rs if late[r["id"]]["late_min"] is not None and late[r["id"]]["daily"]]
        sub = any(not late[r["id"]]["daily"] for r in rs)
        span = ("%s | %s–%s" % (h1(quant(lm)["median"]), h1(min(lm)), h1(max(lm)))) if lm and not sub else "– | –"
        P("| %s | %d | %d | %d | %d | %s |" % (n, len(rs), c["success"], c["red"], c["skipped"], span))
    c = Counter("red" if r["conclusion"] in RED else r["conclusion"] for r in sched)
    P("| **all scheduled** | **%d** | **%d** | **%d** | **%d** | | |" % (len(sched), c["success"], c["red"], c["skipped"]))
    J["scheduled"] = {"all": len(sched), "green": c["success"], "red": c["red"], "skipped": c["skipped"]}
    lm = [late[r["id"]]["late_min"] for r in sched if late[r["id"]]["late_min"] is not None and late[r["id"]]["daily"]]
    unread = [r for r in sched if late[r["id"]]["nominal"] is None]
    qq = quant(lm)
    if qq:
        P("\nDaily-or-rarer crons, %d runs: median %s h late, p10 %s h, p90 %s h, min %s h, max %s h."
          % (qq["n"], h1(qq["median"]), h1(qq["p10"]), h1(qq["p90"]), h1(qq["min"]), h1(qq["max"])))
        J["lateness_hours"] = {k: (h1(v) if k != "n" else v) for k, v in qq.items()}
    if unread:
        P("Scheduled runs whose cron could not be read: %d." % len(unread))
    byday = defaultdict(list)
    for r in sched:
        x = late[r["id"]]
        if x["daily"] and x["late_min"] is not None:
            byday[x["nominal"][:10]].append(x["late_min"])
    if byday:
        P("\n| cron day | runs | median late, h | max late, h |")
        P("|---|---:|---:|---:|")
        for k in sorted(byday):
            v = sorted(byday[k])
            P("| %s | %d | %s | %s |" % (k, len(v), h1(v[len(v) // 2]), h1(v[-1])))

    # B2
    F0, F1 = midnight_up(start), midnight_down(end - timedelta(hours=24))
    P("\n## B2. Cron times with no run\n")
    exp = got = dexp = dgot = 0
    missing = []
    noms = defaultdict(set)
    for r in runs:
        if r["event"] == "schedule" and late.get(r["id"], {}).get("nominal"):
            noms[(r["repo"], r["path"])].add(late[r["id"]]["nominal"])
    if F1 > F0:
        for k, wf in sorted(wfs.items()):
            fires, _ = all_fires(wf.get("crons") or [], F0, F1 - timedelta(seconds=1))
            if not fires:
                continue
            mi = min_interval_h(all_fires(wf["crons"], start - timedelta(days=8), end)[0])
            g = sum(1 for f in fires if iso(f) in noms[k])
            exp += len(fires)
            got += g
            if mi >= 24:
                dexp += len(fires)
                dgot += g
            if g < len(fires):
                missing.append((k, len(fires), g, mi))
        P("Cron times from %s to %s (whole days whose late runs still land in the window): %d, answered by a run %d, "
          "no run %d. Crons that fire once a day or less: %d cron times, %d with no run."
          % (iso(F0), iso(F1), exp, got, exp - got, dexp, dexp - dgot))
        for (repo, path), e, g, mi in missing:
            note = "" if mi >= 24 else " (fires every %.0f h: with delays near GitHub's, a run cannot be tied to one cron time)" % mi
            P("- %s `%s`: %d cron times, %d runs%s" % (repo, path, e, g, note))
    else:
        P("The window holds no whole day whose late runs would still land inside it; nothing is counted here.")
    J["cron_times"] = {"from": iso(F0), "to": iso(F1), "expected": exp, "answered": got, "missing": exp - got,
                       "daily_expected": dexp, "daily_missing": dexp - dgot}

    # C
    st = streaks(runs, S, E)
    P("\n## C. Red streaks, and what turned each green\n")

    def closed_by(s):
        g = s["green"]
        if g is None or g["created_at"] >= E:
            return "still red at the window's end"
        who, _ = judge_run(g, iv)
        e = g["event"]
        if e == "workflow_dispatch":
            return "re-run dispatched by the automation" if who == "automation" else "re-run dispatched, not by the automation"
        if e == "schedule":
            return "the next scheduled run"
        if e == "push":
            return "a push by the automation" if who == "automation" else "a push, not by the automation"
        if e == "workflow_run":
            return "the next run of the workflow it follows"
        if e == "release":
            return "a release by the automation" if who == "automation" else "a release, not by the automation"
        return e
    cat, red_h, rows = Counter(), [], []
    for s in st:
        how = closed_by(s)
        cat[how] += 1
        f0, g = s["fails"][0], s["green"]
        rh = None
        if not how.startswith("still"):
            rh = round(hours(ts(g["updated_at"]) - ts(f0["updated_at"])), 1)
            red_h.append(rh)
        rows.append("| %s | %s | %d | %s | %s | %s | %s | %s |" % (
            s["repo"], s["name"], len(s["fails"]), f0["created_at"], link(owner, s["repo"], f0["id"]), how,
            link(owner, s["repo"], g["id"]) if rh is not None else "–", rh if rh is not None else "–"))
    qh = quant(red_h)
    P("Streaks with a red run created in the window: %d (%d red runs). How they ended:"
      % (len(st), sum(len(s["fails"]) for s in st)))
    for k, v in cat.most_common():
        P("- %s: %d" % (k, v))
    if qh:
        P("- red for, from the first red run's end to the green run's end: median %s h, min %s h, max %s h (%d streaks)"
          % (qh["median"], qh["min"], qh["max"], qh["n"]))
    per = Counter(s["name"] for s in st)
    still = Counter(s["name"] for s in st if closed_by(s).startswith("still"))
    P("- by workflow: " + "; ".join("%s %d (%d still red)" % (n, v, still[n]) for n, v in per.most_common()))
    P("")
    P("| repository | workflow | red runs | first red (created) | first red run | ended by | green run | red for, h |")
    P("|---|---|---:|---|---|---|---|---:|")
    L.extend(rows)
    J["red_streaks"] = {"all": len(st), "red_runs": sum(len(s["fails"]) for s in st),
                        "closed": len(st) - cat["still red at the window's end"],
                        "still_red": cat["still red at the window's end"], "ended_by": dict(cat),
                        "red_hours": qh}

    # D
    wc = [c for c in commits if S <= c["committed_at"] < E]
    rel = [c for c in wc if c["headline"].startswith("chore(release)")]
    pins = [c for c in wc if c["headline"].startswith("fix(security)")]
    rev = [c for c in wc if c["headline"].startswith('Revert "')]
    rel_runs = [r for r in w if r["event"] == "release"]
    P("\n## D. Releases, pin refreshes, reverts\n")
    P("On default branches, commits made in the window: %d. Release commits (`chore(release)`): %d in %d repositories. "
      "Pin refreshes (`fix(security)`): %d in %d repositories. Reverts: %d. Runs started by a published release: %d."
      % (len(wc), len(rel), len({c["repo"] for c in rel}), len(pins), len({c["repo"] for c in pins}), len(rev), len(rel_runs)))
    for c in rev:
        P("- revert: %s [%s](https://github.com/%s/%s/commit/%s) at %s: %s"
          % (c["repo"], c["sha"], owner, c["repo"], c["sha"], c["committed_at"], c["headline"][:100]))
    J["releases"] = {"commits_in_window": len(wc), "release_commits": len(rel), "release_repos": len({c["repo"] for c in rel}),
                     "pin_refresh_commits": len(pins), "reverts": len(rev), "release_event_runs": len(rel_runs)}

    # E
    P("\n## E. Kubernetes freshness\n")
    fw = [(k, v) for k, v in sorted(wfs.items()) if v.get("check_freshness") and v.get("crons")]
    ran = 0
    if not fw:
        P("No scheduled workflow file read for this window calls `%s`. Kubernetes pin drift was not measured by the fleet "
          "inside it." % FRESHNESS_MARK)
    else:
        P("| repository | workflow | cron | cron times in window | runs in window | results |")
        P("|---|---|---|---:|---:|---|")
        for (repo, path), v in fw:
            fires, _ = all_fires(v["crons"], start, end - timedelta(seconds=1))
            rs = [r for r in w if r["repo"] == repo and r["path"] == path and r["event"] == "schedule"]
            ran += 1 if rs else 0
            res = ", ".join("%s %d" % (k, n) for k, n in Counter(r["conclusion"] or r["status"] for r in rs).most_common()) or "–"
            P("| %s | `%s` | `%s` | %d | %d | %s |" % (repo, path, " | ".join(v["crons"]), len(fires), len(rs), res))
        P("\n%d of %d repositories with a freshness check had a scheduled run of it in the window." % (ran, len(fw)))
    J["k8s_freshness"] = {"workflows": len(fw), "ran_in_window": ran}

    # F
    P("\n## F. Who acted\n")
    judged = Counter()
    unexplained = []
    for r in w:
        who, det = judge_run(r, iv)
        judged[who] += 1
        if who == "unexplained":
            unexplained.append(r)
    P("Runs in the window by who made them happen: " + ", ".join("%s %d" % (k, v) for k, v in judged.most_common()) + ".")
    P("Automation runs in %s that explain the owner account's runs and commits: %d (%s)."
      % (AUTOMATION_REPO, len([x for x in iv if S <= iso(x[0]) < E]), ", ".join(sorted({x[2] for x in iv})) or "none"))
    cj = Counter()
    unexp_c = []
    for c in wc:
        if c["author"] == "owner":
            if inside(iv, ts(c["committed_at"])):
                cj["automation"] += 1
            else:
                cj["unexplained"] += 1
                unexp_c.append(c)
        elif c["author"].endswith("[bot]"):
            cj["bot"] += 1
        else:
            cj[c["author"]] += 1
            if c["author"] == "unknown":
                unexp_c.append(c)
    P("Commits in the window by author: " + (", ".join("%s %d" % (k, v) for k, v in cj.most_common()) or "none") + ".")
    if unexplained or unexp_c:
        P("\nNot explained by any automation run (someone operated, or the rule missed a job):\n")
        for r in sorted(unexplained, key=lambda r: r["created_at"]):
            P("- run %s %s «%s» (%s) created %s" % (link(owner, r["repo"], r["id"]), r["repo"], r["name"], r["event"], r["created_at"]))
        for c in unexp_c:
            P("- commit [%s](https://github.com/%s/%s/commit/%s) %s at %s: %s"
              % (c["sha"], owner, c["repo"], c["sha"], c["repo"], c["committed_at"], c["headline"][:100]))
    else:
        P("\nEvery run and commit by the owner account in the window sits inside an automation run.")
    J["unexplained"] = {"runs": len(unexplained), "commits": len(unexp_c)}

    # G
    P("\n## G. People outside\n")
    if outside is None:
        P("Not collected.")
        J["outside"] = None
    else:
        rows, waiting, opened, answered = [], [], 0, 0
        for o in outside:
            if o["created_at"] >= E or (o["closed_at"] and o["closed_at"] < S):
                continue
            opened += S <= o["created_at"] < E
            replies = [t for t in o["owner_comments"] if o["created_at"] <= t < E]
            answered += any(S <= t < E for t in replies)
            open_at_end = not o["closed_at"] or o["closed_at"] >= E
            last_owner = max(replies) if replies else None
            outside_msgs = [o["created_at"]] + [t for t in o["outside_comments"] if t < E]
            since = min([t for t in outside_msgs if not last_owner or t > last_owner] or [None], key=lambda t: t or "")
            wait_h = round(hours(end - ts(since)), 1) if open_at_end and since else None
            if wait_h is not None:
                waiting.append(wait_h)
            rows.append("| [%s#%d](https://github.com/%s/%s/%s/%d) | %s | %s | %s | %s |" % (
                o["repo"], o["number"], owner, o["repo"], "pull" if o["kind"] == "pull" else "issues", o["number"],
                o["created_at"], last_owner or "–", "open" if open_at_end else "closed " + o["closed_at"],
                wait_h if wait_h is not None else "–"))
        P("Issues and pull requests opened by someone outside and open during the window: %d (%d opened in it). "
          "Answered by the owner inside the window: %d. Waiting for the owner at the end: %d%s."
          % (len(rows), opened, answered, len(waiting), (", the longest %s h" % max(waiting)) if waiting else ""))
        if rows:
            P("\n| item | opened | owner's last reply before the end | at the end | waiting, h |")
            P("|---|---|---|---|---:|")
            L.extend(rows)
        J["outside"] = {"open_in_window": len(rows), "opened_in_window": opened, "answered_in_window": answered,
                        "waiting_at_end": len(waiting), "longest_wait_h": max(waiting) if waiting else 0}

    # H
    P("\n## H. Actions minutes\n")
    days = window_days(start, end)
    if minutes is None or not days:
        P("Not collected (%s)." % meta.get("minutes", "no whole day in the window"))
        J["minutes"] = None
    else:
        per = defaultdict(float)
        perrepo = defaultdict(float)
        for m in minutes:
            per[m["date"]] += m["minutes"]
        wd = [x.strftime("%Y-%m-%d") for x in days]
        bd = [(days[0] - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(len(days), 0, -1)]
        for m in minutes:
            if m["date"] in wd:
                perrepo[m["repo"]] += m["minutes"]
        wt, bt = sum(per[x] for x in wd), sum(per[x] for x in bd)
        P("Billing usage, Actions minutes on every runner, public repositories only (they are not charged; the minutes "
          "measure work, not cost). Whole days only.\n")
        P("| days | minutes | per day |")
        P("|---|---:|---:|")
        P("| %s – %s (before) | %d | %d |" % (bd[0], bd[-1], round(bt), round(bt / len(bd))))
        P("| %s – %s (window) | %d | %d |" % (wd[0], wd[-1], round(wt), round(wt / len(wd))))
        P("\nPer day in the window: " + "; ".join("%s %d" % (x, round(per[x])) for x in wd) + ". Biggest: "
          + ", ".join("%s %d" % (k, round(v)) for k, v in sorted(perrepo.items(), key=lambda x: -x[1])[:5]) + ".")
        J["minutes"] = {"window_days": wd, "window_total": round(wt), "window_per_day": round(wt / len(wd)),
                        "before_days": bd, "before_total": round(bt), "before_per_day": round(bt / len(bd))}

    # I
    P("\n## I. The fleet's own jobs (public %s)\n" % AUTOMATION_REPO)
    fo = [r for r in w if r["repo"] == AUTOMATION_REPO]
    if not fo:
        P("No run.")
    else:
        P("| workflow | runs | green | red | skipped | days with a run |")
        P("|---|---:|---:|---:|---:|---:|")
        byname = defaultdict(list)
        for r in fo:
            byname[r["name"]].append(r)
        for n, rs in sorted(byname.items(), key=lambda x: (-len(x[1]), x[0])):
            c = Counter("red" if r["conclusion"] in RED else r["conclusion"] for r in rs)
            P("| %s | %d | %d | %d | %d | %d |" % (n, len(rs), c["success"], c["red"], c["skipped"],
                                                len({r["created_at"][:10] for r in rs})))
    J["fleet_jobs"] = {n: {"runs": len([r for r in fo if r["name"] == n]),
                           "red": len([r for r in fo if r["name"] == n and r["conclusion"] in RED])}
                       for n in sorted({r["name"] for r in fo})}

    # J
    P("\n## J. Per repository\n")
    P("| repository | all runs | scheduled | green | red | skipped | late median, h |")
    P("|---|---:|---:|---:|---:|---:|---:|")
    br = defaultdict(list)
    for r in w:
        br[r["repo"]].append(r)
    for repo in sorted(br):
        rs = br[repo]
        ss = [r for r in rs if r["event"] == "schedule"]
        c = Counter("red" if r["conclusion"] in RED else r["conclusion"] for r in ss)
        lmr = [late[r["id"]]["late_min"] for r in ss if late[r["id"]]["late_min"] is not None and late[r["id"]]["daily"]]
        P("| %s | %d | %d | %d | %d | %d | %s |" % (repo, len(rs), len(ss), c["success"], c["red"], c["skipped"],
                                                 h1(quant(lmr)["median"]) if lmr else "–"))
    return "\n".join(L) + "\n", J


def cmd_report(args):
    text, summary = report(args.dir)
    sys.stdout.write(text)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(summary, fh, indent=1, sort_keys=True)
            fh.write("\n")


# ---------------------------------------------------------------- compare
ROWS = [
    ("window, hours", ("window", "hours"), False),
    ("runs", ("runs", "all"), True),
    ("runs green", ("runs", "success"), True),
    ("runs red (failure)", ("runs", "failure"), True),
    ("scheduled runs", ("scheduled", "all"), True),
    ("scheduled red", ("scheduled", "red"), True),
    ("lateness median, h", ("lateness_hours", "median"), False),
    ("lateness p90, h", ("lateness_hours", "p90"), False),
    ("lateness max, h", ("lateness_hours", "max"), False),
    ("cron times counted (daily-or-rarer)", ("cron_times", "daily_expected"), False),
    ("of them with no run", ("cron_times", "daily_missing"), False),
    ("red streaks", ("red_streaks", "all"), True),
    ("turned green inside the window", ("red_streaks", "closed"), True),
    ("still red at the end", ("red_streaks", "still_red"), False),
    ("red for, median h", ("red_streaks", "red_hours", "median"), False),
    ("release commits", ("releases", "release_commits"), True),
    ("pin refresh commits", ("releases", "pin_refresh_commits"), True),
    ("reverts", ("releases", "reverts"), False),
    ("Kubernetes freshness checks that ran", ("k8s_freshness", "ran_in_window"), False),
    ("Kubernetes freshness checks", ("k8s_freshness", "workflows"), False),
    ("runs no automation explains", ("unexplained", "runs"), False),
    ("commits no automation explains", ("unexplained", "commits"), False),
    ("people outside waiting at the end", ("outside", "waiting_at_end"), False),
    ("longest wait, h", ("outside", "longest_wait_h"), False),
    ("Actions minutes a day, window", ("minutes", "window_per_day"), False),
    ("Actions minutes a day, before", ("minutes", "before_per_day"), False),
]


def dig(d, path):
    for k in path:
        if not isinstance(d, dict) or d.get(k) is None:
            return None
        d = d[k]
    return d


def cmd_compare(args):
    a, b = json.load(open(args.baseline)), json.load(open(args.current))
    ha, hb = a["window"]["hours"], b["window"]["hours"]
    print("| measure | %s → %s | per 24 h | %s → %s | per 24 h |" % (a["window"]["start"][:10], a["window"]["end"][:10],
                                                                b["window"]["start"][:10], b["window"]["end"][:10]))
    print("|---|---:|---:|---:|---:|")
    for label, path, rate in ROWS:
        va, vb = dig(a, path), dig(b, path)
        fa = "–" if va is None else va
        fb = "–" if vb is None else vb
        ra = round(va * 24 / ha, 1) if rate and va is not None else ""
        rb = round(vb * 24 / hb, 1) if rate and vb is not None else ""
        print("| %s | %s | %s | %s | %s |" % (label, fa, ra, fb, rb))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    c = sp.add_parser("collect")
    c.add_argument("--start", required=True)
    c.add_argument("--end", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--owner", default="heyvaldemar")
    c.add_argument("--lookback-hours", type=float, default=24)
    c.add_argument("--parts", default="repos,workflows,runs,outside,minutes")
    r = sp.add_parser("report")
    r.add_argument("dir")
    r.add_argument("--json")
    m = sp.add_parser("compare")
    m.add_argument("baseline")
    m.add_argument("current")
    args = ap.parse_args()
    {"collect": cmd_collect, "report": cmd_report, "compare": cmd_compare}[args.cmd](args)


if __name__ == "__main__":
    main()
