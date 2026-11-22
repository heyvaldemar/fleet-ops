#!/usr/bin/env bash
# templates/release-assets.yml: the steps that decide whether a release is
# trusted, run the way GitHub runs them (bash -eo pipefail), against stand-ins
# for cosign and slsa-verifier that behave like the real tools. A stand-in is
# handed what the signature and the provenance really say (the certificate's
# identity, the ref the provenance names) and answers in the tools' own words.
#
# Each case runs twice: on the template, and on the copy from before
# 16 November 2026 (tests/fixtures/release-assets/before-2026-11-16.yml).
# The old copy passed three things it should not have:
#   - a signature from any workflow of the repository, on any branch
#     (a prefix, '^https://github.com/<repo>/');
#   - a changed archive "refused" because Sigstore could not be reached or a
#     tool was missing, which says nothing about the archive;
#   - a run started by hand from a feature branch, whose provenance then
#     named that branch.
# The words the stand-ins use for a changed artifact are copied from
# cosign v3.1.4 and slsa-verifier v2.7.1 (Release Assets run 43741639578,
# outline-keycloak v2.2.27); LIVE=1 checks them against the real tools.
#
# LIVE=1 LIVE_DIR=<dir with a release's three files> LIVE_REPO=<owner/repo>
# LIVE_TAG=<tag> also runs the step with the real cosign and slsa-verifier:
# once as is, and once with the network cut, which must not be green.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
NEW="$ROOT/templates/release-assets.yml"
OLD="$ROOT/tests/fixtures/release-assets/before-2026-11-16.yml"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok    $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — wanted [$3] in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1 — did not want [$3]" ;; *) ok "$1" ;; esac; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — wanted [$2], got [$3]"; fi; }
red() { if [ "$2" -ne 0 ]; then ok "$1"; else no "$1 — wanted a failure, the step went green"; fi; }
green() { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1 — wanted green, the step exited $2: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)"; fi; }

python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: PyYAML is needed to read the steps out of the workflow"; exit 1; }

step() {   # step <workflow> <step name>: the step's script, as GitHub hands it to bash
  python3 - "$1" "$2" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
hits = [s["run"] for j in wf["jobs"].values() for s in j.get("steps", []) if s.get("name") == sys.argv[2]]
if len(hits) != 1:
    sys.exit("expected one step named %r, found %d" % (sys.argv[2], len(hits)))
print(hits[0])
PY
}
VERIFY="Verify the signature and the provenance, and that a changed archive fails both"

REPO=heyvaldemar/demo-template
TAG=v1.2.3
NAME="demo-template-$TAG"
RELEASE_SAN="https://github.com/$REPO/.github/workflows/release-assets.yml@refs/tags/$TAG"
COSIGN_REFUSAL="Error: failed to verify signature: could not verify message: invalid signature when validating ASN.1 encoded signature"
SLSA_REFUSAL="FAILED: SLSA verification failed: expected hash '0000' not found: artifact hash does not match provenance subject"
NET="tuf refresh failed: Get \"https://tuf-repo-cdn.sigstore.dev/15.root.json\": dial tcp: lookup tuf-repo-cdn.sigstore.dev: no such host"

# The stand-ins. CERT_SAN is the identity in the signing certificate,
# PROV_REF the ref the provenance names. *_CHANGED says what the tool does
# with the archive with one byte appended: refuse (as the tool does), net
# (Sigstore unreachable), gone (the tool is not installed), accept.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/cosign" <<'SH'
#!/usr/bin/env bash
echo "cosign $*" >> "$CALLS"
art="$2"; shift 2
id=""; rx=""
while [ $# -gt 0 ]; do
  case "$1" in
    --certificate-identity) id="$2"; shift 2 ;;
    --certificate-identity-regexp) rx="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$art" = changed.tar.gz ]; then
  case "$COSIGN_CHANGED" in
    net) echo "Error: setting trusted material: getting trusted root from TUF for new bundle verification: error getting live trusted root: $NET" >&2; exit 1 ;;
    gone) echo "bash: cosign: command not found" >&2; exit 127 ;;
    accept) echo "Verified OK"; exit 0 ;;
  esac
