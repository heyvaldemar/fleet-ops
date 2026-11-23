# Operator-absence drill

Written 2026-11-22. Rules for a planned window in which nobody operates the fleet, the measurement that
goes with it, and November's unplanned stop as the thing January is compared with.

## Why

From 2026-11-16 23:06Z to 2026-11-22 03:00Z the account's weekly limit stopped every Claude Code session and
every claude.ai routine, and the GitHub Actions fleet kept running. Nobody had chosen that, so what the stop
showed was partly luck: two self-checks were already red when it began, a push queue waited five days for a
person, and two users' questions went unanswered for six. The drill repeats the stop on purpose, announced
and prepared, to find out which of those were luck and which were design.

Planned window: **2027-01-17T00:00:00Z → 2027-01-20T00:00:00Z** (72 h, Sunday to Wednesday). The window is
always written as two UTC timestamps and passed to the script as they are.

It is chosen to hold what it tests. The weekly Kubernetes freshness checks (below) have a Monday cron,
05:17-05:53Z, and GitHub creates the run 8-10 hours late (November: median 9.0 h, max 9.9 h). Monday
2027-01-18 sits inside the window end to end, so each check has a cron time and its run. November's window
held none: it began on Monday 16.11 at 20:03Z, and the Monday checks of 16.11 had run at 13:36-14:02Z, before it
opened (the next were due 23.11). The report prints a rule with no cron time in the window as not tested,
never as passed.

## What is switched off, what stays on

Off for the whole window, from the first second:

| thing | how it is off | what the report should show |
|---|---|---|
| every Claude Code session | none is started, none is continued; nobody sends one a message | no write by the owner account outside an automation run (F) |
| Mac scheduled tasks | paused, not left to be refused: a paused task attempts nothing, a refused one writes a failed run | an empty run list for the window |
| claude.ai routines (the cloud watcher, the deadline and poll routine, the mail routine, briefs, the reminder, the upstream radar) | paused | an empty run list for the window |
| the owner's own hands | no push, merge, release, comment, review or reply on GitHub | F: 0 runs and 0 commits no automation explains |

On, and the point of the drill:

- GitHub Actions everywhere: scheduled workflows, Dependabot and its auto-merge, the release pipeline.
- The fleet's own jobs in the public copy of fleet-ops: triage (twice a day), catalog, conformance, heartbeat,
  lifecycle, scout, and the site's numbers copied from the catalog.
- The triage's upstream review. It calls a model from inside the workflow with the job's OIDC token and no
  key, billed apart from the claude.ai limit. It ran all November and runs in January. So the honest sentence
  is "no session and no routine ran", never "no model ran".
- Cloudflare Pages builds and the external heartbeat witness.

Not part of the window: the private repositories and forks. The script's repository query asks for public
repositories only, so a private name never reaches its data directory.

## Before the window: the start gate

November began on an unprepared stop, so its baseline has things that were wrong before the stop and are
wrong for reasons that have nothing to do with absence. The drill does not start until:

1. **Fleet Conformance and Fleet heartbeat are green** in the public copy of fleet-ops. In November they were
   red before the stop (conformance since 2026-11-14 17:38Z, heartbeat since 2026-11-15 14:42Z) and stayed
   red for all five days on the same findings, so their red says nothing about absence.
2. **No outside issue or pull request is waiting** for the owner. In November two had waited since 16.11.
3. **The push queue is empty or declared.** In November three pushes into the private source repository queued for
   2026-11-17 03:00Z and waited for a person until 22.11 03:30Z (the first of them; the others later). A queue is allowed to wait in the drill; the list of what waits is written down
   before the window opens, so that "what waited" (the report cannot see it: that repository is private) is
   a comparison of two lists.
4. **The public copy equals the private source**: the last publish ran green.
5. The paused routines and tasks are listed by name, with the time each was paused.

Write the time of the last owner or session write to GitHub down. The script finds the first write in the
window by itself, in F; the last one before it is what shows the gap.

## During: if somebody has to act

Any write by the owner account in the window that no automation run explains is listed by F and counts as an
operator. It does not restart the drill; the window runs to its end and the report says from what time it was
not an absence any more. Nothing is hidden by looking away: the owner may read.

## After: collect and report

