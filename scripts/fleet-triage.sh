#!/bin/bash
# Weekly CI triage for the heyvaldemar docker-compose template fleet.
#
# What it does, per repository:
#   1. FLAKY deploy runs — the deploy job failed while lint/scan stayed
#      green and the run was never retried: rerun the failed jobs once.
#   2. DIGEST DRIFT — a pinned tag re-resolves to a new digest (upstream
#      repushed the same tag, usually a base-image security rebuild):
#      update the pin and push. The verdict is read on the NEXT run: green
#      becomes a patch release, red is reverted, and nothing is waited on.
#      IT USED TO WAIT. Each bump held the runner in a sleep loop until that
#      repository's CI answered — about four minutes, one repository at a
#      time, and one run on 2026-09-14 spent two hours doing it. Measured
#      over nineteen runs: 78 waits, 2 reverts. Ninety-seven per cent of the
#      waiting confirmed what was already true, and GitHub bills every minute
#      of it. What the waiting bought was a red pin reverted in four minutes
#      instead of at the next run; that is the price of this change, and the
#      third daily run is what keeps it down.
#   3. VERSION LAG inside a major — bumped on the same gated path. Across
#      a major — prepared on a branch and reported with its compare link.
#   4. Anything a person has to decide reaches them as an issue in this
#      repository, opened by the workflow from the report.
#
# Requirements: gh (authenticated via GH_TOKEN), docker buildx, jq, git.
# DRY_RUN=true prints what would happen without pushing anything.

set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
# A run that is cut off mid-queue must SAY so. Cancelled by the runner it says
# nothing at all: on 2026-09-05 a single traefik repush queued thirty
# repositories, the job hit its limit at nineteen, and the eleven still red
# were mentioned nowhere. The script keeps its own budget under the job's and
# stops cleanly, reporting what it did not reach - a re-run picks those up,
# because they are still red.
BUDGET_SECONDS="${FLEET_BUDGET_SECONDS:-1800}"
STARTED_AT="$(date +%s)"
budget_left() { [ $(( $(date +%s) - STARTED_AT )) -lt "$BUDGET_SECONDS" ]; }

# WHAT LAST RUN PUSHED AND NOBODY HAS JUDGED YET. Committed to this
# repository by the workflow, because where a bump got to is a fact about the
# fleet and not a cache that may quietly expire: an expired cache would look
# exactly like "nothing is pending" and a red pin would stay on main.
PENDING="${FLEET_PENDING:-${GITHUB_WORKSPACE:-.}/triage-pending.json}"
# How long a pushed bump may go unjudged before it stops being "waiting" and
# starts being something a person should look at. A template's own CI answers
# in about four minutes; twelve hours means its workflow never ran at all.
STALE_HOURS="${FLEET_STALE_HOURS:-12}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

REPORT="$WORKDIR/report.md"
{
  echo "## Fleet triage — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
} > "$REPORT"
note() { echo "$*"; echo "- $*" >> "$REPORT"; }
section() { echo; echo "### $*" >> "$REPORT"; }

# REST, not `gh repo list`: that command speaks GraphQL, which rejects
# fine-grained PATs with a 401 — and a silent empty list once produced a
# green run that had checked nothing. Hence the fail-fast below.
#
# /user/repos, not /users/OWNER/repos: the latter lists PUBLIC repositories
# only, so a private template (gaseous) went red every morning and was in
# no report at all, because the listing never handed it to the loop. The
# token decides what is visible; the listing must not narrow it further.
REPOS=()
# Fleet templates whose names do not end in -docker-compose, -docker or
# -terraform. The filter below is a name rule, so a repository named for what
# it does rather than for how it is deployed is never seen, and nothing fails
# to say so: chatops-privilege-wall sat red with two drifted digests on
# 2026-09-18 and no run had ever looked at it. fleet-conformance.py keeps the
# same list for the same reason; both are name rules and both need the escape.
EXTRA_FLEET_REPOS='chatops-privilege-wall'
list_repos() {
  while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "user/repos?affiliation=owner&per_page=100" --paginate --jq '.[] | select(.archived|not) | .name' | grep -E "docker-compose\$|docker\$|-terraform\$|^(${EXTRA_FLEET_REPOS})\$" | sort)
  if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
    exit 1
  fi
}

# The README quotes the version the compose file pins - "latest stable (1.17.0)"
# and, in some templates, an "# Expected:" line showing what the smoke check
# returns. Bumping the pin without touching those leaves the README saying
# something that is no longer true, and conformance reports it the next
# morning: dify and ollama both drifted that way, silently, because this
# function did not exist.
#
# Deliberately narrow. It rewrites the version ONLY where the README has
# already committed to naming one, and only where the string it replaces is
# exactly the version being moved off. It does not go looking for numbers.
readme_version() {
  local d="$1" oldv="$2" newv="$3"
  local f="$d/README.md"
  [ -f "$f" ] || return 0
  local o="${oldv#v}" n="${newv#v}" tmpf
  [ -n "$o" ] && [ "$o" != "$n" ] || return 0
  tmpf="$(mktemp)"
  sed -E -e "s|(latest stable \(v?)${o}([),])|\1${n}\2|g" \
         -e "s|(latest stable \(v?)${o}( line\))|\1${n}\2|g" \
         -e "s|(\"version\"[[:space:]]*:[[:space:]]*\")${o}(\")|\1${n}\2|g" \
         "$f" > "$tmpf"
  if ! cmp -s "$f" "$tmpf"; then
    cat "$tmpf" > "$f"
    note "$repo: README now names $n where it named $o"
  fi
  rm -f "$tmpf"
}

# The .env.example carries the same version as a commented default:
#     # OLLAMA_IMAGE_VERSION=0.33.2
# It was written once and never moved with the pin. On 2026-09-30 fifty-four
# such lines across forty-two templates named an older release than the
# compose file pinned, and a reader uncommenting one would have pinned the
# past. The same narrowness as readme_version: only the variable this pin
# declares, only where the string is exactly the tag being moved off.
example_version() {
  local d="$1" var="$2" oldtag="$3" newtag="$4"
  local f="$d/.env.example"
  [ -f "$f" ] || return 0
  [ -n "$var" ] && [ -n "$oldtag" ] && [ "$oldtag" != "$newtag" ] || return 0
  local esc tmpf
  esc="$(printf '%s' "$oldtag" | sed -e 's/[][\.*^$|]/\\&/g')"
  tmpf="$(mktemp)"
  sed -E "s|^(#? *${var}=)${esc}([[:space:]#].*)?$|\1${newtag}\2|" "$f" > "$tmpf"
  if ! cmp -s "$f" "$tmpf"; then
    cat "$tmpf" > "$f"
    note "$repo: .env.example now names $newtag for $var where it named $oldtag"
  fi
  rm -f "$tmpf"
}

# A line under [Unreleased] for every version bump, so the next release
# notes are written by the time somebody cuts them. Digest refreshes stay
# silent: same version, same tag, a rebuilt base.
changelog_line() {
  # changelog_line <dir> <section> <line>: the line goes under [Unreleased],
  # in the named section (Changed for a version bump, Security for a rebuilt
  # base image), creating the section when it is not there yet.
  local f="$1/CHANGELOG.md" section="$2" line="$3"
  [ -f "$f" ] || return 0
  grep -q '^## \[Unreleased\]' "$f" || return 0
  python3 - "$f" "$section" "$line" <<'PY'
import io, re, sys
p, section, line = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
s = s.replace("## [Unreleased]\n\n_(no unreleased changes yet)_\n", "## [Unreleased]\n", 1)
head = re.search(r"^## \[Unreleased\]\n", s, re.M)
end = re.search(r"^## \[", s[head.end():], re.M)
body_end = head.end() + (end.start() if end else len(s) - head.end())
body = s[head.end():body_end]
tag = "### %s\n" % section
if tag in body:
    i = body.index(tag) + len(tag)
    # the section opens with a blank line; the new line goes right after it
    if body[i:i + 1] == "\n":
        i += 1
    body = body[:i] + line + "\n" + body[i:]
else:
    body = "\n" + tag + "\n" + line + "\n" + body
    if not body.endswith("\n\n"):
        body = body.rstrip("\n") + "\n\n"
s = s[:head.end()] + body + s[body_end:]
io.open(p, "w", encoding="utf-8").write(s)
PY
}

# A verified refresh becomes a patch release, because update.sh in every
# template moves between release tags: a refresh that stays on main is a
# security rebuild nobody deploying the template ever receives. The
# [Unreleased] section already holds the lines this run wrote; they become
# the section and the notes of the next patch version.
cut_release() {
  local d="$1" repo="$2" f="$1/CHANGELOG.md" cur next notes
  [ -f "$f" ] || { note "$repo: no CHANGELOG.md — the refresh is on main and not in a release"; return 0; }
  # THE HIGHEST TAG, NOT THE LATEST RELEASE PAGE. `gh release view` cannot see a
  # tag that was pushed without one, and on 2026-09-13 that cut v1.0.2 on a
  # repository whose highest tag was already v2.0.0: the newest content ended up
  # carrying the lower version, while update.sh, which sorts tags, would have
  # called the older v2.0.0 the latest release available. Tags come from the API
  # because the clone is --depth 1 and carries almost none of them.
  cur="$(gh api "repos/$OWNER/$repo/tags" --paginate --jq '.[].name' 2>/dev/null \
         | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
  [ -n "$cur" ] || cur="$(gh release view --repo "$OWNER/$repo" --json tagName --jq .tagName 2>/dev/null || true)"
  case "$cur" in v[0-9]*.[0-9]*.[0-9]*) ;; *) note "$repo: no semver release to follow — the refresh is on main and not in a release"; return 0 ;; esac
  next="$(python3 -c 'import sys; v = sys.argv[1][1:].split("."); v[2] = str(int(v[2]) + 1); print("v" + ".".join(v))' "$cur")"
  notes="$WORKDIR/notes-$repo.md"
  if ! python3 - "$f" "$cur" "$next" "$OWNER/$repo" "$notes" <<'PY'
import datetime, io, re, sys
p, cur, nxt, full, notes = sys.argv[1:6]
s = io.open(p, encoding="utf-8").read()
head = re.search(r"^## \[Unreleased\]\n", s, re.M)
if not head:
    sys.exit(1)
