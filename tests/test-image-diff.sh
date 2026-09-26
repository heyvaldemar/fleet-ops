#!/usr/bin/env bash
# Ask the image, not the note.
#
# On 2026-09-22 dashy's notes said "Use UID/GID=1000 instead of node as default"
# and the review called it NEEDS ATTENTION — the right call from notes alone,
# because a bind-mounted file and a changed container user is how an upgrade
# breaks quietly. The images disagreed: 4.7.5 declares User=node, 4.7.7 declares
# User=1000:1000, and both are uid 1000, gid 1000. A rename.
#
# The comparison itself is offline here. One live read follows it, because a
# parser that has never met a registry is a parser nobody has checked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import importlib.util, sys, types

# The reviewer imports the SDK at module scope; this suite is about the part
# that talks to a registry, so the SDK is stood in for rather than installed.
for name in ("anthropic", "anthropic_federation"):
    if name not in sys.modules:
        m = types.ModuleType(name)
        if name == "anthropic":
            m.Anthropic = object
            m.WorkloadIdentityCredentials = object
        else:
            m.FEDERATION = {}
            m.answer = lambda *a, **k: ("", None)
            m.github_oidc_token = lambda *a, **k: ""
        sys.modules[name] = m

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

print("=== where an image lives ===")
check("a bare name is a docker hub library image", m._split_ref("ghost"),
      ("registry-1.docker.io", "library/ghost"))
check("an org name is docker hub too", m._split_ref("lissy93/dashy"),
      ("registry-1.docker.io", "lissy93/dashy"))
check("a host with a dot is its own registry", m._split_ref("ghcr.io/owner/app"),
      ("ghcr.io", "owner/app"))
check("quay as well", m._split_ref("quay.io/org/app"), ("quay.io", "org/app"))

print()
print("=== the comparison ===")
same = {"User": "node", "Entrypoint": ["/e"], "Cmd": ["c"], "Env": ["PATH=/bin", "V=1"]}
out = m.diff_configs(same, dict(same))
check("identical configurations say so in one sentence", "do not differ" in out, True)
check("and do not invent a difference", "->" in out, False)

out = m.diff_configs({"User": "node"}, {"User": "1000:1000"})
check("a changed user is named", "`User`: 'node' -> '1000:1000'" in out, True)

out = m.diff_configs({"Env": ["A=1"]}, {"Env": ["A=1", "B=2"]})
check("an added variable is named", "env `B` added" in out, True)
out = m.diff_configs({"Env": ["A=1", "B=2"]}, {"Env": ["A=1"]})
check("a removed one too", "env `B` removed" in out, True)
out = m.diff_configs({"Env": ["GHOST_VERSION=6.64.0"]}, {"Env": ["GHOST_VERSION=6.65.0"]})
check("and a changed value", "env `GHOST_VERSION`: '6.64.0' -> '6.65.0'" in out, True)

# THE FIELDS ARE THE CONTRACT BETWEEN A CONTAINER AND ITS HOST. Adding one is
# free; forgetting one is a change nobody sees.
for f in ("User", "Entrypoint", "Cmd", "WorkingDir", "ExposedPorts", "Volumes", "Healthcheck"):
    out = m.diff_configs({f: "a"}, {f: "b"})
    check("%s is compared" % f, ("`%s`" % f) in out, True)

print()
print("=== an unreadable registry is not an image that did not change ===")
keep = m.image_config
m.image_config = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no route to host"))
out = m.image_diff("whatever/image", "1", "2")
m.image_config = keep
check("it says it could not read", "could not be read" in out, True)
check("and sends the reader back to the notes", "judge on the notes alone" in out, True)
check("and claims no difference either way", "do not differ" in out, False)

print()
print("=== one live read, so the parser has met a real registry ===")
try:
    cfg = m.image_config("ghost", "6.65.0")
    check("a well-known image answers with a configuration", isinstance(cfg, dict) and bool(cfg), True)
    check("and it carries an environment", any(e.startswith("GHOST_VERSION=") for e in cfg.get("Env") or []), True)
except Exception as e:
    print("  SKIP: the registry could not be reached (%s: %s)" % (e.__class__.__name__, e))

print("\npassed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
