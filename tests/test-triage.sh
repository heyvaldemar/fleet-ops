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
# tag does not exist is exercised too. A tag that is not there is answered the
# way a registry answers it ("not found"); limited/app stands for a registry
# that does not answer at all: Docker Hub's 429 after a burst.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    server/app:19.4.0-ee.0) echo '{"digest":"$NEWDG_A"}'; exit 0 ;;
    vendor/runner:ubuntu-v19.4.0) echo '{"digest":"$NEWDG_B"}'; exit 0 ;;
    limited/app:*) echo "ERROR: failed to authorize: unexpected status from GET request to https://auth.docker.io/token: 429 Too Many Requests" >&2; exit 1 ;;
    vendor/ghost:9.9.9) echo "ERROR: docker.io/vendor/ghost:9.9.9: not found" >&2; exit 1 ;;
  esac
done
echo "ERROR: \${!#}: not found" >&2
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
# The real changelog writer, kept before the stand-in below replaces it: the
# image refresh is judged on the CHANGELOG it actually writes.
eval "$(declare -f changelog_line | sed '1s/^changelog_line/real_changelog_line/')"

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
  # shellcheck disable=SC2030  # this subshell's PATH only, which is the point
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

echo "== a template built from source moves its commit when no SQL moved"
# 2026-10-06: rAthena's master moved two commits, both duplicate keys removed
# from item tables, and the report could only say nothing was auto-fixable.
P=e985006171d2eb320ee512a653f4c83aea3d81b6; H=d4b8e7b8f16061cc2496d377ac8f777ce72a4f39
srcfix() {           # srcfix <files the compare lists, one per line> [log line]
  local d; d="$(mktemp -d)"
  printf 'FROM alpine\nARG RATHENA_REF=%s\nRUN git remote add origin https://github.com/rathena/rathena.git\n' "$P" > "$d/Dockerfile"
  # changelog_line is stood in for above; here it says what it was asked to write.
  changelog_line() { printf 'CHANGELOG %s: %s\n' "$2" "$3"; }
  printf 'freshness\tstep\t2026-10-06T23:13:53Z ##[error]%s\n' \
    "${2:-RATHENA_REF is 2 commits behind upstream master (pinned $P, head $H) — bump and rebuild}" > "$d/log"
  CMP_FILES="$1"
  gh() { jq -n --arg f "$CMP_FILES" '{status: "ahead", ahead_by: 2, files: [$f | split("\n")[] | select(length > 0) | {filename: .}]}'; }
  NOTES=()
  source_ref_refresh "$d" rathena-docker "$d/log"
  printf 'changed=%s noted=%s\n' "$SRC_CHANGED" "$SRC_NOTED"
  grep -o 'RATHENA_REF=[0-9a-f]*' "$d/Dockerfile"
  printf '%s\n' "${NOTES[@]+"${NOTES[@]}"}"
  rm -rf "$d"
}
out="$(srcfix $'db/re/item_db_equip.yml\ndb/re/item_group_db.yml')"
case "$out" in *"changed=1"*) ok "two data-only commits move the pin" ;; *) no "a data-only move was not applied: $out" ;; esac
case "$out" in *"RATHENA_REF=$H"*) ok "the Dockerfile names the new commit" ;; *) no "the Dockerfile was not moved: $out" ;; esac
# shellcheck disable=SC2016 # the backticks are the changelog's Markdown, not a command
case "$out" in *'CHANGELOG Changed: - **`rathena/rathena` moved from `e985006` to `d4b8e7b`.**'*) ok "and the changelog says from what to what" ;; *) no "no changelog line: $out" ;; esac
out="$(srcfix $'db/re/item_db.yml\nsql-files/upgrades/upgrade_20261006.sql')"
case "$out" in *"changed=0"*"RATHENA_REF=$P"*) ok "a move that carries SQL leaves the pin alone" ;; *) no "a SQL move was applied: $out" ;; esac
case "$out" in *"upgrade_20261006.sql"*"needs a human"*) ok "and names the file a person has to apply" ;; *) no "the SQL file was not named: $out" ;; esac
out="$(srcfix 'db/x.yml' 'RATHENA_REF matches the upstream master head')"
case "$out" in *"changed=0 noted=0"*) ok "a green log is not read as a lag" ;; *) no "a log with no lag did something: $out" ;; esac
out="$(srcfix 'db/x.yml' "RATHENA_REF is 2 commits behind upstream master (pinned $H, head $P)")"
case "$out" in *"changed=0"*"does not pin"*) ok "a lag about a commit the Dockerfile does not pin is a person's" ;; *) no "a mismatched lag was applied: $out" ;; esac

echo "== a tag announced an hour ago is a wait, not a decision"
# 2026-10-07: Ghost tagged 6.69.0 one minute after the run started, the image
# was hours from Docker Hub, and the line said "needs a human" regardless.
unpub() {            # unpub <hours since the release, or "none"> -> the note
  local when
  if [ "$1" = none ]; then gh() { return 1; }; else
    when="$(python3 -c 'import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1")"
    eval "gh() { echo '$when'; }"
  fi
  NOTES=()
  unpublished_note ghost-template "ghost:6.69.0" "6.69.0"
  printf '%s\n' "${NOTES[@]}"
}
out="$(unpub 0)"
case "$out" in *"a wait"*) ok "announced this hour: a wait" ;; *) no "a fresh tag was not called a wait: $out" ;; esac
case "$out" in *"needs a human"*) no "a fresh tag still asks a person" ;; *) ok "and no person is asked" ;; esac
out="$(unpub 100)"
case "$out" in *"(100h ago)"*"needs a human"*) ok "announced four days ago and still missing: a person is told, with the age" ;; *) no "a stale tag was not escalated: $out" ;; esac
out="$(unpub none)"
case "$out" in *"needs a human"*) ok "an age that cannot be read is told, never assumed fresh" ;; *) no "an unreadable age was taken as a wait: $out" ;; esac
same "an image with no known source has no age" "" "$(announced_hours some/unknown-image 1.0)"

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

# A TERRAFORM TEMPLATE WRITES THREE SHAPES, AND A CHART IS ONE OF THEM. The
# chart line says "latest is"; on 2026-10-28 nothing read it.
tfl() { printf '%s\n' "$1" | tf_lag_lines; }
same "a provider lag is read" "hashicorp/aws is behind: pinned 6.70.0, latest release is 6.71.0" \
  "$(tfl "::error::hashicorp/aws is behind: pinned 6.70.0, latest release is 6.71.0")"
same "the image lag is read" "TERRAFORM_IMAGE is behind: pinned 1.17, latest release is 1.18" \
  "$(tfl "::error::TERRAFORM_IMAGE is behind: pinned 1.17, latest release is 1.18")"
same "a chart lag is read, named as a chart" "helm_release aws-ebs-csi-driver is behind: pinned 2.67.0, latest is 2.67.2" \
  "$(tfl "::error::helm_release aws-ebs-csi-driver is behind: pinned 2.67.0, latest is 2.67.2")"
same "a chart that is current is not a lag" "" \
  "$(tfl "helm_release aws-ebs-csi-driver 2.67.2 is the latest release")"

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

