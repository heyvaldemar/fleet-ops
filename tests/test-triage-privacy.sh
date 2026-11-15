#!/usr/bin/env bash
# Triage and lifecycle run in the public copy of fleet-ops, and only the house
# copy may name a private repository.
#
# Both ask /user/repos, which answers with the private repositories too, and
# both name every repository they list: in the run log, the report and the
# issue, all readable by anyone. They kept whatever scripts/fleet_kind.py
# accepted, and fleet_kind decides by name, so the first private repository
# named like a template would have been published by both. None was when this
# was written (2026-11-14); fleet-heartbeat.py had drawn the line already.
#
# A fake gh serves one public template, one private one, one whose answer
# leaves its visibility out, and one archived. The private names are invented:
# this file is published with the rest of the public copy.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"$'\n'"          expected: $2"$'\n'"          actual:   $3"; fi
}

# git-auth.sh, which the script sources first, refuses to load without a
# token; nothing here talks to GitHub, so a placeholder does.
GH_TOKEN="${GH_TOKEN:-placeholder-not-a-token}"
FLEET_TEST_SOURCE_ONLY=1 . "$ROOT/scripts/fleet-triage.sh" 2>/dev/null || true
if ! declare -F list_repos >/dev/null; then
  echo "  FAIL  list_repos could not be sourced from scripts/fleet-triage.sh"
  exit 1
fi
set +e
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/repos.json" <<'JSON'
[
  {"name": "open-wiki-traefik-letsencrypt-docker-compose", "archived": false, "private": false},
  {"name": "planted-ledger-traefik-letsencrypt-docker-compose", "archived": false, "private": true},
  {"name": "planted-novis-traefik-letsencrypt-docker-compose", "archived": false},
  {"name": "planted-vault-pipeline-terraform", "archived": false, "private": true},
  {"name": "shelved-board-traefik-letsencrypt-docker-compose", "archived": true, "private": false}
]
JSON

# The fake answers the one listing triage asks for, through the --jq the
# script passes, and nothing else.
gh() {
  local q=""
  [ "${1:-} ${2:-}" = "api user/repos?affiliation=owner&per_page=100" ] || return 1
  while [ $# -gt 0 ]; do [ "$1" = --jq ] && q="$2"; shift; done
  jq -r "$q" "$WORK/repos.json"
}

triage_lists() {   # triage_lists <FLEET_ROLE>: the names, one per line, and everything it printed
  ( FLEET_ROLE="$1"; REPOS=(); list_repos > "$WORK/said" 2>&1; printf '%s\n' "${REPOS[@]}" )
}

echo "== triage, public copy"
got="$(triage_lists "")"
same "only the public template is listed" "open-wiki-traefik-letsencrypt-docker-compose" "$got"
same "no private name is listed or printed" "0" "$(cat "$WORK/said" - <<<"$got" | grep -c planted- || true)"
got="$(triage_lists public)"
same "any role but house is public" "open-wiki-traefik-letsencrypt-docker-compose" "$got"

echo "== triage, house copy"
got="$(triage_lists house)"
same "the house lists the private ones too, archived still left out" \
  "$(printf '%s\n' open-wiki-traefik-letsencrypt-docker-compose planted-ledger-traefik-letsencrypt-docker-compose planted-novis-traefik-letsencrypt-docker-compose planted-vault-pipeline-terraform)" "$got"

echo "== lifecycle"
if python3 - "$ROOT" "$WORK/repos.json" <<'PY'
import importlib.util, json, os, sys
root, fixture = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "scripts"))
spec = importlib.util.spec_from_file_location("lifecycle", os.path.join(root, "scripts", "fleet-lifecycle.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
pages = {1: json.load(open(fixture))}
asked = []
def gh(path, raw=False, timeout=30):
    asked.append(path)
    if not path.startswith("user/repos?affiliation=owner&per_page=100&page="):
        raise AssertionError("unexpected request " + path)
    return pages.get(int(path.rsplit("=", 1)[1]), [])
m.gh = gh
bad = 0
def same(what, want, got):
    global bad
    if want == got:
        print("  ok    %s" % what)
    else:
        bad += 1
        print("  FAIL  %s\n          expected: %r\n          actual:   %r" % (what, want, got))
os.environ.pop("FLEET_ROLE", None)
same("the public copy lists only the public template",
     ["open-wiki-traefik-letsencrypt-docker-compose"], m.fleet_repos())
os.environ["FLEET_ROLE"] = "house"
same("the house lists the private ones too, archived still left out",
     ["open-wiki-traefik-letsencrypt-docker-compose", "planted-ledger-traefik-letsencrypt-docker-compose",
      "planted-novis-traefik-letsencrypt-docker-compose", "planted-vault-pipeline-terraform"], m.fleet_repos())
sys.exit(1 if bad else 0)
PY
then ok "lifecycle draws the same line"; else no "lifecycle names a private repository in the public copy"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
