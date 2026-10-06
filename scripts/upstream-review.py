#!/usr/bin/env python3
"""Read what upstream changed between two image versions, against our compose
file, and say what a deployed host has to know before it moves.

    upstream-review.py --repo <template-repo> --image <ref> --from <v> --to <v> \
        [--source owner/name] [--out review.md] [--json review.json]

The model sees three things: the upstream release notes between the two
versions (GitHub releases of the source repository), the template's compose
file, and its .env.example. It is asked for facts a test cannot find: renamed
or newly required variables, database version requirements, removed defaults,
migration steps that are not automatic. It answers in a fixed shape so the
result can be appended to release notes and to the triage report unchanged.

Authentication is workload identity federation: the GitHub runner mints an
OIDC token for this job, Anthropic exchanges it for a short-lived credential
under the federation rule. No long-lived key exists anywhere.
"""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import sys
import urllib.parse
import urllib.request

import anthropic
from anthropic import WorkloadIdentityCredentials

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# THE REASON THIS LINE EXISTS. answer() was pulled out into the shared module
# so the three callers could not disagree about how a Claude call is made. The
# scout and the lab sweep were given the import; this file was not, and its
# call site was rewritten to use it anyway. Python resolves names at run time,
# so the file still compiled, still linted, and raised NameError only when a
# bump actually had an upstream release to review. Every upstream review since
# has failed and the report said so on every line: "the bump proceeds on the CI
# gate alone". The federation ids and the token minter were duplicated here
# too, and are now gone for the same reason the shared module exists.
from anthropic_federation import FEDERATION, answer, github_oidc_token  # noqa: E402

MODEL = os.environ.get("REVIEW_MODEL", "claude-sonnet-5")

# Publishers that do not put release notes on GitHub at all. Saying so is a
# different answer from "could not retrieve them", and the reviewer must not
# spend a verdict on a lookup that was never going to succeed.
NO_NOTES = {
    "atlassian/confluence": "Atlassian publishes release notes on its own site, not on GitHub",
    "atlassian/bitbucket": "Atlassian publishes release notes on its own site, not on GitHub",
    "atlassian/jira": "Atlassian publishes release notes on its own site, not on GitHub",
    "atlassian/jira-software": "Atlassian publishes release notes on its own site, not on GitHub",
    "mcr.microsoft.com/mssql/server": "Microsoft publishes SQL Server release notes in its own documentation, not on GitHub",
    "gitlab/gitlab-runner": "GitLab Runner is developed on gitlab.com, not on GitHub",
    "codeberg.org/forgejo/forgejo": "Forgejo is developed on Codeberg, not on GitHub",
    # Moved here on 2026-10-03 from SOURCES, where each pointed at a packaging
    # repository with no version tags: the review read nothing under it and
    # reported a lookup failure instead of where the notes actually live.
    "postgres": "PostgreSQL publishes release notes at postgresql.org; docker-library/postgres is the packaging and tags no versions",
    "wordpress": "WordPress publishes release notes on wordpress.org; docker-library/wordpress is the packaging and tags no versions",
    "xwiki": "XWiki publishes release notes on xwiki.org; xwiki/xwiki-docker is the packaging and tags no versions",
    "danixu86/project-zomboid-dedicated-server": "The game's notes are The Indie Stone's; the packaging repository tags no versions at all",
}

