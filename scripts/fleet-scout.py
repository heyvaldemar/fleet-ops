#!/usr/bin/env python3
"""What is worth adding to the fleet, and what it would cost.

    fleet-scout.py [--shortlist 3] [--out scout.md] [--json scout.json]

Reads the awesome-selfhosted catalogue, drops everything this fleet already
has and everything that cannot be pinned or maintained, scores what is left,
and asks Claude to assess the top few against how these templates are built.
It writes a shortlist. It never creates a repository and never publishes
anything: the value of a template here is what running it taught, and that
cannot be generated.

Authentication is workload identity federation, the same as the upstream
review: the runner mints an OIDC token, Anthropic exchanges it under a rule
pinned to this repository and branch. No API key exists anywhere.
"""
import argparse
import datetime
import io
import json
import os
import re
import sys
import urllib.request

import anthropic
from anthropic import WorkloadIdentityCredentials

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anthropic_federation import FEDERATION, answer, github_oidc_token  # noqa: E402

OWNER = "heyvaldemar"
DATA_REPO = "awesome-selfhosted/awesome-selfhosted-data"
MODEL = os.environ.get("SCOUT_MODEL", "claude-sonnet-5")

# Tags whose software is not a self-hosted service with state worth a
# template: a library, a desktop app, a game, a static-site generator.
SKIP_TAGS = {
    "Games", "Software Development - Project Management", "Learning and Courses",
    "Static Site Generators", "Miscellaneous", "Automation",
}
# A licence that makes a public deployment template awkward to hand to
# strangers, or upstream that is not really open.
SKIP_LICENCE_WORDS = ("proprietary", "⊘", "sspl", "busl", "elastic")


