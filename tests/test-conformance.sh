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
  for sc in "$d"/*restore*.sh; do
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

# The gate that decides a repository has a backup loop at all knew a list of
# dump tools and `tar -<flags>c`. Ten templates write `tar -C /data ... -zcpf`
# beside a dump the list did not name, and every rule under the gate skipped
# them. Here the dump tool is renamed out of the list and the archive written
# that way, read-back removed: the rule must still see the loop.
d="$(fixture tarc)"
# shellcheck disable=SC2016  # as above: the $$ belongs to the compose file
sed -i.bak -e 's|pg_dump |pg_backup |' -e 's|tar -zcpf "\$\$DATA_FILE\.partial"|tar -C / -zcpf "$$DATA_FILE.partial"|' \
  -e 's| \&\& tar -tzf "\$\$DATA_FILE\.partial" > /dev/null 2>\&1||' "$d"/*.yml && rm -f "$d"/*.bak
expect "an archive written with tar -C first is still read as a backup loop" "$WORK/tarc" "never read back before it is called a backup"

d="$(fixture license)";   rm -f "$d/LICENSE"
expect "a missing LICENSE is caught" "$WORK/license" "missing LICENSE"

d="$(fixture envex)";     rm -f "$d/.env.example"
expect "a missing .env.example is caught" "$WORK/envex" "missing .env.example"

d="$(fixture gitignore)"; sed -i.bak 's/^\.env$/dot-env/' "$d/.gitignore" && rm -f "$d"/*.bak
expect "a .gitignore that does not exclude .env is caught" "$WORK/gitignore" "does not exclude .env"

d="$(fixture workflow)";  rm -f "$d/.github/workflows/deployment-verification.yml"
expect "a missing workflow is caught" "$WORK/workflow" "no Deployment Verification workflow"

d="$(fixture anonvol)"
python3 - "$d/.github/workflows/deployment-verification.yml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"      - name: Every volume an image declares is one this stack names\n.*?(?=\n      - name:)", "", s, count=1, flags=re.S))
PY
expect "a deploy job that never looks for anonymous volumes is caught" "$WORK/anonvol" "never checks its containers for anonymous volumes"

d="$(fixture updater)";   rm -f "$d/update.sh"
expect "a missing update.sh is caught" "$WORK/updater" "no update.sh"

d="$(fixture unreadable)"
python3 - "$d/update.sh" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"\n# docker compose reads \.env last.*?\nfi\n\n", "\n", s, count=1, flags=re.S))
PY
expect "an update.sh that reads past an unreadable .env is caught" "$WORK/unreadable" "does not stop on an env file it cannot read"

d="$(fixture silentexit)"; sed -i.bak "s/| tr '\\\\n' ' ' || true)\"/| tr '\\\\n' ' ')\"/" "$d/update.sh" && rm -f "$d"/*.bak
expect "an update.sh that dies silently on no required variable is caught" "$WORK/silentexit" "ends with no message when no compose file requires a variable"

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

# BEFORE THE FIRST RELEASE. A dated declaration in the changelog is reported, not
# failed, until its day; after it the gap fails again; without one it always fails.
prerelease() {       # prerelease <dir> <declaration line or empty>
  local d="$WORK/$1/image-docker"; rm -rf "${WORK:?}/${1:?}"; mkdir -p "$d"
  printf '# Changelog\n\n## [Unreleased]\n\n%s\n\n### Added\n\n- an image\n' "$2" > "$d/CHANGELOG.md"
  printf '# An image\n' > "$d/README.md"
  git -C "$d" init -q .
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init
}
prerelease prefuture '<!-- conformance: first release not before 2099-01-01 - a fixture, one image a week -->'
expect "a declared first release is reported until its date" "$WORK/prefuture" "first release not before 2099-01-01 - a fixture"
expect_clean "$WORK/prefuture"
prerelease prepast '<!-- conformance: first release not before 2000-01-01 - a fixture -->'
expect "a declared first release that did not happen fails after its date" "$WORK/prepast" "the first release it declared for 2000-01-01 has not happened"
prerelease prenone ''
expect "no released version and no declaration is still a failure" "$WORK/prenone" "CHANGELOG has no released version at the top"



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
printf 'name: T\non:\n  workflow_run:\n    workflows: ["T"]\n    types: [completed]\n\npermissions:\n  contents: read\n\njobs:\n  merge:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: write\n      pull-requests: write\n    steps:\n      - run: "true"\n' > "$d/.github/workflows/jobscoped-write.yml"
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

# A pin check that calls any new index drift, including one pushed again over
# the same linux/amd64 build: the reference's comparison put back as it was.
d="$(fixture samebuild)"; tag_all "$d"
if python3 - "$d/.github/workflows/freshness.yml" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p).read()
t = s.replace(' && new_build "$ref" "$pinned_digest" "$current_digest"', "")
if t == s:
    sys.exit("the reference's pin check does not ask about the build, so there is nothing to take out")
io.open(p, "w").write(t)
PY
then
  expect "a pin check that calls a re-pushed index drift is caught" "$WORK/samebuild" "reports digest drift for any new index, including one pushed again over the same linux/amd64 build"
else
  echo "  FAIL: the same-build plant could not be made"; FAILED=$((FAILED+1))
fi


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

# A restore that copies a directory over the data root is caught; the same
# words in a comment are not.
d="$(fixture restorecpdot)"; tag_all "$d"
for sc in "$d"/*restore*.sh; do
  # shellcheck disable=SC2016
  [ -e "$sc" ] && printf '    cp -a /tmp/restore-keep/. "$ROOT"/\n' >> "$sc"
done
expect "a restore that copies a directory over the data root is caught" "$WORK/restorecpdot" "copies a directory over the data root"
d="$(fixture restorecpdotcomment)"; tag_all "$d"
for sc in "$d"/*restore*.sh; do
  [ -e "$sc" ] && printf '# it used to run cp -a /tmp/restore-keep/. /data/ here\n' >> "$sc"
done
expect_clean "$WORK/restorecpdotcomment"

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

# DEPENDABOT'S COOLDOWN STAYS ON. A dependabot.yml that turns the three-day
# cooldown down, or excludes dependencies from it, is caught; one that makes
# it longer is not.
dependabot_with() {  # dependabot_with <repo dir> <cooldown lines, already indented>
  mkdir -p "$1/.github"
  printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directory: "/"\n    schedule:\n      interval: weekly\n    cooldown:\n%s\n' "$2" > "$1/.github/dependabot.yml"
}
d="$(fixture cooldownzero)"; tag_all "$d"; dependabot_with "$d" "      default-days: 0"
expect "a cooldown turned off is caught" "$WORK/cooldownzero" "default-days: 0, below the 3-day cooldown"
d="$(fixture cooldownpatch)"; tag_all "$d"; dependabot_with "$d" "      default-days: 5
      semver-patch-days: 1"
expect "a cooldown shortened for patches is caught" "$WORK/cooldownpatch" "semver-patch-days: 1, below the 3-day cooldown"
d="$(fixture cooldownexclude)"; tag_all "$d"; dependabot_with "$d" "      default-days: 5
      exclude:
        - \"*\""
expect "dependencies excluded from the cooldown are caught" "$WORK/cooldownexclude" "excludes dependencies from the cooldown"
d="$(fixture cooldownlonger)"; tag_all "$d"; dependabot_with "$d" "      default-days: 7"
expect_clean "$WORK/cooldownlonger"

# A HEAP THE CONTAINER CANNOT HOLD: the limits rollout gave Confluence 2g under
# a 12G heap. Each case puts a heap setting into the first service's
# environment (postgres in the reference, limited to 1g); the rule must read
# the default out of ${VAR:-...}, read -Xmx out of *_JAVA_OPTS, leave a heap
# that fits alone, and leave MEMORY alone on an image that is not itzg's.
heap_in() {          # heap_in <repo-dir> < line: under the first environment:
  local f add; f="$(compose_of "$1")"; add="$(cat)"
  awk -v add="$add" '{ print } !done && /^    environment:$/ { print add; done = 1 }' "$f" > "$f.new" && mv "$f.new" "$f"
}
d="$(fixture heapunder)"; tag_all "$d"; heap_in "$d" <<'YML'
      JVM_MAXIMUM_MEMORY: ${CASE_JVM_MAXIMUM_MEMORY:-8G}
YML
expect "a container limit under its JVM heap is caught" "$WORK/heapunder" "memory limit 1g cannot hold the 8G JVM heap"
d="$(fixture heapxmx)"; tag_all "$d"; heap_in "$d" <<'YML'
      ES_JAVA_OPTS: -Xms2g -Xmx2g
YML
expect "an -Xmx in JAVA_OPTS above the limit is caught" "$WORK/heapxmx" "memory limit 1g cannot hold the 2g JVM heap"
d="$(fixture heapfits)"; tag_all "$d"; heap_in "$d" <<'YML'
      JVM_MAXIMUM_MEMORY: ${CASE_JVM_MAXIMUM_MEMORY:-512m}
YML
expect_clean "$WORK/heapfits"
d="$(fixture heapnotitzg)"; tag_all "$d"; heap_in "$d" <<'YML'
      MEMORY: 4G
YML
expect_clean "$WORK/heapnotitzg"

# NO SECRET ON A COMMAND LINE. Each case plants one shape the fleet carried
# until 2026-11-08 into a shipped script, a test or the compose file. The
# planted text is assembled from pieces ('-''p', 'P''ASSWORD'): written whole,
# this file would be the violation, since fleet-ops is under the same rule.
put() {             # put <repo-dir> <path> <line>: a script holding one line
  mkdir -p "$(dirname "$1/$2")"
  printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"
}
P='P''ASSWORD'
d="$(fixture argvdump)"; tag_all "$d"; put "$d" tools/dump.sh "mariadb-dump -u app -""p\"\$DB_$P\" appdb"
expect "a MariaDB client given its password as dash-p is caught" "$WORK/argvdump" "a MySQL/MariaDB client given its password as -p"
d="$(fixture argvlong)"; tag_all "$d"; put "$d" tools/ping.sh "mysqladmin ping --pass""word=\$DB_$P"
expect "a password given as a long password option is caught" "$WORK/argvlong" "a password given as --password"
d="$(fixture argvenv)"; tag_all "$d"; put "$d" restore.sh "docker exec -e MYSQL_P""WD=\"\$DB_PASS\" backups sh -c true"
expect "docker -e with MYSQL_PWD and its value (no PASS in the name) is caught" "$WORK/argvenv" "a secret handed to -e NAME=value"
d="$(fixture argvsudo)"; tag_all "$d"; put "$d" templates/user_data.sh.tpl "sudo PG$P=\$DB_$P psql -U app"
expect "an assignment of PGPASSWORD handed to sudo is caught" "$WORK/argvsudo" "a secret set through env/sudo NAME=value"
d="$(fixture argvsqlcmd)"; tag_all "$d"; put "$d" tools/q.sh "sqlcmd -S db -U sa -""P \"\$SA_$P\" -Q 'SELECT 1'"
expect "sqlcmd given its password as dash-P is caught" "$WORK/argvsqlcmd" "sqlcmd given its password as -P"
d="$(fixture argvbearer)"; tag_all "$d"; put "$d" init/init.sh "H=\"Author""ization: Bearer \${ADMIN_TOKEN}\""
expect "an Authorization header built from a variable is caught" "$WORK/argvbearer" "an Authorization header built from a variable"
d="$(fixture argvmc)"; tag_all "$d"; put "$d" tools/mc.sh "mc alias ""set s http://s3:9000 \"\$ROOT_USER\" \"\$ROOT_$P\""
expect "mc alias set with the secret key as an argument is caught" "$WORK/argvmc" "mc alias set given its secret key as an argument"
d="$(fixture argvsed)"; tag_all "$d"; put "$d" entrypoint.sh "s""ed \"s|%PW%|\${RCON_$P}|g\" in.cfg > out.cfg"
expect "a secret written through sed's arguments is caught" "$WORK/argvsed" "a secret written into a file through sed's arguments"
d="$(fixture argvcron)"; tag_all "$d"; put "$d" templates/cron.sh.tpl "echo \"0 2 * * * PG$P=\${db_password} pg_dump -U app\" >> \"\$CRON\""
expect "a secret in a crontab line is caught" "$WORK/argvcron" "a secret in a crontab line"
d="$(fixture argvtest)"; tag_all "$d"; put "$d" tests/e2e-x.sh "docker exec db mariadb -u app -""p\"\$DB_PASS\" -e 'select 1'"
expect "a test is held to it too, and says it is one" "$WORK/argvtest" "in a test, on the CI runner: tests/e2e-x.sh:2"
d="$(fixture argvrcon)"; tag_all "$d"; compose_file="$(compose_of "$d")"
# shellcheck disable=SC2016  # the ${...} belongs to the compose file
printf '  game:\n    image: alpine:3\n    command:\n      - ./srcds_run\n      - +rcon''_password\n      - "${GAME_RCON_%s:?set}"\n' "$P" > "$d/x-compose.part"
python3 - "$compose_file" "$d/x-compose.part" <<'PY'
import sys
c, part = sys.argv[1], open(sys.argv[2]).read()
s = open(c).read()
i = s.index("\nservices:\n") + len("\nservices:\n")
open(c, "w").write(s[:i] + part + s[i:])
PY
rm -f "$d/x-compose.part"
expect "a secret compose interpolates into a command is caught" "$WORK/argvrcon" "GAME_RCON_${P} interpolated by compose into the container's command"
expect "and the Source +rcon_password item with it" "$WORK/argvrcon" "a game server given a secret on its own command line"
# A name that says nothing: rathena's password test logged in with -e P="$2"
# (2026-11-08), which the name list could not see.
d="$(fixture argvshort)"; tag_all "$d"; put "$d" tests/e2e-login.sh "docker run --rm -e A=\"\$1\" -""e P=\"\$2\" python:3.13-alpine true"
expect "a short name with an expanded value is caught, in a test" "$WORK/argvshort" "in a test, on the CI runner: tests/e2e-login.sh:2 a value expanded into -e NAME=value"
d="$(fixture argvsubst)"; tag_all "$d"; put "$d" tools/run.sh "docker run --rm --""env=OPAQUE=\$(cat key.txt) app"
expect "a value from a command substitution through --env= is caught" "$WORK/argvsubst" "tools/run.sh:2 a value expanded into -e NAME=value"
# A README is run by whoever reads it. The jediacademy README handed its RCON
# password to docker as -e PW="$(grep ...)" until v1.3.0 (2026-11-08).
md_append() {       # md_append <repo-dir> <path> <fence-language> <line>
  mkdir -p "$(dirname "$1/$2")"
  local fence='``''`'
  printf '\nOpen a console:\n\n%s%s\n%s\n%s\n' "$fence" "$3" "$4" "$fence" >> "$1/$2"
}
d="$(fixture argvreadme)"; tag_all "$d"
md_append "$d" README.md bash "docker run --rm -it --network container:jka -""e PW=\"\$(grep ^JKA_SERVER_RCON_$P= .env | cut -d= -f2-)\" python:3-alpine"
expect "a README shell block handing PW to docker from a command substitution is caught" "$WORK/argvreadme" "in documentation, run by whoever reads it: README.md:"
expect "and named for what it is" "$WORK/argvreadme" "a value expanded into -e NAME=value, which puts it in docker's argv whatever the name"
d="$(fixture argvdocs)"; tag_all "$d"
md_append "$d" docs/backup.md sh "mariadb-dump -u app -""p\"\$DB_$P\" appdb > dump.sql"
expect "a docs/ sh block is read with the same patterns" "$WORK/argvdocs" "in documentation, run by whoever reads it: docs/backup.md:5 a MySQL/MariaDB client given its password as -p"
# What is NOT a finding: a name without a value, an assignment the shell keeps
# in the environment, a header built by printf, a *_FILE path, redis-server
# (it overwrites its own arguments as it starts, measured), and mkdir -p.
d="$(fixture argvfine)"; tag_all "$d"
put "$d" tools/fine.sh "docker exec -e MYSQL_P""WD backups mariadb -u app -e 'select 1'"
put "$d" tools/fine2.sh "MYSQL_P""WD=\"\$DB_$P\" mariadb-dump -u app appdb"
put "$d" tools/fine3.sh "printf 'header = \"Author""ization: Bearer %s\"\\n' \"\$TOKEN\" | curl -K - https://example.test"
put "$d" tools/fine4.sh "docker run -e DB_${P}_FILE=\"\$SECRET_PATH\" app"
put "$d" tools/fine5.sh "mkdir -p \"\$BACKUP_DIR\""
# -e NAME alone, the fix, takes the value from the caller's environment; a
# literal value is not expanded from anything; a value file is named by path.
put "$d" tests/fine6.sh "P=\"\$2\" docker run --rm -""e P -""e TZ=UTC -""e A_FILE=\"\$KEY_PATH\" python:3.13-alpine true"
# The same README command outside a shell fence: prose, and a yaml block.
# shellcheck disable=SC2016  # the $(...) is planted text, never expanded
printf '\nNever -%s PW="$(grep x .env)" in prose.\n\n```yaml\n-%s PW="$(grep x .env)"\n```\n' e e >> "$d/README.md"
md_append "$d" README.md bash "PW=\"\$(cat pw)\" docker run --rm -""e PW python:3-alpine"
compose_file="$(compose_of "$d")"
python3 - "$compose_file" <<'PY'
import sys
c = sys.argv[1]; s = open(c).read()
i = s.index("\nservices:\n") + len("\nservices:\n")
part = '  cache:\n    image: redis:7\n    command: ["redis-server", "--requirepass", "${CACHE_REDIS_P' + 'ASSWORD:?set}"]\n'
open(c, "w").write(s[:i] + part + s[i:])
PY
out="$(run_on "$WORK/argvfine")"
if printf '%s' "$out" | grep -qE 'secret|password|Authorization|interpolated|argv'; then
  echo "  FAIL: a name, an environment assignment, a printf header, a _FILE path, redis-server, mkdir -p, a literal -e value or a README line outside a shell fence was reported:"
  printf '%s\n' "$out" | grep -E 'secret|password|Authorization|interpolated|argv' | sed 's/^/        /' | head -6
  FAILED=$((FAILED+1))
else
  echo "  PASS: none of the shapes that keep a secret off the command line is reported"; PASSED=$((PASSED+1))
fi
# A REDIS HEALTH CHECK READS THE REPLY. redis-cli exits 0 on NOAUTH and
# WRONGPASS (redis 7.4.11, 2026-11-14), so a bare ping against requirepass is
# green with any password; and affine's check gave the password as -a, which
# compose interpolates into the check's arguments every interval.
redis_check() {     # redis_check <repo-dir> <test line>
  python3 - "$(compose_of "$1")" "$2" <<'PY'
import re, sys
c, line = sys.argv[1], sys.argv[2]
s = open(c).read()
s2, n = re.subn(r'(?m)^      test: \["CMD-SHELL", "redis-cli ping \| grep -q PONG"\]$', "      test: " + line, s)
assert n == 1, "the reference has no PONG-reading Redis check to replace"
open(c, "w").write(s2)
PY
}
d="$(fixture redisbare)"; tag_all "$d"; redis_check "$d" '["CMD", "redis-cli", "ping"]'
expect "a bare redis-cli ping against requirepass is caught" "$WORK/redisbare" "never reads the reply"
d="$(fixture redisdasha)"; tag_all "$d"; redis_check "$d" "[\"CMD\", \"redis-cli\", \"-a\", \"\$NEXTCLOUD_REDIS_$P\", \"ping\"]"
expect "a password compose interpolates into a health check is caught" "$WORK/redisdasha" "NEXTCLOUD_REDIS_${P} interpolated by compose into the container's health check"
expect "and redis-cli -a is named" "$WORK/redisdasha" "a Redis password given to redis-cli as -a"
# A name with KEY at its start is not a secret: keycloak passes KEYCLOAK_DB_NAME
# to pg_isready in its health check.
# shellcheck disable=SC2016  # the ${...} belongs to the compose file
d="$(fixture rediskeycloak)"; tag_all "$d"; redis_check "$d" '["CMD-SHELL", "redis-cli ping | grep -q PONG && test -n ${KEYCLOAK_DB_NAME:-db}"]'
expect_clean "$WORK/rediskeycloak"

# THE DOOR: a declared line is listed as an exemption, with its reason, and passes.
d="$(fixture argvallow)"; tag_all "$d"
allow_line='# conformance: allow-argv-secret - a fixture: the value is a public test constant'
put "$d" tools/allow.sh "$allow_line"$'\n'"mariadb -u app -""p\"\$PUBLIC_TEST_$P\" appdb"
out="$(run_on "$WORK/argvallow")"
if printf '%s' "$out" | grep -q 'Every repository meets the standard' && printf '%s' "$out" | grep -qF 'declared: a fixture: the value is a public test constant'; then
  echo "  PASS: a declared exemption passes and is listed with its reason"; PASSED=$((PASSED+1))
else
  echo "  FAIL: a declared exemption was not handled:"; printf '%s\n' "$out" | sed 's/^/        /' | head -8; FAILED=$((FAILED+1))
fi
# ...and above a command continued over several lines, where a comment cannot
# sit between the lines; one line further up it covers nothing.
d="$(fixture argvallowcont)"; tag_all "$d"
put "$d" tests/canary.sh "$allow_line"$'\n'"docker run --rm \\"$'\n'"  -""e CANARY=\"\$token\" \\"$'\n'"  alpine:3 true"
out="$(run_on "$WORK/argvallowcont")"
if printf '%s' "$out" | grep -q 'Every repository meets the standard' && printf '%s' "$out" | grep -qF 'tests/canary.sh:4 a value expanded into -e NAME=value'; then
  echo "  PASS: a declared exemption above a continued command covers its later lines"; PASSED=$((PASSED+1))
else
  echo "  FAIL: a declared exemption above a continued command was not honoured:"; printf '%s\n' "$out" | sed 's/^/        /' | head -8; FAILED=$((FAILED+1))
fi
d="$(fixture argvallowfar)"; tag_all "$d"
put "$d" tests/canary.sh "$allow_line"$'\n'"true"$'\n'"docker run --rm \\"$'\n'"  -""e CANARY=\"\$token\" alpine:3 true"
expect "a declared exemption two commands up covers nothing" "$WORK/argvallowfar" "in a test, on the CI runner: tests/canary.sh:5 a value expanded into -e NAME=value"

# A repository whose refusals go through a provisioner plants variants of one
# template, not manifests (kubernetes-coder-agent-workspaces, 2026-11-11). The
# plants rule is the same in that form, and each part of it is broken here.
echo "=== planted variants of a template ==="
# Written to a file first: bash 3.2 cannot parse a here-document with quotes
# in it inside a command substitution.
cat > "$WORK/variants-rule.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("conformance", sys.argv[1])
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
class R:
    def __init__(self, files, dirs):
        self.files, self.dirs = files, dirs
    def read(self, p):
        return self.files.get(p)
    def names_in(self, p):
        return self.dirs.get(p, [])
RUN = 'variants="$(awk -F"\\t" \'!/^#/ && NF {print $1}\' "$HERE/variants.tsv")"\n'
GOOD = ("# variant\texpect\trefused by\n"
        "none\tadmitted\tcontrol\n"
        "no-gvisor\tan agent pod runs on gVisor\tthe policy\n"
        "other-home\tmeasured\tnothing\n")
def repo(table=GOOD, run=RUN, tampered=("main.tf",)):
    files = {"tests/e2e/run.sh": run}
    if table is not None:
        files["tests/e2e/variants.tsv"] = table
    return R(files, {"tests/e2e/tampered": list(tampered)})
def check(name, got, want):
    print(("  PASS: " if got == want else "  FAIL: ") + name + ("" if got == want else " (got %r)" % (got,)))
def says(findings, words):
    return any(words in f for f in findings or [])
check("a table of template variants with a control and a refusal meets the plants rule", c.variants_rule(repo()), [])
check("no table is not this rule's business", c.variants_rule(repo(table=None)), None)
check("a table with no tampered template beside it is not this rule's business", c.variants_rule(repo(tampered=())), None)
check("variants without a control are refused",
      says(c.variants_rule(repo(GOOD.replace("none\tadmitted\tcontrol\n", ""))), "without a control"), True)
check("a table where nothing must be refused is refused",
      says(c.variants_rule(repo("none\tadmitted\tcontrol\nother-home\tmeasured\tnothing\n")), "no refusal is ever tried"), True)
check("a variant that does not say what it expects is named",
      says(c.variants_rule(repo(GOOD + "bare\n")), "'bare'"), True)
check("a table the e2e never reads is refused",
      says(c.variants_rule(repo(run="# variants.tsv is named in a comment only\ntrue\n")), "never reads"), True)
PY
out="$(python3 "$WORK/variants-rule.py" "$CHECKER")"
printf '%s\n' "$out"
ran="$(printf '%s\n' "$out" | awk '/^  (PASS|FAIL): /{n++} END{print n+0}')"
PASSED=$((PASSED + $(printf '%s\n' "$out" | awk '/^  PASS: /{n++} END{print n+0}')))
FAILED=$((FAILED + $(printf '%s\n' "$out" | awk '/^  FAIL: /{n++} END{print n+0}')))
if [ "$ran" != 7 ]; then
  echo "  FAIL: the variants checks did not all run ($ran of 7)"; FAILED=$((FAILED+1))
fi

echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
