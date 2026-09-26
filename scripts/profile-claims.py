#!/usr/bin/env python3
"""Is the shop window still telling the truth?

    profile-claims.py [--profile owner/repo] [--json claims.json]

The profile README carries a table naming two repositories and, for each, the
supply-chain surface it is supposed to demonstrate: Cosign keyless signing, an
SPDX SBOM, SLSA build provenance, Trivy SARIF, a digest-pinned base, a daily
freshness check. Those are the strongest claims anywhere in that profile, they
name specific repositories, and until now nothing re-read them.

Every other claim on that page is generated and therefore cannot drift: the
counts come from the API on the catalog's own schedule. This table is hand-written, and a
workflow losing its `sbom: true` or its cosign step would leave the profile
advertising something the repository no longer does - to exactly the audience
that would check.

So the table is the input. Each claim maps to evidence that must be present in
the repository it names; a claim with no rule here fails rather than passes,
because an unverifiable claim on a public profile is the thing this exists to
catch. Add the rule when you add the claim.
"""
import argparse
import json
import re
import subprocess
import sys

OWNER = "heyvaldemar"
ROW = re.compile(r"^\|\s*\[([^\]]+)\]\(https://github\.com/([^/]+)/([^)]+)\)\s*\|([^|]*)\|(.+)\|\s*$")


def gh_raw(path):
    try:
        return subprocess.check_output(
            ["gh", "api", path, "-H", "Accept: application/vnd.github.raw"],
            stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except subprocess.CalledProcessError:
        return ""


def gh_json(path):
    try:
        return json.loads(subprocess.check_output(["gh", "api", path], stderr=subprocess.DEVNULL))
    except subprocess.CalledProcessError:
        return None


def workflows(repo):
    """Every workflow file in one string, plus the list of their names."""
    listing = gh_json("repos/%s/%s/contents/.github/workflows" % (OWNER, repo)) or []
    names = [f["name"] for f in listing if f["name"].endswith((".yml", ".yaml"))]
    body = "\n".join(gh_raw("repos/%s/%s/contents/.github/workflows/%s" % (OWNER, repo, n)) for n in names)
    return names, body


def dockerfile(repo):
    return gh_raw("repos/%s/%s/contents/Dockerfile" % (OWNER, repo))


def compose(repo):
    listing = gh_json("repos/%s/%s/contents" % (OWNER, repo)) or []
    for f in listing:
        if f["name"].endswith(("docker-compose.yml", "docker-compose.yaml")):
            return gh_raw("repos/%s/%s/contents/%s" % (OWNER, repo, f["name"]))
    return ""


def readme(repo):
    return gh_raw("repos/%s/%s/contents/README.md" % (OWNER, repo)) or ""


# claim text (lowercased, matched as a substring) -> what has to be true.
# Each rule says where it looked, so a failure names the file to open.
RULES = [
    ("cosign keyless signing", lambda r, w, b, d, c:
        ("sigstore/cosign-installer" in b and "cosign sign" in b, "workflows: cosign-installer + `cosign sign`")),
    ("sbom", lambda r, w, b, d, c:
        (re.search(r"sbom:\s*true|syft|spdx", b, re.I) is not None, "workflows: `sbom: true`, syft or spdx")),
    ("slsa build provenance", lambda r, w, b, d, c:
        (re.search(r"provenance:\s*mode=|attest-build-provenance|slsa-github-generator", b) is not None,
         "workflows: `provenance: mode=`, actions/attest-build-provenance or the SLSA generator")),
    ("keyless-signed releases", lambda r, w, b, d, c:
        ("release-assets.yml" in w and "cosign sign-blob" in b, ".github/workflows/release-assets.yml: `cosign sign-blob`")),
    ("trivy", lambda r, w, b, d, c:
        (re.search(r"trivy", b, re.I) is not None and re.search(r"sarif", b, re.I) is not None,
         "workflows: trivy with a SARIF upload")),
    ("digest-pinned base", lambda r, w, b, d, c:
        (re.search(r"^FROM\s+\S+@sha256:[0-9a-f]{64}", d, re.M) is not None, "Dockerfile: FROM ...@sha256:")),
    ("digest-pinned upstream images", lambda r, w, b, d, c:
        ("@sha256:" in c, "the compose file: image pins carrying @sha256:")),
    ("openssf scorecard", lambda r, w, b, d, c:
        ("scorecard.yml" in w or "scorecard.yaml" in w, ".github/workflows/scorecard.yml")),
    ("openssf best practices", lambda r, w, b, d, c:
        (re.search(r"bestpractices\.dev/projects/\d+/badge", readme(r)) is not None,
         "README.md: the bestpractices.dev badge with a project number")),
    ("daily freshness check", lambda r, w, b, d, c:
        (re.search(r"(freshness|drift)", b, re.I) is not None and re.search(r"cron:\s*['\"]?[0-9*]+ [0-9*]+ \* \* \*", b) is not None,
         "workflows: a freshness/drift job on a daily cron")),
    ("daily ci deployment smoke", lambda r, w, b, d, c:
        ("deployment-verification.yml" in w and re.search(r"cron:\s*['\"]?[0-9*]+ [0-9*]+ \* \* \*", b) is not None,
         "deployment-verification.yml on a daily cron")),
    ("lint", lambda r, w, b, d, c:
        (re.search(r"actionlint|shellcheck|hadolint|yamllint", b, re.I) is not None, "workflows: a linter")),
]


def check(repo, claim):
    names, body = workflows(repo)
    if not names:
        return False, "no workflows could be read at all"
    low = claim.lower()
    for key, rule in RULES:
        if key in low:
            ok, where = rule(repo, names, body, dockerfile(repo), compose(repo))
            return ok, where
    return None, "no rule for this claim"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", default="%s/%s" % (OWNER, OWNER))
    ap.add_argument("--json", dest="js")
    a = ap.parse_args()

    readme = gh_raw("repos/%s/contents/README.md" % a.profile)
    if not readme:
        sys.exit("could not read the profile README at %s — this check cannot pass by failing to look" % a.profile)

    rows = [m for m in (ROW.match(l) for l in readme.splitlines()) if m]
    if not rows:
        sys.exit("no reference-implementation rows found in the profile README — either the table moved or this parser is wrong; either way it is not proof of anything")

    findings, checked = [], 0
    for m in rows:
        _, owner, repo, _shape, surface = m.groups()
        repo = repo.strip()
        for claim in [c.strip() for c in surface.split("·") if c.strip()]:
            ok, where = check(repo, claim)
            checked += 1
            if ok is None:
                findings.append("%s: the profile claims \"%s\" and there is no rule that checks it — add one to scripts/profile-claims.py" % (repo, claim))
            elif not ok:
                findings.append("%s: the profile claims \"%s\" and the repository no longer shows it (looked at %s)" % (repo, claim, where))
            else:
                print("  ok   %-46s %s" % (repo[:46], claim))
    print()
    if a.js:
        open(a.js, "w", encoding="utf-8").write(json.dumps(dict(profile=a.profile, claims=checked, findings=findings), indent=2) + "\n")
    if not checked:
        sys.exit("the table was found and no claim was read out of it — that is this check being broken, not the fleet being clean")
    for f in findings:
        print("::error::%s" % f)
    print("%d claims read from the profile, %d no longer true" % (checked, len(findings)))
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
