#!/usr/bin/env bash
# test-file-report.sh - drive scripts/file-report.sh against a fake gh.
#
# The thing worth testing here is not whether an issue appears. It is whether
# a run that has nothing new to say stays silent, because that is the whole
# reason the script exists, and it is the one behaviour that cannot be checked
# by looking at the result: silence and a broken script look identical from
# outside. So every case below asserts what was NOT called as well as what was.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

FAKE_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_DIR"' EXIT
cat > "$FAKE_DIR/gh" <<'FAKE'
#!/usr/bin/env bash
# The flag matters as much as the subcommand: `issue close --comment` posts a
# comment AND closes, which is two notifications where the point is one. A
# stand-in that records only "issue close" cannot tell those apart, and an
# assertion against it proves nothing.
call="$1 $2"
for a in "$@"; do [ "$a" = "--comment" ] && call="$call --comment"; done
printf '%s\n' "$call" >> "$FAKE_DIR/calls"
# A second line naming the issue, so an assertion can say WHICH thread was
# edited. Counting bare "issue edit" cannot tell the survivor from the
# duplicate, and once both are touched that number answers the wrong question.
case "$3" in [0-9]*) printf '%s #%s\n' "$call" "$3" >> "$FAKE_DIR/calls" ;; esac
# Keep the body the script handed over. The fingerprint it wrote is the only
# copy that is actually in use; a test that recomputes the hash for itself is
# comparing one reimplementation against another and would pass while the
# script's own version was wrong.
prev=""
for a in "$@"; do
  [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_DIR/last-body" 2>/dev/null
  prev="$a"
done
case "$1 $2" in
  "issue list") cat "$FAKE_DIR/open" 2>/dev/null ;;
  "issue view") cat "$FAKE_DIR/body.$3" 2>/dev/null ;;
esac
exit 0
FAKE
chmod +x "$FAKE_DIR/gh"
export FAKE_DIR
export FLEET_GH="$FAKE_DIR/gh"

reset() { : > "$FAKE_DIR/calls"; : > "$FAKE_DIR/open"; rm -f "$FAKE_DIR"/body.*; }
called() { grep -cx "$1" "$FAKE_DIR/calls" 2>/dev/null || true; }
expect() { # label  call  how-many
  local n; n="$(called "$2")"
  if [ "$n" = "$3" ]; then ok "$1"; else no "$1: '$2' happened $n times, expected $3"; fi
}

report="$FAKE_DIR/report.md"
finger="$FAKE_DIR/finger.txt"
printf '## A report\n- authelia: needs a human\n- dozzle: needs a human\n' > "$report"
printf 'authelia: needs a human\ndozzle: needs a human\n' > "$finger"
# The set the script stores. Computed here rather than imported, because a
# test that asks the code under test what the right answer is has not tested
# anything.
set_of() {
  sort -u "$1" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | shasum -a 256 | cut -c1-8
  done | sort -u | tr '\n' ' ' | sed 's/ $//'
}
FP="$(set_of "$finger")"

# What the SCRIPT makes of a fingerprint file, read back out of the body it
# wrote. Used wherever the answer has to be the script's and not this file's.
fp_of() {
  rm -f "$FAKE_DIR/open" "$FAKE_DIR/last-body"
  "$ROOT/scripts/file-report.sh" --repo o/r --label probe --title t \
      --body "$report" --fingerprint "$1" >/dev/null 2>&1
  sed -n 's/.*fleet-report-fingerprint: \(.*\) -->.*/\1/p' "$FAKE_DIR/last-body"
}

run() { "$ROOT/scripts/file-report.sh" --repo o/r --label triage-report \
          --title "Fleet triage: 2 item(s)" --body "$report" --fingerprint "$finger" "$@"; }

echo "== nothing to report, nothing open: touch nothing"
reset
out="$(run --nothing-to-report)"
expect "no issue is closed" "issue close" 0
expect "no issue is created" "issue create" 0
case "$out" in *"no open"*) ok "it says there was nothing open" ;; *) no "it said: $out" ;; esac

