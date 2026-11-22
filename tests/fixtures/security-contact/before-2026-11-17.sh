#!/bin/bash
# One-shot rollout: every SECURITY.md links GitHub's private advisory form
# first, gives the public contact address second, and names no personal
# address.
#
# WHAT IT FIXES. Since 2026-09-25 every policy has read "Report privately
# through GitHub: **Security → Report a vulnerability** on this repository
# ... Email to <a personal address> also works." (that rollout is in git
# history under this name). On 2026-11-14 the maintainer decided a personal
# address appears nowhere public. The line is rewritten to link the form
# itself, https://github.com/OWNER/REPO/security/advisories/new, and to give
# the address the site gives. Private vulnerability reporting is switched on
# in every repository the link lands in, so the link never leads to a form
# that is off.
#
# THE PERSONAL ADDRESS IS NOT IN THIS FILE. The line is recognised by its
# shape, the three spellings the fleet carried, and replaced whole. The new
# address comes from SECURITY_CONTACT_EMAIL and is never printed.
#
# A rewrite is accepted only when exactly one line changed and the file kept
# its line count; anything else is left alone and named.
#
# Commits carry [skip ci]: one line of documentation in a hundred and twenty
# repositories is not worth a hundred and twenty runs, and in the image
# repositories a push to main publishes an image.
#
# fleet-ops is skipped by default: its SECURITY.md is changed in
# fleet-ops-private and reaches it with the next publish. SKIP_REPOS adds
# more, REPOS_ONLY names the only ones to touch.
#
# Idempotent: a policy that already links the form is skipped, and switching
# private vulnerability reporting on twice changes nothing.
set -euo pipefail
# shellcheck source=scripts/git-auth.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-auth.sh"  # GH_TOKEN reaches git by environment, never in a URL

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
SKIP_REPOS=" fleet-ops ${SKIP_REPOS:-} "
CONTACT="${SECURITY_CONTACT_EMAIL:?SECURITY_CONTACT_EMAIL names the public address for security reports}"
case "$CONTACT" in
  *@*.*) ;;
  *) echo "::error::SECURITY_CONTACT_EMAIL does not look like an address"; exit 1 ;;
esac
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# The three spellings, whole: "(private vulnerability reporting is enabled).
# Email to ... also works.", ". Email to ... also works." and ", or by email
# to ...", each followed by the same sentence about the process. A line that
# carries anything more does not match and is left alone, so nothing a person
# added to it is overwritten.
OLD_RE='^Report privately through GitHub: \*\*Security → Report a vulnerability\*\* on this repository( \(private vulnerability reporting is enabled\)\. Email to [^ ]+@[^ ]+ also works\.|\. Email to [^ ]+@[^ ]+ also works\.|, or by email to [^ ]+@[^ ]+\.) The process is described at \[heyvaldemar\.com/security\]\(https://heyvaldemar\.com/security/\)\.$'

REPOS=()
if [ -n "${REPOS_ONLY:-}" ]; then
  while IFS= read -r _r; do REPOS+=("$_r"); done < <(tr ' ' '\n' <<< "$REPOS_ONLY" | grep . | sed 's/$/\tmain/')
else
  while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
    --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | [.name, .default_branch] | @tsv' | sort)
fi
[ "${#REPOS[@]}" -gt 0 ] || { echo "::error::repository listing came back empty"; exit 1; }

CHANGED=0; CURRENT=0; ODD=0; HELD=0; PVR=0; PVR_FAILED=0
# The form is switched on BEFORE the policy that links it is pushed: a policy
# sending a reporter to a form that is off is the dead channel this file
# exists to remove. A repository where it cannot be switched on is not
# rewritten, and the run ends red.
pvr() {   # pvr <repo>: switch private vulnerability reporting on; 1 if that failed
  [ "$DRY_RUN" = "true" ] && return 0
  if gh api -X PUT "repos/$OWNER/$1/private-vulnerability-reporting" >/dev/null 2>&1; then
    PVR=$((PVR + 1))
  else
    PVR_FAILED=$((PVR_FAILED + 1)); echo "  $1: private vulnerability reporting could not be switched on, policy left as it was"
    return 1
  fi
}

