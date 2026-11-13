#!/usr/bin/env bash
# file-report.sh - keep exactly one open issue per report label, and send mail
# only when what it says has changed.
#
# WHAT THIS REPLACED. Every reporting job here closed its previous issue and
# opened a new one on every run: "Superseded by today's report" on the old
# thread, a fresh thread beside it. Two notifications per run. Fleet Triage
# runs three times a day, so six mails a day arrived to say the same seven
# things, and the one run where the seven things changed looked exactly like
# the five before it. A notification that arrives whether or not anything
# happened carries no information, and it trains the person receiving it to
# archive the whole label unread. That is the failure: not the mail, the
# reader who stops looking.
#
# WHAT IT DOES INSTEAD. One thread per label, alive for as long as the problem
# is. The body is rewritten every run so ages and counts in it stay true, and
# editing a body notifies nobody. A comment is posted only when the caller's
# fingerprint changes, which is the only moment there is something new to read.
# When a run finds nothing left to decide the thread closes, and the next
# finding opens a fresh one.
#
# The caller says what "changed" means by handing over a fingerprint file. It
# is deliberately not guessed here: a report is full of clock times, ages and
# run ids that move every run while nothing has happened, and a wrong guess is
# either mail nobody reads or silence about something real. Silence is the
# dangerous one, so the argument is required.
set -uo pipefail

# The seam the tests drive. Nothing else in this file knows about GitHub.
GH="${FLEET_GH:-gh}"
MARKER="fleet-report-fingerprint"

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
label="" title="" body="" fingerprint="" nothing=0 colour="1d76db" description=""
empty_comment="A later run found nothing left to decide."
changed_comment="This changed since the last run."

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --fingerprint) fingerprint="$2"; shift 2 ;;
    --nothing-to-report) nothing=1; shift ;;
    --empty-comment) empty_comment="$2"; shift 2 ;;
    --changed-comment) changed_comment="$2"; shift 2 ;;
    --colour) colour="$2"; shift 2 ;;
    --description) description="$2"; shift 2 ;;
    *) echo "file-report.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

WHY="$(mktemp)"
trap 'rm -f "$WHY"' EXIT

[ -n "$REPO" ] || { echo "file-report.sh: no repository" >&2; exit 2; }
[ -n "$label" ] || { echo "file-report.sh: --label is required" >&2; exit 2; }

# "EDITING A BODY NOTIFIES NOBODY" IS TRUE UNTIL THE BODY NAMES SOMEONE.
#
# A handle an edit puts into a body is a mention, and GitHub notifies that
# person on the edit. The triage report quotes upstream release notes, and on
# 2026-11-12 a maintainer whose project this fleet only tracks asked in
# heyvaldemar/fleet-ops#50 to stop being notified: "Thanks to @<them>" in a
# quoted changelog had reached them on every rewrite since 2026-11-06. Nothing
# a report says is meant to call anyone, so every body and comment written
# below goes through scripts/quiet-mentions.py first. It is checked here, before
# anything is written, because a filter that fails mid-pipe leaves an empty file
# and an empty body is worse than the mention.
QUIET="$(cd "$(dirname "$0")" && pwd)/quiet-mentions.py"
quiet() { python3 -I "$QUIET"; }
# The backticks are the filter's output, compared as text. Nothing expands.
# shellcheck disable=SC2016
if [ "$(printf 'x @a' | quiet)" != 'x `@a`' ]; then
  echo "file-report.sh: $QUIET does not run here, and no report goes out without it" >&2
  exit 2
fi

$GH label create "$label" --repo "$REPO" --color "$colour" \
  ${description:+--description "$description"} >/dev/null 2>&1 || true

# Newest first, which is what makes the first one the thread to keep.
open_issues="$($GH issue list --repo "$REPO" --label "$label" --state open \
  --json number --jq '.[].number' 2>/dev/null)"

