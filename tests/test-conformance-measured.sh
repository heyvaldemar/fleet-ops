#!/bin/bash
# Every rule for measured Kubernetes repositories in fleet-conformance.py,
# shown a real violation on a copy of the inference gateway.
#
# Same method as test-conformance-sandbox.sh: a conforming copy of the real
# repository must come back clean, and each copy broken in one rule's way must
# come back with that rule's finding.
#
#   ./tests/test-conformance-measured.sh <kubernetes-llm-inference-gateway checkout>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/fleet-conformance.py"
REF="${1:-$ROOT/../kubernetes-llm-inference-gateway}"
[ -d "$REF" ] || { echo "error: no reference repository at $REF" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
run_on() { FLEET_LOCAL_DIR="$1" python3 "$CHECKER" 2>&1; }
git_in() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }

# A conforming copy, named as the gateway (the rules are chosen by name), with
# one released, tagged version whatever the reference's own release state.
fixture() {          # fixture <case> -> the copy's directory
  local d="$WORK/$1/kubernetes-llm-inference-gateway"; rm -rf "${WORK:?}/${1:?}"; mkdir -p "$d"
  cp -R "$REF/." "$d/"; rm -rf "$d/.git" "$d/results" "$d/.kubeconfig"
  printf '# Changelog\n\n## [1.0.0] - 2026-10-30\n\n### Added\n\n- The comparison.\n' > "$d/CHANGELOG.md"
  git_in "$d" init -q && git_in "$d" add -A && git_in "$d" commit -qm fixture && git_in "$d" tag v1.0.0
  printf '%s' "$d"
}

expect() {           # expect <name> <parent> <substring>
  local name="$1" parent="$2" want="$3" out
  out="$(run_on "$parent")"
  if printf '%s' "$out" | grep -qF -- "$want"; then
    echo "  PASS: $name"; PASSED=$((PASSED+1))
  else
    echo "  FAIL: $name — expected a finding containing:"
    echo "        $want"
    echo "        got:"; printf '%s\n' "$out" | sed 's/^/        /' | head -14
    FAILED=$((FAILED+1))
  fi
}

expect_clean() {     # expect_clean <name> <parent>
  local out
  out="$(run_on "$2")"
  if printf '%s' "$out" | grep -q 'Every repository meets the standard'; then
    echo "  PASS: $1"; PASSED=$((PASSED+1))
  else
    echo "  FAIL: $1 — reported as broken:"; printf '%s\n' "$out" | sed 's/^/        /' | head -16
    FAILED=$((FAILED+1))
  fi
}

edit() { local f="$1"; shift; sed -i.bak "$@" "$f" && rm -f "$f.bak"; }

echo "=== fleet conformance, measured Kubernetes rules: does every rule fire? ==="
echo "gateway reference: $REF"
echo

fixture control >/dev/null
expect_clean "an untouched gateway copy is reported as conforming" "$WORK/control"

d="$(fixture files)"; rm -rf "$d/loadgen"
expect "a gateway whose files say otherwise is caught" "$WORK/files" "named as a measured Kubernetes repository, but its files say"

d="$(fixture security)"; rm -f "$d/SECURITY.md"
expect "a missing SECURITY.md is caught" "$WORK/security" "missing SECURITY.md"

d="$(fixture noe2e)"; edit "$d/.github/workflows/e2e.yml" 's#tests/e2e.sh#tests/nothing.sh#g'
expect "CI that never runs the measurement is caught" "$WORK/noe2e" "no workflow runs tests/e2e.sh on a kind cluster"

d="$(fixture nodaily)"; edit "$d/.github/workflows/e2e.yml" -e '/^  schedule:/d' -e '/- cron:/d'
expect "a measurement that never runs on its own is caught" "$WORK/nodaily" "the e2e workflow has no schedule"

d="$(fixture noplants)"; grep '^#' "$d/tests/plants.tsv" > "$d/p" && mv "$d/p" "$d/tests/plants.tsv"
expect "a measurement with no planted break is caught" "$WORK/noplants" "no planted breaks in tests/plants.tsv"

d="$(fixture noplantrun)"; edit "$d/.github/workflows/e2e.yml" 's#tests/plant-violations.py#tests/nothing.py#g'
expect "CI that never shows the measurement its plants is caught" "$WORK/noplantrun" "no workflow shows the measurement its planted breaks"

d="$(fixture lock)"; edit "$d/images.lock" 's#^\(SIM_IMAGE=[^@]*\)@sha256:[0-9a-f]*#\1#'
expect "an image in images.lock without a digest is caught" "$WORK/lock" "images.lock: SIM_IMAGE is not pinned by digest"

d="$(fixture tag)"; edit "$d/deploy/model-server.yaml" 's#\(image: [^@]*\)@sha256:[0-9a-f]*#\1#'
expect "a deployed image without a digest is caught" "$WORK/tag" "deploy/model-server.yaml: image"

d="$(fixture cost)"; edit "$d/README.md" 's/^## What it costs$/## Money/'
expect "a README silent on cost is caught" "$WORK/cost" "README says nothing about what it costs"

d="$(fixture adrs)"; adrs=("$d"/docs/decisions/0*.md); rm -f "${adrs[@]:2}"
expect "too few decision records are caught" "$WORK/adrs" "decision records; the standard asks for at least 3"

d="$(fixture claim)"; printf '\nBattle-tested at scale.\n' >> "$d/README.md"
expect "a production claim is caught" "$WORK/claim" "README.md claims"

d="$(fixture runbooks)"; rm -rf "$d/docs/runbooks"
expect_clean "a measured repository is not asked for a platform's runbooks" "$WORK/runbooks"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