rest = s[head.end():]
end = re.search(r"^## \[", rest, re.M)
body = rest[:end.start()] if end else rest
if not body.strip() or "_(no unreleased changes yet)_" in body:
    sys.exit(1)  # nothing to release
today = datetime.date.today().isoformat()
section = "## [%s] - %s\n" % (nxt[1:], today) + body.rstrip("\n") + "\n\n"
s = s[:head.end()] + "\n_(no unreleased changes yet)_\n\n" + section + s[head.end() + len(body):]
base = "https://github.com/" + full
old_link = "[Unreleased]: %s/compare/%s...HEAD" % (base, cur)
if old_link in s:
    s = s.replace(old_link, "[Unreleased]: %s/compare/%s...HEAD\n[%s]: %s/compare/%s...%s" % (base, nxt, nxt[1:], base, cur, nxt), 1)
io.open(p, "w", encoding="utf-8").write(s)
io.open(notes, "w", encoding="utf-8").write(
    body.strip() + "\n\n## Upgrading\n\n"
    "`git pull` (or `./update.sh`), then `docker compose up -d`. Containers on a refreshed image are recreated; data volumes and `.env` are untouched. "
    "This release was cut by fleet triage after the deploy job booted the stack on the refreshed images.\n\n"
    "Full history in [CHANGELOG.md](%s/blob/main/CHANGELOG.md).\n" % base)
PY
  then
    note "$repo: nothing under [Unreleased] to release"
    return 0
  fi
  if ! git -C "$d" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -aqm "chore(release): $next" \
       -m "Cut by fleet triage after that repository's own CI verified the refreshed pins on main. update.sh moves between release tags, so a refresh that stayed on main was a security rebuild nobody deploying the template received." \
     || ! git -C "$d" push -q origin main; then
    note "$repo: $next could not be committed or pushed — the refresh is on main without a release, needs a human"
    return 0
  fi
  if [ -f "$WORKDIR/reviews-$repo.md" ]; then
    { echo; echo "## What upstream changed"; echo; echo "Read by fleet triage from the upstream release notes (or the commits between the tags) against this compose file, before the bump was applied."; cat "$WORKDIR/reviews-$repo.md"; } >> "$notes"
  fi
  if gh release create "$next" --repo "$OWNER/$repo" --title "$next" --notes-file "$notes" --target main >/dev/null 2>&1; then
    note "$repo: released $next"
  else
    note "$repo: the release commit for $next is on main but the tag could not be created — needs a human"
  fi
}

# What upstream changed between the two versions, read against this
# template. Sets REVIEW_VERDICT and appends the text to the report and to the
# notes that the next release carries. Outside GitHub Actions (no OIDC) the
# review is skipped and says so, never silently.
REVIEW_VERDICT=""
review_bump() {
  local d="$1" repo="$2" ref="$3" oldv="$4" newv="$5"
  local image="${ref%%:*}" out="$WORKDIR/review-$repo-${ref//[^A-Za-z0-9]/_}.md" js
  js="${out%.md}.json"
  REVIEW_VERDICT=""
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ ! -f "${GITHUB_WORKSPACE:-.}/scripts/upstream-review.py" ]; then
    note "$repo: upstream review skipped (no workload identity here) for $ref $oldv -> $newv"
    return 0
  fi
  if (cd "$d" && python3 "$GITHUB_WORKSPACE/scripts/upstream-review.py" --repo "$repo" --image "$image" --from "$oldv" --to "$newv" --out "$out" --json "$js" --cache "$WORKDIR/review-cache" >/dev/null 2>"$out.err"); then
    REVIEW_VERDICT="$(jq -r '.verdict // ""' "$js" 2>/dev/null)"
    note "$repo: upstream review of $ref $oldv -> $newv: ${REVIEW_VERDICT:-no verdict line}"
    { echo; echo "<details><summary>$repo: $ref $oldv -> $newv</summary>"; echo; cat "$out"; echo; echo "</details>"; } >> "$WORKDIR/reviews.md"
    { echo; cat "$out"; } >> "$WORKDIR/reviews-$repo.md"
  else
    note "$repo: upstream review of $ref $oldv -> $newv FAILED: $(tail -1 "$out.err" | cut -c1-160) — the bump proceeds on the CI gate alone"
  fi
}

# A major bump is prepared, never landed: the compose file and the changelog
# are changed on a branch, pushed, and the compare link goes to the report.
# Opening the pull request is the decision, and it is one click.
major_branch() {
  local oldv="$1" newv="$2" moved=()
  local br="bump/${newv#v}"
  # ONE BRANCH, EVERY PIN THAT MOVES WITH THIS VERSION.
  #
  # The checkout used to live inside the loop below, re-pointing the branch at
  # main once per pin. That never lost an edit, because the ref still pointed
  # at main and git carried the dirty tree across, but it only worked by
  # accident: one commit between two pins and the first pin's work would have
  # been dropped without a word. It is done once, here, and the loop only
  # edits.
  # THE BRANCH CARRIES ITS OWN CHANGE AND NOTHING ELSE.
  #
  # The digest-drift pass runs before this one and leaves its edits uncommitted
  # in the same compose file. Without setting them aside, the commit below took
  # them onto the branch, main was left with nothing to commit, and the run
  # died on the `fix(security): refresh pins` commit that followed. mssql hit
  # exactly that on 2026-09-18: a traefik digest refresh belonging on main
  # rode onto bump/2022-CU27 instead, and the triage exited 1.
  local stashed=0
  if [ "$DRY_RUN" != "true" ]; then
    if ! git -C "$dir" diff --quiet; then
      git -C "$dir" stash push -q -u && stashed=1
    fi
    git -C "$dir" checkout -q -B "$br" main
  fi
  while IFS= read -r pin; do
    def="${pin#*:-}"; def="${def%\}}"
    case "$def" in *"$oldv"*@sha256:*) ;; *) continue ;; esac
    ref="${def%%@*}"; olddg="${def##*@}"
    newref="${ref//$oldv/$newv}"
    newdg="$(docker buildx imagetools inspect "$newref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true)"
    [ -n "$newdg" ] || { note "$repo: $newref does not resolve yet — nothing prepared"; continue; }
    if [ "$DRY_RUN" = "true" ]; then note "$repo: would prepare branch $br for $ref -> $newref"; continue; fi
    # THE TAG, NOT THE REPORTED VERSION. A freshness check reports the version
    # it compares, and several of them strip a suffix to get it: GitLab's says
    # "pinned 19.3.2" for an image tagged 19.3.2-ee.0. Searching the file for
    # "19.3.2@sha256:..." then matches nothing, because what is written there
    # is "19.3.2-ee.0@sha256:...". The tag is what the file actually contains,
    # and it is already in hand.
    oldtag="${ref##*:}"; newtag="${newref##*:}"
    for _c in "${composes[@]}"; do
      grep -q "${oldtag}@${olddg}" "$_c" || continue
      tmpf="$(mktemp)"; sed "s|${oldtag}@${olddg}|${newtag}@${newdg}|" "$_c" > "$tmpf"; cat "$tmpf" > "$_c"; rm -f "$tmpf"
    done
    # THE README MOVES WITH THE PIN, as it does on the ordinary bump path.
    # Without this the branch changed the compose file and left the README
    # saying "latest stable (34.0.3)" over a file pinning 35.0.0, which is a
    # conformance finding the next morning and a lie to a reader today. Both
    # Nextcloud templates shipped exactly that on 2026-09-18, and the fleet's
    # own conformance suite is what caught it.
    readme_version "$dir" "$oldv" "$newv"
    # The pin is ${X_IMAGE_TAG:-repo:${X_IMAGE_VERSION:-tag@digest}}; the
    # example declares X_IMAGE_VERSION, so its name follows from the tag's.
    vervar="${pin#\$\{}"; vervar="${vervar%%:-*}"; vervar="${vervar%_IMAGE_TAG}_IMAGE_VERSION"
    example_version "$dir" "$vervar" "$oldtag" "$newtag"
    changelog_line "$dir" "Changed" "- **\`${ref}\` moved to \`${newref}\`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed."
    moved+=("$ref -> $newref")
  done < <(grep -h -oE '\$\{[A-Z0-9_]+_IMAGE_TAG:-.*' "${composes[@]}" | sed -E -e ':a' -e 's/(\$\{[A-Z0-9_]+_IMAGE_TAG:-[^{}]*)\$\{[A-Z0-9_]+:-([^{}]*)\}/\1\2/' -e 'ta' | sort -u)

  # Put the tree back the way the rest of the run expects it, whatever happens
  # below: on main, with the digest work restored.
  restore_main() {
    git -C "$dir" checkout -q main
    [ "$stashed" -eq 1 ] && git -C "$dir" stash pop -q
    return 0
  }

  if [ "$DRY_RUN" = "true" ]; then return 0; fi
  if [ "${#moved[@]}" -eq 0 ]; then
    restore_main
    note "$repo: version lag $oldv -> $newv crosses a major and no pin carried it — needs a human"
    return 0
  fi

  git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
    commit -aqm "chore(deps): move $oldv to $newv

$(printf '%s\n' "${moved[@]}")

Prepared by fleet triage and not landed by it: the deploy job will boot the
stack on the new images when this branch is opened as a pull request, and the
decision to merge stays with a person. Every pin carrying $oldv moves together,
because a version shared by two images is one version." || true
  if ! git -C "$dir" push -q -f origin "$br"; then
    note "$repo: the branch $br could not be pushed — needs a human"
    restore_main
    return 0
  fi
  restore_main
  note "$repo: $oldv -> $newv prepared on branch \`$br\` ($(printf '%s; ' "${moved[@]}" | sed 's/; $//')) — open it: https://github.com/$OWNER/$repo/compare/main...$br?expand=1 — needs a human"
  PREPARED_THIS_RUN+=("$repo:$br")
  # Read by the verdict at the end of the refresh pass. Without it that verdict
  # said "nothing was auto-fixable" directly beneath a branch this function had
  # just pushed, which was false, and turned one decision into two lines that
  # each asked for a person.
  PREPARED_MAJOR=1
}

