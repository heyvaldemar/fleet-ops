#!/usr/bin/env bash
# The update.sh every template ships, run for real in a sandbox: an origin
# with v1.0.0 and v1.1.0, a clone on v1.0.0, --dry-run.
#
# Two ways it failed, both found on 2026-10-05, both silent:
#
#   An env file it cannot read. The new-variable check read .env (or the
#   .tfvars) with 2>/dev/null, so on a host where a restore had copied .env
#   back as root:root 0600 every value read as "not set"; with no new
#   variable to check, the checkout went ahead and `docker compose up` failed
#   afterwards on the permission, with the tree already on the new tag.
#
#   A release that adds a variable when no compose file requires one. The
#   ${VAR:?} search ran in a command substitution under pipefail; grep found
#   nothing, the pipeline failed, set -e ended the script with status 1 right
#   after it listed the new variables, and nothing said why.
#
# Each case runs twice: on the script as published, and on the script with
# the fix taken out, because a test that passes without the thing it tests
# proves nothing. Network is required: the scripts are read from the
# templates themselves, one compose and one Terraform.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

if [ "$(id -u)" = 0 ]; then
  echo "root reads a mode-000 file; run this as an ordinary user" >&2
  exit 1
fi

WORK="$(mktemp -d)"; trap 'chmod -R u+rwX "$WORK"; rm -rf "$WORK"' EXIT

# sandbox <update.sh> <env file> <unreadable|newvar>
# Prints "<rc> <same|moved>" on the first line, then the script's output.
sandbox() {
  local up="$1" envf="$2" mode="$3" d o before rc f
  d="$(mktemp -d "$WORK/s.XXXX")"; o="$d/origin"
  git init -q -b main "$o"
  cp "$up" "$o/update.sh"; chmod +x "$o/update.sh"
  # Every compose file the script names, none requiring anything.
  for f in $(grep -oE '^COMPOSE_FILE="[^"]+"' "$up" | cut -d'"' -f2) \
           $(grep -oE '^COMPOSE_FILES=\([^)]*\)' "$up" | sed -E 's/^COMPOSE_FILES=\(//; s/\)$//'); do
    printf 'services: {}\n' > "$o/$f"
  done
  printf 'A=1\n' > "$o/.env.example"; printf '.env\n*.tfvars\n' > "$o/.gitignore"
  git -C "$o" add -A
  git -C "$o" -c user.name=t -c user.email=t@t commit -qm one; git -C "$o" tag v1.0.0
  if [ "$mode" = newvar ]; then echo 'B=2' >> "$o/.env.example"; else echo '# two' >> "$o/.env.example"; fi
  git -C "$o" -c user.name=t -c user.email=t@t commit -qam two; git -C "$o" tag v1.1.0
  git clone -q "$o" "$d/c" 2>/dev/null; git -C "$d/c" checkout -q v1.0.0
  printf 'A=1\n' > "$d/c/$envf"
  [ "$mode" = unreadable ] && chmod 000 "$d/c/$envf"
  before="$(git -C "$d/c" rev-parse HEAD)"
  (cd "$d/c" && ./update.sh --dry-run) > "$d/out" 2>&1; rc=$?
  [ "$(git -C "$d/c" rev-parse HEAD)" = "$before" ] && echo "$rc same" || echo "$rc moved"
  cat "$d/out"
}

# planted <update.sh> <guard|required>: the script with that fix taken out.
planted() {
  python3 -c '
import re, sys
s = open(sys.argv[1]).read()
if sys.argv[2] == "guard":
    t = re.sub(r"\n# (docker compose reads \.env last|A \.tfvars this user cannot read).*?\n(fi|done)\n\n", "\n", s, count=1, flags=re.S)
else:
    t = s.replace("| tr '"'"'\\n'"'"' '"'"' '"'"' || true)\"", "| tr '"'"'\\n'"'"' '"'"' '"'"')\"", 1)
sys.stdout.write(t)
sys.exit(0 if t != s else 1)' "$1" "$2"
}

for spec in nextcloud-traefik-letsencrypt-docker-compose:.env:compose amazon-rds-pipeline-terraform:prod.tfvars:tf; do
  IFS=: read -r repo envf kind <<<"$spec"
  up="$WORK/$repo.sh"
  if ! gh api -H 'Accept: application/vnd.github.raw' "repos/heyvaldemar/$repo/contents/update.sh" > "$up" 2>/dev/null || [ ! -s "$up" ]; then
    no "could not read update.sh from $repo"; continue
  fi

  echo "== $repo: $envf at mode 000"
  res="$(sandbox "$up" "$envf" unreadable)"; head="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
  if [ "$head" = "1 same" ] && grep -q "^$envf is not readable by" <<<"$out"; then
    ok "refuses, names $envf, HEAD stays on v1.0.0"
  else
    no "expected rc 1, HEAD unmoved and $envf named; got '$head': $out"
  fi
  if planted "$up" guard > "$WORK/$repo.noguard.sh"; then
    res="$(sandbox "$WORK/$repo.noguard.sh" "$envf" unreadable)"; head="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
    if [ "${head%% *}" = 0 ]; then
      ok "without the guard the same run goes ahead, so the refusal above is the guard's"
    else
      no "without the guard the run still refused ('$head'), so the case above proves nothing: $out"
    fi
  else
    no "no guard block to take out of $repo/update.sh"
  fi

  [ "$kind" = compose ] || continue
  echo "== $repo: a release adds a variable no compose file requires"
  res="$(sandbox "$up" "$envf" newvar)"; head="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
  if [ "${head%% *}" = 0 ] && grep -q '^  B$' <<<"$out" && grep -q 'dry run' <<<"$out"; then
    ok "lists B and goes on to the dry run"
  else
    no "expected B listed and a dry run; got '$head': $out"
  fi
  if planted "$up" required > "$WORK/$repo.noor.sh"; then
    res="$(sandbox "$WORK/$repo.noor.sh" "$envf" newvar)"; head="$(head -1 <<<"$res")"
    if [ "${head%% *}" != 0 ]; then
      ok "without '|| true' the same run dies (status ${head%% *}), so the case above is the fix's"
    else
      no "without '|| true' the run still went ahead: the case above proves nothing"
    fi
  else
    no "no '|| true' on the required-variable search in $repo/update.sh"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
