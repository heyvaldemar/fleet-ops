#!/usr/bin/env python3
"""The live catalog and its one-paragraph summary.

    fleet-catalog.py --catalog README.md    rewrite the table between the catalog markers
    fleet-catalog.py --summary README.md    rewrite the paragraph between the summary markers
    fleet-catalog.py                        print both

    fleet-catalog.py --evidence README.md   rewrite the line between the evidence markers

The catalog lists every public template and tool with its latest release
and its own CI badge; it lives in heyvaldemar/catalog. The summary is three
lines of counts for the profile README, linking to the catalog. Both read
GitHub through `gh api` and claim nothing of their own: the badge is the
workflow's, the release is the tag GitHub has, the date is when it was
published. A repository with no release yet is listed with a dash, not hidden.

Either file is rewritten only when a row or a count changed; the timestamp
alone never makes a commit. So the date in each block is the date the numbers
last MOVED, not the date they were last checked, and both blocks now say so.
They used to say "regenerated daily" and carry a date two days old, which is
what a broken job looks like from outside. Whether the job is still running is
a different question and has its own answer: fleet-heartbeat.py fails when a
scheduled workflow here stops firing.
"""
import argparse
import base64
import datetime
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

OWNER = "heyvaldemar"
CATALOG_URL = "https://github.com/%s/catalog" % OWNER
CAT_START, CAT_END = "<!-- fleet-catalog:start -->", "<!-- fleet-catalog:end -->"
SUM_START, SUM_END = "<!-- fleet-summary:start -->", "<!-- fleet-summary:end -->"
EVI_START, EVI_END = "<!-- fleet-evidence:start -->", "<!-- fleet-evidence:end -->"


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], stderr=subprocess.DEVNULL))


def repos():
    out, page = [], 1
    while True:
        batch = gh("users/%s/repos?per_page=100&page=%d&type=owner&sort=full_name" % (OWNER, page))
        out += batch
        if len(batch) < 100:
            break
        page += 1
    return [r for r in out if not r["archived"] and not r["fork"] and not r["private"] and r["name"] != "catalog"]


def _version(tag):
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)$", tag or "")
    return tuple(int(x) for x in m.groups()) if m else None


def latest_release(name):
    """The highest published version, not the release GitHub flags as latest.

    THE FLAG FOLLOWS THE CALENDAR, AND ONCE IT FOLLOWED IT BACKWARDS. A release
    created for a version that had been announced and never tagged, days after
    2.0.x had shipped, took the flag: nextcloud-onlyoffice showed v1.3.0 on this
    page while v2.0.4 was out. The highest non-draft, non-prerelease version is
    the answer a reader means; the flag is used only when no tag parses.
    """
    try:
        rels = gh("repos/%s/%s/releases?per_page=100" % (OWNER, name)) or []
    except subprocess.CalledProcessError:
        rels = []
    good = [r for r in rels if not r.get("draft") and not r.get("prerelease") and _version(r.get("tag_name"))]
    if good:
        top = max(good, key=lambda r: _version(r["tag_name"]))
        return top["tag_name"], (top.get("published_at") or "")[:10]
    try:
        r = gh("repos/%s/%s/releases/latest" % (OWNER, name))
        return r["tag_name"], (r.get("published_at") or "")[:10]
    except subprocess.CalledProcessError:
        return "", ""


def has_workflow(name, wf):
    try:
        gh("repos/%s/%s/contents/.github/workflows/%s" % (OWNER, name, wf))
        return True
    except subprocess.CalledProcessError:
        return False


# Stacks that sit behind Traefik with Let's Encrypt and do not say so in their
# name. A repository that matches no group's name rule but has no workflow from
# the catch-all group's list is dropped silently, so a new stack named for what
# it does rather than for how it is deployed disappears from both the catalog
# and the profile count without anything failing. Add it here instead.
NAMED_TRAEFIK_STACKS = ("chatops-privilege-wall",)