# Two shapes, two workflow names. Everything below asks for the name rather
# than assuming it, so a terraform repository is not silently skipped by a
# `gh run list` that matches nothing.
# THE BRANCH FILTER IS AN INDEX, AND IT CAN BE STALE. On 2026-10-06 13:38 the
# rerun pass asked for the latest run on main with --branch main and got one
# from 2026-09-14, three weeks and two newer runs old; the freshness pass in
# the same triage run, listing without the filter, saw the run from that
# morning. The list without --branch is the one that was current, so main is
# selected here, newest first by the time GitHub created each run. A failed
# call still fails, because settle_pending retries on exactly that.
runs_on_main() {     # runs_on_main <repo> <workflow> <limit> <json fields>
  local out
  out="$(gh run list --repo "$OWNER/$1" --workflow "$2" --limit "$3" --json "headBranch,createdAt,$4")" || return 1
  jq -c '[.[] | select(.headBranch == "main")] | sort_by(.createdAt) | reverse' <<<"$out"
}

workflow_for() {
  case "$1" in
    *-terraform) echo "Terraform Verification" ;;
    *) echo "Deployment Verification" ;;
  esac
}

# The upstream review, for a provider rather than an image: the notes live in
# hashicorp/terraform-provider-<name>, and the file to read the pin against is
# the provider block, not a compose file.
review_provider() {
  local d="$1" repo="$2" src="$3" oldv="$4" newv="$5"
  local out="$WORKDIR/review-$repo-${src//[^A-Za-z0-9]/_}.md" js
  js="${out%.md}.json"
  REVIEW_VERDICT=""
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ ! -f "${GITHUB_WORKSPACE:-.}/scripts/upstream-review.py" ]; then
    note "$repo: upstream review skipped (no workload identity here) for $src $oldv -> $newv"
    return 0
  fi
  # A provider's release notes are not in <ns>/<name>: they are in
  # <ns>/terraform-provider-<name>. Reading the wrong repository is a 404, and
  # a 404 becomes "notes could not be retrieved" - a verdict that says nothing
  # about the upgrade and everything about the lookup.
  local notes_repo="${src%%/*}/terraform-provider-${src##*/}"
  if (cd "$d" && python3 "$GITHUB_WORKSPACE/scripts/upstream-review.py" --repo "$repo" --image "$src" \
        --source "$notes_repo" --from "$oldv" --to "$newv" --compose 01-providers.tf \
        --out "$out" --json "$js" --cache "$WORKDIR/review-cache" >/dev/null 2>"$out.err"); then
    REVIEW_VERDICT="$(jq -r '.verdict // ""' "$js" 2>/dev/null)"
    note "$repo: upstream review of $src $oldv -> $newv: ${REVIEW_VERDICT:-no verdict line}"
    { echo; echo "<details><summary>$repo: $src $oldv -> $newv</summary>"; echo; cat "$out"; echo; echo "</details>"; } >> "$WORKDIR/reviews.md"
    { echo; cat "$out"; } >> "$WORKDIR/reviews-$repo.md"
  else
    note "$repo: upstream review of $src $oldv -> $newv FAILED: $(tail -1 "$out.err" | cut -c1-160) — the bump proceeds on the CI gate alone"
  fi
}

# A terraform repository: providers from the lockfile, CI images from the
# workflow. Sets TF_CHANGED when anything moved.
TF_CHANGED=0
terraform_refresh() {
  local dir="$1" repo="$2" frid="$3"
  local tfimage lags subject oldv newv line
  TF_CHANGED=0
  # The pins live in ci-images.pins, not in the workflow: the fleet token has
  # no `workflow` scope, and giving an automation the right to rewrite its own
  # CI is a ceiling worth keeping.
  # `|| true`: under set -euo pipefail an assignment from a failing pipeline
  # ends the script, and a missing pin file would take every repository
  # behind this one down with it. Absence is a finding, not a crash.
  tfimage="$(grep -m1 -oE '^TERRAFORM_IMAGE=.*' "$dir/ci-images.pins" 2>/dev/null | sed -E 's/^TERRAFORM_IMAGE=//' || true)"
  [ -n "$tfimage" ] || { note "$repo: no TERRAFORM_IMAGE in ci-images.pins — needs a human"; return 0; }

  # Digest drift on the two pinned CI images: same tag, rebuilt binary.
  local var pin ref olddg newdg
  for var in TERRAFORM_IMAGE TFLINT_IMAGE; do
    pin="$(grep -m1 -oE "^${var}=.*" "$dir/ci-images.pins" 2>/dev/null | sed -E "s/^${var}=//" || true)"
    case "$pin" in *@sha256:*) ;; *) continue ;; esac
    ref="${pin%%@*}"; olddg="${pin##*@}"
    newdg="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true)"
    [ -n "$newdg" ] || { note "$repo: $ref did not resolve — registry hiccup, needs a human"; continue; }
    [ "$newdg" = "$olddg" ] && continue
    if [ "$DRY_RUN" = "true" ]; then note "$repo: would refresh $var ($olddg -> $newdg)"; continue; fi
    sed -i "s|${olddg}|${newdg}|" "$dir/ci-images.pins"
    note "$repo: $var — $ref rebuilt upstream ($olddg -> $newdg)"
    changelog_line "$dir" "Security" "- **\`${ref}\` was rebuilt upstream**; the pin moved from \`${olddg:0:19}…\` to \`${newdg:0:19}…\`. Same version, same tag, a rebuilt binary — the one that formats, validates and lints this configuration."
    TF_CHANGED=1
  done

  # Version lag, named by subject: a provider source or TERRAFORM_IMAGE.
  lags="$( (gh run view "$frid" --repo "$OWNER/$repo" --log 2>/dev/null || true) \
      | { grep -oE '[A-Za-z0-9_/.-]+ is behind: pinned [0-9][^,]*, latest ([^ ]+ )?release is [0-9][^ "]*' || true; } | sort -u)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    subject="${line%% is behind*}"
    oldv="$(sed -E 's/.*pinned ([0-9][^,]*),.*/\1/' <<<"$line")"
    newv="$(sed -E 's/.* is ([0-9][^ "]*)$/\1/' <<<"$line")"
    if [ "${oldv%%.*}" != "${newv%%.*}" ]; then
      note "$repo: $subject $oldv -> $newv crosses a major — prepared for a human, not applied"
      terraform_major_branch "$dir" "$repo" "$subject" "$oldv" "$newv"
      continue
    fi
    case "$subject" in
      TERRAFORM_IMAGE)
        # The line the image is tagged with, not a patch: hashicorp/terraform:1.16
        local newref newdg2
        newref="${tfimage%%:*}:${newv}"
        newdg2="$(docker buildx imagetools inspect "$newref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true)"
        [ -n "$newdg2" ] || { note "$repo: $newref does not resolve yet — skipping this bump"; continue; }
        if [ "$DRY_RUN" = "true" ]; then note "$repo: would move TERRAFORM_IMAGE $oldv -> $newv"; continue; fi
        sed -i "s|^TERRAFORM_IMAGE=.*|TERRAFORM_IMAGE=${newref}@${newdg2}|" "$dir/ci-images.pins"
        note "$repo: TERRAFORM_IMAGE moved $oldv -> $newv"
        changelog_line "$dir" "Changed" "- **Terraform ${oldv} → ${newv} in CI.** The same binary that formats, validates and lints this configuration; \`terraform validate\` ran against it before this landed."
        TF_CHANGED=1
        ;;
      */*)
        review_provider "$dir" "$repo" "$subject" "$oldv" "$newv"
        case "$REVIEW_VERDICT" in
          "DO NOT APPLY UNATTENDED"*)
            note "$repo: $subject $oldv -> $newv is inside a major but the upstream review says do not apply unattended — prepared on a branch instead"
            terraform_major_branch "$dir" "$repo" "$subject" "$oldv" "$newv"
            continue ;;
        esac
        if [ "$DRY_RUN" = "true" ]; then note "$repo: would move $subject $oldv -> $newv"; continue; fi
        terraform_bump "$dir" "$repo" "$tfimage" "$subject" "$oldv" "$newv" || continue
        TF_CHANGED=1
        ;;
      *) note "$repo: do not know how to move $subject — needs a human" ;;
    esac
  done <<<"$lags"
}

# The constraint and the lockfile move together, and the lockfile is
# regenerated for every platform it already covers - four here. Regenerating
# for the runner's platform alone would leave a contributor on a Mac with a
# lockfile that refuses their machine.
# Reads the version each provider is locked at. The lockfile is the pin; the
# constraint above it only bounds what the pin may become.
locked_versions() {
  awk '/^provider "registry.terraform.io\// { split($2, p, "registry.terraform.io/"); src = p[2]; gsub(/"/, "", src) }
       /^  version/ { gsub(/"/, "", $3); if (src != "") { print src "=" $3; src = "" } }' "$1/.terraform.lock.hcl" | sort
}

terraform_bump() {
  local dir="$1" repo="$2" tfimage="$3" src="$4" oldv="$5" newv="$6"
  local before after moved err
  grep -q "\"~> ${oldv}\"" "$dir/01-providers.tf" || {
    note "$repo: $src is pinned somewhere other than 01-providers.tf — needs a human"; return 1; }
  before="$(locked_versions "$dir")"
  sed -i "s|\"~> ${oldv}\"|\"~> ${newv}\"|" "$dir/01-providers.tf"
  err="$WORKDIR/tf-$repo-${src##*/}.err"

  # init -upgrade FIRST. `providers lock` alone refuses while the lockfile
  # still pins a version the new constraint excludes, and says so plainly:
  # "must use terraform init -upgrade to allow selection of new versions".
  # Then lock for every platform the file already covers - regenerating for
  # the runner alone leaves a contributor on a Mac with a lockfile that
  # refuses their machine.
  if ! docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$dir":/mnt -w /mnt "$tfimage" \
        init -upgrade -backend=false -input=false >"$err" 2>&1 \
     || ! docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$dir":/mnt -w /mnt "$tfimage" \
        providers lock -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64 -platform=windows_amd64 >>"$err" 2>&1; then
    note "$repo: the lockfile could not be regenerated for $src $newv: $(grep -m1 -oE '[A-Z][^│]{20,150}' "$err" | tail -1) — needs a human"
    rm -rf "$dir/.terraform"
    git -C "$dir" checkout -- 01-providers.tf .terraform.lock.hcl 2>/dev/null || true
    return 1
  fi
  rm -rf "$dir/.terraform"

  after="$(locked_versions "$dir")"
  if ! grep -qx "${src}=${newv}" <<<"$after"; then
    note "$repo: $src did not reach $newv in the lockfile after the upgrade — needs a human"
    git -C "$dir" checkout -- 01-providers.tf .terraform.lock.hcl 2>/dev/null || true
    return 1
  fi
  # Say what actually moved, not what was asked for: `init -upgrade` may lift
  # another provider inside its own constraint at the same time, and a
  # changelog that names only one of them is a changelog that lies.
  moved="$(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ')"
  note "$repo: lockfile regenerated for four platforms; moved: ${moved:-nothing}"
  for entry in $moved; do
    local ps="${entry%%=*}" pv="${entry##*=}" pold
    pold="$(grep -m1 "^${ps}=" <<<"$before" | cut -d= -f2 || true)"
    changelog_line "$dir" "Changed" "- **\`${ps}\` ${pold:-unknown} → ${pv}.** The constraint and the lockfile moved together, and the lockfile carries all four platforms it covered before. \`terraform validate\` ran against the new provider before this landed — that is what catches an argument it renamed or removed."
  done
  return 0
}

