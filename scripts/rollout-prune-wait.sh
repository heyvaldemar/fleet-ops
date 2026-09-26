#!/bin/bash
# One-shot rollout: the prune test waits for the prune, not for a number.
#
# WHAT IT FIXES. test_prune_removes_old placed a file dated 2020, slept
# interval + 60 s, and expected it gone. A backup cycle is a database dump,
# a data backup that takes as long as the data does, the prune, then the
# interval: on 2026-09-25 Nextcloud 35.0.1's data backup took 98 s, the
# cycle ran 160 s, the test asked at 120 s, and a good digest refresh was
# reverted twice for it. Thirty templates carry the same lines.
#
# From now on the test polls for the file to disappear, with a ceiling of
# two cycles plus five minutes, and says how long the prune took.
#
# Idempotent: a test that already polls is skipped; a test whose lines differ
# is left alone and named.
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
  if grep -qF "pruned after" "$f"; then SKIPPED=$((SKIPPED + 1)); rm -rf "$dir"; continue; fi
  # The dollar sign is the point: the literal line is what has to be there.
  # shellcheck disable=SC2016
  if ! grep -qF 'sleep "$CYCLE_WAIT"' "$f" || ! grep -qF "fake old file survived the prune cycle" "$f"; then
    ODD=$((ODD + 1)); echo "  $repo: prune test has another shape, left alone"; rm -rf "$dir"; continue
  fi
  if [ "$DRY_RUN" = "true" ]; then echo "  would rewrite $repo"; CHANGED=$((CHANGED + 1)); rm -rf "$dir"; continue; fi
  python3 - "$f" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = re.compile(r'''  echo "  waiting \$\{CYCLE_WAIT\}s for the next prune cycle\.\.\."\n  sleep "\$CYCLE_WAIT"\n  if backups_sh "ls \$fake_old 2>/dev/null" > /dev/null 2>&1; then fail "fake old file survived the prune cycle"; return 1; fi\n''')
new = '''  # A cycle is a database dump, a data backup that takes as long as the data
  # does, the prune, then the interval. Nextcloud 35.0.1's data backup took
  # 98 s on 2026-09-25 and a fixed wait of interval + 60 s asked before the
  # prune had run. Wait for the prune itself, with a ceiling of two cycles.
  local ceiling=$(( $(interval_seconds) * 2 + 300 )) waited=0
  echo "  waiting up to ${ceiling}s for a prune cycle to remove it..."
  while backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; do
    if [ "$waited" -ge "$ceiling" ]; then fail "fake old file survived ${ceiling}s, longer than two backup cycles"; return 1; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  echo "  pruned after ${waited}s"
'''
s2, n = old.subn(lambda _m: new, s)
if n != 1:
    sys.exit("expected exactly one prune wait, found %d" % n)
io.open(p, "w", encoding="utf-8").write(s2)
PY
  shellcheck "$f" || { echo "  $repo: shellcheck refused the rewritten test"; ODD=$((ODD + 1)); rm -rf "$dir"; continue; }
  (
    cd "$dir"
    git add tests/e2e-backup-restore.sh
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "test: the prune test waits for the prune, not for a number" \
      -m "A backup cycle is a database dump, a data backup that takes as long as the data does, the prune, then the interval. The test slept interval + 60 s and asked; on 2026-09-25 a cycle ran 160 s and a good digest refresh was reverted twice for it. The test now polls for the file to go, with a ceiling of two cycles plus five minutes, and says how long the prune took."
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
echo "rewritten: $CHANGED   pull requests instead: $PRS   already polling: $SKIPPED   no such test: $NONE   left alone: $ODD"
