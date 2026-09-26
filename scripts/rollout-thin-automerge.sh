#!/bin/bash
# One-shot rollout: give the repositories that have Dependabot and nothing to
# merge its pull requests both halves of the loop.
#
# WHY THEY WERE LEFT OUT. Every template here carries
# dependabot-automerge.yml, which merges an update once that repository's own
# Deployment Verification goes green. Ten repositories have Dependabot enabled
# and no such file, because they have no deployment to verify: nine of them
# carry only scorecard.yml, which analyses the repository rather than the pull
# request. So their pull requests waited for a human, and the only thing saying
# so was a notification mail. One had been open thirty-six hours.
#
# WHAT IS ACTUALLY CHECKED. A Dependabot update in these repositories edits a
# workflow file and nothing else, so the check that fits is a workflow linter.
# actionlint on every pull request, and the merge gated on it. That is a real
# verification proportional to the change, not a rubber stamp: a bump that
# leaves a workflow unparseable does not merge.
#
# aws-kubectl-docker is the exception and is skipped: it already runs
# "Build and Publish Docker Image" on pull requests, which is a stronger gate
# than this one, and its automerge is wired to that by hand.
#
# Idempotent: a repository that already has either file is left alone.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100" --paginate --jq '.[] | select(.archived|not) | select(.fork|not) | .name' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

CHANGED=0; SKIPPED=0
for repo in "${REPOS[@]}"; do
  case "$repo" in aws-kubectl-docker) continue ;; esac
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || continue
  if [ ! -f "$dir/.github/dependabot.yml" ]; then rm -rf "$dir"; continue; fi
  if [ -f "$dir/.github/workflows/dependabot-automerge.yml" ] || [ -f "$dir/.github/workflows/verify.yml" ]; then
    SKIPPED=$((SKIPPED+1)); rm -rf "$dir"; continue
  fi

  cat > "$dir/.github/workflows/verify.yml" <<'WF'
name: Verify

# WHAT THERE IS TO VERIFY HERE. This repository has no deployment to boot, so
# there is no smoke test to gate a change on. What a Dependabot update actually
# edits is a workflow file, and an unparseable workflow is the way one of those
# bumps can break something. So the check is a workflow linter, and the
# automerge beside it waits for this to pass.
#
# A check proportional to the change, rather than none at all or a ceremony.
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: verify-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    name: Lint workflow YAML
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: actionlint
        run: |
          docker run --rm -v "$PWD:/mnt" -w /mnt rhysd/actionlint:1.7.12 -color
WF

  cat > "$dir/.github/workflows/dependabot-automerge.yml" <<'WF'
name: Dependabot auto-merge

# Merges a Dependabot pull request once this repository's own verification has
# finished GREEN for that commit — and only then.
#
# NOT `gh pr merge --auto`. That hands the decision to GitHub's auto-merge,
# which waits for the checks a branch protection rule marks as REQUIRED. Where
# no rule marks any, nothing is required, and auto-merge merges the pull
# request immediately — before the verification it was supposed to wait for.
# Triggering on the verification's own completion removes that dependency: if
# the run did not conclude success, this job does nothing at all.
on:
  workflow_run:
    workflows: ["Verify"]
    types: [completed]

# READ AT THE TOP, WRITE ONLY WHERE IT IS USED. A top-level block applies to
# every job in the file, including ones added later; OpenSSF Scorecard scores
# that as Token-Permissions 0/10 and it is right to.
permissions:
  contents: read

jobs:
  merge:
    name: Merge the update if its verification passed
    permissions:
      contents: write
      pull-requests: write
    if: >-
      github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - name: Merge, if this was Dependabot and the run was green
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
          SHA: ${{ github.event.workflow_run.head_sha }}
        run: |
          # The pull request is found from the commit rather than passed in:
          # workflow_run carries the run, not the pull request that caused it.
          pr="$(gh api "repos/$REPO/commits/$SHA/pulls" \
                 --jq '.[] | select(.state=="open") | select(.user.login=="dependabot[bot]") | .number' \
                 | head -1)"
          if [ -z "$pr" ]; then
            echo "no open Dependabot pull request at $SHA — nothing to do"
            exit 0
          fi
          echo "verification passed for #$pr; merging"
          # Squash where the repository allows it, a plain merge where it does
          # not. A repository with squash disabled would otherwise fail here
          # every week, and a job that fails every week is one nobody reads.
          gh pr merge "$pr" --repo "$REPO" --squash --delete-branch \
            || gh pr merge "$pr" --repo "$REPO" --merge --delete-branch
WF

  if [ "$DRY_RUN" = "true" ]; then
    echo "$repo: would add verify.yml + dependabot-automerge.yml"
    rm -rf "$dir"; continue
  fi
  git -C "$dir" add .github/workflows/verify.yml .github/workflows/dependabot-automerge.yml
  git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
    commit -qm "ci: verify pull requests here, and merge the Dependabot ones

This repository has Dependabot enabled and nothing that merges its pull
requests, because it has no deployment to boot and therefore no smoke
test to gate one on. So they waited for a human, and the only thing
saying so was a notification mail. One elsewhere in the fleet had been
open thirty-six hours.

What a Dependabot update actually edits here is a workflow file, so the
check that fits is a workflow linter: actionlint on every pull request,
with the merge gated on it. A bump that leaves a workflow unparseable
does not merge. Proportional to the change rather than none at all." >/dev/null
  git -C "$dir" push -q origin main
  echo "$repo: verification and automerge added"
  CHANGED=$((CHANGED+1))
  rm -rf "$dir"
done

echo
echo "changed: $CHANGED   already had one: $SKIPPED"