echo "== nothing to report, one open: close it, once"
reset
printf '41\n' > "$FAKE_DIR/open"
printf '## the last report\n' > "$FAKE_DIR/body.41"
run --nothing-to-report >/dev/null
expect "the open thread is closed" "issue close" 1
expect "nothing new is opened" "issue create" 0
# Closing with --comment posts a comment and closes, and each is its own
# notification: two mails to say one thing. The reason goes in the body, which
# notifies nobody, and the close event goes out alone.
expect "no comment is posted to explain the close" "issue comment" 0
expect "and the close itself carries none either" "issue close --comment" 0
expect "the reason is written into the body instead" "issue edit" 1

echo "== something to report, nothing open: open one thread, say nothing twice"
reset
run >/dev/null
expect "one thread is opened" "issue create" 1
expect "no comment is posted on a brand new thread" "issue comment" 0
expect "nothing is closed" "issue close" 0

echo "== the same findings again: update in place and stay silent"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## A report\n- old body\n\n<!-- fleet-report-fingerprint: %s -->\n' "$FP" > "$FAKE_DIR/body.42"
out="$(run)"
# Not even an edit. A body edit sends no mail but GitHub still records it
# against the thread, which bumps a subscriber's web inbox for a run that had
# nothing to say. Three times a day, that is the floor this is lowering.
expect "the body is NOT rewritten for nothing" "issue edit" 0
expect "NOBODY is mailed" "issue comment" 0
expect "no second thread is opened" "issue create" 0
expect "the thread is not closed and reopened" "issue close" 0
case "$out" in *"left untouched"*) ok "it reports that it touched nothing" ;; *) no "it said: $out" ;; esac

echo "== the findings changed: update and comment exactly once"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## A report\n\n<!-- fleet-report-fingerprint: 0000000000000000 -->\n' > "$FAKE_DIR/body.42"
run >/dev/null
expect "the body is refreshed" "issue edit" 1
expect "one comment, not two" "issue comment" 1
expect "no second thread is opened" "issue create" 0

echo "== a thread from the old workflow, with no fingerprint in it"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## A report from before this script existed\n' > "$FAKE_DIR/body.42"
run >/dev/null
expect "it adopts the thread rather than opening another" "issue create" 0
expect "and comments once, because it cannot know it is unchanged" "issue comment" 1

echo "== two threads open: keep the newest, close the rest"
reset
printf '44\n43\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$FP" > "$FAKE_DIR/body.44"
run >/dev/null
expect "the older duplicate is closed" "issue close" 1
expect "and its close carries no comment either" "issue close --comment" 0
# Closing the duplicate happens whatever the findings say; the survivor is
# then left alone, because it already says the right thing.
expect "the survivor is not rewritten for nothing" "issue edit #44" 0
expect "only the duplicate's body was touched" "issue edit #43" 1
expect "and nobody is mailed, because it says the same thing" "issue comment" 0

echo "== the order of the findings is not a change"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$FP" > "$FAKE_DIR/body.42"
printf 'dozzle: needs a human\nauthelia: needs a human\n' > "$finger"
run >/dev/null
expect "reordered findings do not mail anyone" "issue comment" 0
printf 'authelia: needs a human\ndozzle: needs a human\n' > "$finger"

echo "== one more finding IS a change"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$FP" > "$FAKE_DIR/body.42"
printf 'authelia: needs a human\ndozzle: needs a human\nimmich: needs a human\n' > "$finger"
run >/dev/null
expect "a new finding mails once" "issue comment" 1

echo "== a list that only got shorter is progress, not an interruption"
# 12 items became 9 became 3 inside twenty minutes on 2026-09-17, and each step
# sent mail. Two of those three said only that the fleet had fixed things
# without help. The body still tracks it; nobody is told.
reset
printf '42\n' > "$FAKE_DIR/open"
printf 'authelia: needs a human\ndozzle: needs a human\nimmich: needs a human\n' > "$finger"
BIG="$(set_of "$finger")"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$BIG" > "$FAKE_DIR/body.42"
printf 'authelia: needs a human\n' > "$finger"
out="$(run)"
expect "the body is still brought up to date" "issue edit" 1
expect "and NOBODY is mailed about two problems going away" "issue comment" 0
case "$out" in *"only lost findings"*) ok "it says why it stayed quiet" ;; *) no "it said: $out" ;; esac

