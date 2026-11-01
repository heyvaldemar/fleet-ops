#!/bin/bash
# One-shot rollout: a CodeQL workflow (templates/codeql.yml) into every public
# repository that does not carry one, in place of GitHub's default setup.
#
# WHAT IT FIXES. On 2026-11-01 OpenSSF Scorecard scored SAST 0/10 on 32 public
# repositories, 33 of which had CodeQL default setup switched on that same
# day. Scorecard finds SAST in two places: code-scanning check runs on merged
# pull requests, and a workflow file that runs github/codeql-action/analyze.
# Default setup has no file, and a repository whose commits reach main without
# a pull request has no check runs to read, so the analysis ran and the score
# said it did not. The rest of the fleet scored 10 only because Dependabot's
# pull requests upload Trivy results; none of them analysed its own workflows.
#
# Per repository: the languages are default setup's own list when it is on,
# otherwise GitHub's language statistics mapped to what CodeQL reads without a
# build (python, javascript-typescript, ruby), plus actions. A repository that
# needs a compiled language is reported and left alone. The file is pushed with
# [skip ci], default setup is switched off (GitHub refuses an advanced upload
# while it is on), and the workflow is started once by hand. Afterwards
# CHECK=true reports each repository's latest run, and DISMISS_SLSA=true closes
# the one alert every repository raises (see below).
#
# Idempotent: a repository that already has .github/workflows/codeql.yml is
# not touched.
set -euo pipefail
# shellcheck source=scripts/git-auth.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-auth.sh"  # GH_TOKEN reaches git by environment, never in a URL

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
CHECK="${CHECK:-false}"   # true: report the latest CodeQL run per repository, change nothing
ONLY="${ONLY:-}"
# fleet-ops is published from fleet-ops-private, which overwrites a commit made
# to it directly; heyvaldemar-com changes through its own process.
SKIP="${SKIP:-fleet-ops heyvaldemar-com}"
COMMIT_SUBJECT="${COMMIT_SUBJECT:-ci: CodeQL as a workflow file, in place of default setup}"
COMMIT_BODY="${COMMIT_BODY:-The same analysis, now pinned by commit, kept current by Dependabot and visible to OpenSSF Scorecard, whose SAST check cannot see default setup. It reads the GitHub Actions workflows here, and its code where CodeQL needs no build, on every change to the default branch, on pull requests and weekly.

[skip ci]}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/../templates/codeql.yml"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
[ "$DRY_RUN" = "true" ] || trap 'rm -rf "$WORKDIR"' EXIT
[ -f "$TEMPLATE" ] || { echo "::error::missing $TEMPLATE"; exit 1; }

REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
  --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | .name' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

# The one finding the first runs make everywhere: release-assets.yml calls the
# SLSA generator by tag. That is required, not an oversight: slsa-verifier
# checks the generator's ref, and the generator's README says it MUST be
# referenced as @vX.Y.Z (slsa-framework/slsa-verifier#12). Only that alert is
# dismissed, with that reason; every other unpinned tag stays open.
if [ "${DISMISS_SLSA:-false}" = "true" ]; then
  why="slsa-github-generator must be called by its full tag: slsa-verifier checks the generator's ref, and the generator's README says it MUST be referenced as @vX.Y.Z, never by hash (slsa-framework/slsa-verifier#12)."
  N=0
  for repo in "${REPOS[@]}"; do
    [ -n "$ONLY" ] && [ "$repo" != "$ONLY" ] && continue
    case " $SKIP " in *" $repo "*) continue ;; esac
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      gh api -X PATCH "repos/$OWNER/$repo/code-scanning/alerts/$n" -f state=dismissed \
        -f dismissed_reason="won't fix" -f dismissed_comment="$why" --silent && N=$((N + 1))
    done < <(gh api "repos/$OWNER/$repo/code-scanning/alerts?state=open&tool_name=CodeQL&per_page=100" \
      --jq '.[] | select(.rule.id == "actions/unpinned-tag")
                | select(.most_recent_instance.location.path == ".github/workflows/release-assets.yml")
                | select(.most_recent_instance.message.text | contains("slsa-framework/slsa-github-generator/"))
                | .number' 2>/dev/null || true)
  done
  echo "dismissed: $N"
  exit 0
fi

if [ "$CHECK" = "true" ]; then
  for repo in "${REPOS[@]}"; do
    [ -n "$ONLY" ] && [ "$repo" != "$ONLY" ] && continue
    case " $SKIP " in *" $repo "*) continue ;; esac
    run="$(gh api "repos/$OWNER/$repo/actions/workflows/codeql.yml/runs?per_page=1" \
      --jq '.workflow_runs[0] | "\(.status) \(.conclusion) \(.html_url)"' 2>/dev/null || true)"
    echo "$repo ${run:-no CodeQL workflow}"
  done
  exit 0
fi

