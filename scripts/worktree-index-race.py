#!/usr/bin/env python3
"""worktree-index-race.py — two writers in one working tree, or one tree each.

    worktree-index-race.py run --out DIR [--repeats 10] [--commits 20]
                               [--think-ms 50] [--gap-ms 0] [--summary FILE]
    worktree-index-race.py analyze --repo DIR --ref REF [--ref REF ...]

WHY. Two coding agents pointed at one checkout share one index, the staging
area every `git add` writes and every `git commit` reads. Nothing in git says
whose staged file is whose: a commit takes whatever is staged when it runs,
and `.git/index.lock` lets one process at a time write that file and fails
everyone else at once, with no wait. They also share `.git/COMMIT_EDITMSG`,
the file `git commit -m` writes its message to and reads it back from.
`git worktree add` gives each writer its own working tree, its own index and
its own COMMIT_EDITMSG over one object store. This measures what that
difference costs or saves, with scripted writers rather than agents, so the
numbers come from git alone and can be repeated on any runner.

THE WORKLOAD, both modes alike. Each repeat is a fresh repository with one
root commit. Two writers, `a` and `b`, start on the same instant and each
makes --commits commits, one new file per commit under its own directory:

    write a/a-007.txt
    git status --porcelain        (what an agent runs before it stages)
    git add a/a-007.txt
    sleep --gap-ms                 (0: add and commit in one shell command)
    git commit -m "a 007"
    sleep 0..--think-ms            (the agent working on its next change)

Each writer commits as its own author, writer-a or writer-b, so the history
says which process made a commit whatever its message says.

A git call that fails on a lock (`index.lock`, or `cannot lock ref`), or a
commit git aborts for an empty message, is retried up to MAX_RETRIES times
after a short sleep, the way a careful agent would; every failed attempt is
counted and its first line kept, verbatim, with the temporary path replaced
by <tmp>. A commit that answers "nothing to commit" is not retried: its file
has already gone out in the other writer's commit. (If the file is not
tracked at that moment it fell out of the index instead, and is counted as
dropped.) A writer that runs out of retries leaves its file staged, and the
other writer's next commit takes it.

    shared    both writers in the main working tree, on main.
    worktree  `git worktree add -b agent-a` and `-b agent-b`, one each; when
              both are done, main merges the two branches (timed, conflicts
              counted) so the integration step is measured, not assumed free.

WHAT IS COUNTED, per mode, from the repository afterwards and the writers'
own logs. A commit is the work of its author, and its files are judged by
what it adds and deletes, not by its message:
  - commits that add a file of the other writer;
  - commits whose message is the other writer's (read from COMMIT_EDITMSG
    after the other writer rewrote it);
  - commits that delete a file, which nobody in this workload ever asks for;
  - writers that found their own file already committed by the other;
  - files missing from the final tree: never committed, or committed and
    deleted later;
  - lock failures and empty-message aborts by command, retried and given up;
  - the time from a writer starting a change (before `git status`) to the
    commit that adds that file returning, whoever made the commit.

Every git call runs with LC_ALL=C and without the global or system config,
so the messages are git's own English and nothing on the machine (a signing
key, a hook, an alias) takes part. `analyze` reads an existing repository
with the same counter, so the test can plant each finding and watch it
counted.
"""
import argparse
import json
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

MAX_RETRIES = 10
WRITERS = ("a", "b")
SUBJECT = re.compile(r"^([ab]) (\d{3})$")
AUTHOR = re.compile(r"^writer-([ab])$")
LANDED = re.compile(r"^\[[^\]]*?([0-9a-f]{7,})\]", re.M)
RETRIED = ("index_lock", "ref_lock", "empty_message")


def git_env(name="setup"):
    env = dict(os.environ)
    env.update({
        "LC_ALL": "C",
        "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_AUTHOR_NAME": name,
        "GIT_AUTHOR_EMAIL": "%s@example.invalid" % name,
        "GIT_COMMITTER_NAME": name,
        "GIT_COMMITTER_EMAIL": "%s@example.invalid" % name,
    })
    return env


