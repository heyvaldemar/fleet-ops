#!/usr/bin/env bash
# test-triage.sh - the parts of fleet-triage.sh that decide what a person
# is asked to look at.
#
# A version can be carried by more than one image. GitLab's server and its
# runner both pin 19.3.2 and are meant to move in lockstep. On 2026-09-18 the
# branch was created inside the pin loop, so it was reset once per pin and
# arrived carrying only the last one, while the report said both were prepared
# and the outer loop bumped the other straight onto main. The runner went to
# 19.4.0 on main while the server it tracks stayed at 19.3.2, which is the one
# thing the upstream review attached to that same run warned against.
#
# So this exercises the real function against a real git repository, with a
# fake docker on PATH resolving the new tags, and asserts the branch carries
# EVERY pin on that version and main carries none of them.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"$'\n'"          expected: $2"$'\n'"          actual:   $3"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OLDDG_A="sha256:$(printf 'a%.0s' $(seq 64))"
OLDDG_B="sha256:$(printf 'b%.0s' $(seq 64))"
NEWDG_A="sha256:$(printf 'c%.0s' $(seq 64))"
NEWDG_B="sha256:$(printf 'd%.0s' $(seq 64))"

# A docker that answers for the new refs and nothing else, so a pin whose new
# tag does not exist is exercised too.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    server/app:19.4.0-ee.0) echo '{"digest":"$NEWDG_A"}'; exit 0 ;;
    vendor/runner:ubuntu-v19.4.0) echo '{"digest":"$NEWDG_B"}'; exit 0 ;;
    vendor/ghost:9.9.9) exit 1 ;;
  esac
done
exit 1
FAKE
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

# A repository shaped like a fleet template.
dir="$WORK/repo"
mkdir -p "$dir"
cat > "$dir/stack.yml" <<YML
x-images:
  app: &app-image \${APP_IMAGE_TAG:-server/app:\${APP_IMAGE_VERSION:-19.3.2-ee.0@$OLDDG_A}}
  runner: &runner-image \${RUNNER_IMAGE_TAG:-vendor/runner:\${RUNNER_IMAGE_VERSION:-ubuntu-v19.3.2@$OLDDG_B}}
YML
# The example declares each pin's version as a commented default. It has to
# move with the pin, and only the line of the pin that moved: OTHER shares the
# value and must stay.
cat > "$dir/.env.example" <<'ENV'
# APP_IMAGE_VERSION=19.3.2-ee.0
# RUNNER_IMAGE_VERSION=ubuntu-v19.3.2
# OTHER_IMAGE_VERSION=19.3.2-ee.0
ENV
cat > "$dir/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-01-01
MD
git -C "$dir" init -q -b main
git -C "$dir" -c user.name=t -c user.email=t@t add -A
git -C "$dir" -c user.name=t -c user.email=t@t commit -qm init
remote="$WORK/remote.git"
git init -q --bare "$remote"
git -C "$dir" remote add origin "$remote"
git -C "$dir" push -q -u origin main

# The script defines the function at load time and runs nothing when sourced
# under this guard, so the real code is exercised rather than a copy.
FLEET_TEST_SOURCE_ONLY=1 . "$ROOT/scripts/fleet-triage.sh" 2>/dev/null || true
if ! declare -f major_branch >/dev/null; then
  echo "  FAIL  major_branch could not be sourced from scripts/fleet-triage.sh"
  exit 1
fi

# What the function reads from its caller's scope.
repo="template-repo"
OWNER="owner"
DRY_RUN="false"
GIT_AUTHOR="t"; GIT_EMAIL="t@t"
composes=("$dir/stack.yml")
PREPARED_THIS_RUN=()
PREPARED_MAJOR=0
NOTES=()
note() { NOTES+=("$1"); }
changelog_line() { :; }

echo "== one version carried by two images"
major_branch "19.3.2" "19.4.0" >/dev/null 2>&1

same "the working tree is left on main" "main" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
same "exactly one branch was pushed" "1" \
  "$(git -C "$remote" for-each-ref --format='%(refname:short)' refs/heads | grep -c '^bump/19.4.0$')"
