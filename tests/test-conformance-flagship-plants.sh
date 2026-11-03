#!/bin/bash
# The plants rule met by a flagship's planted manifests (fleet-conformance.py,
# flagship_plants), shown a real violation on a copy of kubernetes-oscal-evidence.
#
# kubernetes-oscal-evidence plants nothing of its own: its run reads the
# flagship's planted pods from the release flagship.lock pins. A copy of it,
# beside a copy of the flagship's tests/e2e/plants at the pinned tag, must
# come back clean; each copy broken in one link's way (the lock, the tag, the
# flagship's plants, the run) must come back with that link's finding.
#
#   ./tests/test-conformance-flagship-plants.sh <kubernetes-oscal-evidence checkout> <kubernetes-air-gapped-ai-agent checkout, with its tags>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/fleet-conformance.py"
REF="${1:-$ROOT/../kubernetes-oscal-evidence}"
FLAG="${2:-$ROOT/../kubernetes-air-gapped-ai-agent}"
for d in "$REF" "$FLAG"; do [ -d "$d" ] || { echo "error: no reference repository at $d" >&2; exit 1; }; done
read -r LOCKED TAG _ < <(grep -vE '^[[:space:]]*(#|$)' "$REF/flagship.lock" | head -n 1)
FLAGNAME="${LOCKED#*/}"
git -C "$FLAG" rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || { echo "error: $FLAG has no tag $TAG, which $REF/flagship.lock pins (fetch its tags)" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
run_on() { FLEET_LOCAL_DIR="$1" python3 "$CHECKER" 2>&1; }
git_in() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }

# A case: the repository under test, every version its changelog names
# tagged, beside the flagship's planted manifests as they are at the pinned
# tag. The flagship copy has no changelog, so it is read, not judged.
fixture() {          # fixture <case> -> the copy's directory
  local c="$WORK/$1" d f; rm -rf "${WORK:?}/${1:?}"
  d="$c/kubernetes-oscal-evidence"; f="$c/$FLAGNAME"; mkdir -p "$d" "$f"
  cp -R "$REF/." "$d/"; rm -rf "$d/.git" "$d/.cache" "$d/.venv" "$d/out"
  git_in "$d" init -q && git_in "$d" add -A && git_in "$d" commit -qm fixture
  sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' "$d/CHANGELOG.md" | while read -r v; do git_in "$d" tag "v$v"; done
  git -C "$FLAG" archive "$TAG" tests/e2e/plants | tar -x -C "$f"
  printf '# %s\n' "$FLAGNAME" > "$f/README.md"
  git_in "$f" init -q && git_in "$f" add -A && git_in "$f" commit -qm fixture && git_in "$f" tag "$TAG"
  printf '%s' "$c"
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
relock() { local d="$1"; shift; edit "$d/kubernetes-oscal-evidence/flagship.lock" "$@"; git_in "$d/kubernetes-oscal-evidence" commit -qam relock; }

echo "=== fleet conformance, the plants rule met by a flagship's plants: does every link hold? ==="
echo "repository: $REF"
echo "flagship:   $FLAG at $TAG"
echo

c="$(fixture control)"
expect_clean "the repository, beside its flagship's plants at the pinned tag, is reported as conforming" "$c"

c="$(fixture nolock)"; git_in "$c/kubernetes-oscal-evidence" rm -q flagship.lock; git_in "$c/kubernetes-oscal-evidence" commit -qm nolock
expect "no plants and no flagship.lock is still no plants" "$c" "no planted manifests in tests/e2e/plants: no refusal is ever tried"

c="$(fixture stranger)"; relock "$c" "s#^$LOCKED #someone-else/$FLAGNAME #"
expect "a lock naming a repository outside the fleet is caught" "$c" "which is not a fleet repository"

c="$(fixture tag)"; relock "$c" "s#^$LOCKED $TAG #$LOCKED v99.0.0 #"
expect "a lock naming a tag that is not a release is caught" "$c" "at v99.0.0, which is not a release of it"

c="$(fixture flagnoplants)"; f="$c/$FLAGNAME"
git_in "$f" rm -rq tests/e2e/plants && git_in "$f" commit -qm "no plants" && git_in "$f" tag -f "$TAG" >/dev/null
expect "a lock naming a repository with no plants at that tag is caught" "$c" "which plants nothing either"

c="$(fixture flagnocontrol)"; f="$c/$FLAGNAME"
grep -l '^# expect: admitted' "$f"/tests/e2e/plants/*.yaml | while read -r p; do git_in "$f" rm -q "${p#"$f"/}"; done
git_in "$f" commit -qm "no control" && git_in "$f" tag -f "$TAG" >/dev/null
expect "a flagship whose plants have no admitted control is caught" "$c" "whose plants fall short: no planted manifest expects to be admitted"

c="$(fixture ownplants)"; d="$c/kubernetes-oscal-evidence"
edit "$d/scripts/tests.py" 's#os.path.join(FLAGSHIP, "tests/e2e/plants/\*.yaml")#os.path.join(ROOT, "tests/e2e/plants/*.yaml")#'
git_in "$d" commit -qam ownplants
expect "a run that reads planted pods from anywhere but the flagship's release is caught" "$c" "scripts/tests.py reads tests/e2e/plants from somewhere other than"

c="$(fixture noread)"; d="$c/kubernetes-oscal-evidence"
edit "$d/tests/e2e/run.sh" -e '/scripts\/tests\.py/d' -e '/scripts\/component\.py/d'
git_in "$d" commit -qam noread
expect "a run that never reads the flagship's plants is caught" "$c" "tests/e2e/run.sh never reads $FLAGNAME's tests/e2e/plants"

c="$(fixture nofetch)"; d="$c/kubernetes-oscal-evidence"
edit "$d/tests/e2e/run.sh" '/scripts\/flagship\.sh/d'
git_in "$d" commit -qam nofetch
expect "a run that never downloads the flagship's release is caught" "$c" "never downloads the release flagship.lock names"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