terraform_major_branch() {
  local dir="$1" repo="$2" src="$3" oldv="$4" newv="$5"
  local br="bump/${src##*/}-${newv}"
  [ "$DRY_RUN" = "true" ] && { note "$repo: would prepare branch $br"; return 0; }
  git -C "$dir" checkout -q -B "$br" main
  case "$src" in
    */*) sed -i "s|\"~> ${oldv}\"|\"~> ${newv}\"|" "$dir/01-providers.tf" ;;
    *) note "$repo: $src crosses a major and is not a provider — reported only, nothing prepared"; git -C "$dir" checkout -q main; return 0 ;;
  esac
  changelog_line "$dir" "Changed" "- **\`${src}\` ${oldv} → ${newv}.** A major provider release: read its notes, regenerate the lockfile with \`terraform providers lock\`, and let CI validate before merging."
  git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
    commit -aqm "chore(deps): move $src to $newv" -m "A major provider release, prepared by fleet triage and not landed by it. The lockfile is NOT regenerated here: run terraform providers lock with the four platforms after reading the provider's notes. The decision to merge stays with a person." || true
  if ! git -C "$dir" push -q -f origin "$br"; then
    note "$repo: the branch $br could not be pushed — needs a human"
    git -C "$dir" checkout -q main
    return 0
  fi
  git -C "$dir" checkout -q main
  note "$repo: MAJOR $src $oldv -> $newv prepared on branch \`$br\` — open it: https://github.com/$OWNER/$repo/compare/main...$br?expand=1 — needs a human"
  PREPARED_THIS_RUN+=("$repo:$br")
}

# A prepared branch is a question put to a person, and a question stops being
# one when the answer arrives somewhere else. bump/tls-4.4.0 sat on
# amazon-route53-pipeline-terraform for days proposing a constraint main
# already carried, because the same bump landed automatically on the other
# seven terraform repositories and then on this one.
#
# So: read what the branch adds - every added line outside the changelog, which
# is reworded when it lands and would never match - and ask whether main
# already has all of it. If it does, the branch is finished and goes. If it
# does not, and no pull request is open on it, it is still waiting on somebody
# and says so every run. An open pull request is never touched.
sweep_prepared_branches() {
  local repo="$1" br pr cmp f line content redundant checked bver var mver
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    case " ${PREPARED_THIS_RUN[*]:-} " in *" $repo:$br "*) continue ;; esac
    pr="$(gh pr list --repo "$OWNER/$repo" --head "$br" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [ -z "$pr" ] || continue
    cmp="$(gh api "repos/$OWNER/$repo/compare/main...$br" 2>/dev/null || true)"
    [ -n "$cmp" ] || { note "$repo: \`$br\` could not be compared against main — needs a human"; continue; }
    redundant=1; checked=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$f" = "CHANGELOG.md" ] && continue
      checked=$((checked+1))
      content="$(gh api "repos/$OWNER/$repo/contents/$f?ref=main" -H "Accept: application/vnd.github.raw" 2>/dev/null || true)"
      [ -n "$content" ] || { redundant=0; break; }
      while IFS= read -r line; do
        [ -n "${line// /}" ] || continue
        grep -Fqx -- "$line" <<<"$content" || { redundant=0; break 2; }
      done < <(jq -r --arg f "$f" '.files[] | select(.filename==$f) | .patch // ""' <<<"$cmp" | { grep '^+' || true; } | { grep -v '^+++' || true; } | sed 's/^+//')
    done < <(jq -r '.files[].filename' <<<"$cmp")
    if [ "$redundant" -eq 1 ] && [ "$checked" -gt 0 ]; then
      if [ "$DRY_RUN" = "true" ]; then
        note "$repo: would delete \`$br\` — every line it prepares is already on main"
      elif gh api -X DELETE "repos/$OWNER/$repo/git/refs/heads/$br" >/dev/null 2>&1; then
        note "$repo: deleted \`$br\` — the change it prepared reached main by another route"
        SWEPT=$((SWEPT+1))
      else
        note "$repo: \`$br\` proposes nothing main lacks but could not be deleted — needs a human"
      fi
    else
      # AHEAD IN COMMITS IS NOT AHEAD IN VERSION. A prepared branch that main
      # has since overtaken proposes going BACKWARDS, and the line above sent
      # it to a person as a decision. Two were waiting when this was written:
      # dozzle `bump/11.0.0` against a main already on v11.0.1, and nextcloud
      # `bump/32.0.15` against a main on 34.0.3 — that one would have offered
      # a two-major downgrade of a database that only migrates forward. The
      # branch name carries the version it prepares; main carries the version
      # it has; sort -V decides, and there is nothing for a person to weigh.
      bver="${br#bump/}"; bver="${bver#v}"
      var="$(jq -r '.files[] | select(.filename|endswith(".yml")) | .patch // ""' <<<"$cmp" \
             | { grep '^+' || true; } | grep -oE '\$\{[A-Z0-9_]+_IMAGE_VERSION:-' | head -1 | sed -E 's/^\$\{//; s/:-$//')"
      mver=""
      if [ -n "$var" ]; then
        mver="$(gh api "repos/$OWNER/$repo/contents/$(jq -r '[.files[] | select(.filename|endswith(".yml")) | .filename][0]' <<<"$cmp")?ref=main" \
                -H "Accept: application/vnd.github.raw" 2>/dev/null \
                | grep -oE "\\\$\\{${var}:-[^}@]*" | head -1 | sed -E 's/.*:-//; s/^v//')"
      fi
      if [ -n "$mver" ] && [ "$(printf '%s\n%s\n' "$bver" "$mver" | sort -V | tail -1)" = "$mver" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          note "$repo: would delete \`$br\` — main is on $mver, so this branch prepares a move backwards"
        elif gh api -X DELETE "repos/$OWNER/$repo/git/refs/heads/$br" >/dev/null 2>&1; then
          note "$repo: deleted \`$br\` — main reached $mver by another route, so this branch only prepared a move backwards"
          SWEPT=$((SWEPT+1))
        else
          note "$repo: \`$br\` prepares $bver against a main already on $mver and could not be deleted — needs a human"
        fi
      else
        note "$repo: \`$br\` is still ahead of main with no pull request open — open it or delete it: https://github.com/$OWNER/$repo/compare/main...$br?expand=1 — needs a human"
      fi
    fi
  done < <(gh api "repos/$OWNER/$repo/branches?per_page=100" --jq '.[].name' 2>/dev/null | { grep '^bump/' || true; })
}

# Commit what changed, push, and let that repository's own CI judge it:
# green keeps it and cuts the release, red reverts it, cancelled leaves it for
# the next run. Both shapes go through here - the gate is the same promise
# whether the pin is an image digest or a provider constraint.
push_and_defer() {
  local dir="$1" repo="$2" wf="$3" sha err
  err="$WORKDIR/push-$repo.err"
  if ! git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
    commit -aqm "fix(security): refresh pins" \
    -m "The freshness check flagged pins that fell behind: tags re-resolving to new digests, provider releases inside the same major. That repository's own CI judges the refreshed combination before it becomes a release; anything wider than a major line is never bumped automatically." >"$err" 2>&1; then
    note "$repo: the refresh could not be committed: $(tail -1 "$err" | cut -c1-160) — needs a human"
    return 0
  fi
  # A rejected push is one repository's problem. Under set -e it used to be
  # the whole run's: on 2026-09-09 the fleet token was refused a workflow
  # file and five repositories queued behind it were never looked at.
  if ! git -C "$dir" push -q origin main >"$err" 2>&1; then
    note "$repo: the refresh could not be pushed: $(grep -m1 -oE '(remote rejected|refusing|denied|protected)[^"]*' "$err" | cut -c1-160 || tail -1 "$err" | cut -c1-160) — needs a human"
    return 0
  fi
  sha="$(git -C "$dir" rev-parse HEAD)"
  pending_add "$repo" "$sha" "$(workflow_for "$repo")" "version"
  note "$repo: pushed refresh $sha — its CI is judged at the next run, which also cuts the release or reverts"
}


# Remember a push instead of standing over it. One entry per repository: if a
# later push supersedes an unjudged one, the newer commit is what main carries
# and therefore what has to be judged.
pending_add() {   # repo sha wf kind
  [ "$DRY_RUN" = "true" ] && return 0
  python3 - "$PENDING" "$1" "$2" "$3" "$4" "$WORKDIR/reviews-$1.md" <<'PY'
import datetime, io, json, os, sys
p, repo, sha, wf, kind, review = sys.argv[1:7]
try:
    d = json.load(io.open(p, encoding="utf-8"))
    if not isinstance(d, list):
        d = []
except Exception:
    d = []
d = [e for e in d if e.get("repo") != repo]
entry = dict(repo=repo, sha=sha, wf=wf, kind=kind,
             pushed_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
# The upstream review was written by the run that pushed the bump, and the run
# that cuts the release is a different one. Carried here so the release notes
# still say what upstream changed.
if os.path.exists(review):
    entry["review"] = io.open(review, encoding="utf-8").read()
d.append(entry)
io.open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2) + "\n")
PY
}

pending_rows() {
  [ -s "$PENDING" ] || return 0
  python3 - "$PENDING" "$WORKDIR" <<'PY'
import datetime, io, json, os, sys
p, workdir = sys.argv[1:3]
try:
    d = json.load(io.open(p, encoding="utf-8"))
except Exception:
    raise SystemExit
now = datetime.datetime.now(datetime.timezone.utc)
for e in d if isinstance(d, list) else []:
    try:
        age = (now - datetime.datetime.fromisoformat(e["pushed_at"].replace("Z", "+00:00"))).total_seconds() / 3600
    except Exception:
        age = 0.0
    if e.get("review"):
        io.open(os.path.join(workdir, "reviews-%s.md" % e["repo"]), "w", encoding="utf-8").write(e["review"])
    print("\t".join([e.get("repo", ""), e.get("sha", ""), e.get("wf", ""), e.get("kind", ""), "%.1f" % age]))
PY
}

pending_keep() {   # the shas that are still waiting; everything else is settled
  [ "$DRY_RUN" = "true" ] && return 0
  python3 - "$PENDING" "$@" <<'PY'
import io, json, sys
p, keep = sys.argv[1], set(sys.argv[2:])
try:
    d = json.load(io.open(p, encoding="utf-8"))
except Exception:
    d = []
io.open(p, "w", encoding="utf-8").write(
    json.dumps([e for e in d if e.get("sha") in keep], indent=2) + "\n")
PY
}

# ONE WAY TO GET A WORKING COPY, because for three days there were two. The
# settling pass cloned into $WORKDIR/$repo behind this guard; the pin-refresh
# pass, four hundred lines further down, cloned into the same path with no
# guard at all. So every repository the settling pass had just released still
# had its directory, and the refresh clone failed on it with "destination path
# already exists and is not an empty directory". Seven repositories reported
# "freshness failed but clone failed too — needs a human" on the same run that
# released them, three times a day, and the report read as seven real problems.
#
# The depth is 50 rather than 1 because a revert needs the commit and its
# parent, and by the next run there may be others on top. Every caller gets
# that depth now; it costs nothing on repositories this size and it means no
# second caller can arrive with its own shallower idea of a clone.
#
# Stderr is deliberately not silenced. The swallowed form told the report the
# clone had failed and told the log nothing about why.
workdir_for() {   # repo -> dir on stdout, or non-zero
  local repo="$1" dir="$WORKDIR/$1"
  [ -d "$dir" ] || git clone -q --depth 50 \
    "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" || return 1
  echo "$dir"
}

# THE OTHER HALF OF push_and_defer, one run later. Everything the old wait loop
# did on an answer it now does on an answer that arrived while nobody was
# holding a runner open for it.
# pending_action <conclusion>: what a pushed refresh's CI answer means.
#   release  green: cut the release
#   wait     still running or not found yet: judged next run
#   keep     cancelled by a later push, or an answer that is not a verdict on
#            the change (skipped, neutral): left in place, judged as HEAD
#   revert   failure or timed_out: the refresh broke the stack
#   hold     GitHub did not answer the lookup: no verdict either way, kept
#            for the next run and never escalated on age
# On 2026-09-25 13:10 twenty-three digest refreshes were reverted at once:
# the pending row carried the freshness workflow, whose push run is always
# skipped, and "skipped" fell into the revert branch. A refresh is judged by
# the verification workflow, and only a red answer reverts it.
pending_action() {
  case "$1" in
    success) echo release ;;
    running|none) echo wait ;;
    unread) echo hold ;;
    failure|timed_out) echo revert ;;
    *) echo keep ;;
  esac
}

settle_pending() {
  [ -s "$PENDING" ] || return 0
  local repo sha wf kind age verdict dir keep=()
  section "Pushed last run, judged now"
  local any=0
  while IFS=$'\t' read -r repo sha wf kind age; do
    [ -n "$repo" ] || continue
    any=1
    # NO ANSWER IS NOT "NO RUN". The lookup's own failure used to be swallowed
    # into an empty result, read as a CI that never answered, and escalated on
    # age: on 2026-10-05 kf2's refresh, green one minute after its push, was
    # reported as unjudged for 16.8 hours and dropped from this ledger, so its
    # release was never cut. A failed lookup is retried once, and if GitHub
    # still says nothing the row is kept, with no verdict, for the next run.
    runs_json="" run_for_sha=""
    for _try in 1 2; do
      if runs_json="$(runs_on_main "$repo" "$wf" 30 headSha,status,conclusion,databaseId 2>/dev/null)" && [ -n "$runs_json" ]; then
        break
      fi
      runs_json=""; sleep 5
    done
    if [ -z "$runs_json" ]; then
      verdict="unread"
    else
      run_for_sha="$(jq -r --arg sha "$sha" '[.[] | select(.headSha==$sha)][0] // empty' <<<"$runs_json" 2>/dev/null || true)"
      verdict="$(jq -r 'if . == null or . == "" then "none" elif .status=="completed" then (.conclusion // "unknown") else "running" end' <<<"${run_for_sha:-null}" 2>/dev/null || echo "none")"
    fi
    # A FRESHNESS FAILURE IS NOT A VERDICT ON WHAT WAS PUSHED. The rerun pass
    # below already reads which jobs failed; this one used the run's overall
    # conclusion, which cannot tell the designed alarm from a real failure.
    if [ "$verdict" = "failure" ]; then
      rid_for_sha="$(jq -r '.databaseId // empty' <<<"${run_for_sha:-null}" 2>/dev/null || true)"
      if [ -n "$rid_for_sha" ]; then
        red_jobs="$(gh run view "$rid_for_sha" --repo "$OWNER/$repo" --json jobs \
            --jq '[.jobs[] | select(.conclusion=="failure") | .name] | join(",")' 2>/dev/null || true)"
        if freshness_only_failure "$red_jobs"; then
          verdict="success"
          note "$repo: the $kind refresh is green — the only red job was [$red_jobs], which is the freshness alarm and not a verdict on what was pushed"
        fi
      fi
    fi
    case "$(pending_action "$verdict")" in
      release)
        note "$repo: the $kind refresh pushed ${age}h ago is green"
        REFRESHED=$((REFRESHED+1))
        HEALED+=("$repo")
        if [ "$DRY_RUN" = "true" ]; then
          note "$repo: would cut the release for it"
        elif dir="$(workdir_for "$repo")" && [ -n "$dir" ]; then
          cut_release "$dir" "$repo"
          # The freshness verdict still describes the pins from before the
          # refresh, and the next run would read that stale red as a finding.
          fwf="$(freshness_wf_for "$repo")" || fwf="$wf"
          gh workflow run "$fwf" --repo "$OWNER/$repo" --ref main >/dev/null 2>&1 \
            || note "$repo: refreshed and green, but re-running its freshness check failed — that verdict stays stale until the next cron"
        else
          note "$repo: green, but the clone for its release failed — the refresh is on main without a release, needs a human"
        fi
        ;;
      hold)
        note "$repo: GitHub did not answer the run lookup for the $kind refresh $sha (pushed ${age}h ago) — no verdict, kept for the next run"
        keep+=("$sha")
        ;;
      wait)
        if [ "${age%%.*}" -ge "$STALE_HOURS" ]; then
          note "$repo: the $kind refresh $sha was pushed ${age}h ago and its CI has still not answered — main carries it unjudged, needs a human"
        else
          note "$repo: the $kind refresh pushed ${age}h ago is still running — judged next run"
          keep+=("$sha")
        fi
        ;;
      keep)
        # Not red: something was pushed on top and GitHub dropped the run, or
        # the answer says nothing about the change. The passes below judge
        # whatever HEAD is now.
        note "$repo: CI answered '$verdict' on the $kind refresh, which is not a verdict on the change — left in place, judged as HEAD below"
        ;;
      revert)
        if [ "$DRY_RUN" = "true" ]; then
          note "$repo: CI answered '$verdict' — would revert $sha"
        elif dir="$(workdir_for "$repo")" && [ -n "$dir" ] \
             && git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" revert --no-edit "$sha" >/dev/null 2>&1 \
             && git -C "$dir" push -q origin main; then
          note "$repo: CI answered '$verdict' on the $kind refresh — reverted, needs a human"
        else
          [ -n "${dir:-}" ] && git -C "$dir" revert --abort >/dev/null 2>&1
          note "$repo: CI answered '$verdict' on the $kind refresh and the revert did not land — main still carries $sha, needs a human"
        fi
        ;;
    esac
  done < <(pending_rows)
  [ "$any" = 1 ] || echo "- nothing was pending" >> "$REPORT"
  pending_keep "${keep[@]+"${keep[@]}"}"
}

# WHETHER A FAILED SCAN BLAMES THE REGISTRY OR THE IMAGE. Reads a run log on
# stdin; true means the scan never got the bytes it asked for.
#
# Deliberately narrow, and "context deadline exceeded" is deliberately NOT in
# it. blackmesa's Trivy died with exactly that on 2026-09-15, and it was real:
# the secret scanner was walking a 257 MB game archive and ran out of its own
# time. Rerunning that forever would have hidden it. What belongs here is the
# registry saying no — a rate limit, a reset, a handshake that timed out —
# because the next attempt gets a different answer. The attempt > 1 guard above
# is what stops even these from being retried twice.
freshness_only_failure() {
  # Were the failed jobs of a run NOTHING BUT the freshness alarm?
  #
  # That job goes red the moment any pin in a repository lags upstream, which
  # has nothing to do with whether the digest just pushed boots. On 2026-09-21
  # gaseous-server had a good refresh reverted on a run where compose up, the
  # HTTPS smoke test, Trivy and the linter all passed and the only red job was
  # upstream drift.
  #
  # An empty list is NOT freshness-only: it means the jobs could not be read,
  # and a revert is the expensive direction to be wrong in.
  local names="$1"
  [ -n "$names" ] || return 1
  ! tr ',' '\n' <<<"$names" | grep -viE 'upstream drift' | grep -qvE '^[[:space:]]*$'
}

registry_refused() {
  # Case-insensitive: ghcr.io says TOOMANYREQUESTS, Docker Hub's daemon says
  # "toomanyrequests: retry-after" (immich, 2026-09-25).
  grep -qiE "TOOMANYREQUESTS|429 Too Many Requests|connection reset by peer|TLS handshake timeout|unexpected EOF|502 Bad Gateway|503 Service Unavailable"
}

# rerun_verdict <failed-jobs> <log-file>: one word saying what a red run is.
#   freshness  only the drift alarm went red; the refresh pass reads it
#   registry   the log says a registry refused it; worth one more attempt
#   deploy     the deploy job failed and the registry did not; a person
#   scan       a scan failed on its own; a person
#   other      anything else; a person
rerun_verdict() {
  local jobs="$1" log="$2"
  if grep -qE "upstream drift" <<<"$jobs" && ! grep -qiE "compose up|deploy|smoke|boot|Trivy|Build the image" <<<"$jobs"; then
    echo freshness; return 0
  fi
  if [ -s "$log" ] && registry_refused < "$log"; then echo registry; return 0; fi
  if grep -qiE "compose up|deploy|smoke|boot" <<<"$jobs"; then echo deploy; return 0; fi
  if grep -qE "Trivy" <<<"$jobs"; then echo scan; return 0; fi
  echo other
}

# THE FRESHNESS ALARM MOVES TO ITS OWN WORKFLOW.
#
# The badge a visitor sees is the Deployment Verification workflow's, and that
# workflow also carried the freshness job - a designed alarm that goes red when
# a pin is one version behind and that this script clears within the day.
# Measured over fourteen days on 2026-09-23: 281 red runs on main, 254 of them
# with no failing job but that alarm. Nine red badges in ten said "a pin is
# behind", and a visitor reads red as "this does not work".
#
# So the job moves to freshness.yml, one repository at a time, and this asks
# which layout a repository has rather than assuming one. Only a 404 means
# "not moved yet". Anything else is an unreadable answer, and falling back
# would read a verification run that no longer carries the alarm, find it
# green, and report nothing - the lag would sit unread, which is the one
# failure this whole file exists to prevent.
freshness_wf_for() {   # freshness_wf_for <repo> -> workflow carrying the freshness verdict
  local err
  if err="$(gh api "repos/$OWNER/$1/contents/.github/workflows/freshness.yml" 2>&1 >/dev/null)"; then
    echo "freshness.yml"
  elif grep -q "HTTP 404" <<<"$err"; then
    workflow_for "$1"
  else
    return 1
  fi
}

workflow_file_for() {
  case "$1" in
    *-terraform) echo "terraform-verification.yml" ;;
    *) echo "deployment-verification.yml" ;;
  esac
}

# EVERYTHING ABOVE IS DEFINITIONS; EVERYTHING BELOW IS THE RUN.
#
# The guard lets a test source this file and exercise one function against a
# real repository. Without it a test has to paste the function into itself,
# and then it is the paste that is tested: major_branch was wrong for weeks in
# a way any direct test would have caught on its first run.
# THE ROBOT AND THE ALARM AGREED BY COINCIDENCE OF WORDING.
#
# Every template writes its own freshness sentence, and this read one shape of
# it. Measured across the fleet on 2026-09-23: fifty-one alarms matched and
# fifty-one did not. Every Traefik pin in the fleet says "pinned minor 3.6,
# latest release is 3.7" and the word "minor" was enough; zabbix says "is
# behind its line: pinned 7.0.30, latest in 7.0 is 7.0.31"; zomboid says
# "newest stable tag is". Those alarms were correct, their logs said so in
# plain English, and nothing could act on them — a lag reported by hand every
# day for as long as it lasted.
#
# So read the two versions out of the sentence instead of requiring one
# sentence. A qualifier after "pinned" is allowed, and the phrase between
# "latest"/"newest" and the version can be anything that is not a comma, which
# covers "release", "tag", "stable tag" and "in 7.0". A line that names no
# second version - rathena counts commits behind a branch - still matches
# nothing, which is right: it is not a version bump.
lag_lines() {        # stdin: a workflow log -> one line per lag it names
  # The pin's variable is kept when the alarm names one ("X_IMAGE_TAG is
  # behind: ..."), so the bump below can move that pin and no other.
  { grep -oE '([A-Z0-9_]+_IMAGE_TAG )?is behind[^:]*: pinned ([a-z]+ )?v?[0-9][^,]*, (latest|newest)[^,]* is v?[0-9][^ "]*' || true; } | sort -u
}

lag_var() {          # lag_var <line> -> the pin variable the alarm names, or nothing
  case "$1" in [A-Z]*_IMAGE_TAG" is behind"*) printf '%s\n' "${1%% is behind*}" ;; esac
}

# A PIN MOVES WHEN IT IS THE ONE THAT LAGS. Matching by version alone moved
# every pin that carried the same string: on 2026-10-01 itzg/mc-backup went
# 2026.9.2 -> 2026.9.3, the server image pins 2026.9.2 too under its own
# release line, and the run tried to move it to a 2026.9.3 that does not
# exist, then asked a person about it. When the alarm names its variable,
# only that pin is touched; when it does not, the version is all there is.
pin_lags() {         # pin_lags <pin> <lag line> <old version> -> 0 if this pin is the one
  local pin="$1" lag="$2" oldv="$3" def var want
  def="${pin#*:-}"; def="${def%\}}"
  case "$def" in *"$oldv"*@sha256:*) ;; *) return 1 ;; esac
  want="$(lag_var "$lag")"
  [ -z "$want" ] && return 0
  var="${pin#\$\{}"; var="${var%%:-*}"
  [ "$var" = "$want" ]
}

# A PRE-RELEASE IS NOT A TARGET, WHATEVER THE FEED CALLS IT. On 2 October
# 2026 requarks published Wiki.js 3.0.0-beta.617 without the pre-release flag,
# releases/latest named it, the template's freshness check went red, and this
# run prepared a branch to move a production template onto a beta. The suffix
# is read, not the flag. Image tags with ordinary hyphens (18.8.0-postgres-
# tomcat, 19.4.1-ee.0, 2022-CU27-ubuntu-22.04) are not pre-releases.
is_prerelease() {    # is_prerelease <version> -> 0 for alpha, beta, rc, preview, dev, nightly
  grep -qiE -- '-(alpha|beta|rc|pre|preview|dev|nightly|snapshot)([.0-9-]|$)' <<<"$1"
}

lag_pair() {         # lag_pair <line> -> old<TAB>new
  local line="$1" old new
  old="$(sed -E 's/^([A-Z0-9_]+_IMAGE_TAG )?is behind[^:]*: pinned ([a-z]+ )?(v?[0-9][^,]*),.*/\3/' <<<"$line")"
  new="$(sed -E 's/.* is (v?[0-9][^ "]*)$/\1/' <<<"$line")"
  printf '%s\t%s\n' "$old" "$new"
}

