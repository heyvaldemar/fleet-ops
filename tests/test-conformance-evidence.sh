#!/bin/bash
# Every rule for evidence repositories in fleet-conformance.py, shown a real
# violation on a copy of cloud-evidence-pack.
#
# Same method as test-conformance-measured.sh: a conforming copy of the real
# repository must come back clean, and each copy broken in one rule's way must
# come back with that rule's finding.
#
#   ./tests/test-conformance-evidence.sh <cloud-evidence-pack checkout>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/fleet-conformance.py"
REF="${1:-$ROOT/../cloud-evidence-pack}"
[ -d "$REF" ] || { echo "error: no reference repository at $REF" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
run_on() { FLEET_LOCAL_DIR="$1" python3 "$CHECKER" 2>&1; }
git_in() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }

# A conforming copy, named as the pack (the rules are chosen by name), with
# one released, tagged version whatever the reference's own release state.
fixture() {          # fixture <case> -> the copy's directory
  local d="$WORK/$1/cloud-evidence-pack"; rm -rf "${WORK:?}/${1:?}"; mkdir -p "$d"
  cp -R "$REF/." "$d/"; rm -rf "$d/.git" "$d/.cache" "$d/.venv"
  printf '# Changelog\n\n## [1.0.0] - 2026-11-12\n\n### Added\n\n- The packs.\n' > "$d/CHANGELOG.md"
  git_in "$d" init -q && git_in "$d" add -A && git_in "$d" commit -qm fixture && git_in "$d" tag v1.0.0
  printf '%s' "$d"
}

recommit() { git_in "$1" add -A && git_in "$1" commit -qm break; }

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

