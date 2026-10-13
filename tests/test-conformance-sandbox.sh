#!/bin/bash
# Every rule for focused Kubernetes repositories in fleet-conformance.py,
# shown a real violation on a copy of the agent sandbox.
#
# Same method as test-conformance-kubernetes.sh: a conforming copy of the real
# sandbox must come back clean, and each copy broken in one rule's way must
# come back with that rule's finding.
#
#   ./tests/test-conformance-sandbox.sh <kubernetes-ai-agent-sandbox checkout>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/fleet-conformance.py"
REF="${1:-$ROOT/../kubernetes-ai-agent-sandbox}"
[ -d "$REF" ] || { echo "error: no reference repository at $REF" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
run_on() { FLEET_LOCAL_DIR="$1" python3 "$CHECKER" 2>&1; }
git_in() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }

# A conforming copy, named as the sandbox (the rules are chosen by name), with
# one released, tagged version whatever the reference's own release state.
fixture() {          # fixture <case> -> the copy's directory
  local d="$WORK/$1/kubernetes-ai-agent-sandbox"; rm -rf "${WORK:?}/${1:?}"; mkdir -p "$d"
  cp -R "$REF/." "$d/"; rm -rf "$d/.git" "$d/.cache" "$d/out"
  printf '# Changelog\n\n## [1.0.0] - 2026-10-13\n\n### Added\n\n- The sandbox.\n' > "$d/CHANGELOG.md"
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

echo "=== fleet conformance, focused Kubernetes rules: does every rule fire? ==="
echo "sandbox reference: $REF"
echo

fixture control >/dev/null
expect_clean "an untouched sandbox copy is reported as conforming" "$WORK/control"

d="$(fixture files)"; rm -rf "$d/manifests"
expect "a sandbox whose files say otherwise is caught" "$WORK/files" "named as a focused Kubernetes repository, but its files say"

d="$(fixture security)"; rm -f "$d/SECURITY.md"
expect "a missing SECURITY.md is caught" "$WORK/security" "missing SECURITY.md"

d="$(fixture plants)"; grep -v '"images"' "$d/tests/static/plants.tsv" > "$d/p" && mv "$d/p" "$d/tests/static/plants.tsv"
expect "a static check with no planted violation is caught" "$WORK/plants" "no planted violation for the images check"

d="$(fixture novalidate)"; edit "$d/.github/workflows/verify.yml" 's#scripts/validate.sh#scripts/validate-nothing.sh#'
expect "CI that never runs validate.sh is caught" "$WORK/novalidate" "no workflow runs scripts/validate.sh"

d="$(fixture noplantrun)"; edit "$d/.github/workflows/verify.yml" '/tests\/static\/plant_violations.py/d'
expect "CI that never shows the static checks their plants is caught" "$WORK/noplantrun" "no workflow shows the static checks their planted violations"

d="$(fixture nodaily)"; edit "$d/.github/workflows/e2e.yml" -e '/^  schedule:/d' -e '/- cron:/d'
expect "an e2e that never runs on its own is caught" "$WORK/nodaily" "the e2e workflow has no schedule"

d="$(fixture noexpect)"; edit "$d/tests/e2e/plants/no-gvisor.yaml" '/^# expect: /d'
expect "a planted manifest that does not say what it expects is caught" "$WORK/noexpect" "tests/e2e/plants/no-gvisor.yaml does not say what it expects"

d="$(fixture nocontrol)"; rm -f "$d/tests/e2e/plants/compliant-pod.yaml"
expect "refusals without an admitted control are caught" "$WORK/nocontrol" "no planted manifest expects to be admitted"

d="$(fixture tag)"; edit "$d/manifests/tools.yaml" 's#\(image: [^@]*\)@sha256:[0-9a-f]*#\1#'
expect "a manifest image without a digest is caught" "$WORK/tag" "manifests/tools.yaml: image"

d="$(fixture cost)"; edit "$d/README.md" 's/^## Cost$/## Money/'
expect "a README silent on cost is caught" "$WORK/cost" "README says nothing about what it costs"

d="$(fixture adrs)"; rm -f "$d"/docs/decisions/000[23]-*.md
expect "too few decision records are caught" "$WORK/adrs" "decision records; the standard asks for at least 3"

d="$(fixture claim)"; printf '\nBattle-tested at scale.\n' >> "$d/README.md"
expect "a production claim is caught" "$WORK/claim" "README.md claims"

d="$(fixture automerge)"; edit "$d/.github/workflows/dependabot-automerge.yml" 's/workflows: \[".*"\]/workflows: ["kind e2e"]/'
expect "an auto-merge that waits for a workflow the repository does not have is caught" "$WORK/automerge" 'waits for a workflow named "kind e2e"'

d="$(fixture runbooks)"; rm -rf "$d/docs/runbooks"
expect_clean "a sandbox is not asked for a platform's runbooks" "$WORK/runbooks"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
