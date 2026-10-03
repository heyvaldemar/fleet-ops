#!/usr/bin/env bash
# Every repository this reviewer would go looking in has to be the right one:
# present under exactly that name and carrying a version the fleet pinned, as a
# tag (scripts/verify-mapping.sh, against PROVEN_AT in upstream-review.py).
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
export GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
proven="$(read_table PROVEN_AT)"

echo "== every mapping is proven: the repository, under that name, carries the tag"
# Existence alone was the old check, and it could not say no: gh api treated a
# 401, a 403 and a rate limit the same as a 404, and a repository that merely
# answers is a coincidence. verify-mapping.sh answers 0 proven, 1 disproven,
# 2 GitHub did not answer, and only 0 passes.
broken=""; unanswered=""; unrecorded=""; n=0
while IFS=$'\t' read -r image repo; do
  [ -n "$repo" ] || continue
  n=$((n + 1))
  tag="$(awk -F'\t' -v k="$image" '$1 == k {print $2}' <<< "$proven")"
  if [ -z "$tag" ]; then unrecorded="$unrecorded $image"; continue; fi
  rc=0; ./scripts/verify-mapping.sh "$repo" "$tag" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    1) broken="$broken $image->$repo@$tag" ;;
    *) unanswered="$unanswered $image->$repo" ;;
  esac
done <<< "$sources"
if [ -z "$broken$unanswered$unrecorded" ]; then
  ok "all $n of them proven by tag"
else
  [ -z "$unrecorded" ] || no "no proving version recorded in PROVEN_AT:$unrecorded"
  [ -z "$broken" ] || no "disproven, the repository or the tag is gone:$broken"
  [ -z "$unanswered" ] || no "GitHub gave no verdict, which is not a pass:$unanswered"
fi
stale="$(comm -13 <(cut -f1 <<< "$sources" | sort) <(cut -f1 <<< "$proven" | sort))"
if [ -z "$stale" ]; then
  ok "PROVEN_AT names no image that SOURCES dropped"
else
  no "PROVEN_AT entries with no mapping: $stale"
fi

echo "== the check can say no, three ways, and can say it does not know"
# Each answer the script gives is shown a case that must produce it, or the
# zero above proves nothing.
expect_rc() {        # expect_rc <name> <wanted> <command...>
  local name="$1" want="$2" rc=0; shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$name"; else no "$name: exit $rc, wanted $want"; fi
}
expect_rc "a repository that does not exist is 1" 1 ./scripts/verify-mapping.sh henrygd/beszel-agent 0.20.0
expect_rc "a name that redirects to another project is 1" 1 ./scripts/verify-mapping.sh mysql/mysql 9.4.0
expect_rc "a real repository without the pinned tag is 1" 1 ./scripts/verify-mapping.sh henrygd/beszel 0.0.0-never-released
expect_rc "the right repository with its tag is 0" 0 ./scripts/verify-mapping.sh henrygd/beszel 0.20.0
expect_rc "a credential GitHub refuses is 2, not absent" 2 env GITHUB_TOKEN=ghp_this-token-is-not-valid ./scripts/verify-mapping.sh henrygd/beszel 0.20.0

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
