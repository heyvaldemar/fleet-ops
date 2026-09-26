#!/bin/bash
# One-shot rollout: a ruleset on every public repository's default branch that
# blocks force-pushes and deletion. Nothing else.
#
# WHAT IT FIXES. OpenSSF Scorecard, read across all 97 public repositories on
# 2026-09-24, scored Branch-Protection 0 on 91 of them: main could be
# rewritten or deleted by anyone holding the token, and nothing would have
# noticed until a clone came back different. Six repositories already carried
# the same two-rule ruleset, named protect-main, added by hand; this gives the
# rest the same one.
#
# WHAT IT DELIBERATELY DOES NOT DO. No required reviews and no required
# checks. This fleet is one maintainer and an agent pushing to main after the
# repository's own CI has run on the commit, and a rule that requires a pull
# request for every change is a rule that would be bypassed on day one. A rule
# that only forbids rewriting history costs nothing and is never bypassed.
#
# The heartbeat asks every repository for these two rules from now on, so a
# repository created after this rollout without them is a finding.
#
# Idempotent: a branch that already has both rules is skipped.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"

# REST, not `gh repo list`: that command speaks GraphQL, which rejects
# fine-grained PATs with a 401, and a silent empty list would produce a green
# run that had changed nothing.
REPOS=()
while IFS=$'\t' read -r _n _b; do REPOS+=("$_n	$_b"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
  --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | [.name, .default_branch] | @tsv' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

CHANGED=0; SKIPPED=0; FAILED=0
for entry in "${REPOS[@]}"; do
  repo="${entry%%	*}"; branch="${entry#*	}"
  have="$(gh api "repos/$OWNER/$repo/rules/branches/$branch" --jq '[.[].type] | sort | join(",")' 2>/dev/null || echo "unreadable")"
  case "$have" in
    *deletion*non_fast_forward*) SKIPPED=$((SKIPPED + 1)); continue ;;
    unreadable) echo "  $repo: could not read its rules"; FAILED=$((FAILED + 1)); continue ;;
  esac
  if [ "$DRY_RUN" = "true" ]; then
    echo "  would protect $repo ($branch): has [$have]"
    CHANGED=$((CHANGED + 1)); continue
  fi
  if gh api -X POST "repos/$OWNER/$repo/rulesets" --input - >/dev/null <<JSON
{"name":"protect-main","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"non_fast_forward"},{"type":"deletion"}],"bypass_actors":[]}
JSON
  then
    echo "  protected $repo ($branch)"; CHANGED=$((CHANGED + 1))
  else
    echo "  $repo: the ruleset was refused"; FAILED=$((FAILED + 1))
  fi
done

echo "protected: $CHANGED   already had both rules: $SKIPPED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