echo "== a list that lost one and gained one still mails"
reset
printf '42\n' > "$FAKE_DIR/open"
printf 'authelia: needs a human\ndozzle: needs a human\n' > "$finger"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$(set_of "$finger")" > "$FAKE_DIR/body.42"
printf 'authelia: needs a human\nimmich: needs a human\n' > "$finger"
run >/dev/null
expect "a swap is a new finding and mails once" "issue comment" 1

printf 'authelia: needs a human\ndozzle: needs a human\n' > "$finger"

echo "== an empty fingerprint falls back to the body rather than going silent"
reset
printf '42\n' > "$FAKE_DIR/open"
: > "$FAKE_DIR/empty.txt"
BODY_FP="$(set_of "$report")"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$BODY_FP" > "$FAKE_DIR/body.42"
out="$("$ROOT/scripts/file-report.sh" --repo o/r --label triage-report --title t \
        --body "$report" --fingerprint "$FAKE_DIR/empty.txt" 2>&1)"
case "$out" in *"came out empty"*) ok "it says the fingerprint was empty" ;; *) no "it said: $out" ;; esac
# The set derived from the body matches what is stored, so there is nothing to
# write. What matters is that it now tracks the body instead of tracking the
# empty string, which never moves and would have silenced this thread forever.
expect "nothing is rewritten, because nothing differs" "issue edit" 0
expect "and nobody is mailed" "issue comment" 0

echo "== a missing fingerprint file is refused, not guessed at"
reset
if "$ROOT/scripts/file-report.sh" --repo o/r --label l --title t \
     --body "$report" --fingerprint "$FAKE_DIR/does-not-exist" >/dev/null 2>&1; then
  no "it ran without a fingerprint"
else
  ok "it refuses to run without a fingerprint"
fi
expect "and it opened nothing while refusing" "issue create" 0

echo "== an age that grew by itself is not a new finding"
# Most findings this fleet produces carry an elapsed time, and it moves on its
# own between runs. Hashed verbatim, "last fired 51 hours ago" and the same
# line a day later are two different findings, so an unfixed problem would
# comment and mail twice a day forever — worst on the day a schedule actually
# stopped, which is the one finding that must not be buried.
young="$FAKE_DIR/young.txt"; older="$FAKE_DIR/older.txt"
printf -- '- o/r: catalog.yml last fired 51 hours ago; its cron is every 24 hours\n' > "$young"
printf -- '- o/r: catalog.yml last fired 75 hours ago; its cron is every 24 hours\n' > "$older"
if [ "$(fp_of "$young")" = "$(fp_of "$older")" ]; then
  ok "the same finding a day later fingerprints the same"
else
  no "51 hours and 75 hours were read as two different findings"
fi

# End to end: a thread carrying yesterday's fingerprint, run against today's
# wording of the same problem. Silence is the whole point of the script.
# fp_of runs the script, and the script's first act is to read the open-issue
# list this fake keeps. Computing the fingerprint after seeding that list wipes
# it, and the run under test then opens a fresh thread instead of commenting on
# one — which looks exactly like the silence being asserted. Compute first.
YOUNG_FP="$(fp_of "$young")"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$YOUNG_FP" > "$FAKE_DIR/body.42"
"$ROOT/scripts/file-report.sh" --repo o/r --label triage-report --title t \
    --body "$report" --fingerprint "$older" >/dev/null
expect "the thread under test is the one that was there" "issue create" 0
expect "and nobody is mailed about it a day later" "issue comment" 0

# THE CHECK HAS TO BE ABLE TO FAIL. Blanking ages must not blank the things
# that genuinely tell two findings apart, or a second stuck pull request and a
# different upstream version would both arrive as old news.
pr59="$FAKE_DIR/pr59.txt"; pr60="$FAKE_DIR/pr60.txt"
printf -- '- o/r#59 has been open 40 hours: ci: bump an action\n' > "$pr59"
printf -- '- o/r#60 has been open 40 hours: ci: bump an action\n' > "$pr60"
if [ "$(fp_of "$pr59")" = "$(fp_of "$pr60")" ]; then
  no "two different pull requests were collapsed into one finding"
