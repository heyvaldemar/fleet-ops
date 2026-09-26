#!/bin/bash
# One-shot rollout: the OpenSSF Best Practices badge in every README whose
# repository is registered on bestpractices.dev.
#
# WHAT IT IS. The badge is a questionnaire: sixty-seven criteria, each
# answered Met, Unmet or N/A with a sentence saying why, and every answer is
# public on the badge site. Filled in on 2026-09-25 for every public
# repository that is not documentation alone. A repository with no test
# suite says Unmet where it is unmet and stays short of passing; the badge
# then reads "in progress" with a percentage, which is the true state.
#
# The badge line goes right above the licence badge, where the Scorecard badge
# already sits on the repositories that have one. Idempotent: a README that
# already carries a bestpractices.dev badge is skipped; a README without a
# badge block at all is left alone and named.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

project_id() {
  # The site answers with a list; an empty list is "never registered".
  local enc
  enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "https://github.com/$OWNER/$1")"
  curl -fsSL -A "fleet-ops (heyvaldemar.com)" -H "Accept: application/json" \
    "https://www.bestpractices.dev/projects.json?url=$enc" 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d[0]["id"] if isinstance(d,list) and d and isinstance(d[0].get("id"),int) else "")'
}

REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
  --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | .name' | sort)
[ "${#REPOS[@]}" -gt 0 ] || { echo "::error::repository listing came back empty"; exit 1; }

CHANGED=0; SKIPPED=0; ODD=0; NOTREG=0; PRS=0; rc=0
for repo in "${REPOS[@]}"; do
  id="$(project_id "$repo" || true)"
  if [ -z "$id" ]; then NOTREG=$((NOTREG + 1)); echo "  $repo: not registered on bestpractices.dev"; continue; fi
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || { ODD=$((ODD + 1)); echo "  $repo: could not clone"; continue; }
  f="$dir/README.md"
  [ -f "$f" ] || { ODD=$((ODD + 1)); echo "  $repo: no README.md"; rm -rf "$dir"; continue; }
  if grep -qF "bestpractices.dev/projects/" "$f"; then SKIPPED=$((SKIPPED + 1)); rm -rf "$dir"; continue; fi
  if ! grep -qE '^\[!\[' "$f"; then ODD=$((ODD + 1)); echo "  $repo: README has no badge block, left alone"; rm -rf "$dir"; continue; fi
  if [ "$DRY_RUN" = "true" ]; then echo "  would add $repo (project $id)"; CHANGED=$((CHANGED + 1)); rm -rf "$dir"; continue; fi
  python3 - "$f" "$id" <<'PY'
import io, sys
p, pid = sys.argv[1:]
badge = "[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/%s/badge)](https://www.bestpractices.dev/projects/%s)" % (pid, pid)
lines = io.open(p, encoding="utf-8").read().split("\n")
lic = next((i for i, l in enumerate(lines) if l.startswith("[![License")), None)
if lic is not None:
    lines.insert(lic, badge)
else:
    last = max(i for i, l in enumerate(lines) if l.startswith("[!["))
    lines.insert(last + 1, badge)
io.open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
  (
    cd "$dir"
    git add README.md
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "docs: the OpenSSF Best Practices badge, with every answer public" \
      -m "The badge is a questionnaire answered criterion by criterion, each answer naming the workflow or file that makes it true, and the answers are public on bestpractices.dev. Where a criterion is not met the answer says Unmet, and the badge reads what that adds up to."
    if ! git push -q origin HEAD 2>/dev/null; then
      # A repository whose rules require a pull request (aws-kubectl-docker).
      git push -q -f origin HEAD:bestpractices-badge
      gh pr create -R "$OWNER/$repo" --head bestpractices-badge --fill >/dev/null 2>&1 || true
      exit 3
    fi
  ) || rc=$?
  case "${rc:-0}" in
    0) echo "  added $repo (project $id)"; CHANGED=$((CHANGED + 1)) ;;
    3) echo "  $repo: main refuses direct pushes; pull request opened"; PRS=$((PRS + 1)) ;;
    *) echo "  $repo: push failed ($rc)"; ODD=$((ODD + 1)) ;;
  esac
  rc=0
  rm -rf "$dir"
done
echo "added: $CHANGED   pull requests instead: $PRS   already carried: $SKIPPED   not registered: $NOTREG   left alone: $ODD"
