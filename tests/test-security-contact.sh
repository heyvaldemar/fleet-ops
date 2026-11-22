#!/usr/bin/env bash
# scripts/rollout-security-contact.sh, dry run, against four local repositories
# served in place of GitHub (url.insteadOf), and the copy from before
# 17 November 2026 (tests/fixtures/security-contact/before-2026-11-17.sh) the
# same way. The old copy called a policy current as soon as it linked the
# advisory form anywhere, so two of the four below would never have been
# looked at again: one keeps an old contact line beside the new one, one
# names the form in its own words with an old address still in it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok    $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — wanted [$3] in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-500)" ;; esac; }

OWNER=heyvaldemar
CONTACT=security@example.org
OLD_ADDR=old-contact@example.net
PROCESS="The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/)."
new_line() { echo "Report privately through GitHub: [**Security → Report a vulnerability**](https://github.com/$OWNER/$1/security/advisories/new) on this repository. Email to $CONTACT also works. $PROCESS"; }
OLD_LINE="Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to $OLD_ADDR also works. $PROCESS"

repo() {   # repo <name> <SECURITY.md body>: a bare repository with one commit on main
  local src="$WORK/src/$1"
  mkdir -p "$src" "$WORK/remotes"
  git -C "$src" init -q -b main
  printf '# Security policy\n\n%s\n' "$2" > "$src/SECURITY.md"
  git -C "$src" add SECURITY.md
  git -C "$src" -c user.name=t -c user.email=t@example.org commit -q -m init
  git clone -q --bare "$src" "$WORK/remotes/$1.git"
}
repo sc-current "$(new_line sc-current)"
repo sc-old "$OLD_LINE"
repo sc-both "$(new_line sc-both)
$OLD_LINE"
repo sc-own-words "Use the [advisory form](https://github.com/$OWNER/sc-own-words/security/advisories/new), or mail $OLD_ADDR."

cat > "$WORK/gitconfig" <<EOF
[url "file://$WORK/remotes/"]
	insteadOf = https://github.com/$OWNER/
EOF

run() {   # run <script>: OUT, RC (dry run, nothing is pushed, GitHub is never asked)
  mkdir -p "$WORK/bin/scripts"
  cp "$1" "$WORK/bin/scripts/rollout-security-contact.sh"
  cp "$ROOT/scripts/git-auth.sh" "$WORK/bin/scripts/git-auth.sh"
  RC=0
  OUT="$(GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=dummy DRY_RUN=true \
         SECURITY_CONTACT_EMAIL="$CONTACT" REPOS_ONLY="sc-current sc-old sc-both sc-own-words" \
         bash "$WORK/bin/scripts/rollout-security-contact.sh" 2>&1)" || RC=$?
}

echo "== the copy from before 17 November 2026"
run "$ROOT/tests/fixtures/security-contact/before-2026-11-17.sh"
has "it called three policies current, two of them wrongly (the finding)" "$OUT" "already current: 3"
has "and rewrote the old one" "$OUT" "would rewrite sc-old"

echo "== the script"
run "$ROOT/scripts/rollout-security-contact.sh"
has "the line it writes, alone, is current" "$OUT" "already current: 1"
has "an old line is rewritten" "$OUT" "would rewrite sc-old"
has "the new line beside an old one is left for a person" "$OUT" "sc-both: the new contact line and 1 old one(s) side by side, left alone"
has "the form in other words is left for a person" "$OUT" "sc-own-words: links the form in its own words"
has "and the run says so with its counts" "$OUT" "left alone: 2"
if [ "$RC" -ne 0 ]; then ok "a run that left policies alone does not end green"; else no "a run that left policies alone ended green"; fi

echo
echo "security-contact: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