else
  ok "a different pull request number is still a different finding"
fi
v3="$FAKE_DIR/v3.txt"; v4="$FAKE_DIR/v4.txt"
printf -- '- gitlab 19.3.2 is behind, and has been for 40 hours\n' > "$v3"
printf -- '- gitlab 19.4.0 is behind, and has been for 40 hours\n' > "$v4"
if [ "$(fp_of "$v3")" = "$(fp_of "$v4")" ]; then
  no "two different upstream versions were collapsed into one finding"
else
  ok "a different version is still a different finding"
fi

# And a real new finding beside a drifting one still gets through.
reset
both="$FAKE_DIR/both.txt"
cat "$older" > "$both"
printf -- '- o/r: secret-scan.yml is disabled_inactivity\n' >> "$both"
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$YOUNG_FP" > "$FAKE_DIR/body.42"
"$ROOT/scripts/file-report.sh" --repo o/r --label triage-report --title t \
    --body "$report" --fingerprint "$both" --changed-comment "changed" >/dev/null
expect "a genuinely new finding beside a drifting one still mails" "issue comment" 1

echo "== one waiting branch is one decision, however the run words it"
# fleet-triage.sh words a prepared branch two ways: one sentence in the run
# that pushes it, another in a run that only finds it there. Hashed verbatim
# they are two findings, and the thread flips between them for as long as the
# branch waits. On 2026-11-10 that mailed "what needs a decision has changed"
# twice, at 02:29 and 15:27 UTC, about a list holding the same three items.
# Both lines are the thread's own (fleet-ops#50), not a paraphrase.
pushed="$FAKE_DIR/pushed.txt"; found="$FAKE_DIR/found.txt"
cat > "$pushed" <<'LINE'
- ollama-traefik-letsencrypt-docker-compose: 0.12.5 -> 0.13.3 prepared on branch `bump/0.13.3` (ghcr.io/open-webui/open-webui:0.12.5 -> ghcr.io/open-webui/open-webui:0.13.3) — open it: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/main...bump/0.13.3?expand=1 — needs a human
LINE
cat > "$found" <<'LINE'
- ollama-traefik-letsencrypt-docker-compose: `bump/0.13.3` is still ahead of main with no pull request open — open it or delete it: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/main...bump/0.13.3?expand=1 — needs a human
LINE
if [ "$(fp_of "$pushed")" = "$(fp_of "$found")" ]; then
  ok "the run that pushed a branch and the run that found it name one finding"
else
  no "one waiting branch was read as two findings"
fi
# Read as the second sentence, not as a third key: the hash has to be the one
# a thread already stores from any run that only found the branch, or the
# change that ends the false alarm sends one of its own. set_of hashes the
# line as written, with no help from the script.
if [ "$(fp_of "$pushed")" = "$(set_of "$found")" ]; then
  ok "and it is the hash an open thread already stores for that branch"
else
  no "the pushed wording hashes to a key no open thread has seen"
fi
# The sentence for a major version has the same shape and the same decision.
major="$FAKE_DIR/major.txt"; major_found="$FAKE_DIR/major-found.txt"
cat > "$major" <<'LINE'
- gitlab-traefik-letsencrypt-docker-compose: MAJOR gitlab/gitlab-ee 19.4.0 -> 20.0.0 prepared on branch `bump/20.0.0` — open it: https://github.com/heyvaldemar/gitlab-traefik-letsencrypt-docker-compose/compare/main...bump/20.0.0?expand=1 — needs a human
LINE
cat > "$major_found" <<'LINE'
- gitlab-traefik-letsencrypt-docker-compose: `bump/20.0.0` is still ahead of main with no pull request open — open it or delete it: https://github.com/heyvaldemar/gitlab-traefik-letsencrypt-docker-compose/compare/main...bump/20.0.0?expand=1 — needs a human
LINE
if [ "$(fp_of "$major")" = "$(set_of "$major_found")" ]; then
  ok "a major version waiting on its branch is the same one finding"
