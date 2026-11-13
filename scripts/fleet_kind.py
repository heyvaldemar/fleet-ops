#!/usr/bin/env python3
"""What kind of fleet repository a name is, decided in one place.

Four tools used to decide this with four regular expressions of their own
(triage, heartbeat, lifecycle, catalog), and conformance kept a fifth list by
hand. Each new shape of repository had to be added to all of them, and the
one that was missed simply never saw it: chatops-privilege-wall sat red for
days on 2026-09-18 because its name matched none of them.

    kind_of("nextcloud-traefik-letsencrypt-docker-compose")  -> "compose"
    kind_of("aws-eks-reference-platform")                    -> "kubernetes"
    kind_of("kubernetes-ai-agent-sandbox")                   -> "focused"
    kind_of("kubernetes-llm-inference-gateway")              -> "measured"
    kind_of("cloud-evidence-pack")                           -> "evidence"
    kind_of("deadman-switch")                                -> None (not a fleet repository)

The decision is by name, because every caller has a list of names and only
some can afford to read each repository. fleet-conformance.py then checks the
name against the files (kind_from_files): a repository named as Kubernetes
that has no platform/ directory, or one that grew a compose file it is not
named for, is a finding rather than a silent misfiling.

Command line, for the shell scripts:

    ... | fleet_kind.py filter [--triaged]   names on stdin -> "name<TAB>kind"
    fleet_kind.py kind <name>                the kind, or exit 1
"""
import re
import sys

# Named for what they do rather than how they deploy; listed because no
# suffix can describe them.
NAMED = {
    "chatops-privilege-wall": "compose",
    "aws-eks-reference-platform": "kubernetes",
    # Kubernetes, but not a platform: each answers one question on kind
    # (what an untrusted agent can reach; which images a cluster will run;
    # whether a database comes back; what an agent can do with no way
    # out), with rules of its own in conformance.
    "kubernetes-ai-agent-sandbox": "focused",
    "kubernetes-supply-chain-admission": "focused",
    "kubernetes-postgres-recovery": "focused",
    "kubernetes-air-gapped-ai-agent": "focused",
    # The same question as the sandbox, asked of a Cypress Cloud triage
    # agent: what it can do with a failed run's text as its input.
    "cypress-cloud-triage-agent": "focused",
    # One question on kind again: what evidence of the flagship's admission
    # controls an auditor can check without trusting the author.
    "kubernetes-oscal-evidence": "focused",
    # The sandbox's question once more, asked of the workspaces people and
    # agents share: Coder on kind, every workspace inside the sandbox's
    # boundary, and what a template edited to step outside is refused for.
    "kubernetes-coder-agent-workspaces": "focused",
    # The question every focused repository asks, put to all of them at once:
    # one set of planted instructions through each boundary's signed release,
    # on kind, with what got out read from the boundary's own side.
    "agent-security-benchmark": "focused",
    # Kubernetes on kind again, but the answer is a number: one way of
    # running a workload measured against another under the same load.
    "kubernetes-llm-inference-gateway": "measured",
    # No cluster and no cloud account of its own: it reads the flagship's
    # scheduled cloud runs from their signed records and turns each into
    # OSCAL evidence, so its proof is the runs it refuses, not a kind run.
    "cloud-evidence-pack": "evidence",
    "helm-charts": "helm",
}

SUFFIXES = (
    (re.compile(r"docker-compose$"), "compose"),
    (re.compile(r"-docker$"), "docker"),
    (re.compile(r"-terraform$"), "terraform"),
    (re.compile(r"^kubernetes-[a-z0-9-]+$"), "kubernetes"),
)

# The kinds fleet triage repairs on its own. A kind outside this set is still
# in the fleet (conformance judges it, the catalog lists it, lifecycle watches
# its versions), and fleet-heartbeat reports any red run of it as one with no
# triage report, so a failure there reaches a person instead of nobody.
TRIAGED = {"compose", "docker", "terraform"}

# The workflow that carries each kind's verdict.
WORKFLOW = {
    "compose": ("Deployment Verification", "deployment-verification.yml"),
    "docker": ("Deployment Verification", "deployment-verification.yml"),
    "terraform": ("Terraform Verification", "terraform-verification.yml"),
    "kubernetes": ("kind e2e", "kind-e2e.yml"),
    "focused": ("e2e", "e2e.yml"),
    "measured": ("E2E", "e2e.yml"),
    "evidence": ("Pack", "pack.yml"),
    "helm": ("Verification", "verification.yml"),
}


def kind_of(name):
    if name in NAMED:
        return NAMED[name]
    for pattern, kind in SUFFIXES:
        if pattern.search(name):
            return kind
    return None


def triaged(name):
    return kind_of(name) in TRIAGED


def kind_from_files(names):
    """What the top-level file listing says the repository is, or None."""
    names = set(names)
    if "Chart.yaml" in names or ("charts" in names and "ct.yaml" in names):
        return "helm"
    if {"platform", "kind"} <= names or ("kustomization.yaml" in names and "Makefile" in names):
        return "kubernetes"
    if {"kind", "manifests"} <= names:
        return "focused"
    # A focused repository that takes its kind cluster from another one's
    # release, vendored, and proves templates against it: the cluster's files
    # sit under vendor/, not kind/ (kubernetes-coder-agent-workspaces).
    if {"manifests", "vendor", "templates"} <= names:
        return "focused"
    if {"loadgen", "deploy"} <= names:
        return "measured"
    # Evidence read from another repository's runs: a mapping, the OSCAL it
    # builds and the lock of the system it reads, with no cluster of its own
    # (kubernetes-oscal-evidence has mapping/ and oscal/ too, and kind/ with
    # manifests/, so it is focused above).
    if {"mapping", "oscal", "tests", "flagship.lock"} <= names and "kind" not in names:
        return "evidence"
    if any(n.endswith((".yml", ".yaml")) and "compose" in n for n in names):
        return "compose"
    if any(n.endswith(".tf") for n in names):
        return "terraform"
    if "Dockerfile" in names:
        return "docker"
    return None


def main(argv):
    if argv[:1] == ["filter"]:
        only_triaged = "--triaged" in argv
        for line in sys.stdin:
            name = line.strip()
            kind = kind_of(name)
            if kind and (not only_triaged or kind in TRIAGED):
                print("%s\t%s" % (name, kind))
        return 0
    if len(argv) == 2 and argv[0] == "kind":
        kind = kind_of(argv[1])
        if not kind:
            return 1
        print(kind)
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
