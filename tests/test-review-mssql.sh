#!/usr/bin/env bash
# SQL Server's notes are read from Microsoft, and "absent" means absent.
#
# Until 2026-11-14 mcr.microsoft.com/mssql/server sat in NO_NOTES and every CU
# move was reviewed on nothing: "no release notes could be read and the
# registry could not be queried either". Both were there. Microsoft keeps a
# build list per release line and a KB article per update, and its registry
# answers anonymously; the reviewer asked it for a token it does not issue.
# The move from CU27 to CU28 also carried two security updates on CU27
# (GDR1, GDR2) that nothing had read.
#
# The reader is a read receipt: every article it read is named with its KB,
# build, date and address. "absent:" is the one answer that says the version
# is not there, and only when Microsoft's own list answered and does not carry
# it. A list that does not answer, or answers with a page in which not one
# update can be found, is no verdict, and is shown here not to say absent.
#
# Offline against stand-in pages first, then live reads, because a reader that
# has never met the real pages is a reader nobody has checked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import importlib.util, sys, types, urllib.error, urllib.request

for name in ("anthropic", "anthropic_federation"):
    if name not in sys.modules:
        mod = types.ModuleType(name)
        if name == "anthropic":
            mod.Anthropic = object
            mod.WorkloadIdentityCredentials = object
        else:
            mod.FEDERATION = {}
            mod.answer = lambda *a, **k: ("", None)
            mod.github_oidc_token = lambda *a, **k: ""
        sys.modules[name] = mod

