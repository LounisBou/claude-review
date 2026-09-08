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

# Test that _request survives non-JSON responses (like diffs).
# Mock urllib.request.urlopen to return plain text, verify _request returns it as a string.
result=$(python3 -c "
import sys
sys.path.insert(0, '$GHDIR')
from unittest.mock import Mock, patch
from ghlib import http

# Mock response with plain text (like a diff)
mock_resp = Mock()
mock_resp.read.return_value = b'--- file\n+++ file\n'
mock_resp.status = 200
mock_resp.__enter__ = Mock(return_value=mock_resp)
mock_resp.__exit__ = Mock(return_value=False)

with patch('urllib.request.urlopen', return_value=mock_resp):
    status, data = http._request('GET', 'http://example.com/diff', None, {})
    # data should be a string, not a dict
    if isinstance(data, str) and data.startswith('---'):
        print('ok')
    else:
        print('fail')
")
check "transport survives non-JSON response" "ok" "$result"

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

echo "== formatters =="

render() {
  printf '%s' "$2" | python3 -c "
import json, sys
sys.path.insert(0, '$GHDIR')
from ghlib import fmt
print(fmt.render('$1', json.load(sys.stdin)))
"
}

check "pr-number from a list" "42" "$(render pr-number '[{"number":42}]')"
check "pr-number from an object" "42" "$(render pr-number '{"number":42}')"
check "pr-number when absent" "" "$(render pr-number '[]')"
check "pr-url" "https://x/1" "$(render pr-url '{"html_url":"https://x/1"}')"
check "pr-merge-status merged" "merged" "$(render pr-merge-status '{"state":"closed","merged":true}')"
check "pr-merge-status open" "open" "$(render pr-merge-status '{"state":"open","merged":false}')"
check "pr-merge-status closed" "closed" "$(render pr-merge-status '{"state":"closed","merged":false}')"
check "open-threads keeps only unresolved" "1" \
  "$(render open-threads '[{"id":"a","isResolved":false},{"id":"b","isResolved":true}]' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
check "resolve-status" "resolved" "$(render resolve-status '{"resolveReviewThread":{"thread":{"isResolved":true}}}')"

check "thread-summary with null author renders ?" "| ? |" \
  "$(render thread-summary '[{"id":"t1","path":"f.py","line":"10","comments":{"nodes":[{"author":null}]},"isResolved":false}]' | grep -o '| ? |')"

check "issue-comments-summary with null user renders ?" "| ? |" \
  "$(render issue-comments-summary '[{"id":"c1","user":null,"body":"test comment"}]' | grep -o '| ? |')"

check_status "resolve-status with null mutation payload exits 3" 3 \
  sh -c "printf '{\"resolveReviewThread\":null}' | python3 -c \"
import json, sys
sys.path.insert(0, '$GHDIR')
from ghlib import fmt, errors
try:
    fmt.render('resolve-status', json.load(sys.stdin))
except errors.GhError as e:
    sys.exit(e.code)
\""

check_status "an unknown formatter exits 1" 1 \
  sh -c "printf '{}' | python3 -c \"
import json, sys
sys.path.insert(0, '$GHDIR')
from ghlib import fmt, errors
try:
    fmt.render('nope', json.load(sys.stdin))
except errors.GhError as e:
    sys.exit(e.code)
\""

echo "== carried-over reads =="

F2="$WORK/fix2"; mkdir -p "$F2"
gh() { env GH_FIXTURES="$F2" GH_TOKEN=x GH_REPO=acme/thing python3 "$GHDIR/gh.py" "$@"; }

printf '%s' '{"login":"someone"}' > "$F2/GET_user.json"
check "auth-check reaches /user" "someone" "$(gh auth-check --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])')"

printf '%s' '[{"number":7,"title":"T","state":"open","html_url":"u","head":{"ref":"h"},"base":{"ref":"main"},"draft":false}]' \
  > "$F2/GET_repos_acme_thing_pulls__head=acme:feature-x.json"
check "pr-get resolves the branch PR number" "7" "$(gh pr-get --branch feature-x --format pr-number)"

printf '%s' '{"number":7,"state":"closed","merged":true}' > "$F2/GET_repos_acme_thing_pulls_7.json"
check "pr-status reports merged" "merged" "$(gh pr-status 7 --format pr-merge-status)"

printf '%s' '[{"id":11,"body":"hello","user":{"login":"bob"}}]' > "$F2/GET_repos_acme_thing_issues_7_comments.json"
check "pr-issue-comments returns the comments" "11" \
  "$(gh pr-issue-comments 7 --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"

# --format is defined on the parent parser but also mirrored (via SUPPRESS) onto
# every subparser, so it must work on either side of the subcommand, and the
# parent's "raw" default must still apply when the flag is given on neither.
check "--format also works before the subcommand" "someone" \
  "$(gh --format raw auth-check | python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])')"

check "--format defaults to raw when omitted on both sides" "someone" \
  "$(gh auth-check | python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])')"

# comments-resolved-batch must map a missing or malformed file to a usage exit
# instead of leaking a raw FileNotFoundError/JSONDecodeError traceback.
check_status "comments-resolved-batch on a missing file exits 1" 1 \
  gh comments-resolved-batch "$F2/does-not-exist.json"

out=$(gh comments-resolved-batch "$F2/does-not-exist.json" 2>&1)
check "missing file prints an error line" "1" "$(printf '%s' "$out" | grep -c '^error:')"
check "missing file has no traceback" "0" "$(printf '%s' "$out" | grep -cE 'Traceback|^[A-Za-z]*Error:')"

printf 'not json' > "$F2/bad.json"
check_status "comments-resolved-batch on malformed json exits 1" 1 \
  gh comments-resolved-batch "$F2/bad.json"

out=$(gh comments-resolved-batch "$F2/bad.json" 2>&1)
check "malformed file prints an error line" "1" "$(printf '%s' "$out" | grep -c '^error:')"
check "malformed file has no traceback" "0" "$(printf '%s' "$out" | grep -cE 'Traceback|^[A-Za-z]*Error:')"

# A non-numeric pr must fail via argparse's own mapped usage exit, not an
# unguarded int() conversion inside the handler.
check_status "pr-threads with a non-numeric pr exits 1" 1 \
  gh pr-threads abc

out=$(gh pr-threads abc 2>&1)
check "non-numeric pr has no traceback" "0" "$(printf '%s' "$out" | grep -cE 'Traceback|^[A-Za-z]*Error:')"

echo "== body-file fidelity =="

F3="$WORK/fix3"; mkdir -p "$F3"
gh3() { env GH_FIXTURES="$F3" GH_TOKEN=x GH_REPO=acme/thing python3 "$GHDIR/gh.py" "$@"; }

# Every character class that breaks shell quoting, in one body.
BODY="$WORK/body.md"
{
  printf 'Line one with `backticks` and a $VAR sequence\n'
  printf 'A "double quoted" phrase and a '\''single quoted'\'' one\n'
  printf '\n'
  printf '```bash\n'
  printf 'echo "$(whoami)" && rm -rf /tmp/nothing\n'
  printf '```\n'
  printf 'Trailing line with an accent: éàü\n'
  # A CRLF line, so that removing newline="" from bodies.read is detectable.
  # Without one, the setting this test exists to protect is never exercised.
  printf 'A line ending in CRLF\r\n'
} > "$BODY"

printf '%s' '{"id":99}' > "$F3/POST_repos_acme_thing_issues_7_comments.json"
gh3 pr-comment 7 --body-file "$BODY" >/dev/null

# Compare through files, never through "$(...)": command substitution strips
# every trailing newline from BOTH sides before check() sees them, so a real
# stripping regression in bodies.read would compare equal and pass.
python3 -c "
import json, sys
for line in open('$F3/sent.jsonl'):
    row = json.loads(line)
    if row['path'].endswith('/issues/7/comments'):
        sys.stdout.write(row['body']['body'])
        break
" > "$WORK/sent-body.md"
check_status "body-file arrives byte-identical" 0 cmp -s "$BODY" "$WORK/sent-body.md"

check_status "a missing body file exits 1" 1 gh3 pr-comment 7 --body-file "$WORK/nope.md"
check_status "an empty body file exits 1" 1 sh -c ": > '$WORK/empty.md'; $(printf '%q ' env GH_FIXTURES="$F3" GH_TOKEN=x GH_REPO=acme/thing python3 "$GHDIR/gh.py") pr-comment 7 --body-file '$WORK/empty.md'"

echo "== review writes =="

printf '%s' '{"id":5,"state":"COMMENTED"}' > "$F3/POST_repos_acme_thing_pulls_7_reviews.json"
cat > "$WORK/inline.json" <<'JSON'
[{"path":"src/a.py","line":12,"side":"RIGHT","body":"Consider renaming this."}]
JSON
gh3 review-submit 7 --event COMMENT --body-file "$BODY" --comments-file "$WORK/inline.json" >/dev/null

payload=$(python3 -c "
import json
for line in open('$F3/sent.jsonl'):
    row = json.loads(line)
    if row['path'].endswith('/pulls/7/reviews'):
        print(row['body']['event'], len(row['body']['comments']), row['body']['comments'][0]['path'])
")
check "review-submit sends event and inline comments" "COMMENT 1 src/a.py" "$payload"

# Task 5 overrode ArgumentParser.error() so argparse's own exit 2 becomes the
# CLI's documented usage code. An invalid --event choice therefore exits 1.
check_status "an invalid event exits 1 as a usage error" 1 gh3 review-submit 7 --event NOPE --body-file "$BODY"

echo "== pr content =="

printf '%s' '[{"filename":"src/a.py","status":"modified","patch":"@@ -1 +1 @@"}]' \
  > "$F3/GET_repos_acme_thing_pulls_7_files.json"
check "pr-files lists changed paths" "src/a.py" \
  "$(gh3 pr-files 7 --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["filename"])')"

printf '%s' '{"content":"aGVsbG8=","encoding":"base64"}' \
  > "$F3/GET_repos_acme_thing_contents_README.md__ref=main.json"
check "file-at-ref decodes base64 content" "hello" \
  "$(gh3 file-at-ref README.md main --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)["content"])')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