GROUPS = [
    ("Self-hosted applications behind Traefik with Let's Encrypt", "self-hosted applications behind Traefik",
     lambda n: n.endswith("-traefik-letsencrypt-docker-compose") or n in NAMED_TRAEFIK_STACKS,
     ["deployment-verification.yml"]),
    ("Game servers", "game servers",
     lambda n: n.endswith("-server-docker-compose") or n in ("game-server-wireguard-relay-docker-compose", "minecraft-server-proxy-docker-compose", "rathena-docker", "modernuo-docker"), ["deployment-verification.yml"]),
    ("Other stacks", "other stacks",
     lambda n: n.endswith("-docker-compose") or n.endswith("-docker"), ["deployment-verification.yml", "retention-verification.yml", "publish.yml"]),
    ("Terraform pipelines on AWS", "Terraform pipelines on AWS",
     lambda n: n.endswith("-terraform"), ["terraform-verification.yml"]),
    ("Operations tools and scripts", "operations tools and scripts",
     lambda n: True, ["tests.yml", "verification.yml"]),
]

SPECIAL = {"cs2": "Counter-Strike 2", "cs2-classic": "CS2 classic maps", "tf2": "Team Fortress 2", "l4d2": "Left 4 Dead 2",
           "kf2": "Killing Floor 2", "jediacademy": "Jedi Academy", "blackmesa": "Black Mesa", "zomboid": "Project Zomboid",
           "quake3": "Quake III (QuakeJS)", "game-server-wireguard-relay": "Game-server WireGuard relay",
           "minecraft-server-proxy": "Minecraft proxy (Velocity)", "minecraft-server": "Minecraft server",
           "mssql-server": "SQL Server", "wikijs": "Wiki.js", "homeassistant": "Home Assistant", "nextcloud-onlyoffice": "Nextcloud + ONLYOFFICE", "romm": "RomM", "webrcade": "WebRcade", "gaseous-server-using": "Gaseous Server",
           "outline-keycloak": "Outline + Keycloak", "rocketchat": "Rocket.Chat", "gitlab": "GitLab", "gitea": "Gitea", "glpi": "GLPI",
           "otrs": "OTRS", "xwiki": "XWiki", "siyuan": "SiYuan", "docmost": "Docmost", "homebox": "Homebox", "owncloud": "ownCloud",
           "sonarqube": "SonarQube", "vaultwarden": "Vaultwarden", "keycloak": "Keycloak", "mailu": "Mailu", "seafile": "Seafile",
           "zammad": "Zammad", "authelia": "Authelia", "affine": "AFFiNE", "dashy": "Dashy", "ollama": "Ollama", "portainer": "Portainer",
           "zabbix": "Zabbix", "jira": "Jira", "confluence": "Confluence", "bitbucket": "Bitbucket", "joomla": "Joomla", "wordpress": "WordPress",
           "ghost": "Ghost", "grafana": "Grafana", "mattermost": "Mattermost", "mattermost-data-retention": "Mattermost data retention",
           "nextcloud": "Nextcloud", "sftp": "SFTP", "rathena": "rAthena (Ragnarok Online)", "modernuo": "ModernUO (Ultima Online)",
           "aws-kubectl": "aws-kubectl image", "restore-drill": "restore-drill", "deadman-switch": "deadman-switch",
           "external-disk-backup": "external-disk-backup", "sops-env-git": "sops-env-git", "systemd-timer-table": "systemd-timer-table",
           "unhealthy-watchdog": "unhealthy-watchdog"}


def title(name):
    n = re.sub(r"-(traefik-letsencrypt-)?docker-compose$|-docker$|-pipeline-terraform$", "", name)
    if n not in ("minecraft-server", "mssql-server", "minecraft-server-proxy"):
        n = re.sub(r"-server$", "", n)
    return SPECIAL.get(n, n.replace("-", " ").title())