# A MINOR NEEDS SAFE TO APPLY. Dify 1.18.0 -> 1.19.0 was reviewed NEEDS
# ATTENTION on 2026-11-04 and reached main half done; a patch keeps riding.
cm() { crosses_minor "$1" "$2" && echo minor || echo patch; }
same "Dify 1.18.0 -> 1.19.0 crosses a minor" "minor" "$(cm 1.18.0 1.19.0)"
same "a patch does not" "patch" "$(cm 10.5.1 10.5.2)"
same "a two-part line moving is a minor" "minor" "$(cm 3.7 3.8)"
same "a leading v is read past" "patch" "$(cm v2.6.0 v2.6.4)"
same "an edition suffix is not a minor" "patch" "$(cm 19.3.1-ee.0 19.3.2-ee.0)"
same "a calendar month is a minor" "minor" "$(cm 2026.9.3 2026.10.0)"
same "a calendar day inside the month is not" "patch" "$(cm 2026.9.2 2026.9.3)"

# A LINE IS NOT A VERSION. Open WebUI's check says "pinned minor 0.12" over a
# tag 0.12.0; the bump must name 0.13.0, never 0.13.0.0.
same "a minor line over a full tag moves the whole version" "ghcr.io/open-webui/open-webui:0.13.0" "$(bumped_ref ghcr.io/open-webui/open-webui:0.12.0 0.12 0.13.0)"
same "and keeps the tag's suffix" "vendor/app:0.13.0-cuda" "$(bumped_ref vendor/app:0.12.4-cuda 0.12 0.13.0)"
same "and its v" "vendor/app:v0.13.0" "$(bumped_ref vendor/app:v0.12.4 0.12 v0.13.0)"
same "a tag that is the line itself moves as before" "traefik:3.8" "$(bumped_ref traefik:3.7 3.7 3.8)"
same "an edition suffix moves as before" "server/app:19.4.0-ee.0" "$(bumped_ref server/app:19.3.2-ee.0 19.3.2 19.4.0)"
same "a registry port is not a tag" "reg.example:5000/app:0.13.0" "$(bumped_ref reg.example:5000/app:0.12.1 0.12 0.13.0)"

# A NEWER MINOR HIDES THE PATCHES OF THE ONE PINNED. Open WebUI sat at 0.12.0
# on 2026-11-08 with 0.12.1-0.12.5 published, because every alarm named 0.13.x
# and only a branch came of it. The registry is asked for the pinned line.
#
# registry_tags against a fake registry: a 401 that names its token realm,
# an anonymous token, a second page behind a Link header. The token reaches
# curl on stdin only; an argument is what ps shows every user on the host.
CURLLOG="$WORK/curl.log"
fake_curl() {
  local a=" $* " o="" d="" cfg url
  while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift 2 ;; -D) d="$2"; shift 2 ;; *) shift ;; esac; done
  if [[ "$a" != *" --config - "* ]]; then
    printf 'TOKEN%s\n' "$a" >> "$CURLLOG"; printf '{"token":"tok-not-for-argv"}\n'; return 0
  fi
  cfg="$(cat)"; url="$(sed -nE 's/^url = "(.*)"$/\1/p' <<<"$cfg")"
  if ! grep -q 'Authorization: Bearer tok-not-for-argv' <<<"$cfg"; then
    printf 'GET %s ANON%s\n' "$url" "$a" >> "$CURLLOG"
    case "$url" in
      *broken*) printf 'HTTP/1.1 500\r\n\r\n' > "$d"; : > "$o"; printf 500; return 0 ;;
      *mcr.example*) printf 'HTTP/1.1 200\r\n\r\n' > "$d"; printf '{"tags":["1.0.0","1.0.1"]}\n' > "$o"; printf 200; return 0 ;;
    esac
    printf 'HTTP/1.1 401\r\nWww-Authenticate: Bearer realm="https://auth.example/token",service="reg.example",scope="repository:team/app:pull"\r\n\r\n' > "$d"
    : > "$o"; printf 401; return 0
  fi
  printf 'GET %s AUTH%s\n' "$url" "$a" >> "$CURLLOG"
  case "$url" in
    *"last=0.12."|*"last=0.12.&"*)
      printf 'HTTP/1.1 200\r\nLink: </v2/team/app/tags/list?last=0.13.0&n=1000>; rel="next"\r\n\r\n' > "$d"
      printf '{"tags":["0.12.0","0.12.4","0.13.0"]}\n' > "$o" ;;
    *last=*) printf 'HTTP/1.1 200\r\n\r\n' > "$d"; printf '{"tags":["0.12.5","0.13.0"]}\n' > "$o" ;;
    *) printf 'HTTP/1.1 200\r\nLink: </v2/team/app/tags/list?last=0.12.4&n=1000>; rel="next"\r\n\r\n' > "$d"
       printf '{"tags":["0.12.0","0.12.4"]}\n' > "$o" ;;
  esac
  printf 200
}
rt() { : > "$CURLLOG"; ( curl() { fake_curl "$@"; }; registry_tags "$1" | tr '\n' ' ' ); }
same "every page of tags is read, the token fetched once" "0.12.0 0.12.4 0.12.5 0.13.0 " "$(rt reg.example/team/app)"
same "the token is asked of the realm the 401 named, for its scope" "1" \
  "$(grep -c '^TOKEN .*service=reg.example .*scope=repository:team/app:pull https://auth.example/token' "$CURLLOG")"
same "the second page is the Link header's, on the same host" "1" \
  "$(grep -c '^GET https://reg.example/v2/team/app/tags/list?last=0.12.4&n=1000 AUTH' "$CURLLOG")"
same "the token is never an argument" "0" "$(grep -c 'tok-not-for-argv' "$CURLLOG")"
rt postgres >/dev/null
same "a bare name is Docker Hub's library" "https://registry-1.docker.io/v2/library/postgres/tags/list?n=1000" \
  "$(head -1 "$CURLLOG" | cut -d' ' -f2)"
rt grafana/grafana >/dev/null
same "a two-part name with no host is Docker Hub's too" "https://registry-1.docker.io/v2/grafana/grafana/tags/list?n=1000" \
  "$(head -1 "$CURLLOG" | cut -d' ' -f2)"
same "a registry that needs no token is read without one" "1.0.0 1.0.1 " "$(rt mcr.example/team/app)"
rtp() { : > "$CURLLOG"; ( curl() { fake_curl "$@"; }; registry_tags reg.example/team/app "$@" | tr '\n' ' ' ); }
same "asked from a line, only the line's tags come back" "0.12.0 0.12.4 " "$(rtp 0.12.)"
same "and the list stops where the line's block ends" "0" "$(grep -c 'last=0.13.0' "$CURLLOG")"
same "asked from after a tag, the list is read past it" "0.12.5 " "$(rtp 0.12. 0.12.4)"
same "from that tag" "1" "$(grep -c 'tags/list?n=1000&last=0.12.4 AUTH' "$CURLLOG")"
if ( curl() { fake_curl "$@"; }; registry_tags reg.broken/team/app >/dev/null ); then
  no "a registry answering 500 was read as an empty list"
else ok "a registry answering 500 is not an answer"; fi

