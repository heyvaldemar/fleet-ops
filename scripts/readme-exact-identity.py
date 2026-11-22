#!/usr/bin/env python3
"""A README's "Verify what you deploy" section, moved to the exact signer.

    readme-exact-identity.py <README.md> <owner/repo>

Until 16 November 2026 the section told a reader to verify a release with
--certificate-identity-regexp '^https://github.com/<owner>/<repo>/', a
prefix that any workflow of the repository, on any branch, matches. This
rewrites the section in place to name release-assets.yml on the tag, puts
--source-tag <tag> into the slsa-verifier command, and says what a release
signed by a run started by hand on main needs instead.

Only the forms the rollout wrote are rewritten, each matched exactly; a
section edited by hand is left as it is for a person to read.

Exit 0: rewritten. 1: already exact, or no such section. 2: a section that
is not one of the known forms (nothing written).
"""
import io
import re
import sys

LEAD = ("The identity is exact: this repository's `release-assets.yml`, on the tag you deploy. "
        "A signature from any other workflow, or from this one on another ref, fails the check.")
# The three closing paragraphs the rollout has written, and what each becomes.
OLD_HAND = ("Add `--source-tag <tag>` for a release published after 24 September 2026, which is signed by "
            "the run that published it. The five releases before that date were signed by a run started by "
            "hand on `main`, so their provenance names the branch, not the tag; the archive is still the "
            "tag's tree, and the signature still belongs to this repository's workflow.")
NEW_HAND = (LEAD + " A release published after 24 September 2026 is signed by the run that published it, "
            "so the commands above take it as they are. The five releases before that date were signed by "
            "a run started by hand on `main`: for those, end the identity in `@refs/heads/main` and give "
            "slsa-verifier `--source-branch main` instead of `--source-tag <tag>`. The archive is still the "
            "tag's tree.")
OLD_EACH = "Each release was signed by the run that published it, so its provenance names the tag."
NEW_EACH = LEAD + " " + OLD_EACH
WORKFLOW = "The workflow that makes them is [`release-assets.yml`](.github/workflows/release-assets.yml)."


def main():
    path, full = sys.argv[1], sys.argv[2]
    s = io.open(path, encoding="utf-8").read()
    head = s.find("\n### Verify what you deploy\n")
    if head < 0:
        return 1
    m = re.search(r"\n(?:---\n\n)?#{2,3} ", s[head + 1:])
    end = head + 1 + m.start() if m else len(s)
    sec = s[head:end]
    exact = ("  --certificate-identity https://github.com/%s/.github/workflows/release-assets.yml@refs/tags/<tag> \\\n"
             % full)
    prefix = "  --certificate-identity-regexp '^https://github.com/%s/' \\\n" % full
    if exact in sec and prefix not in sec:
        return 1
    if sec.count(prefix) != 1:
        print("%s: the section names the signer in a form the rollout did not write; read it by hand" % path)
        return 2
    new = sec.replace(prefix, exact)
    uri = "  --source-uri github.com/%s\n```" % full
    # In the command itself: the old closing paragraph names the flag too.
    if "  --source-tag <tag>\n```" not in new:
        if new.count(uri) != 1:
            print("%s: the slsa-verifier command is not in a known form; read it by hand" % path)
            return 2
        new = new.replace(uri, "  --source-uri github.com/%s \\\n  --source-tag <tag>\n```" % full)
    tail = new.rsplit("```", 1)
    if OLD_HAND in tail[1]:
        tail[1] = tail[1].replace(OLD_HAND, NEW_HAND, 1)
    elif OLD_EACH in tail[1]:
        tail[1] = tail[1].replace(OLD_EACH, NEW_EACH, 1)
    elif tail[1].lstrip("\n").startswith(WORKFLOW):
        tail[1] = tail[1].replace(WORKFLOW, LEAD + " " + WORKFLOW, 1)
    else:
        print("%s: the paragraph after the commands is not one the rollout wrote; read it by hand" % path)
        return 2
    new = "```".join(tail)
    io.open(path, "w", encoding="utf-8").write(s[:head] + new + s[end:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