ENV = git_env()


def git(cwd, *args, check=True):
    p = subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise SystemExit("git %s failed in %s: %s" % (" ".join(args), cwd, p.stderr.strip()))
    return p


def classify(text):
    if "cannot lock ref" in text:
        return "ref_lock"
    if "index.lock" in text:
        return "index_lock"
    if "empty commit message" in text:
        return "empty_message"
    if ("nothing to commit" in text or "nothing added to commit" in text
            or "no changes added to commit" in text):
        return "nothing_to_commit"
    return "other"


KEYWORD = {"ref_lock": "cannot lock ref", "index_lock": "index.lock",
           "empty_message": "empty commit message", "nothing_to_commit": "nothing"}


def scrub(text, root):
    """git's text with the repeat's temporary directory replaced by <tmp>.

    The real path first: macOS hands out /var/folders/... and git prints
    /private/var/folders/..., which the shorter spelling would leave half
    replaced.
    """
    return text.replace(os.path.realpath(root), "<tmp>").replace(root, "<tmp>").strip()


def first_line(text, root, kind):
    """The line that says what happened: the first naming the kind, else the first."""
    lines = [l.strip() for l in scrub(text, root).splitlines() if l.strip()]
    for line in lines:
        if KEYWORD.get(kind, "\0") in line:
            return line
    return lines[0] if lines else ""


# ---------------------------------------------------------------- writer --

def writer(args):
    rnd = random.Random(args.seed)
    wenv = git_env("writer-" + args.name)
    log = {"name": args.name, "commits": [], "events": [], "samples": {}}
    while time.time_ns() < args.start_at:
        time.sleep(0.0005)
    for i in range(args.commits):
        rel = "%s/%s-%03d.txt" % (args.name, args.name, i)
        subject = "%s %03d" % (args.name, i)
        rec = {"i": i, "file": rel, "subject": subject, "t_start": time.time_ns(),
               "t_land": None, "sha": None, "outcome": None, "retries": {}}
        os.makedirs(os.path.join(args.dir, args.name), exist_ok=True)
        with open(os.path.join(args.dir, rel), "w", encoding="utf-8") as fh:
            fh.write("%s\n" % subject)

        def call(op, *gargs):
            attempt = 0
            while True:
                p = subprocess.run(["git", *gargs], cwd=args.dir, env=wenv,
                                   capture_output=True, text=True)
                if p.returncode == 0:
                    return p, None
                text = p.stderr + p.stdout
                kind = classify(text)
                log["events"].append({"i": i, "op": op, "kind": kind, "attempt": attempt,
                                      "line": first_line(text, args.root, kind), "t": time.time_ns()})
                log["samples"].setdefault("%s %s" % (op, kind), scrub(text, args.root))
                if kind in RETRIED and attempt < MAX_RETRIES:
                    key = "%s_%s" % (op, kind)
                    rec["retries"][key] = rec["retries"].get(key, 0) + 1
                    attempt += 1
                    time.sleep(0.01 + rnd.random() * 0.03)
                    continue
                return p, kind

        call("status", "status", "--porcelain")
        _, kind = call("add", "add", "--", rel)
        if kind is not None:
            rec["outcome"] = "add_failed_" + kind
            log["commits"].append(rec)
            continue
        if args.gap_ms:
            time.sleep(args.gap_ms / 1000.0)
        p, kind = call("commit", "commit", "-m", subject)
        if kind is None:
            rec["t_land"] = time.time_ns()
            rec["outcome"] = "landed"
            # "[main 1a2b3c4] a 007": the hash is this process's commit; the
            # message after it may not be this writer's, which is the point.
            m = LANDED.search(p.stdout)
            rec["sha"] = m.group(1) if m else None
        elif kind == "nothing_to_commit":
            # Nothing staged: either the file went out in the other writer's
            # commit (it is tracked now), or it fell out of the index without
            # being committed by anyone, which would be a lost update.
            tracked = subprocess.run(["git", "ls-files", "--error-unmatch", "--", rel], cwd=args.dir,
                                     env=wenv, capture_output=True, text=True).returncode == 0
            rec["outcome"] = "taken_by_other" if tracked else "dropped_from_index"
        else:
            rec["outcome"] = "commit_failed_" + kind
        log["commits"].append(rec)
        if args.think_ms:
            time.sleep(rnd.random() * args.think_ms / 1000.0)
    with open(args.log, "w", encoding="utf-8") as fh:
        json.dump(log, fh)