same "it is one commit ahead of main" "1" \
  "$(git -C "$dir" rev-list --count main..bump/19.4.0)"

branch_file="$(git -C "$dir" show "bump/19.4.0:stack.yml")"
case "$branch_file" in
  *"19.4.0-ee.0@$NEWDG_A"*) ok "the server pin moved on the branch" ;;
  *) no "the server pin did not move on the branch" ;;
esac
case "$branch_file" in
  *"ubuntu-v19.4.0@$NEWDG_B"*) ok "the runner pin moved on the branch, in the same commit" ;;
  *) no "the runner pin was lost — the branch was reset between pins" ;;
esac

main_file="$(git -C "$dir" show "main:stack.yml")"
case "$main_file" in
  *"19.3.2-ee.0@$OLDDG_A"*) ok "main still carries the old server pin" ;;
  *) no "main was modified, and it must not be" ;;
esac
case "$main_file" in
  *"ubuntu-v19.3.2@$OLDDG_B"*) ok "main still carries the old runner pin" ;;
  *) no "main was modified, and it must not be" ;;
esac

same "it is reported as prepared, once" "1" "$(printf '%s\n' "${PREPARED_THIS_RUN[@]}" | grep -c 'bump/19.4.0')"
branch_env="$(git -C "$dir" show "bump/19.4.0:.env.example")"
case "$branch_env" in
  *"# APP_IMAGE_VERSION=19.4.0-ee.0"*) ok "the example's server default moved with the pin" ;;
  *) no "the example's server default did not move: $branch_env" ;;
esac
case "$branch_env" in
  *"# RUNNER_IMAGE_VERSION=ubuntu-v19.4.0"*) ok "the example's runner default moved too" ;;
  *) no "the example's runner default did not move" ;;
esac
case "$branch_env" in
  *"# OTHER_IMAGE_VERSION=19.3.2-ee.0"*) ok "a variable that only shares the value stays" ;;
  *) no "an unrelated variable was rewritten because its value matched" ;;
esac
case "$(git -C "$dir" show "main:.env.example")" in
  *"# APP_IMAGE_VERSION=19.3.2-ee.0"*) ok "main's example is untouched" ;;
  *) no "main's example was modified, and it must not be" ;;
esac
same "the verdict flag is set" "1" "$PREPARED_MAJOR"
named="$(printf '%s\n' "${NOTES[@]}")"
case "$named" in
  *"server/app"*) case "$named" in *"vendor/runner"*) ok "the report names both images" ;;
                    *) no "the report names only the server" ;; esac ;;
  *) no "the report names neither image" ;;
esac

echo "== an unrelated edit already in the tree stays on main"
# The digest-drift pass runs before this one and leaves its edits uncommitted
# in the same compose file. They belong on main. Until 2026-09-18 the commit
# below took them onto the branch instead, main was left with nothing to
# commit, and the run died on the refresh commit that followed.
git -C "$dir" checkout -q main
git -C "$dir" checkout -q -- stack.yml 2>/dev/null
# an unrelated pin drifts, exactly as the digest pass would leave it
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
printf 'unrelated: &other-image ${OTHER_IMAGE_TAG:-vendor/other:1.0@sha256:deadbeef}
' >> "$dir/stack.yml"
NOTES=(); PREPARED_THIS_RUN=(); PREPARED_MAJOR=0
major_branch "19.3.2" "19.4.0" >/dev/null 2>&1

same "the tree is back on main" "main" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
case "$(cat "$dir/stack.yml")" in
  *"vendor/other:1.0@sha256:deadbeef"*) ok "the unrelated edit is still in the working tree, uncommitted" ;;
  *) no "the unrelated edit was swallowed by the branch" ;;
esac
case "$(git -C "$dir" show "bump/19.4.0:stack.yml")" in
  *"vendor/other"*) no "the branch carried an edit that was not its own" ;;
  *) ok "the branch carries only its own change" ;;