# line_newest over a stubbed tag list: the tag's own shape, its own line.
WEBUI_TAGS='0.11.6 0.12.0 0.12.0-cuda 0.12.1 0.12.4-cuda 0.12.5 0.12.5-cuda 0.12.5-cuda126 0.12.6-rc1 0.13.0 0.13.2 latest main'
tag_line() { ( registry_tags() { echo "registry asked" >> "$CURLLOG"; tr ' ' '\n' <<<"$WEBUI_TAGS"; }; line_newest "$1" ); }
same "the newest patch of the pinned line, not the newest release" "0.12.0	0.12.5	0.12" "$(tag_line ghcr.io/open-webui/open-webui:0.12.0)"
same "the suffix is kept: -cuda moves to -cuda" "0.12.4	0.12.5	0.12" "$(tag_line vendor/app:0.12.4-cuda)"
WEBUI_TAGS='0.12.4-cuda 0.12.6-cuda126 0.12.7'
same "and matched exactly: -cuda126 and a bare tag are other images" "" "$(tag_line vendor/app:0.12.4-cuda)"
WEBUI_TAGS='0.11.6 0.12.0 0.12.0-cuda 0.12.1 0.12.4-cuda 0.12.5 0.12.5-cuda 0.12.5-cuda126 0.12.6-rc1 0.13.0 0.13.2 latest main'
same "a pre-release in the line is not a patch" "" "$(tag_line vendor/app:0.12.5)"
WEBUI_TAGS='v1.2.3 v1.2.9 v1.2.10 1.2.11 v1.3.0'
same "patches compare as numbers, and the v prefix is part of the shape" "v1.2.3	v1.2.10	1.2" "$(tag_line vendor/app:v1.2.3)"
WEBUI_TAGS='0.12.0 0.13.0'
same "a line with nothing newer gives nothing" "" "$(tag_line vendor/app:0.12.0)"
: > "$CURLLOG"
same "a tag that is a line itself (traefik:3.7) gives nothing" "" "$(tag_line traefik:3.7)"
same "and the registry is not even asked" "0" "$(grep -c 'registry asked' "$CURLLOG")"
# ghcr.io keeps tags in push order and answers `last=0.12.` with nothing at
# all; the whole list is read when the pinned tag is not in the block.
WEBUI_TAGS='main git-509d2a6 0.12.5 latest 0.12.0 0.13.2'
pref() { : > "$CURLLOG"; ( registry_tags() { echo "asked $2 after ${3:-none}" >> "$CURLLOG"; [ -z "${3:-}" ] || tr ' ' '\n' <<<"$WEBUI_TAGS" | grep "^$2"; }; line_newest "$1" ); }
same "a block without the pinned tag is asked again from after that tag" "0.12.0	0.12.5	0.12" "$(pref ghcr.io/open-webui/open-webui:0.12.0)"
same "from the line first, then from the pinned tag" "asked 0.12. after none asked 0.12. after 0.12.0" "$(tr '\n' ' ' < "$CURLLOG" | sed 's/ $//')"
blk() { : > "$CURLLOG"; ( registry_tags() { echo "asked $2 after ${3:-none}" >> "$CURLLOG"; tr ' ' '\n' <<<"0.12.0 0.12.7"; }; line_newest "$1" ); }
same "a block that has it is the answer" "0.12.0	0.12.7	0.12" "$(blk vendor/app:0.12.0)"
same "and nothing more is asked" "asked 0.12. after none" "$(tr '\n' ' ' < "$CURLLOG" | sed 's/ $//')"
if ( registry_tags() { return 1; }; line_newest vendor/app:0.12.0 >/dev/null ); then
  no "a registry that did not answer was read as no newer patch"
else ok "a registry that did not answer says so"; fi

# all_line_lags: a lag line, in the alarms' own shape and naming its pin's
# variable, for every pin whose own line has a newer patch.
lc="$WORK/line-compose.yml"
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
printf '%s\n' \
  '  webui: ${WEBUI_IMAGE_TAG:-ghcr.io/open-webui/open-webui:${WEBUI_IMAGE_VERSION:-0.12.0@sha256:aaaa}}' \
  '  db: ${DB_IMAGE_TAG:-postgres:${DB_IMAGE_VERSION:-10.12.3@sha256:bbbb}}' \
  '  proxy: ${TRAEFIK_IMAGE_TAG:-traefik:${TRAEFIK_IMAGE_VERSION:-3.7@sha256:cccc}}' \
  '  free: ${FREE_IMAGE_TAG:-vendor/unpinned:1.2.3}' > "$lc"
ll() {
  : > "$CURLLOG"
  ( REPORT="$WORK/line-report"; : > "$REPORT"; repo=ollama
    registry_tags() { echo "registry asked $1 $2" >> "$CURLLOG"; tr ' ' '\n' <<<"$WEBUI_TAGS"; }
    all_line_lags "$lc" 2>/dev/null )
}
WEBUI_TAGS='0.12.0 0.12.1 0.12.5 0.13.0 0.13.2 10.12.3 10.12.9'
extra="$(ll)"
same "every full-version pin behind its own line gets one, naming its variable" \
  "WEBUI_IMAGE_TAG is behind its line: pinned 0.12.0, latest in 0.12 is 0.12.5
DB_IMAGE_TAG is behind its line: pinned 10.12.3, latest in 10.12 is 10.12.9" "$(sort -r <<<"$extra")"
same "each registry is asked from its pin's own line" "2" \
  "$(grep -cE '^registry asked (ghcr.io/open-webui/open-webui 0\.12\.|postgres 10\.12\.)$' "$CURLLOG")"
same "a line tag (traefik:3.7) and a pin with no digest send nobody to a registry" "0" \
  "$(grep -cE 'registry asked (traefik|vendor/unpinned)' "$CURLLOG")"
webui_lag="$(grep '^WEBUI' <<<"$extra")"
same "the line reads back as the patch it is" "0.12.0	0.12.5" "$(lag_pair "$webui_lag")"
same "for that pin alone" "WEBUI_IMAGE_TAG" "$(lag_var "$webui_lag")"
same "and does not cross a minor, so it rides as a patch" "patch" "$(cm 0.12.0 0.12.5)"
same "the bump it makes is the published tag" "ghcr.io/open-webui/open-webui:0.12.5" \
  "$(bumped_ref ghcr.io/open-webui/open-webui:0.12.0 "$(lag_pair "$webui_lag" | cut -f1)" "$(lag_pair "$webui_lag" | cut -f2)")"
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
same "and pin_lags moves the Open WebUI pin with it" "yes" "$(pl '${WEBUI_IMAGE_TAG:-ghcr.io/open-webui/open-webui:0.12.0@sha256:aaaa}' "$webui_lag" 0.12.0)"
# shellcheck disable=SC2016  # ${...} is compose interpolation, written literally
same "and not the postgres pin beside it" "no" "$(pl '${DB_IMAGE_TAG:-postgres:10.12.3@sha256:bbbb}' "$webui_lag" 0.12.0)"
WEBUI_TAGS='0.12.0 0.13.2 10.12.3'
same "pins at the head of their lines bring nothing" "" "$(ll)"
# note() is the test's own collector above; here it only has to reach a file.
quiet="$( : > "$CURLLOG"; ( REPORT="$WORK/line-report"; : > "$REPORT"; repo=ollama
  note() { printf 'NOTE %s\n' "$*" >> "$REPORT"; }
  registry_tags() { return 1; }
  out="$(all_line_lags "$lc" 2>/dev/null)"; printf '%s|' "$out"; cat "$REPORT" ) )"
