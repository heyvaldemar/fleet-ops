#!/usr/bin/env bash
# scripts/git-auth.sh, sourced the way every rollout sources it: the token
# reaches git only through its environment, and a commit made afterwards says
# +0000 whatever zone the machine is in. Before 17 November 2026 a rollout run
# from a laptop wrote the laptop's offset into the author and committer dates
# of every commit it pushed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok    $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — wanted [$2], got [$3]"; fi; }

commit_offsets() {   # commit_offsets <file to source or empty>: the author and committer offsets of a fresh commit
  local repo="$WORK/repo-$RANDOM"
  # A zone that is not UTC, the way a laptop is; 'Etc/GMT-9' is UTC+9.
  # shellcheck disable=SC2016  # expanded by the inner shell
  env -i PATH="$PATH" HOME="$WORK" TZ=Etc/GMT-9 GH_TOKEN=dummy-token bash -c '
    set -e
    [ -n "$1" ] && . "$1"
    git init -q -b main "$2"
    cd "$2"
    echo x > f && git add f
    git -c user.name=t -c user.email=t@example.org commit -q -m x
    git log -1 --format="%ad %cd" --date=format:%z
  ' _ "$1" "$repo"
}

echo "== a commit after sourcing git-auth.sh"
same "author and committer say +0000 in a zone that is not UTC" "+0000 +0000" "$(commit_offsets "$ROOT/scripts/git-auth.sh")"
echo "== the same commit without it (what a rollout wrote before)"
same "the zone's own offset is written" "+0900 +0900" "$(commit_offsets "")"
echo "== the token stays out of the command line"
# shellcheck disable=SC2016  # expanded by the inner shell
OUT="$(env -i PATH="$PATH" GH_TOKEN=dummy-token bash -c '. "$1"; echo "$GIT_CONFIG_KEY_0"; case "$GIT_CONFIG_VALUE_0" in "AUTHORIZATION: basic "*) echo header ;; esac' _ "$ROOT/scripts/git-auth.sh")"
same "the token goes in an extraheader for github.com" "http.https://github.com/.extraheader
header" "$OUT"

echo
echo "git-auth: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