else
  no "the major-version wording was read as a finding of its own"
fi

# End to end, both ways round: a thread that stores one wording, a run that
# writes the other. The stored hash is computed here, the way the script
# before this change stored it.
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$(set_of "$found")" > "$FAKE_DIR/body.42"
"$ROOT/scripts/file-report.sh" --repo o/r --label triage-report --title t \
    --body "$report" --fingerprint "$pushed" --changed-comment "changed" >/dev/null
expect "the thread under test is the one that was there" "issue create" 0
expect "a run that pushes the branch again mails nobody" "issue comment" 0
BRANCH_FP="$(fp_of "$pushed")"
reset
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$BRANCH_FP" > "$FAKE_DIR/body.42"
"$ROOT/scripts/file-report.sh" --repo o/r --label triage-report --title t \
    --body "$report" --fingerprint "$found" --changed-comment "changed" >/dev/null
expect "and the next run, which only finds it, mails nobody either" "issue comment" 0

# THE CHECK HAS TO BE ABLE TO FAIL. Reading two sentences as one must not read
# two branches as one, or a second version waiting for a person would arrive
# as old news.
newer="$FAKE_DIR/newer.txt"; elsewhere="$FAKE_DIR/elsewhere.txt"; stuck="$FAKE_DIR/stuck.txt"
cat > "$newer" <<'LINE'
- ollama-traefik-letsencrypt-docker-compose: 0.12.5 -> 0.13.4 prepared on branch `bump/0.13.4` (ghcr.io/open-webui/open-webui:0.12.5 -> ghcr.io/open-webui/open-webui:0.13.4) — open it: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/main...bump/0.13.4?expand=1 — needs a human
LINE
cat > "$elsewhere" <<'LINE'
- open-webui-traefik-letsencrypt-docker-compose: 0.12.5 -> 0.13.3 prepared on branch `bump/0.13.3` (ghcr.io/open-webui/open-webui:0.12.5 -> ghcr.io/open-webui/open-webui:0.13.3) — open it: https://github.com/heyvaldemar/open-webui-traefik-letsencrypt-docker-compose/compare/main...bump/0.13.3?expand=1 — needs a human
LINE
cat > "$stuck" <<'LINE'
- ollama-traefik-letsencrypt-docker-compose: `bump/0.13.3` prepares 0.13.3 against a main already on 0.13.4 and could not be deleted — needs a human
LINE
if [ "$(fp_of "$newer")" = "$(fp_of "$pushed")" ]; then
  no "two branches of one repository were collapsed into one finding"
else
  ok "a newer branch in the same repository is still a different finding"
fi
if [ "$(fp_of "$elsewhere")" = "$(fp_of "$pushed")" ]; then
  no "the same branch name in two repositories was collapsed into one finding"
else
  ok "the same branch name in another repository is still a different finding"
fi
if [ "$(fp_of "$stuck")" = "$(fp_of "$found")" ]; then
  no "a branch that could not be deleted was read as a branch that waits"
else
  ok "a branch that could not be deleted is a different decision, and stays one"
fi
reset
two="$FAKE_DIR/two.txt"
cat "$found" "$newer" > "$two"
printf '42\n' > "$FAKE_DIR/open"
printf '## x\n\n<!-- fleet-report-fingerprint: %s -->\n' "$BRANCH_FP" > "$FAKE_DIR/body.42"
"$ROOT/scripts/file-report.sh" --repo o/r --label triage-report --title t \
    --body "$report" --fingerprint "$two" --changed-comment "changed" >/dev/null
expect "a second branch beside the waiting one still mails, once" "issue comment" 1

