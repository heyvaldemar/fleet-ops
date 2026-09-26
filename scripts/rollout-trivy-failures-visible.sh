#!/usr/bin/env bash
# rollout-trivy-failures-visible.sh - stop hiding a Trivy scan that could not
# finish, in every template that hides one.
#
# WHAT WAS WRONG. Sixty repositories carried `continue-on-error: true` on the
# Trivy job, under a comment saying findings surface in the Security tab rather
# than blocking CI. The first half of that is not what the flag was doing. The
# action's exit-code defaults to 0, so findings never failed the step in the
# first place; the only thing continue-on-error could hide was a scan that did
# not complete. And when the scan step fails, the SARIF upload step after it is
# skipped, so nothing reaches the Security tab either.
#
# Which is exactly what happened. blackmesa-server's image bakes the game in,
# Trivy's secret scanner walked a 257 MB .vpk, hit its own deadline, and the
# scan died. The run concluded success. Every watcher in this fleet reads run
# conclusions, so the triage saw green, the heartbeat saw green, and a security
# check sat broken and silent, producing no findings anywhere.
#
# WHAT THIS CHANGES. continue-on-error comes off, and exit-code 0 goes in
# explicitly. The behaviour for findings is identical, and now it is stated in
# the file instead of inherited from an action default that could move. The
# behaviour for a broken scanner is the opposite of what it was: the run goes
# red and the triage reports it, which is the whole arrangement this fleet is
# built on.
#
# Measured blast radius before running it: one repository was red, and it was
# fixed first. A rollout whose consequences have not been counted is a wave.
set -uo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

changed=0 skipped=0 already=0
skips=""

transform() {   # file -> 0 changed, 1 already right, 2 shape not recognised
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")

# The job block that actually runs Trivy. Jobs sit at two spaces under "jobs:",
# so the block runs from its header to the next line at that indentation.
start = None
for i, l in enumerate(lines):
    if re.match(r"^  [A-Za-z0-9_-]+:\s*$", l):
        start = i
    if "aquasecurity/trivy-action" in l and start is not None:
        job_start = start
        break
else:
    sys.exit(2)

job_end = len(lines)
for i in range(job_start + 1, len(lines)):
    if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i]):
        job_end = i
        break

block = lines[job_start:job_end]

# 1. continue-on-error, and the comment that explained it.
coe = [i for i, l in enumerate(block) if re.match(r"^\s*continue-on-error:\s*true\s*$", l)]
if len(coe) > 1:
    sys.exit(2)
did = False
if coe:
    i = coe[0]
    drop = {i}
    if i and re.match(r"^\s*#.*(block CI|Security tab)", block[i - 1]):
        drop.add(i - 1)
    block = [l for j, l in enumerate(block) if j not in drop]
    did = True

# 2. exit-code, stated rather than inherited.
if not any(re.match(r"^\s*exit-code:", l) for l in block):
    anchor = [i for i, l in enumerate(block) if re.match(r"^\s*ignore-unfixed:\s*true\s*$", l)]
    if len(anchor) != 1:
        sys.exit(2)
    i = anchor[0]
    pad = re.match(r"^(\s*)", block[i]).group(1)
    block[i + 1:i + 1] = [
        pad + "# FINDINGS DO NOT FAIL THIS STEP; A SCAN THAT CANNOT FINISH DOES.",
        pad + "# Stated here rather than left to the action's default, because",
        pad + "# this job no longer carries continue-on-error and the difference",
        pad + "# now decides whether a red run means a new CVE upstream or a",
        pad + "# scanner that died before it could report one.",
        pad + 'exit-code: "0"',
    ]
    did = True

if not did:
    sys.exit(1)
open(path, "w", encoding="utf-8").write("\n".join(lines[:job_start] + block + lines[job_end:]))
PY
}

for repo in $(gh repo list "$OWNER" --no-archived --source --visibility public -L 300 --json name -q '.[].name' | sort); do
  wf="$(gh api "repos/$OWNER/$repo/contents/.github/workflows" -q '.[].name' 2>/dev/null \
        | grep -iE 'verif' | head -1)"
  [ -n "$wf" ] || continue
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" || {
    skipped=$((skipped+1)); skips="$skips\n  $repo: clone failed"; continue; }
  f="$dir/.github/workflows/$wf"
  grep -q "aquasecurity/trivy-action" "$f" 2>/dev/null || continue

  transform "$f"; rc=$?
  case "$rc" in
    1) already=$((already+1)); continue ;;
    2) skipped=$((skipped+1)); skips="$skips\n  $repo: $wf is not the shape this rollout knows"; continue ;;
  esac

  # A workflow this edits and does not parse is worse than one it never
  # touched, so every file is linted before it is allowed to leave.
  if ! docker run --rm -v "$dir:/mnt" -w /mnt rhysd/actionlint:1.7.12 >/dev/null 2>&1; then
    skipped=$((skipped+1)); skips="$skips\n  $repo: actionlint refused the edited file"; continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "would change $repo/$wf"
    changed=$((changed+1))
    continue
  fi

  git -C "$dir" -c user.name="${GIT_AUTHOR:-Vladimir Mikhalev}" \
      -c user.email="${GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}" \
      commit -aqm "fix(ci): a Trivy scan that cannot finish now fails the run

continue-on-error was not keeping findings from blocking CI. The action's
exit-code defaults to 0, so findings never failed the step. The only thing the
flag could hide was a scan that did not complete, and when the scan step fails
the SARIF upload after it is skipped, so nothing reaches the Security tab
either.

blackmesa-server is where that showed: Trivy's secret scanner walked a 257 MB
game archive, hit its own deadline, and died. The run concluded success, every
watcher in this fleet reads run conclusions, and a security check sat broken
and silent.

exit-code 0 is now stated in the file rather than inherited, so the behaviour
for findings is unchanged and visible. A scanner that cannot finish goes red."
  if git -C "$dir" push -q origin HEAD:main 2>/dev/null; then
    echo "changed $repo/$wf"
    changed=$((changed+1))
  else
    skipped=$((skipped+1)); skips="$skips\n  $repo: push refused"
  fi
done

printf '\nchanged %d, already correct %d, skipped %d\n' "$changed" "$already" "$skipped"
[ -n "$skips" ] && printf 'skipped:%b\n' "$skips"
exit 0
