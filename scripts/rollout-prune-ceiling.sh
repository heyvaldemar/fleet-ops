#!/bin/bash
# One-shot rollout: the other two shapes of the prune test wait for the
# prune with a ceiling of two cycles, like the thirty-six already do.
#
# Nine data-only templates already polled, but with a ceiling of interval
# + 90 s; Keycloak slept a fixed 45 s. Both are the assumption ledger #92
# names: that a cycle is shorter than a number chosen when the data was
# small. Same rule as rollout-prune-wait.sh: poll for the file to go, stop
# at two cycles plus five minutes, say how long the prune took.
#
# Idempotent: a test already carrying the ceiling is skipped; any other
# shape is left alone and named.
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
  f="$dir/tests/e2e-backup-restore.sh"
  [ -f "$f" ] || { NONE=$((NONE + 1)); rm -rf "$dir"; continue; }
  if grep -qF "pruned after" "$f" || grep -qF "longer than two backup cycles" "$f"; then SKIPPED=$((SKIPPED + 1)); rm -rf "$dir"; continue; fi
  if ! grep -qF "test_prune_removes_old" "$f"; then NONE=$((NONE + 1)); echo "  $repo: no prune test"; rm -rf "$dir"; continue; fi
  if [ "$DRY_RUN" = "true" ]; then
    if python3 - "$f" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
poll = re.search(r'  local elapsed=0\n  echo "  waiting up to \$\{CYCLE_WAIT\}s for the next prune cycle\.\.\."\n  while \[\[ \$elapsed -lt \$CYCLE_WAIT \]\]; do\n(    \S+ "test ! -f \$\{fake\}" && \{ echo "  the old file was pruned"; return 0; \}\n)    sleep 5; elapsed=\$\(\(elapsed \+ 5\)\)\n  done\n  echo "  the old file is still there after a full cycle" >&2\n', s)
fixed = re.search(r'  echo "  waiting 45s for next prune cycle\.\.\."\n  sleep 45\n\n  if backups_sh "ls \$fake_old 2>/dev/null" > /dev/null 2>&1; then\n    fail "fake old file still present after prune cycle"\n    return 1\n  fi\n', s)
sys.exit(0 if (poll or fixed) else 1)
PY
    then echo "  would rewrite $repo"; CHANGED=$((CHANGED + 1)); else ODD=$((ODD + 1)); echo "  $repo: prune test has another shape, left alone"; fi
    rm -rf "$dir"; continue
  fi
  if ! python3 - "$f" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
poll = re.compile(r'  local elapsed=0\n  echo "  waiting up to \$\{CYCLE_WAIT\}s for the next prune cycle\.\.\."\n  while \[\[ \$elapsed -lt \$CYCLE_WAIT \]\]; do\n(    (\S+) "test ! -f \$\{fake\}" && \{ echo "  the old file was pruned"; return 0; \}\n)    sleep 5; elapsed=\$\(\(elapsed \+ 5\)\)\n  done\n  echo "  the old file is still there after a full cycle" >&2\n')
m = poll.search(s)
if m:
    helper = m.group(2)
    new = ('''  # A cycle is the archive, which takes as long as the data does, then the
  # interval. Wait for the prune itself, with a ceiling of two cycles; the
  # fixed wait this replaces reverted a good refresh twice on 2026-09-25.
  local ceiling=$(( $(interval_seconds) * 2 + 300 )) elapsed=0
  echo "  waiting up to ${ceiling}s for a prune cycle to remove it..."
  while [[ $elapsed -lt $ceiling ]]; do
    %s "test ! -f ${fake}" && { echo "  pruned after ${elapsed}s"; return 0; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "  the old file is still there after ${ceiling}s, longer than two backup cycles" >&2
''' % helper)
    s = s[:m.start()] + new + s[m.end():]
else:
    fixed = re.compile(r'  echo "  waiting 45s for next prune cycle\.\.\."\n  sleep 45\n\n  if backups_sh "ls \$fake_old 2>/dev/null" > /dev/null 2>&1; then\n    fail "fake old file still present after prune cycle"\n    return 1\n  fi\n')
    m = fixed.search(s)
    if not m:
        sys.exit("no known prune wait")
    new = '''  # A cycle is the dump, the prune, then the interval. Wait for the prune
  # itself, with a ceiling of two cycles; a fixed wait is the assumption
  # that reverted a good refresh twice elsewhere on 2026-09-25.
  local iv="${KEYCLOAK_BACKUP_INTERVAL:-30s}" secs
  case "$iv" in *h) secs=$(( ${iv%h} * 3600 )) ;; *m) secs=$(( ${iv%m} * 60 )) ;; *s) secs="${iv%s}" ;; *) secs="$iv" ;; esac
  local ceiling=$(( secs * 2 + 300 )) waited=0
  echo "  waiting up to ${ceiling}s for a prune cycle to remove it..."
  while backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; do
    if [ "$waited" -ge "$ceiling" ]; then fail "fake old file survived ${ceiling}s, longer than two backup cycles"; return 1; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  echo "  pruned after ${waited}s"
'''
    s = s[:m.start()] + new + s[m.end():]
io.open(p, "w", encoding="utf-8").write(s)
PY
  then ODD=$((ODD + 1)); echo "  $repo: prune test has another shape, left alone"; rm -rf "$dir"; continue; fi
  shellcheck "$f" || { echo "  $repo: shellcheck refused the rewritten test"; ODD=$((ODD + 1)); rm -rf "$dir"; continue; }
  (
    cd "$dir"
    git add tests/e2e-backup-restore.sh
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "test: the prune test waits for the prune, with a ceiling of two cycles" \
      -m "The wait was a number chosen when the data was small: interval plus ninety seconds, or a fixed forty-five. A cycle is the archive, which takes as long as the data does, then the interval. The test now polls for the file to go, stops at two cycles plus five minutes, and says how long the prune took. Same rule as the thirty-six templates changed earlier today."
    if ! git push -q origin HEAD 2>/dev/null; then
      git push -q -f origin HEAD:prune-wait
      gh pr create -R "$OWNER/$repo" --head prune-wait --fill >/dev/null 2>&1 || true
      exit 3
    fi
  ) || rc=$?
  case "${rc:-0}" in
    0) echo "  rewrote $repo"; CHANGED=$((CHANGED + 1)) ;;
    3) echo "  $repo: main refuses direct pushes; pull request opened"; PRS=$((PRS + 1)) ;;
    *) echo "  $repo: push failed ($rc)"; ODD=$((ODD + 1)) ;;
  esac
  rc=0
  rm -rf "$dir"
done
echo "rewritten: $CHANGED   pull requests instead: $PRS   already at the ceiling: $SKIPPED   no prune test: $NONE   left alone: $ODD"
