#!/usr/bin/env python3
"""Are the jobs that watch the fleet still running at all?

    fleet-heartbeat.py [--repo owner/name] [--tolerance 2.0] [--json beat.json]
    fleet-heartbeat.py --failing       this repository's own jobs that run and fail
    fleet-heartbeat.py --fleet          the same question asked of every public repository

Everything here is scheduled: the catalog daily, triage twice a day,
conformance daily, the scout and the lifecycle review on Mondays. Each one
fails loudly when it finds something wrong. None of them can fail when it stops
running, and that is the failure with no symptom - the profile keeps showing
the numbers it last wrote, the catalog keeps showing yesterday's releases, and
everything looks exactly as it did when it worked.

Three ways that happens, all of them quiet:

  - GitHub disables a scheduled workflow after 60 days without activity in the
    repository, which is a state on the workflow, not a failed run;
  - a personal access token expires, and a workflow that cannot check out the
    repository it writes to never gets far enough to do anything;
  - a schedule simply does not fire. GitHub's own documentation says scheduled
    runs may be delayed or dropped under load.

So this reads what GitHub knows about every scheduled workflow in the
repository - its state, and when it last COMPLETED a scheduled run - and goes
red when one has been quiet for longer than its own interval allows. The list
of workflows is read from the directory, never written out here: a list kept by
hand falls behind the files it describes, which is the exact fault it would be
looking for.

AND TWO THINGS NOTHING ELSE COVERS, both of them consequences of switching
off GitHub's Actions emails on 2026-09-14.

Fleet triage walks repositories whose names end in -docker-compose, -docker or
-terraform, and opens an issue for anything in them that needs a person. Twenty
one public repositories match none of those patterns — the operations tools
this account publishes among them — and a red run in one of those now reaches
nobody at all. So --fleet reports a FAILING workflow in exactly the
repositories triage does not walk, and only there: inside triage's list a red
freshness job is the designed alarm and saying it twice is how a report stops
being read.

And a Dependabot pull request nobody merged. Most repositories here carry a
workflow that merges one after its own CI goes green; three do not have that
file at all, so their pull requests sit open for ever and the notification mail
was the only thing saying so. One had been waiting thirty-six hours.

AND THE SAME QUESTION FOR THE TEMPLATES. Every repository in the fleet boots
itself in CI on a daily schedule, and that is the claim the profile makes in
one sentence. A template nobody has touched for two months is exactly the one
GitHub disables the schedule on, and the badge in its README goes on showing
the last run that happened. --fleet asks GitHub about every public repository:
any workflow it has disabled, and any schedule that has stopped firing. The
interval is not read from the cron there but measured from the runs themselves,
so a weekly job is judged as weekly without this file being told.

AND A JOB THAT RUNS AND FAILS EVERY TIME.
Everything above measures whether a schedule FIRED, which is the right question
for the fleet: a template's freshness job going red is the designed alarm, and
triage consumes it. It is the wrong question for the machinery in this
repository. Until 2026-09-14 a broken job here was covered by GitHub's own
failure email; those were switched off that day, because eighteen of every
twenty were "a robot will fix this in forty minutes". That left nothing at all
watching for the case where triage itself cannot run — an expired token, an API
that moved, a bug pushed at five o'clock. Every issue this repository opens is
gated on a FINDING, and a job that crashes produces no findings.

So --failing reads the conclusions of this repository's own scheduled runs and
reports a workflow whose latest scheduled run failed and which has not had a
successful one inside its own interval. One flake is not a finding; a job that
has been failing since yesterday is.

WHO WATCHES THIS ONE. Two jobs run it: this heartbeat every morning, and the
weekly lab sweep. Each checks every scheduled workflow including the other, so
if the heartbeat stops the sweep says so within a week, and if the sweep stops
the heartbeat says so the next morning. If both stop at once, the cause is that
GitHub disabled the schedules, and GitHub emails about that itself. There is no
fourth case where this repository is silent and nothing anywhere notices.
"""
import argparse
import base64
import datetime
import glob
import io
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import time
import urllib.request
import sys

# `- cron:` at the start of a list item, with whatever YAML allows after it.
# THE TRAILING COMMENT IS THE POINT. The first version required the line to end
# at the closing quote, so `- cron: '0 12 * * *'  # an hour before triage` was
# not a cron line at all - and fleet-conformance.yml, whose first schedule is
# written exactly like that, came back with one schedule instead of two. A
# workflow whose only cron carried a comment would have been read as having no
# schedule and dropped from this check without a word, which is the fault this
# file exists to catch, committed by the file itself.
CRON = re.compile(r"^\s+-\s*cron:\s*(?:'([^']*)'|\"([^\"]*)\"|([^#\s].*?))\s*(?:#.*)?$")


def cron_of(line):
    m = CRON.match(line)
    if not m:
        return None
    return (m.group(1) or m.group(2) or m.group(3) or "").strip() or None


# A FINDING THAT IS TRUE, FILED, AND NOT GOING TO CHANGE TODAY.
#
# On 2026-09-18 this job learned to look at the private half of the fleet and
# found eleven repositories its token cannot read. That is a real gap and it
# is reported. It is also a decision only the account's owner can make, and it
# turned this job red twice a day for as long as it went unmade.
#
# A job that is red every day cannot also mean "a watcher died last night",
# and that second meaning is the only reason this file exists. So a finding
# of this kind is printed, carried into the report and the JSON, and left out
# of the exit code. Nothing earns that on its own: it is standing only while
# it matches a baseline someone wrote down by hand, and the moment it grows
# past that baseline it is new again, and new is what a red run is for.
STANDING_PREFIX = "(standing) "


def is_standing(finding):
    return finding.startswith(STANDING_PREFIX)


def plain_finding(finding):
    return finding[len(STANDING_PREFIX):] if is_standing(finding) else finding