if [ "$nothing" -eq 1 ]; then
  if [ -z "$open_issues" ]; then
    echo "nothing to report, and no open $label thread"
    exit 0
  fi
  for n in $open_issues; do
    # THE REASON GOES IN THE BODY, NOT IN A COMMENT.
    #
    # Closing with --comment posts a comment and closes, and each of those is
    # its own notification: two mails to say one thing. The close event has to
    # notify, and should — an empty queue is worth knowing — but the sentence
    # explaining it does not need a mail of its own. Editing a body notifies
    # nobody, so the reason is prepended there and the close goes out alone.
    body="$($GH issue view "$n" --repo "$REPO" --json body --jq .body 2>/dev/null)"
    printf '> %s\n\n%s\n' "$empty_comment" "$body" | quiet > "$WHY"
    $GH issue edit "$n" --repo "$REPO" --body-file "$WHY" >/dev/null 2>&1 || true
    $GH issue close "$n" --repo "$REPO" >/dev/null && echo "closed #$n"
  done
  exit 0
fi

# Written as plain ifs rather than A && B || C. The chained form is correct
# here and two shellcheck versions disagree about whether to say so, which
# makes the answer depend on which machine ran the linter.
if [ -z "$body" ] || [ ! -f "$body" ]; then
  echo "file-report.sh: --body must name a file" >&2
  exit 2
fi
if [ -z "$fingerprint" ] || [ ! -f "$fingerprint" ]; then
  echo "file-report.sh: --fingerprint must name a file" >&2
  exit 2
fi

# AN EMPTY FINGERPRINT IS A BUG, AND A QUIET ONE. It means the caller's
# extraction matched nothing, so every run would hash the same empty string,
# every run would look unchanged, and this thread would never say another word
# while the fleet burned. Falling back to the whole body is noisier and that is
# the point: when this mechanism is unsure, it must fail towards telling
# someone, never towards silence.
if [ ! -s "$fingerprint" ]; then
  echo "::warning::file-report.sh: the fingerprint for $label came out empty, so the whole report is being used instead. Whatever produced $fingerprint no longer matches the report." >&2
  fingerprint="$body"
fi

# A SET, NOT A HASH, because the two directions are not the same news.
#
# One hash over the whole list answers "did anything change". That is the wrong
# question. A list going from twelve items to nine to three is three
# notifications, and two of them say only that the fleet fixed things without
# help. On 2026-09-17 that is exactly what arrived: 12, then 9, then 3, all
# within twenty minutes.
#
# What a person needs to be told is that something NEW needs them. Something
# resolving is visible in the body whenever they next look, and it is not an
# interruption. So each finding is hashed on its own and the set is stored; a
# comment is posted only when the set gains a member.
# AN AGE THAT GREW BY ITSELF IS NOT NEW NEWS.
#
# Most findings this fleet produces carry an elapsed time: "last fired 51 hours
# ago", "has been open 40 hours", "expires in 9 days". That number moves on its
# own between runs, so a finding nobody has fixed hashes differently every time
# and reads as a fresh one — a comment and an email twice a day about the same
# unfixed thing. It would arrive worst on the day something actually stopped,
# which is the one finding here that must not be buried.
#
# So each line is hashed with its durations blanked. Only a number followed by
# a unit of time is touched: pull request numbers, version numbers and plain
# counts still tell two findings apart, and the body keeps the real figures.
age_blind() {
  # No \b here on purpose: BSD sed has no word boundary and fails this match
  # silently, so the runner would blank ages and a local check would not. The
  # optional trailing s does the same job in both.
  sed -E 's/[0-9]+(\.[0-9]+)?[[:space:]]+(second|minute|hour|day|week|month)(s?)/<age> \2\3/g'
}

# ONE WAITING BRANCH IS ONE DECISION, HOWEVER THE RUN WORDS IT.
#
# fleet-triage.sh says a prepared branch two ways. The run that pushes it
# writes "<repo>: 0.12.5 -> 0.13.3 prepared on branch `bump/0.13.3` (...) —
# open it: <url> — needs a human". A run that only finds it there writes
# "<repo>: `bump/0.13.3` is still ahead of main with no pull request open —
# open it or delete it: <url> — needs a human". Same branch, same decision,
# two hashes, and the thread flips between them for as long as the branch
# waits. On 2026-11-10 that mailed "what needs a decision has changed" twice,
# at 02:29 and 15:27 UTC, about a list holding the same three items.
#
# So the first sentence is read as the second before it is hashed. As the
# second and not as a third key, because the second is what an open thread
# already stores: a new key would be new to every thread, and the fix for a
# false alarm would send one more. Repository and branch stay in the line, so
# another branch is still another finding, and the body keeps the sentence the
# run wrote. tests/test-file-report.sh holds fleet-triage.sh to both wordings.
same_branch() {
  # The backticks are the report's own, around the branch name. Nothing here
  # is meant to expand.
  # shellcheck disable=SC2016
  sed -E 's#^(- )?([^:[:space:]]+): .* prepared on branch `([^`]+)`.*(https://github\.com/[^[:space:]]+/compare/main\.\.\.[^[:space:]]+) — needs a human$#\1\2: `\3` is still ahead of main with no pull request open — open it or delete it: \4 — needs a human#'
}

