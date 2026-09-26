#!/bin/bash
# One-shot rollout: the Release Assets workflow into every public repository
# that has published a release, a "Verify what you deploy" section in the
# README where the README has a supply-chain section, and, with
# BACKFILL=true, a run of the workflow for each of the last five releases so
# they carry the same archive, signature and provenance as the next one will.
#
# WHAT IT FIXES. OpenSSF Scorecard's Signed-Releases check was "not
# applicable" across the whole fleet on 2026-09-24: 833 tags, and not one
# release carried an artifact anyone could verify. A person deploying a tag
# trusted that the tag had not moved. From this rollout on, a release carries
# a git archive of the tag, a keyless Sigstore signature over it, and SLSA v1
# provenance from the SLSA generator, and the README says how to check all
# three with nothing from this repository trusted.
#
# Idempotent: a repository carrying the current workflow is not rewritten; a README
# already carrying the section is left alone; BACKFILL skips a release that
# already has an .intoto.jsonl asset.
set -euo pipefail

OWNER="${FLEET_OWNER:-heyvaldemar}"
DRY_RUN="${DRY_RUN:-false}"
BACKFILL="${BACKFILL:-false}"
ONLY="${ONLY:-}"
GIT_AUTHOR="${FLEET_GIT_AUTHOR:-Vladimir Mikhalev}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-10498744+heyvaldemar@users.noreply.github.com}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/../templates/release-assets.yml"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
[ -f "$TEMPLATE" ] || { echo "::error::missing $TEMPLATE"; exit 1; }

REPOS=()
while IFS= read -r _r; do REPOS+=("$_r"); done < <(gh api "users/$OWNER/repos?per_page=100&type=owner" --paginate \
  --jq '.[] | select(.archived|not) | select(.fork|not) | select(.private|not) | .name' | sort)
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "::error::repository listing came back empty — token or API problem, refusing to report a false green"
  exit 1
fi

