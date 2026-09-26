#!/usr/bin/env bash
# The scout re-ranks the same catalogue every Monday and the scores barely
# move, so it proposed the same three candidates a day after they were judged
# and closed. A report that repeats a decision somebody already made stops
# being read, and a scout nobody reads has failed completely rather than
# partly.
#
# The risk in the fix is that it is silent: a mistyped key filters nothing and
# the file still looks right. That is what most of this exercises.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import importlib.util, io, json, os, sys, types

# The scout imports the Anthropic SDK at module scope for the part of its work
# this file does not touch. A stand-in keeps the import from deciding whether
# these assertions can run at all.
for name in ("anthropic",):
    if name not in sys.modules:
        m = types.ModuleType(name)
        m.WorkloadIdentityCredentials = object
        m.Anthropic = object
        sys.modules[name] = m

spec = importlib.util.spec_from_file_location("sc", "scripts/fleet-scout.py")
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

passed = failed = 0
def check(what, got, want):
    global passed, failed
    if got == want:
        print("  PASS: %s" % what); passed += 1
    else:
        print("  FAIL: %s\n        got %r, wanted %r" % (what, got, want)); failed += 1

print("=== the list of decisions the scout must not re-open ===")
d = sc.declined()
check("the shipped list is readable", isinstance(d, dict), True)
check("its comment is not a candidate", "_comment" in d, False)
check("every entry says when it was decided and why",
      all({"decided", "verdict", "why"} <= set(v) for v in d.values()), True)

# THE SLUG IS THE WHOLE MECHANISM. It is the catalogue name lowercased with
# runs of non-alphanumerics hyphenated, so "Dify.ai" is dify-ai and not dify.
# Every key must be a slug of itself, or it matches nothing and the file does
# nothing while looking like it works.
import re
def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
check("every key is already in slug form", [k for k in d if slug(k) != k], [])
check("and the three that were judged are the three named",
      sorted(d), ["dify-ai", "hoppscotch-community-edition", "stirling-pdf"])

# The three as the catalogue actually spells them.
for name in ("Dify.ai", "Stirling-PDF", "Hoppscotch Community Edition"):
    check("%s resolves to a declined key" % name, slug(name) in d, True)

# A missing file means nothing has been declined, which is the safe reading:
# a deleted list must not quietly empty the catalogue.
real = os.path.join("scripts", "..", "scout-declined.json")
moved = real + ".hidden"
os.rename(real, moved)
try:
    check("with no list at all, nothing is declined", sc.declined(), {})
finally:
    os.rename(moved, real)

# And a file that is not JSON is the same answer rather than a crash.
io.open(moved, "w", encoding="utf-8").write("{ not json")
os.replace(real, real + ".keep"); os.replace(moved, real)
try:
    check("an unreadable list declines nothing either", sc.declined(), {})
finally:
    os.replace(real + ".keep", real)

print("\npassed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
