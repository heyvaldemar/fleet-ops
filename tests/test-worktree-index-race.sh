#!/usr/bin/env bash
# test-worktree-index-race.sh - the race counter, shown what it counts.
#
# The worktree mode is expected to report zero foreign commits and zero lock
# failures, and a counter that can only say zero would report exactly that.
# So each counter is first shown the thing it counts, planted: a commit by
# writer a that carries writer b's file, and an index.lock left behind by a
# process that is gone. Then one short run of both modes must account for
# every file its writers made.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/worktree-index-race.py"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', expected '$3')"; fi; }
field() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if k.isdigit() else d[k]
print(d)' "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git -c user.name=t -c user.email=t@example.invalid "$@"; }

# A foreign file in a commit is counted, and a clean commit is not.
r="$WORK/plant"
g init -q -b main "$r"
echo root > "$r/README"
g -C "$r" add README && g -C "$r" commit -q -m root
mkdir -p "$r/a" "$r/b"
echo 1 > "$r/a/a-000.txt"
g -C "$r" add a/a-000.txt && g -C "$r" commit -q -m "a 000"
g -C "$r" branch clean
echo 2 > "$r/a/a-001.txt"
echo 3 > "$r/b/b-000.txt"
g -C "$r" add a/a-001.txt b/b-000.txt && g -C "$r" commit -q -m "a 001"
python3 "$S" analyze --repo "$r" --ref main > "$WORK/planted.json"
check "a's commit carrying b's file is counted" "$(field "$WORK/planted.json" commits_with_foreign_files)" 1
check "the foreign file is named" "$(field "$WORK/planted.json" hits.0.foreign.0)" b/b-000.txt
python3 "$S" analyze --repo "$r" --ref clean > "$WORK/clean.json"
check "a clean history counts no foreign commit" "$(field "$WORK/clean.json" commits_with_foreign_files)" 0

# A stale index.lock is counted on every attempt, and the writer gives up.
touch "$r/.git/index.lock"
python3 "$S" writer --name a --dir "$r" --root "$WORK" --log "$WORK/stale.json" \
  --start-at 0 --commits 1 --think-ms 0 --gap-ms 0 --seed 1
check "a stale lock fails the add and is not retried for ever" "$(field "$WORK/stale.json" commits.0.outcome)" add_failed_index_lock
check "every attempt against the lock is counted" "$(python3 -c 'import json,sys; print(sum(1 for e in json.load(open(sys.argv[1]))["events"] if e["kind"] == "index_lock"))' "$WORK/stale.json")" 11
case "$(field "$WORK/stale.json" samples.add\ index_lock)" in
  *"<tmp>/plant/.git/index.lock': File exists."*) ok "git's own line is kept, with the path replaced" ;;
  *) no "git's own line is kept, with the path replaced" ;;
esac
rm -f "$r/.git/index.lock"

# A short run of both modes accounts for every file it made.
python3 "$S" run --out "$WORK/run" --repeats 1 --commits 6 --think-ms 0 > /dev/null || no "a short run exits 0"
res="$WORK/run/result.json"
if [ -s "$res" ]; then
  check "the first mode is the shared tree" "$(field "$res" modes.0.mode)" shared
  check "the second mode is a worktree each" "$(field "$res" modes.1.mode)" worktree
  check "a worktree each: no commit carries the other's file" "$(field "$res" modes.1.commits_with_foreign_files)" 0
  check "a worktree each: every attempt made its own commit" "$(field "$res" modes.1.commits_made)" 12
  check "a worktree each: the merge has no conflict" "$(field "$res" modes.1.merge.conflicts)" 0
  for m in 0 1; do
    check "mode $m: no file is left uncommitted" "$(field "$res" modes.$m.files_never_committed)" 0
  done
  # Every attempt ends in exactly one outcome, and every file the writers
  # made is either in some commit or reported as never committed. Under
  # contention a writer can also run out of retries on the lock; its file
  # stays staged and goes out in the other writer's commit, so "own commits
  # plus files taken" alone does not add up (the first CI run of this test
  # found that, 11 of 12).
  for m in 0 1; do
    outcomes="$(python3 -c 'import json,sys; print(sum(json.load(open(sys.argv[1]))["modes"][int(sys.argv[2])]["outcomes"].values()))' "$res" "$m")"
    check "mode $m: every attempt has one outcome" "$outcomes" 12
    files="$(field "$res" modes.$m.files_committed)"
    never="$(field "$res" modes.$m.files_never_committed)"
    check "mode $m: every file is in a commit or reported uncommitted" "$((files + never))" 12
  done
  check "a worktree each: every attempt landed in its own commit" "$(field "$res" modes.1.outcomes.landed)" 12
  check "the git version is recorded" "$(field "$res" environment.git | cut -c1-12)" "git version "
else
  no "a short run writes result.json"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