case "$quiet" in
  "|"*"ghcr.io/open-webui/open-webui:0.12.0 — its own patch line not checked, the registry did not list its tags"*) ok "a registry that did not answer adds no lag and is reported as not checked" ;;
  *) no "registry down: $quiet" ;;
esac


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

echo "== an image repository refreshes the base digests in its Dockerfile"
# kubectl-docker, os-shell-docker, minio-client-docker and jmx-exporter-docker
# have no compose file. Their freshness check went red every few days on a
# debian:*-slim or golang:1.27-* repush, triage said "no compose file found",
# and two sessions moved the digests by hand on 2026-11-05 and 11-07.
# Dependabot never opened a pull request for one.
dg() { printf 'sha256:%s' "$(printf '%064d' 0 | tr 0 "$1")"; }
D_OLD="$(dg 1)"; D_NEW="$(dg 2)"     # debian:trixie-slim, no toolchain declared
G_OLD="$(dg 3)"; G_NEW="$(dg 4)"     # golang:1.27-trixie, Go unchanged on amd64/arm64
M_OLD="$(dg 5)"; M_NEW="$(dg 6)"     # maven:...-temurin-21, the JDK moved
B_OLD="$(dg 7)"; B_NEW="$(dg 8)"     # golang:1.27-bookworm, its old digest unreadable
imgbin="$WORK/imgbin"; mkdir -p "$imgbin"
# Reached through a docker() function in each subshell rather than PATH, so
# the fake above stays the one the other tests see. It answers the two
# questions triage asks: the digest a tag names now ({{json .Manifest}}) and a
# digest's config ({{json .Image}}), an index of platforms or, for a single
# platform, the config alone.
cat > "$imgbin/docker" <<FAKE
#!/usr/bin/env bash
ref=""; fmt=""
while [ \$# -gt 0 ]; do
  case "\$1" in --format) fmt="\$2"; shift ;; buildx|imagetools|inspect) ;; *) ref="\$1" ;; esac
  shift
