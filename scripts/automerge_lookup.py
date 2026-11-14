#!/usr/bin/env python3
"""automerge_lookup.py - the Dependabot automerge finds its pull request in
the event, checks it against the pull request itself, and fails when it
cannot find one it should have.

    python3 scripts/automerge_lookup.py <dependabot-automerge.yml>
        exit 0  the file was changed
        exit 1  it already has this change
        exit 2  it is not a shape this knows; nothing was written

WHAT WAS WRONG. The job found the pull request by asking GitHub which pull
request carries the commit that went green. On 2026-11-11 GitHub answered
nothing, five minutes after siyuan-docker-compose#8 had opened. The job said
"nothing to do", went green, and the update waited sixty hours, until the
fleet heartbeat named it on 2026-11-13. A job that cannot do what it exists
for and reports success is the one failure nobody reads.

WHAT IT DOES NOW.
  - The pull request comes from github.event.workflow_run.pull_requests,
    which lists the ones the run was for. The commit lookup is the fallback,
    asked six times, twenty seconds apart.
  - What may be merged is decided by the pull request, read back from the
    API, never by the event: its author must be dependabot[bot] and its head
    must be the commit that was verified. A head that moved since is a commit
    nothing has run; the merge is refused and the run on the new head
    decides. `gh pr merge --match-head-commit` holds GitHub to the same
    commit, so nothing can land in between the check and the merge.
  - A run Dependabot started whose pull request cannot be found turns the job
    red. Any other run with no pull request is still "nothing to do".

Only the lookup block, the environment beside it and the merge lines are
touched, so the variants that wait for other gates (an e2e run, a second
Verify) keep them.
"""
import re
import sys

MARK = "THE PULL REQUEST COMES FROM THE EVENT"

ENV_OLD = re.compile(r"^(?P<i>[ ]+)SHA: \$\{\{ github\.event\.workflow_run\.head_sha \}\}\n", re.M)

LOOKUP_OLD = re.compile(
    r"^(?P<i>[ ]+)# The pull request is found from the commit rather than passed in:\n"
    r"[ ]+# workflow_run carries the run, not the pull request that caused it\.\n"
    r"[ ]+pr=\"\$\(gh api \"repos/\$REPO/commits/\$SHA/pulls\" \\\n"
    r"[ ]+--jq '\.\[\] \| select\(\.state==\"open\"\) \| select\(\.user\.login==\"dependabot\[bot\]\"\) \| \.number' \\\n"
    r"[ ]+\| head -1\)\"\n"
    r"[ ]+if \[ -z \"\$pr\" \]; then\n"
    r"[ ]+echo \"no open Dependabot pull request at \$SHA[^\"\n]*nothing to do\"\n"
    r"[ ]+exit 0\n"
    r"[ ]+fi\n",
    re.M,
)

MERGE_OLD = re.compile(
    r"^(?P<i>[ ]+)gh pr merge \"\$pr\" --repo \"\$REPO\" --squash --delete-branch \\\n"
    r"(?P<j>[ ]+)\|\| gh pr merge \"\$pr\" --repo \"\$REPO\" --merge --delete-branch\n",
    re.M,
)

ENV_NEW = """\
{i}SHA: ${{{{ github.event.workflow_run.head_sha }}}}
{i}# The pull requests the run was for, its branch and who started it.
{i}# Through the environment, never pasted into the script: a branch name
{i}# is text whoever opens a pull request chooses.
{i}PRS: ${{{{ toJSON(github.event.workflow_run.pull_requests) }}}}
{i}HEAD_BRANCH: ${{{{ github.event.workflow_run.head_branch }}}}
{i}ACTOR: ${{{{ github.event.workflow_run.actor.login }}}}
"""

LOOKUP_NEW = """\
{i}# THE PULL REQUEST COMES FROM THE EVENT, AND THE COMMIT IS ONLY THE
{i}# FALLBACK. This used to ask which pull request carries the commit, and
{i}# on 2026-11-11 GitHub answered nothing five minutes after
{i}# siyuan-docker-compose#8 opened: the job said "nothing to do", went
{i}# green, and the update waited sixty hours. The event lists the pull
{i}# requests the run was for; the commit is asked about only when that
{i}# list is empty, six times, twenty seconds apart.
{i}pr="$(jq -r '.[0].number // empty' <<<"$PRS" 2>/dev/null || true)"
{i}tries=0
{i}while [ -z "$pr" ] && [ "$tries" -lt 6 ]; do
{i}  if [ "$tries" -gt 0 ]; then sleep 20; fi
{i}  tries=$((tries + 1))
{i}  pr="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '.[0].number // empty' 2>/dev/null || true)"
{i}done
{i}if [ -z "$pr" ]; then
{i}  # A run Dependabot started with no pull request to be found is a
{i}  # failure, not "nothing to do": the update would wait where nobody looks.
{i}  if [ "$ACTOR" = "dependabot[bot]" ] && [ "${{HEAD_BRANCH#dependabot/}}" != "$HEAD_BRANCH" ]; then
{i}    echo "::error::verification passed at $SHA on $HEAD_BRANCH, and no pull request was found for it, in the event or in six lookups"
{i}    exit 1
{i}  fi
{i}  echo "no pull request at $SHA: nothing to do"
{i}  exit 0
{i}fi
{i}# WHAT MAY BE MERGED IS DECIDED BY THE PULL REQUEST, NOT BY THE EVENT.
{i}# Its author must be Dependabot and its head the commit that was
{i}# verified. A head that moved since is a commit nothing here has run:
{i}# the run on that head decides instead.
{i}info="$(gh api "repos/$REPO/pulls/$pr" --jq '"\\(.state) \\(.user.login) \\(.head.sha)"')" \\
{i}  || {{ echo "::error::#$pr could not be read"; exit 1; }}
{i}read -r state author head <<<"$info"
{i}if [ "$author" != "dependabot[bot]" ]; then
{i}  echo "#$pr is $author's, not Dependabot's: not merging"
{i}  exit 0
{i}fi
{i}if [ "$state" != open ]; then
{i}  echo "#$pr is $state: nothing to merge"
{i}  exit 0
{i}fi
{i}if [ "$head" != "$SHA" ]; then
{i}  echo "::warning::#$pr is at $head now, and the run that passed was for $SHA: not merging"
{i}  exit 0
{i}fi
"""

MERGE_NEW = """\
{i}# --match-head-commit: GitHub refuses the merge if the head moved after
{i}# the check above, so what lands is the commit that was verified.
{i}gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$SHA" \\
{j}|| gh pr merge "$pr" --repo "$REPO" --merge --delete-branch --match-head-commit "$SHA"
"""


def transform(s):
    """Return (code, text): 0 changed, 1 already done, 2 unknown shape."""
    if MARK in s:
        return 1, s
    found = [p.findall(s) for p in (ENV_OLD, LOOKUP_OLD, MERGE_OLD)]
    if any(len(f) != 1 for f in found):
        return 2, s
    s = ENV_OLD.sub(lambda m: ENV_NEW.format(i=m.group("i")), s, count=1)
    s = LOOKUP_OLD.sub(lambda m: LOOKUP_NEW.format(i=m.group("i")), s, count=1)
    s = MERGE_OLD.sub(lambda m: MERGE_NEW.format(i=m.group("i"), j=m.group("j")), s, count=1)
    return 0, s


def main(argv):
    path = argv[1]
    with open(path, encoding="utf-8") as f:
        s = f.read()
    code, out = transform(s)
    if code == 0:
        with open(path, "w", encoding="utf-8") as f:
            f.write(out)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