The window must have ended. About 250 API calls for a 72 h window over some 120 public repositories, one
serial pass, no parallel loops: the quota is the account's, shared with every job that runs as the owner.
Check it first.

```bash
gh api rate_limit --jq '.resources | {core: .core.remaining, graphql: .graphql.remaining, search: .search.remaining}'
```

```bash
scripts/absence-report.py collect --start 2027-01-17T00:00:00Z --end 2027-01-20T00:00:00Z --out "$DIR"
```

```bash
scripts/absence-report.py report "$DIR" --json "$DIR/summary.json" > "$DIR/report.md"
```

```bash
scripts/absence-report.py compare tests/fixtures/absence-2026-11/summary.json "$DIR/summary.json"
```

`collect` takes `--parts` to redo one source (`repos,workflows,runs,outside,minutes`). The data directory holds
public facts and times only (run ids, results, cron lines, commit headlines and, for people outside, only the
times they wrote), never a login that is neither the owner's nor a bot's, and can be committed as it is.
`tests/fixtures/absence-2026-11` is November's.

The report's sections: A runs by event; B scheduled runs and how late GitHub created them; B2 cron times with
no run; C red streaks and what turned each green; D releases, pin refreshes, reverts; E Kubernetes
freshness; F who acted; G people outside; H Actions minutes; I the fleet's own jobs; J per repository. The
rules each number follows are in the script's header, and `tests/test-absence-report.sh` plants every one.

### What the script does not see

The private repositories (the push queue, the watcher's runs, the private heartbeat); Cloudflare Pages
builds (check runs, not workflow runs: read them on the commits of heyvaldemar-com); the external witness;
anything on claude.ai or the Mac. Those are read by hand after the window, and each line of the table below
says where.

## What counts as a failure

| id | rule | pass | fail | November (public repositories) |
|---|---|---|---|---|
| D1 | every daily-or-rarer cron time in the window's whole days has a run (B2) | 0 missing | any missing | 0 of 922 |
| D1b | no run is created 24 h or more after its cron time (the method ties a run to the latest cron time before it, which is exact only under a day) | max < 24 h | read by hand | max 9.9 h |
| D2 | the fleet's own jobs: every scheduled triage, catalog, conformance and heartbeat run is green (I), given the start gate | all green | any red | triage 11/11, catalog 5/5; conformance 0/6 and heartbeat 0/5 (red before the stop) |
| D3 | every red streak is closed by the fleet or is a thing the fleet is designed to hand to a person (a bump the triage will not apply alone, named «needs a human» in its report) (C) | none left over | a still-red streak the triage report does not name | 63 of 72 closed, 9 still red (7 of them Pin Freshness waiting on a human decision, plus conformance and heartbeat) |
| D4 | nobody operated (F) | 0 runs, 0 commits | any | 4 runs and 1 commit, all the release that opened the window |
| D5 | an automatic revert is a pass if it leaves main green; it is listed (D) | main green after it | main still red 24 h after | 1 revert, main red 8.8 h |
| D6 | **new since November.** Every Kubernetes repository with a scheduled freshness check had a run for each cron time in the window (E) | all ran | a cron time with no run, or a Kubernetes repository with none | 0 workflows with a cron time in the window: not tested |
| D7 | **new since November.** No person outside waits more than 48 h at the end, counted from their last message with no reply (G), and a question opened in the first 24 h got an answer from the fleet | 0 waiting > 48 h | any | 2 waiting, 143.2 h and 144.3 h; none opened in the window: the answer path not tested |
| D8 | **new since November.** A red watcher names the cause the log supports (manual, below) | the text says nobody is answering by design, or the wake is skipped with that reason | the text sends the reader to debug a routine that is paused, or hides that a limit refused it | red twice on «read its last runs on claude.ai» while every wake was refused by the limit |
| D9 | minutes a day stay near November's (H); a day above twice November's is read by hand | ≤ 2× | > 2× unexplained | 2,423 a day (public) |

Lateness (B) is reported, not judged: it is GitHub's scheduler, it was 8–10 h before the stop too (on 15.11
the heartbeat cron 07:15 ran at 14:45), and a change in it is a change in GitHub.

### D6 in practice

