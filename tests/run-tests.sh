#!/bin/bash
# Test suite. No network, no plugin installation, isolated HOME per case.
#
# Each case runs a script against a temporary state directory or a temporary
# HOME and compares its output or its side effects with an expected value.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$1"
    printf '       expected: %s\n' "$(printf '%s' "$2" | tr '\n' '⏎')"
    printf '       actual:   %s\n' "$(printf '%s' "$3" | tr '\n' '⏎')"
    fail=$((fail + 1))
  fi
}

# check_status <name> <expected-exit-code> <command...>
check_status() {
  local name="$1" expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local code=$?
  check "$name" "exit $expected" "exit $code"
}

echo "== manifests =="

check "plugin name" "pr-review" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$ROOT/.claude-plugin/plugin.json")"

check "plugin license" "MIT" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$ROOT/.claude-plugin/plugin.json")"

check "marketplace lists the plugin" "pr-review" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"][0]["name"])' "$ROOT/.claude-plugin/marketplace.json")"

# The product name belongs only in load-bearing identifiers: host paths, host
# environment variables, the plugin name and the manifest directory.
# Scope: the executable surface only. README.md and CLAUDE.md address a
# reader who is installing the plugin and may name the host product freely.
hits=$(grep -rniI 'claude' "$ROOT/skills" "$ROOT/scripts" "$ROOT/commands" 2>/dev/null \
  | grep -viE '~/\.claude/|\$HOME/\.claude|CLAUDE_CONFIG_DIR|CLAUDE_PLUGIN_ROOT|CLAUDE_CODE_SESSION_ID|claude-plugins-official|claude-review|\.claude-plugin|/\.claude/' || true)
check "no product name in skill prose" "" "$hits"

echo "== preflight: system tools =="

# A PATH containing none of the required tools.
mkdir -p "$WORK/emptybin"
check_status "missing python3 exits 11" 11 \
  env PATH="$WORK/emptybin" HOME="$WORK" /bin/bash "$ROOT/scripts/preflight.sh"

# Not a git repository at all.
mkdir -p "$WORK/norepo"
check_status "not a git repo exits 13" 13 \
  env HOME="$WORK" PR_REVIEW_SKIP_PLUGINS=1 sh -c "cd '$WORK/norepo' && /bin/bash '$ROOT/scripts/preflight.sh'"

# A git repository whose origin is not GitHub.
mkdir -p "$WORK/gitlab" && git -C "$WORK/gitlab" init -q -b main
git -C "$WORK/gitlab" remote add origin https://gitlab.com/acme/thing.git
check_status "non-github origin exits 13" 13 \
  env HOME="$WORK" PR_REVIEW_SKIP_PLUGINS=1 sh -c "cd '$WORK/gitlab' && /bin/bash '$ROOT/scripts/preflight.sh'"

# The failure message names the remedy.
msg=$(env PATH="$WORK/emptybin" HOME="$WORK" /bin/bash "$ROOT/scripts/preflight.sh" 2>&1 >/dev/null | grep -c '^fix:')
check "failure prints a fix line" "1" "$msg"

echo "== preflight: plugin dependencies =="

mkdir -p "$WORK/repo" && git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" remote add origin https://github.com/acme/thing.git

settings() { mkdir -p "$WORK/cfg"; printf '%s' "$1" > "$WORK/cfg/settings.json"; }
pf() {
  env HOME="$WORK" PR_REVIEW_SETTINGS="$WORK/cfg/settings.json" PR_REVIEW_SKIP_AUTH=1 \
    sh -c "cd '$WORK/repo' && bash '$ROOT/scripts/preflight.sh'"
}

settings '{"enabledPlugins":{"pr-review-toolkit@claude-plugins-official":true,"code-review@claude-plugins-official":true}}'
check_status "both dependencies enabled passes" 0 pf

settings '{"enabledPlugins":{"pr-review-toolkit@claude-plugins-official":true,"code-review@claude-plugins-official":false}}'
check_status "a disabled dependency exits 10" 10 pf

settings '{"enabledPlugins":{"pr-review-toolkit@claude-plugins-official":true}}'
check_status "an absent dependency exits 10" 10 pf

settings '{ this is not json'
check_status "malformed settings exits 10" 10 pf

settings '{"enabledPlugins":{"pr-review-toolkit@claude-plugins-official":true,"code-review@claude-plugins-official":false}}'
named=$(pf 2>&1 >/dev/null | grep -c 'code-review')
check "the failure names the offending plugin" "2" "$named"

settings '{"enabledPlugins":"not-a-dict"}'
check_status "enabledPlugins as string exits 10" 10 pf

settings '[]'
check_status "top-level array exits 10" 10 pf

settings '{"enabledPlugins":"not-a-dict"}'
output=$(pf 2>&1)
error_lines=$(printf '%s' "$output" | grep -c '^error:')
fix_lines=$(printf '%s' "$output" | grep -c '^fix:')
traceback_lines=$(printf '%s' "$output" | grep -cE 'Traceback|^[A-Za-z]*Error:')
check "enabledPlugins string produces error lines" "2" "$error_lines"
check "enabledPlugins string produces fix lines" "2" "$fix_lines"
check "enabledPlugins string has no traceback" "0" "$traceback_lines"