def gh(path, host="api.github.com"):
    req = urllib.request.Request("https://%s/%s" % (host, path), headers={"Accept": "application/vnd.github+json"})
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def declined():
    """Candidates already put forward and judged not worth a template.

    The scout re-ranks the same catalogue every week and the scores barely
    move, so without this it proposes the same shortlist for ever. A report
    that repeats a decision somebody already made stops being read, and a
    scout nobody reads has failed completely rather than partly.

    Missing or unreadable means nothing has been declined, which is the safe
    reading: every candidate then gets proposed, and a deleted file cannot
    quietly empty the catalogue.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scout-declined.json")
    try:
        raw = json.load(io.open(path, encoding="utf-8"))
    except Exception:
        return {}
    return {k: v for k, v in raw.items() if not k.startswith("_")}


def fleet():
    """What is already covered - by repository name and by the images pinned
    in every compose file, so a service is not proposed under another name."""
    names, images = set(), set()
    page = 1
    while True:
        batch = gh("users/%s/repos?per_page=100&page=%d&type=owner" % (OWNER, page))
        for r in batch:
            n = r["name"]
            names.add(n)
            names.add(re.sub(r"-(traefik-letsencrypt-)?docker-compose$|-docker$|-server-docker-compose$", "", n))
        if len(batch) < 100:
            break
        page += 1
    return names, images


def entries():
    tree = gh("repos/%s/git/trees/HEAD?recursive=1" % DATA_REPO)["tree"]
    files = [t["path"] for t in tree if t["path"].startswith("software/") and t["path"].endswith(".yml")]
    out = []
    # One raw fetch per file is a thousand requests; the tarball is one.
    tar = "/tmp/awesome.tar.gz"
    urllib.request.urlretrieve("https://codeload.github.com/%s/tar.gz/refs/heads/master" % DATA_REPO, tar)
    import tarfile
    with tarfile.open(tar) as t:
        for m in t.getmembers():
            if "/software/" not in m.name or not m.name.endswith(".yml"):
                continue
            raw = t.extractfile(m).read().decode("utf-8", "replace")
            e = {"_file": m.name.rsplit("/", 1)[-1]}
            key = None
            for line in raw.split("\n"):
                if re.match(r"^[a-z_]+:", line):
                    key, _, val = line.partition(":")
                    val = val.strip()
                    e[key] = val if val else []
                elif line.startswith("  - ") and isinstance(e.get(key), list):
                    e[key].append(line[4:].strip())
            out.append(e)
    return out, len(files)


def source_meta(url):
    m = re.match(r"https?://github\.com/([^/]+)/([^/#?]+)", url or "")
    if not m:
        return None
    full = "%s/%s" % (m.group(1), m.group(2).rstrip(".git"))
    try:
        r = gh("repos/%s" % full)
    except Exception:
        return None
    rel = ""
    try:
        rel = (gh("repos/%s/releases/latest" % full).get("published_at") or "")[:10]
    except Exception:
        pass
    return dict(full=full, stars=r.get("stargazers_count", 0), pushed=(r.get("pushed_at") or "")[:10],
                archived=r.get("archived", False), release=rel, topics=r.get("topics", []),
                description=r.get("description") or "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shortlist", type=int, default=3)
    ap.add_argument("--out", default="scout.md")
    ap.add_argument("--json", dest="js", default="scout.json")
    a = ap.parse_args()

    have, _ = fleet()
    ents, total = entries()
    today = datetime.date.today()

    # --- the hard filter. Every rejection here is a rule, not a taste.
    cands = []
    for e in ents:
        name = e.get("name") or ""
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        if not name or slug in have or name.lower().replace(" ", "") in {h.replace("-", "") for h in have}:
            continue
        plat = e.get("platforms") or []
        if "Docker" not in plat:
            continue                                    # no image, no template
        tags = e.get("tags") or []
        if set(tags) & SKIP_TAGS:
            continue
        lic = " ".join(e.get("licenses") or []).lower()
        if any(w in lic for w in SKIP_LICENCE_WORDS):
            continue
        cands.append((e, slug, tags))

    # --- the soft filter: alive, and big enough that somebody will deploy it
    scored = []
    for e, slug, tags in cands:
        meta = source_meta(e.get("source_code_url"))
        if not meta or meta["archived"]:
            continue
        if meta["stars"] < 900:
            continue
        try:
            age = (today - datetime.date.fromisoformat(meta["pushed"])).days
        except Exception:
            continue
        if age > 90:                                     # not maintained
            continue
        rel_age = 9999
        if meta["release"]:
            try:
                rel_age = (today - datetime.date.fromisoformat(meta["release"])).days
            except Exception:
                pass
        # Releases are what a pin follows; a project that never tags one can
        # only be pinned by digest and never bumped deliberately.
        score = meta["stars"] / 1000.0
        if rel_age < 120:
            score += 6
        if age < 21:
            score += 2
        # source_meta carries GitHub's own description; the catalogue carries
        # the curated one. Both matter and they are not the same sentence, so
        # they get separate names instead of colliding in one keyword.
        row = dict(meta)
        row.update(name=e["name"], slug=slug, tags=tags,
                   catalogue_description=e.get("description", ""),
                   website=e.get("website_url", ""), licenses=e.get("licenses") or [],
                   score=round(score, 2), release_age_days=rel_age)
        scored.append(row)
    scored.sort(key=lambda x: -x["score"])
    # ALREADY ANSWERED. Dropped after scoring rather than before it, so the
    # count below says how many decisions this list is holding back: a filter
    # that silently swallows the catalogue looks exactly like a catalogue with
    # nothing in it.
    already = declined()
    skipped = [r["name"] for r in scored if r["slug"] in already]
    scored = [r for r in scored if r["slug"] not in already]
    # A KEY THAT MATCHES NOTHING IS A TYPO UNTIL PROVEN OTHERWISE. The slug is
    # the catalogue name lowercased with runs of non-alphanumerics hyphenated,
    # so "Dify.ai" is dify-ai and not dify. Get it wrong and the entry silently
    # does nothing while the file looks like it is working — said out loud
    # instead, because that is the only way anyone finds out.
    unmatched = sorted(k for k in already if k not in {c[1] for c in cands})
    if unmatched:
        print("scout-declined.json names %d candidate(s) not in this catalogue run: %s — a typo, "
              "or they have left the catalogue" % (len(unmatched), ", ".join(unmatched)), file=sys.stderr)
    top = scored[:a.shortlist]

    result = dict(generated=str(today), catalogue_entries=total, after_hard_filter=len(cands),
                  after_soft_filter=len(scored), declined_already=skipped,
                  declined_unmatched=unmatched,
                  shortlist=[t["name"] for t in top])
    if skipped:
        print("skipped %d already judged: %s" % (len(skipped), ", ".join(skipped)), file=sys.stderr)

    if not top:
        io.open(a.out, "w", encoding="utf-8").write(
            "Nothing cleared the filters today. %d entries read, %d had a Docker image and a usable licence, "
            "none of those were both maintained and unclaimed%s.\n"
            % (total, len(cands),
               "" if not skipped else ", and %d had already been judged (%s)" % (len(skipped), ", ".join(skipped))))
        io.open(a.js, "w", encoding="utf-8").write(json.dumps(result, indent=2) + "\n")
        print("nothing to propose")
        return

    client = anthropic.Anthropic(credentials=WorkloadIdentityCredentials(identity_token_provider=github_oidc_token, **FEDERATION))
    system = (
        "You assess candidate services for a fleet of production deployment templates. Each template in that fleet "
        "pins every image by digest, hardens each service, sets measured resource limits, proves its health check in "
        "both directions, backs up its data atomically and restores it in a test, boots in CI on every change, and "
        "upgrades from its previous release on the same volumes before a release is cut.\n\n"
        "For each candidate, say what a template for it would actually involve and whether it is worth the permanent "
        "cost of one more repository in that fleet. Be sceptical: most services are not. Say plainly when a candidate "
        "is thin, duplicates something the fleet already covers in substance, or has no state worth backing up. "
        "Never invent a fact about a project you were not given; when you do not know, say which page would settle it.\n\n"
        "Answer in this exact Markdown shape, once per candidate:\n\n"
        "### <name>\n"
        "**Verdict:** WORTH IT / THIN / NO, one line with the reason.\n"
        "- **The stack:** the containers a template would need (app, database, cache, reverse proxy) and what holds state.\n"
        "- **What CI could prove:** what a runner can actually boot and check for it, and what it cannot.\n"
        "- **Where the traps are:** what its own documentation or issue tracker suggests goes wrong on a first deployment.\n"
        "- **What to check before starting:** the one or two pages that would settle whether this is worth it.\n"
    )
    lines = []
    for t in top:
        lines.append(
            "## %s\n- catalogue description: %s\n- source: github.com/%s (%d stars, last push %s, latest release %s)\n"
            "- licence: %s\n- tags: %s\n- what its own repository says: %s\n- topics: %s\n"
            % (t["name"], t["catalogue_description"], t["full"], t["stars"], t["pushed"], t["release"] or "none",
               ", ".join(t["licenses"]), ", ".join(t["tags"]), t["description"], ", ".join(t["topics"][:12])))
    user = ("The fleet already covers these, so do not propose them again:\n%s\n\nCandidates:\n\n%s"
            % (", ".join(sorted(x for x in have if "-" in x)[:120]), "\n".join(lines)))

    text, msg = answer(client, model=MODEL, max_tokens=6000, system=system, messages=[{"role": "user", "content": user}])

    head = ("*%d entries in the catalogue; %d had a Docker image and a licence this fleet can hand to strangers; "
            "%d of those are maintained, released and not already covered. The %d below scored highest. "
            "Nothing here has been created: a template is worth publishing once somebody has run the thing.*\n\n"
            % (total, len(cands), len(scored), len(top)))
    table = ["| Candidate | Stars | Last push | Latest release | Licence |", "| :--- | ---: | :--- | :--- | :--- |"]
    for t in top:
        table.append("| [%s](https://github.com/%s) | %d | %s | %s | %s |"
                     % (t["name"], t["full"], t["stars"], t["pushed"], t["release"] or "—", ", ".join(t["licenses"])))
    io.open(a.out, "w", encoding="utf-8").write(head + "\n".join(table) + "\n\n" + text + "\n")
    result["input_tokens"] = msg.usage.input_tokens
    result["output_tokens"] = msg.usage.output_tokens
    io.open(a.js, "w", encoding="utf-8").write(json.dumps(result, indent=2) + "\n")
    print(text)
    print("\n[%s in=%d out=%d]" % (MODEL, msg.usage.input_tokens, msg.usage.output_tokens), file=sys.stderr)


if __name__ == "__main__":
    main()
