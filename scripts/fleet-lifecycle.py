#!/usr/bin/env python3
"""Every database in the fleet, checked against its vendor's support calendar.

The freshness check in each repository watches for a newer tag of the image it
pins. That is the wrong instrument for a database, because a database is pinned
at a major on purpose: postgres:16 keeps receiving patches for years and never
"lags", so a major that reaches end of support would sit in a template forever
without a single check going red.

This asks the other question. For every data store the fleet pins it reads the
vendor's own support calendar from endoflife.date, finds the cycle the pin
falls in, and reports anything already past its end of support or approaching
it. A template on an unsupported database is a template that stops receiving
security fixes, which is the one thing a person deploying it cannot find out by
reading it.

A second check, narrower and stricter: some applications publish the versions
of their companion services they actually support. Rocket.Chat does, at
releases.rocket.chat/<version>/info. Where that exists it is read directly,
because a release that runs on a database the vendor still supports but the
application does not is broken in a way no calendar shows.

Usage:
  fleet-lifecycle.py [--warn-days 180] [--report report.md] [--json out.json]
"""
import argparse
import datetime
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request

OWNER = os.environ.get("FLEET_OWNER", "heyvaldemar")
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
TODAY = datetime.date.today()

# Image name -> endoflife.date product. Only things with a real published
# support calendar: a data store or the reverse proxy in front of it. An
# application's own lifecycle is the upstream review's job, not this one,
# with one exception: an application held on a Long Term Support line on
# purpose. Confluence stays on 10.2 because 11.0 needs PostgreSQL 17 and is a
# one-way upgrade (2026-10-10), and Jira sits on its 11.3 LTS line; for those
# the end of the line is the reminder to move, so its date is watched here.
PRODUCTS = {
    "atlassian/confluence": "confluence",
    "atlassian/jira-software": "jira-software",
    "postgres": "postgresql",
    "mysql": "mysql",
    "mariadb": "mariadb",
    "mongo": "mongodb",
    "redis": "redis",
    "valkey": "valkey",
    "elasticsearch": "elasticsearch",
    "docker.elastic.co/elasticsearch/elasticsearch": "elasticsearch",
    "opensearchproject/opensearch": "opensearch",
    "rabbitmq": "rabbitmq",
    "memcached": "memcached",
    "traefik": "traefik",
    "mcr.microsoft.com/mssql/server": "mssqlserver",
}

# Applications that publish, in machine-readable form, which versions of a
# companion service they support. The value says where to ask and what the
# answer constrains.
COMPANION_SUPPORT = {
    "rocketchat/rocket.chat": {
        "url": "https://releases.rocket.chat/%s/info",
        "field": "compatibleMongoVersions",
        "companion": "mongo",
        "label": "MongoDB",
    },
}