# Images whose GitHub source is not <owner>/<name> of the image reference.
SOURCES = {
    # Added 2026-09-20. A third of the images this fleet pins resolved to a
    # repository that does not exist, and every one of those reviews came back
    # "the release notes could not be retrieved" — a verdict about the lookup
    # wearing the clothes of a verdict about the upgrade. beszel is how it was
    # found: the agent ships from the hub's repository, and henrygd/beszel-agent
    # is not a repository at all.
    #
    # Each of these was accepted only after the version this fleet has pinned
    # was found as a tag in the repository named. A mapping that points at the
    # wrong project is worse than none: it produces confident notes about
    # somebody else's software.
    "henrygd/beszel-agent": "henrygd/beszel",
    "ghcr.io/advplyr/audiobookshelf": "advplyr/audiobookshelf",
    "ghcr.io/crazy-max/diun": "crazy-max/diun",
    "ghcr.io/gethomepage/homepage": "gethomepage/homepage",
    "ghcr.io/tecnativa/docker-socket-proxy": "tecnativa/docker-socket-proxy",
    "zabbix/zabbix-agent2": "zabbix/zabbix",
    "zabbix/zabbix-web-nginx-pgsql": "zabbix/zabbix",
    "elestio/glpi": "glpi-project/glpi",
    "owncloud/server": "owncloud/core",
    "gitlab/gitlab-ee": "gitlabhq/gitlabhq",
    "traefik": "traefik/traefik",
    "mariadb": "MariaDB/server",
    "redis": "redis/redis",
    "valkey/valkey": "valkey-io/valkey",
    "lissy93/dashy": "Lissy93/dashy",
    "b3log/siyuan": "siyuan-note/siyuan",
    "itzg/minecraft-server": "itzg/docker-minecraft-server",
    "itzg/mc-backup": "itzg/docker-mc-backup",
    "itzg/mc-proxy": "itzg/docker-mc-proxy",
    "joedwards32/cs2": "joedwards32/CS2",
    "vaultwarden/server": "dani-garcia/vaultwarden",
    "gitea/gitea": "go-gitea/gitea",
    "grafana/grafana": "grafana/grafana",
    "portainer/portainer-ce": "portainer/portainer",
    "nextcloud": "nextcloud/server",
    "ghost": "TryGhost/Ghost",
    "homeassistant/home-assistant": "home-assistant/core",
    "vaultwarden": "dani-garcia/vaultwarden",
    "ollama/ollama": "ollama/ollama",
    "requarks/wiki": "requarks/wiki",
    "docmost/docmost": "docmost/docmost",
    "zabbix/zabbix-server-pgsql": "zabbix/zabbix-docker",
    "mattermost/mattermost-team-edition": "mattermost/mattermost",
    "rocketchat/rocket.chat": "RocketChat/Rocket.Chat",
    "sonarqube": "SonarSource/sonarqube",
    "keycloak/keycloak": "keycloak/keycloak",
    "quay.io/keycloak/keycloak": "keycloak/keycloak",
    "outlinewiki/outline": "outline/outline",
    "authelia/authelia": "authelia/authelia",
    "glpi/glpi": "glpi-project/glpi",
    # Images whose notes live somewhere the name does not say. Without an
    # entry here the fallback treats "owner/name" on Docker Hub as a GitHub
    # repository of the same name, which 404s for every image published from a
    # monorepo or under a different account - and the review then says it could
    # not read the notes, which triage records and lands the bump anyway. That
    # was 26 of the fleet's 89 pinned images.
    "langgenius/dify-api": "langgenius/dify",
    "langgenius/dify-web": "langgenius/dify",
    "langgenius/dify-agent-backend": "langgenius/dify",
    "langgenius/dify-agent-local-sandbox": "langgenius/dify",
    "langgenius/dify-sandbox": "langgenius/dify-sandbox",
    "langgenius/dify-plugin-daemon": "langgenius/dify-plugin-daemon",
    "ghcr.io/immich-app/immich-server": "immich-app/immich",
    "ghcr.io/immich-app/immich-machine-learning": "immich-app/immich",
    "semitechnologies/weaviate": "weaviate/weaviate",
    "ghcr.io/mailu/admin": "Mailu/Mailu",
    "ghcr.io/mailu/dovecot": "Mailu/Mailu",
    "ghcr.io/mailu/fetchmail": "Mailu/Mailu",
    "ghcr.io/mailu/nginx": "Mailu/Mailu",
    "ghcr.io/mailu/oletools": "Mailu/Mailu",
    "ghcr.io/mailu/postfix": "Mailu/Mailu",
    "ghcr.io/mailu/radicale": "Mailu/Mailu",
    "ghcr.io/mailu/rspamd": "Mailu/Mailu",
    "ghcr.io/mailu/unbound": "Mailu/Mailu",
    "ghcr.io/mailu/webmail": "Mailu/Mailu",
    "ghcr.io/open-webui/open-webui": "open-webui/open-webui",
    "ghcr.io/sysadminsmedia/homebox": "sysadminsmedia/homebox",
    "ghcr.io/toeverything/affine": "toeverything/AFFiNE",
    "ghcr.io/zammad/zammad": "zammad/zammad",
    "elasticsearch": "elastic/elasticsearch",
    "joomla": "joomla/joomla-cms",
    "rabbitmq": "rabbitmq/rabbitmq-server",
}