# The rewrite reproduces a sentence fleet-triage.sh prints. Reword either
# sentence there and not here, and the two part again with nothing else in
# this file to notice. Single quotes on purpose: these are the script's own
# source lines, variables and all.
triage="$ROOT/scripts/fleet-triage.sh"
# shellcheck disable=SC2016
n_pushed="$(grep -cF -- 'prepared on branch \`$br\`' "$triage" || true)"
# shellcheck disable=SC2016
n_tail="$(grep -cF -- '— open it: https://github.com/$OWNER/$repo/compare/main...$br?expand=1 — needs a human"' "$triage" || true)"
# shellcheck disable=SC2016
n_found="$(grep -cF -- '\`$br\` is still ahead of main with no pull request open — open it or delete it: https://github.com/$OWNER/$repo/compare/main...$br?expand=1 — needs a human"' "$triage" || true)"
if [ "$n_pushed" = 2 ] && [ "$n_tail" = 2 ]; then
  ok "fleet-triage.sh still writes the pushed wording the rewrite reads, in both places"
else
  no "fleet-triage.sh words a pushed branch $n_pushed time(s), $n_tail with the link the rewrite reads; file-report.sh expects 2 and 2"
fi
if [ "$n_found" = 1 ]; then
  ok "and still writes the found wording the rewrite produces"
else
  no "fleet-triage.sh no longer writes the found sentence file-report.sh reproduces ($n_found match(es))"
fi

echo "== a handle quoted in a report notifies nobody"
# A quoted changelog thanked a maintainer by handle, and every rewrite of
# heyvaldemar/fleet-ops#50 notified them. What goes to GitHub must carry the
# handle as code, on a new thread and on a rewrite alike; the fingerprint is
# taken before that, so it does not move because of it.
reset
saved="$(cat "$report")"
# shellcheck disable=SC2016
printf '## A report\n- authelia: needs a human\n- dozzle: needs a human\n> "Thanks to @some-maintainer for the fixes", and `@dependabot rebase` as code\n' > "$report"
run >/dev/null
# shellcheck disable=SC2016
if grep -q 'Thanks to `@some-maintainer` for' "$FAKE_DIR/last-body" && ! grep -q 'to @some-maintainer' "$FAKE_DIR/last-body"; then
  ok "a new thread carries the handle as code"
else
  no "a new thread carried a live handle: $(grep -o '.\{0,12\}@some-maintainer.\{0,4\}' "$FAKE_DIR/last-body")"
fi
# shellcheck disable=SC2016
if grep -q '`@dependabot rebase`' "$FAKE_DIR/last-body" && ! grep -q '``@dependabot' "$FAKE_DIR/last-body"; then
  ok "text already in code is left as it was"
else
  no "code was quoted twice"
fi
printf '41\n' > "$FAKE_DIR/open"
printf '## old\n<!-- fleet-report-fingerprint: 00000000 -->\n' > "$FAKE_DIR/body.41"
: > "$FAKE_DIR/last-body"
run >/dev/null
# shellcheck disable=SC2016
if grep -q 'Thanks to `@some-maintainer` for' "$FAKE_DIR/last-body"; then
  ok "a rewrite carries it as code too"
else
  no "a rewrite carried a live handle"
fi
printf '%s\n' "$saved" > "$report"

echo "== a create that fails is not a thread that opened"
# On 2026-09-22 this printed "opened a new fleet-to-hosts thread" twice against
# repositories the credential could not write to. Both reports were lost and
# the run went green. A filer that cannot tell whether it filed is the shape
# every check here is written to refuse.
reset
cat > "$FAKE_DIR/gh" <<'FAKE'
#!/usr/bin/env bash
call="$1 $2"
printf '%s\n' "$call" >> "$FAKE_DIR/calls"
case "$1 $2" in
  "issue list") : ;;
  "issue create") echo "HTTP 403: Resource not accessible by personal access token" >&2; exit 1 ;;
esac
exit 0
FAKE
chmod +x "$FAKE_DIR/gh"
if out="$(run 2>&1)"; then
  no "a refused create was reported as success"
else
  ok "a create the server refused fails the run"
fi
case "$out" in *"reached nobody"*) ok "and it says the report reached nobody" ;;
  *) no "it failed without saying the report was lost" ;; esac
case "$out" in *"## A report"*) ok "and prints the report that could not be filed" ;;
  *) no "the lost report was not printed anywhere" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