def collect():
    rows = {g[0]: [] for g in GROUPS}
    for r in repos():
        n = r["name"]
        for label, _, match, wfs in GROUPS:
            if not match(n):
                continue
            wf = next((w for w in wfs if has_workflow(n, w)), None)
            if not wf:
                break
            tag, date = latest_release(n)
            badge = "[![CI](https://github.com/%s/%s/actions/workflows/%s/badge.svg?branch=main)](https://github.com/%s/%s/actions/workflows/%s)" % (OWNER, n, wf, OWNER, n, wf)
            rel = "[%s](https://github.com/%s/%s/releases/tag/%s) · %s" % (tag, OWNER, n, tag, date) if tag else "—"
            rows[label].append([title(n), n, rel, badge])
            break
    seen = {}
    for label in rows:
        for row in rows[label]:
            seen[row[0]] = seen.get(row[0], 0) + 1
    for label in rows:
        for row in rows[label]:
            if seen[row[0]] > 1:
                row[0] += " (behind Traefik)" if "traefik" in row[1] else " (standalone)"
        rows[label].sort(key=lambda x: x[0].lower())
    return rows


# THE EVIDENCE LINE COUNTS WHAT RUNS, NOT WHAT EXISTS.
#
# The profile tells the story of 23 September 2026: 72 restore scripts across
# 47 templates that CI had never run. That count is history and stays in the
# prose. What is true today goes here, recounted daily: how many restore
# scripts the fleet ships and how many of them a test or workflow actually
# invokes - the same test the conformance rule applies, so the profile cannot
# claim what the rule would fail. A repository it cannot read is counted as
# unread and said, never as run.
RESTORE_RE = re.compile(r"[A-Za-z0-9_.-]*restore[A-Za-z0-9_.-]*\.sh")
QUIET = ("#", "echo ", "note ", "printf ", "ok ", "bad ", "fail ")


def listing(name, path=""):
    try:
        return [e["name"] for e in gh("repos/%s/%s/contents/%s" % (OWNER, name, path))]
    except (subprocess.CalledProcessError, TypeError):
        return None


def text_of(name, path):
    d = gh("repos/%s/%s/contents/%s" % (OWNER, name, path))
    return base64.b64decode(d["content"]).decode("utf-8", "replace")


def restore_runs(name):
    """(scripts shipped, scripts something runs), or None when it cannot tell."""
    names = listing(name)
    if names is None:
        return None
    scripts = sorted(n for n in names if RESTORE_RE.fullmatch(n))
    if not scripts:
        return [], []
    paths = ["tests/%s" % n for n in (listing(name, "tests") or []) if n.endswith(".sh")]
    paths += [".github/workflows/%s" % n for n in (listing(name, ".github/workflows") or [])]
    lines = []
    for path in paths:
        try:
            body = text_of(name, path)
        except subprocess.CalledProcessError:
            return None
        lines += [t for t in (l.strip() for l in body.splitlines()) if t and not t.startswith(QUIET)]
    text = "\n".join(lines)
    run = [sc for sc in scripts if re.search(r"(?:(?<![\w/.-])\./|/)" + re.escape(sc) + r"(?![\w.-])", text)]
    return scripts, run


def count_tags(name):
    n, page = 0, 1
    while True:
        batch = gh("repos/%s/%s/tags?per_page=100&page=%d" % (OWNER, name, page))
        n += len(batch)
        if len(batch) < 100:
            return n
        page += 1


def collect_evidence(names):
    ev = {"scripts": 0, "templates": 0, "run": 0, "unread": [], "tags": 0}
    for name in names:
        got = restore_runs(name)
        if got is None:
            ev["unread"].append(name)
        elif got[0]:
            ev["templates"] += 1
            ev["scripts"] += len(got[0])
            ev["run"] += len(got[1])
        try:
            ev["tags"] += count_tags(name)
        except subprocess.CalledProcessError:
            if name not in ev["unread"]:
                ev["unread"].append(name)
    return ev