# -------------------------------------------------------------- analysis --

def commits_on(repo, refs):
    """Every non-merge commit a writer made reachable from refs, with what it changed."""
    out = git(repo, "log", "--no-merges", "--format=%H%x09%an%x09%s", *refs).stdout
    rows = []
    for line in out.splitlines():
        sha, author, subject = line.split("\t", 2)
        a = AUTHOR.match(author)
        if not a:
            continue
        s = SUBJECT.match(subject)
        added, deleted = [], []
        for ns in git(repo, "diff-tree", "--no-commit-id", "--name-status", "-r", sha).stdout.splitlines():
            status, _, path = ns.partition("\t")
            (deleted if status == "D" else added).append(path)
        rows.append({"sha": sha, "subject": subject, "maker": a.group(1),
                     "message_of": s.group(1) if s else None, "added": added, "deleted": deleted})
    return rows


def findings(rows, repo, refs):
    foreign = [{"subject": r["subject"], "by": r["maker"],
                "foreign": [f for f in r["added"] if f.split("/", 1)[0] != r["maker"]]} for r in rows]
    foreign = [h for h in foreign if h["foreign"]]
    wrong = [{"subject": r["subject"], "by": r["maker"]} for r in rows if r["message_of"] != r["maker"]]
    deleting = [{"subject": r["subject"], "by": r["maker"], "deleted": r["deleted"]} for r in rows if r["deleted"]]
    tip = set()
    for ref in refs:
        tip |= set(git(repo, "ls-tree", "-r", "--name-only", ref).stdout.split())
    return foreign, wrong, deleting, tip


def analyze(args):
    rows = commits_on(args.repo, args.ref)
    foreign, wrong, deleting, _ = findings(rows, args.repo, args.ref)
    print(json.dumps({"commits": len(rows),
                      "commits_with_foreign_files": len(foreign),
                      "foreign_files": sum(len(h["foreign"]) for h in foreign),
                      "commits_with_the_other_message": len(wrong),
                      "commits_deleting_files": len(deleting),
                      "foreign": foreign, "wrong_message": wrong, "deleting": deleting}))


# ------------------------------------------------------------------ run --

def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(q * (len(s) - 1)))))
    return round(s[k], 1)


