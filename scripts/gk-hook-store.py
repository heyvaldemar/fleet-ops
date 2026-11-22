#!/usr/bin/env python3
"""gk-hook-store.py — what the GitKraken CLI keeps of a Claude Code session.

    gk-hook-store.py run --gk PATH --out DIR [--summary FILE] [--strace PATH]
    gk-hook-store.py scan ROOT MARK...        which files under ROOT hold each mark
    gk-hook-store.py perms ROOT               files or folders others may read
    gk-hook-store.py connects STRACE_LOG      connect() calls in an strace log
    gk-hook-store.py pin VERSION PLATFORM     the pinned URL and sha256 of a gk core, or exit
    gk-hook-store.py check-zip ZIP SHA256     exit unless ZIP has that sha256

WHY. GitKraken Desktop and GitLens show live Claude Code status through a
Claude Code plugin, gitkraken-hooks, that pipes every hook event to
`gk ai hook run --host claude-code`. A hook event carries the prompt, the
command a tool is about to run, that command's output and the agent's last
reply. This measures, on a runner and with synthetic data only, what gk does
with them: what it writes, with which file modes, how long it keeps it, what
`gk ai hook remove-session` takes away, whether deleted text survives in the
SQLite file (and whether it would with SQLite's secure_delete on, tried on a
copy), and whether the hook opens network connections.

Everything runs in a box: HOME, the XDG folders, CLAUDE_CONFIG_DIR and TMPDIR
point into a fresh temporary folder per section, so gk finds no account, no
GitKraken window to talk to and no earlier state. No plugin is installed:
the events are handed to gk on stdin exactly as Claude Code would hand them.

EACH CHECK IS SHOWN WHAT IT LOOKS FOR before it is believed: the mark search
finds a mark in a file and in a deleted SQLite row and loses it after VACUUM
or when the row was deleted with secure_delete on, the mode check flags a planted 0644 file, the connect counter counts a planted
connection. A plant the check misses fails the run. What gk does is recorded,
not asserted: the run fails only when a check cannot see.
"""
import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd")
MARKS = {
    "prompt": "MARK-PROMPT-7f3a",
    "command": "MARK-COMMAND-9b1c",
    "stdout": "MARK-STDOUT-6e8f",
    "reply": "MARK-REPLY-2c5a",
    "transcript": "MARK-TRANSCRIPT-4d2e",
}


# ------------------------------------------------------------- detectors --