# The version at which each SOURCES mapping was proven: the repository exists
# under exactly that name and carries this tag (scripts/verify-mapping.sh).
# tests/test-review-sources.sh proves every one again on every run, so a
# repository that is renamed, emptied or retagged fails there and not in a
# review. Taken from the fleet's pins on 2026-10-03; a line pin (3.7, 9) is
# proven by the newest tag in that line, a floating tag by the latest release.
PROVEN_AT = {
    "henrygd/beszel-agent": "0.21.0",
    "ghcr.io/advplyr/audiobookshelf": "2.37.1",
    "ghcr.io/crazy-max/diun": "4.33.0",
    "ghcr.io/gethomepage/homepage": "v2.4.0",
    "ghcr.io/tecnativa/docker-socket-proxy": "v0.5.0",
    "zabbix/zabbix-agent2": "7.0.31",
    "zabbix/zabbix-web-nginx-pgsql": "7.0.31",
    "elestio/glpi": "11.0.8",
    "owncloud/server": "11.0.1",
    "gitlab/gitlab-ee": "19.4.1",
    "traefik": "3.7.13",
    "mariadb": "mariadb-11.8.3",
    "redis": "7.4.11",
    "valkey/valkey": "9.1.2",
    "lissy93/dashy": "4.7.17",
    "b3log/siyuan": "v3.8.6",
    "itzg/minecraft-server": "2026.9.2",
    "itzg/mc-backup": "2026.9.3",
    "itzg/mc-proxy": "2026.10.0",
    "joedwards32/cs2": "5.0.0",
    "vaultwarden/server": "1.37.3",
    "gitea/gitea": "28.0.0",
    "grafana/grafana": "13.2.3",
    "portainer/portainer-ce": "2.45.1",
    "nextcloud": "35.0.1",
    "ghost": "6.67.0",
    "homeassistant/home-assistant": "2026.9.4",
    "vaultwarden": "1.37.3",
    "ollama/ollama": "0.35.1",
    "requarks/wiki": "2.5.315",
    "docmost/docmost": "0.96.0",
    "zabbix/zabbix-server-pgsql": "7.0.31",
    "mattermost/mattermost-team-edition": "11.11.1",
    "rocketchat/rocket.chat": "8.8.1",
    "sonarqube": "26.9.0.129388",
    "keycloak/keycloak": "26.8.0",
    "quay.io/keycloak/keycloak": "26.8.0",
    "outlinewiki/outline": "1.10.1",
    "authelia/authelia": "4.39.28",
    "glpi/glpi": "11.0.8",
    "langgenius/dify-api": "1.17.1",
    "langgenius/dify-web": "1.17.1",
    "langgenius/dify-agent-backend": "1.17.1",
    "langgenius/dify-agent-local-sandbox": "1.17.1",
    "langgenius/dify-sandbox": "0.2.15",
    "langgenius/dify-plugin-daemon": "0.6.10",
    "ghcr.io/immich-app/immich-server": "v3.2.4",
    "ghcr.io/immich-app/immich-machine-learning": "v3.2.4",
    "semitechnologies/weaviate": "1.27.0",
    "ghcr.io/mailu/admin": "2024.06.61",
    "ghcr.io/mailu/dovecot": "2024.06.61",
    "ghcr.io/mailu/fetchmail": "2024.06.61",
    "ghcr.io/mailu/nginx": "2024.06.61",
    "ghcr.io/mailu/oletools": "2024.06.61",
    "ghcr.io/mailu/postfix": "2024.06.61",
    "ghcr.io/mailu/radicale": "2024.06.61",
    "ghcr.io/mailu/rspamd": "2024.06.61",
    "ghcr.io/mailu/unbound": "2024.06.61",
    "ghcr.io/mailu/webmail": "2024.06.61",
    "ghcr.io/open-webui/open-webui": "0.11.4",
    "ghcr.io/sysadminsmedia/homebox": "0.26.2",
    "ghcr.io/toeverything/affine": "0.27.4",
    "ghcr.io/zammad/zammad": "7.2.0",
    "elasticsearch": "8.19.20",
    "joomla": "6.1.4",
    "rabbitmq": "4.3.6",
}


