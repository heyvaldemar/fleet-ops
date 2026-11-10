#!/usr/bin/env bash
# The template pin check, run on recorded registry answers in both directions.
#
# tests/fixtures/same-build/ holds four indexes exactly as the registry served
# them, each named by its own digest (the first case checks that):
#   alpine:3.22 bfe7ceb9… (2026-11-08) and 49340b34… (2026-11-09): the second
#     rebuilt only linux/riscv64 and its attestation; linux/amd64 is
#     9db29348… in both. Fifteen templates went red over this on 2026-11-09.
#   quay.io/keycloak/keycloak:26.8.2 3879c623… and 723b1d6e…: linux/amd64
#     moved from 4340d05e… to c126f032…, a new build, an update.
#
# The step under test is the fleet's standard one, run the way GitHub runs it
# (bash -eo pipefail) against a docker that answers from those files: once as
# it was, to show the false red, and once after the rollout's transform.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
ROLL="$ROOT/scripts/rollout-freshness-same-build.py"
FIX="$ROOT/tests/fixtures/same-build"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok    $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — wanted [$3] in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1 — did not want [$3]" ;; *) ok "$1" ;; esac; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — wanted [$2], got [$3]"; fi; }

A_OLD=sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034
A_NEW=sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
K_OLD=sha256:3879c623248408de29a5303178b5816c77e8dfef3890c361f8c0bbeaa979ba3b
K_NEW=sha256:723b1d6e254c0fc96d5cffec860c7e0744d6a3277822b865bb538cf891575e41
A_REF=alpine:3.22
K_REF=quay.io/keycloak/keycloak:26.8.2

python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: PyYAML is needed to read the step out of the workflow"; exit 1; }

