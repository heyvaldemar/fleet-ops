#!/usr/bin/env bash
# test-quiet-mentions.sh - scripts/quiet-mentions.py makes every handle in a
# report inert and changes nothing else.
#
# The case that made it: the triage report's upstream review of an Immich
# release quoted its notes thanking a maintainer by handle, and every rewrite
# of heyvaldemar/fleet-ops#50 notified that maintainer again.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

q() { printf '%s' "$1" | python3 -I "$ROOT/scripts/quiet-mentions.py"; }
same() { # label input expected
  local got; got="$(q "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1: got [$got], expected [$3]"; fi
}

echo "== handles in prose become code"
# shellcheck disable=SC2016
same "the quote that pinged a maintainer" \
  '"Thanks to @some-maintainer for a whole batch of security fixes"' \
  '"Thanks to `@some-maintainer` for a whole batch of security fixes"'
# shellcheck disable=SC2016
same "at the start of a line, in brackets, before punctuation" \
  '@alice (@bob-c), @dave.' \
  '`@alice` (`@bob-c`), `@dave`.'
# shellcheck disable=SC2016
same "a team, which notifies all its members" \
  'cc @some-org/some-team' \
  'cc `@some-org/some-team`'
# shellcheck disable=SC2016
same "inside a blockquote and a list" \
  $'> by @alice\n- reviewed by @bob' \
  $'> by `@alice`\n- reviewed by `@bob`'

echo "== what is not a mention is left as it is"
same "an address" 'mail security@example.com' 'mail security@example.com'
same "an action ref" 'uses actions/checkout@v4' 'uses actions/checkout@v4'
same "a digest" 'alpine@sha256:9db29348' 'alpine@sha256:9db29348'
same "a lone at sign" 'meet @ 10' 'meet @ 10'
same "a handle that ends in a hyphen is no login" 'x @bad- y' 'x @bad- y'

echo "== code is left alone"
# shellcheck disable=SC2016
same "an inline span" 'run `@dependabot rebase` now' 'run `@dependabot rebase` now'
# shellcheck disable=SC2016
same "a double-backtick span" 'see ``a `@b` c`` here' 'see ``a `@b` c`` here'
fenced=$'```\n@alice in a block\n```\nand @bob after it'
# shellcheck disable=SC2016
want=$'```\n@alice in a block\n```\nand `@bob` after it'
same "a fenced block, and prose after it" "$fenced" "$want"
# shellcheck disable=SC2016
same "a lone backtick does not swallow the next paragraph" \
  $'a stray ` here\n\nthanks @alice' \
  $'a stray ` here\n\nthanks `@alice`'

echo "== nothing else changes"
body=$'## Report\n\n- dozzle: needs a human\n<!-- fleet-report-fingerprint: 1a2b3c4d -->'
same "a report with no handle comes out byte for byte" "$body" "$body"
# Counted in bytes: $(...) would strip the very newlines being checked.
got="$(printf 'a @b\n\n' | python3 -I "$ROOT/scripts/quiet-mentions.py" | wc -c | tr -d ' ')"
if [ "$got" = 8 ]; then ok "trailing newlines are kept"; else no "came out $got bytes, expected 8"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