def known_gaps():
    """Repositories this token is known not to read, accepted on purpose.

    This is the second half of the finding's own sentence: "or accept that
    they are unwatched." Accepting it is an edit to a file that shows up in a
    diff and in review, never a default and never something this script
    decides for itself. A repository that becomes unreadable and is not named
    here has not been accepted by anyone.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "known-gaps.txt")
    try:
        lines = io.open(path, encoding="utf-8").read().splitlines()
    except OSError:
        # Absent means nothing has been accepted, which is the safe reading:
        # every gap then counts as new and turns the run red.
        return set()
    return {ln.strip() for ln in lines if ln.strip() and not ln.startswith("#")}


def report(findings):
    """Print every finding and answer how many of them should turn this red."""
    blocking = [f for f in findings if not is_standing(f)]
    for f in findings:
        if is_standing(f):
            print("::notice::%s" % plain_finding(f))
        else:
            print("::error::%s" % f)
    standing = len(findings) - len(blocking)
    if standing:
        print("%d finding(s) above are standing: reported, already filed, and waiting on a "
              "decision this job cannot make. They are not what a red run here means — see "
              "scripts/known-gaps.txt." % standing)
    return len(blocking)


def gh(path):
    try:
        return json.loads(subprocess.check_output(["gh", "api", path], stderr=subprocess.PIPE))
    except subprocess.CalledProcessError as e:
        lines = (e.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        sys.exit("cannot read %s: %s" % (path, lines[0] if lines else "gh api failed"))


def gh_exists(path):
    """Whether something is there, with 404 as an answer rather than a failure.

    gh() above exits on any error, which is right for a listing that must not
    come back empty and wrong for a question whose answer can legitimately be
    "no". Only a 404 counts as absent here. Anything else, an expired token
    above all, would otherwise report every repository in the fleet as missing
    every file, and ninety-four findings that are all the same bug is worse
    than one finding that says the credential died.
    """
    p = subprocess.run(["gh", "api", path], capture_output=True)
    if p.returncode == 0:
        return True
    err = (p.stderr or b"").decode("utf-8", "replace")
    if "404" in err or "Not Found" in err:
        return False
    first = err.strip().splitlines()
    sys.exit("cannot read %s: %s" % (path, first[0] if first else "gh api failed"))


def gh_or_none(path):
    """gh(), with a repository this credential may not read as an answer.

    gh() exits on any error, and the private half of the account holds
    repositories the fleet token is not allowed to see: the first loop to ask
    one of them for its workflows would end the whole run. 403 and 404 come
    back as None; anything else, an expired token above all, still exits.
    """
    p = subprocess.run(["gh", "api", path], capture_output=True)
    if p.returncode == 0:
        return json.loads(p.stdout)
    err = (p.stderr or b"").decode("utf-8", "replace")
    if any(k in err for k in ("404", "Not Found", "403", "Resource not accessible")):
        return None
    first = err.strip().splitlines()
    sys.exit("cannot read %s: %s" % (path, first[0] if first else "gh api failed"))


# The supply-chain files every repository here carries: Dependabot to move the
# pinned action SHAs, Scorecard to score what that buys, and the automerge that
# waits for the repository's own verification before taking an update.
STANDARD_WORKFLOWS = ("scorecard.yml", "dependabot-automerge.yml")

# Filled from the repository listing, so unverified_heads asks about the branch
# a repository actually uses rather than assuming main.
DEFAULT_BRANCH = {}


# THE TWO THINGS A SECURITY REVIEWER OPENS FIRST. SECURITY.md says where a
# report goes; the branch rules say whether main can be rewritten. On
# 2026-09-24 OpenSSF Scorecard, read across all 97 public repositories, had
# nine without a policy and 91 without any rule on main, and nothing here had
# ever asked. Both are cheap, both are scored by a third party, and a new
# repository would have shipped without either again.
STANDARD_FILES = ("SECURITY.md",)
BRANCH_RULES = ("non_fast_forward", "deletion")
# A repository that publishes releases signs them: the archive, the keyless
# signature and the SLSA provenance come from this workflow, rolled out on
# 2026-09-24. A repository with no release yet is not asked for it.
RELEASE_WORKFLOW = "release-assets.yml"


URL_RE = re.compile(r"https?://[^\s)>\]\"']+")
CODE_RE = re.compile(r"```.*?```|`[^`\n]*`", re.S)


def policy_links(text):
    """Every URL a SECURITY.md names, without trailing punctuation. A URL
    inside code is an argument, not a place a reporter is sent: the cosign
    identity regexp and OIDC issuer in aws-kubectl-docker's policy tripped
    the first sweep of this rule (2026-09-25)."""
    prose = CODE_RE.sub(" ", text or "")
    return sorted({u.rstrip(".,;:") for u in URL_RE.findall(prose)})


_LINK_CACHE = {}


def dead_links(urls, fetch=None, sleep=time.sleep, cache=None):
    """The URLs that do not answer. A policy that sends a reporter to a 404
    has no channel: every SECURITY.md in the fleet did, from April to
    2026-09-25, and nothing opened the link.

    ONCE PER SWEEP, AND ASKED TWICE. Ninety-seven policies name the same
    page, and the first version asked it ninety-seven times a sweep; on
    2026-09-26 one of those answers did not come and one repository was
    reported as sending reporters to a page that answered 200 before and
    after. A URL is asked once per run, and a failure is asked again after a
    pause before it is called dead."""
    fetch = fetch or _http_status
    cache = _LINK_CACHE if cache is None else cache
    dead = []
    for u in urls:
        if u not in cache:
            ok = 200 <= fetch(u) < 400
            if not ok:
                sleep(5)
                ok = 200 <= fetch(u) < 400
            cache[u] = ok
        if not cache[u]:
            dead.append(u)
    return dead


def _http_status(url):
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "fleet-heartbeat"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status
    except urllib.error.HTTPError as e:
        if e.code in (403, 405):  # a host that refuses HEAD or bots: try GET
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "fleet-heartbeat"}), timeout=20) as r:
                    return r.status
            except Exception:
                return 0
        return e.code
    except Exception:
        return 0


def missing_branch_rules(rule_types):
    """Which of the two rules main lacks: no force-push, no deletion."""
    return [r for r in BRANCH_RULES if r not in rule_types]


def missing_standard_files(workflow_names, has_dependabot_config, has_security_policy=True, has_releases=False):
    """Which of the three a repository is missing, the policy file, and the
    release workflow where the repository publishes releases.

    There was no rule for this anywhere, and on 2026-09-15 one repository had
    been live for four days without any of them. The conformance check walks
    that repository by name and has nothing to say about these files; nothing
    else looks at all. The gap was not that a check failed, it was that the
    question had never been asked, which is the kind that survives any number
    of green runs.

    It lives in the heartbeat rather than in conformance because conformance
    walks templates and this applies to all ninety-four.
    """
    missing = [f for f in STANDARD_WORKFLOWS if f not in workflow_names]
    if not has_dependabot_config:
        missing.append(".github/dependabot.yml")
    if not has_security_policy:
        missing.append("SECURITY.md")
    if has_releases and RELEASE_WORKFLOW not in workflow_names:
        missing.append(RELEASE_WORKFLOW)
    return missing


def period_hours(cron):
    """How long between two firings, at the outside. Deliberately generous: a
    wrong answer here that is too small pages somebody for a job that is merely
    late, and an alarm that cries wolf is an alarm that gets muted."""
    f = cron.split()
    if len(f) != 5:
        return 24.0
    minute, hour, dom, _, dow = f
    if dow.strip() != "*":
        return 24.0 * 7
    if dom.strip() != "*":
        return 24.0 * 31
    if hour.startswith("*/"):
        return float(hour[2:])
    if hour == "*":
        return float(minute[2:]) / 60 if minute.startswith("*/") else 1.0
    return 24.0


MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "expected-workflows.txt")


def manifest_drift(root, manifest=MANIFEST):
    """The workflows this repository is supposed to carry, against the checkout.

    A commit from a broken clone deleted six of them on 2026-09-24 and the
    heartbeat, which lists what it watches from the checkout, watched fewer
    things and said nothing. The list may only change on purpose: a workflow
    named here and absent is a finding, and so is one present and unnamed,
    because a list that is allowed to fall behind the files is no list.
    """
    expected = {l.strip() for l in open(manifest, encoding="utf-8") if l.strip() and not l.startswith("#")}
    present = {os.path.basename(p) for p in glob.glob(os.path.join(root, ".github/workflows/*.yml"))}
    out = ["%s is named in scripts/expected-workflows.txt and is not in the checkout" % m for m in sorted(expected - present)]
    out += ["%s is in the checkout and not named in scripts/expected-workflows.txt" % u for u in sorted(present - expected)]
    return out


def scheduled_workflows(root):
    out = []
    for path in sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml"))):
        crons = [c for c in (cron_of(l) for l in open(path, encoding="utf-8")) if c]
        if crons:
            # Several schedules on one workflow: the loosest one is what this
            # may assume, because a job firing twice a day is still a job that
            # has fired if only one of the two lands.
            out.append((os.path.basename(path), max(period_hours(c) for c in crons), crons))
    return out


# Past this, a windowed answer is confirmed against an unwindowed one before
# it is allowed to become a finding. Chosen above every daily cron here and
# below the tolerance a daily schedule is judged by, so the extra request is
# made only where it changes an answer.
CONFIRM_AFTER_HOURS = 30


def last_fired(repo, ident):
    """When a workflow last FIRED on its schedule, whatever came of it.

    The first version asked for successful runs only, which made a job that
    runs every day and fails every day indistinguishable from one that has
    stopped running - and it reported the first as the second. GitLab's daily
    verification had failed three days running when this was written, and the
    check called it quiet. A failing run is GitHub's notification to send; this
    file answers one question, whether the schedule still fires.

    By numeric id, not by file name: GitHub also lists workflows it manages
    itself, whose "path" is not a file in the repository at all.
    """
    # ASKED BY DATE, NOT BY POSITION, AND NOT BY SORTING WHAT COMES BACK.
    #
    # Sorting ten records fixes an order that arrived wrong. It cannot fix a
    # page that holds the wrong ten. On 2026-09-16 a request for the ten most
    # recent scheduled runs of keycloak's deployment-verification.yml came back
    # carrying a run from 13 July, and this file reported a workflow that had
    # fired ninety minutes earlier as having stopped 1564 hours ago, a figure
    # matching that July run to the minute.
    #
    # A date filter removes the question. The server decides what falls inside
    # the window, and the newest of those is the answer whatever order they
    # arrive in. Thirty days is chosen against the longest schedule here: a
    # weekly cron with the tolerance applied is late at fourteen days, so
    # thirty leaves room and stays far under one page.
    since = (datetime.datetime.now(datetime.timezone.utc)
             - datetime.timedelta(days=30)).strftime("%Y-%m-%d")
    runs = gh("repos/%s/actions/workflows/%s/runs?event=schedule&per_page=100&created=%%3E%s"
              % (repo, ident, since))["workflow_runs"]
    if runs:
        newest = max(when(r) for r in runs)
        # TWO INDEPENDENT ANSWERS, AND THE NEWER ONE WINS.
        #
        # The date filter was supposed to end this and only made it rarer. On
        # 2026-09-22 this query answered for jediacademy's verification with
        # nothing newer than the 18th, while runs from the 19th, 20th, 21st and
        # 22nd sat in the same repository — the last of them finished two hours
        # before the run that asked. The report said a daily schedule had been
        # silent for ninety-eight hours, which is the one alarm here that has to
        # be believed.
        #
        # A run that EXISTS is proof the schedule fired; an absent one proves
        # nothing at all. So when the windowed answer looks old enough to
        # become a finding, ask again without the window and keep whichever is
        # newer. That can only ever remove a false alarm, never invent one.
        if (datetime.datetime.now(datetime.timezone.utc) - newest).total_seconds() > CONFIRM_AFTER_HOURS * 3600:
            again = newest_first(gh("repos/%s/actions/workflows/%s/runs?event=schedule&per_page=100"
                                    % (repo, ident))["workflow_runs"])
            if again:
                newest = max(newest, when(again[0]))
        return newest
    # Nothing inside the window at all. That is either a workflow with no
    # schedule, or one that stopped more than thirty days ago, and those are
    # different answers: the first must stay silent, the second must not. Ask
    # again without the window. Whatever comes back now is at least thirty days
    # old, so an imprecise answer here cannot invent an alarm, only confirm one.
    ever = newest_first(gh("repos/%s/actions/workflows/%s/runs?event=schedule&per_page=100"
                           % (repo, ident))["workflow_runs"])
    return when(ever[0]) if ever else None


def when(run):
    return datetime.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))


def newest_first(runs):
    """Runs in real recency order, newest first.

    THE API'S ORDER IS NOT A CONTRACT, AND IT BROKE. It is almost always newest
    first. On 2026-09-15 at 18:03 it was not: a request for the single most
    recent scheduled run of sops-env-git's tests.yml came back with the run
    from 2026-09-12, and this file reported a workflow that had run at 09:42
    that same morning as having stopped 81 hours earlier. Ten minutes later the
    identical request answered correctly, which is the worst version of this
    bug: it cannot be reproduced on demand and it looks like a real finding.

    That matters more here than almost anywhere else in this repository. This
    file is the last thing watching the machinery, and a watcher that cries
    wolf is worse than no watcher at all, because the real alarm that comes
    afterwards is indistinguishable from the false ones before it.

    Sorting costs nothing on ten records and is correct whatever order arrives.
    """
    return sorted(runs, key=lambda r: r.get("created_at") or "", reverse=True)


def declared_period(repo, path):
    """The interval from the workflow's own cron, read from the file.

    NOT INFERRED FROM THE RUNS. Inferring it was the first version: take the
    gaps between the last few runs and call the median the interval. Every
    weekly workflow in this fleet has exactly one scheduled run in its history,
    so there were no gaps to take a median of, the fallback said "daily", and
    the check reported 91 repositories as having stopped - on a Sunday, about
    jobs that run on Tuesday. A schedule states its interval; there is no need
    to guess at it.
    """
    try:
        body = json.loads(subprocess.check_output(
            ["gh", "api", "repos/%s/contents/%s" % (repo, path)], stderr=subprocess.DEVNULL))
    except subprocess.CalledProcessError:
        return None
    text = base64.b64decode(body.get("content", "")).decode("utf-8", "replace")
    crons = [c for c in (cron_of(l) for l in text.splitlines()) if c]
    return max(period_hours(c) for c in crons) if crons else None


# The repositories fleet triage walks. Anything else has no report of its own.
TRIAGED = re.compile(r"(docker-compose|docker|-terraform)$")


def list_owned(include_private):
    """Repositories this token owns, newest naming first.

    /user/repos, not /users/OWNER/repos: the second is PUBLIC ONLY, whatever
    the token can see, which is how the private half of this estate stayed
    invisible to every check in this file. fleet-triage.sh learned the same
    thing about the same endpoint and its comment says so.
    """
    out, page = [], 1
    while True:
        batch = gh("user/repos?affiliation=owner&per_page=100&page=%d&sort=full_name" % page)
        for r in batch:
            if r["archived"] or r["fork"]:
                continue
            if r["private"] and not include_private:
                continue
            out.append(r["full_name"])
            DEFAULT_BRANCH[r["full_name"]] = r.get("default_branch") or "main"
        if len(batch) < 100:
            break
        page += 1
    return out


# A SECOND CREDENTIAL, BECAUSE THIS CHECK ONLY NEEDS TO READ.
#
# Widening the fine-grained token this fleet already runs on would hand every
# job that writes — and they do write: branches, releases, issues — the same
# reach into the home-lab config and the live website. This one question,
# "is a Dependabot pull request sitting unmerged", needs Pull requests: read
# and nothing else. So it may be answered by a separate read-only token, and
# falls back to the ambient one when there is none, which is what happens
# today and must keep working unchanged.
READ_TOKEN = "FLEET_READ_TOKEN"

# Told apart from every other error, because the fix is one checkbox and the
# symptom is a whole fleet reporting itself clean.
NO_PR_PERMISSION = "the credential cannot list pull requests on this repository"

# Not a fault: Issues are off, and a pull request is an issue, so there are no
# pull requests here to watch. It still has to be told apart from the silence
# of a repository with none, because Dependabot does not know that either.
NO_PR_FEATURE = "this repository has pull requests turned off with its issues"


def pr_env(base):
    """The environment to ask about pull requests in. Never logged: the value
    is moved from one variable to another and never rendered."""
    env = dict(base)
    token = env.get(READ_TOKEN)
    if token:
        env["GH_TOKEN"] = token
        env.pop("GITHUB_TOKEN", None)          # gh prefers GH_TOKEN, but leave nothing to guess at
    return env


def open_prs(full):
    """(pull requests, error). A repository with issues disabled answers 404
    here, and that is "there are none to list", not a failure. Anything else is
    an error the caller reports: a repository this could not read is a
    repository nothing is watching, and the two must not look the same.

    Its own function so the suite can replace it. A check nobody can show a
    violation to is the thing this file exists to refuse."""
    attempts = [pr_env(os.environ)] if os.environ.get(READ_TOKEN) else []
    attempts.append(dict(os.environ))          # whatever the job already runs on
    err, missing = "gh api failed", False
    for env in attempts:
        try:
            return json.loads(subprocess.check_output(
                ["gh", "api", "repos/%s/pulls?state=open&per_page=50" % full],
                stderr=subprocess.PIPE, env=env)), None
        except subprocess.CalledProcessError as e:
            text = (e.stderr or b"").decode("utf-8", "replace").strip()
            if "404" in text or "Not Found" in text:
                # NOT "there are none". GitHub answers 404 rather than 403 when
                # a credential may not know the repository exists at all, so
                # this is either a repository with pull requests turned off or
                # one this token cannot see — and reading the second as the
                # first is how 105 repositories came back with 0 pull requests
                # and a clean report on 2026-09-20. Try the next credential,
                # and if none of them gets further, ask something that can tell
                # the two apart.
                missing = True
                continue
            err = text.splitlines()[0] if text else "gh api failed"
    if missing:
        for env in attempts:
            try:
                meta = json.loads(subprocess.check_output(
                    ["gh", "api", "repos/%s" % full], stderr=subprocess.PIPE, env=env))
            except subprocess.CalledProcessError:
                continue
            # THE REPOSITORY READS AND ITS PULL REQUEST LIST DOES NOT, which is
            # two different facts wearing the same status code.
            #
            # A pull request IS an issue on GitHub, so turning Issues off takes
            # the pull request endpoint with it and that repository answers 404
            # to anyone, including a credential that can read everything else
            # about it. The other cause is a credential without the Pull
            # requests permission, which GitHub also reports as 404 rather than
            # 403 on this route.
            #
            # Measured across all 105 repositories on this account: issues on,
            # the endpoint answered 103 times out of 103; issues off, it
            # refused 2 out of 2. No exceptions either way.
            if meta.get("has_issues") is False:
                return [], NO_PR_FEATURE
            return [], NO_PR_PERMISSION
        return [], "404 on %s with every credential — this token cannot see the repository" % full
    return [], err


def unverified_heads(owner, repos, now, hours=3):
    """Repositories whose main has sat with no check on it at all.

    A merge pushed with GITHUB_TOKEN triggers no workflow, so a Dependabot
    automerge used to leave main at a commit nothing had verified and the
    repository page showing its latest commit with no tick. On 2026-09-17 that
    was fourteen repositories, up from four two days earlier. The automerge now
    dispatches the verification after merging, and this is what notices if that
    dispatch ever stops working, because its failure mode is silence: the merge
    still lands, the page still updates, and nothing says a word.

    Three hours of grace, because a dispatched run has to be queued and
    started, and a head that is minutes old with no check yet is not a finding.
    """
    out = []
    for full in repos:
        head = gh("repos/%s/commits/%s" % (full, DEFAULT_BRANCH.get(full, "main")))
        landed = datetime.datetime.fromisoformat(
            head["commit"]["committer"]["date"].replace("Z", "+00:00"))
        age = (now - landed).total_seconds() / 3600
        if age < hours:
            continue
        checks = gh("repos/%s/commits/%s/check-runs?per_page=1" % (full, head["sha"]))
        if checks.get("total_count", 0) == 0:
            out.append("%s: main has sat at %s for %.0f hours with no check on it — nothing has verified what is there"
                       % (full, head["sha"][:8], age))
    return out


def waiting_on_us(owner, now, hours=48):
    """Issues and pull requests a person outside the fleet opened, still
    waiting for its maintainer to say something.

    Everything else here watches the machinery, and the machinery never
    watched the people it serves. On 2026-09-23 a Keycloak user asked for a
    way to tune Traefik's timeouts (keycloak #45). The request was reasonable,
    the fix was a day's work, and three days later it had no reply, because no
    job read the issue trackers of 97 repositories and the notification email
    went where every other notification goes. A question from outside is the
    one signal no test can produce, and silence is what a reader of the
    tracker sees.

    Waiting means: opened by someone who is not the owner and not a bot, open
    longer than `hours`, and either never answered or answered last by them.
    """
    q = urllib.parse.quote("user:%s is:open -author:%s" % (owner, owner))
    found = gh("search/issues?q=%s&per_page=100&sort=created&order=asc" % q) or {}
    out = []
    for it in found.get("items", []):
        who = (it.get("user") or {})
        if who.get("type") == "Bot" or who.get("login", "").endswith("[bot]"):
            continue
        opened = datetime.datetime.fromisoformat(it["created_at"].replace("Z", "+00:00"))
        age = (now - opened).total_seconds() / 3600
        if age < hours:
            continue
        full = it["repository_url"].split("/repos/", 1)[1]
        kind = "pull request" if "pull_request" in it else "issue"
        if it.get("comments", 0):
            thread = gh("repos/%s/issues/%d/comments?per_page=100" % (full, it["number"]))
            last = (thread[-1].get("user") or {}).get("login") if thread else None
            if last == owner:
                continue                       # answered; the next word is theirs
            said = "last word is %s's" % last
        else:
            said = "no reply at all"
        out.append("%s#%d: %s opened this %s %.0f hours ago and it has %s: %s"
                   % (full, it["number"], who.get("login", "someone"), kind, age, said, it["html_url"]))
    return out


def dependabot_branches(full):
    """Branch names Dependabot pushed and could not turn into a pull request.

    Its own function so the suite can replace it: the case it exists for cannot
    be produced on demand against a live repository."""
    try:
        refs = json.loads(subprocess.check_output(
            ["gh", "api", "repos/%s/branches?per_page=100" % full], stderr=subprocess.PIPE))
    except subprocess.CalledProcessError:
        return []
    return [b["name"] for b in refs if b.get("name", "").startswith("dependabot/")]


def stuck_dependabot(owner, repos, now, hours=24, stats=None):
    """Pull requests opened by Dependabot that nobody merged.

    Not a style point: three repositories here have no automerge workflow at
    all, so their pull requests wait for a human who was being told by an email
    that no longer arrives. A pull request open for a day has either failed its
    checks or has nothing watching it, and both are worth a line.
    """
    out = []
    unreadable, readable, why = [], [], ""
    denied = []
    seen = 0
    for full in repos:
        prs, err = open_prs(full)
        if not err:
            readable.append(full.split("/")[-1])
        if err == NO_PR_FEATURE:
            # DEPENDABOT DOES NOT KNOW EITHER. It clones, finds an update,
            # pushes a branch, and then fails to open the pull request that
            # would deliver it — quietly, on a schedule, for as long as nobody
            # looks. Two repositories here carried a branch from 2026-09-06
            # holding action digest bumps that had nowhere to go.
            for b in dependabot_branches(full):
                out.append("%s: Dependabot pushed %s and cannot open a pull request for it — "
                           "this repository has issues turned off, and a pull request is an issue. "
                           "Merge the branch, turn issues on, or stop Dependabot here."
                           % (full, b))
            continue
        if err == NO_PR_PERMISSION:
            denied.append(full.split("/")[-1])
            continue
        if err:
            # ONE FINDING, NOT ONE PER REPOSITORY. A token that cannot reach a
            # repository cannot reach eleven of them either, and eleven lines
            # saying so is eleven copies of a single fact — the shape this file
            # already refuses in missing_standard_files. The repositories are
            # named because the fix is scoped to them.
            unreadable.append(full.split("/")[-1])
            why = why or err
            continue
        for pr in prs or []:
            seen += 1
            if not pr["user"]["login"].startswith("dependabot"):
                continue
            age = (now - datetime.datetime.fromisoformat(pr["created_at"].replace("Z", "+00:00"))).total_seconds() / 3600
            if age >= hours:
                out.append("%s#%d has been open %.0f hours: %s" % (full, pr["number"], age, pr["title"][:70]))
    # A LIST THAT ACCEPTS WHAT NO LONGER NEEDS ACCEPTING IS A LIST THAT
    # ACCEPTS ANYTHING. Every name in known-gaps.txt buys silence for one
    # repository. The day access is widened, or a repository is renamed or
    # retired, that name goes on buying silence for nothing — and if the same
    # repository ever falls out of reach again it would be waved through as
    # standing instead of turning this red. So the list is checked against
    # what actually happened this run, and a name that no longer earns its
    # place is a finding like any other.
    # Only names this run actually READ. A name missing from the listing
    # altogether is not evidence of anything: the repository may be gone, or
    # this token may simply not see it, and telling him to delete the line for
    # a repository that still exists and is still unwatched is the one wrong
    # answer available here.
    # HOW MUCH OF THE FLEET THIS ACTUALLY LOOKED AT.
    #
    # A run that examined nothing and a run that found nothing print the same
    # empty result, and the second is the one this whole check exists to
    # produce. On 2026-09-20 a Dependabot pull request 45 hours old on
    # gaseous-server sat through a run that reported the fleet clean, and
    # nothing in the output could say whether it had been looked at.
    if denied:
        # Named, not just counted: the fix is per repository on the token, so a
        # number alone leaves him comparing two lists by hand. Capped, because
        # a hundred names is a wall and the count already carries the scale.
        shown = sorted(denied)
        names = ", ".join(shown[:20]) + ("" if len(shown) <= 20 else ", and %d more" % (len(shown) - 20))
        out.append("the credential can reach %d repository(ies) but not their pull request lists (%s). "
                   "Pull requests cannot be turned off on GitHub, so an accessible repository always "
                   "answers this endpoint — a 404 is the Pull requests permission missing. Grant "
                   "Pull requests: Read-only on the token behind FLEET_READ_PAT."
                   % (len(denied), names))
    if stats is not None:
        stats["given"] = len(repos)
        stats["read"] = len(readable)
        stats["prs"] = seen
        stats["denied"] = len(denied)
    if not repos:
        # The one blindness nothing else here would say out loud. A repository
        # that cannot be read is already reported by name above; a listing that
        # handed over nothing at all leaves this check with nothing to report
        # and no way to tell that apart from a quiet fleet.
        out.append("the stuck-pull-request check was handed no repositories at all — that is the "
                   "listing being broken, not the fleet being quiet")

    settled = sorted(known_gaps() & set(readable))
    if settled:
        out.append("this token can read %d repository(ies) that scripts/known-gaps.txt still "
                   "accepts as unwatched: %s. Delete those lines — while they stay, a repository "
                   "that falls out of reach again is waved through instead of reported."
                   % (len(settled), ", ".join(settled)))
    if unreadable:
        said = ("nothing is watching pull requests on %d repositories this token cannot read (%s) — %s. "
                "Widen the fine-grained PAT's repository access to include them, or accept that they are "
                "unwatched by naming them in scripts/known-gaps.txt."
                % (len(unreadable), ", ".join(sorted(unreadable)), why))
        fresh = sorted(set(unreadable) - known_gaps())
        if fresh:
            # NOT ON THE LIST, SO NOBODY HAS ACCEPTED IT. A repository that
            # drops out of reach after the baseline was written is the case
            # this check was built for, and it is worth a red run on its own.
            out.append("%s Nobody has accepted %s: %s"
                       % (said, "these" if len(fresh) > 1 else "this", ", ".join(fresh)))
        else:
            out.append(STANDING_PREFIX + said)
    return out


def schedule_late(full, wf, now, tolerance):
    """(finding or None, 1 if a schedule was judged else 0) for one workflow."""
    fired = last_fired(full, wf["id"])
    if fired is None:
        return None, 0                        # no schedule, or one that has never fired
    age = (now - fired).total_seconds() / 3600
    if age <= 24:
        return None, 1                        # inside a day: no schedule here is that fast
    period = declared_period(full, wf["path"])
    if period is None:
        return None, 0                        # scheduled runs but no cron now: descheduled on purpose
    if age > period * tolerance + 2:
        # A SCHEDULE CHANGED SINCE IT LAST FIRED HAS NOT MISSED ANYTHING YET.
        # On 2026-09-23 three templates went from a weekly cron to a daily one
        # at 15:41; their last run was the weekly one two days before, and this
        # would have reported them 62 hours late the next morning, before the
        # new daily time had even come round. The clock starts at whichever is
        # later: the last run, or the last change to the workflow file.
        changed = last_changed(full, wf["path"])
        if changed and changed > fired:
            age = (now - changed).total_seconds() / 3600
        if age > period * tolerance + 2:
            return ("%s: %s last fired %.0f hours ago; its cron is every %.0f hours"
                    % (full, wf["path"].split("/")[-1], age, period)), 1
    return None, 1


def last_changed(full, path):
    """When the workflow file last changed on the default branch, or None."""
    commits = gh_or_none("repos/%s/commits?path=%s&per_page=1" % (full, path))
    if not commits:
        return None
    return datetime.datetime.fromisoformat(commits[0]["commit"]["committer"]["date"].replace("Z", "+00:00"))


def fleet(owner, tolerance, now):
    """Every public repository: what GitHub has disabled, and what has stopped
    firing. The claim this fleet makes in one line - every template boots in CI
    daily - is only true while these schedules are alive, and a schedule that
    GitHub switches off after sixty days of quiet leaves the badge showing the
    last run it managed."""
    repos = list_owned(include_private=False)

    findings, checked, disabled = [], 0, 0
    for full in repos:
        workflows = gh("repos/%s/actions/workflows?per_page=100" % full)["workflows"]
        gone = missing_standard_files(
            {w["path"].split("/")[-1] for w in workflows
             if w["path"].startswith(".github/workflows/")},
            gh_exists("repos/%s/contents/.github/dependabot.yml" % full),
            gh_exists("repos/%s/contents/SECURITY.md" % full),
            gh_exists("repos/%s/releases/latest" % full))
        if gone:
            findings.append("%s: carries none of %s" % (full, ", ".join(gone))
                            if len(gone) >= 3 else
                            "%s: is missing %s" % (full, ", ".join(gone)))
        policy = gh_or_none("repos/%s/contents/SECURITY.md" % full)
        if policy and policy.get("content"):
            text = base64.b64decode(policy["content"]).decode("utf-8", "replace")
            for u in dead_links(policy_links(text)):
                findings.append("%s: SECURITY.md sends a reporter to %s, which does not answer" % (full, u))
        rules = gh_or_none("repos/%s/rules/branches/%s" % (full, DEFAULT_BRANCH.get(full, "main"))) or []
        lack = missing_branch_rules({r.get("type") for r in rules})
        if lack:
            findings.append("%s: %s has no rule against %s" % (
                full, DEFAULT_BRANCH.get(full, "main"),
                " or ".join({"non_fast_forward": "force-push", "deletion": "deletion"}[r] for r in lack)))
        for wf in workflows:
            if not wf["path"].startswith(".github/workflows/"):
                continue                      # GitHub's own, not this repository's
            name = wf["path"].split("/")[-1]
            if wf["state"] != "active":
                # The sixty-day case lands here. It is not a failed run, it is
                # not a red badge, and nothing else in this fleet looks for it.
                disabled += 1
                findings.append("%s: %s is %s" % (full, name, wf["state"]))
                continue
            # A RED RUN WHERE NOTHING ELSE LOOKS. Inside triage's list this is
            # the designed alarm and it has a report of its own; outside it,
            # with the Actions mail switched off, a failure reaches nobody.
            if not TRIAGED.search(full.split("/")[-1]):
                runs = newest_first(gh("repos/%s/actions/workflows/%s/runs?per_page=5"
                                       % (full, wf["id"]))["workflow_runs"])
                if runs and runs[0].get("conclusion") == "failure":
                    if not any(r.get("conclusion") == "success" for r in runs[1:3]):
                        findings.append("%s: %s has failed its last runs, and this repository has no triage report of its own" % (full, name))

            late, seen = schedule_late(full, wf, now, tolerance)
            checked += seen
            if late:
                findings.append(late)
    # THE PRIVATE HALF TOO, for this one check.
    #
    # Whether a pull request is stuck applies to every repository a person
    # owns. The schedule and standard-files checks above stay public-only on
    # purpose: a private config repository is not expected to carry Scorecard,
    # and reporting that every morning would be noise. But on 2026-09-18 two
    # Dependabot pull requests had been sitting on heyvaldemar-com, the live
    # website, for four and seven days, one of them green and mergeable the
    # whole time, and nothing here had ever looked at them — not because a
    # check failed but because the listing never handed them over.
    pr_stats = {}
    owned = list_owned(include_private=True)
    findings += stuck_dependabot(owner, owned, now, stats=pr_stats)
    findings += waiting_on_us(owner, now)
    # AND THE PRIVATE HALF'S SCHEDULES, only those two questions: is a schedule
    # disabled, and has one stopped firing. heyvaldemar-com, the live website,
    # carries the daily job that copies the fleet's numbers into its HTML, and
    # GitHub switches off a private repository's schedule after sixty quiet days
    # as readily as a public one's. The public-only checks above stay public:
    # a private config repository is not expected to carry Scorecard.
    for full in [r for r in owned if r not in repos]:
        listing = gh_or_none("repos/%s/actions/workflows?per_page=100" % full)
        if listing is None:
            continue                          # unreadable here is reported above, as standing
        for wf in listing["workflows"]:
            if not wf["path"].startswith(".github/workflows/"):
                continue
            if wf["state"] != "active":
                disabled += 1
                findings.append("%s: %s is %s" % (full, wf["path"].split("/")[-1], wf["state"]))
                continue
            late, seen = schedule_late(full, wf, now, tolerance)
            checked += seen
            if late:
                findings.append(late)
    findings += unverified_heads(owner, repos, now)
    return findings, len(repos), checked, disabled, pr_stats


def token_expiry():
    """When the credential everything here depends on stops working.

    A fine-grained token answers this in a response header. It is the single
    most likely quiet death of this machinery: the token expires, every job
    that writes anything starts failing, and the jobs that only read carry on
    looking healthy. An absent header is not a finding - a classic token or an
    OAuth session has no expiry to report - but it is said out loud, because
    "checked and there is nothing to report" and "could not check" must not
    look the same.
    """
    try:
        out = subprocess.check_output(["gh", "api", "user", "-i"], stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except subprocess.CalledProcessError:
        return None, "the token could not read /user at all"
    for line in out.splitlines():
        if line.lower().startswith("github-authentication-token-expiration:"):
            raw = line.split(":", 1)[1].strip()
            for fmt in ("%Y-%m-%d %H:%M:%S %Z", "%Y-%m-%d %H:%M:%S UTC", "%Y-%m-%dT%H:%M:%SZ"):
                try:
                    when = datetime.datetime.strptime(raw, fmt).replace(tzinfo=datetime.timezone.utc)
                    return when, raw
                except ValueError:
                    continue
            return None, "expiry header present but unparsed: %s" % raw
        if line.strip() == "":
            break
    return None, "no expiry header: this token does not expire, or does not say so"


def watch_drift(keep=("heyvaldemar/fleet-ops", "heyvaldemar/fleet-ops-private")):
    """Repositories this account is watching beyond the ones it means to.

    Every report the fleet produces is an issue in fleet-ops, and every report
    about the home servers an issue in fleet-ops-private, so those two are
    the repositories worth watching; the rest were turned down to Participating
    on 2026-09-15 to stop a hundred Dependabot threads a week. It drifts back
    on its own: GitHub subscribes the creator of a repository, and there is no
    longer a setting to opt out of that - the checkbox the documentation used
    to describe is gone from the notification settings page and from the
    documentation.

    So the policy is asserted here instead of remembered. Repositories owned by
    other people are left alone: watching somebody else's work is a decision,
    not drift.
    """
    subs, page, out = [], 1, []
    while page <= 5:
        b = gh("user/subscriptions?per_page=100&page=%d" % page)
        if not b:
            break
        subs += b
        if len(b) < 100:
            break
        page += 1
    mine = [r["full_name"] for r in subs
            if r["owner"]["login"] == "heyvaldemar" and r["full_name"] not in keep]
    if mine:
        out.append("watching %d of its own repositories beyond %s, so their Dependabot threads will mail again: %s"
                   % (len(mine), ", ".join(keep), ", ".join(sorted(mine)[:6]) + (" …" if len(mine) > 6 else "")))
    return out


def explained(workflow, finding, run_id=None):
    """THIS JOB GOING RED IS NOT NEWS ABOUT THIS JOB — WHEN IT WAS THE REPORT.

    It fails on purpose whenever it finds something, so its own red run arrived
    as a second finding underneath the first, saying only that the report above
    exists. A crash is different and has to stay loud.

    The first version asked whether a report was open, which loops: the report
    would contain nothing but this finding, close for having nothing to say,
    and reopen on the next run. What actually separates the two is WHICH STEP
    failed. The reporting step is the one that exits non-zero on findings;
    anything else failing is a crash, and that is the case this exists for.
    """
    if workflow != OWN_WORKFLOW or not run_id:
        return finding
    env = dict(os.environ)
    own = env.get(SELF_TOKEN)
    if own:
        env["GH_TOKEN"] = own
        env.pop("GITHUB_TOKEN", None)
    try:
        jobs = json.loads(subprocess.check_output(
            ["gh", "api", "repos/%s/actions/runs/%s/jobs" % (env.get("GITHUB_REPOSITORY", ""), run_id)],
            stderr=subprocess.PIPE, env=env))["jobs"]
    except (subprocess.CalledProcessError, ValueError, KeyError):
        return finding                     # could not check: stay loud
    failed = [st["name"] for j in jobs for st in (j.get("steps") or [])
              if st.get("conclusion") == "failure"]
    if not failed:
        return finding                     # failed with no failing step: say so
    if all(name == REPORT_STEP for name in failed):
        return STANDING_PREFIX + finding + " — it was the reporting step, which is this job saying it found something"
    return finding


REPORT_STEP = "Say it where it will be read"
OWN_WORKFLOW = "fleet-heartbeat.yml"
SELF_TOKEN = "FLEET_SELF_TOKEN"


def failing_here(repo, tolerance, now):
    """Scheduled workflows in THIS repository whose latest run failed and which
    have not succeeded inside their own interval."""
    findings, rows = [], []
    states = {w["path"].split("/")[-1]: w for w in gh("repos/%s/actions/workflows?per_page=100" % repo)["workflows"]}
    for name, period, _crons in scheduled_workflows("."):
        meta = states.get(name)
        if not meta or meta["state"] != "active":
            continue
        runs = newest_first(gh("repos/%s/actions/workflows/%s/runs?event=schedule&per_page=10"
                               % (repo, meta["id"]))["workflow_runs"])
        if not runs:
            continue
        latest = runs[0]
        if latest.get("conclusion") in (None, "success", "cancelled", "skipped"):
            rows.append((name, "ok", ""))
            continue
        ok = next((r for r in runs if r.get("conclusion") == "success"), None)
        age = (now - when(ok)).total_seconds() / 3600 if ok else None
        allowed = period * tolerance + 2
        if age is None:
            findings.append(explained(name,
                            "%s has never completed a scheduled run successfully, and its latest one ended in %s"
                            % (name, latest["conclusion"]), latest.get("id")))
            rows.append((name, "FAILING", "never green"))
        elif age > allowed:
            findings.append(explained(name,
                            "%s last succeeded %.0f hours ago and its latest scheduled run ended in %s; its schedule is every %.0f hours"
                            % (name, age, latest["conclusion"], period), latest.get("id")))
            rows.append((name, "FAILING", "%.0fh since green" % age))
        else:
            rows.append((name, "flaked", "green %.0fh ago" % age))
    return findings, rows


def push_workflows(root):
    """Workflows here that run on a push: `on: push` in any of its spellings."""
    out = []
    for path in sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml"))):
        text = open(path, encoding="utf-8").read()
        if re.search(r"(?m)^\s{1,4}push:\s*($|\n)", text) or re.search(r"(?m)^on:\s*(push\s*$|\[[^\]]*\bpush\b)", text):
            out.append(os.path.basename(path))
    return out


def red_on_main(repo, root="."):
    """Push-triggered workflows here whose latest run on main failed.

    The scheduled check never sees them: Verify runs on a push, not a cron,
    and it was red for fourteen hours on 2026-09-24/25 while every scheduled
    job was green and the heartbeat said the machinery was fine. With mail
    off, a red push run in a private repository reaches nobody; this line
    puts it in the same issue as everything else."""
    findings, rows = [], []
    states = {w["path"].split("/")[-1]: w for w in gh("repos/%s/actions/workflows?per_page=100" % repo)["workflows"]}
    # A workflow that also runs on a schedule is judged by failing_here, with
    # its tolerance for a flake; judged here as well it would be named twice,
    # and named for a push run its schedule has since succeeded past. The
    # first sweep of this rule did exactly that to fleet-catalog.yml.
    scheduled = {name for name, _period, _crons in scheduled_workflows(root)}
    for name in push_workflows(root):
        meta = states.get(name)
        if not meta or meta["state"] != "active" or name in scheduled:
            continue
        runs = newest_first(gh("repos/%s/actions/workflows/%s/runs?event=push&branch=main&per_page=1"
                               % (repo, meta["id"]))["workflow_runs"])
        if not runs or runs[0].get("conclusion") in (None, "success", "cancelled", "skipped"):
            rows.append((name, "ok", "on push"))
            continue
        findings.append(explained(name, "%s is red on main: its latest push run ended in %s"
                                  % (name, runs[0]["conclusion"]), runs[0].get("id")))
        rows.append((name, "FAILING", "red on main"))
    return findings, rows


def workflow_born(repo, name, now, max_details=20):
    """When a workflow file last came into being: the newest commit that ADDED it.

    The first version took the oldest commit that ever touched the path. In
    the private copy of this repository scorecard.yml was added on
    2026-09-05, deleted the same evening, and added again on 2026-09-25; the
    heartbeat called it 482 hours old and never fired, about a file that had
    existed for a day. A file's age runs from the last time it appeared.

    Walked newest-first, one commit detail per step, because only the detail
    says whether a commit added, changed or removed the file; bounded, since
    this is asked only of a workflow that has never fired, which is almost
    always a new one with a short history. Falls back to the oldest commit
    when the walk finds no add inside its bound, and to now when there is no
    history at all.
    """
    path = ".github/workflows/%s" % name
    commits = gh("repos/%s/commits?path=%s&per_page=100" % (repo, path)) or []
    when = lambda c: datetime.datetime.fromisoformat(c["commit"]["author"]["date"].replace("Z", "+00:00"))
    for c in commits[:max_details]:
        detail = gh("repos/%s/commits/%s" % (repo, c["sha"])) or {}
        if any(f.get("filename") == path and f.get("status") == "added" for f in detail.get("files") or []):
            return when(c)
    return when(commits[-1]) if commits else now


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--failing", action="store_true", help="this repository's own jobs that run and fail")
    ap.add_argument("--fleet", action="store_true", help="ask the same question of every public repository")
    ap.add_argument("--owner", default="heyvaldemar")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "heyvaldemar/fleet-ops"))
    ap.add_argument("--root", default=".")
    ap.add_argument("--tolerance", type=float, default=2.0,
                    help="how many intervals a workflow may miss before this is a finding")
    ap.add_argument("--json", dest="js")
    a = ap.parse_args()

    now = datetime.datetime.now(datetime.timezone.utc)

    if a.failing:
        findings, rows = failing_here(a.repo, a.tolerance, now)
        red, red_rows = red_on_main(a.repo)
        findings += red
        rows += red_rows
        findings += watch_drift()
        exp, note = token_expiry()
        if exp is not None:
            days = (exp - now).total_seconds() / 86400
            print("  token expires in %.0f days (%s)" % (days, note))
            if days < 14:
                findings.append("the token these jobs run on expires in %.0f days (%s) — every job that writes anything stops that day" % (days, note))
        else:
            print("  token expiry: %s" % note)
        width = max([len(r[0]) for r in rows] or [20])
        for name, state, detail in rows:
            print("%-*s  %-8s %s" % (width, name, state, detail))
        if a.js:
            open(a.js, "w", encoding="utf-8").write(json.dumps(
                dict(repo=a.repo, checked=now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                     workflows=[dict(name=n, state=s_, detail=d) for n, s_, d in rows],
                     token=note, findings=findings), indent=2) + "\n")
        if not rows:
            sys.exit("no scheduled workflows found to judge — that is this check being broken, not the machinery being well")
        sys.exit(1 if report(findings) else 0)

    if a.fleet:
        findings, repos, checked, disabled, pr_stats = fleet(a.owner, a.tolerance, now)
        print("%d public repositories, %d live schedules among them, %d quiet, %d disabled by GitHub"
              % (repos, checked, len(findings) - disabled, disabled))
        # Said out loud every run, clean or not: "looked at nothing" and "found
        # nothing" are the two answers that must never print the same way.
        # Whether a read-only credential was configured at all, never its
        # value. "Checked and there is nothing" and "could not check" must not
        # look the same, and neither must "no such credential".
        print("stuck pull requests: %d of %d repositories read, %d open pull requests seen "
              "(%d refused the list; read credential: %s)"
              % (pr_stats.get("read", 0), pr_stats.get("given", 0), pr_stats.get("prs", 0),
                 pr_stats.get("denied", 0),
                 "present" if os.environ.get(READ_TOKEN) else "absent"))
        if a.js:
            open(a.js, "w", encoding="utf-8").write(json.dumps(
                dict(owner=a.owner, checked=now.strftime("%Y-%m-%dT%H:%M:%SZ"), repositories=repos,
                     scheduled_workflows=checked, findings=findings), indent=2) + "\n")
        if not checked:
            sys.exit("not one scheduled workflow found across %d repositories - that is this check being broken, not the fleet being quiet" % repos)
        sys.exit(1 if report(findings) else 0)

    states = {w["path"].split("/")[-1]: w for w in gh("repos/%s/actions/workflows?per_page=100" % a.repo)["workflows"]}

    findings, rows = manifest_drift(a.root), []
    for name, period, crons in scheduled_workflows(a.root):
        allowed = period * a.tolerance + 2
        meta = states.get(name)
        if not meta:
            findings.append("%s is scheduled in this repository but GitHub does not list it as a workflow at all" % name)
            rows.append((name, period, "not registered", "—"))
            continue
        if meta["state"] != "active":
            # The 60-day case lands here, and it is the whole reason this file
            # exists: a disabled workflow has no failed run to notice.
            findings.append("%s is %s: it is not running, and it has no failing run to show for it" % (name, meta["state"]))
            rows.append((name, period, meta["state"], "—"))
            continue
        fired = last_fired(a.repo, meta["id"])
        if fired is None:
            # Never fired on its schedule. New is fine; old is not, and the age
            # of the file is what tells them apart.
            age = (now - workflow_born(a.repo, name, now)).total_seconds() / 3600
            verdict = "new" if age <= allowed else "never fired"
            if verdict == "never fired":
                findings.append("%s has never fired on its schedule, and it was added %.0f hours ago" % (name, age))
            rows.append((name, period, verdict, "—"))
            continue
        age = (now - fired).total_seconds() / 3600
        ok = age <= allowed
        if not ok:
            findings.append("%s last fired %.0f hours ago; its schedule is every %.0f hours, so anything past %.0f is it having stopped"
                            % (name, age, period, allowed))
        rows.append((name, period, "ok" if ok else "QUIET", "%.0fh ago" % age))

    width = max(len(r[0]) for r in rows) if rows else 20
    print("%-*s  %9s  %-13s %s" % (width, "workflow", "every", "state", "last fired"))
    for name, period, state, when in rows:
        print("%-*s  %8.0fh  %-13s %s" % (width, name, period, state, when))
    print()
    if a.js:
        open(a.js, "w", encoding="utf-8").write(json.dumps(
            dict(repo=a.repo, checked=now.strftime("%Y-%m-%dT%H:%M:%SZ"), tolerance=a.tolerance,
                 workflows=[dict(name=n, period_hours=p, state=s, last=w) for n, p, s, w in rows],
                 findings=findings), indent=2) + "\n")
    if not rows:
        # An empty check that exits 0 is the thing this file exists to catch.
        sys.exit("no scheduled workflows found under %s/.github/workflows - either the directory moved or this ran in the wrong place" % a.root)
    if findings and report(findings):
        sys.exit(1)
    print("%d scheduled workflows, all of them have run inside their own interval" % len(rows))


if __name__ == "__main__":
    main()
