#!/usr/bin/env bash
# rollout-verify-merged-main.sh - make the Dependabot automerge verify what it
# merged, in every repository that has one.
#
# WHAT WAS WRONG. The automerge merges with GITHUB_TOKEN, and GitHub does not
# run workflows for pushes made with that token. So the pull request was
# verified, the merge result was not, and main landed with no checks on its
# head. The repository page then shows its latest commit with no tick at all.
# On 2026-09-17 that was fourteen repositories out of ninety-four, up from four
# two days earlier, and it grows with every merge Dependabot makes.
#
# It is not only cosmetic. A pull request is verified against the main it was
# opened on. If main moved before the merge, which the triage makes happen
# several times a day, the merged combination is one nothing has booted.
#
# WHAT THIS CHANGES. workflow_dispatch is the documented exception to the
# no-cascade rule, so after a successful merge the job asks the verification it
# was waiting on to run again, on main as merged. The workflow to dispatch is
# read from the event itself rather than guessed: github.event.workflow_run.path
# is the file that just went green. The job gains actions: write for it.
set -uo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

changed=0 skipped=0 already=0
skips=""

transform() {   # file -> 0 changed, 1 already right, 2 shape not recognised
  python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "verification dispatched on main as merged" in s:
    sys.exit(1)

perms_old = """    permissions:
      contents: write
      pull-requests: write
"""
perms_new = """    permissions:
      contents: write
      pull-requests: write
      # To dispatch the verification on main once the merge is in.
      actions: write
"""
env_old = """          SHA: ${{ github.event.workflow_run.head_sha }}
"""
env_new = """          SHA: ${{ github.event.workflow_run.head_sha }}
          VERIFY: ${{ github.event.workflow_run.path }}
"""
merge_old = """          gh pr merge "$pr" --repo "$REPO" --squash --delete-branch \\
            || gh pr merge "$pr" --repo "$REPO" --merge --delete-branch
"""
merge_new = merge_old + """          # THE MERGE IS PUSHED WITH GITHUB_TOKEN, AND GITHUB RUNS NO WORKFLOWS
          # FOR PUSHES MADE WITH IT. So main would land with no checks on its
          # head: the pull request was verified, the merge result was not, and
          # the repository page would show its latest commit with no tick. On
          # 2026-09-17 that was fourteen repositories out of ninety-four, up
          # from four two days earlier, growing with every merge.
          #
          # workflow_dispatch is the documented exception to that rule. The
          # verification this job was waiting on is asked to run again, on main
          # as merged. The file to dispatch comes from the event, not a guess.
          gh workflow run "$(basename "$VERIFY")" --repo "$REPO" --ref main
          echo "verification dispatched on main as merged"
"""
for old in (perms_old, env_old, merge_old):
    if s.count(old) != 1:
        sys.exit(2)
s = s.replace(perms_old, perms_new, 1).replace(env_old, env_new, 1).replace(merge_old, merge_new, 1)
open(path, "w", encoding="utf-8").write(s)
PY
}

for repo in $(gh repo list "$OWNER" --no-archived --source --visibility public -L 300 --json name -q '.[].name' | sort); do
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" || {
    skipped=$((skipped+1)); skips="$skips\n  $repo: clone failed"; continue; }
  f="$dir/.github/workflows/dependabot-automerge.yml"
  [ -f "$f" ] || continue

  transform "$f"; rc=$?
  case "$rc" in
    1) already=$((already+1)); continue ;;
    2) skipped=$((skipped+1)); skips="$skips\n  $repo: dependabot-automerge.yml is not the shape this rollout knows"; continue ;;
  esac

  if ! docker run --rm -v "$dir:/mnt" -w /mnt rhysd/actionlint:1.7.12 >/dev/null 2>&1; then
    skipped=$((skipped+1)); skips="$skips\n  $repo: actionlint refused the edited file"; continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "would change $repo"
    changed=$((changed+1))
    continue
  fi

  git -C "$dir" -c user.name="${GIT_AUTHOR:-Vladimir Mikhalev}" \
      -c user.email="${GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}" \
      commit -aqm "ci: verify main as merged, not only the pull request

The automerge merges with GITHUB_TOKEN, and GitHub runs no workflows for
pushes made with that token. The pull request was verified; the merge result
was not, and main landed with no checks on its head. The repository page then
shows its latest commit with no tick. Across the fleet that was fourteen
repositories on 2026-09-17, up from four two days earlier.

It is not only cosmetic. A pull request is verified against the main it was
opened on, and if main moved before the merge the merged combination is one
nothing has booted.

workflow_dispatch is the documented exception to the no-cascade rule, so the
job now asks the verification it was waiting on to run again on main once the
merge is in. The workflow to dispatch is read from the event that woke this
job, not guessed."
  if git -C "$dir" push -q origin HEAD:main 2>/dev/null; then
    echo "changed $repo"
    changed=$((changed+1))
  else
    skipped=$((skipped+1)); skips="$skips\n  $repo: push refused"
  fi
done

printf '\nchanged %d, already correct %d, skipped %d\n' "$changed" "$already" "$skipped"
[ -n "$skips" ] && printf 'skipped:%b\n' "$skips"
exit 0
