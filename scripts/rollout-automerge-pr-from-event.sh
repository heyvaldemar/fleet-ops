#!/usr/bin/env bash
# rollout-automerge-pr-from-event.sh - give every repository's Dependabot
# automerge the lookup in scripts/automerge_lookup.py: the pull request from
# the event, checked against the pull request itself, and red when a run
# Dependabot started has none to be found.
#
# WHAT WAS WRONG. On 2026-11-11 siyuan-docker-compose#8 went green and the
# automerge asked GitHub which pull request carried the commit. Five minutes
# after the pull request opened the answer was empty, the job said "nothing
# to do" and went green, and the update waited sixty hours until the fleet
# heartbeat named it (fleet-ops#54). Every one of the fleet's automerge files
# found its pull request that way.
#
# WHAT IS LEFT ALONE.
#   - A repository whose automerge waits only for workflows that never run on
#     a pull request. Its job is skipped on every run by design: the
#     flagship's e2e runs on main, on a schedule and by hand, and its
#     Dependabot updates are merged by hand after e2e on a branch. Changing
#     its file would change nothing it does, and a push there starts an e2e.
#   - fleet-ops: the public copy is published from fleet-ops-private and a
#     commit made there directly is reverted by the next publish. It gets
#     this with the private copy's own file.
#   - The repositories named in HOLD below, each with its reason. A push of
#     this file must not cut or publish anything: the image repositories
#     publish on every push to main, so they wait for their next publish.
#   - Private repositories, unless VISIBILITY=private: their runs are billed,
#     so they go in a wave of their own.
#
# GUARDS. The edit must touch dependabot-automerge.yml and nothing else, by
# exactly the line counts the change has everywhere (a mass push once carried
# an empty file into 31 repositories), and actionlint, with shellcheck on the
# step's script, must pass on the edited file. A repository failing either is
# skipped and named, never pushed.
#
#   DRY_RUN=true scripts/rollout-automerge-pr-from-event.sh   say what would change
#   scripts/rollout-automerge-pr-from-event.sh                one sequential wave
set -uo pipefail
# shellcheck source=scripts/git-auth.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-auth.sh"  # GH_TOKEN reaches git by environment, never in a URL

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
# public is the wave; private is its own, smaller one: those runs are billed.
VISIBILITY="${VISIBILITY:-public}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
F=.github/workflows/dependabot-automerge.yml

# Repository -> why it waits. Revisit each on its date.
HOLD="fleet-ops	published from fleet-ops-private; never committed to directly
aws-eks-reference-platform	its pins are held until its scheduled cloud run of 2026-11-18; after that, run this again
aws-kubectl-docker	publish.yml rebuilds, pushes and signs the image on every push to main, which is a release; it gets this with its next intended publish
jmx-exporter-docker	publish.yml rebuilds, pushes and signs the image on every push to main, which is a release; it gets this with its next intended publish
kubectl-docker	publish.yml rebuilds, pushes and signs the image on every push to main, which is a release; it gets this with its next intended publish
minio-client-docker	publish.yml rebuilds, pushes and signs the image on every push to main, which is a release; it gets this with its next intended publish
os-shell-docker	publish.yml rebuilds, pushes and signs the image on every push to main, which is a release; it gets this with its next intended publish
heyvaldemar-com	the site deploys on every push to main and has its own owner; the change goes to it there"

# What the change is, counted once on a known file: every repository must
# show exactly this, or it is not the change this script makes.
expect="$(cp "$HERE/../tests/fixtures/automerge/siyuan-docker-compose.yml" "$WORKDIR/probe.yml" \
  && python3 -I "$HERE/automerge_lookup.py" "$WORKDIR/probe.yml" \
  && git diff --no-index --numstat "$HERE/../tests/fixtures/automerge/siyuan-docker-compose.yml" "$WORKDIR/probe.yml" | awk '{print $1 "\t" $2}')"
[ -n "$expect" ] || { echo "the change could not be measured on the fixture" >&2; exit 1; }