echo "== the recordings are what the registry served"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
for d in "$A_OLD" "$A_NEW" "$K_OLD" "$K_NEW"; do
  same "${d:7:12}.json hashes to its own name" "${d#sha256:}" "$(sha "$FIX/${d#sha256:}.json")"
done
amd() { jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64" and ((.platform.variant // "") == ""))][0].digest' "$FIX/${1#sha256:}.json"; }
A_AMD="$(amd "$A_OLD")"
same "both alpine indexes carry one linux/amd64 build" "$A_AMD" "$(amd "$A_NEW")"
if [ "$(amd "$K_OLD")" != "$(amd "$K_NEW")" ]; then ok "the keycloak indexes carry two linux/amd64 builds"; else no "keycloak amd64 builds differ"; fi

# ---------------------------------------------------------------- a template
mkdir -p "$WORK/bin" "$WORK/raw" "$WORK/t/.github/workflows"
cat > "$WORK/t/.github/workflows/freshness.yml" <<'YML'
name: Pin Freshness

on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  check-pin-freshness:
    name: Check pinned images for upstream drift
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Compare pinned digests against what each tag resolves to now
        run: |
          status=0
          for var in APP_BACKUPS_IMAGE_TAG APP_IMAGE_TAG; do
            pin="$(grep -m1 -oE "\\$\\{${var}:-.*" app.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
            ref="${pin%%@*}"
            pinned_digest="${pin##*@}"
            # Three attempts: an unanswered registry lookup used to leave this empty,
            # and the comparison below then reported it as drift.
            current_digest=""
            for attempt in 1 2 3; do
              current_digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty')"
              [ -n "$current_digest" ] && break
              sleep $(( attempt * 5 ))
            done
            if [ -z "$current_digest" ]; then
              echo "::error::${ref} did not resolve after three attempts: the registry did not answer, or the tag is gone. The pin itself is unchanged."
              status=1
              continue
            fi
            if [ "$pinned_digest" != "$current_digest" ]; then
              echo "::error::${var} digest drift: pinned ${pinned_digest}, but ${ref} now resolves to ${current_digest}"
              status=1
            else
              echo "${var} OK (${ref})"
            fi
          done
          exit "$status"
YML
cat > "$WORK/t/app.yml" <<YML
services:
  app:
    image: \${APP_IMAGE_TAG:-$K_REF@$K_OLD}
  backups:
    image: \${APP_BACKUPS_IMAGE_TAG:-$A_REF@$A_OLD}
YML
cp "$WORK/t/.github/workflows/freshness.yml" "$WORK/before.yml"

# A docker that answers imagetools from the recordings. CURRENT says what each
# tag resolves to now; RAW_DOWN makes every --raw read fail like a registry
# that did not answer. Every call is logged.
cat > "$WORK/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[ "$1 $2 $3" = "buildx imagetools inspect" ] || { echo "fake docker: $*" >&2; exit 2; }
shift 3
if [ "$1" = "--raw" ]; then
  [ -z "${RAW_DOWN:-}" ] || { echo "ERROR: failed to do request: connection reset" >&2; exit 1; }
  d="${2##*@}"; d="${d#sha256:}"
  for f in "$FIX/$d.json" "$RAW/$d.json"; do [ -f "$f" ] && { cat "$f"; exit 0; }; done
  echo "ERROR: $2: not found" >&2; exit 1
fi
d="$(awk -v r="$1" '$1 == r {print $2}' "$CURRENT")"
[ -n "$d" ] || { echo "ERROR: $1: not found" >&2; exit 1; }
printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","size":2364}\n' "$d"
SH
chmod +x "$WORK/bin/docker"

step() {             # step <workflow>: the drift step's script, as GitHub hands it to bash
  python3 - "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for j in wf["jobs"].values() for s in j["steps"] if "digest drift" in s.get("run", "")))
PY
}
OUT="" RC=0
run_step() {         # run_step <workflow> <alpine now> <keycloak now>: OUT, RC
  step "$1" > "$WORK/step.sh"
  printf '%s %s\n%s %s\n' "$A_REF" "$2" "$K_REF" "$3" > "$WORK/current"
  : > "$WORK/docker.log"
  RC=0
  OUT="$(cd "$WORK/t" && PATH="$WORK/bin:$PATH" FIX="$FIX" RAW="$WORK/raw" CURRENT="$WORK/current" \
         DOCKER_LOG="$WORK/docker.log" bash --noprofile --norc -eo pipefail "$WORK/step.sh" 2>&1)" || RC=$?
}

echo "== as it was: a re-pushed index is reported as drift"
run_step "$WORK/before.yml" "$A_NEW" "$K_OLD"
same "the old step fails on alpine's re-pushed index" 1 "$RC"
has "and calls it drift" "$OUT" "APP_BACKUPS_IMAGE_TAG digest drift: pinned $A_OLD, but $A_REF now resolves to $A_NEW"

echo "== the rollout's transform"
msg="$(python3 "$ROLL" --file "$WORK/t/.github/workflows/freshness.yml")"; rc=$?
same "the standard step is changed" "0:1 site" "$rc:$msg"
AFTER="$WORK/t/.github/workflows/freshness.yml"
same "the error lines are the same text as before" "$(grep '::error::' "$WORK/before.yml")" "$(grep '::error::' "$AFTER")"
same "the helper is inserted once" 1 "$(grep -c '^ *new_build() {' "$AFTER")"

echo "== same build: the index moved, linux/amd64 did not"
run_step "$AFTER" "$A_NEW" "$K_OLD"
same "passes" 0 "$RC"
has "with a notice naming both digests and the build" "$OUT" "::notice::$A_REF index moved from $A_OLD to $A_NEW over the same linux/amd64 build $A_AMD"
has "and the pin reported OK" "$OUT" "APP_BACKUPS_IMAGE_TAG OK ($A_REF)"
hasnt "and no drift" "$OUT" "digest drift"

echo "== new build: linux/amd64 moved"
run_step "$AFTER" "$A_OLD" "$K_NEW"
same "fails" 1 "$RC"
has "as drift, in the words it always used" "$OUT" "::error::APP_IMAGE_TAG digest drift: pinned $K_OLD, but $K_REF now resolves to $K_NEW"
hasnt "without a same-build notice" "$OUT" "::notice::"

echo "== both in one run"
run_step "$AFTER" "$A_NEW" "$K_NEW"
same "fails, for the one that moved" 1 "$RC"
has "the re-push is a notice" "$OUT" "::notice::$A_REF index moved"
has "the new build is drift" "$OUT" "APP_IMAGE_TAG digest drift"
hasnt "and the re-push is not" "$OUT" "APP_BACKUPS_IMAGE_TAG digest drift"

echo "== nothing moved"
run_step "$AFTER" "$A_OLD" "$K_OLD"
same "passes" 0 "$RC"
hasnt "without reading a single index" "$(cat "$WORK/docker.log")" "--raw"

echo "== fails closed"
RAW_DOWN=1; export RAW_DOWN
run_step "$AFTER" "$A_NEW" "$K_OLD"
unset RAW_DOWN
same "an index that cannot be read is still drift" 1 "$RC"
has "named as drift" "$OUT" "APP_BACKUPS_IMAGE_TAG digest drift"
# an index with no plain linux/amd64: an arm64 build and an amd64/v3 one only
X=sha256:$(printf 'x%.0s' {1..64} | tr x 1)
printf '{"manifests":[{"digest":"sha256:%s","platform":{"os":"linux","architecture":"arm64"}},{"digest":"%s","platform":{"os":"linux","architecture":"amd64","variant":"v3"}}]}\n' \
  "$(printf 'a%.0s' {1..64})" "$A_AMD" > "$WORK/raw/${X#sha256:}.json"
run_step "$AFTER" "$X" "$K_OLD"
same "an index without a plain linux/amd64 build cannot be compared, so it is drift" 1 "$RC"

# --------------------------------------------------------------- the shapes
echo "== every shape the fleet has, and what is refused"
mkdir -p "$WORK/s"
python3 - "$WORK/before.yml" "$WORK/s" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
t = open(src).read()
# terraform-verification: a missing pin is caught first, so the compare is an elif
open(out + "/elif.yml", "w").write(t.replace(
    '              continue\n            fi\n            if [ "$pinned_digest"',
    '            elif [ "$pinned_digest"'))
# a single pin, no loop variable in the message
open(out + "/novar.yml", "w").write(t.replace("::error::${var} digest drift", "::error::digest drift"))
# two compares in one block: the helper still goes in once
two = t.replace('          exit "$status"\n',
    '          pin="$(grep -m1 -oE \'\\$\\{X_IMAGE_TAG:-.*\' app.yml)"\n'
    '          ref="${pin%%@*}"; pinned_digest="${pin##*@}"; current_digest="$pinned_digest"\n'
    '          if [ "$pinned_digest" != "$current_digest" ]; then\n'
    '            echo "::error::X_IMAGE_TAG digest drift: pinned ${pinned_digest}, but ${ref} now resolves to ${current_digest}"\n'
    '          fi\n'
    '          exit "$status"\n')
open(out + "/two.yml", "w").write(two)
# a drift line under a comparison this does not know
open(out + "/unknown.yml", "w").write(t.replace(
    'if [ "$pinned_digest" != "$current_digest" ]; then', 'if ! cmp_digests "$pinned_digest" "$current_digest"; then'))
# the image reference held in another name
open(out + "/noref.yml", "w").write(t.replace('ref="${pin%%@*}"', 'image="${pin%%@*}"; ref="$image"'))
# a step that is not bash
open(out + "/sh.yml", "w").write(t.replace("        run: |\n          status=0", "        shell: sh\n        run: |\n          status=0"))
# no drift check at all
open(out + "/none.yml", "w").write("name: x\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
PY
r() { local m rc; m="$(python3 "$ROLL" --file "$WORK/s/$1.yml")"; rc=$?; printf '%s:%s' "$rc" "$m"; }
same "elif (the terraform CI images): changed" "0:1 site" "$(r elif)"
# shellcheck disable=SC2016 # the workflow's own text, not this script's variables
ELIF='elif [ "$pinned_digest" != "$current_digest" ] && new_build "$ref"'
if grep -qF "$ELIF" "$WORK/s/elif.yml"; then ok "  and it stays an elif"; else no "  and it stays an elif"; fi
same "  a second pass changes nothing" "1:already compares the build" "$(r elif)"
same "a single pin, no variable in the message: changed" "0:1 site" "$(r novar)"
same "  a second pass changes nothing" "1:already compares the build" "$(r novar)"
same "two compares in one block: both changed" "0:2 sites" "$(r two)"
same "  and the helper is in it once" 1 "$(grep -c '^ *amd64_build() {' "$WORK/s/two.yml")"
same "a second pass changes nothing" "1:already compares the build" "$(r two)"
for c in unknown noref sh; do cp "$WORK/s/$c.yml" "$WORK/s/$c.orig"; done
case "$(r unknown)" in 2:*) ok "an unknown comparison is refused" ;; *) no "unknown comparison: $(r unknown)" ;; esac
case "$(r noref)" in 2:*) ok "a reference not held in \$ref is refused" ;; *) no "noref: $(r noref)" ;; esac
case "$(r sh)" in 2:*) ok "a step that is not bash is refused" ;; *) no "sh: $(r sh)" ;; esac
for c in unknown noref sh; do
  if cmp -s "$WORK/s/$c.yml" "$WORK/s/$c.orig"; then ok "  $c left untouched"; else no "  $c was written"; fi