# --- what the images themselves say, which is not what the notes say ---------
#
# A release note is a sentence somebody wrote. The image is the thing that will
# run. On 2026-09-22 dashy's notes said "Use UID/GID=1000 instead of node as
# default" and the review called it NEEDS ATTENTION, correctly from notes alone:
# a bind-mounted file and a changed container user is how an upgrade breaks
# quietly. The images disagreed: 4.7.5 declares User=node and 4.7.7 declares
# User=1000:1000, and both resolve to uid 1000, gid 1000. A rename.
#
# So the review now gets the two image configurations as the registry reports
# them, without pulling anything. A field that differs is a fact; a field that
# does not is the answer to the question the note raised.
REGISTRY_FIELDS = ("User", "Entrypoint", "Cmd", "WorkingDir", "ExposedPorts", "Volumes", "Healthcheck")
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def _split_ref(image):
    """(registry host, repository path) for an image reference without a tag."""
    first = image.split("/")[0]
    if "." in first or ":" in first or first == "localhost":
        return first, image.split("/", 1)[1]
    return "registry-1.docker.io", image if "/" in image else "library/" + image


def _token(host, repo):
    urls = {
        "registry-1.docker.io": "https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull",
        "ghcr.io": "https://ghcr.io/token?service=ghcr.io&scope=repository:%s:pull",
        "quay.io": "https://quay.io/v2/auth?service=quay.io&scope=repository:%s:pull",
        "lscr.io": "https://ghcr.io/token?service=ghcr.io&scope=repository:%s:pull",
    }
    if host not in urls:
        raise RuntimeError("no anonymous token endpoint known for %s" % host)
    with urllib.request.urlopen(urls[host] % repo, timeout=20) as r:
        return json.load(r).get("token") or json.load(r).get("access_token")


def _get(host, repo, kind, ref, token, raw=False):
    url = "https://%s/v2/%s/%s/%s" % ("ghcr.io" if host == "lscr.io" else host, repo, kind, ref)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read() if raw else json.load(r)


def image_config(image, tag):
    """The config of an image's linux/amd64 variant, straight from the registry."""
    host, repo = _split_ref(image)
    token = _token(host, repo)
    man = _get(host, repo, "manifests", tag, token)
    if "manifests" in man:                      # an index: pick the platform
        pick = next((m for m in man["manifests"]
                     if (m.get("platform") or {}).get("architecture") == "amd64"
                     and (m.get("platform") or {}).get("os") == "linux"), None)
        if not pick:
            raise RuntimeError("no linux/amd64 manifest in the index")
        man = _get(host, repo, "manifests", pick["digest"], token)
    digest = (man.get("config") or {}).get("digest")
    if not digest:
        raise RuntimeError("manifest carries no config digest")
    return json.loads(_get(host, repo, "blobs", digest, token, raw=True)).get("config") or {}


def _env_map(cfg):
    out = {}
    for e in cfg.get("Env") or []:
        k, _, v = e.partition("=")
        out[k] = v
    return out


def image_diff(image, frm, to):
    """What changed between two tags of one image, as the registry reports it."""
    try:
        a, b = image_config(image, frm), image_config(image, to)
    except Exception as e:
        # AN UNREADABLE REGISTRY IS NOT AN IMAGE THAT DID NOT CHANGE. Saying
        # which of the two this is costs one sentence and is the whole value.
        return ("The image configurations could not be read from the registry (%s: %s). "
                "Nothing below is measured; judge on the notes alone and say so."
                % (e.__class__.__name__, e))
    return diff_configs(a, b)


def diff_configs(a, b):
    """The same comparison over two configurations already in hand."""
    lines = []
    for f in REGISTRY_FIELDS:
        if a.get(f) != b.get(f):
            lines.append("- `%s`: %r -> %r" % (f, a.get(f), b.get(f)))
    ea, eb = _env_map(a), _env_map(b)
    for k in sorted(set(eb) - set(ea)):
        lines.append("- env `%s` added, default %r" % (k, eb[k][:80]))
    for k in sorted(set(ea) - set(eb)):
        lines.append("- env `%s` removed (was %r)" % (k, ea[k][:80]))
    for k in sorted(set(ea) & set(eb)):
        if ea[k] != eb[k]:
            lines.append("- env `%s`: %r -> %r" % (k, ea[k][:60], eb[k][:60]))
    if not lines:
        return ("The two image configurations are identical in every field that changes behaviour: "
                "%s, and the environment. Whatever the notes say about those, the images do not differ."
                % ", ".join("`%s`" % f for f in REGISTRY_FIELDS))
    return "The registry reports these differences between the two images:\n" + "\n".join(lines)