esac
git -C "$dir" checkout -q -- stack.yml

echo "== a version no pin carries"
git -C "$dir" checkout -q main
NOTES=(); PREPARED_THIS_RUN=(); PREPARED_MAJOR=0
major_branch "9.9.9" "9.9.10" >/dev/null 2>&1
same "no branch is pushed for it" "0" \
  "$(git -C "$remote" for-each-ref --format='%(refname:short)' refs/heads | grep -c '^bump/9.9.10$')"
same "and it is left on main" "main" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
case "$(printf '%s\n' "${NOTES[@]}")" in
  *"no pin carried it"*) ok "it says no pin carried that version" ;;
  *) no "it said: $(printf '%s\n' "${NOTES[@]}")" ;;
esac

echo "== a scan the registry refused is not a finding"
# blackmesa's Trivy died with "context deadline exceeded" on 2026-09-15 and it
# was real: the secret scanner was walking a 257 MB game archive. immich's died
# with TOOMANYREQUESTS from ghcr.io on 09-18 and the same commit had passed an
# hour earlier. One is the image, the other is the registry, and only the
# second is worth another attempt.
refused() { printf '%s\n' "$1" | registry_refused && echo yes || echo no; }
same "a rate limit is the registry" "yes" \
  "$(refused 'GET https://ghcr.io/v2/x/blobs/sha256:a: TOOMANYREQUESTS: retry-after: 287us')"
same "so is a reset connection" "yes" "$(refused 'failed to get layer: connection reset by peer')"
same "so is a 503" "yes" "$(refused 'unexpected status: 503 Service Unavailable')"
same "a scanner that ran out of its own time is NOT" "no" \
  "$(refused 'walk error: failed to analyze app/bms/bms_textures_019.vpk: semaphore acquire: context deadline exceeded')"
same "nor is an ordinary scan error" "no" "$(refused 'analyze error: pipeline error: failed to analyze layer')"
same "Docker Hub's lowercase spelling is the registry too" "yes" \
  "$(refused 'Error response from daemon: toomanyrequests: retry-after: 251.293µs, allowed: 44000/minute')"

echo "== what a pushed refresh's CI answer means"
# 2026-09-25 13:10: twenty-three digest refreshes reverted in one run. The
# pending row carried the freshness workflow, whose push run is always
# skipped, and "skipped" fell into the revert branch.
same "green is a release" "release" "$(pending_action success)"
same "a red run is a revert" "revert" "$(pending_action failure)"
same "a run that timed out is a revert" "revert" "$(pending_action timed_out)"
same "still running is a wait" "wait" "$(pending_action running)"
same "no run yet is a wait" "wait" "$(pending_action none)"
same "cancelled by a later push is kept" "keep" "$(pending_action cancelled)"
same "skipped is not a verdict on the change, and is kept" "keep" "$(pending_action skipped)"
same "an answer nobody has seen is kept, not reverted" "keep" "$(pending_action neutral)"
same "a lookup GitHub did not answer is held, never escalated" "hold" "$(pending_action unread)"