def scan(root, marks):
    """Every file under root whose raw bytes hold a mark: SQLite pages and WAL included."""
    found = {m: [] for m in marks}
    enc = {m: m.encode() for m in marks}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            try:
                with open(p, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            for m in marks:
                if enc[m] in data:
                    found[m].append(os.path.relpath(p, root))
    return {m: sorted(v) for m, v in found.items()}


def perms(root, only=None):
    """Files with any group or other bit, and folders with any, under root."""
    bad, seen = [], []
    for d, dirs, files in os.walk(root):
        for name in dirs + files:
            p = os.path.join(d, name)
            rel = os.path.relpath(p, root)
            if only and only not in rel:
                continue
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                continue
            mode = stat.S_IMODE(st.st_mode)
            kind = "dir" if stat.S_ISDIR(st.st_mode) else "file"
            seen.append({"path": rel, "kind": kind, "mode": "%04o" % mode})
            if mode & 0o077:
                bad.append({"path": rel, "kind": kind, "mode": "%04o" % mode})
    return {"checked": len(seen), "open_to_others": bad, "modes": sorted({s["kind"] + " " + s["mode"] for s in seen})}


CONNECT = re.compile(r'connect\(\d+, \{sa_family=(AF_INET6?)[^}]*?(?:sin6?_port=htons\((\d+)\))[^}]*?'
                     r'(?:inet_addr\("([^"]+)"\)|inet_pton\(AF_INET6, "([^"]+)")')


def connects(log_text):
    """connect() calls to an IP address in an strace log; local sockets are not counted."""
    calls = []
    for line in log_text.splitlines():
        m = CONNECT.search(line)
        if not m:
            continue
        family, port, v4, v6 = m.groups()
        addr = v4 or v6
        calls.append({"family": family, "addr": addr, "port": int(port),
                      "dns": int(port) == 53, "loopback": addr.startswith("127.") or addr == "::1"})
    return {"attempts": len(calls),
            "dns": sum(1 for c in calls if c["dns"]),
            "outside": sorted({"%s:%d" % (c["addr"], c["port"]) for c in calls if not c["loopback"] and not c["dns"]}),
            "calls": calls}


# ------------------------------------------------------------------ boxes --

class Box:
    def __init__(self, gk, base, name, umask=0o022):
        self.gk, self.umask = gk, umask
        self.root = os.path.join(base, name)
        self.home = os.path.join(self.root, "home")
        self.work = os.path.join(self.root, "work")
        for d in (self.home, self.work, os.path.join(self.root, "claude"), os.path.join(self.root, "tmp")):
            os.makedirs(d, exist_ok=True)
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home,
            "CLAUDE_CONFIG_DIR": os.path.join(self.root, "claude"),
            "TMPDIR": os.path.join(self.root, "tmp"),
            "LC_ALL": "C",
        }
        # On Linux these are the XDG defaults under the box's HOME, set so a
        # runner's own XDG settings cannot point gk outside it. macOS has no
        # XDG defaults and gk honours some of these there, so they stay unset
        # and gk picks the folders it uses on a Mac (under ~/Library).
        if sys.platform != "darwin":
            self.env.update({
                "XDG_CONFIG_HOME": os.path.join(self.home, ".config"),
                "XDG_CACHE_HOME": os.path.join(self.home, ".cache"),
                "XDG_DATA_HOME": os.path.join(self.home, ".local", "share"),
                "XDG_STATE_HOME": os.path.join(self.home, ".local", "state"),
            })

    def gk_run(self, args, stdin=None, extra_env=None, prefix=(), timeout=60):
        env = dict(self.env, **(extra_env or {}))
        um = self.umask
        return subprocess.run(list(prefix) + [self.gk] + list(args), input=stdin, env=env, capture_output=True,
                              text=True, timeout=timeout, preexec_fn=lambda: os.umask(um))

    def event(self, sid, name, flags=("--no-telemetry",), extra_env=None, prefix=(), transcript=None, timeout=60,
              **fields):
        d = {"session_id": sid, "hook_event_name": name, "cwd": self.work,
             "transcript_path": transcript or os.path.join(self.work, "transcript.jsonl"),
             "permission_mode": "default"}
        d.update(fields)
        return self.gk_run(["ai", "hook", "run", "--host", "claude-code"] + list(flags), stdin=json.dumps(d),
                           extra_env=extra_env, prefix=prefix, timeout=timeout)

    def find(self, name):
        for d, _, files in os.walk(self.home):
            if name in files:
                return os.path.join(d, name)
        return None

    def session_file(self, sid):
        for d, _, files in os.walk(self.home):
            if sid + ".json" in files:
                return os.path.join(d, sid + ".json")
        return None


def full_session(box, sid, marks, transcript=None):
    """The six events of one short session, each carrying its own mark."""
    seen = []
    payloads = {
        "SessionStart": {"source": "startup"},
        "UserPromptSubmit": {"prompt": marks["prompt"] + " add a note and commit it"},
        "PreToolUse": {"tool_name": "Bash", "tool_input": {"command": "git commit -m " + marks["command"]}},
        "PostToolUse": {"tool_name": "Bash", "tool_input": {"command": "git commit -m " + marks["command"]},
                        "tool_response": {"stdout": marks["stdout"] + " [main abc1234] note", "stderr": ""}},
        "Stop": {"stop_hook_active": False, "last_assistant_message": marks["reply"] + " committed the note"},
        "SessionEnd": {"reason": "other"},
    }
    for name in EVENTS:
        p = box.event(sid, name, transcript=transcript, **payloads[name])
        seen.append({"event": name, "exit": p.returncode,
                     "found": {k: [f.replace(os.sep, "/") for f in v] for k, v in scan(box.home, marks.values()).items()}})
    return seen


