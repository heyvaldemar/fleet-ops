#!/usr/bin/env bash
# verify-mapping.sh: a mapping is accepted only when the repository exists
# under exactly that name and carries the version the fleet pins, as a tag.
# Exit 0 proven, 1 disproven, 2 GitHub did not answer, which is no verdict.
set -euo pipefail
repo="$1"
pin="$2"
api="https://api.github.com/repos/$repo"
auth=(-H "Authorization: Bearer ${GITHUB_TOKEN:?}")
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
body=$(mktemp)
trap 'rm -f "$body"' EXIT

code=$(curl -sSL -o "$body" -w '%{http_code}' "${auth[@]}" "$api" || true)   # a transport failure prints 000
case "$code" in
  200) ;;
  404) echo "no repository at $repo"; exit 1 ;;
  *) echo "GitHub answered $code for $repo: no verdict"; exit 2 ;;
esac
name=$(jq -r '.full_name' "$body")
if [ "$(lower "$name")" != "$(lower "$repo")" ]; then
  echo "$repo redirects to $name: map to $name only if that is the project"
  exit 1
fi

for tag in "$pin" "v$pin"; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" "$api/git/ref/tags/$tag" || true)
  case "$code" in
    200) echo "proven: $repo carries $tag"; exit 0 ;;
    404) ;;
    *) echo "GitHub answered $code for $repo tag $tag: no verdict"; exit 2 ;;
  esac
done
echo "$repo exists but has no tag for $pin: mapping unproven"
exit 1