Read at 2026-11-22 from the workflow files at each repository's default branch (GitHub code search for
`check-freshness.py` under `.github/workflows`, then the files), eight repositories call it, each on a Monday
cron: kubernetes-postgres-recovery (`29 5 * * 1`), cypress-cloud-triage-agent (`53 5 * * 1`),
kubernetes-ai-agent-sandbox, kubernetes-supply-chain-admission, kubernetes-air-gapped-ai-agent and
kubernetes-coder-agent-workspaces (`37 5 * * 1`), oxy-llm-gateway (`41 5 * * 1`) and aws-eks-reference-platform
(`17 5 * * 1`). `collect` rereads the files at the window's end, so the January table is the January list.

The check fails a pin only when upstream's newer release is three days old or more; younger is a warning.
These repositories are outside fleet triage, so a failed freshness run is for a person, and in the drill it
stays failed. That is expected: D6 asks whether the check ran and said so, not whether the pins were moved.

### D7 in practice

Canary: decision of the owner before the start. A question can only be answered if someone asks one; without a
canary, D7 is tested only if a real person writes in the window, and is reported as not tested otherwise.

### D8 in practice (the one rule the script cannot read)

The watcher is `Cloud watchers` in the private source repository (private: its runs are not in the report). After the
window, for each red run in it, read the annotation text only:

```bash
gh api "repos/$PRIVATE_SOURCE_REPO/check-runs/$CHECK_RUN_ID/annotations" --jq '.[].message'
```

`CHECK_RUN_ID` is the job's id from `gh run view <run> --repo "$PRIVATE_SOURCE_REPO" --json jobs`. Print
the messages and nothing else from that response.

## What changed after November: the fixes under test

Each item is a thing November got wrong, what exists on 2026-11-22, and which rule checks it in January. The
third column is as far as this file can see; the commit is added when a fix lands.