if [ -n "${FLEET_TEST_SOURCE_ONLY:-}" ]; then return 0; fi

list_repos

# Counters the settle pass and the refresh pass both add to: a repository
# healed by either no longer needs a person.
REFRESHED=0
HEALED=()

# FIRST, because a bump pushed last run that went red is a repository whose CI
# is failing right now. Judged after the rerun pass, that red would be read as
# a flake and rerun, and after the refresh pass its own drift would be
# recalculated from a pin that is about to be reverted.
settle_pending

section "Reruns"
RERUns=0
for repo in "${REPOS[@]}"; do
  wf="$(workflow_for "$repo")"
  run_json="$(runs_on_main "$repo" "$wf" 20 databaseId,conclusion,status,attempt 2>/dev/null || true)"
  if [ -z "$run_json" ]; then continue; fi
  concl="$(jq -r '.[0].conclusion // empty' <<<"$run_json")"
  status="$(jq -r '.[0].status // empty' <<<"$run_json")"
  attempt="$(jq -r '.[0].attempt // 1' <<<"$run_json")"
  rid="$(jq -r '.[0].databaseId // empty' <<<"$run_json")"
  if [ "$status" != "completed" ] || [ "$concl" != "failure" ]; then continue; fi
  if [ "$attempt" -gt 1 ]; then
    note "$repo: run $rid failed on attempt $attempt — already retried, needs a human"
    continue
  fi
  # Only the deploy job failed? Then it smells like a flake.
  failed_jobs="$(gh run view "$rid" --repo "$OWNER/$repo" --json jobs \
      --jq '[.jobs[] | select(.conclusion=="failure") | .name] | join(",")')"
  case "$failed_jobs" in
    "docker compose up"*|"Build the image"*)
      if [ "$DRY_RUN" = "true" ]; then
        note "$repo: would rerun failed deploy job of run $rid ($failed_jobs)"
      else
        gh run rerun "$rid" --repo "$OWNER/$repo" --failed
        note "$repo: reran failed deploy job of run $rid ($failed_jobs)"
        RERUns=$((RERUns+1))
      fi
      ;;
    *)
      # THE REGISTRY IS READ BEFORE THE JOB NAMES. A scan-only failure used to
      # fall through to "needs a human"; immich arrived that way on 2026-09-18
      # with ghcr.io answering TOOMANYREQUESTS, and the log has been read for
      # that since. On 2026-09-25 the same registry refused the three scans AND
      # the deploy's pulls in one run, the deploy job's name matched first, and
      # the verdict was "not a deploy flake, needs a human" without the log
      # ever being opened. Now the log decides first, whatever failed.
      logf="$(mktemp)"
      gh run view "$rid" --repo "$OWNER/$repo" --log > "$logf" 2>/dev/null || true
      verdict="$(rerun_verdict "$failed_jobs" "$logf")"
      rm -f "$logf"
      case "$verdict" in
        registry)
          if [ "$DRY_RUN" = "true" ]; then
            note "$repo: would rerun run $rid — the registry refused it ($failed_jobs), not the repository"
          elif gh run rerun "$rid" --repo "$OWNER/$repo" --failed >/dev/null 2>&1; then
            note "$repo: reran run $rid — the registry refused it ($failed_jobs), not the repository"
            RERUns=$((RERUns+1))
          else
            note "$repo: run $rid failed in [$failed_jobs] and could not be rerun — needs a human"
          fi
          ;;
        freshness) note "$repo: run $rid failed in [$failed_jobs] — freshness, handled below" ;;
        scan) note "$repo: run $rid failed in [$failed_jobs] — the scan itself failed rather than the registry, needs a human" ;;
        *) note "$repo: run $rid failed in [$failed_jobs] — not a deploy flake, needs a human" ;;
      esac
      ;;
  esac