fp="$(sort -u "$fingerprint" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s' "$line" | age_blind | same_branch | shasum -a 256 | cut -c1-8
      done | sort -u | tr '\n' ' ')"
fp="${fp% }"

full="$(mktemp)"
trap 'rm -f "$full" "$WHY"' EXIT
{ cat "$body"; printf '\n<!-- %s: %s -->\n' "$MARKER" "$fp"; } | quiet > "$full"

keep=""
for n in $open_issues; do
  if [ -z "$keep" ]; then
    keep="$n"
  else
    # More than one open thread under this label means an earlier run left one
    # behind. Without this the fingerprint below would be compared against
    # whichever happened to be listed first, and the answer would depend on
    # the order GitHub returned them in.
    # The reason in the body, the close on its own, for the reason written
    # against the other close above: two notifications to say one thing.
    dup="$($GH issue view "$n" --repo "$REPO" --json body --jq .body 2>/dev/null)"
    printf '> Superseded by #%s.\n\n%s\n' "$keep" "$dup" | quiet > "$WHY"
    $GH issue edit "$n" --repo "$REPO" --body-file "$WHY" >/dev/null 2>&1 || true
    $GH issue close "$n" --repo "$REPO" >/dev/null \
      && echo "closed duplicate #$n"
  fi
done

if [ -z "$keep" ]; then
  # SAYING IT OPENED ONE IS NOT THE SAME AS OPENING ONE. On 2026-09-22 this
  # printed "opened a new fleet-to-hosts thread" twice against two repositories
  # the credential could not write to, and both reports were lost while the
  # run went green. A report filer that cannot tell whether it filed is the
  # exact shape every check in this repository is written to refuse.
  if ! $GH issue create --repo "$REPO" --label "$label" --title "$title" --body-file "$full"; then
    echo "file-report.sh: could not open a $label thread in $REPO — the report below reached nobody" >&2
    sed -n '1,40p' "$full" >&2
    exit 1
  fi
  echo "opened a new $label thread"
  exit 0
fi

was="$($GH issue view "$keep" --repo "$REPO" --json body --jq .body 2>/dev/null \
  | sed -n "s/.*<!-- $MARKER: \\([0-9a-f ]*\\) -->.*/\\1/p" | tail -1)"

# AN UNCHANGED LIST IS NOT TOUCHED AT ALL, not even its body.
#
# Editing a body sends no mail, and that was the design: rewrite it every run
# so the ages and counts inside stay true. It is still not free. GitHub records
# the edit against the thread, so a subscriber's web inbox is bumped by a run
# that had nothing to say, three times a day. Measured on 2026-09-17: a run
# that posted no comment still moved the thread to the top of the inbox.
#
# When the set of findings is identical there is nothing in the body worth that
# bump. The report carries its own timestamp in its first line, so a reader can
# always see which run last wrote it, and the decisions it lists are current by
# definition, because they are the ones that have not changed.
if [ "$was" = "$fp" ]; then
  echo "#$keep says the same thing; left untouched, nothing notified"
  exit 0
fi

$GH issue edit "$keep" --repo "$REPO" --title "$title" --body-file "$full" >/dev/null

# What is in the new set and was not in the old one. Anything that only left
# the set is progress, and progress is not an interruption.
appeared=""
for h in $fp; do
  case " $was " in *" $h "*) ;; *) appeared="$appeared $h" ;; esac
done

if [ -z "$appeared" ]; then
  # The body is current and nobody was told, which is the whole point.
  echo "#$keep only lost findings; updated in place, nobody mailed"
else
  $GH issue comment "$keep" --repo "$REPO" --body "$(printf '%s' "$changed_comment" | quiet)" >/dev/null
  echo "#$keep gained $(printf '%s' "$appeared" | wc -w | tr -d ' ') finding(s); commented once"
fi