echo "== a lookup that fails is not a CI that never answered"
# 2026-10-05: kf2's refresh was green one minute after its push. The triage's
# lookup failed, the failure was swallowed into "no run", and at 16.8 hours
# the row was escalated and dropped, so the release was never cut. A gh that
# refuses every call must leave the row in the ledger with no verdict.
(
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh"; chmod +x "$fakebin/gh"
  sleep() { :; }
  PATH="$fakebin:$PATH"
  # DRY_RUN off, so "kept" means the ledger was rewritten and the row survived.
  PENDING="$(mktemp)"; REPORT="$(mktemp)"; WORKDIR="$(mktemp -d)"; STALE_HOURS=12; DRY_RUN=false
  printf '[{"repo": "r", "sha": "abc1234", "wf": "Deployment Verification", "kind": "digest", "pushed_at": "%s"}]\n' \
    "$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=20)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" > "$PENDING"
  NOTES=()
  settle_pending >/dev/null 2>&1
  # note() is the test's own, collecting into NOTES; the report file is not it.
  said="$(printf '%s\n' "${NOTES[@]+"${NOTES[@]}"}")"
  case "$said" in *"did not answer"*) echo "SAID";; esac
  case "$said" in *"needs a human"*) echo "ESCALATED";; esac
  grep -q '"abc1234"' "$PENDING" && echo "KEPT"
  rm -rf "$fakebin" "$PENDING" "$REPORT" "$WORKDIR"
) > "$WORK/unread.out"
out="$(cat "$WORK/unread.out")"
case "$out" in *SAID*) ok "it says GitHub did not answer" ;; *) no "it did not say GitHub was silent: $out" ;; esac
case "$out" in *ESCALATED*) no "a silent GitHub was escalated to a person" ;; *) ok "and it does not ask a person about it" ;; esac
case "$out" in *KEPT*) ok "the row stays in the ledger for the next run" ;; *) no "the row was dropped, so its release would never be cut" ;; esac
same "a refresh is judged by the verification workflow, never by the freshness one" "Deployment Verification" \
  "$(workflow_for gitea-traefik-letsencrypt-docker-compose)"

echo "== the latest run on main is chosen here, not by GitHub's branch filter"
# 2026-10-06 13:38: --branch main --limit 1 answered with a run from
# 2026-09-14 on a repository whose newest runs on main were from that morning,
# and the report called a three-week-old failure the current one. The stand-in
# answers in the stale order: the old failure first, a newer run on another
# branch next to it, the newest run on main last.
(
  answer="$(mktemp)"; GH_ARGS="$(mktemp)"
  cat > "$answer" <<'JSON'
[{"headBranch":"main","createdAt":"2026-09-14T11:18:03Z","databaseId":1,"conclusion":"failure","status":"completed","attempt":1},
 {"headBranch":"bump/9.0.0","createdAt":"2026-10-06T09:00:00Z","databaseId":3,"conclusion":"failure","status":"completed","attempt":1},
 {"headBranch":"main","createdAt":"2026-10-06T00:33:07Z","databaseId":2,"conclusion":"success","status":"completed","attempt":1}]
JSON
  gh() { printf '%s\n' "$*" >> "$GH_ARGS"; cat "$answer"; }
  runs_on_main r "Terraform Verification" 20 databaseId,conclusion,status,attempt | jq -r '.[0].databaseId'
  grep -q -- '--branch' "$GH_ARGS" && echo "FILTERED"
  gh() { return 1; }
  runs_on_main r "Terraform Verification" 20 databaseId || echo "FAILED"
  rm -f "$answer" "$GH_ARGS"
) > "$WORK/onmain.out" 2>/dev/null
out="$(cat "$WORK/onmain.out")"
same "the newest run on main is the one judged" "2" "$(head -1 <<<"$out")"
case "$out" in *FILTERED*) no "the branch filter is still asked for" ;; *) ok "and GitHub's branch filter is never asked for" ;; esac
case "$out" in *FAILED*) ok "a gh that fails still fails, so the caller can retry" ;; *) no "a failed lookup came back as an empty answer" ;; esac

echo "== the log is read before the job names"
# immich, 2026-09-25 11:01: the registry refused the three scans and the
# deploy's pulls in one run; the deploy job's name matched first and the run
# was handed to a person without the log being opened.
vlog="$(mktemp)"; printf '%s\n' 'Error response from daemon: toomanyrequests: retry-after: 251us' > "$vlog"
qlog="$(mktemp)"; printf '%s\n' 'analyze error: pipeline error: failed to analyze layer' > "$qlog"
same "scans and the deploy, refused by the registry: rerun" "registry" \
  "$(rerun_verdict 'Scan pinned upstream image with Trivy (postgres),Scan pinned upstream image with Trivy (immich-server),docker compose up + Immich HTTPS smoke' "$vlog")"
same "the deploy alone, with a quiet log: a person" "deploy" \
  "$(rerun_verdict 'Lint,docker compose up + Immich HTTPS smoke' "$qlog")"