done
# Scorecard, separately: it runs in every repository and fails when GitHub's
# GraphQL API fails, which says nothing about the repository and reaches the
# maintainer as an email anyway. Rerun ONLY when the log carries GitHub's own
# error; a genuine Scorecard failure is reported and left alone.
for repo in "${REPOS[@]}"; do
  budget_left || continue
  scj="$( (runs_on_main "$repo" 'OpenSSF Scorecard' 20 databaseId,conclusion,status,attempt 2>/dev/null || true) | jq -c '.[0] // empty')"
  [ -n "$scj" ] || continue
  [ "$(jq -r '.status // empty' <<<"$scj")" = "completed" ] || continue
  [ "$(jq -r '.conclusion // empty' <<<"$scj")" = "failure" ] || continue
  scid="$(jq -r '.databaseId' <<<"$scj")"
  if [ "$(jq -r '.attempt // 1' <<<"$scj")" -gt 1 ]; then
    note "$repo: Scorecard run $scid failed twice — not GitHub having a moment, needs a human"
    continue
  fi
  # WHICH STEP FAILED, asked before the log is fetched, because this is one
  # API call and the log is a download of the whole run.
  #
  # A failure confined to the SARIF upload is not this repository's either:
  # Scorecard finished and GitHub's code-scanning endpoint refused the result.
  # On 2026-09-15 forgejo failed exactly that way, with the analysis green
  # above it and nothing in the log between "Uploading results" and cleanup,
  # and it was reported as a real finding three times a day. It asked a person
  # to go and look at a repository that had nothing wrong with it, which is the
  # most expensive kind of false alarm: the next real one is read the same way.
  #
  # The attempt > 1 guard above is what keeps this honest. An upload that fails
  # twice is escalated, so a repository with code scanning genuinely switched
  # off is still found, one run later.
  failed_steps="$( (gh run view "$scid" --repo "$OWNER/$repo" --json jobs 2>/dev/null || true) \
      | jq -r '[.jobs[].steps[] | select(.conclusion=="failure") | .name] | unique | join("|")' 2>/dev/null || true)"
  why=""
  case "$failed_steps" in
    "Upload SARIF to GitHub Security tab")
      why="the analysis passed and only GitHub's code-scanning upload failed" ;;
  esac
  if [ -z "$why" ] && (gh run view "$scid" --repo "$OWNER/$repo" --log 2>/dev/null || true) \
      | grep -qE "scorecard had an error: internal error|githubv4\.Query: Something went wrong"; then
    why="GitHub's API failed, not this repository"
  fi

  if [ -z "$why" ]; then
    note "$repo: Scorecard run $scid failed on its own terms — needs a human"
  elif [ "$DRY_RUN" = "true" ]; then
    note "$repo: would rerun Scorecard run $scid ($why)"
  elif gh run rerun "$scid" --repo "$OWNER/$repo" >/dev/null 2>&1; then
    note "$repo: reran Scorecard run $scid — $why"
    RERUns=$((RERUns+1))
  else
    note "$repo: Scorecard run $scid failed inside GitHub and could not be rerun — needs a human"
  fi
