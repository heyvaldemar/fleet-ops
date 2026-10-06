#!/usr/bin/env bash
# The release a template runs now is read as a baseline, not as a change.
#
# On 2026-10-06 the review of Rocket.Chat 8.8.1 -> 8.9.0 read "MongoDB: 8.0"
# under the new release's engine versions, called it a mismatch against the
# template's MongoDB 7.0, and triage held the bump for a person. The 8.8.1
# notes carried the same line, the template had been running 8.8.1 on 7.0,
# and the startup check that enforces the version was unchanged. The review
# had only ever been shown the notes AFTER the pin.
#
# The lookup is offline here against a stand-in for the GitHub API. One live
# read follows, of the very release that was misread, because a lookup that
# has never met the real API is a lookup nobody has checked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import importlib.util, sys, types, urllib.error

for name in ("anthropic", "anthropic_federation"):
    if name not in sys.modules:
        mod = types.ModuleType(name)
        if name == "anthropic":
            mod.Anthropic = object
            mod.WorkloadIdentityCredentials = object
        else:
            mod.FEDERATION = {}
            mod.answer = lambda *a, **k: ("", None)
            mod.github_oidc_token = lambda *a, **k: ""
        sys.modules[name] = mod

spec = importlib.util.spec_from_file_location("ur", "scripts/upstream-review.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0
def check(what, got, want):
    global passed, failed
    if got == want:
        print("  PASS: %s" % what); passed += 1
    else:
        print("  FAIL: %s\n        got %r, wanted %r" % (what, got, want)); failed += 1

def stand_in(releases):
    asked = []
    def gh(path):
        asked.append(path)
        tag = path.rsplit("/", 1)[1]
        if tag in releases:
            return releases[tag]
        raise urllib.error.HTTPError(path, 404, "Not Found", None, None)
    return gh, asked

print("=== which release is the baseline ===")
real_gh = m.gh
m.gh, asked = stand_in({"8.8.1": {"tag_name": "8.8.1", "published_at": "2026-10-01T00:00:00Z",
                                  "body": "### Engine versions\n\n- MongoDB: `8.0`"}})
out = m.from_release("RocketChat/Rocket.Chat", "8.8.1")
check("a bare tag is found as it is written", out is not None and "MongoDB: `8.0`" in out, True)
check("and is labelled with its tag and date", out.splitlines()[0], "### 8.8.1 (2026-10-01)")

m.gh, asked = stand_in({"v2.1.0": {"tag_name": "v2.1.0", "body": "needs PostgreSQL 16"}})
out = m.from_release("o/app", "2.1.0@sha256:abc")
check("a v-prefixed tag is found from a pin that carries a digest", out is not None and "PostgreSQL 16" in out, True)
check("the digest never reaches the lookup", any("@" in p for p in asked), False)

m.gh, asked = stand_in({"release-3.0.0": {"tag_name": "release-3.0.0", "body": "x"}})
check("a release- prefix is tried as well", m.from_release("o/app", "3.0.0") is not None, True)

m.gh, asked = stand_in({"1.0.0": {"tag_name": "1.0.0", "body": "   "}})
check("an empty body is no baseline", m.from_release("o/app", "1.0.0"), None)

m.gh, asked = stand_in({})
check("no release at all is no baseline, not an error", m.from_release("o/app", "9.9.9"), None)
check("and each spelling is asked once", len(asked), len(set(asked)))

print()
print("=== the review is told what the baseline is for ===")
src = open("scripts/upstream-review.py", encoding="utf-8").read()
check("the prompt carries the baseline section", "THE RELEASE THE TEMPLATE RUNS NOW" in src, True)
check("and the rule that it never decides the verdict",
      "do not let it decide the verdict" in src, True)

print()
print("=== one live read: the release that was misread ===")
m.gh = real_gh
try:
    live = m.from_release("RocketChat/Rocket.Chat", "8.8.1")
except Exception as e:
    live = None
    print("  (live read raised %s)" % e)
check("Rocket.Chat 8.8.1 already named MongoDB 8.0", live is not None and "MongoDB: `8.0`" in live, True)

print("\npassed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