done
env_of() { printf '{"architecture":"x","os":"linux","config":{"Env":["PATH=/usr/bin"%s]}}' "\${1:+,\"\$1\"}"; }
index() { printf '{"linux/amd64":%s,"linux/arm64":%s,"linux/386":%s}' "\$(env_of "\$1")" "\$(env_of "\$2")" "\$(env_of "\$3")"; }
case "\$fmt" in
  *Manifest*)
    case "\$ref" in
      debian:trixie-slim) echo '{"digest":"$D_NEW"}' ;;
      golang:1.27-trixie) echo '{"digest":"$G_NEW"}' ;;
      maven:3.9.16-eclipse-temurin-21) echo '{"digest":"$M_NEW"}' ;;
      golang:1.27-bookworm) echo '{"digest":"$B_NEW"}' ;;
      limited/*) echo "ERROR: unexpected status from HEAD request: 429 Too Many Requests" >&2; exit 1 ;;
      *) echo "ERROR: docker.io/\$ref: not found" >&2; exit 1 ;;
    esac ;;
  *Image*)
    case "\$ref" in
      debian:trixie-slim@$D_OLD|debian:trixie-slim@$D_NEW) index "" "" "" ;;
      # Go moved on a platform the fleet does not build, and nowhere else.
      golang:1.27-trixie@$G_OLD) index GOLANG_VERSION=1.27.3 GOLANG_VERSION=1.27.3 GOLANG_VERSION=1.27.3 ;;
      golang:1.27-trixie@$G_NEW) index GOLANG_VERSION=1.27.3 GOLANG_VERSION=1.27.3 GOLANG_VERSION=1.27.4 ;;
      maven:3.9.16-eclipse-temurin-21@$M_OLD) index JAVA_VERSION=jdk-21.0.12+8 JAVA_VERSION=jdk-21.0.12.1+1 "" ;;
      maven:3.9.16-eclipse-temurin-21@$M_NEW) index JAVA_VERSION=jdk-21.0.13+11 JAVA_VERSION=jdk-21.0.12.1+1 "" ;;
      golang:1.27-bookworm@$B_NEW) index GOLANG_VERSION=1.27.3 GOLANG_VERSION=1.27.3 "" ;;
      single/go:1@*) env_of GOLANG_VERSION=1.27.3 ;;
      other/arch:1@*) printf '{"linux/s390x":%s}' "\$(env_of GOLANG_VERSION=1.27.3)" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$imgbin/docker"

imgrepo() {          # imgrepo <dir> <Dockerfile text>: a repository shaped like an image repo, pushed
  local d="$1"
  mkdir -p "$d/.github/workflows"
  printf '%s\n' "$2" > "$d/Dockerfile"
  printf 'name: Publish Docker Image\n' > "$d/.github/workflows/publish.yml"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.1] - 2026-11-05\n\n### Changed\n\n- Debian.\n' > "$d/CHANGELOG.md"
  git -C "$d" init -q -b main
  git -C "$d" -c user.name=t -c user.email=t@t add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init
  git init -q --bare "$d.git"
  git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q -u origin main
}
# The log of the 2026-11-07 os-shell run, in its shape: the echo the step
# prints, the error it raised for a digest, the exit, and a tool release.
# Not named imglog: image_repo_pass has a local by that name, and the stand-in
# gh below, called from inside it, would read the local (bash scopes dynamically).
FRESH_LOG="$WORK/freshness.log"
{
  # shellcheck disable=SC2016  # the step's own source line, printed unexpanded as GitHub shows it
  printf 'pins\tUNKNOWN STEP\t2026-11-07T11:51:26.58Z \033[36;1m    echo "::error::${name} is now ${current}; the Dockerfile pins ${pinned#*@}"; fail=1\033[0m\n'
  printf 'pins\tUNKNOWN STEP\t2026-11-07T11:51:28.33Z ##[error]debian:trixie-slim is now %s; the Dockerfile pins %s\r\n' "$D_NEW" "$D_OLD"
  printf 'pins\tUNKNOWN STEP\t2026-11-07T11:51:30.57Z ##[error]Process completed with exit code 1.\n'
  printf 'pins\tUNKNOWN STEP\t2026-11-07T11:51:32.41Z ##[error]mikefarah/yq v4.55.0 is out; the Dockerfile pins v4.54.2 (update YQ with the tag and its commit)\n'
  printf 'pins\tUNKNOWN STEP\t2026-11-07T11:51:32.42Z ##[error]Process completed with exit code 1.\n'
} > "$FRESH_LOG"

img="$WORK/img"
imgrepo "$img" "# syntax=docker/dockerfile:1
FROM --platform=\$BUILDPLATFORM golang:1.27-trixie@$G_OLD AS build
ARG YQ_VERSION=v4.54.2
FROM --platform=\$BUILDPLATFORM maven:3.9.16-eclipse-temurin-21@$M_OLD AS jvm
FROM debian:trixie-slim@$D_OLD AS builder
FROM scratch AS checksums
FROM debian:trixie-slim@$D_OLD AS final"
(
  docker() { "$imgbin/docker" "$@"; }
  PENDING="$WORK/img-pending.json"; DRY_RUN=false; OWNER=owner
  changelog_line() { real_changelog_line "$@"; }
  gh() { case "$1 $2" in "run view") cat "$FRESH_LOG" ;; *) return 1 ;; esac; }
  NOTES=()
  image_repo_pass "$img" kubectl-docker 42369927826
  printf 'changed=%s noted=%s\n' "$IMG_CHANGED" "$IMG_NOTED"
  printf 'NOTE %s\n' "${NOTES[@]}"
) > "$WORK/img.out" 2>&1
out="$(cat "$WORK/img.out")"
remote_df="$(git -C "$img.git" show main:Dockerfile)"
same "the debian pin moved on both FROM lines that carry it" "2" "$(grep -c "debian:trixie-slim@$D_NEW" <<<"$remote_df")"
same "and the old debian digest is gone" "0" "$(grep -c "$D_OLD" <<<"$remote_df")"
case "$remote_df" in *"golang:1.27-trixie@$G_NEW AS build"*) ok "golang moved: Go changed only on a platform the fleet does not build" ;; *) no "golang did not move: $remote_df" ;; esac
case "$remote_df" in *"maven:3.9.16-eclipse-temurin-21@$M_OLD AS jvm"*) ok "the maven pin stays: its JDK moved" ;; *) no "a JDK move was applied: $remote_df" ;; esac
case "$remote_df" in *"ARG YQ_VERSION=v4.54.2"*) ok "the tool version is left alone" ;; *) no "the yq pin was touched: $remote_df" ;; esac
case "$out" in *"different toolchain inside (JAVA_VERSION=jdk-21.0.12+8 -> JAVA_VERSION=jdk-21.0.13+11)"*"Needs a human"*) ok "the refusal names the JDK it moved from and to" ;; *) no "the JDK refusal was not said: $out" ;; esac
case "$out" in *"mikefarah/yq v4.55.0 is out"*"needs a human"*) ok "the tool release in the log is a person's, and named" ;; *) no "the yq line was lost: $out" ;; esac
same "the digest line in the log is not handed to a person" "0" "$(grep -c 'is now sha256.*needs a human' <<<"$out")"
same "nor is the step's exit" "0" "$(grep -c 'Process completed' <<<"$out")"
# shellcheck disable=SC2016  # a literal ${name}, the unexpanded echo
same "nor the echo the step printed" "0" "$(grep -c '\${name}' <<<"$out")"
case "$out" in *"changed=1 noted=1"*) ok "the pass says it changed something" ;; *) no "flags: $out" ;; esac
same "one commit was pushed to main" "1" "$(git -C "$img.git" rev-list --count main~1..main)"
same "its message says what it is" "fix(security): refresh base image digests" "$(git -C "$img.git" log -1 --format=%s main)"
same "no tag: a rebuilt base is not a release" "" "$(git -C "$img.git" tag)"
remote_cl="$(git -C "$img.git" show main:CHANGELOG.md)"
same "the CHANGELOG carries one Security line per refreshed image" "2" "$(sed -n '/^## \[Unreleased\]/,/^## \[1/p' <<<"$remote_cl" | grep -c 'was rebuilt upstream')"
case "$remote_cl" in *"### Security"*"golang:1.27-trixie"*"the same toolchain inside (\`GOLANG_VERSION=1.27.3\`)"*) ok "the golang line names the Go it still has" ;; *) no "the golang line: $remote_cl" ;; esac
case "$(grep 'debian:trixie-slim' <<<"$remote_cl")" in *"toolchain"*) no "the debian line claims a toolchain it does not declare" ;; *) ok "the debian line claims no toolchain" ;; esac
case "$remote_cl" in *"## [1.0.1] - 2026-11-05"*) ok "the released sections are untouched" ;; *) no "a released section moved: $remote_cl" ;; esac
row="$(jq -c '.[0] | {repo, wf, kind, sha}' "$WORK/img-pending.json" 2>/dev/null)"
same "the push is in the pending ledger, judged by publish.yml" \
  "{\"repo\":\"kubectl-docker\",\"wf\":\"publish.yml\",\"kind\":\"image-digest\",\"sha\":\"$(git -C "$img.git" rev-parse main)\"}" "$row"

echo "== an image refresh that cannot be read is refused, never guessed"
img2="$WORK/img2"
imgrepo "$img2" "FROM --platform=\$BUILDPLATFORM golang:1.27-bookworm@$B_OLD AS tools
FROM nowhere/gone:1@$D_OLD AS gone
FROM debian@$D_OLD AS bare"
(
  docker() { "$imgbin/docker" "$@"; }; PENDING="$WORK/img2-pending.json"; DRY_RUN=false; OWNER=owner
  gh() { return 1; }
  NOTES=()
  image_repo_pass "$img2" os-shell-docker 1
  printf 'changed=%s noted=%s\n' "$IMG_CHANGED" "$IMG_NOTED"
  printf 'NOTE %s\n' "${NOTES[@]}"
) > "$WORK/img2.out" 2>&1
out="$(cat "$WORK/img2.out")"
case "$out" in *"golang:1.27-bookworm was repushed"*"could not be read from both digests"*"needs a human"*) ok "an old digest whose config is gone is refused" ;; *) no "an unreadable toolchain: $out" ;; esac
case "$out" in *"nowhere/gone:1 did not resolve"*"needs a human"*) ok "a tag that does not resolve is a person's" ;; *) no "a dead tag: $out" ;; esac
case "$out" in *"debian@$D_OLD is pinned by digest with no tag to follow"*) ok "a digest with no tag is not followed to latest" ;; *) no "a bare digest: $out" ;; esac
case "$out" in *"changed=0 noted=1"*) ok "nothing changed, and the reasons are said" ;; *) no "flags: $out" ;; esac
same "nothing was pushed" "1" "$(git -C "$img2.git" rev-list --count main)"
same "and nothing is pending" "no" "$([ -s "$WORK/img2-pending.json" ] && echo yes || echo no)"

echo "== a registry that does not answer is not checked, never unpublished or current"
rd() { resolve_digest "$1"; echo "rc=$? digest=$RESOLVED_DIGEST why=$RESOLVE_WHY"; }
out="$(rd server/app:19.4.0-ee.0)"
case "$out" in "rc=0 digest=$NEWDG_A why=") ok "a tag the registry names resolves to its digest" ;; *) no "a resolving tag: $out" ;; esac
out="$(rd vendor/ghost:9.9.9)"
case "$out" in "rc=3 digest= why="*"not found"*) ok "a tag the registry says is not there is unpublished (3)" ;; *) no "a missing tag: $out" ;; esac
out="$(rd limited/app:1.0)"
case "$out" in "rc=4 digest= why="*"429 Too Many Requests"*) ok "a 429 is not checked (4), with the registry's reason" ;; *) no "a 429: $out" ;; esac
# shellcheck disable=SC2329  # resolve_digest calls the docker below
out="$( (docker() { return 1; }; rd any/image:1) )"
case "$out" in "rc=4 digest= why=docker exited 1 and said nothing") ok "a failure with no message is not checked either, and says so" ;; *) no "a silent failure: $out" ;; esac
# shellcheck disable=SC2329  # resolve_digest calls the docker below
out="$( (docker() { echo '{}'; }; rd any/image:1) )"
case "$out" in "rc=4 digest= why=the registry answered without a digest") ok "an answer without a digest is not checked, not current" ;; *) no "an empty answer: $out" ;; esac

dir3="$WORK/repo3"; mkdir -p "$dir3"
# shellcheck disable=SC2016  # the ${...} belongs to the compose file
printf 'x-images:\n  app: &app-image ${APP_IMAGE_TAG:-limited/app:${APP_IMAGE_VERSION:-2.0.0@%s}}\n' "$OLDDG_A" > "$dir3/stack.yml"
out="$(
  dir="$dir3"; composes=("$dir3/stack.yml"); NOTES=(); PREPARED_THIS_RUN=()
  major_branch "2.0.0" "3.0.0" >/dev/null 2>&1
  printf 'NOTE %s\n' "${NOTES[@]+"${NOTES[@]}"}"
)"
case "$out" in *"limited/app:3.0.0 not checked, the registry did not answer"*"429"*"nothing prepared"*) ok "a major that cannot be checked says not checked" ;; *) no "a 429 on a major: $out" ;; esac
case "$out" in *"does not resolve yet"*) no "a 429 was reported as an unpublished tag: $out" ;; *) ok "and never as an unpublished tag" ;; esac

img4="$WORK/img4"
imgrepo "$img4" "FROM limited/base:1@$D_OLD"
(
  docker() { "$imgbin/docker" "$@"; }; PENDING="$WORK/img4-pending.json"; DRY_RUN=false; OWNER=owner
  gh() { return 1; }
  NOTES=()
  image_repo_pass "$img4" os-shell-docker 1
  printf 'changed=%s noted=%s\n' "$IMG_CHANGED" "$IMG_NOTED"
  printf 'NOTE %s\n' "${NOTES[@]}"
) > "$WORK/img4.out" 2>&1
out="$(cat "$WORK/img4.out")"
case "$out" in *"limited/base:1 not checked, the registry did not answer"*"next run asks again"*) ok "an image base the registry would not answer for is not checked" ;; *) no "a 429 on an image repo: $out" ;; esac
case "$out" in *"dead tag"*|*"is current"*) no "a 429 was read as dead or current: $out" ;; *) ok "and neither dead nor current" ;; esac
same "nothing was pushed for it" "1" "$(git -C "$img4.git" rev-list --count main)"

echo "== a dry run writes nothing, and a current Dockerfile is not a finding of its own"
img3="$WORK/img3"
imgrepo "$img3" "FROM debian:trixie-slim@$D_OLD AS final"
(
  docker() { "$imgbin/docker" "$@"; }; PENDING="$WORK/img3-pending.json"; DRY_RUN=true; OWNER=owner
  gh() { return 1; }
  NOTES=()
  image_repo_pass "$img3" jmx-exporter-docker 1
  printf 'changed=%s noted=%s\n' "$IMG_CHANGED" "$IMG_NOTED"
  printf 'NOTE %s\n' "${NOTES[@]}"
  git -C "$img3" status --porcelain
  # Already current: no refresh, and the pass itself says so once.
  DRY_RUN=false; NOTES=()
  printf 'FROM debian:trixie-slim@%s AS final\n' "$D_NEW" > "$img3/Dockerfile"
  image_repo_pass "$img3" jmx-exporter-docker 1
  printf 'current changed=%s noted=%s\n' "$IMG_CHANGED" "$IMG_NOTED"
  printf 'CURRENT %s\n' "${NOTES[@]}"
) > "$WORK/img3.out" 2>&1
out="$(cat "$WORK/img3.out")"
case "$out" in *"would refresh debian:trixie-slim"*) ok "a dry run says what it would refresh" ;; *) no "dry run: $out" ;; esac
case "$out" in *" M "*|*"M Dockerfile"*|*"M CHANGELOG"*) no "a dry run edited the tree: $out" ;; *) ok "and edits nothing" ;; esac
case "$out" in *"current changed=0 noted=0"*) ok "a current Dockerfile changes nothing" ;; *) no "current: $out" ;; esac
case "$out" in *"CURRENT jmx-exporter-docker: freshness is red but nothing in its Dockerfile was auto-fixable"*"needs a human"*) ok "and a red check with nothing to fix still reaches a person" ;; *) no "silent red: $out" ;; esac

echo "== what an image declares as its toolchain"
tc() { ( docker() { "$imgbin/docker" "$@"; }; image_toolchain "$1" ) && echo "rc=0" || echo "rc=1"; }
same "an index: only the platforms the fleet builds" $'linux/amd64 GOLANG_VERSION=1.27.3\nlinux/arm64 GOLANG_VERSION=1.27.3\nrc=0' "$(tc "golang:1.27-trixie@$G_NEW")"
same "one platform: its config alone" $'image GOLANG_VERSION=1.27.3\nrc=0' "$(tc "single/go:1@$G_NEW")"
same "an image declaring none is read as none" "rc=0" "$(tc "debian:trixie-slim@$D_NEW")"
same "an index without amd64 or arm64 is unreadable, not empty" "rc=1" "$(tc "other/arch:1@$G_NEW")"
same "a digest the registry will not describe is unreadable" "rc=1" "$(tc "golang:1.27-bookworm@$B_OLD")"

echo "== a green image build is the delivery, a red one is reverted"
judge() {            # judge <conclusion> -> what settle_pending did with an image-digest row on $img
  (
    sha="$(git -C "$img.git" rev-parse main)"
    PENDING="$(mktemp)"; REPORT="$(mktemp)"; DRY_RUN=false; STALE_HOURS=12; OWNER=owner
    REFRESHED=0; HEALED=(); CALLS="$(mktemp)"; RUNS="$(mktemp)"
    printf '[{"repo":"kubectl-docker","sha":"%s","wf":"publish.yml","kind":"image-digest","pushed_at":"%s"}]\n' \
      "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PENDING"
    printf '[{"headBranch":"main","createdAt":"2026-11-08T10:00:00Z","headSha":"%s","status":"completed","conclusion":"%s","databaseId":7}]\n' \
      "$sha" "$1" > "$RUNS"
    gh() {
      printf '%s\n' "$*" >> "$CALLS"
      case "$1 $2" in
        "run list") cat "$RUNS" ;;
        "run view") echo "Build and publish" ;;
        "workflow run") return 0 ;;
        "api repos/owner/kubectl-docker/contents/.github/workflows/freshness.yml") return 0 ;;
        *) return 1 ;;
      esac
    }
    sleep() { :; }
    cut_release() { echo "CUT $*" >> "$CALLS"; }
    workdir_for() { echo "$img"; }
    NOTES=()
    settle_pending >/dev/null 2>&1
    printf 'NOTE %s\n' "${NOTES[@]+"${NOTES[@]}"}"
    sed 's/^/CALL /' "$CALLS"
    printf 'LEDGER %s\n' "$(jq -c 'length' "$PENDING")"
    rm -f "$PENDING" "$REPORT" "$CALLS" "$RUNS"
  )
}
out="$(judge success)"
case "$out" in *"CALL CUT"*) no "a release was cut for a rebuilt base" ;; *) ok "green cuts no release" ;; esac
case "$out" in *"publish.yml is green on it"*"no release for a rebuilt base"*) ok "and says the green build is the delivery" ;; *) no "green: $out" ;; esac
case "$out" in *"CALL workflow run freshness.yml --repo owner/kubectl-docker --ref main"*) ok "the freshness check is asked again" ;; *) no "freshness not rerun: $out" ;; esac
case "$out" in *"needs a human"*) no "a green image refresh asked a person: $out" ;; *) ok "nobody is asked" ;; esac
case "$out" in *"LEDGER 0"*) ok "the row is settled" ;; *) no "the row stayed: $out" ;; esac
out="$(judge failure)"
case "$out" in *"CI answered 'failure' on the image-digest refresh — reverted, needs a human"*) ok "a red build is reverted and a person told" ;; *) no "red: $out" ;; esac
same "main is back on the old debian digest" "2" "$(git -C "$img.git" show main:Dockerfile | grep -c "debian:trixie-slim@$D_OLD")"
case "$out" in *"CALL CUT"*) no "a release was cut for a red build" ;; *) ok "and no release is cut" ;; esac


# THE WHOLE RUN, ON TWO TEMPLATES. The refresh pass and the patch-line pass
# are the script's body, not functions, so the body is what runs here. A fake
# gh serves Ollama, red with Open WebUI's own sentence about 0.13.2, and
# Mailu, green with ten digest checks and no version check; a fake docker
# resolves digests; a fake curl is the registries' tag lists; git clones from
# local remotes. Once dry, once for real.
e2e="$WORK/e2e"; mkdir -p "$e2e/bin"
E2E_RED=ollama-traefik-letsencrypt-docker-compose
E2E_GREEN=mailu-traefik-letsencrypt-docker-compose
dgn() { printf 'sha256:%064d' "$1"; }
e2e_remotes() {      # fresh remotes for both templates; prints nothing
  rm -rf "$e2e/remote" "$e2e/src-red" "$e2e/src-green"; mkdir -p "$e2e/remote"
  git init -q -b main "$e2e/src-red"
  printf '%s\n' 'x-images:' \
    "  traefik: \${TRAEFIK_IMAGE_TAG:-traefik:\${TRAEFIK_IMAGE_VERSION:-3.7@$(dgn 4)}}" \
    "  ollama: \${OLLAMA_IMAGE_TAG:-ollama/ollama:\${OLLAMA_IMAGE_VERSION:-0.40.15@$(dgn 7)}}" \
    "  webui: \${WEBUI_IMAGE_TAG:-ghcr.io/open-webui/open-webui:\${WEBUI_IMAGE_VERSION:-0.12.0@$(dgn 1)}}" \
    > "$e2e/src-red/$E2E_RED.yml"
  printf '%s\n' '# OLLAMA_IMAGE_TAG=ollama/ollama:0.33.2@sha256:…' \
    '# WEBUI_IMAGE_TAG=ghcr.io/open-webui/open-webui:0.12.0@sha256:…' '# WEBUI_IMAGE_VERSION=0.12.0' > "$e2e/src-red/.env.example"
  git init -q -b main "$e2e/src-green"
  printf '%s\n' 'x-images:' \
    "  admin: \${ADMIN_IMAGE_TAG:-ghcr.io/mailu/admin:\${ADMIN_IMAGE_VERSION:-2024.06.67@$(dgn 5)}}" \
    "  redis: \${REDIS_IMAGE_TAG:-redis:\${REDIS_IMAGE_VERSION:-7.4@$(dgn 4)}}" \
    > "$e2e/src-green/$E2E_GREEN.yml"
  local r
  for r in red green; do
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n' > "$e2e/src-$r/CHANGELOG.md"
    git -C "$e2e/src-$r" add -A && git -C "$e2e/src-$r" -c user.name=t -c user.email=t@t commit -qm init
  done
  git clone -q --bare "$e2e/src-red" "$e2e/remote/$E2E_RED"
  git clone -q --bare "$e2e/src-green" "$e2e/remote/$E2E_GREEN"
}
e2e_remotes
printf 'Check pinned images for upstream drift\tUNKNOWN STEP\t2026-11-08T06:00:01Z ##[error]Open WebUI pin is behind: pinned minor 0.12, latest release is 0.13.2\n' > "$e2e/fresh.log"
printf '[url "file://%s/remote/"]\n\tinsteadOf = https://github.com/owner/\n[user]\n\tname = t\n\temail = t@t\n' "$e2e" > "$e2e/gitconfig"
cat > "$e2e/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$E2E_DIR/calls"
sha() { git -C "$E2E_DIR/remote/$1" rev-parse main; }
case "$*" in
  "api user/repos"*) printf '%s\n%s\n' "$E2E_RED" "$E2E_GREEN" ;;
  "api repos/owner/"*"/contents/.github/workflows/freshness.yml"*) echo '{}' ;;
  "api repos/owner/$E2E_RED/commits/main"*) sha "$E2E_RED" ;;
  "api repos/owner/$E2E_GREEN/commits/main"*) sha "$E2E_GREEN" ;;
  "run list --repo owner/$E2E_RED --workflow freshness.yml"*) printf '[{"databaseId":7,"event":"schedule","conclusion":"failure","status":"completed","headSha":"%s"}]\n' "$(sha "$E2E_RED")" ;;
  "run list --repo owner/$E2E_GREEN --workflow freshness.yml"*) printf '[{"databaseId":8,"event":"schedule","conclusion":"success","status":"completed","headSha":"%s"}]\n' "$(sha "$E2E_GREEN")" ;;
  "run list"*) echo '[]' ;;
  "run view 7"*"--log"*) cat "$E2E_DIR/fresh.log" ;;
esac
exit 0
GH
cat > "$e2e/bin/docker" <<'DK'
#!/bin/bash
echo "docker $*" >> "$E2E_DIR/calls"
case "$4" in
  *open-webui:0.12.0) n=1 ;; *open-webui:0.12.5) n=2 ;; *open-webui:0.13.2) n=3 ;;
  *mailu/admin:2024.06.67) n=5 ;; *mailu/admin:2024.06.68) n=6 ;;
  *ollama/ollama:0.40.15) n=7 ;; *ollama/ollama:0.40.16) n=8 ;;
  *) n=4 ;;
esac
printf '{"digest":"sha256:%064d"}\n' "$n"
DK
cat > "$e2e/bin/curl" <<'CU'
#!/bin/bash
o="" d=""; a=" $* "
while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift 2 ;; -D) d="$2"; shift 2 ;; *) shift ;; esac; done
[[ "$a" == *" --config - "* ]] || exit 22
url="$(sed -nE 's/^url = "(.*)"$/\1/p')"
echo "curl $url" >> "$E2E_DIR/calls"
case "$url" in
  https://ghcr.io/v2/open-webui/open-webui/tags/list*) t='["0.12.0","0.12.1","0.12.5","0.12.5-cuda","0.13.0","0.13.2"]' ;;
  https://ghcr.io/v2/mailu/admin/tags/list*) t='["2024.06.66","2024.06.67","2024.06.68","2024.06.68-arm64","master"]' ;;
  https://registry-1.docker.io/v2/ollama/ollama/tags/list*) t='["0.40.15","0.40.16","0.40.16-rocm","0.41.0"]' ;;
  *) printf 'HTTP/1.1 404\r\n\r\n' > "$d"; : > "$o"; printf 404; exit 0 ;;
esac
printf 'HTTP/1.1 200\r\n\r\n' > "$d"; printf '{"tags":%s}\n' "$t" > "$o"; printf 200
CU
chmod +x "$e2e/bin/gh" "$e2e/bin/docker" "$e2e/bin/curl"
e2e_run() {          # e2e_run <true|false> [ledger] -> the script's output; the exit code in $e2e/rc
  printf '%s\n' "${2:-[]}" > "$e2e/pending.json"; : > "$e2e/calls"
  # shellcheck disable=SC2031  # the outer PATH is meant; the image tests change it inside their own subshell only
  (cd "$e2e" && env -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u GITHUB_WORKSPACE \
    "PATH=$e2e/bin:$PATH" GH_TOKEN=dummy DRY_RUN="$1" FLEET_OWNER=owner \
    FLEET_PENDING="$e2e/pending.json" GIT_CONFIG_GLOBAL="$e2e/gitconfig" GITHUB_STEP_SUMMARY='' \
    E2E_DIR="$e2e" E2E_RED="$E2E_RED" E2E_GREEN="$E2E_GREEN" \
    bash "$ROOT/scripts/fleet-triage.sh" 2>&1; echo "$?" > "$e2e/rc")
}
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — not in the output: $3"$'\n'"$2" ;; esac; }
red_main0="$(git -C "$e2e/remote/$E2E_RED" rev-parse main)"; green_main0="$(git -C "$e2e/remote/$E2E_GREEN" rev-parse main)"
e2e_out="$(e2e_run true)"
same "the dry run finishes" "0" "$(cat "$e2e/rc")"
has "the alarm's own minor is still handled as before" "$e2e_out" \
  "$E2E_RED: would bump ghcr.io/open-webui/open-webui:0.12.0 -> ghcr.io/open-webui/open-webui:0.13.2@$(dgn 3)"
has "and the pinned line's patch is offered beside it" "$e2e_out" \
  "$E2E_RED: would bump ghcr.io/open-webui/open-webui:0.12.0 -> ghcr.io/open-webui/open-webui:0.12.5@$(dgn 2)"
has "a pin the alarm never named is moved within its line as well" "$e2e_out" \
  "$E2E_RED: would bump ollama/ollama:0.40.15 -> ollama/ollama:0.40.16@$(dgn 8)"
has "a green template's pin with no version check is moved within its line" "$e2e_out" \
  "$E2E_GREEN: would bump ghcr.io/mailu/admin:2024.06.67 -> ghcr.io/mailu/admin:2024.06.68@$(dgn 6)"
same "a pin on a line tag (redis:7.4) sends nobody to a registry" "0" "$(grep -c '^curl .*library/redis' "$e2e/calls")"
same "a dry run pushes nothing to the red template" "$red_main0" "$(git -C "$e2e/remote/$E2E_RED" rev-parse main)"
same "nor to the green one" "$green_main0" "$(git -C "$e2e/remote/$E2E_GREEN" rev-parse main)"

e2e_out="$(e2e_run false)"
same "the real run finishes" "0" "$(cat "$e2e/rc")"
same "Open WebUI's patch is on main" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show "main:$E2E_RED.yml" | grep -c "open-webui:\${WEBUI_IMAGE_VERSION:-0.12.5@$(dgn 2)}")"
same "its minor waits on a branch" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show "bump/0.13.2:$E2E_RED.yml" | grep -c "open-webui:\${WEBUI_IMAGE_VERSION:-0.13.2@$(dgn 3)}")"
same "and the branch did not take the patch with it" "0" \
  "$(git -C "$e2e/remote/$E2E_RED" show "bump/0.13.2:$E2E_RED.yml" | grep -c '0\.12\.5')"
same "the example's whole pin moves with it" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show main:.env.example | grep -cxF '# WEBUI_IMAGE_TAG=ghcr.io/open-webui/open-webui:0.12.5@sha256:…')"
same "and so does its version line" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show main:.env.example | grep -cxF '# WEBUI_IMAGE_VERSION=0.12.5')"
same "on the branch, the example names the minor" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show bump/0.13.2:.env.example | grep -cxF '# WEBUI_IMAGE_TAG=ghcr.io/open-webui/open-webui:0.13.2@sha256:…')"
same "an example that was already stale is not guessed at" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show main:.env.example | grep -cxF '# OLLAMA_IMAGE_TAG=ollama/ollama:0.33.2@sha256:…')"
same "Ollama moved within its line in the same commit" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" show "main:$E2E_RED.yml" | grep -c "ollama/ollama:\${OLLAMA_IMAGE_VERSION:-0.40.16@$(dgn 8)}")"
same "Mailu's admin image is on main at 2024.06.68" "1" \
  "$(git -C "$e2e/remote/$E2E_GREEN" show "main:$E2E_GREEN.yml" | grep -c "mailu/admin:\${ADMIN_IMAGE_VERSION:-2024.06.68@$(dgn 6)}")"
same "its redis pin is untouched" "1" \
  "$(git -C "$e2e/remote/$E2E_GREEN" show "main:$E2E_GREEN.yml" | grep -c "redis:\${REDIS_IMAGE_VERSION:-7.4@$(dgn 4)}")"
same "the commit says what moved it" "fix(security): move pins to the newest patch of their own line" \
  "$(git -C "$e2e/remote/$E2E_GREEN" log -1 --format=%s main)"
bt='`'
same "the changelog says it under Unreleased" "1" \
  "$(git -C "$e2e/remote/$E2E_GREEN" show main:CHANGELOG.md | grep -cF "ghcr.io/mailu/admin:2024.06.67$bt moved to ${bt}ghcr.io/mailu/admin:2024.06.68$bt")"
same "both pushes wait in the ledger for the next run's verdict" \
  "$E2E_GREEN digest Deployment Verification|$E2E_RED digest Deployment Verification" \
  "$(jq -r 'sort_by(.repo) | map("\(.repo) \(.kind) \(.wf)") | join("|")' "$e2e/pending.json")"
same "each row names the commit on main" \
  "$(git -C "$e2e/remote/$E2E_GREEN" rev-parse main) $(git -C "$e2e/remote/$E2E_RED" rev-parse main)" \
  "$(jq -r 'sort_by(.repo) | map(.sha) | join(" ")' "$e2e/pending.json")"
same "a template pushed by the refresh pass is not pushed twice" "1" \
  "$(git -C "$e2e/remote/$E2E_RED" rev-list --count "$red_main0..main")"
has "and the report says the green one was pushed for its line" "$e2e_out" "$E2E_GREEN: pushed patch-line refresh"

# A refresh pushed and not judged yet keeps its repository out of the pass:
# the ledger has one row per repository, and a second push would inherit it.
e2e_remotes
green_main0="$(git -C "$e2e/remote/$E2E_GREEN" rev-parse main)"
waiting="$(printf '[{"repo":"%s","sha":"%s","wf":"Deployment Verification","kind":"digest","pushed_at":"%s"}]' \
  "$E2E_GREEN" "$green_main0" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
e2e_out="$(e2e_run false "$waiting")"
same "a run with an unjudged push finishes" "0" "$(cat "$e2e/rc")"
same "that repository's main is not touched" "$green_main0" "$(git -C "$e2e/remote/$E2E_GREEN" rev-parse main)"
same "and its row is still the one waiting" "$green_main0" \
  "$(jq -r --arg r "$E2E_GREEN" '.[] | select(.repo == $r) | .sha' "$e2e/pending.json")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