def one_repeat(mode, n, args, tmp):
    root = tempfile.mkdtemp(prefix="%s-%02d-" % (mode, n), dir=tmp)
    repo = os.path.join(root, "repo")
    git(root, "init", "-q", "-b", "main", repo)
    with open(os.path.join(repo, "README"), "w", encoding="utf-8") as fh:
        fh.write("race\n")
    git(repo, "add", "README")
    git(repo, "commit", "-q", "-m", "root")
    dirs = {}
    if mode == "shared":
        dirs = {w: repo for w in WRITERS}
    else:
        for w in WRITERS:
            wt = os.path.join(root, "wt-" + w)
            git(repo, "worktree", "add", "-q", "-b", "agent-" + w, wt)
            dirs[w] = wt
    start_at = time.time_ns() + 300_000_000
    procs, logs = [], {}
    for k, w in enumerate(WRITERS):
        logs[w] = os.path.join(root, "writer-%s.json" % w)
        procs.append(subprocess.Popen([
            sys.executable, os.path.abspath(__file__), "writer",
            "--name", w, "--dir", dirs[w], "--root", root, "--log", logs[w],
            "--start-at", str(start_at), "--commits", str(args.commits),
            "--think-ms", str(args.think_ms), "--gap-ms", str(args.gap_ms),
            "--seed", str(args.seed + n * 10 + k)]))
    for p in procs:
        if p.wait() != 0:
            raise SystemExit("a writer exited %s" % p.returncode)
    wl = {w: json.load(open(logs[w], encoding="utf-8")) for w in WRITERS}

    refs = ["main"] if mode == "shared" else ["agent-a", "agent-b"]
    rows = commits_on(repo, refs)
    foreign, wrong, deleting, tip = findings(rows, repo, refs)

    # When each commit returned to the process that made it, by hash.
    landed_at = {}
    for w in WRITERS:
        for c in wl[w]["commits"]:
            if c["sha"]:
                landed_at[c["sha"]] = c["t_land"]

    def returned(sha):
        for short, t in landed_at.items():
            if sha.startswith(short):
                return t
        return None

    adder = {}
    for r in reversed(rows):  # oldest first: the first commit that added a file carried it
        for f in r["added"]:
            adder.setdefault(f, r["sha"])
    land_ms, never, missing = [], [], []
    for w in WRITERS:
        for c in wl[w]["commits"]:
            f = c["file"]
            if f not in tip:
                missing.append(f)
            sha = adder.get(f)
            if sha is None:
                never.append(f)
                continue
            t = returned(sha)
            if t is not None:
                land_ms.append((t - c["t_start"]) / 1e6)

    merge = None
    if mode == "worktree":
        t0 = time.time_ns()
        p = git(repo, "merge", "-q", "--no-edit", "agent-a", "agent-b", check=False)
        merge = {"ms": round((time.time_ns() - t0) / 1e6, 1), "exit": p.returncode,
                 "conflicts": len(git(repo, "diff", "--name-only", "--diff-filter=U").stdout.split())}

    fails = {}
    lines = {}
    outcomes = {}
    samples = {}
    for w in WRITERS:
        for e in wl[w]["events"]:
            key = "%s %s" % (e["op"], e["kind"])
            fails[key] = fails.get(key, 0) + 1
            lines.setdefault(e["kind"], {})
            lines[e["kind"]][e["line"]] = lines[e["kind"]].get(e["line"], 0) + 1
        for c in wl[w]["commits"]:
            outcomes[c["outcome"]] = outcomes.get(c["outcome"], 0) + 1
        for k, v in wl[w]["samples"].items():
            samples.setdefault(k, v)
    shutil.copy(logs["a"], os.path.join(args.out, "raw", "%s-%02d-writer-a.json" % (mode, n)))
    shutil.copy(logs["b"], os.path.join(args.out, "raw", "%s-%02d-writer-b.json" % (mode, n)))
    return {
        "mode": mode, "repeat": n,
        "attempted": len(WRITERS) * args.commits,
        "commits_made": len(rows),
        "commits_with_foreign_files": len(foreign),
        "foreign_files": sum(len(h["foreign"]) for h in foreign),
        "commits_with_the_other_message": len(wrong),
        "commits_deleting_files": len(deleting),
        "files_deleted": sum(len(h["deleted"]) for h in deleting),
        "files_never_committed": len(never),
        "files_missing_at_the_end": len(missing),
        "missing": sorted(missing),
        "deleting": deleting,
        "outcomes": outcomes,
        "failed_attempts": fails,
        "land_ms": land_ms,
        "merge": merge,
        "lines": lines,
        "samples": samples,
    }


