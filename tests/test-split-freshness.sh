#!/usr/bin/env bash
# Moving the freshness job out of Deployment Verification, shown what it must
# refuse as well as what it must do.
#
# The first version of the move produced a concurrency group reading
# "pin-freshness-${{ github.ref }} github.ref }}" and every linter passed it: a
# garbled string is still a string. So the result is compared as data, and the
# cases below break it in each way that matters.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok    $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }
check() {            # check <name> <command...>: passes when the command succeeds
  local name="$1"; shift
  if "$@"; then ok "$name"; else no "$name"; fi
}
refuse() {           # refuse <name> <command...>: passes when the command fails
  local name="$1"; shift
  if "$@"; then no "$name"; else ok "$name"; fi
}

fixture() {          # fixture <dir>: a template shaped like the fleet's
  mkdir -p "$1/.github/workflows"
  cat > "$1/.github/workflows/deployment-verification.yml" <<'YML'
name: Deployment Verification

on:
  push:
    branches:
      - main
  schedule:
    # daily, to catch upstream drift
    - cron: "0 6 * * *"
  workflow_dispatch:

concurrency:
  group: deployment-verification-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

env:
  # a comment inside the environment
  GH_API_TOKEN: ${{ github.token }}

jobs:
  lint:
    name: Lint
    runs-on: ubuntu-latest
    steps:
      - run: echo lint

  # THE COMMENT ABOVE THE JOB travels with it.
  check-pin-freshness:
    name: Check pinned images for upstream drift
    runs-on: ubuntu-latest
    steps:
      # and the ones inside it
      - run: echo "compare $GH_API_TOKEN"

  deploy-and-test:
    name: docker compose up
    needs: lint
    runs-on: ubuntu-latest
    steps:
      - run: echo up
YML
}

echo "=== the move ==="
d="$WORK/a"; fixture "$d"
check "a template in the fleet's shape is split" python3 scripts/split-freshness.py "$d" >/dev/null 2>&1
f="$d/.github/workflows/freshness.yml"; v="$d/.github/workflows/deployment-verification.yml"
check "freshness.yml exists" test -f "$f"
refuse "the job left the verification workflow" grep -q "check-pin-freshness:" "$v"
check "the comment above the job went with it" grep -q "THE COMMENT ABOVE THE JOB" "$f"
check "and the comments inside it" grep -q "and the ones inside it" "$f"
want="  group: pin-freshness-\${{ github.ref }}"
check "its concurrency group is its own, and whole" grep -qxF "$want" "$f"
check "the environment came with its comments" grep -q "a comment inside the environment" "$f"
check "the other jobs stayed" grep -qE "^  (deploy-and-test|lint):" "$v"
out="$(python3 scripts/split-freshness.py "$d" 2>&1)"
check "a second run changes nothing" grep -q "already split" <<<"$out"

echo
echo "=== what it must refuse ==="
d="$WORK/b"; fixture "$d"
python3 - "$d/.github/workflows/deployment-verification.yml" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p).read()
s = s.replace("    needs: lint\n", "    needs: [lint, check-pin-freshness]\n")
io.open(p, "w").write(s)
PY
out="$(python3 scripts/split-freshness.py "$d" 2>&1)"; rc=$?
check "a job that needs the freshness job is refused" test "$rc" -ne 0
check "and it says which" grep -q "needs the moved job" <<<"$out"
refuse "and nothing was written" test -f "$d/.github/workflows/freshness.yml"

d="$WORK/c"; fixture "$d"
sed -i.bak 's/check-pin-freshness:/check-something-else:/' "$d/.github/workflows/deployment-verification.yml"
out="$(python3 scripts/split-freshness.py "$d" 2>&1)"; rc=$?
check "no freshness job is refused, not guessed" test "$rc" -ne 0
check "and it says why" grep -q "exactly one freshness job" <<<"$out"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