settings '[]'
output=$(pf 2>&1)
error_lines=$(printf '%s' "$output" | grep -c '^error:')
fix_lines=$(printf '%s' "$output" | grep -c '^fix:')
traceback_lines=$(printf '%s' "$output" | grep -cE 'Traceback|^[A-Za-z]*Error:')
check "top-level array produces error lines" "2" "$error_lines"
check "top-level array produces fix lines" "2" "$fix_lines"
check "top-level array has no traceback" "0" "$traceback_lines"

echo "== preflight: GitHub token =="

# Missing token, missing gh
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/fakebin/gh"
chmod +x "$WORK/fakebin/gh"
check_status "missing token exits 12" 12 \
  env -u GH_TOKEN HOME="$WORK" PR_REVIEW_SETTINGS="$WORK/cfg/settings.json" PR_REVIEW_SKIP_PLUGINS=1 PATH="$WORK/fakebin:$PATH" \
    sh -c "cd '$WORK/repo' && bash '$ROOT/scripts/preflight.sh'"

# Token via environment variable
check_status "GH_TOKEN set exits 0" 0 \
  env HOME="$WORK" PR_REVIEW_SETTINGS="$WORK/cfg/settings.json" PR_REVIEW_SKIP_PLUGINS=1 GH_TOKEN="dummy-token-12345" \
    sh -c "cd '$WORK/repo' && bash '$ROOT/scripts/preflight.sh'"

echo "== http transport =="

GHDIR="$ROOT/skills/github-curl"
FIX="$WORK/fix"; mkdir -p "$FIX"

printf '%s' '{"number":42,"title":"A title"}' > "$FIX/GET_repos_acme_thing_pulls_42.json"

out=$(env GH_FIXTURES="$FIX" GH_TOKEN=x python3 -c "
import sys; sys.path.insert(0, '$GHDIR')
from ghlib import http
print(http.rest('GET', '/repos/acme/thing/pulls/42')['title'])
")
check "reads a fixture instead of the network" "A title" "$out"

# Pagination: two pages joined into a single list.
printf '%s' '[{"id":1}]' > "$FIX/GET_repos_acme_thing_pulls_42_comments.json"
printf '%s' '[{"id":2}]' > "$FIX/GET_repos_acme_thing_pulls_42_comments__page=2.json"
# GH_PAGE_SIZE=1 makes a one-item page a full page, so a second is fetched.
# The third request finds no fixture, returns nothing, and ends the loop.
out=$(env GH_FIXTURES="$FIX" GH_TOKEN=x GH_PAGE_SIZE=1 python3 -c "
import sys; sys.path.insert(0, '$GHDIR')
from ghlib import http
print(len(http.rest('GET', '/repos/acme/thing/pulls/42/comments', paginate=True)))
")
check "paginates until a short page" "2" "$out"

# Each HTTP status maps to its own exit code.
raises() {  # raises <name> <status> <message> <expected-exit>
  printf '{"__status":%s,"message":"%s"}' "$2" "$3" > "$FIX/GET_repos_acme_thing_err_$2.json"
  check_status "$1" "$4" \
    env GH_FIXTURES="$FIX" GH_TOKEN=x python3 -c "
import sys; sys.path.insert(0, '$GHDIR')
from ghlib import http, errors
try:
    http.rest('GET', '/repos/acme/thing/err/$2')
except errors.GhError as e:
    sys.exit(e.code)
sys.exit(0)
"
}

raises "a 401 raises AuthError"          401 "Bad credentials"        2
raises "a 403 rate limit raises code 5"  403 "API rate limit exceeded" 5
raises "a 404 raises NotFound"           404 "Not Found"              4
raises "a 422 raises ApiError"           422 "Validation Failed"      3
raises "a 429 raises code 5"             429 "You have exceeded a secondary rate limit" 5

# Requests are recorded for later assertion.
sent=$(wc -l < "$FIX/sent.jsonl" | tr -d ' ')
check "records every request sent" "9" "$sent"

echo "== cli skeleton =="

check "resolves owner/repo from the origin remote" "acme/thing" \
  "$(sh -c "cd '$WORK/repo' && python3 -c \"
import sys; sys.path.insert(0, '$GHDIR')
from ghlib import repo
print(repo.nwo())
\"")"

check "--repo overrides the remote" "other/name" \
  "$(env GH_REPO=other/name python3 -c "
import sys; sys.path.insert(0, '$GHDIR')
from ghlib import repo
print(repo.nwo())
")"

check_status "an unknown subcommand exits 1" 1 \
  env GH_TOKEN=x python3 "$GHDIR/gh.py" no-such-command

check_status "no subcommand exits 1" 1 \
  env GH_TOKEN=x python3 "$GHDIR/gh.py"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