for entry in "${REPOS[@]}"; do
  repo="${entry%%$'\t'*}"; branch="${entry#*$'\t'}"
  case "$SKIP_REPOS" in *" $repo "*) HELD=$((HELD + 1)); echo "  $repo: skipped"; continue ;; esac
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 --branch "$branch" "https://github.com/$OWNER/$repo" "$dir" 2>/dev/null \
    || { ODD=$((ODD + 1)); echo "  $repo: could not be cloned"; continue; }
  f=""
  for p in SECURITY.md .github/SECURITY.md docs/SECURITY.md; do [ -f "$dir/$p" ] && { f="$p"; break; }; done
  if [ -z "$f" ]; then ODD=$((ODD + 1)); echo "  $repo: no SECURITY.md"; rm -rf "$dir"; continue; fi
  if grep -qF "/security/advisories/new" "$dir/$f"; then
    CURRENT=$((CURRENT + 1)); pvr "$repo" || true; rm -rf "$dir"; continue
  fi
  n="$(grep -cE "$OLD_RE" "$dir/$f" || true)"
  if [ "$n" != 1 ]; then ODD=$((ODD + 1)); echo "  $repo: $n contact lines of a known shape, left alone"; rm -rf "$dir"; continue; fi
  before="$(wc -l < "$dir/$f")"
  python3 - "$dir/$f" "$OLD_RE" "$OWNER" "$repo" "$CONTACT" <<'PY'
import io, re, sys
path, old_re, owner, repo, contact = sys.argv[1:]
new = ("Report privately through GitHub: [**Security → Report a vulnerability**]"
       "(https://github.com/%s/%s/security/advisories/new) on this repository. "
       "Email to %s also works. The process is described at "
       "[heyvaldemar.com/security](https://heyvaldemar.com/security/)." % (owner, repo, contact))
s = io.open(path, encoding="utf-8").read()
io.open(path, "w", encoding="utf-8").write(re.sub(old_re, lambda _m: new, s, count=1, flags=re.M))
PY
  stat="$(git -C "$dir" diff --numstat -- "$f")"
  if [ "$stat" != "1	1	$f" ] || [ "$(wc -l < "$dir/$f")" != "$before" ]; then
    ODD=$((ODD + 1)); echo "  $repo: the rewrite changed more than the contact line, left alone"; rm -rf "$dir"; continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    # DRY_RUN_KEEP=<dir> keeps each diff there, to be read with the addresses masked.
    [ -n "${DRY_RUN_KEEP:-}" ] && git -C "$dir" diff -- "$f" > "$DRY_RUN_KEEP/$repo.diff"
    echo "  would rewrite $repo"; CHANGED=$((CHANGED + 1)); rm -rf "$dir"; continue
  fi
  if ! pvr "$repo"; then rm -rf "$dir"; continue; fi
  rc=0
  (
    cd "$dir"
    git add -- "$f"
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q \
      -m "docs(security): report through the advisory form or the public address [skip ci]"
    # Another session may have pushed since the clone; the change is one line
    # of a file nothing else edits, so it rebases cleanly or not at all.
    git pull -q --rebase origin "$branch" 2>/dev/null
    git push -q origin "HEAD:$branch" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  rewrote $repo"; CHANGED=$((CHANGED + 1))
  else
    ODD=$((ODD + 1)); echo "  $repo: push refused ($rc), nothing changed there"
  fi
  rm -rf "$dir"
done
echo "rewritten: $CHANGED   already current: $CURRENT   skipped: $HELD   left alone: $ODD   reporting switched on: $PVR   failed: $PVR_FAILED"
[ "$ODD" -eq 0 ] && [ "$PVR_FAILED" -eq 0 ]