def gh(path):
    req = urllib.request.Request("https://api.github.com/" + path, headers={"Accept": "application/vnd.github+json"})
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def normalise(v):
    return re.sub(r"^v", "", v.split("@")[0])


# Release notes are what a project chooses to announce. The breaking change is
# often somewhere else: an UPGRADING.md, a BREAKING_CHANGES.md, or the top of a
# CHANGELOG that carries more than the release page does. Only four of twelve
# upstreams this fleet tracks keep such a file, so this is an addition to the
# notes and never a replacement for them - and it is read at the version being
# moved TO, because that is the copy describing the move.
UPGRADE_FILES = ("UPGRADING.md", "UPGRADE.md", "MIGRATION.md", "BREAKING_CHANGES.md", "CHANGELOG.md")


def upgrade_doc(source, to, limit=30000):
    """The upgrade file the project keeps in its repository, if it keeps one."""
    for ref in (to, "v" + normalise(to), normalise(to), None):
        for name in UPGRADE_FILES:
            path = "repos/%s/contents/%s" % (source, urllib.parse.quote(name))
            if ref:
                path += "?ref=" + urllib.parse.quote(ref, safe="")
            try:
                meta = gh(path)
            except Exception:
                continue
            if not isinstance(meta, dict) or meta.get("encoding") != "base64":
                continue
            try:
                body = base64.b64decode(meta.get("content", "")).decode("utf-8", "replace")
            except Exception:
                continue
            if not body.strip():
                continue
            # The newest entries are at the top of every one of these files.
            return name, body[:limit], len(body)
    return None, None, 0



def release_notes(source, frm, to, limit=60):
    """Every release strictly after `frm` up to and including `to`, newest
    first as GitHub lists them. Tags are matched loosely: v1.2.3, 1.2.3 and
    release-1.2.3 all count as 1.2.3."""
    rels = []
    try:
        # Three pages: a project that releases weekly has a year of history
        # in three hundred entries, and the pin can be that old.
        for page in (1, 2, 3):
            batch = gh("repos/%s/releases?per_page=100&page=%d" % (source, page))
            rels += batch
            if len(batch) < 100:
                break
    except Exception as e:
        if not rels:
            return None, "GitHub releases for %s could not be read: %s" % (source, e)
    out = []
    frm_n, to_n = normalise(frm), normalise(to)
    inside = False
    for r in rels:
        tag = normalise(re.sub(r"^(release-|v)", "", r.get("tag_name", "")))
        if tag == to_n:
            inside = True
        if inside:
            if tag == frm_n:
                break
            out.append("### %s (%s)\n%s" % (r.get("tag_name"), (r.get("published_at") or "")[:10], (r.get("body") or "").strip()))
    if not out:
        # Many projects publish a GitHub release for a minor and only a tag
        # for each patch (Dashy: releases for 4.6.0, tags for 4.6.1-4.6.13).
        # The commits between the two tags are then the notes.
        for a, b in ((frm, to), ("v" + frm_n, "v" + to_n), (frm_n, to_n)):
            try:
                cmp = gh("repos/%s/compare/%s...%s" % (source, urllib.parse.quote(a, safe=""), urllib.parse.quote(b, safe="")))
            except Exception:
                continue
            commits = cmp.get("commits") or []
            if not commits:
                continue
            lines = []
            for c in commits:
                msg = (c.get("commit", {}).get("message") or "").strip()
                if re.match(r"^(Merge|chore\(deps\)|build\(deps\)|\[skip ci\])", msg):
                    continue
                lines.append("- " + msg.replace("\n", "\n  "))
            text = "### Commits between %s and %s (%d, from the compare API; no release notes were found for these tags under %s, so the commits are the record)\n%s" % (
                a, b, len(commits), source, "\n".join(lines))
            return text[:60000], None
        return None, "no releases between %s and %s found under %s (%d releases read), and no tag range compared" % (frm, to, source, len(rels))
    text = "\n\n".join(out)
    return text[:60000], None


