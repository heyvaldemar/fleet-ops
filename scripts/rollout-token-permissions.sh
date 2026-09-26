#!/bin/bash
# One-shot rollout: move the write permissions in dependabot-automerge.yml from
# the top of the file to the one job that needs them.
#
# WHAT IT FIXES, AND WHY IT IS NOT COSMETIC. A top-level `permissions:` block
# applies to every job in the workflow, so `contents: write` and
# `pull-requests: write` at the top hand write access to anything the file ever
# grows. OpenSSF Scorecard scores that as Token-Permissions 0/10 — measured on
# 2026-09-14 across the fleet: 83 of 94 public repositories carried it, and
# every one of those scored zero on that check. The profile advertises
# "commit-SHA-pinned GitHub Actions with per-job permissions" while this file
# did the opposite in almost every repository the reader would click into.
#
# The workflow has exactly one job, which does need both writes: it merges a
# Dependabot pull request after that repository's own verification went green.
# Nothing it does changes; what changes is that the grant stops applying to
# jobs that do not exist yet.
#
# Idempotent: a repository already carrying the job-level form is skipped.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# REST, not `gh repo list`: that command speaks GraphQL, which rejects
# fine-grained PATs with a 401 — and a silent empty list would produce a green
# run that had changed nothing. Hence the fail-fast below.
REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100" --paginate --jq '.[] | select(.archived|not) | select(.fork|not) | .name' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

CHANGED=0; SKIPPED=0; ODD=0
for repo in "${REPOS[@]}"; do
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || continue
  wf="$dir/.github/workflows/dependabot-automerge.yml"
  [ -f "$wf" ] || { rm -rf "$dir"; continue; }

  # The detection lives in python, not in grep: BSD grep has no -P, and a
  # rollout that silently matches nothing on the machine it is run from is the
  # worst possible outcome for a one-shot script.
  verdict="$(python3 - "$wf" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
if "permissions:\n  contents: write\n  pull-requests: write\n" in s:
    print("rewrite")
elif "permissions:\n  contents: read\n" in s and "    permissions:\n      contents: write" in s:
    print("done")
else:
    print("odd")
PY
)"
  case "$verdict" in
    done) SKIPPED=$((SKIPPED+1)); echo "$repo: already job-scoped"; rm -rf "$dir"; continue ;;
    odd)  ODD=$((ODD+1)); echo "$repo: dependabot-automerge.yml does not carry the shape this rewrites — left alone, look at it"; rm -rf "$dir"; continue ;;
  esac

  python3 - "$wf" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = """permissions:
  contents: write
  pull-requests: write
"""
new = """# READ AT THE TOP, WRITE ONLY WHERE IT IS USED. A top-level block applies to
# every job in the file, including ones added later; OpenSSF Scorecard scores
# that as Token-Permissions 0/10 and it is right to. The merge job below is
# the only thing here that writes anything.
permissions:
  contents: read
"""
assert old in s
s = s.replace(old, new, 1)
job = """jobs:
  merge:
    name: Merge the update if its verification passed
"""
assert job in s
s = s.replace(job, """jobs:
  merge:
    name: Merge the update if its verification passed
    permissions:
      contents: write
      pull-requests: write
""", 1)
io.open(p, "w", encoding="utf-8").write(s)
PY

  if [ "$DRY_RUN" = "true" ]; then
    echo "$repo: would move the writes to the merge job"
    rm -rf "$dir"; continue
  fi
  git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
    commit -aqm "fix(ci): grant the automerge writes to the job, not the file

A top-level permissions block applies to every job in the workflow,
including any added later, so contents: write and pull-requests: write
at the top of this file granted more than the one job that needs them.
OpenSSF Scorecard scores that as Token-Permissions 0/10; measured across
the fleet on 2026-09-14, 83 of 94 public repositories carried this shape
and every one of them scored zero on that check.

The merge job keeps both writes. Nothing it does changes." >/dev/null
  git -C "$dir" push -q origin main
  echo "$repo: writes moved to the merge job"
  CHANGED=$((CHANGED+1))
  rm -rf "$dir"
done

echo
echo "changed: $CHANGED   already job-scoped: $SKIPPED   unexpected shape: $ODD"