def http_json(url, headers=None, timeout=30):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def gh(path, raw=False, timeout=30):
    headers = {"Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json",
               "User-Agent": "fleet-lifecycle"}
    if TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    req = urllib.request.Request("https://api.github.com/" + path.lstrip("/"), headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode("utf-8")
    return body if raw else json.loads(body)


_eol_cache = {}


def waivers(path):
    """Pins held on purpose: reason, and a date to look at them again."""
    try:
        with io.open(path, encoding="utf-8") as fh:
            return json.load(fh).get("waivers", [])
    except (OSError, ValueError) as e:
        print("  ! waivers unreadable (%s) - every finding is reported" % e, file=sys.stderr)
        return []


def waiver_for(held, repo, image):
    for w in held:
        if w.get("repo") == repo and w.get("image") == image:
            return w
    return None


def cycles(product):
    """The vendor's support calendar, newest cycle first."""
    if product not in _eol_cache:
        try:
            _eol_cache[product] = http_json("https://endoflife.date/api/%s.json" % product,
                                            {"User-Agent": "fleet-lifecycle"})
        except (urllib.error.URLError, ValueError, OSError) as e:
            print("  ! %s: support calendar unreadable (%s)" % (product, e), file=sys.stderr)
            _eol_cache[product] = []
    return _eol_cache[product]


def base_version(v):
    """7.0.30-ubuntu -> 7.0.30, 17-alpine -> 17, 4.3-management -> 4.3.

    A tag carries the distribution variant after the version; the calendar
    knows nothing about variants.
    """
    return re.split(r"[-_+]", v, maxsplit=1)[0]


def match_cycle(product, version):
    """The calendar entry a pin falls in: the longest cycle that prefixes it.

    postgres:17-alpine falls in cycle 17; elasticsearch:8.19.20 in 8.19;
    mongo:7.0 in 7.0. Matching on dot boundaries so 1.6 never claims 1.60.

    Some vendors key the calendar on an internal version and sell the product
    under a year. SQL Server's cycle 16.0 is the 2022 everybody types into a
    docker tag, and that year is in releaseLabel, so the label is tried too -
    otherwise the one repository pinning it is reported as unknown forever.
    """
    v = base_version(version)
    best = None
    for entry in cycles(product):
        keys = [str(entry.get("cycle", ""))]
        label = str(entry.get("releaseLabel", "") or "")
        if label:
            keys.append(label.split()[0])
        for c in keys:
            if c and (v == c or v.startswith(c + ".")):
                if best is None or len(c) > best[0]:
                    best = (len(c), entry)
    return best[1] if best else None


def parse_pins(compose):
    """The x-images block, which is the single source of truth for every pin.

    Each line reads `name: &anchor ${TAG_VAR:-image:${VERSION_VAR:-1.2@sha256:..}}`
    and what matters here is the image and the version default.
    """
    block = re.search(r"^x-images:\n(.*?)(?=^\S)", compose, re.S | re.M)
    if not block:
        return []
    out = []
    for line in block.group(1).splitlines():
        m = re.search(r":-\s*([A-Za-z0-9][A-Za-z0-9./_-]*):\$\{[A-Z0-9_]+:-([^@}\s]+)", line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def companion_verdict(repo, pins, findings):
    """What the application itself says about the database beside it."""
    by_image = dict(pins)
    for image, spec in COMPANION_SUPPORT.items():
        if image not in by_image:
            continue
        app_version = base_version(by_image[image])
        try:
            info = http_json(spec["url"] % app_version, {"User-Agent": "fleet-lifecycle"})
        except (urllib.error.URLError, ValueError, OSError) as e:
            findings.append({"repo": repo, "kind": "companion", "level": "unknown", "image": image,
                             "text": "%s %s: could not read what it supports (%s)" % (image, app_version, e)})
            continue
        allowed = info.get(spec["field"]) or []
        pinned = by_image.get(spec["companion"])
        if not allowed or not pinned:
            continue
        pinned_base = base_version(pinned)
        if not any(pinned_base == a or pinned_base.startswith(str(a) + ".") for a in allowed):
            findings.append({
                "repo": repo, "kind": "companion", "level": "expired", "image": spec["companion"],
                "text": "%s %s supports %s %s and this template pins %s:%s — the application, not the vendor, "
                        "is the one refusing it" % (image, app_version, spec["label"],
                                                    "/".join(str(a) for a in allowed), spec["companion"], pinned)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--warn-days", type=int, default=180,
                    help="how far ahead an approaching end of support is worth saying (default 180)")
    ap.add_argument("--report", default=None)
    ap.add_argument("--json", dest="js", default=None)
    ap.add_argument("--repos", default=None, help="comma-separated, instead of the whole fleet")
    ap.add_argument("--waivers", default="lifecycle-waivers.json",
                    help="pins held on purpose, with the reason and a date to look again")
    a = ap.parse_args()

    if a.repos:
        repos = [r.strip() for r in a.repos.split(",") if r.strip()]
    else:
        repos, page = [], 1
        while True:
            batch = gh("user/repos?affiliation=owner&per_page=100&page=%d" % page)
            if not batch:
                break
            repos += [r["name"] for r in batch
                      if not r["archived"] and re.search(r"(docker-compose|docker)$", r["name"])]
            page += 1
        repos.sort()

    findings, checked = [], 0
    for repo in repos:
        try:
            names = [f["name"] for f in gh("repos/%s/%s/contents" % (OWNER, repo))
                     if f["name"].endswith(".yml") and not f["name"].startswith(".")]
        except (urllib.error.URLError, OSError):
            continue
        if not names:
            continue
        # EVERY compose file, not the first one. outline-keycloak splits its
        # stack across three: traefik in the first, keycloak and its postgres
        # in the second, outline with a second postgres and a redis in the
        # third. Reading one of them checked a sixth of that repository and
        # reported the rest as if it had looked.
        pins = []
        for name in sorted(names):
            try:
                pins += parse_pins(gh("repos/%s/%s/contents/%s" % (OWNER, repo, name), raw=True))
            except (urllib.error.URLError, OSError):
                continue
        if not pins:
            continue
        for image, version in sorted(set(pins)):
            product = PRODUCTS.get(image)
            if not product:
                continue
            checked += 1
            entry = match_cycle(product, version)
            if entry is None:
                findings.append({"repo": repo, "kind": "calendar", "level": "unknown", "image": image,
                                 "text": "%s:%s is in no cycle the %s calendar lists — check by hand"
                                         % (image, version, product)})
                continue
            eol = entry.get("eol")
            if eol in (True,):
                findings.append({"repo": repo, "kind": "calendar", "level": "expired", "image": image,
                                 "text": "%s:%s (cycle %s) is out of support" % (image, version, entry["cycle"])})
                continue
            if not isinstance(eol, str):
                continue  # eol false: supported, no date announced
            when = datetime.date(*(int(x) for x in eol.split("-")))
            days = (when - TODAY).days
            if days < 0:
                findings.append({"repo": repo, "kind": "calendar", "level": "expired", "image": image,
                                 "text": "%s:%s (cycle %s) went out of support on %s, %d days ago"
                                         % (image, version, entry["cycle"], eol, -days)})
            elif days <= a.warn_days:
                findings.append({"repo": repo, "kind": "calendar", "level": "expiring", "image": image,
                                 "text": "%s:%s (cycle %s) goes out of support on %s, in %d days"
                                         % (image, version, entry["cycle"], eol, days)})
        companion_verdict(repo, pins, findings)

    held = waivers(a.waivers)
    for f in findings:
        w = waiver_for(held, f["repo"], f["image"])
        if not w or f["level"] not in ("expired", "expiring"):
            continue
        due = w.get("review_by", "")
        if due and due <= TODAY.isoformat():
            f["text"] += " — the hold on %s was to be looked at by %s, and that date has passed" % (
                w.get("pinned", "?"), due)
            continue
        f["level"] = "held"
        f["waiver"] = w
        f["text"] += " — held on purpose, next look %s" % (due or "unscheduled")

    order = {"expired": 0, "expiring": 1, "unknown": 2, "held": 4}
    findings.sort(key=lambda f: (order.get(f["level"], 3), f["repo"]))

    lines = ["## Fleet lifecycle — %s" % TODAY.isoformat(), "",
             "%d pinned data stores across %d repositories, read against their vendors' own support calendars."
             % (checked, len(repos)), ""]
    if not findings:
        lines.append("- every pinned data store is inside its supported window")
    for f in findings:
        lines.append("- **%s** — %s%s" % (f["repo"], f["text"],
                                          " — needs a human" if f["level"] in ("expired", "expiring") else ""))
        if f.get("waiver"):
            lines.append("  <br>%s" % f["waiver"].get("reason", ""))
    report = "\n".join(lines) + "\n"
    print(report)

    if a.report:
        open(a.report, "w", encoding="utf-8").write(report)
    if a.js:
        open(a.js, "w", encoding="utf-8").write(json.dumps(
            {"date": TODAY.isoformat(), "checked": checked, "findings": findings}, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write("needs_human=%d\n" % sum(1 for f in findings if f["level"] in ("expired", "expiring")))


if __name__ == "__main__":
    main()