fi
if [ -n "$id" ] && [ "$id" != "$CERT_SAN" ]; then
  echo "Error: failed to verify certificate identity: no matching CertificateIdentity found, last error: expected SAN value \"$id\", got \"$CERT_SAN\"" >&2; exit 1
fi
if [ -n "$rx" ] && ! printf '%s' "$CERT_SAN" | grep -Eq -- "$rx"; then
  echo "Error: failed to verify certificate identity: no matching CertificateIdentity found" >&2; exit 1
fi
if [ "$art" = changed.tar.gz ]; then echo "$COSIGN_REFUSAL" >&2; exit 1; fi
echo "Verified OK"
SH
cat > "$WORK/bin/slsa-verifier" <<'SH'
#!/usr/bin/env bash
echo "slsa-verifier $*" >> "$CALLS"
art="$2"; shift 2
want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source-tag) want="refs/tags/$2"; shift 2 ;;
    --source-branch) want="refs/heads/$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$art" = changed.tar.gz ]; then
  case "$SLSA_CHANGED" in
    net) echo "FAILED: SLSA verification failed: $NET" >&2; exit 1 ;;
    gone) echo "bash: slsa-verifier: command not found" >&2; exit 127 ;;
    accept) echo "PASSED: SLSA verification passed"; exit 0 ;;
  esac
fi
if [ -n "$want" ] && [ "$want" != "$PROV_REF" ]; then
  echo "FAILED: SLSA verification failed: expected ref '$want', got '$PROV_REF'" >&2; exit 1
fi
if [ "$art" = changed.tar.gz ]; then echo "$SLSA_REFUSAL" >&2; exit 1; fi
echo "PASSED: SLSA verification passed"
SH
chmod +x "$WORK/bin/cosign" "$WORK/bin/slsa-verifier"

# run_verify <workflow> <event> <ref> <cert SAN> <provenance ref> <cosign on changed> <slsa on changed>: OUT, RC
run_verify() {
  local d="$WORK/run"; rm -rf "$d"; mkdir -p "$d/out"
  : > "$d/out/$NAME.tar.gz"; : > "$d/out/$NAME.tar.gz.sigstore.json"; : > "$d/out/$NAME.intoto.jsonl"
  step "$1" "$VERIFY" > "$d/step.sh" || { no "the verify step is in $1"; return; }
  CALLS="$d/calls"; : > "$CALLS"
  RC=0
  OUT="$(cd "$d" && env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$d" CALLS="$CALLS" NET="$NET" \
         COSIGN_REFUSAL="$COSIGN_REFUSAL" SLSA_REFUSAL="$SLSA_REFUSAL" \
         GITHUB_REPOSITORY="$REPO" GITHUB_REF="$3" GITHUB_REF_NAME="${3#refs/*/}" TAG="$TAG" EVENT="$2" \
         CERT_SAN="$4" PROV_REF="$5" COSIGN_CHANGED="$6" SLSA_CHANGED="$7" \
         bash --noprofile --norc -eo pipefail "$d/step.sh" 2>&1)" || RC=$?
  CALLED="$(cat "$CALLS")"
}

