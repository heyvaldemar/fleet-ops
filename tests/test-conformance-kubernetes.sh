#!/bin/bash
# Every Kubernetes rule in fleet-conformance.py, and the helm_release rule for
# Terraform, shown a real violation.
#
# Same method as test-conformance.sh: a conforming copy of a real repository
# must come back clean, and each copy broken in one rule's way must come back
# with that rule's finding. A rule that stays quiet over its own violation is
# a bug in the rule.
#
#   ./tests/test-conformance-kubernetes.sh <kubernetes-repo> <terraform-repo-with-helm_release>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/fleet-conformance.py"
K8S="${1:-$ROOT/../aws-eks-reference-platform}"
TF="${2:-$ROOT/../amazon-eks-cluster-pipeline-terraform}"
for d in "$K8S" "$TF"; do [ -d "$d" ] || { echo "error: no reference repository at $d" >&2; exit 1; }; done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
run_on() { FLEET_LOCAL_DIR="$1" python3 "$CHECKER" 2>&1; }
git_in() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }

# A conforming copy of the Kubernetes reference, whatever its own release
# state: three decision records and one released, tagged version.
fixture() {          # fixture <case> [repo-name] -> the copy's directory
  local name="${2:-kubernetes-case}" d
  d="$WORK/$1/$name"; rm -rf "${WORK:?}/${1:?}"; mkdir -p "$d"
  cp -R "$K8S/." "$d/"; rm -rf "$d/.git" "$d/.cache" "$d/out"
  mkdir -p "$d/docs/decisions"
  local n=0 f
  for f in "$d"/docs/decisions/[0-9][0-9][0-9][0-9]-*.md; do [ -e "$f" ] && n=$((n+1)); done
  for i in 1 2 3; do
    [ "$n" -ge 3 ] && break
    printf '# %d. A decision\n\n- Status: accepted\n' "$i" > "$d/docs/decisions/900$i-fixture.md"; n=$((n+1))
  done
  printf '# Changelog\n\n## [1.0.0] - 2026-10-11\n\n### Added\n\n- The platform.\n' > "$d/CHANGELOG.md"
  git_in "$d" init -q && git_in "$d" add -A && git_in "$d" commit -qm fixture && git_in "$d" tag v1.0.0
  printf '%s' "$d"
}

tf_fixture() {       # tf_fixture <case> -> a copy of the Terraform reference
  # Named like a Terraform pipeline whatever the clone was called: the rules
  # are chosen by name (scripts/fleet_kind.py).
  local d="$WORK/$1/case-pipeline-terraform"; rm -rf "${WORK:?}/${1:?}"; mkdir -p "$d"
  cp -R "$TF/." "$d/"
  printf '%s' "$d"
}

expect() {           # expect <name> <parent> <substring>
  local name="$1" parent="$2" want="$3" out
  out="$(run_on "$parent")"
  if printf '%s' "$out" | grep -qF -- "$want"; then
    echo "  PASS: $name"; PASSED=$((PASSED+1))
  else
    echo "  FAIL: $name — expected a finding containing:"
    echo "        $want"
    echo "        got:"; printf '%s\n' "$out" | sed 's/^/        /' | head -14
    FAILED=$((FAILED+1))
  fi
}

expect_clean() {     # expect_clean <name> <parent>
  local out
  out="$(run_on "$2")"
  if printf '%s' "$out" | grep -q 'Every repository meets the standard'; then
    echo "  PASS: $1"; PASSED=$((PASSED+1))
  else
    echo "  FAIL: $1 — reported as broken:"; printf '%s\n' "$out" | sed 's/^/        /' | head -16
    FAILED=$((FAILED+1))
  fi
}

edit() { local f="$1"; shift; sed -i.bak "$@" "$f" && rm -f "$f.bak"; }

echo "=== fleet conformance, Kubernetes rules: does every rule fire? ==="
echo "kubernetes reference: $K8S"
echo "terraform reference:  $TF"
echo

d="$(fixture control)"
expect_clean "an untouched Kubernetes copy is reported as conforming" "$WORK/control"

d="$(fixture security)"; rm -f "$d/SECURITY.md"
expect "a missing SECURITY.md is caught" "$WORK/security" "missing SECURITY.md"

d="$(fixture validate)"; edit "$d/scripts/validate.sh" 's/^check_pluto() {/check_pluto_gone() {/'
expect "validate.sh without one of its checks is caught" "$WORK/validate" "scripts/validate.sh has no pluto check"

d="$(fixture plants)"; grep -v '"pluto"' "$d/tests/static/plants.tsv" > "$d/p" && mv "$d/p" "$d/tests/static/plants.tsv"
expect "a check with no planted violation is caught" "$WORK/plants" "no planted violation for the pluto check"