spec = importlib.util.spec_from_file_location("ur", "scripts/upstream-review.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0
def check(what, got, want):
    global passed, failed
    if got == want:
        print("  PASS: %s" % what); passed += 1
    else:
        print("  FAIL: %s\n        got %r, wanted %r" % (what, got, want)); failed += 1

LIST = "https://example.test/sql-server-2022/kb5023451-build-versions"
HEAD = ("<tr><th>Cumulative update name</th><th>SQL Server build version</th><th>SQL Server (sqlservr.exe) file version</th>"
        "<th>Knowledge Base number</th><th>Release date</th></tr>")
def row(name, build, kb, date, href):
    return ('<tr><td><a href="%s">%s</a></td><td>%s</td><td>2022.160.x</td><td>%s</td><td>%s</td></tr>'
            % (href, name, build, kb, date))
# GDR2 is listed before GDR1 on purpose: the number comes from the build.
BUILDS = "<html><main><table>" + HEAD + "".join([
    row("CU28 (Latest)", "16.0.4325.4", "KB5125472", "November 12, 2026", "cumulative-update/kb5125472-cu28"),
    row("CU27", "16.0.4295.3", "KB5104824", "September 15, 2026", "cumulative-update/kb5104824-cu27"),
    row("CU27 + GDR", "16.0.4315.2", "KB5129300", "November 10, 2026", "cumulative-update/kb5129300-gdr-nov"),
    row("CU27 + GDR", "16.0.4305.5", "KB5126934", "October 13, 2026", "cumulative-update/kb5126934-gdr-oct"),
    row("CU26", "16.0.4265.3", "KB5093420", "July 16, 2026", "cumulative-update/kb5093420-cu26"),
]) + "</table></main></html>"
def article(title, summary, fixes):
    trs = "".join("<tr><td>%s</td><td>%s</td><td>SQL Server Engine</td><td>Backup Restore</td><td>%s</td></tr>" % f for f in fixes)
    return ("<html><main><h1>%s</h1><ul><li>Summary</li><li>Known issues in this update</li></ul>"
            "<h2>Summary</h2><p>%s</p><h2>Known issues in this update</h2><p>No known issues.</p>"
            "<h2>Improvements and fixes included in this update</h2>"
            "<p>A downloadable Microsoft Excel workbook ...</p>"
            "<table><tr><th>Bug reference</th><th>Description</th><th>Fix area</th><th>Component</th><th>Platform</th></tr>%s</table>"
            "<h2>How to obtain or download the latest cumulative update package for Linux</h2><p>INSTALL STEPS</p></main></html>"
            % (title, summary, trs))
PAGES = {
    LIST: BUILDS,
    "https://example.test/sql-server-2022/cumulative-update/kb5125472-cu28": article(
        "KB5125472 - Cumulative Update 28", "This update contains 91 fixes.",
        [("5571551", "Fixes a VDI out-of-bounds write.", "All"),
         ("5216517", "Fixes a Windows-only monitoring query.", "Windows"),
         ("5596464", "Fixes an out-of-bounds read on client connection requests.", "All")]),
    "https://example.test/sql-server-2022/cumulative-update/kb5129300-gdr-nov": article(
        "KB5129300 - security update for CU27", "CVE-2026-116942 - Remote Code Execution",
        [("5270202", "Fixes an out-of-bounds read on client connection requests.", "Linux, Windows")]),
    "https://example.test/sql-server-2022/cumulative-update/kb5126934-gdr-oct": article(
        "KB5126934 - security update for CU27", "CVE-2026-94512 - Remote Code Execution",
        [("5571550", "Fixes a VDI out-of-bounds write.", "Linux, Windows")]),
}

def stand_in(pages, refuse=()):
    asked = []
    def web(url, timeout=30):
        asked.append(url)
        if url in refuse or url not in pages:
            raise urllib.error.URLError("refused by the stand-in")
        return pages[url]
    return web, asked

real_web, real_lists = m.web, dict(m.MSSQL_BUILD_LISTS)
m.MSSQL_BUILD_LISTS["2022"] = LIST

print("=== a CU move reads every update after the pin, newest first ===")
m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04@sha256:4402d880", "2022-CU28-ubuntu-22.04")
heads = [l for l in (text or "").split("\n") if l.startswith("### ")]
check("no problem when every page answers", problem, None)
check("CU28 and both CU27 security updates, newest first", heads, [
    "### CU28 - KB5125472, build 16.0.4325.4, 2026-11-12",
    "### CU27 GDR2 - KB5129300, build 16.0.4315.2, 2026-11-10",
    "### CU27 GDR1 - KB5126934, build 16.0.4305.5, 2026-10-13"])
check("each article names the address it was read from",
      all(("read from https://example.test/sql-server-2022/cumulative-update/" in (text or "").split(h, 1)[1].split("\n")[1]) for h in heads), True)
check("the list it came from is named first", (text or "").startswith("(from Microsoft's SQL Server 2022 build list, %s)" % LIST), True)
check("a Windows-only fix is left out", "Windows-only monitoring" in (text or ""), False)
check("and counted where it was left out", "2 fixes apply on Linux and are listed, 1 Windows-only fixes left out" in (text or ""), True)
check("a fix for All and one for Linux, Windows are both kept",
      "5571551" in (text or "") and "5270202" in (text or ""), True)
check("the CVE summary of a security update is read", "CVE-2026-116942" in (text or ""), True)
check("the article's own table of contents is not read as its summary",
      (text or "").count("Known issues in this update"), 3)
check("nothing after 'How to obtain' is read", "INSTALL STEPS" in (text or ""), False)
check("the pinned CU itself is not read as a change", "KB5104824" in (text or ""), False)
check("no article is read twice", len(asked), len(set(asked)))

m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU27-GDR2-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
check("from a security update, only what came after it is read",
      [l for l in (text or "").split("\n") if l.startswith("### ")], ["### CU28 - KB5125472, build 16.0.4325.4, 2026-11-12"])
m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU27-GDR1-ubuntu-22.04")
check("GDR1 is the lower build, whatever order the page lists them in",
      [l for l in (text or "").split("\n") if l.startswith("### ")], ["### CU27 GDR1 - KB5126934, build 16.0.4305.5, 2026-10-13"])
m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU9-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
check("a pin the list no longer names reads the target alone and says so",
      problem is None and "is read alone, with no baseline" in text and text.count("### ") == 1, True)

print()
print("=== absent is said only when Microsoft's own list answered ===")
m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU28-ubuntu-22.04", "2022-CU99-ubuntu-22.04")
check("a CU the list does not carry is absent", (problem or "").startswith("absent: "), True)
check("and the answer names the newest update the list does carry",
      "the newest update it lists is CU28, build 16.0.4325.4, 2026-11-12" in (problem or ""), True)
check("and no article is fetched for it", asked, [LIST])
m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU28-ubuntu-22.04", "2022-CU28-GDR1-ubuntu-22.04")
check("a security update the list does not carry yet is absent", (problem or "").startswith("absent: ") and "CU28 GDR1" in problem, True)

m.web, asked = stand_in(PAGES, refuse=(LIST,))
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
check("a list that does not answer is not absent", (problem or "absent").startswith("absent"), False)
check("it says it could not be read and that this is no verdict",
      "could not be read" in (problem or "") and "no verdict" in (problem or ""), True)
m.web, asked = stand_in(dict(PAGES, **{LIST: "<html><main><p>We moved this page.</p></main></html>"}))
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
check("a list that answers with no update in it is not absent", (problem or "absent").startswith("absent"), False)
check("it says the page changed shape", "changed shape" in (problem or ""), True)
m.web, asked = stand_in({LIST: BUILDS})
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
check("when no article answers, the move is no verdict, not absent",
      problem is not None and not problem.startswith("absent") and "no verdict" in problem, True)
m.web, asked = stand_in(PAGES, refuse=("https://example.test/sql-server-2022/cumulative-update/kb5129300-gdr-nov",))
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
check("one article that does not answer keeps its heading and says so",
      problem is None and "### CU27 GDR2 - KB5129300" in text and "could not be read: URLError" in text, True)
m.web, asked = stand_in(PAGES)
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2019-CU32-ubuntu-20.04")
check("a line with no known list names the line and is no verdict",
      text is None and "SQL Server 2019 line" in (problem or "") and not problem.startswith("absent"), True)
check("and asks nothing of the network", asked, [])
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-latest")
check("a floating tag names no update to match", text is None and "names no cumulative update" in (problem or ""), True)

print()
print("=== a link read off a page leads only back to the same host ===")
# The real web(), with the network replaced: what is refused is refused
# before anything is asked of the network.
m.web = real_web
fetched = []
def fetch(url, timeout=30):
    fetched.append(url)
    return dict(PAGES, **{LIST: OFFSITE}).get(url, "")
OFFSITE = BUILDS.replace("cumulative-update/kb5129300-gdr-nov", "file:///etc/passwd").replace(
    "cumulative-update/kb5126934-gdr-oct", "https://169.254.169.254/metadata")
real_fetch = m._fetch
m._fetch = fetch
try:
    text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU28-ubuntu-22.04")
    check("a row linking a file is not fetched", "file:///etc/passwd" in fetched, False)
    check("a row linking another host is not fetched", any("169.254" in u for u in fetched), False)
    check("each says why it was not read",
          (text or "").count("could not be read: ValueError: refused") == 2, True)
    check("the article on the list's own host is still read", "### CU28 - KB5125472" in (text or "") and "5571551" in (text or ""), True)
    for url in ("http://example.test/sql-server-2022/x", "https://example.test.evil/x", "ftp://example.test/x"):
        try:
            m.web(url); refused = False
        except ValueError:
            refused = True
        check("refused before any request: %s" % url, refused and url not in fetched, True)
finally:
    m._fetch = real_fetch
try:
    m._SameHostsRedirect().redirect_request(urllib.request.Request(LIST), None, 302, "Found", {}, "https://169.254.169.254/")
    redirected = True
except ValueError:
    redirected = False
check("a redirect off the host is refused", redirected, False)
m.web, asked = stand_in(PAGES)

print()
print("=== Microsoft's registry is read without a token ===")
calls = []
def no_network(req, timeout=None):
    calls.append(req)
    raise AssertionError("the network was asked")
real_urlopen = urllib.request.urlopen
urllib.request.urlopen = no_network
try:
    check("no token is asked of mcr.microsoft.com", m._token("mcr.microsoft.com", "mssql/server"), None)
    check("and nothing was requested to find that out", calls, [])
    try:
        m._get("mcr.microsoft.com", "mssql/server", "manifests", "2022-CU28-ubuntu-22.04", None)
    except AssertionError:
        pass
    sent = calls[-1] if calls else None
    check("a request without a token carries no Authorization header",
          sent is not None and sent.get_header("Authorization") is None, True)
finally:
    urllib.request.urlopen = real_urlopen

print()
print("=== the tables agree ===")
check("SQL Server is no longer declared unreadable", "mcr.microsoft.com/mssql/server" in m.NO_NOTES, False)
check("no image is both read from the web and mapped or declared unmappable",
      sorted(set(m.WEB_NOTES) & (set(m.SOURCES) | set(m.NO_NOTES))), [])
check("every web source names a reader that exists", all(v in m.WEB_READERS for v in m.WEB_NOTES.values()), True)
src = open("scripts/upstream-review.py", encoding="utf-8").read()
check("main() reads WEB_NOTES before NO_NOTES",
      0 < src.find("if image in WEB_NOTES:") < src.find("elif image in NO_NOTES:"), True)

print()
print("=== live: the list is the right one, proven by the image itself ===")
m.web, m.MSSQL_BUILD_LISTS = real_web, real_lists
try:
    rows = m.mssql_builds(m.web(m.MSSQL_BUILD_LISTS["2022"]), m.MSSQL_BUILD_LISTS["2022"])
except Exception as e:
    rows = []
    print("  (live list raised %s: %s)" % (e.__class__.__name__, e))
by = {r["name"]: r["build"] for r in rows}
for tag, name in (("2022-CU27-ubuntu-22.04", "CU27"), ("2022-CU27-GDR1-ubuntu-22.04", "CU27 GDR1")):
    try:
        label = (m.image_config("mcr.microsoft.com/mssql/server", tag).get("Labels") or {}).get("com.microsoft.version")
    except Exception as e:
        label = "unreadable (%s)" % e.__class__.__name__
    check("%s on MCR is the build Microsoft lists for %s" % (tag, name), label, by.get(name, "not listed"))
text, problem = m.mssql_notes("2022-CU26-ubuntu-22.04", "2022-CU27-ubuntu-22.04")
check("CU26 -> CU27 reads KB5104824 live",
      problem is None and "### CU27 - KB5104824, build 16.0.4295.3, 2026-09-15" in (text or ""), True)
text, problem = m.mssql_notes("2022-CU27-ubuntu-22.04", "2022-CU99-ubuntu-22.04")
check("a CU that does not exist is absent live", (problem or "").startswith("absent: "), True)

print("\npassed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