done
if [ "$RERUns" -eq 0 ]; then echo "- nothing rerun" >> "$REPORT"; fi

section "Pin refreshes (digest repushes + patch releases)"
NOT_REACHED=()
PREPARED_THIS_RUN=()
SWEPT=0
for repo in "${REPOS[@]}"; do
  # Each refresh below pushes and then waits for that repository's whole CI,
  # so the queue is measured in tens of minutes, not seconds. Stop while there
  # is still time to write a report rather than being cut off inside one.
  if ! budget_left; then NOT_REACHED+=("$repo"); continue; fi
  # Freshness verdict comes from the latest schedule/dispatch run of whichever
  # workflow carries it in this repository.
  if ! wf="$(freshness_wf_for "$repo")"; then
    note "$repo: could not tell which workflow carries its freshness check — not judged this run, needs a look if it repeats"
    continue
  fi
  frj="$( (gh run list --repo "$OWNER/$repo" --workflow "$wf" --limit 10 \
      --json databaseId,event,conclusion,status,headSha 2>/dev/null || true) \
      | jq -c '[.[] | select(.event=="schedule" or .event=="workflow_dispatch") | select(.status=="completed")][0] // empty')"
  if [ -z "$frj" ]; then continue; fi
  fr="$(jq -r '.conclusion // empty' <<<"$frj")"
  frid="$(jq -r '.databaseId // empty' <<<"$frj")"
  frsha="$(jq -r '.headSha // empty' <<<"$frj")"
  if [ "$fr" != "failure" ]; then continue; fi

  # A VERDICT ABOUT CODE THAT IS NO LONGER THERE IS NOT A FINDING.
  #
  # The freshness job runs on a cron. A refresh this script pushed since then
  # has moved main, so the red it left behind describes pins that were replaced
  # hours ago. Reading it anyway finds no new drift to fix and reports "nothing
  # was auto-fixable — needs a human" about a repository that was fixed.
  #
  # On 2026-09-17 that put nine repositories in the decision list of a report
  # which, a few lines above, said of each of them "the digest refresh is
  # green" and "released v1.0.1". One document, two contradictory sentences,
  # nine times over, and twelve decisions mailed where three were real.
  #
  # Comparing the run's head against main is the exact question, and it is one
  # API call. The cost of being wrong is one cron's delay on a repository whose
  # pins have just been rewritten; the cost of the old behaviour was a decision
  # list nobody can trust, which is the more expensive of the two by a distance.
  head_sha="$(gh api "repos/$OWNER/$repo/commits/main" -q .sha 2>/dev/null || true)"
  if [ -n "$head_sha" ] && [ -n "$frsha" ] && [ "$head_sha" != "$frsha" ]; then
    note "$repo: its freshness verdict is about ${frsha:0:8} and main is ${head_sha:0:8} — the red predates the change, judged when the next check lands"
    continue
  fi

  dir="$(workdir_for "$repo")" || {
    note "$repo: freshness failed and the clone failed too — needs a human"; continue; }
  # EVERY compose file in the repository, not the first one found. This used
  # to be `find ... -print -quit`: outline-keycloak ships three compose files
  # and dashy two, so a pin that drifted anywhere but the first was reported
  # by that repository's own freshness job and then skipped here. On
  # 2026-09-06 outline-keycloak sat red with a stale traefik pin while this
  # script reported that nothing was auto-fixable.
  # A terraform template pins a constraint and a lockfile, not an image
  # digest, and its gate proves something else: validate against the new
  # provider is what catches an argument it renamed. Its own branch, then.
  case "$repo" in
    *-terraform)
      terraform_refresh "$dir" "$repo" "$frid"
      drift_fixed="$TF_CHANGED"
      if [ "$drift_fixed" -eq 1 ]; then push_and_defer "$dir" "$repo" "$wf"; fi
      continue
      ;;
  esac

  composes=()
  while IFS= read -r _f; do
    [ -n "$_f" ] && composes+=("$_f")
  done < <(find "$dir" -maxdepth 1 -name '*.yml' | sort)
  [ "${#composes[@]}" -gt 0 ] || { note "$repo: freshness failed, no compose file found — needs a human"; continue; }

  # Pins are `${X_IMAGE_TAG:-repo:${X_IMAGE_VERSION:-tag@sha256:digest}}`
  # (or the older flat form); the sed loop below folds the inner default
  # so every pin reads as `${X_IMAGE_TAG:-repo:tag@sha256:digest}`.
  drift_fixed=0 lag_seen=0 PREPARED_MAJOR=0 UNRESOLVED_TAG=0
  while IFS= read -r pin; do
    var="${pin#\$\{}"; var="${var%%:-*}"
    def="${pin#*:-}"; def="${def%\}}"
    case "$def" in *@sha256:*) ;; *) continue ;; esac
    ref="${def%%@*}"; old_digest="${def##*@}"
    new_digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true)"
    [ -n "$new_digest" ] || { note "$repo: $ref did not resolve — registry hiccup or dead tag, needs a human"; continue; }
    if [ "$new_digest" != "$old_digest" ]; then
      for _c in "${composes[@]}"; do
        grep -q "@${old_digest}" "$_c" || continue
        tmpf="$(mktemp)"
        sed "s|@${old_digest}|@${new_digest}|" "$_c" > "$tmpf"
        cat "$tmpf" > "$_c"; rm -f "$tmpf"
      done
      note "$repo: $var — $ref repushed upstream ($old_digest -> $new_digest)"
      changelog_line "$dir" "Security" "- **\`${ref}\` was rebuilt upstream**; the pin moved from \`${old_digest:0:19}…\` to \`${new_digest:0:19}…\`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer."
      drift_fixed=1
    fi
  done < <(grep -h -oE '\$\{[A-Z0-9_]+_IMAGE_TAG:-.*' "${composes[@]}" | sed -E -e ':a' -e 's/(\$\{[A-Z0-9_]+_IMAGE_TAG:-[^{}]*)\$\{[A-Z0-9_]+:-([^{}]*)\}/\1\2/' -e 'ta' | sort -u)

  # A log with no lag line is the normal case, so the grep below is wrapped:
  # an empty match returns 1, and under pipefail that ended the whole triage
  # run instead of this one repository's check.
  # Patch-level version bumps. The freshness log names each lag exactly
  # ("... is behind: pinned X, latest tag is Y", and some jobs name the
  # source between "latest" and "release"); bumps that stay inside
  # the same major.minor ride the same commit and CI gate as digest
  # refreshes. Anything wider is a decision, not a chore — reported only.
  lags="$( (gh run view "$frid" --repo "$OWNER/$repo" --log 2>/dev/null || true) | lag_lines)"
  while IFS= read -r lag; do
    if [ -z "$lag" ]; then continue; fi
    oldv="$(lag_pair "$lag" | cut -f1)"
    newv="$(lag_pair "$lag" | cut -f2)"
    ob="${oldv#v}"; nb="${newv#v}"
    if is_prerelease "$newv"; then
      note "$repo: upstream names $newv as its latest, which is a pre-release whatever its flag says — not applied, not prepared; the freshness check should read stable releases only"
      continue
    fi
    # THE MAJOR IS THE LINE. Inside one major, a minor or a patch rides the
    # same commit, CI gate and revert as a digest refresh: the deploy job boots
    # the stack on the new image before anything stays on main. Across a
    # major, the change is made on a BRANCH and reported with its compare
    # link, so the decision is one click and the work is already done. The
    # freshness jobs that scope themselves to one line (mssql 2022) never
    # report across it, so this never sees those.
    if [ "${ob%%.*}" != "${nb%%.*}" ]; then
      while IFS= read -r pin; do
        def="${pin#*:-}"; def="${def%\}}"
        case "$def" in *"$oldv"*@sha256:*) review_bump "$dir" "$repo" "${def%%@*}" "$oldv" "$newv" ;; esac
      done < <(grep -h -oE '\$\{[A-Z0-9_]+_IMAGE_TAG:-.*' "${composes[@]}" | sed -E -e ':a' -e 's/(\$\{[A-Z0-9_]+_IMAGE_TAG:-[^{}]*)\$\{[A-Z0-9_]+:-([^{}]*)\}/\1\2/' -e 'ta' | sort -u)
      major_branch "$oldv" "$newv"
      continue
    fi
    while IFS= read -r pin; do
      def="${pin#*:-}"; def="${def%\}}"
      pin_lags "$pin" "$lag" "$oldv" || continue
      ref="${def%%@*}"; olddg="${def##*@}"
      newref="${ref//$oldv/$newv}"
      newdg="$(docker buildx imagetools inspect "$newref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true)"
      if [ -z "$newdg" ]; then
        # The vendor's own freshness feed names a version whose image is not
        # published. Nothing here can fix that and the next run retries, but it
        # is not nothing either: a tag that never appears leaves this
        # repository red forever, so it is said once, plainly, instead of twice
        # as itself and again as "nothing was auto-fixable".
        note "$repo: $newref is announced upstream but not published yet — skipped, retried next run; if it never appears the freshness check stays red — needs a human"
        UNRESOLVED_TAG=1
        continue
      fi
      if [ "$DRY_RUN" = "true" ]; then
        note "$repo: would bump $ref -> $newref@$newdg"
        continue
      fi
      # Upstream first. A verdict of DO NOT APPLY UNATTENDED turns this bump
      # into a prepared branch, exactly as a major: the CI gate proves a fresh
      # start and the upgrade drill proves the data path, but neither reads a
      # release note that says "rename this variable before you start".
      review_bump "$dir" "$repo" "$ref" "$oldv" "$newv"
      case "$REVIEW_VERDICT" in
        "DO NOT APPLY UNATTENDED"*)
          note "$repo: $ref $oldv -> $newv is inside a major but the upstream review says do not apply unattended — prepared on a branch instead"
          major_branch "$oldv" "$newv"
          # BREAK, NOT CONTINUE. major_branch takes every pin carrying this
          # version onto the branch, so the remaining pins in this loop are
          # already handled and must not also be bumped on main. Continuing
          # here is how GitLab's runner reached main at 19.4.0 on 2026-09-18
          # while the server it is supposed to track stayed at 19.3.2 — the
          # server was held for review, the runner walked past it, and the
          # review attached to that same run was the thing warning against
          # exactly that.
          break ;;
      esac
      # A BUMP THAT EDITED NOTHING IS NOT A BUMP. Skipping a compose file that
      # does not carry the old version and digest is right; running the lines
      # below anyway was not. Until 2026-09-13 the report said "version bump",
      # the changelog announced the new version, the CI gate passed and a
      # release went out, while the pin on main had never moved. The gate
      # passed because nothing had changed, which is all a gate can prove when
      # the change it guards never happened.
      #
      # GitLab shipped v1.6.6 that way. The freshness check reports the version
      # as 19.3.1 while the image tag is 19.3.1-ee.0, so the substitution built
      # from the reported version matched nothing, and the release announced
      # 19.3.2 over a file still pinning 19.3.1.
      # The tag, for the reason written against the same substitution in
      # major_branch: the reported version and the image tag are not always
      # the same string, and the file contains the tag.
      oldtag="${ref##*:}"; newtag="${newref##*:}"
      bumped=0
      for _c in "${composes[@]}"; do
        grep -q "${oldtag}@${olddg}" "$_c" || continue
        tmpf="$(mktemp)"
        sed "s|${oldtag}@${olddg}|${newtag}@${newdg}|" "$_c" > "$tmpf"
        cat "$tmpf" > "$_c"; rm -f "$tmpf"
        bumped=1
      done
      if [ "$bumped" -eq 0 ]; then
        note "$repo: $ref $oldv -> $newv could NOT be applied — no compose file carries ${oldtag}@${olddg}, so the pin was left alone and nothing was written. Needs a person."
        continue
      fi
      readme_version "$dir" "$oldv" "$newv"
      vervar="${pin#\$\{}"; vervar="${vervar%%:-*}"; vervar="${vervar%_IMAGE_TAG}_IMAGE_VERSION"
      example_version "$dir" "$vervar" "$oldtag" "$newtag"
      note "$repo: version bump $ref -> $newref"
      changelog_line "$dir" "Changed" "- **\`${ref}\` moved to \`${newref}\`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed."
      drift_fixed=1
    done < <(grep -h -oE '\$\{[A-Z0-9_]+_IMAGE_TAG:-.*' "${composes[@]}" | sed -E -e ':a' -e 's/(\$\{[A-Z0-9_]+_IMAGE_TAG:-[^{}]*)\$\{[A-Z0-9_]+:-([^{}]*)\}/\1\2/' -e 'ta' | sort -u)
  done <<<"$lags"

  if [ "$drift_fixed" -eq 1 ]; then
    if [ "$DRY_RUN" = "true" ]; then
      note "$repo: would commit and push the digest refresh"
      continue
    fi
    git -C "$dir" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
      commit -aqm "fix(security): refresh pins (upstream repushes, patch releases)