def summarise(mode, reps):
    land = [x for r in reps for x in r["land_ms"]]
    fail, lines, outcomes, samples = {}, {}, {}, {}
    for r in reps:
        for k, v in r["failed_attempts"].items():
            fail[k] = fail.get(k, 0) + v
        for kind, d in r["lines"].items():
            for line, v in d.items():
                lines.setdefault(kind, {})
                lines[kind][line] = lines[kind].get(line, 0) + v
        for k, v in r["outcomes"].items():
            outcomes[k] = outcomes.get(k, 0) + v
        for k, v in r["samples"].items():
            samples.setdefault(k, v)

    def total(key):
        return sum(r[key] for r in reps)

    s = {
        "mode": mode,
        "repeats": len(reps),
        "attempted": total("attempted"),
        "commits_made": total("commits_made"),
        "commits_with_foreign_files": total("commits_with_foreign_files"),
        "foreign_files": total("foreign_files"),
        "repeats_with_a_foreign_commit": sum(1 for r in reps if r["commits_with_foreign_files"]),
        "commits_with_the_other_message": total("commits_with_the_other_message"),
        "commits_deleting_files": total("commits_deleting_files"),
        "files_deleted": total("files_deleted"),
        "taken_by_other": outcomes.get("taken_by_other", 0),
        "dropped_from_index": outcomes.get("dropped_from_index", 0),
        "files_never_committed": total("files_never_committed"),
        "files_missing_at_the_end": total("files_missing_at_the_end"),
        "outcomes": outcomes,
        "index_lock_failures": sum(v for k, v in fail.items() if k.endswith("index_lock")),
        "ref_lock_failures": sum(v for k, v in fail.items() if k.endswith("ref_lock")),
        "empty_message_aborts": sum(v for k, v in fail.items() if k.endswith("empty_message")),
        "gave_up": sum(v for k, v in outcomes.items() if k.endswith(RETRIED)),
        "failed_attempts_by_command": dict(sorted(fail.items())),
        "land_ms": {"median": round(statistics.median(land), 1) if land else None,
                    "p95": pct(land, 0.95), "max": round(max(land), 1) if land else None,
                    "n": len(land)},
        "lines": {k: dict(sorted(v.items(), key=lambda kv: -kv[1])) for k, v in sorted(lines.items())},
        "samples": dict(sorted(samples.items())),
        "per_repeat": [{k: r[k] for k in (
            "repeat", "commits_made", "commits_with_foreign_files", "commits_with_the_other_message",
            "commits_deleting_files", "files_never_committed", "files_missing_at_the_end", "missing",
            "deleting", "failed_attempts", "merge")} for r in reps],
    }
    if mode == "worktree":
        ms = [r["merge"]["ms"] for r in reps]
        s["merge"] = {"median_ms": round(statistics.median(ms), 1), "max_ms": max(ms),
                      "conflicts": sum(r["merge"]["conflicts"] for r in reps),
                      "nonzero_exits": sum(1 for r in reps if r["merge"]["exit"])}
    return s


