#!/usr/bin/env python3
"""quiet-mentions.py - stdin to stdout, every @handle outside code made inert.

A REPORT HERE QUOTES OTHER PEOPLE'S TEXT. The triage report carries an
upstream review that quotes release notes; the scout and the lab sweep carry
summaries of other projects' commits and changelogs. Release notes thank
people by handle, and a handle in an issue body is a mention: GitHub notifies
that person when the issue is opened, and again on every edit that puts the
handle back. file-report.sh rewrites its body whenever the findings change, so
a maintainer of a project this fleet merely tracks was notified five times
between 2026-11-06 and 2026-11-12 by a thread that had nothing to do with
them, until they asked, in that thread, for it to stop
(heyvaldemar/fleet-ops#50).

Nothing these jobs write is meant to call a person. So every handle outside
code is put in a code span, where GitHub shows it and notifies nobody. Text
already in code (fenced blocks, inline spans) is left alone: it notifies
nobody as it is, and a second pair of backticks would break it.

Not a mention, and so not touched: an address (a@b.example), a ref
(actions/checkout@v4), anything with a letter, digit, backtick or one of
/ . @ + - right before the @.
"""
import re
import sys

# Fenced blocks first, then inline code spans of any backtick run length.
CODE = re.compile(
    r"(?P<fence>^[ \t]{0,3}(?P<mark>`{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]{0,3}(?P=mark)[ \t]*$|\Z))"
    # A span ends at its paragraph: a lone backtick must not pair with one
    # three paragraphs down and hide every handle in between.
    r"|(?P<span>(?P<ticks>`+)(?!`)(?:(?!\n[ \t]*\n).)*?(?<!`)(?P=ticks)(?!`))",
    re.M | re.S,
)
# A GitHub login (letters, digits, single hyphens, at most 39), optionally
# /team for an organisation's team, which notifies its members.
HANDLE = re.compile(
    r"(?<![A-Za-z0-9_`/.@+-])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})(/[A-Za-z0-9_.-]+)?(?![A-Za-z0-9_-])"
)


def quiet(text):
    out, last = [], 0
    for m in CODE.finditer(text):
        out.append(HANDLE.sub(lambda h: "`" + h.group(0) + "`", text[last:m.start()]))
        out.append(m.group(0))
        last = m.end()
    out.append(HANDLE.sub(lambda h: "`" + h.group(0) + "`", text[last:]))
    return "".join(out)


if __name__ == "__main__":
    sys.stdout.write(quiet(sys.stdin.read()))