d="$(fixture novalidate)"; edit "$d/.github/workflows/verification.yml" 's#scripts/validate.sh#scripts/validate-nothing.sh#'
expect "CI that never runs validate.sh is caught" "$WORK/novalidate" "no workflow runs scripts/validate.sh"

d="$(fixture noplantrun)"; edit "$d/.github/workflows/verification.yml" '/tests\/static\/plant_violations.py/d'
expect "CI that never shows the static checks their plants is caught" "$WORK/noplantrun" "no workflow shows the static checks their planted violations"

d="$(fixture nodaily)"; edit "$d/.github/workflows/kind-e2e.yml" -e '/^  schedule:/d' -e '/- cron:/d'
expect "a kind e2e that never runs on its own is caught" "$WORK/nodaily" "the kind e2e workflow has no schedule"

d="$(fixture noupgrade)"; edit "$d/.github/workflows/kind-e2e.yml" 's/upgrade-marker.sh check/upgrade-marker.sh skip/'
expect "a kind e2e without the upgrade drill is caught" "$WORK/noupgrade" "no upgrade drill from the previous release"

d="$(fixture cloud)"
cat > "$d/.github/workflows/eks.yml" <<'EOF'
name: eks
on:
  push:
    branches: [main]
permissions:
  contents: read
  id-token: write
jobs:
  up:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@0000000000000000000000000000000000000000
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
      - run: make eks-up CONFIRM_SPEND=yes
EOF
expect "a cloud run with a stored key is caught" "$WORK/cloud" "a cloud run with a stored access key instead of OIDC"
expect "a cloud run without always-teardown is caught" "$WORK/cloud" "a cloud run without a teardown that runs if: always()"
expect "a cloud run without a timeout is caught" "$WORK/cloud" "a cloud run without a job timeout"
expect "a cloud run that starts on push is caught" "$WORK/cloud" "a cloud run that starts on its own"

# The one cloud run allowed on a schedule: ADR 10's sweeper, delete-only.
sweeper() {          # sweeper <case> <role variable> <extra step>: a scheduled sweeper workflow
  local d; d="$(fixture "$1")"
  cat > "$d/.github/workflows/sweep.yml" <<EOF
name: sweep
on:
  schedule:
    - cron: "41 6 * * *"
permissions:
  contents: read
concurrency:
  group: sweep
jobs:
  sweep:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      id-token: write
    steps:
      - uses: aws-actions/configure-aws-credentials@0000000000000000000000000000000000000000
        with:
          role-to-assume: \${{ vars.$2 }}
      - run: ./scripts/aws-sweep.sh
      - if: always()
        run: $3
EOF
}
sweeper sweep-ok AWS_SWEEP_ROLE_ARN "echo done"
expect_clean "a scheduled sweeper with the delete-only role is allowed" "$WORK/sweep-ok"
sweeper sweep-create AWS_CREATE_ROLE_ARN "echo done"
expect "a scheduled cloud run with the creation role is caught" "$WORK/sweep-create" "sweep.yml: a cloud run that starts on its own"
sweeper sweep-apply AWS_SWEEP_ROLE_ARN "terraform -chdir=terraform apply -auto-approve"
expect "a scheduled cloud run that applies is caught" "$WORK/sweep-apply" "sweep.yml: a cloud run that starts on its own"

# A run that applies may start on a schedule: at most weekly, behind a
# repository variable the owner sets.
weekly() {           # weekly <case> <cron> <job condition>: a scheduled apply with its teardown
  local d; d="$(fixture "$1")"
  cat > "$d/.github/workflows/weekly.yml" <<EOF
name: weekly
on:
  schedule:
    - cron: "$2"
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: weekly
jobs:
  up:
    if: $3
    runs-on: ubuntu-latest
    timeout-minutes: 100
    permissions:
      id-token: write
    steps:
      - uses: aws-actions/configure-aws-credentials@0000000000000000000000000000000000000000
        with:
          role-to-assume: \${{ vars.AWS_CREATE_ROLE_ARN }}
      - run: terraform -chdir=terraform apply -auto-approve
  down:
    needs: up
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - run: terraform -chdir=terraform destroy -auto-approve
EOF
}
gate="github.ref == 'refs/heads/main' && (inputs.confirm == 'SPEND' || (github.event_name == 'schedule' && vars.AWS_VALIDATION_ENABLED == 'true'))"
weekly weekly-ok "17 3 * * 1" "$gate"
expect_clean "a weekly apply behind a repository variable is allowed" "$WORK/weekly-ok"
weekly weekly-daily "17 3 * * *" "$gate"
expect "a daily apply is caught" "$WORK/weekly-daily" "weekly.yml: a cloud run that starts on its own"
weekly weekly-minutely "* * * * 1" "$gate"
expect "an apply every minute of one weekday is caught" "$WORK/weekly-minutely" "weekly.yml: a cloud run that starts on its own"
weekly weekly-ungated "17 3 * * 1" "github.ref == 'refs/heads/main'"
expect "a weekly apply with no variable to switch it off is caught" "$WORK/weekly-ungated" "weekly.yml: a cloud run that starts on its own"

