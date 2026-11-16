#!/usr/bin/env bash
# test-gk-hook-store.sh - the gk hook store checks, shown what they look for.
#
# scripts/gk-hook-store.py reports what gk wrote, kept and sent, and a check
# that can only say "nothing" would report exactly that. So each one is shown
# the thing it counts before it is believed: a mark in a file and in a deleted
# SQLite row (gone after VACUUM), a 0644 file among 0600 ones, and connect()
# lines in an strace log. No gk binary is needed here; the workflow runs gk.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/gk-hook-store.py"
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if python3 "$S" self-test --dir "$WORK/self" > "$WORK/self.json"; then ok "the built-in plants are all seen"; else no "the built-in plants: $(cat "$WORK/self.json")"; fi

mkdir -p "$WORK/box/GitKrakenCLI/sessions"
printf 'x MARK-A y' > "$WORK/box/GitKrakenCLI/sessions/one.json"; chmod 600 "$WORK/box/GitKrakenCLI/sessions/one.json"
chmod 700 "$WORK/box/GitKrakenCLI" "$WORK/box/GitKrakenCLI/sessions"
out="$(python3 "$S" scan "$WORK/box" MARK-A MARK-B)"
case "$out" in *'"MARK-A": ["GitKrakenCLI/sessions/one.json"]'*'"MARK-B": []'*) ok "scan names the file that holds a mark, and only that one" ;; *) no "scan: $out" ;; esac
if [ "$(python3 "$S" perms "$WORK/box" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["open_to_others"]))')" = 0 ]; then
  ok "0600 files in 0700 folders are not flagged"
else
  no "perms flagged a closed tree"
fi
printf '{}' > "$WORK/box/GitKrakenCLI/sessions/two.json"; chmod 644 "$WORK/box/GitKrakenCLI/sessions/two.json"
case "$(python3 "$S" perms "$WORK/box")" in *two.json*) ok "a 0644 file is flagged" ;; *) no "perms missed a 0644 file" ;; esac

cat > "$WORK/log" <<'LOG'
101 connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("198.51.100.7")}, 16) = -1 EINPROGRESS
101 connect(4, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0
101 connect(5, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = -1 ENOENT
LOG
c="$(python3 "$S" connects "$WORK/log")"
case "$c" in *'"attempts": 2'*'"dns": 1'*'"outside": ["198.51.100.7:443"]'*) ok "connect() to an address is counted, DNS apart, a local socket not" ;; *) no "connects: $c" ;; esac
: > "$WORK/empty"
case "$(python3 "$S" connects "$WORK/empty")" in *'"attempts": 0'*) ok "an empty log counts nothing" ;; *) no "an empty log counted something" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
