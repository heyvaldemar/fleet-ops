#!/bin/bash
# Every rule in fleet-conformance.py, shown a real violation.
#
# WHY. A check that has never failed is not known to work. This repository has
# been bitten by that shape twice: a leak detector that had been installed for
# days and passed a live webhook when it was finally fed one, and a symmetry
# check of my own that was satisfied by seven files it should have rejected.
# So each rule below gets a repository broken in exactly its way, and the run
# fails if the rule stays quiet.
#
#   ./tests/test-conformance.sh [path-to-a-conforming-repo]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/fleet-conformance.py"
SRC="${1:-$ROOT/../nextcloud-traefik-letsencrypt-docker-compose}"
[ -d "$SRC" ] || { echo "error: no reference repository at $SRC" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0

# Runs the checker over a lone repository and prints its findings.
run_on() { FLEET_LOCAL_DIR="$1" python3 "$CHECKER" 2>&1; }

# fresh copy of the reference repository under a compose-template name
fixture() {
  local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/case-docker-compose"
  cp -R "$SRC/." "$d/case-docker-compose/" 2>/dev/null
  # A conforming repository has CI run each restore script it ships. The
  # reference does not yet, so the fixture carries a test that does; the
  # restore cases below take it away again.
  local sc; mkdir -p "$d/case-docker-compose/tests"
  for sc in "$d"/case-docker-compose/*restore*.sh; do
    [ -e "$sc" ] && printf './%s backup.gz\n' "$(basename "$sc")" >> "$d/case-docker-compose/tests/zz-restore-run.sh"
  done
  # Tagged as the real repository is, so every case reports only the rule it
  # is breaking. Untagged, all of them would also report every changelog
  # version as unreleased and the output would stop being readable.
  local v
  for v in $(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$d/case-docker-compose/CHANGELOG.md" 2>/dev/null | tr -d '#[] '); do
    git -C "$d/case-docker-compose" tag "v$v" >/dev/null 2>&1
  done
  printf '%s' "$d/case-docker-compose"
}

expect() {           # expect <name> <dir-of-fixture-parent> <substring>
  local name="$1" parent="$2" want="$3" out
  out="$(run_on "$parent")"
  if printf '%s' "$out" | grep -qF -- "$want"; then
    echo "  PASS: $name"; PASSED=$((PASSED+1))
  else
    echo "  FAIL: $name — expected a finding containing:"
    echo "        $want"
    echo "        got:"; printf '%s\n' "$out" | sed 's/^/        /' | head -12
    FAILED=$((FAILED+1))
  fi
}

expect_clean() {     # the unmodified copy must produce nothing
  local parent="$1" out
  out="$(run_on "$parent")"
  if printf '%s' "$out" | grep -q 'Every repository meets the standard'; then
    echo "  PASS: an untouched copy is reported as conforming"; PASSED=$((PASSED+1))
  else
    echo "  FAIL: an untouched copy was reported as broken:"
    printf '%s\n' "$out" | sed 's/^/        /' | head -14
    FAILED=$((FAILED+1))
  fi
}

echo "=== fleet conformance: does every rule fire? ==="
echo "reference: $SRC"
echo

# The control. If this fails, every result below is meaningless.
# EVERY version the changelog claims, because the rule reads every section.
# The reference is cloned shallow and arrives with no tags at all, so a control
# carrying only the newest one fails a rule that is working correctly.
tag_all() {          # tag_all <repo-dir>: one tag per version in its changelog
  local d="$1" v
  for v in $(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$d/CHANGELOG.md" | tr -d '#[] '); do
    git -C "$d" tag "v$v" >/dev/null 2>&1
  done
}
d="$(fixture control)"; tag_all "$d"
expect_clean "$WORK/control"

d="$(fixture pins)";      sed -i.bak 's/^x-images:/x-imagez:/' "$d"/*.yml && rm -f "$d"/*.bak
expect "a missing x-images block is caught" "$WORK/pins" "no x-images block"

d="$(fixture digest)";    sed -i.bak 's/@sha256:[0-9a-f]*//g' "$d"/*.yml && rm -f "$d"/*.bak
expect "pins with no digest are caught" "$WORK/digest" "carries no digest pin"

d="$(fixture tmo-gone)";  sed -i.bak '/respondingTimeouts.idleTimeout=/d' "$d"/*.yml && rm -f "$d"/*.bak
expect "a Traefik idle timeout with no variable is caught" "$WORK/tmo-gone" "idleTimeout on the HTTPS entry point"

d="$(fixture tmo-fixed)"
# shellcheck disable=SC2016 # the ${...} is the literal text being replaced
sed -i.bak 's/readTimeout=${TRAEFIK_READ_TIMEOUT:-60s}/readTimeout=60s/' "$d"/*.yml && rm -f "$d"/*.bak
expect "a Traefik read timeout written as a literal is caught" "$WORK/tmo-fixed" "readTimeout on the HTTPS entry point"

d="$(fixture example-stale)"
# the example's default is the version the pin had one release ago
sed -i.bak -E 's/^(#? *NEXTCLOUD_IMAGE_VERSION=).*/\10.0.1/' "$d/.env.example" && rm -f "$d/.env.example.bak"
expect "an .env.example default older than the pin is caught" "$WORK/example-stale" ".env.example names 0.0.1 for NEXTCLOUD_IMAGE_VERSION"

d="$(fixture nonewpriv)"; sed -i.bak 's/no-new-privileges:true/keep-privileges:true/' "$d"/*.yml && rm -f "$d"/*.bak
expect "a service without no-new-privileges is caught" "$WORK/nonewpriv" "no security_opt no-new-privileges"

d="$(fixture limits)";    sed -i.bak 's/^          memory: /          memoree: /' "$d"/*.yml && sed -i.bak2 's/^        limits:/        limitz:/' "$d"/*.yml && rm -f "$d"/*.bak "$d"/*.bak2
expect "a service without resource limits is caught" "$WORK/limits" "no resource limits"

d="$(fixture grace)";     sed -i.bak '/stop_grace_period/d' "$d"/*.yml && rm -f "$d"/*.bak
expect "a database without stop_grace_period is caught" "$WORK/grace" "no stop_grace_period"

d="$(fixture atomic)";    sed -i.bak 's/\.partial//g' "$d"/*.yml && rm -f "$d"/*.bak
expect "a backup written straight to its final name is caught" "$WORK/atomic" "writes straight to the final name"

d="$(fixture cond)"
# shellcheck disable=SC2016  # $$DATA_FILE is literal in a compose file, not a shell expansion
sed -i.bak 's|mv "\$\$DATA_FILE\.partial" "\$\$DATA_FILE";|[ -f "$$DATA_FILE" ] \&\& mv "$$DATA_FILE.partial" "$$DATA_FILE";|' "$d"/*.yml && rm -f "$d"/*.bak
expect "a success condition testing the pre-rename name is caught" "$WORK/cond" "success condition tests the final name"

# The read-back is what turns an exit code into a statement about the file.
# Removed here, the loop promotes whatever tar left behind - which is how a
# truncated archive gets logged as OK and older copies pruned around it.
d="$(fixture readback)"
# shellcheck disable=SC2016  # as above: the $$ belongs to the compose file
sed -i.bak 's| && tar -tzf "\$\$DATA_FILE\.partial" > /dev/null 2>&1||' "$d"/*.yml && rm -f "$d"/*.bak
expect "a tar archive renamed without being read back is caught" "$WORK/readback" "never read back before it is called a backup"

d="$(fixture license)";   rm -f "$d/LICENSE"
expect "a missing LICENSE is caught" "$WORK/license" "missing LICENSE"

d="$(fixture envex)";     rm -f "$d/.env.example"
expect "a missing .env.example is caught" "$WORK/envex" "missing .env.example"

d="$(fixture gitignore)"; sed -i.bak 's/^\.env$/dot-env/' "$d/.gitignore" && rm -f "$d"/*.bak
expect "a .gitignore that does not exclude .env is caught" "$WORK/gitignore" "does not exclude .env"

d="$(fixture workflow)";  rm -f "$d/.github/workflows/deployment-verification.yml"
expect "a missing workflow is caught" "$WORK/workflow" "no Deployment Verification workflow"

d="$(fixture trivy)";     sed -i.bak 's/[Tt]rivy/scanner/g' "$d/.github/workflows/deployment-verification.yml" && rm -f "$d/.github/workflows"/*.bak
expect "a workflow that scans nothing is caught" "$WORK/trivy" "does not scan an image with Trivy"

d="$(fixture boot)";      sed -i.bak 's/docker compose/docker komposz/g' "$d/.github/workflows/deployment-verification.yml" && rm -f "$d/.github/workflows"/*.bak
expect "a workflow that never starts the stack is caught" "$WORK/boot" "does not actually start the stack"

d="$(fixture tag)"
# shellcheck disable=SC2046  # splitting is the point: every tag becomes an argument
( cd "$d" && git tag -d $(git tag) >/dev/null 2>&1 )   # every tag removed
expect "a CHANGELOG version with no matching tag is caught" "$WORK/tag" "no tag"

# EVERY SECTION, NOT ONLY THE NEWEST. self-host-repo-hardening-runbook
# announced 1.3.0, 1.3.1 and 1.3.2 and carried none of those tags. A rule that
# reads the top section alone passes the moment somebody tags the latest and
# leaves the ones behind it untagged.
d="$(fixture oldtag)"
oldest="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$d/CHANGELOG.md" | tr -d '#[] ' | tail -1)"
git -C "$d" tag -d "v$oldest" >/dev/null 2>&1
expect "an older CHANGELOG version left untagged is caught" "$WORK/oldtag" "$oldest"

# A REPOSITORY WITH NO COMPOSE FILE STILL MAKES CLAIMS. The runbook above is a
# documentation repository: the rule that would have caught it sat behind a
# compose file it does not have, so three announced releases were never
# questioned.
d="$WORK/nocompose/docs-repo"; rm -rf "$WORK/nocompose"; mkdir -p "$d"
printf '# Changelog\n\n## [Unreleased]\n\n## [9.9.9] - 2026-09-22\n\n### Added\n\n- a release nobody tagged\n' > "$d/CHANGELOG.md"
printf '# A runbook\n' > "$d/README.md"
git -C "$d" init -q .
git -C "$d" add -A
git -C "$d" -c user.name=t -c user.email=t@t commit -qm init
expect "a documentation repository's untagged release is caught too" "$WORK/nocompose" "9.9.9"



# A declared exemption must be honoured AND reported - a door that opens
# silently is just a hole.
d="$(fixture exempt)"
sed -i.bak 's|^        limits:|        limitz:|' "$d"/*.yml
sed -i.bak2 's|^  redis:|  redis:\n    # conformance: allow-no-limits - a fixture, not a real exemption|' "$d"/*.yml
rm -f "$d"/*.bak "$d"/*.bak2
expect "a declared exemption is reported, not counted as a failure" "$WORK/exempt" "Declared exemptions"

d="$(fixture undeclared)"; sed -i.bak 's|^        limits:|        limitz:|' "$d"/*.yml && rm -f "$d"/*.bak
expect "the same gap without a declaration is still a failure" "$WORK/undeclared" "no resource limits"

# The loop is not always in the compose file. zammad keeps it in
# scripts/backup.sh, and a check that only read the compose reported that
# repository as conforming while it still wrote dumps straight to their final
# name - the exact defect the rule exists to catch, missed because of where
# the code lived rather than what it did.
d="$(fixture scriptloop)"
sed -i.bak 's/\.partial//g' "$d"/*.yml && rm -f "$d"/*.bak
mkdir -p "$d/scripts"
cat > "$d/scripts/backup.sh" <<'LOOP'
#!/bin/bash
DB_FILE="/backups/app.gz"
pg_dump -U u d | gzip > "${DB_FILE}"
LOOP
expect "a backup loop in a shipped script is checked too" "$WORK/scriptloop" "writes straight to the final name"

d="$(fixture notcompose)"; rm -f "$d"/*.yml
expect "a repository with no compose file is set aside, not failed" "$WORK/notcompose" "Not compose templates"

# A write grant at the top of a workflow file, where it applies to every job in
# it including ones added later. Every repository in the fleet carried this in
# dependabot-automerge.yml until 2026-09-14, and OpenSSF Scorecard scored it
# Token-Permissions 0/10 while the profile advertised "per-job permissions".
d="$(fixture toplevel-write)"
mkdir -p "$d/.github/workflows"
printf 'name: T\non:\n  workflow_run:\n    workflows: ["X"]\n    types: [completed]\n\npermissions:\n  contents: write\n  pull-requests: write\n\njobs:\n  merge:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' > "$d/.github/workflows/toplevel-write.yml"
expect "a top-level write grant is a finding" "$(dirname "$d")" "grants contents, pull-requests at the top of the file"

# And the same file with the grant where it belongs must be silent. The copy
# inherits the reference repository's own workflows, so the one this rule was
# written for is put right here too — a negative case that depends on some
# other repository being clean proves nothing about the rule.
d="$(fixture jobscoped-write)"
mkdir -p "$d/.github/workflows"
python3 - "$d/.github/workflows/dependabot-automerge.yml" <<'FIX' 2>/dev/null || true
import io, sys, os
p = sys.argv[1]
if os.path.isfile(p):
    s = io.open(p, encoding="utf-8").read()
    s = s.replace("permissions:\n  contents: write\n  pull-requests: write\n", "permissions:\n  contents: read\n", 1)
    s = s.replace("jobs:\n  merge:\n", "jobs:\n  merge:\n    permissions:\n      contents: write\n      pull-requests: write\n", 1)
    io.open(p, "w", encoding="utf-8").write(s)
FIX
printf 'name: T\non:\n  workflow_run:\n    workflows: ["X"]\n    types: [completed]\n\npermissions:\n  contents: read\n\njobs:\n  merge:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: write\n      pull-requests: write\n    steps:\n      - run: "true"\n' > "$d/.github/workflows/jobscoped-write.yml"
expect_clean "$(dirname "$d")"

# .ENV.EXAMPLE IS THE FILE PEOPLE COPY, AND NOTHING CHECKED THAT IT IS ENOUGH.
# wordpress referenced the apex domain from its www-redirect router and never
# named it in .env.example: the rule rendered as Host(``), which Traefik
# accepts, gives a load balancer, and then drops with one line at debug level.
#
# The fixtures below are appended with quoted here-documents: the ${...} in
# them are the thing under test, not expansions, and a quoted here-document is
# the one way to write that which both the shell and the linter read as text.
compose_of() {       # compose_of <repo-dir>: its first compose file
  local f
  for f in "$1"/*compose*.yml; do printf '%s' "$f"; return; done
}

d="$(fixture envmissing)"; tag_all "$d"
cat >> "$(compose_of "$d")" <<'YML'

      NEW_REQUIRED_THING: ${A_VARIABLE_NOBODY_DOCUMENTED}
YML
expect "a required variable missing from .env.example is caught" "$WORK/envmissing" "A_VARIABLE_NOBODY_DOCUMENTED"

# A COMMENTED LINE IS NOT A DECLARATION. It leaves the value unset, which is
# the whole defect; the optional tunables are commented out in these files on
# purpose and must not be mistaken for coverage.
d="$(fixture envcommented)"; tag_all "$d"
cat >> "$(compose_of "$d")" <<'YML'

      NEW_REQUIRED_THING: ${A_COMMENTED_VARIABLE}
YML
cat >> "$d/.env.example" <<'ENV'

# A_COMMENTED_VARIABLE=something
ENV
expect "a variable only commented out in .env.example is caught" "$WORK/envcommented" "A_COMMENTED_VARIABLE"

# AND THE THREE WAYS IT MUST STAY QUIET. A default, a declaration, and a
# mention inside a comment - jira names a variable only in a sentence about a
# redirect, and the first version of this scan reported that as a defect.
d="$(fixture envquiet)"; tag_all "$d"
cat >> "$(compose_of "$d")" <<'YML'

      HAS_A_DEFAULT: ${THIS_ONE_HAS_A_DEFAULT:-fine}
      IS_DECLARED: ${THIS_ONE_IS_DECLARED}
      # a comment mentioning ${THIS_ONE_IS_ONLY_A_COMMENT}
YML
cat >> "$d/.env.example" <<'ENV'

THIS_ONE_IS_DECLARED=yes
ENV
expect_clean "$WORK/envquiet"

# NESTED SUBSTITUTION. ${A:-${B}} has a default at the outer level and none at
# the inner one, and the inner is the one that renders empty.
d="$(fixture envnested)"; tag_all "$d"
cat >> "$(compose_of "$d")" <<'YML'

      NESTED: ${OUTER_HAS_DEFAULT:-${INNER_HAS_NONE}}
YML
expect "a variable required only inside a nested default is caught" "$WORK/envnested" "INNER_HAS_NONE"


echo

# THE FRESHNESS JOB MAY LIVE IN ITS OWN WORKFLOW. It was moved so the badge a
# reader sees says whether the stack boots rather than whether a pin is one
# version behind. Moved by the real splitter, the reference template must still
# conform; with the job gone from both files it must not.
d="$(fixture freshsplit)"; tag_all "$d"
python3 "$ROOT/scripts/split-freshness.py" "$d" >/dev/null
expect_clean "$WORK/freshsplit"

d="$(fixture freshgone)"; tag_all "$d"
python3 "$ROOT/scripts/split-freshness.py" "$d" >/dev/null
rm -f "$d/.github/workflows/freshness.yml"
expect "a template with no freshness job anywhere is caught" "$WORK/freshgone" "does not check the pins for drift"


# A ONE-SHOT ROLLOUT IS A POINT IN TIME. Each rule below was established by a
# wave that fixed everything it looked at once and never looked again.
#
# The daily schedule: three templates received their CI after the wave that
# made it daily had run, and stayed weekly under a policy that says daily.
d="$(fixture weeklycron)"; tag_all "$d"
sed -i.bak 's/- cron: "0 6 \* \* \*"/- cron: "0 6 * * 1"/' "$d/.github/workflows/"*.yml && rm -f "$d/.github/workflows/"*.bak
expect "a weekly verification schedule is caught" "$WORK/weeklycron" "which is not daily"

# A Trivy scan that cannot finish, hidden - in a template...
d="$(fixture trivyhidden)"; tag_all "$d"
python3 - "$d/.github/workflows/deployment-verification.yml" <<'PY'
import io, re, sys
p = sys.argv[1]; s = io.open(p).read()
s = re.sub(r"(?m)^(  scan-trivy:\n(?:    [^\n]*\n)*?    runs-on: [^\n]*\n)", r"\1    continue-on-error: true\n", s, count=1)
io.open(p, "w").write(s)
PY
expect "a hidden Trivy failure in a template is caught" "$WORK/trivyhidden" "runs Trivy with continue-on-error"

# ...and in a repository that is NOT a template, which is where the wave that
# fixed sixty templates never looked. The one pipeline that publishes an image
# kept the flag.
nt="$WORK/nontemplate/publish-docker"; mkdir -p "$nt/.github/workflows"
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n' > "$nt/CHANGELOG.md"
cat > "$nt/.github/workflows/publish.yml" <<'YML'
name: Publish
on: push
permissions:
  contents: read
jobs:
  scan-trivy:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000
YML
git -C "$nt" init -q && git -C "$nt" -c user.name=t -c user.email=t@t add -A && git -C "$nt" -c user.name=t -c user.email=t@t commit -qm init && git -C "$nt" tag v1.0.0
expect "a hidden Trivy failure outside the templates is caught too" "$WORK/nontemplate" "runs Trivy with continue-on-error"

# And a Trivy step, rather than a whole job, carrying the flag.
nt2="$WORK/nontemplate2/publish-docker"; mkdir -p "$nt2/.github/workflows"
cp "$nt/CHANGELOG.md" "$nt2/"
cat > "$nt2/.github/workflows/publish.yml" <<'YML'
name: Publish
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: echo build
      - name: Trivy scan
        uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000
        continue-on-error: true
YML
git -C "$nt2" init -q && git -C "$nt2" -c user.name=t -c user.email=t@t add -A && git -C "$nt2" -c user.name=t -c user.email=t@t commit -qm init && git -C "$nt2" tag v1.0.0
expect "a Trivy step with the flag is caught" "$WORK/nontemplate2" "a Trivy step in job build carries continue-on-error"


# EVERY SERVICE SAYS WHAT HAPPENS WHEN IT STOPS. Without a policy it stays down
# after a reboot while the rest of the stack returns: Nextcloud's cron sidecar
# did exactly that, and the UI never said background jobs had stopped.
d="$(fixture norestart)"; tag_all "$d"
python3 - "$(compose_of "$d")" <<'PY'
import io, re, sys
p = sys.argv[1]; s = io.open(p).read()
s, n = re.subn(r"(?m)^    restart: [^\n]*\n", "", s, count=1)
assert n == 1
io.open(p, "w").write(s)
PY
expect "a service with no restart policy is caught" "$WORK/norestart" "has no restart policy"

# A one-shot service that says so stays quiet.
d="$(fixture oneshot)"; tag_all "$d"
python3 - "$(compose_of "$d")" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p).read()
s = s.replace("\nservices:\n", "\nservices:\n  one-shot-init:\n    image: busybox:1.37\n    command: [\"true\"]\n"
              "    security_opt:\n      - no-new-privileges:true\n"
              "    deploy:\n      resources:\n        limits:\n          memory: 16m\n"
              "    restart: \"no\"\n\n", 1)
io.open(p, "w").write(s)
PY
expect_clean "$WORK/oneshot"

# strip_runs <repo-dir>: every line that runs a restore script goes, the test
# file itself stays - the reference runs its own scripts since it was converted,
# and a missing test would break a different rule than the one under test.
# The workflows are stripped too: since 2026-09-24 the clean-machine drill
# names the restore scripts in dr-drill.yml, and a fixture that left that in
# had nothing unrun (Verify was red for a day on exactly that).
strip_runs() {
  local f
  rm -f "$1/tests/zz-restore-run.sh"
  for f in "$1"/tests/*.sh "$1"/.github/workflows/*.yml; do
    [ -e "$f" ] || continue
    sed -i.bak -E '/^[[:space:]]*[^#[:space:]].*\.\/[A-Za-z0-9_.-]*restore[A-Za-z0-9_.-]*\.sh/d' "$f" && rm -f "$f.bak"
  done
}

# A compose file that prunes, and no test that exercises the prune, is caught.
# Thirteen templates were in that state on 2026-09-25; Zammad had never asked.
d="$(fixture pruneuntested)"; tag_all "$d"
for f in "$d"/tests/*.sh; do
  [ -e "$f" ] || continue
  sed -i.bak -E '/[Pp]run/d' "$f" && rm -f "$f.bak"
done
expect "a prune nothing tests is caught" "$WORK/pruneuntested" "no test under tests/ exercises the prune"
# A comment that says "prune" is not a test that does.
d="$(fixture prunecomment)"; tag_all "$d"
for f in "$d"/tests/*.sh; do
  [ -e "$f" ] || continue
  sed -i.bak -E 's/^([^#]*[Pp]run)/# \1/' "$f" && rm -f "$f.bak"
done
expect "a prune mentioned only in a comment is still caught" "$WORK/prunecomment" "no test under tests/ exercises the prune"

# A restore script nothing runs is caught.
d="$(fixture restoreunrun)"; tag_all "$d"; strip_runs "$d"
expect "a restore script CI never runs is caught" "$WORK/restoreunrun" "CI never runs"

# Naming it is not running it: a comment and an echo do not count.
d="$(fixture restoremention)"; tag_all "$d"
cp "$d/tests/zz-restore-run.sh" "$WORK/runs.txt"; strip_runs "$d"
sed -e 's/^/# /' "$WORK/runs.txt" > "$d/tests/zz-mention.sh"
sed -e 's/^/echo "restoring with /; s/$/"/' "$WORK/runs.txt" >> "$d/tests/zz-mention.sh"
expect "a restore script only mentioned in a comment or echo is caught" "$WORK/restoremention" "CI never runs"

# Run through a path, as "$ROOT/<script>", is run.
d="$(fixture restorebypath)"; tag_all "$d"; strip_runs "$d"
for sc in "$d"/*restore*.sh; do
  # The dollar signs are the point: the fixture must carry "$ROOT/..." literally.
  # shellcheck disable=SC2016
  [ -e "$sc" ] && printf 'S="$ROOT/%s"\n"$S" backup.gz\n' "$(basename "$sc")" >> "$d/tests/zz-by-path.sh"
done
expect_clean "$WORK/restorebypath"

# On the list and still unrun: reported as declared, not as a failure.
d="$(fixture restorelisted)"; tag_all "$d"; strip_runs "$d"
out="$(FLEET_RESTORE_NOT_YET_RUN=case-docker-compose FLEET_LOCAL_DIR="$WORK/restorelisted" python3 "$CHECKER" 2>&1)"
if printf '%s' "$out" | grep -q "Every repository meets the standard" && printf '%s' "$out" | grep -q "restore scripts CI does not run yet"; then
  echo "  PASS: a listed repository is reported as declared, not failed"; PASSED=$((PASSED+1))
else
  echo "  FAIL: a listed repository was not reported as declared:"; printf '%s\n' "$out" | sed 's/^/        /' | head -8; FAILED=$((FAILED+1))
fi

# On the list and now running them: the list has to shrink.
d="$(fixture restoreshrink)"; tag_all "$d"
out="$(FLEET_RESTORE_NOT_YET_RUN=case-docker-compose FLEET_LOCAL_DIR="$WORK/restoreshrink" python3 "$CHECKER" 2>&1)"
if printf '%s' "$out" | grep -q "take it off RESTORE_NOT_YET_RUN"; then
  echo "  PASS: a listed repository that now runs its scripts must leave the list"; PASSED=$((PASSED+1))
else
  echo "  FAIL: a listed repository that runs its scripts was not told to leave the list:"; printf '%s\n' "$out" | sed 's/^/        /' | head -8; FAILED=$((FAILED+1))
fi

echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