section() {
  local repo="$1"
  cat <<MD

### Verify what you deploy

Every release from v$2 on carries three files made on GitHub's runner with a short-lived identity and no stored key: \`$repo-<tag>.tar.gz\`, a \`git archive\` of exactly the tree the tag points at; \`$repo-<tag>.tar.gz.sigstore.json\`, a keyless [Sigstore](https://www.sigstore.dev/) signature over it; and \`$repo-<tag>.intoto.jsonl\`, [SLSA](https://slsa.dev/) build provenance from the SLSA generator. To check them with nothing from this repository trusted:

\`\`\`bash
cosign verify-blob $repo-<tag>.tar.gz \\
  --bundle $repo-<tag>.tar.gz.sigstore.json \\
  --certificate-identity-regexp '^https://github.com/$OWNER/$repo/' \\
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

slsa-verifier verify-artifact $repo-<tag>.tar.gz \\
  --provenance-path $repo-<tag>.intoto.jsonl \\
  --source-uri github.com/$OWNER/$repo
\`\`\`

Add \`--source-tag <tag>\` for a release published after 24 September 2026, which is signed by the run that published it. The five releases before that date were signed by a run started by hand on \`main\`, so their provenance names the branch, not the tag; the archive is still the tag's tree, and the signature still belongs to this repository's workflow. The workflow that makes them is [\`release-assets.yml\`](.github/workflows/release-assets.yml).
MD
}

ADDED=0; README=0; SKIPPED=0; NORELEASE=0; DISPATCHED=0; PRS=0
for repo in "${REPOS[@]}"; do
  [ -n "$ONLY" ] && [ "$repo" != "$ONLY" ] && continue
  latest="$(gh api "repos/$OWNER/$repo/releases/latest" --jq .tag_name 2>/dev/null || true)"
  if [ -z "$latest" ]; then NORELEASE=$((NORELEASE + 1)); continue; fi
  dir="$WORKDIR/$repo"
  git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$repo" "$dir" 2>/dev/null || { echo "  $repo: could not clone"; continue; }
  changed=false
  if ! cmp -s "$TEMPLATE" "$dir/.github/workflows/release-assets.yml" 2>/dev/null; then
    # Missing, or an older copy: the template is the one source of the file.
    mkdir -p "$dir/.github/workflows"
    cp "$TEMPLATE" "$dir/.github/workflows/release-assets.yml"
    changed=true; ADDED=$((ADDED + 1))
  fi
  if grep -q "^## Supply chain trust" "$dir/README.md" 2>/dev/null; then
    section "$repo" "${latest#v}" > "$WORKDIR/section.md"
    if python3 - "$dir/README.md" "$WORKDIR/section.md" <<'PY'
import io, re, sys
p, sec = sys.argv[1], io.open(sys.argv[2], encoding="utf-8").read()
s = io.open(p, encoding="utf-8").read()
# The section sits at the end of "## Supply chain trust", before the next
# "## " heading (or the "---" rule that precedes it). An existing copy whose
# text differs is replaced; one that matches leaves the file alone (exit 1).
start = s.index("\n## Supply chain trust")
m = re.search(r"\n(?:---\n\n)?## ", s[start + 1:])
end = start + 1 + m.start() if m else len(s)
head, tail = s[:end], s[end:]
i = head.find("\n### Verify what you deploy")
if i >= 0:
    head = head[:i]
body = head.rstrip("\n") + "\n" + sec + tail
if body == s:
    sys.exit(1)
io.open(p, "w", encoding="utf-8").write(body)
PY
    then changed=true; README=$((README + 1)); fi
  fi
  if [ "$changed" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      echo "  would push to $repo (latest $latest)"
    else
      rc=0
      (
        cd "$dir"
        git add -A
        git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -m "ci: every release carries an archive, a keyless signature and SLSA provenance" \
          -m "A tag is a name and a name can be moved. From here on a release carries a git archive of the tag, a Sigstore signature over it and SLSA build provenance, all made on the runner with no stored key, and the README says how to verify them with nothing from this repository trusted. Existing releases are given the same three files by running the workflow against their tags."
        # A repository whose rules require a pull request (aws-kubectl-docker)
        # gets one, on a branch, and the loop goes on.
        if ! git push -q origin HEAD 2>/dev/null; then
          git push -q origin HEAD:refs/heads/release-assets -f
          gh pr create -R "$OWNER/$repo" --head release-assets --fill >/dev/null 2>&1 || true
          echo "  $repo: main refuses direct pushes; pull request opened"
          exit 3
        fi
      ) || rc=$?
      # set -e would end the script on the subshell's exit code; it is caught above.
      case $rc in
        0) echo "  pushed to $repo" ;;
        3) PRS=$((PRS + 1)); rm -rf "$dir"; continue ;;
        *) echo "  $repo: push failed"; rm -rf "$dir"; continue ;;
      esac
    fi
  else
    SKIPPED=$((SKIPPED + 1))
  fi
  if [ "$BACKFILL" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    # The workflow must exist on the default branch before it can be started.
    sleep 2
    while IFS=$'\t' read -r tag has; do
      [ "$has" = "true" ] && continue
      if gh workflow run release-assets.yml -R "$OWNER/$repo" -f "tag=$tag" >/dev/null 2>&1; then
        DISPATCHED=$((DISPATCHED + 1))
      else
        echo "  $repo $tag: dispatch refused"
      fi
      sleep 1
    done < <(gh api "repos/$OWNER/$repo/releases?per_page=5" --jq '.[] | select(.draft|not) | [.tag_name, ([.assets[].name] | map(endswith(".intoto.jsonl")) | any)] | @tsv')
  fi
  rm -rf "$dir"
done

echo "workflow added: $ADDED   readme sections: $README   already done: $SKIPPED   no release: $NORELEASE   pull requests instead: $PRS   backfill runs started: $DISPATCHED"