# What CodeQL reads with build-mode none. Anything else needs a build and a
# person to say how.
languages_of() {  # repo -> comma-separated CodeQL languages, or "!<language>" when one needs a build
  local repo="$1" state langs
  state="$(gh api "repos/$OWNER/$repo/code-scanning/default-setup" --jq '.state + " " + (.languages | join(","))' 2>/dev/null || true)"
  if [ "${state%% *}" = "configured" ]; then
    langs="${state#* }"
  else
    # Under 512 bytes is not code to analyse: homepage-traefik-letsencrypt-
    # docker-compose's only JavaScript was a 79-byte example config, and
    # CodeQL fails a language in which it can parse nothing.
    langs="$(gh api "repos/$OWNER/$repo/languages" --jq 'to_entries | map(select(.value >= 512) | .key) | join(",")' 2>/dev/null || true)"
  fi
  python3 - "$langs" <<'PY'
import sys
seen = []
build = {"go", "java", "java-kotlin", "kotlin", "c", "c++", "c-cpp", "cpp", "c#", "csharp", "swift"}
names = {"python": "python", "javascript": "javascript-typescript", "typescript": "javascript-typescript",
         "javascript-typescript": "javascript-typescript", "ruby": "ruby", "actions": "actions"}
for raw in filter(None, sys.argv[1].split(",")):
    k = raw.strip().lower()
    if k in build:
        print("!" + raw); sys.exit(0)
    v = names.get(k)
    if v and v not in seen:
        seen.append(v)
if "actions" not in seen:
    seen.append("actions")
# actions last, as in the eight repositories that carried this file first.
seen.sort(key=lambda v: v == "actions")
print(",".join(seen))
PY
}

describe() {  # comma-separated languages -> the words for the file's comment
  local words=() l
  IFS=, read -ra ls <<<"$1"
  for l in "${ls[@]}"; do
    case "$l" in
      python) words+=("Python") ;;
      javascript-typescript) words+=("JavaScript and TypeScript") ;;
      ruby) words+=("Ruby") ;;
    esac
  done
  if [ "${#words[@]}" -eq 0 ]; then
    echo "this repository's GitHub Actions workflows"
  else
    local joined
    joined="$(printf '%s, ' "${words[@]}")"; joined="${joined%, }"
    echo "this repository's $joined and of its GitHub Actions workflows"
  fi
}

ADDED=0; SKIPPED=0; NEEDS_BUILD=0; FAILED=0; DISPATCHED=0
for repo in "${REPOS[@]}"; do
  [ -n "$ONLY" ] && [ "$repo" != "$ONLY" ] && continue
  case " $SKIP " in *" $repo "*) continue ;; esac
  if gh api "repos/$OWNER/$repo/contents/.github/workflows/codeql.yml" --silent 2>/dev/null; then
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  langs="$(languages_of "$repo")"
  case "$langs" in
    "!"*) echo "  $repo: ${langs#!} needs a build; left alone"; NEEDS_BUILD=$((NEEDS_BUILD + 1)); continue ;;
  esac
  branch="$(gh api "repos/$OWNER/$repo" --jq .default_branch)"
  # Spread the weekly runs over the week, the same slot for a repository every
  # time the script runs.
  sum="$(printf '%s' "$repo" | cksum | cut -d' ' -f1)"
  cron="$((sum % 60)) $((3 + sum / 60 % 5)) * * $((sum / 300 % 7))"
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://github.com/$OWNER/$repo" "$dir" 2>/dev/null || { echo "  $repo: could not clone"; FAILED=$((FAILED + 1)); continue; }
  mkdir -p "$dir/.github/workflows"
  what="$(describe "$langs")"
  python3 - "$TEMPLATE" "$dir/.github/workflows/codeql.yml" "$what" "$branch" "$cron" "${langs//,/, }" <<'PY'
import io, re, sys, textwrap
src, dst, what, branch, cron, langs = sys.argv[1:]
s = io.open(src, encoding="utf-8").read()
for k, v in (("@WHAT@", what), ("@BRANCH@", branch), ("@CRON@", cron), ("@LANGUAGES@", langs)):
    assert k in s, k
    s = s.replace(k, v)
assert "@" not in s.replace("@3d3c", "").replace("@9b32", ""), "a placeholder survived"
# The words put in can make the opening comment's lines any length: wrap it again.
m = re.search(r"\n\n((?:# [^\n]*\n)+)on:\n", s)
text = " ".join(line[2:] for line in m.group(1).splitlines())
s = s[:m.start(1)] + textwrap.fill(text, 78, initial_indent="# ", subsequent_indent="# ") + "\n" + s[m.end(1):]
io.open(dst, "w", encoding="utf-8").write(s)
PY
  if ! actionlint "$dir/.github/workflows/codeql.yml" >/dev/null 2>&1; then
    echo "  $repo: actionlint refuses the generated file; left alone"; FAILED=$((FAILED + 1)); continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "  would push to $repo ($branch): $langs, cron $cron"
    continue
  fi
  rc=0
  (
    cd "$dir"
    git add .github/workflows/codeql.yml
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "$COMMIT_SUBJECT" -m "$COMMIT_BODY"
    git push -q origin HEAD 2>/dev/null || exit 3
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  $repo: push refused (rules?); left alone"; FAILED=$((FAILED + 1)); rm -rf "$dir"; continue
  fi
  ADDED=$((ADDED + 1))
  if [ "$(gh api "repos/$OWNER/$repo/code-scanning/default-setup" --jq .state 2>/dev/null || true)" = "configured" ]; then
    gh api -X PATCH "repos/$OWNER/$repo/code-scanning/default-setup" -f state=not-configured --silent 2>/dev/null \
      || echo "  $repo: default setup did not switch off; the first run will be refused"
  fi
  sleep 2
  if gh api -X POST "repos/$OWNER/$repo/actions/workflows/codeql.yml/dispatches" -f ref="$branch" --silent 2>/dev/null; then
    DISPATCHED=$((DISPATCHED + 1))
  else
    echo "  $repo: dispatch refused"
  fi
  echo "  pushed to $repo: $langs"
  rm -rf "$dir"
done

echo "added: $ADDED   already had one: $SKIPPED   need a build: $NEEDS_BUILD   failed: $FAILED   runs started: $DISPATCHED"