| November | what exists on 2026-11-22 | checked by |
|---|---|---|
| **Kubernetes freshness was not measured.** `check-freshness.py` was called by none of the 403 scheduled workflow files that ran in the window, so nothing watched Kubernetes pin drift during the stop. (The weekly checks have a Monday cron, and the window held no Monday.) | one `check-freshness.py` for every Kubernetes repository, with a three-day release-age grace (templates/check-freshness.py; fleet conformance holds each copy to it byte for byte), eight repositories scheduled on Mondays (list above). Still open: four repositories without it (kubernetes-llm-inference-gateway, kubernetes-oscal-evidence, netpol-first-instant, agent-security-benchmark) and the question of twice-weekly runs. | D6, E, and the choice of window above |
| **Users went unanswered.** [keycloak#54](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/issues/54) (opened 16.11 03:48Z) and [zabbix#14](https://github.com/heyvaldemar/zabbix-docker-compose/issues/14) (16.11 02:42Z) were flagged by the heartbeat every day from 18.11 and still had no reply at the end (143–144 h). Detection worked; nothing answered. | both were answered and closed on 2026-11-22 (05:11Z) by a session. No workflow on main answers an outsider. | D7, G, and the start gate |
| **The watcher blamed the wrong thing.** On 20.11 and 21.11 `Cloud watchers` went red with «outbox item(s) woke the cloud routine four times and are still not handled: read its last runs on claude.ai». The runs on claude.ai show every wake refused by `rate_limit: rejected (seven_day)`: nothing was wrong with the routine. | the step's text is unchanged on main (`An item four wakes old is red`). Since 6122eb4 the watcher runs pinned code from a state branch. | D8 |
| **Two self-checks were already red.** Fleet Conformance (14.11, on oxy-llm-gateway, which cannot meet four template-only rules) and heartbeat (15.11, on growing findings). | conformance skips those four rules for a named gateway (913ca79, on main since the 22.11 04:31Z push). The heartbeat's findings (an unanswered pair of issues, a repository with no check on main) were not changes to the heartbeat. | the start gate |

## November, the reference

Window 2026-11-16T20:03:41Z → 2026-11-22T03:00:00Z, 126.9 h. The window opens at the last write a session made
(a release of a small image repository), so the five items in F are that write and what it started.
Public repositories only, 122 of them: the numbers are lower than the fact file's by what its private
repositories did (2,851 runs in 126 repositories there; 2,784 in 122 here). Regenerate any line with
`scripts/absence-report.py report tests/fixtures/absence-2026-11`; `tests/fixtures/absence-2026-11/summary.json`
is the script's summary of it, and the test fails if the two ever differ.

What stopped, and when (from the fact file; claude.ai and Mac times are the services' own):

| | |
|---|---|
| last write by a session | 2026-11-16 20:23:56Z |
| weekly limit hit | between 22:28:25Z and 23:06:06Z on 16.11 |
| limit lifted | 2026-11-22 03:00:00Z |
| first write by a session after it | 2026-11-22 03:30:12Z |
| no session write | 5 d 7 h 6 min |
| agent runs refused | 52 cloud routine runs (7 routines) and every Mac task run from 16.11 23:06Z to 19.11 17:05Z |

Headline numbers (the same as the JSON, `compare` prints them per 24 h):

| measure | November |
|---|---:|
| runs | 2,784 (1,891 success, 111 failure, 782 skipped) |
| scheduled runs | 1,134 (1,043 green, 91 red) |
| lateness of daily-or-rarer crons, 1,123 runs | median 9.0 h, p10 8.2, p90 9.6, max 9.9 |
| daily cron times with no run | 0 of 922 (cron times 17.11 00:00Z → 21.11 00:00Z) |
| red streaks | 72 (111 red runs); 63 closed with no person, 9 still red at the end |
| how the 63 closed | 52 re-run dispatched by the triage after it refreshed and released the pin, 7 next scheduled run, 3 push by the triage, 1 next run of the workflow it follows |
| red for, the 63 | median 10.2 h, p90 23.3 h, max 33.5 h |
| release commits | 80 in 48 repositories (81 runs started by a published release) |
| pin refreshes | 81 in 49 repositories; 1 revert (humanitz, main red 8.8 h) |
| runs no automation explains | 4 and 1 commit (the release that opened the window) |
| people outside waiting at the end | 2, longest 144.3 h; none opened in the window |
| Actions minutes a day, public repositories | 2,423 while stopped, 10,663 over the five days before |

Scheduled runs by cron day (daily-or-rarer crons):

| cron day | runs | median late, h | max late, h |
|---|---:|---:|---:|
| 2026-11-17 | 319 | 9.4 | 9.9 |
| 2026-11-18 | 201 | 9.0 | 9.5 |
| 2026-11-19 | 201 | 9.2 | 9.6 |
| 2026-11-20 | 201 | 8.8 | 9.3 |
| 2026-11-21 | 199 | 8.2 | 8.5 |

The fleet's own jobs (public copy of fleet-ops):

| job | runs | result |
|---|---:|---|
| Fleet Triage | 11 | 11 green: refreshed pins, released, re-ran checks, reverted one push, rewrote its report each run |
| Fleet catalog | 5 | 5 green: regenerated the catalog once a day, and the site's numbers followed it |
| Fleet Conformance | 6 | 6 red, «1 of 84 do not meet the standard» (red since 14.11) |
| Fleet heartbeat | 5 | 5 red, the same findings every day with the clocks growing (red since 15.11) |

What waited for a person, public items only: a feature request and a bug report with no reply
(keycloak#54, zabbix#14); seven template bumps the triage would not apply alone (rocketchat 9.0.0, gitlab
19.6.0 and 19.6.1, anythingllm 1.20.0, dify 1.20.0, diun 4.34.0, docmost 0.98.0), each «needs a human»;
one reverted pin refresh (humanitz); four upstream threads updated by others that nobody read; the planned
upstream follow-ups.

What the table does not carry: the claude.ai and Mac refusal logs, the private repositories' runs, and the
Cloudflare Pages builds (5 of 5 green after the catalog's five commits to the site, 3–4 min each).

## Files

- `scripts/absence-report.py`: `collect`, `report`, `compare`.
- `tests/test-absence-report.sh`: plants each rule, runs the collector against a stand-in for `gh` that also
  answers for a private repository, and runs November's recorded sweep through the same code.
- `tests/fixtures/absence-2026-11/`: November's sweep in the script's data format (public repositories only).
- `tests/fixtures/absence-2026-11/summary.json`: its summary, the left side of `compare`.
