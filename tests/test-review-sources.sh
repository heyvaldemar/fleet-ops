#!/usr/bin/env bash
# Every repository this reviewer would go looking in has to exist.
#
# A third of the images this fleet pins once resolved to a repository that is
# not there, and every one of those reviews came back "the release notes could
# not be retrieved" — a verdict about the lookup wearing the clothes of a
# verdict about the upgrade. The failure is silent by construction: the review
# still runs, still writes a paragraph, and still says NEEDS ATTENTION.
#
# Network is required, and that is the point: a table of repository names can
# only be checked against the thing it names.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

read_table() {
  python3 - "$1" <<'PY'
import ast, io, sys
s = io.open("scripts/upstream-review.py", encoding="utf-8").read()
b = s.split(sys.argv[1] + " = ", 1)[1]
d = e = 0
for i, c in enumerate(b):
    if c == "{":
        d += 1
    elif c == "}":
        d -= 1
        if d == 0:
            e = i + 1
            break
for k, v in ast.literal_eval(b[:e]).items():
    print("%s\t%s" % (k, v))
PY
}

sources="$(read_table SOURCES)"
[ -n "$sources" ] || { echo "  FAIL  SOURCES could not be read at all"; exit 1; }
echo "== every SOURCES value is a repository that exists"
missing=""
while IFS=$'\t' read -r image repo; do
  [ -n "$repo" ] || continue
  gh api "repos/$repo" --jq .full_name >/dev/null 2>&1 || missing="$missing $image->$repo"
done <<< "$sources"
if [ -z "$missing" ]; then
  ok "all $(printf '%s\n' "$sources" | wc -l | tr -d ' ') of them resolve"
else
  no "these point at nothing:$missing"
fi

echo "== a name that cannot exist is caught"
# The check above can only be trusted if it fails on a repository that is not
# there. This one cannot be: the owner is reserved and the name is nonsense.
if gh api "repos/heyvaldemar/this-name-is-not-a-repository-xyzzy" --jq .full_name >/dev/null 2>&1; then
  no "a repository that should not exist answered — this check proves nothing"
else
  ok "the lookup this check relies on does report absence"
fi

echo "== nothing is in both tables"
both="$(comm -12 <(read_table SOURCES | cut -f1 | sort) <(read_table NO_NOTES | cut -f1 | sort))"
if [ -z "$both" ]; then
  ok "no image is both mapped and declared unmappable"
else
  no "in both SOURCES and NO_NOTES: $both"
fi

echo "== every NO_NOTES entry says why"
short="$(read_table NO_NOTES | awk -F'\t' 'length($2) < 25 {print $1}')"
if [ -z "$short" ]; then
  ok "each one carries a reason a reader can act on"
else
  no "these have no real reason: $short"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