# A stand-in for gh: `gh release view <tag> --json assets --jq ...` prints the
# names in GH_ASSETS, one per line, or fails when GH_ASSETS is "fail".
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS"
[ "$GH_ASSETS" = fail ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
[ -n "$GH_ASSETS" ] && printf '%s\n' $GH_ASSETS
exit 0
SH
chmod +x "$WORK/bin/gh"

# run_meta <workflow> <event> <ref> [assets the release already has | fail]: OUT, RC for the "Which tag" step
run_meta() {
  local d="$WORK/meta"; rm -rf "$d"; mkdir -p "$d"
  step "$1" "Which tag" > "$d/step.sh" || { no "the Which tag step is in $1"; return; }
  CALLS="$d/calls"; : > "$CALLS"
  RC=0
  OUT="$(env -i PATH="$WORK/bin:/usr/bin:/bin" CALLS="$CALLS" GH_ASSETS="${4:-}" GITHUB_OUTPUT="$d/output" \
         GITHUB_REPOSITORY="$REPO" GITHUB_EVENT_NAME="$2" GITHUB_REF="$3" TAG="$TAG" \
         bash --noprofile --norc -eo pipefail "$d/step.sh" 2>&1)" || RC=$?
  CALLED="$(cat "$CALLS")"
}

echo "== the fixture is the template as it was"
same "before-2026-11-16.yml is blob 56d7d35a" 56d7d35aad9f5ba06f800e9214b2940a91a4eb51 "$(git hash-object "$OLD")"

echo "== a real release verifies, on both"
for wf in "$OLD" "$NEW"; do
  run_verify "$wf" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" refuse refuse
  green "$(basename "$wf"): signature, provenance and two real refusals" "$RC"
done
has "the template names the exact identity" "$CALLED" "--certificate-identity $RELEASE_SAN "
hasnt "the template names no prefix" "$CALLED" "identity-regexp"
has "a release is checked against its tag" "$CALLED" "--source-tag $TAG"

echo "== a signature from another workflow of the same repository"
OTHER="https://github.com/$REPO/.github/workflows/scratch.yml@refs/heads/try-something"
run_verify "$OLD" release "refs/tags/$TAG" "$OTHER" "refs/tags/$TAG" refuse refuse
green "the old prefix accepted it (the finding)" "$RC"
run_verify "$NEW" release "refs/tags/$TAG" "$OTHER" "refs/tags/$TAG" refuse refuse
red "the template refuses it" "$RC"
has "  in cosign's words" "$OUT" "no matching CertificateIdentity"
run_verify "$NEW" release "refs/tags/$TAG" "https://github.com/$REPO/.github/workflows/release-assets.yml@refs/heads/main" "refs/tags/$TAG" refuse refuse
red "the template refuses this file signed on main for a release" "$RC"

echo "== Sigstore unreachable for the changed archive"
run_verify "$OLD" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" net refuse
green "the old step read cosign's network error as a refusal (the finding)" "$RC"
run_verify "$NEW" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" net refuse
red "the template fails on cosign's network error" "$RC"
has "  and says why" "$OUT" "cosign exited 1 on the changed archive without saying it changed"
run_verify "$OLD" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" refuse net
green "the old step read slsa-verifier's network error as a refusal (the finding)" "$RC"
run_verify "$NEW" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" refuse net
red "the template fails on slsa-verifier's network error" "$RC"
has "  and says why" "$OUT" "slsa-verifier exited 1 on the changed archive without saying it changed"

echo "== a tool missing for the changed archive"
run_verify "$OLD" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" gone refuse
green "the old step read 'command not found' as a refusal (the finding)" "$RC"
run_verify "$NEW" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" gone refuse
red "the template fails on it" "$RC"
has "  and names the exit code" "$OUT" "cosign exited 127"
run_verify "$NEW" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" refuse gone
red "the template fails when slsa-verifier is the one missing" "$RC"

echo "== a tool that accepts the changed archive"
for wf in "$OLD" "$NEW"; do
  run_verify "$wf" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" accept refuse
  red "$(basename "$wf"): cosign accepting it fails" "$RC"
  run_verify "$wf" release "refs/tags/$TAG" "$RELEASE_SAN" "refs/tags/$TAG" refuse accept
  red "$(basename "$wf"): slsa-verifier accepting it fails" "$RC"
done

echo "== a run started by hand"
run_meta "$OLD" workflow_dispatch refs/heads/try-something
green "the old step let it start from a feature branch (the finding)" "$RC"
run_meta "$NEW" workflow_dispatch refs/heads/try-something
red "the template refuses a feature branch" "$RC"
has "  and says where to start it" "$OUT" "a release is signed only from refs/heads/main"
run_meta "$NEW" workflow_dispatch refs/heads/main
green "the template starts from main" "$RC"
run_meta "$NEW" release "refs/tags/$TAG"
green "a release run is not affected" "$RC"
same "  and asks GitHub nothing" "" "$CALLED"
SIGNED="$NAME.tar.gz $NAME.tar.gz.sigstore.json $NAME.intoto.jsonl"
run_meta "$OLD" workflow_dispatch refs/heads/main "$SIGNED"
green "the old step let a run by hand re-sign a release that has its files (the finding)" "$RC"
run_meta "$NEW" workflow_dispatch refs/heads/main "$SIGNED"
red "the template refuses to replace a release's signature" "$RC"
has "  and says how to replace it on purpose" "$OUT" "Delete the three files first"
run_meta "$NEW" workflow_dispatch refs/heads/main "notes.txt"
green "a release with other files but no signature is signed" "$RC"
run_meta "$NEW" workflow_dispatch refs/heads/main fail
red "a release that cannot be read is not signed blind" "$RC"
MAIN_SAN="https://github.com/$REPO/.github/workflows/release-assets.yml@refs/heads/main"
run_verify "$NEW" workflow_dispatch refs/heads/main "$MAIN_SAN" refs/heads/main refuse refuse
green "a run from main verifies its own files" "$RC"
has "  against main" "$CALLED" "--source-branch main"
has "  with this file on main as the identity" "$CALLED" "--certificate-identity $MAIN_SAN "
# Past the guard (a copy without it), the verify step still holds the line.
BR_SAN="https://github.com/$REPO/.github/workflows/release-assets.yml@refs/heads/try-something"
run_verify "$OLD" workflow_dispatch refs/heads/try-something "$BR_SAN" refs/heads/try-something refuse refuse
green "the old verify step accepted provenance from a feature branch (the finding)" "$RC"
run_verify "$NEW" workflow_dispatch refs/heads/try-something "$BR_SAN" refs/heads/try-something refuse refuse
red "the template's verify step refuses provenance that does not name main" "$RC"

echo "== the signing job checks the same identity, and nothing in the file is looser"
SIGN="$(step "$NEW" "Sign it, keyless")"
# The literal line, read with the shell's variables unexpanded.
# shellcheck disable=SC2016
has "the signing job verifies with the exact identity" "$SIGN" '--certificate-identity "https://github.com/${GITHUB_REPOSITORY}/.github/workflows/release-assets.yml@${GITHUB_REF}"'
hasnt "no identity-regexp anywhere in the template, comments included" "$(cat "$NEW")" "identity-regexp"
same "the repository's own copy is the template" "$(git hash-object "$NEW")" "$(git hash-object .github/workflows/release-assets.yml)"

if [ "${LIVE:-}" = 1 ]; then
  echo "== live: the real tools on a real release"
  : "${LIVE_DIR:?}" "${LIVE_REPO:?}" "${LIVE_TAG:?}"
  d="$WORK/live"; mkdir -p "$d/out"; cp "$LIVE_DIR"/* "$d/out/"
  step "$NEW" "$VERIFY" > "$d/step.sh"
  live() {  # live <what it shows, for the reader> [env...]
    shift
    RC=0
    OUT="$(cd "$d" && rm -f out/changed.tar.gz && env "$@" GITHUB_REPOSITORY="$LIVE_REPO" GITHUB_REF="refs/tags/$LIVE_TAG" \
           TAG="$LIVE_TAG" EVENT=release bash --noprofile --norc -eo pipefail "$d/step.sh" 2>&1)" || RC=$?
  }
  live "as is" HOME="$HOME"
  green "the real tools verify it and refuse the changed copy for being changed" "$RC"
  has "  cosign's words are the ones the step waits for" "$OUT" "cosign refused the changed archive"
  has "  slsa-verifier's too" "$OUT" "slsa-verifier refused the changed archive"
  live "no network" HOME="$d" HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9
  red "with Sigstore unreachable the step is not green" "$RC"
fi

echo
echo "release-assets: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
