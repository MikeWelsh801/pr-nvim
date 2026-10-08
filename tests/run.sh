#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
export PATH="$here/bin:$PATH" PR_REVIEW_FIXTURES="$here/fixtures" PR_REVIEW_TMP="$tmp" PR_REVIEW_POST_OUT="$tmp/posted.json"
cd "$tmp"  # not a git repo, so file contents go through the (stub) API
nvim --headless -u NONE --cmd "set rtp+=$here/.." -c "lua dofile('$here/run.lua')" -c "qa!" 2>&1
rm -rf "$tmp"