def minutes(s):
    s = int(s)
    return "%d min %d s" % (s // 60, s % 60) if s >= 60 else "%d s" % s


def render_evidence(ev, drills=None, sc=None, bp=None):
    drills = drills or []
    passed = [d for d in drills if d.get("ok") and isinstance(d.get("seconds_total"), (int, float))]
    drilled = (" %d of %d templates restored an older release's backup into the current release on a machine "
               "that had never run the stack, the fastest in %s." % (
                   len(passed), len(drills), minutes(min(d["seconds_total"] for d in passed)))) if passed else ""
    scored = (" OpenSSF Scorecard, run by OpenSSF and not by me, puts the median at %s across %d repositories." % (
        sc["median"], sc["scored"])) if sc and sc.get("scored") else ""
    badged = (" The OpenSSF Best Practices badge, a questionnaire I answered and OpenSSF publishes with every "
              "answer, is passing on %d of %d registered repositories%s." % (
                  bp["passing"], bp["registered"],
                  ("; %d could not be read today" % len(bp["unread"])) if bp.get("unread") else "")
              ) if bp and bp.get("registered") else ""
    if ev["run"] == ev["scripts"]:
        lead = "**Today: %d restore scripts across %d repositories, every one of them run by CI.**" % (ev["scripts"], ev["templates"])
    else:
        lead = "**Today: %d restore scripts across %d repositories, and CI runs %d of them.** The fleet rule fails the rest until they run." % (
            ev["scripts"], ev["templates"], ev["run"])
    unread = (" %d %s could not be read today and %s not counted." % (
        len(ev["unread"]), "repository" if len(ev["unread"]) == 1 else "repositories",
        "is" if len(ev["unread"]) == 1 else "are")) if ev["unread"] else ""
    return (EVI_START + "\n" + lead + " %d releases are tagged across the fleet.%s%s%s%s "
            "fleet-ops recounts these %s and rewrites this line when a number changes; these last changed %s UTC.\n"
            % (ev["tags"], unread, drilled, scored, badged, cadence(), stamp()) + EVI_END + "\n")


# THE CLEAN-MACHINE DRILL, AS MEASURED. Each template that carries
# dr-drill.yml restores its previous release's backups onto a runner that has
# never run it, and keeps the result as an artifact. Only a run that succeeded
# is quoted; a template whose last drill failed is listed as failing, with no
# number, because a restore time from a restore that did not work is not a time.
def dr_result(name):
    try:
        runs = gh("repos/%s/%s/actions/workflows/dr-drill.yml/runs?status=completed&per_page=1" % (OWNER, name))
    except subprocess.CalledProcessError:
        return None
    run = (runs.get("workflow_runs") or [None])[0]
    if not run:
        return None
    if run["conclusion"] != "success":
        return {"repository": name, "ok": False, "run": run["html_url"], "finished_at": run["updated_at"]}
    arts = gh("repos/%s/%s/actions/runs/%d/artifacts" % (OWNER, name, run["id"])).get("artifacts", [])
    art = next((a for a in arts if a["name"] == "dr-result" and not a["expired"]), None)
    if not art:
        return {"repository": name, "ok": True, "run": run["html_url"], "finished_at": run["updated_at"]}
    blob = subprocess.check_output(["gh", "api", "repos/%s/%s/actions/artifacts/%d/zip" % (OWNER, name, art["id"])],
                                   stderr=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as d:
        z = os.path.join(d, "a.zip")
        io.open(z, "wb").write(blob)
        with zipfile.ZipFile(z) as zf:
            r = json.loads(zf.read("dr-result.json"))
    return {"repository": name, "ok": bool(r.get("markers_back")), "from": r.get("from"), "to": r.get("to"),
            "seconds_total": r.get("seconds_total"), "seconds_restore": r.get("seconds_restore"),
            "run": run["html_url"], "finished_at": r.get("finished_at")}


# THE RECOVERY POINT, AS SHIPPED. A drill gives the recovery time; the other
# half of the question a security questionnaire asks is how much can be lost,
# and that is the backup interval the template ships with. It is read from
# .env.example, the file people copy, commented or not, so the number here is
# the default an operator gets without touching anything.
def backup_interval(name):
    try:
        env = text_of(name, ".env.example")
    except subprocess.CalledProcessError:
        return None
    # Keycloak writes KEYCLOAK_BACKUP_INTERVAL; the rest write BACKUP_INTERVAL.
    m = re.search(r"^#?\s*(?:[A-Z0-9]+_)*BACKUP_INTERVAL=([0-9]+[smhd])\s*$", env, re.M)
    return m.group(1) if m else None


def hours(interval):
    """'24h' -> 24, '1d' -> 24, '30m' -> 0.5; None for anything else."""
    m = re.fullmatch(r"([0-9]+)([smhd])", interval or "")
    if not m:
        return None
    n = int(m.group(1))
    return {"s": n / 3600, "m": n / 60, "h": n, "d": n * 24}[m.group(2)]


def with_rpo(d):
    iv = backup_interval(d["repository"])
    d["backup_interval"] = iv
    d["rpo_hours"] = hours(iv)
    return d


# SCORED BY SOMEBODY ELSE. OpenSSF Scorecard runs its own checks against every
# public repository here and publishes the result; this reads that result and
# repeats it, low marks included. A number the fleet awarded itself would be
# a claim; this one is a measurement by a third party with its own rules.
SCORECARD = "https://api.securityscorecards.dev/projects/github.com/%s/%s"


def scorecard(name):
    try:
        with urllib.request.urlopen(SCORECARD % (OWNER, name), timeout=30) as r:
            d = json.load(r)
    except Exception:
        return None
    if not isinstance(d.get("score"), (int, float)):
        return None
    return {"score": d["score"], "date": d.get("date"),
            "checks": {c["name"]: c["score"] for c in d.get("checks", []) if "name" in c and "score" in c}}


def collect_scorecard(names):
    scored, unscored = {}, []
    for n in names:
        got = scorecard(n)
        if got is None:
            unscored.append(n)
        else:
            scored[n] = got
    if not scored:
        return {"scored": 0, "unscored": unscored}
    scores = sorted(v["score"] for v in scored.values())
    mid = len(scores) // 2
    median = scores[mid] if len(scores) % 2 else round((scores[mid - 1] + scores[mid]) / 2, 1)
    lowest = min(scored, key=lambda n: (scored[n]["score"], n))
    below = {}
    for v in scored.values():
        for check, sc in v["checks"].items():
            if 0 <= sc < 10:                  # -1 is "not applicable", not a low mark
                below[check] = below.get(check, 0) + 1
    return {"scored": len(scored), "median": median,
            "lowest": scored[lowest]["score"], "lowest_repository": lowest,
            "scores": {n: v["score"] for n, v in sorted(scored.items())},
            "below_ten": dict(sorted(below.items())), "unscored": unscored,
            "date": max((v["date"] or "") for v in scored.values()) or None}


# ANSWERED BY ME, PUBLISHED BY THEM. The OpenSSF Best Practices badge is a
# questionnaire: sixty-seven criteria, each answered Met, Unmet or N/A with a
# sentence saying why, and every answer is public on bestpractices.dev. A
# badge is only as honest as its answers, so each answer names the workflow or
# file that makes it true, and a repository with no test suite says Unmet and
# stays short of passing. This reads what the site says today and repeats it,
# the short ones by name.
BESTPRACTICES = "https://www.bestpractices.dev/projects.json?url=%s"
BESTPRACTICES_PASSING = ("passing", "silver", "gold")
# The badge site answers 429 after about twenty quick requests and forgives
# within five seconds (measured 2026-09-25: the first run read 24 of 97 and
# called the rest unread). One request every two seconds stays under it; a
# 429 that still comes is waited out and asked again.
BP_PACE = 2.0
BP_RETRY_WAIT = 10.0
BP_TRIES = 3


def _bp_fetch(url):
    """(status, body) from the badge site; a status of 0 is no answer at all."""
    req = urllib.request.Request(url, headers={
        "Accept": "application/json", "User-Agent": "fleet-ops (heyvaldemar.com)"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception:
        return 0, ""


def bestpractices(name, fetch=None, sleep=time.sleep):
    """A dict for a registered repository, False for one the site has never
    heard of, None when the site could not be asked."""
    fetch = fetch or _bp_fetch
    url = BESTPRACTICES % urllib.parse.quote("https://github.com/%s/%s" % (OWNER, name), safe="")
    d = None
    for attempt in range(BP_TRIES):
        status, body = fetch(url)
        if status == 429:
            sleep(BP_RETRY_WAIT * (attempt + 1))
            continue
        if status != 200:
            return None
        try:
            d = json.loads(body)
        except ValueError:
            return None
        break
    if not isinstance(d, list):
        return None
    if not d or not isinstance(d[0].get("id"), int):
        return False
    p = d[0]
    return {"id": p["id"], "level": p.get("badge_level") or "in_progress",
            "percent": p.get("badge_percentage_0"), "date": (p.get("updated_at") or "")[:10] or None}


def collect_bestpractices(names, sleep=time.sleep):
    found, unregistered, unread = {}, [], []
    for i, n in enumerate(names):
        if i:
            sleep(BP_PACE)
        got = bestpractices(n, sleep=sleep)
        if got is None:
            unread.append(n)
        elif got is False:
            unregistered.append(n)
        else:
            found[n] = got
    passing = [n for n, v in found.items() if v["level"] in BESTPRACTICES_PASSING]
    return {"registered": len(found), "passing": len(passing),
            "levels": {n: v["level"] for n, v in sorted(found.items())},
            "ids": {n: v["id"] for n, v in sorted(found.items())},
            "short": {n: v["percent"] for n, v in sorted(found.items()) if n not in passing},
            "unregistered": unregistered, "unread": unread,
            "date": (max((v["date"] or "") for v in found.values()) or None) if found else None}


def fleet_json(rows, ev, drills, sc=None, bp=None):
    return json.dumps({
        "measured_at": stamp() + " UTC",
        "repositories": sum(len(v) for v in rows.values()),
        "groups": {short: len(rows[label]) for label, short, _, _ in GROUPS if rows[label]},
        "restore_scripts": ev["scripts"], "restore_scripts_run": ev["run"], "restore_repositories": ev["templates"],
        "release_tags": ev["tags"], "unread": ev["unread"],
        "clean_machine_restores": drills,
        "scorecard": sc or {"scored": 0, "unscored": []},
        "bestpractices": bp or {"registered": 0, "passing": 0, "unregistered": [], "unread": []},
    }, indent=1, sort_keys=True) + "\n"


def write_json(path, text):
    """Rewritten only when something but the timestamp changed, as the blocks are."""
    old = io.open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    strip = lambda t: re.sub(r'"measured_at": "[^"]*"', "", t)
    if strip(old) == strip(text):
        return "unchanged"
    io.open(path, "w", encoding="utf-8").write(text)
    return "updated"


WORKFLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", ".github", "workflows", "fleet-catalog.yml")


def expand_hours(field):
    """The hours a cron's hour field names, or None if it is a shape this does
    not understand. `*/4` is four times the runs of `6`, and the first version
    counted the string instead of the schedule."""
    out = []
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, _, st = part.partition("/")
            if not st.isdigit() or int(st) == 0:
                return None
            step = int(st)
        if part == "*":
            lo, hi = 0, 23
        elif "-" in part:
            a, _, b = part.partition("-")
            if not (a.isdigit() and b.isdigit()):
                return None
            lo, hi = int(a), int(b)
        elif part.isdigit():
            lo = hi = int(part)
        else:
            return None
        if not (0 <= lo <= hi <= 23):
            return None
        out += list(range(lo, hi + 1, step))
    return out


def cadence(path=None):
    """How often this job actually runs, in words, read from its own cron.

    THE PAGE SAID "every four hours" FOR WEEKS AFTER IT STOPPED BEING TRUE.
    The sentence was a constant in this file; the schedule was a line in a
    workflow; nothing compared them. It went to twice a day, then to once, and
    the most-read page in this fleet went on announcing four hours — on the
    same page that exists to say that a claim with nothing checking it is
    worth nothing.

    Derived, so it cannot drift again. An unreadable or scheduleless workflow
    says so rather than inventing a number.
    """
    try:
        body = io.open(path or WORKFLOW, encoding="utf-8").read()
    except OSError:
        return "on a schedule this file could not read"
    hours = []
    for c in re.findall(r"cron:\s*['\"]([^'\"]+)['\"]", body):
        f = c.split()
        if len(f) != 5:
            continue
        _, hour, dom, _, dow = f
        if dom not in ("*", "?") or dow not in ("*", "?"):
            return "weekly" if dow not in ("*", "?") else "monthly"
        got = expand_hours(hour)
        if got is None:
            return "on a schedule this file could not read"
        hours += got
    if not hours:
        return "when something asks it to"
    n = len(set(hours))
    if n == 1:
        return "once a day"
    if n == 2:
        return "twice a day"
    if 24 % n == 0:
        return "every %d hours" % (24 // n)
    return "%d times a day" % n


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")


def render_catalog(rows):
    total = sum(len(v) for v in rows.values())
    out = [CAT_START, "",
           "*%d repositories. The badge says whether each one boots in its own CI; whether its pins are current is a separate daily check that the fleet acts on, so a pin one version behind does not turn a working template red. The release is the tag GitHub has. Rebuilt by [fleet-ops](https://github.com/%s/fleet-ops) %s and rewritten when a row changes; this table last changed %s UTC.*" % (total, OWNER, cadence(), stamp()),
           ""]
    for label, _, _, _ in GROUPS:
        if not rows[label]:
            continue
        out += ["## %s (%d)" % (label, len(rows[label])), "", "| Repository | Latest release | CI |", "| :--- | :--- | :--- |"]
        out += ["| [%s](https://github.com/%s/%s) | %s | %s |" % (t, OWNER, n, rel, badge) for t, n, rel, badge in rows[label]]
        out.append("")
    out.append(CAT_END)
    return "\n".join(out) + "\n"


def render_summary(rows):
    total = sum(len(v) for v in rows.values())
    parts = ["%d %s" % (len(rows[label]), short) for label, short, _, _ in GROUPS if rows[label]]
    return (SUM_START + "\n"
            "**[%d repositories under this standard](%s)**: %s. Every template is pinned by digest, boots in CI daily, "
            "upgrades from its previous release on the same volumes, and is released only after that passes. "
            "fleet-ops recounts them %s and rewrites this line when a number changes; these last changed %s UTC.\n" % (total, CATALOG_URL, ", ".join(parts), cadence(), stamp())
            + SUM_END + "\n")


def rewrite(path, start, end, block):
    s = io.open(path, encoding="utf-8").read()
    if start not in s or end not in s:
        sys.exit("markers %s / %s not found in %s" % (start, end, path))
    i, j = s.index(start), s.index(end) + len(end) + 1
    new = s[:i] + block + s[j:]
    # THE COMPARISON IGNORES THE TIMESTAMP, and it must not depend on the
    # words around it. The first version matched "last <date> UTC"; the moment
    # the sentence said "last changed <date> UTC" instead, the pattern stopped
    # matching, every run would have differed from the last one, and this would
    # have pushed a commit to the profile on every run, for ever.
    strip = lambda t: re.sub(r"[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC", "", t)
    if strip(new) == strip(s):
        return "unchanged"
    io.open(path, "w", encoding="utf-8").write(new)
    return "updated"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog")
    ap.add_argument("--summary")
    ap.add_argument("--evidence")
    ap.add_argument("--json")
    a = ap.parse_args()
    rows = collect()
    if not a.catalog and not a.summary and not a.evidence and not a.json:
        print(render_summary(rows))
        print(render_evidence(collect_evidence([r["name"] for r in repos()])))
        print(render_catalog(rows))
        return
    if a.catalog:
        print("catalog:", rewrite(a.catalog, CAT_START, CAT_END, render_catalog(rows)))
    if a.summary:
        print("summary:", rewrite(a.summary, SUM_START, SUM_END, render_summary(rows)))
    if a.evidence or a.json:
        names = [r["name"] for r in repos()]
        ev = collect_evidence(names)
        drills = [with_rpo(d) for d in (dr_result(n) for n in names if has_workflow(n, "dr-drill.yml")) if d]
        sc = collect_scorecard(names)
        bp = collect_bestpractices(names)
    if a.evidence:
        print("evidence:", rewrite(a.evidence, EVI_START, EVI_END, render_evidence(ev, drills, sc, bp)))
    if a.json:
        print("json:", write_json(a.json, fleet_json(rows, ev, drills, sc, bp)))


if __name__ == "__main__":
    main()