# The release check is wherever the exact identity of pack.yml on a tag is
# named: pack.yml itself (v1.0.0) or the script it runs (scripts/release-verify.sh).
release_check() {
  grep -l -E -- '--certificate-identity[ =]"?[^"[:space:]]*/\.github/workflows/pack\.yml@refs/tags/' \
    "$1/.github/workflows/pack.yml" "$1"/scripts/*.sh 2>/dev/null | head -1
}

echo "=== fleet conformance, evidence rules: does every rule fire? ==="
echo "pack reference: $REF"
echo

fixture control >/dev/null
expect_clean "an untouched pack copy is reported as conforming" "$WORK/control"

d="$(fixture files)"; rm -rf "$d/mapping"; recommit "$d"
expect "a pack whose files say otherwise is caught" "$WORK/files" "named as an evidence repository, but its files say"

d="$(fixture security)"; rm -f "$d/SECURITY.md"; recommit "$d"
expect "a missing SECURITY.md is caught" "$WORK/security" "missing SECURITY.md"

d="$(fixture staticplant)"; grep -v -F '"gate"' "$d/tests/static/plants.tsv" > "$d/p" && mv "$d/p" "$d/tests/static/plants.tsv"; recommit "$d"
expect "a static check with no planted violation is caught" "$WORK/staticplant" "no planted violation for the gate check"

d="$(fixture novalidate)"; edit "$d/.github/workflows/pack.yml" 's#scripts/validate.sh#scripts/nothing.sh#g'; recommit "$d"
expect "CI that never runs the static checks is caught" "$WORK/novalidate" "no workflow runs scripts/validate.sh"

d="$(fixture nodaily)"; edit "$d/.github/workflows/pack.yml" -e '/^  schedule:/d' -e '/- cron:/d'; recommit "$d"
expect "packs that are never built on their own are caught" "$WORK/nodaily" "the workflow that builds the packs has no schedule"

d="$(fixture nobuild)"; edit "$d/.github/workflows/pack.yml" -e 's#scripts/packs.sh#scripts/nothing.sh#g' -e 's#tests/e2e/run.sh#tests/e2e/nothing.sh#g'; recommit "$d"
expect "CI that never builds a pack is caught" "$WORK/nobuild" "no workflow builds the packs"

d="$(fixture cluster)"; printf '      - run: kind create cluster\n' >> "$d/.github/workflows/pack.yml"; recommit "$d"
expect "a pack built on a cluster of its own is caught" "$WORK/cluster" "creates a kind cluster"

d="$(fixture login)"; printf '      - uses: aws-actions/configure-aws-credentials@v4\n' >> "$d/.github/workflows/pack.yml"; recommit "$d"
expect "a pack workflow that logs in to a cloud is caught" "$WORK/login" "logs in to a cloud"

d="$(fixture nolinks)"; edit "$d/README.md" 's#actions/runs/[0-9]*#actions#g'; recommit "$d"
expect "a README that links no run is caught" "$WORK/nolinks" "the README links no run"

d="$(fixture norefusal)"; edit "$d/scripts/plant.py" 's#"red-run"#"red"#g'; recommit "$d"
expect "a refusal that is never planted is caught" "$WORK/norefusal" "plants no red-run run"

d="$(fixture plantcheck)"; edit "$d/scripts/validate.sh" 's#tests/e2e/plants.sh#tests/e2e/nothing.sh#g'; recommit "$d"
expect "static checks that never run the plants are caught" "$WORK/plantcheck" "no check_plants that runs tests/e2e/plants.sh"

d="$(fixture mutatecheck)"; edit "$d/scripts/validate.sh" 's#scripts/mutate.py#scripts/nothing.py#g'; recommit "$d"
expect "static checks that never switch the gate's rules off are caught" "$WORK/mutatecheck" "no check_mutations that runs scripts/mutate.py"

d="$(fixture plantlist)"; edit "$d/tests/e2e/plants.sh" 's#plant.py all#plant.py some#g'; recommit "$d"
expect "plants that do not come from the builder's own list are caught" "$WORK/plantlist" "does not take its plants from scripts/plant.py all"

d="$(fixture nomutations)"; grep '^#' "$d/tests/plants.tsv" > "$d/p"; mv "$d/p" "$d/tests/plants.tsv"; recommit "$d"
expect "a gate whose rules are never switched off is caught" "$WORK/nomutations" "no lines in tests/plants.tsv"

d="$(fixture noaks)"; rm -rf "$d"/tests/fixtures/runs/aks-*; recommit "$d"
expect "a cloud with no recorded run is caught" "$WORK/noaks" "no recorded aks run in tests/fixtures/runs"

d="$(fixture noarchive)"; for r in "$d"/tests/fixtures/runs/gke-*; do rm -f "$r"/*.zip; done; recommit "$d"
expect "a recorded run without its archive is caught" "$WORK/noarchive" "no gke run with its run.json, artifact.json and archive"

d="$(fixture noplantsdir)"; edit "$d/mapping/controls.yaml" 's#tests/e2e/plants#tests/e2e/elsewhere#g'; recommit "$d"
expect "a mapping that never names the flagship's plants is caught" "$WORK/noplantsdir" "never names the flagship's tests/e2e/plants"

d="$(fixture unsigned)"; edit "$d/.github/workflows/pack.yml" 's#cosign sign-blob#cosign sign-nothing#g'; recommit "$d"
expect "packs that are never signed are caught" "$WORK/unsigned" "pack.yml signs nothing"

d="$(fixture regexp)"; edit "$(release_check "$d")" 's#--certificate-identity "#--certificate-identity-regexp "#g'; recommit "$d"
expect "a release verified for any identity that matches is caught" "$WORK/regexp" "for the exact identity of pack.yml on a tag"

d="$(fixture noslsa)"; edit "$(release_check "$d")" 's#slsa-verifier verify-artifact#slsa-verifier version#g'; recommit "$d"
expect "a release whose provenance is never verified is caught" "$WORK/noslsa" "verifies the packs' provenance with slsa-verifier"

d="$(fixture nobyte)"; edit "$(release_check "$d")" "s#printf 'x' >>#cat /dev/null >>#g"; recommit "$d"
expect "a verification never shown a changed byte is caught" "$WORK/nobyte" "shows the verification a changed byte"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