def environment():
    env = {"git": git(".", "--version").stdout.strip(),
           "python": platform.python_version(),
           "cpus": os.cpu_count(),
           "system": platform.platform()}
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    env["os"] = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    for k in ("ImageOS", "ImageVersion", "RUNNER_OS", "RUNNER_ARCH",
              "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def markdown(result):
    s = {m["mode"]: m for m in result["modes"]}
    rows = [
        ("commits attempted", "attempted"),
        ("commits made", "commits_made"),
        ("commits that add the other writer's file", "commits_with_foreign_files"),
        ("repeats with at least one such commit", "repeats_with_a_foreign_commit"),
        ("commits under the other writer's message", "commits_with_the_other_message"),
        ("commits that delete a file", "commits_deleting_files"),
        ("own file already committed by the other", "taken_by_other"),
        ("own file dropped from the index, committed by nobody", "dropped_from_index"),
        ("files never committed", "files_never_committed"),
        ("files missing from the final tree", "files_missing_at_the_end"),
        ("index.lock failures (each retried)", "index_lock_failures"),
        ("ref lock failures (each retried)", "ref_lock_failures"),
        ("empty-message aborts (each retried)", "empty_message_aborts"),
        ("gave up after %d retries" % MAX_RETRIES, "gave_up"),
    ]
    out = ["## Two writers: one index, or a worktree each", "",
           "%s; %s; %d repeats x 2 writers x %d commits, think 0..%d ms, add-to-commit gap %d ms." % (
               result["environment"]["git"], result["environment"].get("os", result["environment"]["system"]),
               result["params"]["repeats"], result["params"]["commits"],
               result["params"]["think_ms"], result["params"]["gap_ms"]), "",
           "| | one working tree | a worktree each |", "|---|---:|---:|"]
    for label, key in rows:
        out.append("| %s | %s | %s |" % (label, s["shared"][key], s["worktree"][key]))
    for q in ("median", "p95", "max"):
        out.append("| change to landed commit, %s ms | %s | %s |" % (
            q, s["shared"]["land_ms"][q], s["worktree"]["land_ms"][q]))
    m = s["worktree"]["merge"]
    out.append("| merging the two branches, median ms | - | %s (conflicts %s) |" % (m["median_ms"], m["conflicts"]))
    out += ["", "Lines git printed, verbatim, with counts:", ""]
    for mode in ("shared", "worktree"):
        for kind, d in s[mode]["lines"].items():
            if kind == "ref_lock":
                out.append("- %s, %s, %dx: `fatal: cannot lock ref 'HEAD': is at <sha> but expected <sha>` "
                           "(and kin; hashes differ each time)" % (mode, kind, sum(d.values())))
                continue
            for line, v in d.items():
                out.append("- %s, %s, %dx: `%s`" % (mode, kind, v, line))
    out += ["", "The whole message, once per command and kind:", ""]
    for mode in ("shared", "worktree"):
        for k, text in s[mode]["samples"].items():
            out += ["%s, %s:" % (mode, k), "", "```text", text, "```", ""]
    return "\n".join(out) + "\n"


def run(args):
    os.makedirs(os.path.join(args.out, "raw"), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="race-")
    reps = {"shared": [], "worktree": []}
    # Interleaved, so a runner that slows down part-way slows both modes.
    for n in range(1, args.repeats + 1):
        for mode in ("shared", "worktree"):
            reps[mode].append(one_repeat(mode, n, args, tmp))
    result = {
        "measured": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": environment(),
        "params": {"repeats": args.repeats, "commits": args.commits, "think_ms": args.think_ms,
                   "gap_ms": args.gap_ms, "max_retries": MAX_RETRIES, "seed": args.seed},
        "modes": [summarise(m, reps[m]) for m in ("shared", "worktree")],
    }
    with open(os.path.join(args.out, "result.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")
    md = markdown(result)
    with open(os.path.join(args.out, "result.md"), "w", encoding="utf-8") as fh:
        fh.write(md)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(md)
    print(md)
    shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--out", required=True)
    r.add_argument("--repeats", type=int, default=10)
    r.add_argument("--commits", type=int, default=20)
    r.add_argument("--think-ms", type=int, default=50)
    r.add_argument("--gap-ms", type=int, default=0)
    r.add_argument("--seed", type=int, default=20261202)
    r.add_argument("--summary")
    w = sub.add_parser("writer")
    for a in ("--name", "--dir", "--root", "--log"):
        w.add_argument(a, required=True)
    for a in ("--start-at", "--commits", "--think-ms", "--gap-ms", "--seed"):
        w.add_argument(a, type=int, required=True)
    a = sub.add_parser("analyze")
    a.add_argument("--repo", required=True)
    a.add_argument("--ref", action="append", required=True)
    args = ap.parse_args()
    {"run": run, "writer": writer, "analyze": analyze}[args.cmd](args)


if __name__ == "__main__":
    main()