The freshness check flagged pins that fell behind: tags re-resolving
to new digests (base-image security rebuilds) and patch releases
inside the same major.minor. The deploy job boots and smoke-tests the
refreshed combination before this stays on main; anything wider than a
patch is never bumped automatically."
    git -C "$dir" push -q origin main
    sha="$(git -C "$dir" rev-parse HEAD)"
    pending_add "$repo" "$sha" "$(workflow_for "$repo")" "digest"
    note "$repo: pushed digest refresh $sha — its CI is judged at the next run, which also cuts the release or reverts"
  else
    lag_seen=1
  fi
  if [ "$lag_seen" -eq 1 ]; then
    # NO DIGEST REFRESH IS NOT THE SAME AS NOTHING DONE. Three different
    # outcomes used to arrive here and all three were reported with the same
    # sentence. A prepared major branch IS the action, and saying nothing was
    # fixable beside its compare link was simply untrue. An unpublished tag is
    # a wait, and it already says so one line above. Only the third case is a
    # person's to look at, and lumping the other two in with it is what made
    # this report count five decisions on a day it had three.
    if [ "$PREPARED_MAJOR" -eq 1 ] || [ "$UNRESOLVED_TAG" -eq 1 ]; then
      :
    else
      note "$repo: freshness is red but nothing was auto-fixable — see the run log, needs a human"
    fi
  fi
done
if [ "$REFRESHED" -eq 0 ]; then echo "- nothing refreshed" >> "$REPORT"; fi

section "Prepared branches"
for repo in "${REPOS[@]}"; do sweep_prepared_branches "$repo"; done
if [ "$SWEPT" -eq 0 ]; then echo "- nothing to sweep" >> "$REPORT"; fi
if [ "${#NOT_REACHED[@]}" -gt 0 ]; then
  section "Not reached — the run ran out of time"
  note "${#NOT_REACHED[@]} repositories were not looked at: ${NOT_REACHED[*]}"
  note "They are still red, so the next run picks them up. Re-run this workflow to continue now."
fi

if [ -f "$WORKDIR/reviews.md" ]; then
  { echo; echo "### Upstream reviews"; echo; echo "What upstream changed for every bump this run prepared, read against the template before it moved."; cat "$WORKDIR/reviews.md"; } >> "$REPORT"
fi
echo
cat "$REPORT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
fi
# A repository this run healed no longer needs a person, whatever the rerun
# stage thought before the refresh stage reached it. sonarqube failed its
# freshness job AND its deploy smoke on 2026-09-10 because the pinned digest
# had been repushed; the rerun stage declined to call that a flake and wrote
# "needs a human", the refresh stage of the same run then replaced the digest,
# watched CI go green and cut a release, and the issue still opened. Only the
# provisional line is rewritten - the one naming a run id - so a real finding
# about a different pin in the same repository survives.
if [ "${#HEALED[@]}" -gt 0 ]; then
  python3 - "$REPORT" "${HEALED[@]}" <<'PY'
import io, re, sys
p, healed = sys.argv[1], set(sys.argv[2:])
out = []
for line in io.open(p, encoding="utf-8").read().splitlines():
    m = re.match(r"^- ([^:]+): run \d+ failed in \[.*\] . .*needs a human$", line)
    if m and m.group(1) in healed:
        line = line.replace("needs a human", "and this run fixed it below")
    out.append(line)
io.open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
fi

# The report outlives this script: the workflow turns it into an issue when a
# line in it needs a person. Counted here, where the lines are.
if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  cp "$REPORT" "$GITHUB_WORKSPACE/triage-report.md"
  humans="$(grep -c 'needs a human' "$REPORT" || true)"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "needs_human=$humans" >> "$GITHUB_OUTPUT"
fi
