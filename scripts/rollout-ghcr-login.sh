#!/bin/bash
# One-shot rollout: a template that pulls several images from ghcr.io logs
# in there with the workflow token before it scans and before it deploys.
#
# WHAT IT FIXES. ghcr.io throttles anonymous pulls per address, and every
# GitHub runner shares a few addresses. Immich, five images from ghcr.io,
# died on TOOMANYREQUESTS on 2026-09-18 and twice on 2026-09-25, each time
# with the same commit green an hour earlier. An authenticated pull is
# counted against the token instead; Trivy reads the same credential store
# as docker. Applied where the compose file names two or more ghcr.io
# images; Docker Hub images are untouched.
#
# Idempotent: a workflow already logging in is skipped; a workflow whose
# jobs are not laid out as the template's are is left alone and named.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

REPOS=()
if [ -n "${REPOS_ONLY:-}" ]; then
  read -r -a REPOS <<< "$REPOS_ONLY"
else
  while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
    --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | .name' | sort)
fi
[ "${#REPOS[@]}" -gt 0 ] || { echo "::error::repository listing came back empty"; exit 1; }

CHANGED=0; SKIPPED=0; ODD=0; NONE=0; PRS=0; rc=0
for repo in "${REPOS[@]}"; do
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || continue
  wf="$dir/.github/workflows/deployment-verification.yml"
  n=$(cat "$dir"/*compose*.yml 2>/dev/null | grep -c "ghcr.io/" || true)
  if [ ! -f "$wf" ] || [ "${n:-0}" -lt 2 ]; then NONE=$((NONE + 1)); rm -rf "$dir"; continue; fi
  if grep -qF "docker login ghcr.io" "$wf"; then SKIPPED=$((SKIPPED + 1)); rm -rf "$dir"; continue; fi
  if [ "$DRY_RUN" = "true" ]; then echo "  would rewrite $repo ($n ghcr.io images)"; CHANGED=$((CHANGED + 1)); rm -rf "$dir"; continue; fi
  if ! python3 - "$wf" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
login = '''      - name: Log in to ghcr.io, so its rate limit is per token and not per shared runner address
        # ghcr.io throttles anonymous pulls per address, and every runner
        # shares a few. Immich died on TOOMANYREQUESTS three times in a week
        # with the same commit green between. An authenticated pull is
        # counted against the token; Trivy reads the same credential store.
        env:
          GH_TOKEN: ${{ github.token }}
        run: echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
'''
def patch(block):
    m = re.search(r'    permissions:\n((?:      \S.*\n)+)', block)
    if not m:
        raise SystemExit("no permissions block")
    if "packages:" not in m.group(1):
        block = block[:m.end()] + "      packages: read\n" + block[m.end():]
    m = re.search(r'      - name: Checkout repository\n(?:        .*\n)+', block)
    if not m:
        raise SystemExit("no checkout step")
    return block[:m.end()] + "\n" + login + block[m.end():]
i = s.find("\n  scan-trivy:\n"); j = s.find("\n  deploy-and-test:\n")
if i < 0 or j < 0 or j < i:
    raise SystemExit("jobs are not laid out as the template's are")
k = re.search(r"\n  [a-z][a-z0-9-]*:\n", s[j + 1:])
end = j + 1 + k.start() if k else len(s)
s = s[:i + 1] + patch(s[i + 1:j + 1]) + patch(s[j + 1:end]) + s[end:]
io.open(p, "w", encoding="utf-8").write(s)
PY
  then ODD=$((ODD + 1)); echo "  $repo: workflow has another shape, left alone"; rm -rf "$dir"; continue; fi
  actionlint "$wf" || { echo "  $repo: actionlint refused the rewritten workflow"; ODD=$((ODD + 1)); rm -rf "$dir"; continue; }
  (
    cd "$dir"
    git add .github/workflows/deployment-verification.yml
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "ci: pull this repository's ghcr.io images as a token, not as a shared address" \
      -m "ghcr.io throttles anonymous pulls per address, and every GitHub runner shares a few. Immich died on TOOMANYREQUESTS three times in a week with the same commit green between. The scan and the deploy jobs now log in to ghcr.io with the workflow token, so the limit is counted per token; Trivy reads the same credential store as docker. Nothing changes for the images on Docker Hub."
    if ! git push -q origin HEAD 2>/dev/null; then
      git push -q -f origin HEAD:ghcr-login
      gh pr create -R "$OWNER/$repo" --head ghcr-login --fill >/dev/null 2>&1 || true
      exit 3
    fi
  ) || rc=$?
  case "${rc:-0}" in
    0) echo "  rewrote $repo ($n ghcr.io images)"; CHANGED=$((CHANGED + 1)) ;;
    3) echo "  $repo: main refuses direct pushes; pull request opened"; PRS=$((PRS + 1)) ;;
    *) echo "  $repo: push failed ($rc)"; ODD=$((ODD + 1)) ;;
  esac
  rc=0
  rm -rf "$dir"
done
echo "rewritten: $CHANGED   pull requests instead: $PRS   already logging in: $SKIPPED   fewer than two ghcr.io images: $NONE   left alone: $ODD"
