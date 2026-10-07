#!/usr/bin/env bash
# Every shell script in this repository is committed executable.
#
# scripts/fleet-triage.sh was committed without its exec bit on 2026-09-01.
# The workflows run `chmod +x` on it, which works, and leaves the file
# modified in the checkout, which nobody noticed until it mattered: the step
# that pushes the pending ledger rebases first, git refuses to rebase over a
# modified file, and on 2026-10-06 the ledger was lost the one time main moved
# during a run. A script committed executable makes that chmod a no-op.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bad="$(git ls-files -s -- 'scripts/*.sh' 'tests/*.sh' | awk '$1 != "100755" {print $4}')"
if [ -z "$bad" ]; then
  echo "  ok    every script under scripts/ and tests/ is committed executable"
  exit 0
fi
echo "  FAIL  committed without the exec bit (git update-index --chmod=+x):"
while IFS= read -r f; do echo "        $f"; done <<<"$bad"
exit 1
