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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
