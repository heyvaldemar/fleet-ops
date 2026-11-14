#!/usr/bin/env bash
# test-automerge-lookup.sh - the Dependabot automerge, as
# scripts/automerge_lookup.py leaves it, merges what was verified, refuses
# what was not, and goes red when it cannot find the pull request it exists
# for.
#
# The case that made it: on 2026-11-11 siyuan-docker-compose#8 went green,
# the job asked GitHub which pull request carried the commit, got nothing back
# five minutes after the pull request opened, said "nothing to do" and went
# green itself. The update waited sixty hours.
#
# The step's own script is cut out of real workflow files (copies from the
# fleet in tests/fixtures/automerge) and run the way Actions runs it, with a
# fake gh that answers from canned JSON through the real jq expressions, and a
# sleep that only counts. Every case runs on the file before the change too:
# the two that made the change must fail there, or this test proves nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/automerge"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null || { echo "jq is needed: the step runs jq on the event, and gh's --jq is jq"; exit 1; }

SHA=1111111111111111111111111111111111111111
MOVED=2222222222222222222222222222222222222222

# THE FAKE gh. Answers from $CASE/<name>.json through the --jq expression it
# was given, exactly as gh does, and logs every call to $CASE/calls.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/calls"
if [ "$1" = api ]; then
  path="$2"; shift 2; expr="."
  while [ $# -gt 0 ]; do [ "$1" = --jq ] && expr="$2"; shift; done
  case "$path" in
    */commits/*/pulls)
      n=$(( $(cat "$CASE/lookups" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/lookups"
      f="$CASE/lookup-$n.json"; [ -f "$f" ] || f="$CASE/lookup.json"; [ -f "$f" ] || f=/dev/null
      [ -s "$f" ] || { echo "[]" | jq -r "$expr"; exit 0; }
      jq -r "$expr" < "$f" ;;
    */pulls/*)
      [ -f "$CASE/pull.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
      jq -r "$expr" < "$CASE/pull.json" ;;
    */actions/workflows/*/runs*)
      jq -r "$expr" < "$CASE/runs.json" ;;
    *) echo "fake gh: unexpected api $path" >&2; exit 1 ;;
  esac
  exit 0
fi
[ "$1 $2" = "pr merge" ] && exit 0
[ "$1 $2" = "workflow run" ] && exit 0
echo "fake gh: unexpected $*" >&2; exit 1
SH
# shellcheck disable=SC2016 # expands where the fake runs, not here
printf '#!/usr/bin/env bash\necho x >> "$CASE/sleeps"\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/gh" "$WORK/bin/sleep"

# The merge step's script, as Actions would run it.
step() {   # workflow file -> the run: block of the merge step
  python3 -I - "$1" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"- name: Merge, if this was Dependabot and the run was green\n(?:.*\n)*?(?P<i>[ ]+)run: \|\n", s)
i = len(m.group("i"))
out = []
for line in s[m.end():].split("\n"):
    if line.strip() and len(line) - len(line.lstrip(" ")) <= i:
        break
    out.append(line[i + 2:])
sys.stdout.write("\n".join(out) + "\n")
PY
}

new_of() {   # fixture -> path of the changed copy
  local out
  out="$WORK/new-$(basename "$1")"
  cp "$1" "$out"
  python3 -I "$ROOT/scripts/automerge_lookup.py" "$out" >/dev/null
  printf '%s' "$out"
}

# run_case <workflow file> <case dir> <PRS json> <actor> <branch> -> exit code in $rc
run_case() {
  step "$1" > "$2/step.sh"
  rc=0
  ( cd "$2" && CASE="$2" PATH="$WORK/bin:$PATH" GH_TOKEN=x REPO=heyvaldemar/example \
      SHA="$SHA" VERIFY=.github/workflows/deployment-verification.yml \
      PRS="$3" ACTOR="$4" HEAD_BRANCH="$5" \
      bash --noprofile --norc -eo pipefail "$2/step.sh" > "$2/out" 2>&1 ) || rc=$?
}

mkcase() {   # name -> fresh case dir
  local d="$WORK/case-$1-$RANDOM"; mkdir -p "$d"; : > "$d/calls"; printf '%s' "$d"
}
merged() { grep -q '^pr merge' "$1/calls"; }
pull_json() {   # state author head
  printf '{"number":8,"state":"%s","user":{"login":"%s"},"head":{"sha":"%s"}}\n' "$1" "$2" "$3"
}
EVENT_PR='[{"number":8,"head":{"sha":"'$SHA'"}}]'
DEPENDABOT_BRANCH=dependabot/github_actions/github-actions-7b4d336379

OLD="$FIX/siyuan-docker-compose.yml"
NEW="$(new_of "$OLD")"

echo "== the change is the one asked for, and only that"
c=$(python3 -I "$ROOT/scripts/automerge_lookup.py" "$NEW" >/dev/null; echo $?)
if [ "$c" = 1 ]; then ok "a second pass finds it already done (exit 1)"; else no "a second pass exited $c, expected 1"; fi
printf 'name: x\non: push\njobs: {}\n' > "$WORK/odd.yml"; cp "$WORK/odd.yml" "$WORK/odd-before.yml"
c=$(python3 -I "$ROOT/scripts/automerge_lookup.py" "$WORK/odd.yml" >/dev/null; echo $?)
if [ "$c" = 2 ] && cmp -s "$WORK/odd.yml" "$WORK/odd-before.yml"; then ok "a shape it does not know is left alone (exit 2)"; else no "unknown shape: exit $c, or the file was written"; fi
for f in "$FIX"/*.yml; do
  n="$(new_of "$f")"
  if [ "$(grep -A2 '^    if: >-' "$f")" = "$(grep -A2 '^    if: >-' "$n")" ]; then
    ok "$(basename "$f" .yml): the job's if: is untouched, so a repository whose gate never runs on a pull request stays inert"
  else
    no "$(basename "$f" .yml): the job's if: changed"
  fi
  # shellcheck disable=SC2016 # the workflow's own $SHA, matched as text
  if [ "$(grep -c -- '--match-head-commit "$SHA"' "$n")" = 2 ]; then ok "$(basename "$f" .yml): both merges are held to the verified commit"; else no "$(basename "$f" .yml): a merge is not held to the verified commit"; fi
done

echo "== the pull request is not found (the siyuan case)"
d=$(mkcase lost-old); run_case "$OLD" "$d" '[]' 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ]; then ok "before the change: green with nothing done, which is the bug this test is for"; else no "before the change it exited $rc; the plant does not reproduce the bug"; fi
d=$(mkcase lost-new); run_case "$NEW" "$d" '[]' 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" != 0 ] && ! merged "$d"; then ok "after: red, and nothing merged"; else no "after: exit $rc, merged: $(merged "$d" && echo yes || echo no)"; fi
if grep -q '::error::' "$d/out"; then ok "after: it says why, as an error"; else no "after: no ::error:: line"; fi
if [ "$(cat "$d/lookups" 2>/dev/null)" = 6 ]; then ok "after: the commit was asked six times"; else no "after: asked $(cat "$d/lookups" 2>/dev/null) times"; fi
if [ "$(wc -l < "$d/sleeps" 2>/dev/null | tr -d ' ')" = 5 ]; then ok "after: with a wait between tries, none after the last"; else no "after: slept $(wc -l < "$d/sleeps" 2>/dev/null) times"; fi

echo "== the head moved after the run that passed"
d=$(mkcase moved-old); pull_json open 'dependabot[bot]' "$MOVED" > "$d/pull.json"; echo '[{"number":8,"state":"open","user":{"login":"dependabot[bot]"}}]' > "$d/lookup.json"
run_case "$OLD" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if merged "$d"; then ok "before the change: it merged a head nothing had verified, the other half of the bug"; else no "before the change it did not merge; the plant does not reproduce the bug"; fi
d=$(mkcase moved-new); pull_json open 'dependabot[bot]' "$MOVED" > "$d/pull.json"
run_case "$NEW" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && ! merged "$d"; then ok "after: the merge is refused"; else no "after: exit $rc, merged: $(merged "$d" && echo yes || echo no)"; fi
if grep -q '::warning::' "$d/out"; then ok "after: and the refusal says so"; else no "after: no ::warning:: line"; fi

echo "== what still merges"
d=$(mkcase event); pull_json open 'dependabot[bot]' "$SHA" > "$d/pull.json"
run_case "$NEW" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && grep -q "^pr merge 8 .*--squash .*--match-head-commit $SHA" "$d/calls"; then ok "the pull request from the event, Dependabot's, at the verified head: merged, held to that head"; else no "event case: exit $rc; calls: $(tr '\n' '|' < "$d/calls")"; fi
if grep -q '^workflow run deployment-verification.yml --repo heyvaldemar/example --ref main' "$d/calls"; then ok "and main is verified again as merged"; else no "no dispatch on main"; fi
if grep -q 'commits/.*/pulls' "$d/calls"; then no "the commit was asked although the event named the pull request"; else ok "the commit is not asked when the event names the pull request"; fi
d=$(mkcase late); pull_json open 'dependabot[bot]' "$SHA" > "$d/pull.json"; : > "$d/lookup-1.json"; : > "$d/lookup-2.json"; echo '[{"number":8}]' > "$d/lookup.json"
run_case "$NEW" "$d" '[]' 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && merged "$d" && [ "$(cat "$d/lookups")" = 3 ]; then ok "an empty event and a commit GitHub links on the third try: merged"; else no "late case: exit $rc, lookups $(cat "$d/lookups" 2>/dev/null)"; fi

echo "== what is left alone, green"
d=$(mkcase human); pull_json open 'someone' "$SHA" > "$d/pull.json"
run_case "$NEW" "$d" "$EVENT_PR" 'someone' 'feature/x'
if [ "$rc" = 0 ] && ! merged "$d"; then ok "a person's pull request is not merged"; else no "human case: exit $rc"; fi
d=$(mkcase disguised); pull_json open 'someone' "$SHA" > "$d/pull.json"
run_case "$NEW" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && ! merged "$d"; then ok "an event that claims Dependabot does not make a person's pull request Dependabot's"; else no "disguised case: exit $rc"; fi
d=$(mkcase nopr); run_case "$NEW" "$d" '[]' 'someone' 'feature/x'
if [ "$rc" = 0 ] && ! merged "$d"; then ok "no pull request for a run nobody's bot started: nothing to do, green"; else no "nopr case: exit $rc"; fi
d=$(mkcase closed); pull_json closed 'dependabot[bot]' "$SHA" > "$d/pull.json"
run_case "$NEW" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && ! merged "$d"; then ok "a pull request already merged or closed: nothing to merge, green"; else no "closed case: exit $rc"; fi
d=$(mkcase unread); run_case "$NEW" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" != 0 ] && ! merged "$d"; then ok "a pull request that cannot be read: red, never green"; else no "unread case: exit $rc"; fi

echo "== the gates a variant adds are kept"
FLAG="$(new_of "$FIX/kubernetes-air-gapped-ai-agent.yml")"
d=$(mkcase gate-red); pull_json open 'dependabot[bot]' "$SHA" > "$d/pull.json"; echo '{"workflow_runs":[{"conclusion":"failure"}]}' > "$d/runs.json"
run_case "$FLAG" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && ! merged "$d"; then ok "a second gate that is red still stops the merge"; else no "gate-red: exit $rc"; fi
d=$(mkcase gate-green); pull_json open 'dependabot[bot]' "$SHA" > "$d/pull.json"; echo '{"workflow_runs":[{"conclusion":"success"}]}' > "$d/runs.json"
run_case "$FLAG" "$d" "$EVENT_PR" 'dependabot[bot]' "$DEPENDABOT_BRANCH"
if [ "$rc" = 0 ] && merged "$d"; then ok "and a green one lets it through"; else no "gate-green: exit $rc"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
