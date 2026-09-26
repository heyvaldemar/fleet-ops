#!/usr/bin/env python3
"""split-freshness.py <repo-dir> [--check] — move the freshness job into its own workflow.

WHY. The badge on every template and on the catalogue is the Deployment
Verification workflow's, and that workflow also ran the freshness check: a
designed alarm that goes red when a pin is one version behind, which triage
clears within the day. Measured over fourteen days on 2026-09-23, 281 red runs
on main, and 254 of them had no failing job except that alarm. Nine red badges
in ten said "a pin is behind" to a reader who sees "this template is broken".

So the job moves, verbatim, to .github/workflows/freshness.yml, with the same
triggers, permissions and environment it ran under. Text is moved rather than
YAML regenerated, so every comment in the job travels with it; the result is
then parsed and compared as data, and nothing is written unless the moved job,
the jobs left behind, the triggers and the environment are all equal to what
they were.

--check reports what would change and writes nothing.
"""
import io
import os
import re
import sys

import yaml

FRESH_IDS = ("check-pin-freshness", "check-source-freshness")
TOP = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):")
JOB = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")

HEADER = """name: Pin Freshness

# ITS OWN WORKFLOW, SO THE BADGE MEANS WHAT A READER THINKS IT MEANS.
#
# This job used to run inside Deployment Verification, whose badge is the one
# on the README and in the catalogue. It is a designed alarm: it goes red when
# a pin falls behind upstream, and the fleet's triage moves the pin within the
# day. Measured across the fleet over fourteen days, nine red runs in ten were
# this alarm and nothing else, and a visitor cannot tell "one version behind"
# from "does not boot". The job below is unchanged; only its address moved.
"""


def blocks(header):
    """Top-level keys of the part above `jobs:`, each with the comment lines
    directly above it, in order."""
    out, cur, pending = {}, None, []
    for line in header.splitlines(True):
        m = TOP.match(line)
        if m:
            cur = m.group(1)
            out[cur] = "".join(pending) + line
            pending = []
        elif cur is not None and (line.startswith((" ", "\t")) or line.strip() == ""):
            if line.strip() == "" or line.lstrip().startswith("#") and not line.startswith(" "):
                pending.append(line)
            else:
                out[cur] += "".join(pending) + line
                pending = []
        else:
            pending.append(line)
    return out


def split(text):
    if "\njobs:\n" not in text:
        raise ValueError("no jobs: section")
    head, body = text.split("\njobs:\n", 1)
    head += "\n"
    lines = body.splitlines(True)
    starts = [i for i, l in enumerate(lines) if JOB.match(l)]
    ids = [JOB.match(lines[i]).group(1) for i in starts]
    fresh = [j for j in ids if j in FRESH_IDS]
    if len(fresh) != 1:
        raise ValueError("expected exactly one freshness job, found %r" % fresh)
    k = ids.index(fresh[0])
    a = starts[k]
    # comment lines directly above the job belong to it
    while a > 0 and lines[a - 1].startswith("  #"):
        a -= 1
    b = starts[k + 1] if k + 1 < len(starts) else len(lines)
    # trailing comments that introduce the NEXT job stay with it
    while b > a and k + 1 < len(starts) and lines[b - 1].startswith("  #"):
        b -= 1
    job = "".join(lines[a:b]).rstrip("\n") + "\n"
    rest = "".join(lines[:a] + lines[b:])
    verification = head.rstrip("\n") + "\n\njobs:\n" + rest

    top = blocks(head)
    parts = [HEADER]
    if "on" not in top:
        raise ValueError("no on: block")
    parts.append(top["on"].strip("\n") + "\n")
    if "concurrency" in top:
        # The WHOLE rest of the line. The first version replaced up to the
        # first space and left "pin-freshness-${{ github.ref }} github.ref }}":
        # a valid string to every linter, and a concurrency group that shared
        # nothing with anything, which is how it would have shipped.
        conc = re.sub(r"(?m)^(\s*group:).*$", r"\1 pin-freshness-${{ github.ref }}", top["concurrency"], count=1)
        parts.append("\n" + conc.strip("\n") + "\n")
    for key in ("permissions", "env", "defaults"):
        if key in top:
            parts.append("\n" + top[key].strip("\n") + "\n")
    parts.append("\njobs:\n" + job)
    return verification, "".join(parts), fresh[0]


def verify(old, new_ver, new_fresh, fid):
    """Everything that ran before still runs, under the same conditions."""
    o, v, f = yaml.safe_load(old), yaml.safe_load(new_ver), yaml.safe_load(new_fresh)
    # PyYAML reads the key `on` as True
    trig = lambda d: d.get("on", d.get(True))
    problems = []
    if f["jobs"] != {fid: o["jobs"][fid]}:
        problems.append("the moved job is not identical to the original")
    left = {k: val for k, val in o["jobs"].items() if k != fid}
    if v["jobs"] != left:
        problems.append("the jobs left behind changed")
    for d, name in ((v, "verification"), (f, "freshness")):
        if trig(d) != trig(o):
            problems.append("the %s triggers differ from the original" % name)
        for key in ("env", "permissions"):
            if d.get(key) != o.get(key):
                problems.append("the %s %s differs from the original" % (name, key))
    oc, fc = o.get("concurrency"), f.get("concurrency")
    if oc is not None:
        want = dict(oc, group="pin-freshness-${{ github.ref }}")
        if fc != want:
            problems.append("the freshness concurrency is %r, wanted %r" % (fc, want))
        if v.get("concurrency") != oc:
            problems.append("the verification concurrency changed")
    for j, spec in v["jobs"].items():
        needs = spec.get("needs") or []
        if fid in ([needs] if isinstance(needs, str) else needs):
            problems.append("%s needs the moved job" % j)
    return problems


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    check = "--check" in sys.argv[2:]
    vpath = os.path.join(d, ".github", "workflows", "deployment-verification.yml")
    fpath = os.path.join(d, ".github", "workflows", "freshness.yml")
    if os.path.exists(fpath):
        print("%s: already split" % d)
        return 0
    old = io.open(vpath, encoding="utf-8").read()
    new_ver, new_fresh, fid = split(old)
    problems = verify(old, new_ver, new_fresh, fid)
    if problems:
        for p in problems:
            print("%s: REFUSED — %s" % (d, p), file=sys.stderr)
        return 1
    if check:
        print("%s: would move %s (%d lines) to freshness.yml" % (d, fid, new_fresh.count("\n")))
        return 0
    io.open(vpath, "w", encoding="utf-8").write(new_ver)
    io.open(fpath, "w", encoding="utf-8").write(new_fresh)
    print("%s: moved %s to freshness.yml" % (d, fid))
    return 0


if __name__ == "__main__":
    sys.exit(main())