same "a scan alone, failing on its own: a person" "scan" \
  "$(rerun_verdict 'Scan pinned upstream image with Trivy (postgres)' "$qlog")"
same "the drift alarm alone: freshness" "freshness" \
  "$(rerun_verdict 'Check pinned images for upstream drift' "$vlog")"
same "the drift alarm beside a refused deploy is the registry, not freshness" "registry" \
  "$(rerun_verdict 'Check pinned images for upstream drift,docker compose up + smoke' "$vlog")"
same "a log that could not be read does not make a rerun" "deploy" \
  "$(rerun_verdict 'docker compose up + smoke' /dev/null)"
rm -f "$vlog" "$qlog"

echo
echo "== a freshness alarm is not a verdict on what was pushed"
# On 2026-09-21 gaseous-server had a good digest refresh reverted. In the run
# that condemned it, compose up, the HTTPS smoke test, Trivy and the linter all
# passed; the only red job was upstream drift, which goes red whenever any pin
# in that repository lags and says nothing about the digest just written.
fo() { freshness_only_failure "$1" && echo yes || echo no; }
same "the drift job alone is the alarm" "yes" \
  "$(fo 'Check pinned images for upstream drift')"
same "and so is the terraform wording of it" "yes" \
  "$(fo 'Check pinned providers and images for upstream drift')"
same "the deploy job failing is a real failure" "no" \
  "$(fo 'docker compose up + Gaseous HTTPS smoke')"
same "the alarm beside a real failure is still a real failure" "no" \
  "$(fo 'Check pinned images for upstream drift,docker compose up + smoke')"
same "a scan failure is not the alarm either" "no" \
  "$(fo 'Scan pinned upstream image with Trivy (gaseous)')"
# THE DIRECTION THAT COSTS. Jobs that could not be read must not be waved
# through as "nothing real failed": a revert thrown away is recoverable, a
# broken pin left on main is what this whole pass exists to prevent.
same "jobs that could not be read are NOT waved through" "no" "$(fo '')"


# WHAT THE ROBOT CAN READ IS NOT WHAT THE ALARM SAYS. Each template writes its
# own freshness sentence. Measured across the fleet on 2026-09-23: fifty-one
# shapes the old grep matched, fifty-one it did not — every Traefik pin among
# them. Those alarms were right, their logs said so in plain English, and
# nothing could act on them.
lagcase() {          # lagcase <name> <line> <expected old> <expected new>
  local got
  got="$(printf '%s\n' "$2" | lag_lines | head -1)"
  if [ -z "$got" ]; then no "$1 (nothing matched)"; return; fi
  same "$1" "$3	$4" "$(lag_pair "$got")"
}

lagcase "a plain tag lag is read" \
  "::error::ghost pin is behind: pinned 6.64.0, latest tag is 6.65.0" 6.64.0 6.65.0
lagcase "a qualifier after 'pinned' does not hide it" \
  "::error::Traefik pin is behind: pinned minor 3.6, latest release is 3.7" 3.6 3.7
lagcase "nor does a line named between 'behind' and the colon" \
  "::error::Zabbix pin is behind its line: pinned 7.0.30, latest in 7.0 is 7.0.31" 7.0.30 7.0.31
lagcase "nor 'newest stable tag' instead of 'latest tag'" \
  "::error::ZOMBOID_SERVER_IMAGE_TAG is behind: pinned 41.78.16, newest stable tag is 41.78.20" 41.78.16 41.78.20
lagcase "a v prefix survives on both sides" \
  "::error::pin is behind: pinned v1.2.3, latest release is v1.2.4" v1.2.3 v1.2.4
lagcase "a lag that names its variable keeps it and still parses" \
  "::error::MINECRAFT_SERVER_BACKUP_IMAGE_TAG is behind: pinned 2026.9.2, latest itzg/docker-mc-backup release is 2026.9.3" 2026.9.2 2026.9.3