# THE BASELINE. The notes read are the ones AFTER the pin, so a requirement
# the pinned release already carried looks new. On 2026-10-06 Rocket.Chat
# 8.9.0 listed "MongoDB: 8.0" under engine versions, the review called it a
# mismatch against the template's MongoDB 7.0 and held the bump for a person.
# 8.8.1, the release the template was already running on 7.0, carried the same
# line, and the startup check that enforces it was byte-for-byte unchanged.
# The release being moved FROM is read too, as a baseline and never as a
# change.
def from_release(source, frm, limit=12000):
    n = normalise(frm)
    for tag in dict.fromkeys((frm.split("@")[0], "v" + n, n, "release-" + n)):
        try:
            r = gh("repos/%s/releases/tags/%s" % (source, urllib.parse.quote(tag, safe="")))
        except Exception:
            continue
        body = (r.get("body") or "").strip()
        if body:
            return "### %s (%s)\n%s" % (r.get("tag_name"), (r.get("published_at") or "")[:10], body[:limit])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--image", required=True, help="image reference without tag, e.g. lissy93/dashy")
    ap.add_argument("--from", dest="frm", required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--source", help="GitHub owner/name that publishes the release notes")
    ap.add_argument("--compose", default=None, help="path of the compose file (default: <repo>.yml)")
    ap.add_argument("--out", default="review.md")
    ap.add_argument("--json", dest="js", default=None)
    ap.add_argument("--cache", default=None,
                    help="directory where a review of the same source and range is reused")
    a = ap.parse_args()

    image = re.sub(r"^docker\.io/(library/)?", "", a.image)
    source = a.source or SOURCES.get(image) or (image if "/" in image and not image.startswith(("ghcr.io", "quay.io", "lscr.io")) else None)
    compose_path = a.compose or (a.repo + ".yml")
    compose = open(compose_path, encoding="utf-8").read() if os.path.exists(compose_path) else ""
    envx = open(".env.example", encoding="utf-8").read() if os.path.exists(".env.example") else ""

    if image in NO_NOTES:
        source, notes, problem = None, None, NO_NOTES[image]
    elif not source:
        notes, problem = None, "no known source repository for %s" % image
    else:
        notes, problem = release_notes(source, a.frm, a.to)

    # One upgrade, one review. Dify ships four images from one repository and
    # moves them together, so a release produced four calls that read the same
    # notes and wrote the same verdict four times. Worse, triage rewrites the
    # pins one at a time, so the second review read a compose file mid-rewrite
    # and reported the version mismatch it was in the middle of fixing.
    #
    # Keyed on the SOURCE, not the image: itzg/minecraft-server and
    # itzg/mc-backup share a version scheme and are different projects, and
    # both deserve their own read.
    cached = None
    if a.cache and source:
        key = hashlib.sha256(("%s|%s|%s" % (source, a.frm, a.to)).encode()).hexdigest()[:16]
        cached = os.path.join(a.cache, "review-%s" % key)
        if os.path.exists(cached + ".md") and os.path.exists(cached + ".json"):
            text = io.open(cached + ".md", encoding="utf-8").read()
            io.open(a.out, "w", encoding="utf-8").write(text)
            if a.js:
                data = json.loads(io.open(cached + ".json", encoding="utf-8").read())
                data["image"] = image
                data["reused_from"] = source
                io.open(a.js, "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
            print(text)
            print("\n[reused the review of %s %s -> %s]" % (source, a.frm, a.to), file=sys.stderr)
            return

    client = anthropic.Anthropic(credentials=WorkloadIdentityCredentials(identity_token_provider=github_oidc_token, **FEDERATION))

    system = (
        "You review upgrades of self-hosted deployment templates for an operator who runs them in production. "
        "You are given upstream release notes between two versions of one image, the docker compose file that pins it, "
        "and the .env.example that documents its variables. Report only what a deployed host has to act on. "
        "Be exact and quote the note you rely on. Never invent a change that is not in the notes. "
        "If the notes are missing or empty, say so and list what should be checked by hand instead. "
        "A section headed WHAT THE IMAGES THEMSELVES DIFFER IN is measured from the two image configurations in the registry, not written by anybody. Where it and the notes disagree about the container user, entrypoint, command, ports, volumes, healthcheck or environment, it is right and the notes are a description: say so plainly and let it decide the verdict for that point. It says nothing about behaviour inside the application, so a breaking change in the code is still the notes' to report. "
        "An UPGRADING, BREAKING_CHANGES or CHANGELOG section may be included after the notes: it is the "
        "project's own upgrade documentation, it often carries the breaking change the release page does "
        "not, and it is worth more than the notes when the two disagree. Read only the part covering the "
        "range being moved through. "
        "Write in plain English, no marketing, no reassurance. Answer in this exact Markdown shape:\n\n"
        "## Upstream changes %s -> %s\n\n"
        "**Verdict:** one line: SAFE TO APPLY / NEEDS ATTENTION / DO NOT APPLY UNATTENDED, with the reason.\n"
        "SAFE TO APPLY is not available when the notes name a version of a companion service - a database, a "
        "cache, a search engine - that the compose file does not pin, whatever else the release contains. "
        "That mismatch is the verdict, not a remark under it: an application running on an engine version its "
        "own release notes do not list is the failure this review exists to stop. "
        "A section headed THE RELEASE THE TEMPLATE RUNS NOW holds the notes of the version being moved FROM, "
        "given only as a baseline. A requirement it already states is not a change in this upgrade: the "
        "template already runs against it and its deploy job boots that way. Name such a requirement under "
        "Data and dependencies as already true at the current version, and do not let it decide the verdict; "
        "the rule above is for a requirement this range introduces or raises.\n\n"
        "### Breaking changes\n- ... (or: none found in the notes)\n\n"
        "### Variables\n- renamed, removed or newly required variables, with the compose or .env.example line they affect (or: none)\n\n"
        "### Data and dependencies\n- database version requirements, irreversible migrations, removed defaults, changed ports or paths (or: none)\n\n"
        "### Before applying\n- the concrete steps, if any, a deployed host needs (backup, a manual migration command, a config edit)\n\n"
        "### Notes read\n- the release tags whose notes you read, or the reason they could not be read\n" % (a.frm, a.to)
    )
    user = "Template repository: %s\nImage: %s\nFrom: %s\nTo: %s\nRelease-notes source: %s\n\n" % (a.repo, image, a.frm, a.to, source or "none")
    if notes:
        user += "=== UPSTREAM RELEASE NOTES ===\n" + notes + "\n\n"
    else:
        user += "=== UPSTREAM RELEASE NOTES ===\n(not available: %s)\n\n" % problem
    baseline = from_release(source, a.frm) if source and notes else None
    if baseline:
        user += "=== THE RELEASE THE TEMPLATE RUNS NOW (%s, a baseline, not a change) ===\n%s\n\n" % (a.frm, baseline)
    doc_name, doc_body, doc_len = (None, None, 0)
    if source:
        doc_name, doc_body, doc_len = upgrade_doc(source, a.to)
    if doc_body:
        user += ("=== UPSTREAM %s (top %d of %d characters, newest first) ===\n%s\n\n"
                 % (doc_name, len(doc_body), doc_len, doc_body))
    # Once: every call is four requests to a registry per image.
    images_differ = image_diff(image, a.frm, a.to)
    user += "=== WHAT THE IMAGES THEMSELVES DIFFER IN ===\n%s\n\n" % images_differ
    user += "=== COMPOSE FILE (%s) ===\n%s\n\n=== .env.example ===\n%s\n" % (compose_path, compose[:40000], envx[:20000])

    text, msg = answer(client, model=MODEL, max_tokens=6000, system=system, messages=[{"role": "user", "content": user}])
    verdict = re.search(r"\*\*Verdict:\*\*\s*(.+)", text)
    result = {
        "repo": a.repo, "image": image, "from": a.frm, "to": a.to, "source": source,
        "notes_found": bool(notes), "notes_problem": problem,
        "image_diff": images_differ,
        "verdict": verdict.group(1).strip() if verdict else "",
        "upgrade_doc": doc_name or "",
        "baseline_read": bool(baseline),
        "model": MODEL, "input_tokens": msg.usage.input_tokens, "output_tokens": msg.usage.output_tokens,
    }
    open(a.out, "w", encoding="utf-8").write(text + "\n")
    if a.js:
        open(a.js, "w", encoding="utf-8").write(json.dumps(result, indent=2) + "\n")
    if cached:
        os.makedirs(a.cache, exist_ok=True)
        open(cached + ".md", "w", encoding="utf-8").write(text + "\n")
        open(cached + ".json", "w", encoding="utf-8").write(json.dumps(result, indent=2) + "\n")
    print(text)
    print("\n[%s in=%d out=%d]" % (MODEL, msg.usage.input_tokens, msg.usage.output_tokens), file=sys.stderr)


if __name__ == "__main__":
    main()