# The same two shapes on Google Cloud (the flagship's ADR 22): a sweeper that
# logs in as the delete-only service account, and a weekly apply whose push
# trigger ignores main, so a branch can only ask for a credential and be refused.
gsweeper() {         # gsweeper <case> <service account variable> <extra step>
  local d; d="$(fixture "$1")"
  cat > "$d/.github/workflows/gke-sweep.yml" <<EOF
name: gke-sweep
on:
  schedule:
    - cron: "41 6 * * *"
permissions:
  contents: read
concurrency:
  group: gke-sweep
jobs:
  sweep:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      id-token: write
    steps:
      - uses: google-github-actions/auth@0000000000000000000000000000000000000000
        with:
          workload_identity_provider: \${{ vars.GKE_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: \${{ vars.$2 }}
      - run: $3
EOF
}
gsweeper gsweep-ok GKE_SWEEP_SERVICE_ACCOUNT "./scripts/gke-sweep.sh"
expect_clean "a GKE sweeper with the delete-only account needs no teardown and may be scheduled" "$WORK/gsweep-ok"
gsweeper gsweep-create GKE_CREATE_SERVICE_ACCOUNT "./scripts/gke-sweep.sh"
expect "a scheduled GKE run with the creation account is caught" "$WORK/gsweep-create" "gke-sweep.yml: a cloud run that starts on its own"
expect "a GKE run with the creation account still needs its teardown" "$WORK/gsweep-create" "gke-sweep.yml: a cloud run without a teardown that runs if: always()"

gweekly() {          # gweekly <case> <push branches line> <job condition>
  local d; d="$(fixture "$1")"
  cat > "$d/.github/workflows/gke.yml" <<EOF
name: gke
on:
  schedule:
    - cron: "23 3 * * 5"
  workflow_dispatch:
  push:
    $2
    paths:
      - gke/**
permissions:
  contents: read
concurrency:
  group: gke
jobs:
  refused:
    if: github.ref != 'refs/heads/main'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: python3 scripts/ask-for-a-credential.py
  up:
    if: $3
    runs-on: ubuntu-latest
    timeout-minutes: 100
    permissions:
      id-token: write
    steps:
      - uses: google-github-actions/auth@0000000000000000000000000000000000000000
        with:
          service_account: \${{ vars.GKE_CREATE_SERVICE_ACCOUNT }}
      - run: terraform -chdir=gke apply -auto-approve
  down:
    needs: up
    if: always() && $3
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: google-github-actions/auth@0000000000000000000000000000000000000000
        with:
          service_account: \${{ vars.GKE_CREATE_SERVICE_ACCOUNT }}
      - run: terraform -chdir=gke destroy -auto-approve
EOF
}
ggate="github.ref == 'refs/heads/main' && (inputs.confirm == 'SPEND' || (github.event_name == 'schedule' && vars.GKE_VALIDATION_ENABLED == 'true'))"
gweekly gweekly-ok "branches-ignore: [main]" "$ggate"
expect_clean "a weekly GKE apply whose push ignores main is allowed" "$WORK/gweekly-ok"
gweekly gweekly-main "branches: [main]" "$ggate"
expect "a GKE apply a push to main starts is caught" "$WORK/gweekly-main" "gke.yml: a cloud run that starts on its own"
gweekly gweekly-anybranch "branches-ignore: [main]" "github.event_name == 'schedule' && vars.GKE_VALIDATION_ENABLED == 'true' || github.event_name == 'push'"
expect "a GKE apply a branch push can reach is caught" "$WORK/gweekly-anybranch" "gke.yml: a cloud run that starts on its own"

d="$(fixture tftest)"; rm -f "$d"/terraform/tests/*.tftest.hcl
expect "Terraform without a test is caught" "$WORK/tftest" "terraform/ has no terraform test"

d="$(fixture tfplants)"; rm -f "$d/terraform/tests/plants.tsv"
expect "a Terraform test never shown a violation is caught" "$WORK/tfplants" "the Terraform test is never shown a violation in CI"

# The plant follows the pin wherever it moves. Written against 3.9.1, it
# planted nothing once the platform's Kyverno chart went to 3.9.2 on
# 2026-10-27, and this check failed on a rule that still worked.
d="$(fixture range)"; f="$d/platform/appsets/kyverno.yaml"
minor="$(sed -n 's/^ *targetRevision: \([0-9][0-9]*\.[0-9][0-9]*\)\.[0-9][0-9]*$/\1/p' "$f" | head -1)"
edit "$f" "s/targetRevision: ${minor}\.[0-9][0-9]*$/targetRevision: ${minor}.*/"
expect "a chart version range is caught" "$WORK/range" "targetRevision ${minor:-<no chart pin found>}.* is not one exact version"

# Whichever ApplicationSet carries a Git source: the file names change, the
# rule does not.
appset_with() { grep -l "$1" "$2"/platform/appsets/*.yaml | head -1; }
d="$(fixture branch)"; edit "$(appset_with "targetRevision: '{{ .metadata.annotations.platform_revision }}'" "$d")" \
  "s/targetRevision: '{{ .metadata.annotations.platform_revision }}'/targetRevision: main/"
expect "a Git source on a branch is caught" "$WORK/branch" "targetRevision main is not one exact version"

d="$(fixture generator)"
if f="$(appset_with "revision: '{{ .metadata.annotations.platform_revision }}'" "$d")" && grep -q "^ *revision: '" "$f"; then
  edit "$f" "s/^\( *\)revision: '{{ .metadata.annotations.platform_revision }}'/\1revision: HEAD/"
  expect "a Git generator reading HEAD is caught" "$WORK/generator" "revision HEAD is not one exact version"
else
  echo "  note: the reference has no Git generator yet; its rule is exercised once it does"
fi

d="$(fixture digest)"; edit "$d/apps/demo/base/frontend.yaml" 's/@sha256:[0-9a-f]*//'
expect "an authored image without a digest is caught" "$WORK/digest" "is not pinned by digest"

d="$(fixture webhookonly)"; edit "$d/policies/require-probes.yaml" '/validatingAdmissionPolicy:/{n;s/enabled: true/enabled: false/;}'
expect "a policy only Kyverno's webhook enforces is caught" "$WORK/webhookonly" "policy require-probes is enforced only through Kyverno's webhook"

d="$(fixture policytest)"; edit "$d/policies/tests/require-probes/kyverno-test.yaml" '/result: fail/d'
expect "a policy test with no violation is caught" "$WORK/policytest" "policy require-probes has no test that shows it a violation"

d="$(fixture diagram)"
# shellcheck disable=SC2016  # the backticks are literal Markdown, not a command
edit "$d/README.md" 's/```mermaid/```text/'
expect "a README without the diagram is caught" "$WORK/diagram" "README has no architecture diagram"

d="$(fixture cost)"; edit "$d/README.md" '/^#.*[Cc]ost/d'
expect "a README silent on cost is caught" "$WORK/cost" "README says nothing about what it costs"

d="$(fixture adrs)"; rm -f "$d"/docs/decisions/[0-9][0-9][0-9][0-9]-*.md
expect "missing decision records are caught" "$WORK/adrs" "docs/decisions holds 0 decision records"

d="$(fixture runbook)"; rm -f "$d/docs/runbooks/restore.md"
expect "a missing runbook is caught" "$WORK/runbook" "no restore runbook in docs/runbooks"

d="$(fixture claim)"; printf '\nIt runs in production at a large bank.\n' >> "$d/README.md"
expect "a production claim is caught" "$WORK/claim" 'README.md claims "runs in production"'

d="$(fixture claimok)"; printf '\nIt runs in production at a large bank.\n' >> "$d/README.md"
printf 'runs in production  confirmed by the maintainer on 2026-10-11\n' > "$d/.github/claims-allowlist"
expect_clean "an allowlisted claim is not a finding" "$WORK/claimok"

d="$(fixture misnamed platform-case)"
expect "a Kubernetes repository the name rule misfiles is caught" "$WORK/misnamed" "its files are a Kubernetes platform, but its name puts it outside"

d="$(tf_fixture tfcontrol)"
expect_clean "an untouched Terraform copy with helm_release is reported as conforming" "$WORK/tfcontrol"

d="$(tf_fixture tfhelm)"
for wf in "$d"/.github/workflows/*.yml; do edit "$wf" 's/helm_release/helm_rel/g'; done
expect "helm_release pins nobody compares upstream are caught" "$WORK/tfhelm" "installs charts with helm_release and no workflow compares"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