# Does any workflow this automerge waits for run on a pull request?
gate_runs_on_prs() {   # repo dir -> 0 yes, 1 no (inert by design)
  python3 -I - "$1" <<'PY'
import os, re, sys
d = os.path.join(sys.argv[1], ".github", "workflows")
bodies = {}
for n in os.listdir(d):
    if n.endswith((".yml", ".yaml")):
        bodies[n] = open(os.path.join(d, n), encoding="utf-8").read()
am = bodies.get("dependabot-automerge.yml", "")
m = re.search(r"^\s+workflow_run:\s*\n\s+workflows:\s*\[([^\]]*)\]", am, re.M)
wanted = {w.strip().strip("\"'") for w in m.group(1).split(",")} if m else set()
for body in bodies.values():
    t = re.search(r"^name:\s*(.+?)\s*$", body, re.M)
    if not t or t.group(1).strip("\"'") not in wanted:
        continue
    on = re.search(r"^on:\s*(.*?)(?=^\S)", body, re.M | re.S)
    block = on.group(0) if on else ""
    if re.search(r"\bpull_request(_target)?\b", block):
        sys.exit(0)
sys.exit(1)
PY
}

changed=0 already=0 skipped=0 inert=0
report=""
note() { report="$report\n  $1"; }

for repo in $(gh repo list "$OWNER" --no-archived --source --visibility "$VISIBILITY" -L 300 --json name -q '.[].name' | sort); do
  why="$(printf '%s\n' "$HOLD" | awk -F'\t' -v r="$repo" '$1 == r {print $2}')"
  if [ -n "$why" ]; then
    skipped=$((skipped+1)); note "$repo: held — $why"; continue
  fi
  dir="$WORKDIR/$repo"
  if ! git clone -q --depth 1 "https://github.com/$OWNER/$repo" "$dir" 2>/dev/null; then
    skipped=$((skipped+1)); note "$repo: clone failed"; continue
  fi
  [ -f "$dir/$F" ] || continue
  if ! gate_runs_on_prs "$dir"; then
    inert=$((inert+1)); note "$repo: its automerge waits only for workflows that never run on a pull request — inert by design, left alone"
    continue
  fi

  python3 -I "$HERE/automerge_lookup.py" "$dir/$F"; rc=$?
  case "$rc" in
    0) ;;
    1) already=$((already+1)); continue ;;
    *) skipped=$((skipped+1)); note "$repo: $F is not the shape this rollout knows"; continue ;;
  esac

  got="$(git -C "$dir" diff --numstat | awk '{print $1 "\t" $2 "\t" $3}')"
  if [ "$got" != "$expect	$F" ]; then
    skipped=$((skipped+1)); note "$repo: the edit is not the expected one ($(printf '%s' "$got" | tr '\t\n' ' |'))"; continue
  fi
  if ! docker run --rm -v "$dir:/mnt" -w /mnt rhysd/actionlint:1.7.12 -no-color "$F" >/dev/null 2>&1; then
    skipped=$((skipped+1)); note "$repo: actionlint refused the edited file"; continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "would change $repo"
    changed=$((changed+1))
    continue
  fi

  git -C "$dir" -c user.name="${GIT_AUTHOR:-Vladimir Mikhalev}" \
      -c user.email="${GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}" \
      commit -qam "ci: automerge takes its pull request from the event, checks author and head, and fails when it finds none"
  if git -C "$dir" push -q origin HEAD:main 2>/dev/null; then
    echo "changed $repo"
    changed=$((changed+1))
  else
    skipped=$((skipped+1)); note "$repo: push refused"
  fi
done

printf '\n%s %d, already done %d, inert by design %d, skipped %d\n' \
  "$([ "$DRY_RUN" = true ] && echo 'would change' || echo changed)" "$changed" "$already" "$inert" "$skipped"
[ -n "$report" ] && printf 'not changed:%b\n' "$report"
exit 0
