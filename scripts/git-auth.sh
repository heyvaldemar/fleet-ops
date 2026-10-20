#!/usr/bin/env bash
# scripts/git-auth.sh - sourced, not run (run, it sets nothing that outlives it): hands GH_TOKEN to git through its
# environment, as an Authorization header for github.com set by GIT_CONFIG_*.
#
# Never in a URL. A URL is a command-line argument, which any process on the
# runner can read, and a clone writes its remote URL, token and all, into
# .git/config. printf is a shell builtin, so the token is not in base64's
# arguments either: base64 reads it on stdin.
: "${GH_TOKEN:?GH_TOKEN is needed to talk to GitHub}"
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
