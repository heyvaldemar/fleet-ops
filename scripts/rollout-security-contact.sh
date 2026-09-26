#!/bin/bash
# One-shot rollout: SECURITY.md stops promising a PGP key on a page that does
# not exist, and names the private channel that does.
#
# WHAT IT FIXES. Since April every SECURITY.md said "the PGP public key is
# published at heyvaldemar.com/security", and that page answered 404: the
# sentence was written before the page, the page was never made, and nothing
# in the fleet checks that a URL in a policy answers. Found on 2026-09-25
# while filling in the OpenSSF Best Practices questionnaire, whose
# "private vulnerability reporting" question asks for exactly that URL.
#
# From now on: GitHub's private vulnerability reporting is enabled on every
# repository (Security -> Report a vulnerability), the policy points there
# first and to email second, and heyvaldemar.com/security describes the
# process. The heartbeat checks that every URL in SECURITY.md answers.
#
# Idempotent: a policy already carrying the new sentence is skipped.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Three spellings of the same sentence were in the fleet (a semicolon, a colon,
# a full stop before "the PGP public key"); the first run matched one of them
# and left three repositories alone, which is why this is a pattern now.
OLD_RE='Send reports to v@valdemar\.ai\. Encrypted email is preferred[;:.] [Tt]he PGP public key is published at \[heyvaldemar\.com/security\]\(https://heyvaldemar\.com/security/?\)\.'
NEW='Report privately through GitHub: **Security → Report a vulnerability** on this repository (private vulnerability reporting is enabled). Email to v@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).'

REPOS=()
if [ -n "${REPOS_ONLY:-}" ]; then
  read -r -a REPOS <<< "$REPOS_ONLY"
else
  while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
    --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | .name' | sort)
fi
[ "${#REPOS[@]}" -gt 0 ] || { echo "::error::repository listing came back empty"; exit 1; }

CHANGED=0; SKIPPED=0; ODD=0; PRS=0; rc=0
for repo in "${REPOS[@]}"; do
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || continue
  f="$dir/SECURITY.md"
  [ -f "$f" ] || { ODD=$((ODD + 1)); echo "  $repo: no SECURITY.md"; rm -rf "$dir"; continue; }
  if grep -qF "Report privately through GitHub" "$f"; then SKIPPED=$((SKIPPED + 1)); rm -rf "$dir"; continue; fi
  if ! grep -qE "$OLD_RE" "$f"; then ODD=$((ODD + 1)); echo "  $repo: policy has another wording, left alone"; rm -rf "$dir"; continue; fi
  if [ "$DRY_RUN" = "true" ]; then echo "  would rewrite $repo"; CHANGED=$((CHANGED + 1)); rm -rf "$dir"; continue; fi
  python3 - "$f" "$OLD_RE" "$NEW" <<'PY'
import io, re, sys
p, old_re, new = sys.argv[1:]
s = io.open(p, encoding="utf-8").read()
io.open(p, "w", encoding="utf-8").write(re.sub(old_re, lambda _m: new, s))
PY
  (
    cd "$dir"
    git add SECURITY.md
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "docs(security): the private channel that exists, not a key page that did not" \
      -m "The policy pointed encrypted reports at heyvaldemar.com/security, which answered 404 since April. GitHub private vulnerability reporting is now enabled here and named first; email second; the page describes the process. The heartbeat checks that every URL in this file answers."
    if ! git push -q origin HEAD 2>/dev/null; then
      # A repository whose rules require a pull request (aws-kubectl-docker).
      git push -q -f origin HEAD:security-contact
      gh pr create -R "$OWNER/$repo" --head security-contact --fill >/dev/null 2>&1 || true
      gh pr merge -R "$OWNER/$repo" security-contact --auto --squash >/dev/null 2>&1 || true
      exit 3
    fi
  ) || rc=$?
  case "${rc:-0}" in
    0) echo "  rewrote $repo"; CHANGED=$((CHANGED + 1)) ;;
    3) echo "  $repo: main refuses direct pushes; pull request opened, merges when its checks pass"; PRS=$((PRS + 1)) ;;
    *) echo "  $repo: push failed ($rc)"; ODD=$((ODD + 1)) ;;
  esac
  rc=0
  rm -rf "$dir"
done
echo "rewritten: $CHANGED   pull requests instead: $PRS   already current: $SKIPPED   left alone: $ODD"