# ------------------------------------------------------------- sections --

def section_fields(gk, base):
    box = Box(gk, base, "fields")
    tr = os.path.join(box.work, "transcript.jsonl")
    with open(tr, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": MARKS["transcript"]}}) + "\n")
    stages = full_session(box, "11111111-2222-3333-4444-555555555555", MARKS, transcript=tr)
    names = {v: k for k, v in MARKS.items()}
    table = []
    for s in stages:
        row = {"after": s["event"], "exit": s["exit"]}
        for mark, files in s["found"].items():
            row[names[mark]] = sorted({re.sub(r"[0-9a-f-]{36}", "<id>", f) for f in files})
        table.append(row)
    # A transcript that cannot be read without blocking: a named pipe with no writer.
    fifo_box = Box(gk, base, "fifo")
    fifo = os.path.join(fifo_box.work, "transcript.jsonl")
    os.mkfifo(fifo)
    opened = []
    for name in EVENTS:
        t0 = time.time()
        try:
            p = fifo_box.event("22222222-2222-3333-4444-555555555555", name, transcript=fifo, timeout=10,
                               prompt="p", source="startup", reason="other")
            opened.append({"event": name, "exit": p.returncode, "seconds": round(time.time() - t0, 2)})
        except subprocess.TimeoutExpired:
            opened.append({"event": name, "exit": "timeout", "seconds": round(time.time() - t0, 2)})
    return {"after_each_event": table, "transcript_as_fifo": opened}


def section_perms(gk, base):
    out = {}
    for um in (0o022, 0o077):
        box = Box(gk, base, "perms-%04o" % um, umask=um)
        full_session(box, "33333333-2222-3333-4444-555555555555", MARKS)
        res = perms(box.home, only="GitKrakenCLI")
        # An open file matters by what it holds: say whether it holds any mark.
        for b in res["open_to_others"]:
            if b["kind"] == "file":
                data = open(os.path.join(box.home, b["path"]), "rb").read()
                b["holds_a_mark"] = any(m.encode() in data for m in MARKS.values())
        out["umask %04o" % um] = res
    return out


def _age(box, sid, days, db=True, js=True):
    t = int(time.time()) - days * 86400
    if db:
        con = sqlite3.connect(box.find("cache.db"))
        con.execute("update ai_sessions set updated_at=?, ended_at=? where session_id=?", (t, t, sid))
        con.commit()
        con.close()
    if js:
        p = box.session_file(sid)
        d = json.load(open(p))
        iso = datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for k in ("endedAt", "updatedAt"):
            d[k] = iso
        json.dump(d, open(p, "w"))


def _present(box, sid):
    con = sqlite3.connect(box.find("cache.db"))
    row = con.execute("select status from ai_sessions where session_id=?", (sid,)).fetchone()
    con.close()
    return {"json": box.session_file(sid) is not None, "db_row": row is not None}


def section_retention(gk, base):
    """Ended sessions aged by editing their timestamps; gk's own cleanup does the rest.

    gk throttles its cleanup to once per 30 s through a row in its cache, so
    the trigger comes 35 s after the last write, and no throttle is touched.
    """
    box = Box(gk, base, "retention")
    cases = {
        "31 days, both timestamps": ("aaaaaaaa-0000-0000-0000-000000000031", 31, True, True),
        "29 days, both timestamps": ("aaaaaaaa-0000-0000-0000-000000000029", 29, True, True),
        "31 days, database only": ("aaaaaaaa-0000-0000-0000-0000000000d1", 31, True, False),
        "31 days, JSON only": ("aaaaaaaa-0000-0000-0000-0000000000a1", 31, False, True),
    }
    for sid, *_ in cases.values():
        for name in ("SessionStart", "UserPromptSubmit", "SessionEnd"):
            box.event(sid, name, source="startup", prompt="p", reason="other")
    for sid, days, db, js in cases.values():
        _age(box, sid, days, db, js)
    before = {k: _present(box, v[0]) for k, v in cases.items()}
    time.sleep(35)
    box.event("bbbbbbbb-0000-0000-0000-000000000001", "SessionStart", source="startup")
    after = {k: _present(box, v[0]) for k, v in cases.items()}
    return {"aged_fields": {"database": "ai_sessions.ended_at and updated_at", "json": "endedAt and updatedAt"},
            "before": before, "after_cleanup": after}


def section_remove(gk, base):
    box = Box(gk, base, "remove")
    sid = "cccccccc-0000-0000-0000-000000000001"
    full_session(box, sid, MARKS)
    db = box.find("cache.db")
    store = os.path.dirname(db)
    out = {"before_remove": {k: v for k, v in scan(box.home, [MARKS["prompt"]]).items()}}
    pre = os.path.join(base, "remove-pre")
    os.makedirs(pre)
    for f in os.listdir(store):
        if f.startswith("cache.db"):
            shutil.copy2(os.path.join(store, f), pre)
    p = box.gk_run(["ai", "hook", "remove-session", sid, "--no-telemetry"])
    out["remove_session_exit"] = p.returncode
    out["after_remove"] = {"present": _present(box, sid),
                           "mark_in_store_files": scan(store, [MARKS["prompt"]])[MARKS["prompt"]]}
    con = sqlite3.connect(db)
    out["freelist_pages"] = con.execute("pragma freelist_count").fetchone()[0]
    out["journal_mode"] = con.execute("pragma journal_mode").fetchone()[0]
    out["secure_delete_default_of_this_reader"] = con.execute("pragma secure_delete").fetchone()[0]
    con.close()
    copy = os.path.join(base, "remove-copy")
    os.makedirs(copy, exist_ok=True)
    for f in os.listdir(store):
        if f.startswith("cache.db"):
            shutil.copy2(os.path.join(store, f), copy)
    c = sqlite3.connect(os.path.join(copy, "cache.db"))
    c.execute("pragma wal_checkpoint(TRUNCATE)")
    c.close()
    out["copy_after_checkpoint"] = scan(copy, [MARKS["prompt"]])[MARKS["prompt"]]
    c = sqlite3.connect(os.path.join(copy, "cache.db"))
    c.execute("vacuum")
    c.close()
    out["copy_after_vacuum"] = scan(copy, [MARKS["prompt"]])[MARKS["prompt"]]
    # What secure_delete would change. It is a setting of the connection that
    # deletes, not of the file, so gk's own connection decides; this deletes
    # the same session row from a copy taken before remove-session, once with
    # it off (as gk left the file) and once with it on. The file is scanned
    # after the commit with the connection still open (the WAL holds the new
    # page, the main file may still hold the old one) and after the close
    # (SQLite checkpoints a WAL file when its last connection closes).
    out["secure_delete_on_a_copy"] = {"copy_before_remove": scan(pre, [MARKS["prompt"]])[MARKS["prompt"]]}
    for mode in ("off", "on"):
        d = os.path.join(base, "remove-sd-" + mode)
        shutil.copytree(pre, d)
        c = sqlite3.connect(os.path.join(d, "cache.db"))
        c.execute("pragma secure_delete=%s" % mode)
        got = c.execute("pragma secure_delete").fetchone()[0]
        n = c.execute("delete from ai_sessions where session_id = ?", (sid,)).rowcount
        c.commit()
        committed = scan(d, [MARKS["prompt"]])[MARKS["prompt"]]
        c.close()
        out["secure_delete_on_a_copy"][mode] = {
            "pragma_reads": got, "rows_deleted": n, "after_commit_connection_open": committed,
            "after_close": scan(d, [MARKS["prompt"]])[MARKS["prompt"]]}
    return out


def section_network(gk, base, strace):
    if not strace:
        return {"measured": False, "why": "no strace on this machine"}
    out = {}
    # The counter is shown a connection first: a TCP connect to a TEST-NET
    # address (RFC 5737), which goes nowhere.
    log = os.path.join(base, "plant.strace")
    subprocess.run([strace, "-f", "-qq", "-e", "trace=connect", "-o", log, sys.executable, "-c",
                    "import socket; s=socket.socket(); s.settimeout(1); s.connect_ex(('192.0.2.1', 9))"],
                   capture_output=True)
    plant = connects(open(log).read())
    out["plant"] = {"attempts": plant["attempts"], "outside": plant["outside"]}
    modes = {"default": ((), None), "--no-telemetry": (("--no-telemetry",), None),
             "GK_CLI_NO_TELEMETRY=1": ((), {"GK_CLI_NO_TELEMETRY": "1"})}
    for label, (flags, env) in modes.items():
        box = Box(gk, base, "net-" + re.sub(r"\W+", "-", label).strip("-"))
        log = os.path.join(box.root, "gk.strace")
        total = {"attempts": 0, "dns": 0, "outside": set()}
        for loop in range(5):
            for name in EVENTS:
                lg = "%s.%d.%s" % (log, loop, name)
                box.event("dddddddd-0000-0000-0000-00000000000%d" % loop, name, flags=flags, extra_env=env,
                          prefix=(strace, "-f", "-qq", "-e", "trace=connect", "-o", lg),
                          source="startup", prompt="p", reason="other")
                c = connects(open(lg).read())
                total["attempts"] += c["attempts"]
                total["dns"] += c["dns"]
                total["outside"].update(c["outside"])
        out[label] = {"events": 30, "connect_attempts": total["attempts"], "dns_attempts": total["dns"],
                      "outside_destinations": sorted(total["outside"])}
    return out


# -------------------------------------------------------------- run ------

def self_test(base):
    """The detectors, shown what they look for. Any miss ends the run."""
    t = os.path.join(base, "self-test")
    os.makedirs(t)
    misses = []
    with open(os.path.join(t, "plain.txt"), "w") as fh:
        fh.write("x MARK-PLANT-1 y")
    db = os.path.join(t, "plant.db")
    con = sqlite3.connect(db)
    con.execute("pragma secure_delete=off")
    con.execute("create table t(v text)")
    con.execute("insert into t values (?)", ("MARK-PLANT-2" * 50,))
    con.execute("insert into t values (?)", ("keep" * 50,))
    con.commit()
    con.execute("delete from t where v like 'MARK-PLANT-2%'")
    con.commit()
    con.close()
    s = scan(t, ["MARK-PLANT-1", "MARK-PLANT-2", "MARK-NEVER"])
    if s["MARK-PLANT-1"] != ["plain.txt"]:
        misses.append("scan missed a mark in a plain file")
    if s["MARK-PLANT-2"] != ["plant.db"]:
        misses.append("scan missed a mark in a deleted SQLite row")
    if s["MARK-NEVER"]:
        misses.append("scan found a mark that was never written")
    con = sqlite3.connect(db)
    con.execute("vacuum")
    con.close()
    if scan(t, ["MARK-PLANT-2"])["MARK-PLANT-2"]:
        misses.append("a deleted row survived VACUUM in the plant, so the scan cannot tell")
    con = sqlite3.connect(os.path.join(t, "wiped.db"))
    con.execute("pragma secure_delete=on")
    con.execute("create table t(v text)")
    con.execute("insert into t values (?)", ("MARK-PLANT-3" * 50,))
    con.execute("insert into t values (?)", ("keep" * 50,))
    con.commit()
    con.execute("delete from t where v like 'MARK-PLANT-3%'")
    con.commit()
    con.close()
    if scan(t, ["MARK-PLANT-3"])["MARK-PLANT-3"]:
        misses.append("this SQLite kept a row deleted with secure_delete on, so that check cannot tell")
    os.makedirs(os.path.join(t, "GitKrakenCLI"), mode=0o700)
    loose = os.path.join(t, "GitKrakenCLI", "loose.json")
    open(loose, "w").close()
    os.chmod(loose, 0o644)
    if not any(b["path"].endswith("loose.json") for b in perms(t, only="GitKrakenCLI")["open_to_others"]):
        misses.append("perms missed a 0644 file")
    sample = ('123 connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.9")}, 16) = -1\n'
              '123 connect(4, {sa_family=AF_UNIX, sun_path="/run/x.sock"}, 110) = 0\n'
              '124 connect(5, {sa_family=AF_INET6, sin6_port=htons(53), sin6_flowinfo=htonl(0), '
              'inet_pton(AF_INET6, "::1", &sin6_addr), sin6_scope_id=0}, 28) = 0\n')
    c = connects(sample)
    if c["attempts"] != 2 or c["outside"] != ["203.0.113.9:443"] or c["dns"] != 1:
        misses.append("the connect counter misread its sample: %s" % c)
    return misses


def environment(gk, strace):
    def out(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip().splitlines()[0]
        except Exception as e:
            return "unavailable: %s" % e
    env = {"gk": gk, "gk_version": out([gk, "version"]),
           "gk_sha256": hashlib.sha256(open(gk, "rb").read()).hexdigest(),
           "machine": platform.machine(), "system": platform.platform(),
           "python_sqlite": sqlite3.sqlite_version, "strace": out([strace, "-V"]) if strace else None}
    try:
        with open("/etc/os-release") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    env["os"] = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    for k in ("ImageOS", "ImageVersion", "RUNNER_ARCH", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_SHA",
              "GK_VERSION", "GK_URL", "GK_ZIP_SHA256"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def markdown(r):
    lines = ["## What gk keeps of a Claude Code session", "",
             "%s, %s, %s. Synthetic events only, one fresh box per section." % (
                 r["environment"]["gk_version"], r["environment"].get("os", r["environment"]["system"]),
                 r["environment"]["machine"]), "",
             "| after | prompt | command | stdout | reply | transcript |", "|---|---|---|---|---|---|"]
    for row in r["fields"]["after_each_event"]:
        lines.append("| %s | %s |" % (row["after"], " | ".join(
            "yes" if row.get(k) else "-" for k in ("prompt", "command", "stdout", "reply", "transcript"))))
    lines += ["", "Modes: " + "; ".join("%s: %s, open to others %d" % (k, ", ".join(v["modes"]), len(v["open_to_others"]))
                                         for k, v in r["perms"].items()), ""]
    lines += ["Retention: " + "; ".join("%s → json %s, db %s" % (k, v["json"], v["db_row"])
                                         for k, v in r["retention"]["after_cleanup"].items()), ""]
    rm = r["remove"]
    lines += ["remove-session: record %s; prompt mark in store files %s; after checkpoint %s; after VACUUM %s" % (
        rm["after_remove"]["present"], rm["after_remove"]["mark_in_store_files"], rm["copy_after_checkpoint"],
        rm["copy_after_vacuum"]), ""]
    sd = rm["secure_delete_on_a_copy"]
    lines += ["The same row deleted from a copy taken before remove-session: " + "; ".join(
        "secure_delete %s → after commit %s, after close %s" % (k, v["after_commit_connection_open"], v["after_close"])
        for k, v in sd.items() if k != "copy_before_remove"), ""]
    net = r["network"]
    if net.get("measured", True):
        lines += ["Network (plant: %d attempt(s)): " % net["plant"]["attempts"] + "; ".join(
            "%s: %d connect(), %d DNS, outside %s" % (k, v["connect_attempts"], v["dns_attempts"], v["outside_destinations"] or "none")
            for k, v in net.items() if k != "plant")]
    else:
        lines += ["Network: not measured (%s)" % net["why"]]
    return "\n".join(lines) + "\n"


def run(args):
    os.makedirs(args.out, exist_ok=True)
    base = tempfile.mkdtemp(prefix="gk-hook-store-")
    misses = self_test(base)
    if misses:
        raise SystemExit("the checks cannot see: " + "; ".join(misses))
    strace = args.strace or shutil.which("strace")
    r = {"measured": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
         "environment": environment(args.gk, strace),
         "marks": MARKS,
         "fields": section_fields(args.gk, base),
         "perms": section_perms(args.gk, base),
         "retention": section_retention(args.gk, base),
         "remove": section_remove(args.gk, base),
         "network": section_network(args.gk, base, strace)}
    for mode, v in r["remove"]["secure_delete_on_a_copy"].items():
        if mode == "copy_before_remove":
            if not v:
                raise SystemExit("the copy taken before remove-session holds no prompt mark")
            continue
        if v["rows_deleted"] != 1 or v["pragma_reads"] != (1 if mode == "on" else 0):
            raise SystemExit("the secure_delete copy (%s) did not delete one row as asked: %s" % (mode, v))
    if r["network"].get("measured", True) and r["network"]["plant"]["attempts"] < 1:
        raise SystemExit("the connect counter did not see its planted connection")
    with open(os.path.join(args.out, "result.json"), "w") as fh:
        json.dump(r, fh, indent=2)
        fh.write("\n")
    md = markdown(r)
    with open(os.path.join(args.out, "result.md"), "w") as fh:
        fh.write(md)
    if args.summary:
        with open(args.summary, "a") as fh:
            fh.write(md)
    print(md)


# ------------------------------------------------------------ the core ---

PINS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gk-core-pins.json")
PIN_HOST = "https://release.gitkraken.dev/"


def pin_for(version, platform, pins=PINS):
    """The URL and sha256 a gk core may be fetched from and run with, or exit."""
    with open(pins) as fh:
        p = json.load(fh).get(version, {})
    p = p.get(platform) if isinstance(p, dict) else None
    if not isinstance(p, dict):
        raise SystemExit("no pin for gk %s %s in %s: dispatch with record: true, check the sum, add it"
                         % (version, platform, pins))
    url, sha = p.get("url", ""), p.get("sha256", "")
    if not url.startswith(PIN_HOST) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit("the pin for gk %s %s is not an %s URL with a sha256" % (version, platform, PIN_HOST))
    return url, sha


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--gk", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--summary")
    r.add_argument("--strace")
    s = sub.add_parser("scan")
    s.add_argument("root")
    s.add_argument("marks", nargs="+")
    p = sub.add_parser("perms")
    p.add_argument("root")
    c = sub.add_parser("connects")
    c.add_argument("log")
    st = sub.add_parser("self-test")
    st.add_argument("--dir")
    pn = sub.add_parser("pin")
    pn.add_argument("version")
    pn.add_argument("platform")
    pn.add_argument("--pins", default=PINS)
    cz = sub.add_parser("check-zip")
    cz.add_argument("zip")
    cz.add_argument("sha256")
    a = ap.parse_args()
    if a.cmd == "run":
        run(a)
    elif a.cmd == "pin":
        print("%s %s" % pin_for(a.version, a.platform, a.pins))
    elif a.cmd == "check-zip":
        got = sha256_of(a.zip)
        print("core zip sha256: %s" % got)
        if got != a.sha256:
            raise SystemExit("the core zip is not the one pinned (want %s)" % a.sha256)
    elif a.cmd == "scan":
        print(json.dumps(scan(a.root, a.marks)))
    elif a.cmd == "perms":
        print(json.dumps(perms(a.root)))
    elif a.cmd == "connects":
        print(json.dumps(connects(open(a.log).read())))
    else:
        base = a.dir or tempfile.mkdtemp(prefix="gk-hook-store-test-")
        misses = self_test(base)
        print(json.dumps({"misses": misses}))
        sys.exit(1 if misses else 0)


if __name__ == "__main__":
    main()