# ONE VERSION STRING, TWO IMAGES THAT DO NOT MOVE TOGETHER. The server and its
# backup sidecar both pinned 2026.9.2 on 2026-10-01; only the sidecar lagged.
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
srv='${MINECRAFT_SERVER_IMAGE_TAG:-itzg/minecraft-server:2026.9.2@sha256:aaaa}'
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
bak='${MINECRAFT_SERVER_BACKUP_IMAGE_TAG:-itzg/mc-backup:2026.9.2@sha256:bbbb}'
named="$(printf '%s\n' "::error::MINECRAFT_SERVER_BACKUP_IMAGE_TAG is behind: pinned 2026.9.2, latest itzg/docker-mc-backup release is 2026.9.3" | lag_lines)"
pl() { pin_lags "$1" "$2" "$3" && echo yes || echo no; }
same "the pin the alarm names moves" "yes" "$(pl "$bak" "$named" 2026.9.2)"
same "a pin that only shares the version stays" "no" "$(pl "$srv" "$named" 2026.9.2)"
unnamed="$(printf '%s\n' "::error::pin is behind: pinned 2026.9.2, latest release is 2026.9.3" | lag_lines)"
same "an alarm that names no variable still moves every pin on that version" "yes" "$(pl "$srv" "$unnamed" 2026.9.2)"
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
same "a pin on another version never moves" "no" "$(pl '${X_IMAGE_TAG:-a/b:1.0.0@sha256:cccc}' "$named" 2026.9.2)"

# A PRE-RELEASE PUBLISHED AS LATEST. The suffix decides, and the ordinary
# hyphens in image tags must not be mistaken for one.
pr() { is_prerelease "$1" && echo yes || echo no; }
same "a beta published without the flag is still a pre-release" "yes" "$(pr 3.0.0-beta.617)"
same "a release candidate is one" "yes" "$(pr v2.6.0-rc.1)"
same "and so is an upper-case RC" "yes" "$(pr 1.0.0-RC2)"
same "a stable version is not" "no" "$(pr 2.5.315)"
same "an XWiki flavour tag is not" "no" "$(pr 18.8.0-postgres-tomcat)"
same "a GitLab edition tag is not" "no" "$(pr 19.4.1-ee.0)"
same "a SQL Server CU tag is not" "no" "$(pr 2022-CU27-ubuntu-22.04)"
same "nor a word that merely starts like one" "no" "$(pr 7.0-debian-preserve)"

# AND WHAT MUST STILL MATCH NOTHING. rathena counts commits behind a branch:
# real, reported, and not a version bump anybody can make automatically.
same "a commits-behind line is not a version lag" "" \
  "$(printf '%s\n' "::error::RATHENA_REF is 5 commits behind upstream master (pinned abc1234, head def5678)" | lag_lines)"
same "and neither is an ordinary log line" "" \
  "$(printf '%s\n' "Successfully pulled image" | lag_lines)"


# WHERE THE FRESHNESS VERDICT LIVES. A repository moved to freshness.yml is read
# there; one not moved yet is read where it always was; and an answer that is
# neither - a transport error - must not quietly fall back, because the old
# workflow no longer carries the alarm and would read as green for ever.
fake_gh() {          # the contents API, answering as $FAKE says
  case "$FAKE" in
    (found) return 0 ;;
    (missing) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    (broken) echo "error connecting to api.github.com" >&2; return 1 ;;
  esac
}
fwcase() {           # fwcase <name> <what the contents API does> <expected>
  local got
  # The ( ) patterns above and the stand-in defined here, rather than a case
  # written inside $( ): bash 3.2, which macOS still ships, cannot parse the
  # latter, and a suite that only runs on the runner is half a suite.
  got="$(gh() { fake_gh "$@"; }; FAKE="$2" freshness_wf_for some-template-docker-compose || echo "REFUSED")"
  same "$1" "$3" "$got"
}
OWNER="owner"
fwcase "a moved repository is read from freshness.yml" found "freshness.yml"
fwcase "one not moved yet is read where it always was" missing "Deployment Verification"
fwcase "an unreadable answer is refused, not guessed" broken "REFUSED"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