done
same "a workflow with no drift check is left alone" "3:no digest drift check" "$(r none)"
for c in elif novar two; do
  if step "$WORK/s/$c.yml" > "$WORK/s/$c.sh" && bash -n "$WORK/s/$c.sh"; then ok "$c: the step still parses"; else no "$c: the step does not parse"; fi
done

# ------------------------------------------------------------- the changelog
echo "== the changelog line"
mkdir -p "$WORK/c1" "$WORK/c2" "$WORK/c3"
printf '# Changelog\n\n## [Unreleased]\n\n_(no unreleased changes yet)_\n\n## [1.0.0] - 2026-01-01\n\n- first\n' > "$WORK/c1/CHANGELOG.md"
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- **Earlier fix.**\n\n## [1.0.0] - 2026-01-01\n' > "$WORK/c2/CHANGELOG.md"
printf '# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- **Earlier change.**\n\n## [1.0.0] - 2026-01-01\n' > "$WORK/c3/CHANGELOG.md"
python3 - "$ROLL" "$WORK" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("roll", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for c in ("c1", "c2", "c3"):
    m.changelog(sys.argv[2] + "/" + c)
PY
c1="$(cat "$WORK/c1/CHANGELOG.md")"; c2="$(cat "$WORK/c2/CHANGELOG.md")"; c3="$(cat "$WORK/c3/CHANGELOG.md")"
has "an empty [Unreleased] gets a Fixed section" "$c1" "## [Unreleased]

### Fixed

- **An index pushed again over the same build is no longer reported as drift.**"
hasnt "  and loses its placeholder" "$c1" "_(no unreleased changes yet)_"
has "an existing Fixed section gets the line on top" "$c2" "### Fixed

- **An index pushed again over the same build is no longer reported as drift.**"
has "  above what was there" "$c2" "rebuilt, and no pin"
same "  once" 1 "$(grep -c '^### Fixed' "$WORK/c2/CHANGELOG.md")"
has "a Changed-only section gets a Fixed one beside it" "$c3" "### Changed

- **Earlier change.**"
has "  with the line" "$c3" "### Fixed

- **An index pushed again"
hasnt "nothing lands in a released version" "$(sed -n '/^## \[1.0.0\]/,$p' "$WORK/c1/CHANGELOG.md")" "An index pushed again"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
