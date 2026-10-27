#!/bin/bash
# scripts/fleet_kind.py decides which repositories are in the fleet and how
# each is treated. These cases are what it has to get right, and the last
# block makes sure every tool that selects repositories asks it rather than
# carrying a pattern of its own again: five tools with five patterns is how a
# repository ends up seen by some and missed by others.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$ROOT/scripts/fleet_kind.py"
PASSED=0; FAILED=0
ok() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
no() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
verdict() {          # verdict <status> <pass message> <fail message>
  if [ "$1" -eq 0 ]; then ok "$2"; else no "$3"; fi
}

echo "=== fleet_kind: which repository is which ==="
while read -r name want; do
  got="$(python3 "$K" kind "$name" 2>/dev/null || echo none)"
  same=1; [ "$got" = "$want" ] && same=0
  verdict "$same" "$name is $want" "$name is '$got', expected $want"
done <<'CASES'
nextcloud-traefik-letsencrypt-docker-compose compose
cs2-server-docker-compose compose
rathena-docker docker
amazon-eks-cluster-pipeline-terraform terraform
chatops-privilege-wall compose
aws-eks-reference-platform kubernetes
kubernetes-portable-platform kubernetes
kubernetes-ai-workload-sandbox kubernetes
kubernetes-ai-agent-sandbox focused
kubernetes-supply-chain-admission focused
kubernetes-postgres-recovery focused
kubernetes-air-gapped-ai-agent focused
cypress-cloud-triage-agent focused
helm-charts helm
heyvaldemar-com none
deadman-switch none
CASES

out="$(printf 'aws-eks-reference-platform\nhelm-charts\nrathena-docker\namazon-eks-cluster-pipeline-terraform\n' | python3 "$K" filter --triaged | cut -f1 | tr '\n' ' ')"
same=1; [ "$out" = "rathena-docker amazon-eks-cluster-pipeline-terraform " ] && same=0
verdict "$same" "triage gets compose, docker and terraform only" "triage would get: $out"

# The file listing must agree with the name for the shapes whose rules differ.
python3 - "$ROOT/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import fleet_kind as k
cases = {
    ("platform", "kind", "Makefile", "README.md"): "kubernetes",
    ("kind", "manifests", "Makefile", "gvisor.lock"): "focused",
    ("Chart.yaml", "values.yaml"): "helm",
    ("nextcloud-docker-compose.yml", ".env.example"): "compose",
    ("01-providers.tf", "README.md"): "terraform",
    ("Dockerfile", "README.md"): "docker",
    ("README.md",): None,
}
bad = [(n, k.kind_from_files(n), w) for n, w in cases.items() if k.kind_from_files(n) != w]
sys.exit(1 if bad else 0)
PY
verdict $? "the file listing classifies each shape" "the file listing misclassifies a shape"

echo "=== every tool asks fleet_kind ==="
for f in fleet-triage.sh fleet-heartbeat.py fleet-lifecycle.py fleet-catalog.py fleet-conformance.py; do
  grep -q 'fleet_kind' "$ROOT/scripts/$f"; verdict $? "$f asks fleet_kind" "$f does not ask fleet_kind"
done
# A classification pattern of its own, anywhere but fleet_kind.py. The
# catalog's title() strips suffixes for display and is not a classification.
left="$(grep -nE '(docker-compose\\?\$|docker\\?\$\|-terraform|\(docker-compose\|docker)' "$ROOT"/scripts/fleet-{triage.sh,heartbeat.py,lifecycle.py,conformance.py} 2>/dev/null | grep -vE '^\s*#|title|re\.sub' || true)"
same=1; [ -z "$left" ] && same=0
verdict "$same" "no tool carries a name pattern of its own" "a name pattern outside fleet_kind.py: $left"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
