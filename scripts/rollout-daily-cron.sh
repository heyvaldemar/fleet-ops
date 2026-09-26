#!/bin/bash
# One-shot rollout: switch every pin-bearing template's freshness cron
# from weekly to daily. Security patches should not wait for a Monday.
# Idempotent — repos already on the daily cron are skipped.

set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# REST, not `gh repo list`: that command speaks GraphQL, which rejects
# fine-grained PATs with a 401 — and a silent empty list once produced a
# green run that had checked nothing. Hence the fail-fast below.
REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100" --paginate --jq '.[] | select(.archived|not) | .name' | grep -E 'docker-compose$|docker$' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

CHANGED=0
for repo in "${REPOS[@]}"; do
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || continue
  wf="$dir/.github/workflows/deployment-verification.yml"
  if [ ! -f "$wf" ]; then continue; fi
  if ! grep -q "upstream drift" "$wf"; then echo "$repo: no drift job, skipped"; continue; fi
  if grep -qF -e '- cron: "0 6 * * *"' "$wf"; then echo "$repo: already daily"; continue; fi
  if ! grep -qF -e '- cron: "0 6 * * 1"' "$wf"; then echo "$repo: unexpected cron, skipped"; continue; fi

  tmpf="$(mktemp)"
  sed -e 's/- cron: "0 6 \* \* 1"/- cron: "0 6 * * *"/' \
      -e 's/# Weekly rebuild to catch upstream image drift\./# Daily rebuild: security patches should not wait for a weekly slot./' \
      -e 's/# Weekly rebuild to catch upstream drift\./# Daily rebuild: security patches should not wait for a weekly slot./' \
      -e 's/# Weekly cron + manual dispatch only:/# Scheduled + manual dispatch only:/' \
      -e 's/# Weekly cron + manual dispatch only\./# Scheduled + manual dispatch only./' \
      "$wf" > "$tmpf"
  cat "$tmpf" > "$wf"; rm -f "$tmpf"

  if [ "$DRY_RUN" = "true" ]; then
    echo "$repo: would switch to the daily cron"
    continue
  fi
  git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
    commit -aqm "feat(ci): run the freshness check daily

A weekly slot means a security patch published on Tuesday sits
unnoticed until Monday. The pin checks are cheap; the deploy job still
runs only on pushes, PRs, and manual dispatch."
  git -C "$dir" push -q origin main
  echo "$repo: switched to the daily cron"
  CHANGED=$((CHANGED+1))
done

echo "switched: $CHANGED repositories"
