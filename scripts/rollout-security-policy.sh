#!/bin/bash
# One-shot rollout: a SECURITY.md in every public repository that has none.
#
# WHAT IT FIXES. The templates have carried a security policy since April;
# the repositories around them (the catalog, the profile, a gitignore
# template, course notes, the assets behind a donation button) did not, and
# OpenSSF Scorecard says so in public: Security-Policy 0 on nine of 97 on
# 2026-09-24. A reviewer who opens one of those nine finds no address to send
# a report to, and the fleet's own SECURITY.md two clicks away does not help
# them. The file below is the template one without the sections that only
# apply to a deployment template: same address, same seven days, same rule
# about public issues.
#
# The heartbeat asks every repository for the file from now on.
#
# Idempotent: a repository that has one, under any of the paths GitHub
# recognises, is skipped.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
  --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | .name' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

CHANGED=0; SKIPPED=0
for repo in "${REPOS[@]}"; do
  have=false
  for path in SECURITY.md .github/SECURITY.md docs/SECURITY.md; do
    if gh api "repos/$OWNER/$repo/contents/$path" >/dev/null 2>&1; then have=true; break; fi
  done
  if [ "$have" = "true" ]; then SKIPPED=$((SKIPPED + 1)); continue; fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "  would add SECURITY.md to $repo"; CHANGED=$((CHANGED + 1)); continue
  fi
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || { echo "  $repo: could not clone"; continue; }
  cat > "$dir/SECURITY.md" <<'MD'
# Security Policy

## Supported versions

Only the current `main` is supported. Fixes land there; nothing is backported.

## Reporting a vulnerability

Send reports to v@valdemar.ai. Encrypted email is preferred; the PGP public key is published at [heyvaldemar.com/security](https://heyvaldemar.com/security).

You can expect an acknowledgment within 7 days. This project does not operate a bounty program; researchers who submit valid, responsibly disclosed reports receive public credit.

Please do not open public GitHub issues for security reports.
MD
  (
    cd "$dir"
    git add SECURITY.md
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "docs: a security policy, so a report has somewhere to go" \
      -m "The same address and the same seven days as every template in the fleet. OpenSSF Scorecard had scored Security-Policy 0 here; a reviewer opening this repository found no way to report anything privately."
    git push -q origin HEAD
  )
  echo "  added SECURITY.md to $repo"; CHANGED=$((CHANGED + 1))
done

echo "added: $CHANGED   already had one: $SKIPPED"
