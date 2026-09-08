# pr-review plugin — phase 1 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test the `pr-review` plugin in `~/dev/claude-review` — manifests, dependency preflight, the `gh.py` GitHub tool, and the four extracted skills — without installing anything or touching any consumer repository.

**Architecture:** A Claude Code plugin that is a thin layer over the upstream `pr-review-toolkit` and `code-review` plugins. A shared bash preflight refuses to run when a dependency is missing or disabled. A single Python 3 stdlib CLI (`gh.py`) replaces the previous `gh-api.sh | gh-parse.py` pipe, with formatting as a `--format` flag and every text body passed by file.

**Tech Stack:** Python 3.9+ (stdlib only: `urllib`, `json`, `argparse`, `hashlib`, `base64`), bash, git.

**Spec:** `docs/design.md` (commit `b09894e3`)

## Global Constraints

- Python 3.9+ standard library only. No pip packages, no `requests`.
- Bash is used only for `install.sh`, `scripts/preflight.sh` and `tests/run-tests.sh`.
- Every text body reaches `gh.py` through `--body-file <path>`. No `--body "text"` form exists on any subcommand.
- The 16 carried-over subcommand names are preserved verbatim: `auth-check`, `pr-get`, `pr-list`, `pr-threads`, `pr-comments`, `pr-issue-comments`, `pr-reviews`, `pr-status`, `pr-checks`, `comment-resolved`, `comments-resolved-batch`, `thread-resolve`, `comment-resolve`, `comment-unresolve`, `pr-create`, `pr-merge`.
- `gh.py` exit codes: `0` success, `1` usage, `2` auth, `3` API error, `4` not found, `5` rate limited after retries.
- `preflight.sh` exit codes: `0` ok, `10` missing/disabled plugin dependency, `11` missing system tool, `12` auth failure, `13` not a GitHub repository.
- Each failure prints one `error:` line and one `fix:` line to stderr. The `fix:` line gives the literal command when one exists and is universal (`gh auth login`, `/plugin install <name>`); where the remedy depends on the reader's platform or package manager (installing python3 or curl) it names the concrete action instead. Never a restatement of the error.
- Plugin skill paths are always written `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/...`. Never a relative `.claude/skills/` path.
- No user input may reach an unguarded conversion or file read. A bad PR number, a missing
  file or malformed JSON must surface as a mapped exit code, never a Python traceback.
  Numeric arguments use argparse's `type=int` (its failure routes through the overridden
  `error()`); file reads are wrapped and re-raised as `errors.UsageError`.
- Never write `x.get("k", {}).get(...)` against API data. `.get` returns the default only when the
  key is ABSENT; a key present with a JSON `null` returns `None` and the chained call raises
  `AttributeError`, which surfaces as a traceback instead of a mapped exit code. GitHub sends
  `null` for deleted-account authors and similar fields. Use `(x.get("k") or {}).get(...)`.
- All repository content is English. Commit subjects are imperative prose with no `feat:`/`fix:` prefix; the body explains why. No `Claude-Session`, `Co-Authored-By: Claude` or `Generated with` trailers.
- Tests never touch the network and never write outside `mktemp -d`.
- Do not run `git push`, `/plugin install`, or modify anything under `~/.claude/` or `~/dev/www/`. Those are phases 2 and 3.

---

### Task 1: Repository skeleton, manifests and test harness

**Files:**
- Create: `.gitignore`, `LICENSE`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `tests/run-tests.sh` exporting shell functions `check <name> <expected> <actual>` and `check_status <name> <expected-exit-code> <command...>`, the variables `ROOT` (repo root) and `WORK` (temp dir), and the `pass`/`fail` counters. Every later task appends its own `== section ==` to this file.

- [ ] **Step 1: Write the failing test**

Create `tests/run-tests.sh`:

```bash
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `.claude-plugin/plugin.json` does not exist, python3 raises `FileNotFoundError`.

- [ ] **Step 3: Write minimal implementation**

`.claude-plugin/plugin.json`:

```json
{
  "name": "pr-review",
  "description": "Interactive PR review workflow: item-by-item walkthrough, GitHub comment processing, autonomous review-fix loop, and a stdlib GitHub API tool.",
  "version": "0.1.0",
  "author": {
    "name": "Lounis Bou",
    "email": "lounis.bou@gmail.com"
  },
  "homepage": "https://github.com/LounisBou/claude-review",
  "repository": "https://github.com/LounisBou/claude-review",
  "license": "MIT",
  "keywords": ["pull-request", "code-review", "github", "api", "python"]
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "claude-review",
  "owner": {
    "name": "Lounis Bou",
    "email": "lounis.bou@gmail.com"
  },
  "metadata": {
    "description": "PR review tooling",
    "version": "0.1.0"
  },
  "plugins": [
    {
      "name": "pr-review",
      "source": "./",
      "description": "Interactive PR review walkthrough, GitHub comment processing, autonomous review-fix loop, and a stdlib GitHub API tool.",
      "version": "0.1.0",
      "author": {
        "name": "Lounis Bou"
      }
    }
  ]
}
```

`.gitignore`:

```
.DS_Store
*.bak
__pycache__/
*.pyc

# The global ~/.gitignore on some machines ignores `docs/`. A repository
# .gitignore takes precedence over global excludes, so this negation restores
# docs/ for this project, where the design document is versioned.
!docs/
```

`LICENSE`: copy the MIT text from `~/dev/claude-orchestrator/LICENSE`, changing only the copyright year to 2026 if it differs.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add .gitignore LICENSE .claude-plugin tests/run-tests.sh
git commit -m "Lay down the manifests and the test harness

The suite is bash with no network and an isolated temporary directory per
case, matching the sibling plugins, so a check can assert a script's exit
code and its side effects without a live GitHub or an installed plugin."
```

---

### Task 2: Preflight — system tool checks

**Files:**
- Create: `scripts/preflight.sh`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `check`, `check_status`, `ROOT`, `WORK` from Task 1.
- Produces: `scripts/preflight.sh`, runnable as `bash scripts/preflight.sh`. Prints nothing and exits `0` on success; on failure prints one `error:` line plus one `fix:` line to stderr and exits with the code from Global Constraints. Honours `PR_REVIEW_SETTINGS` (path to a settings.json, default `$HOME/.claude/settings.json`) so tests can point it at a fixture.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the final `echo`:

```bash
echo "== preflight: system tools =="

# A PATH containing none of the required tools.
mkdir -p "$WORK/emptybin"
check_status "missing python3 exits 11" 11 \
  env PATH="$WORK/emptybin" HOME="$WORK" bash "$ROOT/scripts/preflight.sh"

# Not a git repository at all.
mkdir -p "$WORK/norepo"
check_status "not a git repo exits 13" 13 \
  env HOME="$WORK" PR_REVIEW_SKIP_PLUGINS=1 sh -c "cd '$WORK/norepo' && bash '$ROOT/scripts/preflight.sh'"

# A git repository whose origin is not GitHub.
mkdir -p "$WORK/gitlab" && git -C "$WORK/gitlab" init -q -b main
git -C "$WORK/gitlab" remote add origin https://gitlab.com/acme/thing.git
check_status "non-github origin exits 13" 13 \
  env HOME="$WORK" PR_REVIEW_SKIP_PLUGINS=1 sh -c "cd '$WORK/gitlab' && bash '$ROOT/scripts/preflight.sh'"

# The failure message names the remedy.
msg=$(env PATH="$WORK/emptybin" HOME="$WORK" bash "$ROOT/scripts/preflight.sh" 2>&1 >/dev/null | grep -c '^fix:')
check "failure prints a fix line" "1" "$msg"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL on all four — `scripts/preflight.sh: No such file or directory` (exit 127, not the expected codes).

- [ ] **Step 3: Write minimal implementation**

`scripts/preflight.sh`:

```bash
#!/usr/bin/env bash
# Refuse to run when a dependency is missing, so no skill degrades silently.
set -u

SETTINGS="${PR_REVIEW_SETTINGS:-$HOME/.claude/settings.json}"

die() {
  printf 'error: %s\n' "$1" >&2
  printf 'fix:   %s\n' "$2" >&2
  exit "$3"
}

# ── System tools ──────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH" "install python3 (3.9 or later)" 11

python3 - <<'PY' || die "python3 is older than 3.9" "install python3 3.9 or later" 11
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY

command -v curl >/dev/null 2>&1 || die "curl not found on PATH" "install curl" 11

# ── Repository ────────────────────────────────────────────────
remote=$(git remote get-url origin 2>/dev/null || echo "")
[ -n "$remote" ] || die "no git remote named origin" "run this from a GitHub repository clone" 13
case "$remote" in
  *github.com*) : ;;
  *) die "origin is not a github.com remote: $remote" "run this from a GitHub repository clone" 13 ;;
esac

exit 0
```

Note: the plugin-dependency and auth checks are added in Task 3; `PR_REVIEW_SKIP_PLUGINS` is honoured there.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/run-tests.sh
git commit -m "Refuse to start when a required tool or remote is absent

A thin layer over other plugins is worthless if it degrades quietly, so the
preflight stops at the first failure and prints the exact command that fixes
it rather than a diagnosis the reader has to translate into an action."
```

---

### Task 3: Preflight — plugin dependency and auth checks

**Files:**
- Modify: `scripts/preflight.sh`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `die`, `SETTINGS` from Task 2.
- Produces: preflight now also enforces that `pr-review-toolkit@claude-plugins-official` and `code-review@claude-plugins-official` are present **and** `true` in `enabledPlugins`, and that a GitHub token is obtainable. `PR_REVIEW_SKIP_PLUGINS=1` skips the plugin block; `PR_REVIEW_SKIP_AUTH=1` skips the token check. Both exist for tests only.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
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
check "the failure names the offending plugin" "1" "$named"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — every case exits `0`, because preflight does not yet read `settings.json`.

- [ ] **Step 3: Write minimal implementation**

Insert into `scripts/preflight.sh`, after the repository block and before `exit 0`:

```bash
# ── Plugin dependencies ───────────────────────────────────────
# The authority is enabledPlugins, not the presence of files under
# ~/.claude/plugins/cache: a plugin can sit on disk and be inert.
if [ "${PR_REVIEW_SKIP_PLUGINS:-0}" != "1" ]; then
  missing=$(python3 - "$SETTINGS" <<'PY'
import json, sys
required = ["pr-review-toolkit@claude-plugins-official", "code-review@claude-plugins-official"]
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    enabled = data["enabledPlugins"] if isinstance(data, dict) else None
    if not isinstance(enabled, dict):
        raise ValueError("enabledPlugins is not an object")
except (OSError, ValueError, KeyError, TypeError):
    # Unreadable, not JSON, or JSON of the wrong shape all mean the same
    # thing: nothing here proves a dependency is enabled.
    print(" ".join(required))
    sys.exit(0)
print(" ".join(k for k in required if enabled.get(k) is not True))
PY
)
  if [ -n "$missing" ]; then
    for dep in $missing; do
      printf 'error: required plugin not installed or not enabled: %s\n' "$dep" >&2
      printf 'fix:   /plugin install %s   then enable it in /plugin\n' "$dep" >&2
    done
    exit 10
  fi
fi

# ── GitHub token ──────────────────────────────────────────────
if [ "${PR_REVIEW_SKIP_AUTH:-0}" != "1" ]; then
  token="${GH_TOKEN:-$(gh auth token 2>/dev/null || echo "")}"
  [ -n "$token" ] || die "no GitHub token available" "gh auth login" 12
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/run-tests.sh
git commit -m "Treat a disabled dependency as a missing one

On the machine this was written for, one of the two upstream plugins was
installed and set to false. A check for files on disk would have reported
success and then failed at the first use, so the enabledPlugins map is the
authority and a plugin that is present but inert fails the same way an
absent one does."
```

---

### Task 4: HTTP transport with fixtures, pagination and typed errors

**Files:**
- Create: `skills/github-curl/ghlib/__init__.py`, `skills/github-curl/ghlib/errors.py`, `skills/github-curl/ghlib/http.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `errors.py`: `class GhError(Exception)` with attribute `code: int`; subclasses `AuthError` (code 2), `ApiError` (3), `NotFound` (4), `RateLimited` (5), `UsageError` (1).
  - `http.py`: `rest(method: str, path: str, body: dict | None = None, *, paginate: bool = False) -> dict | list`, `graphql(query: str, variables: dict) -> dict`, `token() -> str`.
  - Fixture mode: when `GH_FIXTURES` is set, `rest` and `graphql` read from `$GH_FIXTURES/<slug>.json` instead of the network, and append every request they would have sent, as one JSON object per line, to `$GH_FIXTURES/sent.jsonl`. The slug is `<METHOD>_<path>` with `/` replaced by `_`, a leading `_` stripped, and `?` replaced by `__`; for GraphQL the slug is `graphql`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
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

# Requests are recorded for later assertion.
sent=$(wc -l < "$FIX/sent.jsonl" | tr -d ' ')
check "records every request sent" "8" "$sent"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `ModuleNotFoundError: No module named 'ghlib'`.

- [ ] **Step 3: Write minimal implementation**

`skills/github-curl/ghlib/__init__.py`: empty file.

`skills/github-curl/ghlib/errors.py`:

```python
"""Typed failures, each carrying the process exit code it maps to."""


class GhError(Exception):
    code = 3

    def __init__(self, message):
        super().__init__(message)
        self.message = message


class UsageError(GhError):
    code = 1


class AuthError(GhError):
    code = 2


class ApiError(GhError):
    code = 3


class NotFound(GhError):
    code = 4


class RateLimited(GhError):
    code = 5
```

`skills/github-curl/ghlib/http.py`:

```python
"""REST and GraphQL transport.

When GH_FIXTURES is set, responses are read from that directory and no socket
is opened, which is what lets the suite run offline.
"""

import json
import os
import subprocess
import time
import urllib.error
import urllib.request

from . import errors

API = "https://api.github.com"
_MAX_RETRIES = 3


def token():
    tok = os.environ.get("GH_TOKEN")
    if not tok:
        try:
            tok = subprocess.run(
                ["gh", "auth", "token"], capture_output=True, text=True, check=False
            ).stdout.strip()
        except OSError:
            tok = ""
    if not tok:
        raise errors.AuthError("no GitHub token; run: gh auth login")
    return tok


def _slug(method, path):
    # The path's own leading "/" becomes a leading "_" once slashes are
    # replaced; strip it from the path alone, before joining, so the separator
    # between method and path is one underscore. Stripping after the join is a
    # no-op, because the joined string starts with the method's first letter.
    body = path.replace("/", "_").replace("?", "__").lstrip("_")
    return method + "_" + body


def _record(payload):
    dirname = os.environ.get("GH_FIXTURES")
    if not dirname:
        return
    with open(os.path.join(dirname, "sent.jsonl"), "a") as fh:
        fh.write(json.dumps(payload, sort_keys=True) + "\n")


def _fixture(slug):
    dirname = os.environ["GH_FIXTURES"]
    try:
        with open(os.path.join(dirname, slug + ".json")) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None


def _raise_for(status, data):
    message = data.get("message", "request failed") if isinstance(data, dict) else "request failed"
    if status == 429 or (status in (401, 403) and "rate limit" in message.lower()):
        raise errors.RateLimited(message)
    if status in (401, 403):
        raise errors.AuthError(message)
    if status == 404:
        raise errors.NotFound(message)
    raise errors.ApiError("%s (HTTP %s)" % (message, status))


def _request(method, url, body, headers):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            parsed = json.loads(raw) if raw else {}
        except ValueError:
            parsed = {"message": raw[:200]}
        return exc.code, parsed


def _call(method, path, body=None, accept="application/vnd.github+json"):
    slug = _slug(method, path)
    _record({"method": method, "path": path, "body": body})

    if os.environ.get("GH_FIXTURES"):
        data = _fixture(slug)
        if data is None:
            return None
        if isinstance(data, dict) and "__status" in data:
            status = data.pop("__status")
            if status >= 400:
                _raise_for(status, data)
        return data

    headers = {
        "Authorization": "Bearer " + token(),
        "Accept": accept,
        "Content-Type": "application/json",
        "User-Agent": "pr-review-plugin",
    }
    for attempt in range(_MAX_RETRIES):
        status, data = _request(method, API + path, body, headers)
        if status in (403, 429) and attempt < _MAX_RETRIES - 1:
            time.sleep(2 ** attempt)
            continue
        # The last attempt falls through here, so the final response decides:
        # _raise_for maps a persistent 429 to RateLimited (exit 5). There is no
        # post-loop raise, because the loop cannot exhaust without returning or
        # raising, and a line that can never run is a lie about the control flow.
        if status >= 400:
            _raise_for(status, data)
        return data


def rest(method, path, body=None, paginate=False, accept="application/vnd.github+json"):
    if not paginate:
        result = _call(method, path, body, accept)
        return {} if result is None else result

    items = []
    page = 1
    size = int(os.environ.get("GH_PAGE_SIZE", "100"))
    while True:
        sep = "&" if "?" in path else "?"
        suffix = "" if page == 1 else "%spage=%d" % (sep, page)
        chunk = _call(method, path + suffix, body, accept)
        if not chunk:
            break
        items.extend(chunk)
        if len(chunk) < size:
            break
        page += 1
    return items


def graphql(query, variables):
    _record({"method": "POST", "path": "/graphql", "query": query, "variables": variables})
    if os.environ.get("GH_FIXTURES"):
        return _fixture("graphql") or {}
    headers = {
        "Authorization": "Bearer " + token(),
        "Content-Type": "application/json",
        "User-Agent": "pr-review-plugin",
    }
    status, data = _request(
        "POST", "https://api.github.com/graphql", {"query": query, "variables": variables}, headers
    )
    if status >= 400:
        _raise_for(status, data)
    if "errors" in data:
        raise errors.ApiError(data["errors"][0].get("message", "graphql error"))
    return data.get("data") or {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib tests/run-tests.sh
git commit -m "Give the transport a fixture mode so the suite runs offline

Every response can be served from a directory of JSON files and every request
that would have gone out is appended to a log, which is what makes a write
subcommand assertable without a live repository to write to."
```

---

### Task 5: Repository detection and the CLI skeleton

**Files:**
- Create: `skills/github-curl/ghlib/repo.py`, `skills/github-curl/gh.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `errors` from Task 4.
- Produces:
  - `repo.py`: `owner_repo() -> tuple[str, str]` reading `--repo`/`GH_REPO` first, then `git remote get-url origin`; raises `errors.UsageError` when neither yields an `owner/name`. `nwo() -> str` returns `"owner/name"`.
  - `gh.py`: argparse CLI. Global options `--repo owner/name` and `--format NAME` (default `raw`). Each `ghlib` module exposes `register(subparsers)`; `gh.py` imports them in a fixed order and calls each. Handlers return a Python object; `gh.py` passes it to `fmt.render(name, obj)` and prints the result. Any `GhError` is printed as `error: <message>` on stderr and exits with `err.code`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `No module named 'ghlib.repo'`, and `gh.py` does not exist.

- [ ] **Step 3: Write minimal implementation**

`skills/github-curl/ghlib/repo.py`:

```python
"""Resolve the owner/name the subcommands act on."""

import os
import re
import subprocess

from . import errors

_OVERRIDE = None
_PATTERN = re.compile(r"(?:git@github\.com:|https://github\.com/)([^/]+)/(.+?)(?:\.git)?$")


def set_override(value):
    global _OVERRIDE
    _OVERRIDE = value


def owner_repo():
    candidate = _OVERRIDE or os.environ.get("GH_REPO")
    if candidate:
        if "/" not in candidate:
            raise errors.UsageError("--repo expects owner/name, got: " + candidate)
        owner, name = candidate.split("/", 1)
        return owner, name

    url = subprocess.run(
        ["git", "remote", "get-url", "origin"], capture_output=True, text=True, check=False
    ).stdout.strip()
    match = _PATTERN.search(url)
    if not match:
        raise errors.UsageError("no GitHub origin remote; pass --repo owner/name")
    return match.group(1), match.group(2)


def nwo():
    return "%s/%s" % owner_repo()
```

`skills/github-curl/gh.py`:

```python
#!/usr/bin/env python3
"""GitHub API calls for the pr-review plugin.

Every text body is passed with --body-file, never as an argument, because
multi-line markdown containing backticks and quotes does not survive a shell
argument reliably.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ghlib import assets, comments, errors, fmt, issues, meta, pr, repo, reviews  # noqa: E402

_MODULES = (pr, comments, reviews, meta, issues, assets)


def build_parser():
    parser = argparse.ArgumentParser(prog="gh.py", description=__doc__)
    parser.add_argument("--repo", help="owner/name, overriding the origin remote")
    parser.add_argument("--format", default="raw", help="output formatter (default: raw)")
    subparsers = parser.add_subparsers(dest="command")
    for module in _MODULES:
        module.register(subparsers)
    # Accept the global flags after the subcommand as well, because
    # `gh.py pr-get --format pr-number` is the form every caller writes and the
    # form the skills document. SUPPRESS is what makes this safe: without it the
    # subparser would overwrite the parent's value with a second default
    # whenever the flag is omitted after the subcommand.
    for sub in subparsers.choices.values():
        sub.add_argument("--repo", default=argparse.SUPPRESS)
        sub.add_argument("--format", default=argparse.SUPPRESS)
    return parser


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help(sys.stderr)
        return 1
    if args.repo:
        repo.set_override(args.repo)
    try:
        result = args.handler(args)
        rendered = fmt.render(args.format, result)
        if rendered:
            print(rendered)
        return 0
    except errors.GhError as exc:
        print("error: " + exc.message, file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Create placeholder modules so the imports resolve; each is filled in by a later task. For now, `comments.py`, `reviews.py`, `meta.py`, `issues.py`, `assets.py` and `pr.py` each contain only:

```python
def register(subparsers):
    return None
```

and `fmt.py` contains:

```python
import json


def render(name, obj):
    if obj is None:
        return ""
    if name == "raw":
        return json.dumps(obj, indent=2, sort_keys=True)
    raise NotImplementedError(name)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl tests/run-tests.sh
git commit -m "Route every subcommand through one parser and one error exit

Each domain module registers its own subparser, so adding a capability
touches one file, and a typed failure becomes a process exit code in exactly
one place instead of at each call site."
```

---

### Task 6: Output formatters

**Files:**
- Modify: `skills/github-curl/ghlib/fmt.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `fmt.render(name, obj) -> str` supporting `raw`, `error-check`, `pr-number`, `pr-url`, `pr-merge-status`, `checks-status`, `open-threads`, `resolved-threads`, `thread-summary`, `resolve-status`, `pr-details`, `issue-comments-summary`. An unknown name raises `errors.UsageError`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `NotImplementedError: pr-number`.

- [ ] **Step 3: Write minimal implementation**

Replace `skills/github-curl/ghlib/fmt.py`:

```python
"""Turn an API response into the shape a skill wants to read."""

import json

from . import errors


def _first(obj):
    if isinstance(obj, list):
        return obj[0] if obj else None
    return obj


def _raw(obj):
    return json.dumps(obj, indent=2, sort_keys=True)


def _error_check(obj):
    if isinstance(obj, dict) and "message" in obj and "documentation_url" in obj:
        raise errors.ApiError(obj["message"])
    return ""


def _pr_number(obj):
    item = _first(obj)
    return str(item["number"]) if item and "number" in item else ""


def _pr_url(obj):
    item = _first(obj)
    return item.get("html_url", "") if item else ""


def _pr_merge_status(obj):
    item = _first(obj) or {}
    if item.get("merged"):
        return "merged"
    return "open" if item.get("state") == "open" else "closed"


def _checks_status(obj):
    failed = [
        run.get("name", "?")
        for run in obj.get("check_runs", [])
        if run.get("conclusion") in ("failure", "timed_out", "cancelled")
    ]
    pending = [run for run in obj.get("check_runs", []) if run.get("status") != "completed"]
    if failed:
        result = "FAILURE"
    elif pending:
        result = "PENDING"
    else:
        result = "SUCCESS"
    return json.dumps({"result": result, "failed_checks": failed}, sort_keys=True)


def _threads(obj, resolved):
    items = obj if isinstance(obj, list) else obj.get("threads", [])
    return json.dumps([t for t in items if bool(t.get("isResolved")) is resolved], sort_keys=True)


def _thread_summary(obj):
    items = json.loads(_threads(obj, False))
    if not items:
        return "No open review threads."
    lines = ["| thread | file | line | author |", "|---|---|---|---|"]
    for thread in items:
        first = ((thread.get("comments") or {}).get("nodes") or [{}])[0]
        lines.append(
            "| %s | %s | %s | %s |"
            % (
                thread.get("id", "?"),
                thread.get("path", "?"),
                thread.get("line", "?"),
                (first.get("author") or {}).get("login", "?"),
            )
        )
    return "\n".join(lines)


def _resolve_status(obj):
    thread = (obj.get("resolveReviewThread") or {}).get("thread") or {}
    if thread.get("isResolved"):
        return "resolved"
    thread = (obj.get("unresolveReviewThread") or {}).get("thread") or {}
    if thread and not thread.get("isResolved"):
        return "unresolved"
    raise errors.ApiError("thread was not resolved")


def _issue_comments_summary(obj):
    if not isinstance(obj, list) or not obj:
        return "No issue comments."
    lines = ["| id | author | first line |", "|---|---|---|"]
    for comment in obj:
        body = (comment.get("body") or "").strip().splitlines()
        lines.append(
            "| %s | %s | %s |"
            % (
                comment.get("id", "?"),
                (comment.get("user") or {}).get("login", "?"),
                body[0][:60] if body else "",
            )
        )
    return "\n".join(lines)


def _pr_details(obj):
    item = _first(obj) or {}
    return json.dumps(
        {
            "number": item.get("number"),
            "title": item.get("title"),
            "state": item.get("state"),
            "draft": item.get("draft"),
            "head": (item.get("head") or {}).get("ref"),
            "base": (item.get("base") or {}).get("ref"),
            "url": item.get("html_url"),
        },
        sort_keys=True,
    )


_FORMATTERS = {
    "raw": _raw,
    "error-check": _error_check,
    "pr-number": _pr_number,
    "pr-url": _pr_url,
    "pr-merge-status": _pr_merge_status,
    "pr-details": _pr_details,
    "checks-status": _checks_status,
    "open-threads": lambda obj: _threads(obj, False),
    "resolved-threads": lambda obj: _threads(obj, True),
    "thread-summary": _thread_summary,
    "resolve-status": _resolve_status,
    "issue-comments-summary": _issue_comments_summary,
}


def render(name, obj):
    if obj is None:
        return ""
    handler = _FORMATTERS.get(name)
    if handler is None:
        raise errors.UsageError(
            "unknown --format %r; known: %s" % (name, ", ".join(sorted(_FORMATTERS)))
        )
    return handler(obj)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib/fmt.py tests/run-tests.sh
git commit -m "Make formatting a flag rather than a second script in a pipe

The previous shape piped raw JSON into a separate parser; folding the
formatters into one table keeps the same vocabulary for the skills while
leaving raw as the default, so the unprocessed response is still what a
reader sees unless a shape is asked for."
```

---

### Task 7: Carried-over read subcommands

**Files:**
- Modify: `skills/github-curl/ghlib/pr.py`, `skills/github-curl/ghlib/comments.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `http.rest`, `http.graphql`, `repo.owner_repo`, `fmt.render`.
- Produces: subcommands `auth-check`, `pr-get`, `pr-list`, `pr-status <pr>`, `pr-checks <pr>` in `pr.py`; `pr-threads <pr>`, `pr-comments <pr>`, `pr-issue-comments <pr>`, `pr-reviews <pr>`, `comment-resolved <node_id>`, `comments-resolved-batch <json_file>` in `comments.py`. Each registers a subparser whose `handler` attribute is the function to call.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `gh.py: error: argument command: invalid choice: 'auth-check'`, exit 2.

- [ ] **Step 3: Write minimal implementation**

`skills/github-curl/ghlib/pr.py`:

```python
"""Pull request reads."""

import subprocess

from . import http, repo


def _current_branch():
    return subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, check=False
    ).stdout.strip()


def auth_check(args):
    return http.rest("GET", "/user")


def pr_get(args):
    owner, name = repo.owner_repo()
    branch = args.branch or _current_branch()
    return http.rest("GET", "/repos/%s/%s/pulls?head=%s:%s" % (owner, name, owner, branch))


def pr_list(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/pulls?state=open" % (owner, name), paginate=True)


def pr_status(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/pulls/%s" % (owner, name, args.pr))


def pr_checks(args):
    owner, name = repo.owner_repo()
    pull = http.rest("GET", "/repos/%s/%s/pulls/%s" % (owner, name, args.pr))
    sha = (pull.get("head") or {}).get("sha", "")
    statuses = http.rest("GET", "/repos/%s/%s/commits/%s/status" % (owner, name, sha))
    runs = http.rest("GET", "/repos/%s/%s/commits/%s/check-runs" % (owner, name, sha))
    return {"statuses": statuses, "check_runs": runs.get("check_runs", [])}


def register(subparsers):
    parser = subparsers.add_parser("auth-check", help="verify the token works")
    parser.set_defaults(handler=auth_check)

    parser = subparsers.add_parser("pr-get", help="get the PR for a branch")
    parser.add_argument("--branch", default=None, help="defaults to the current branch")
    parser.set_defaults(handler=pr_get)

    parser = subparsers.add_parser("pr-list", help="list open PRs")
    parser.set_defaults(handler=pr_list)

    parser = subparsers.add_parser("pr-status", help="get PR state")
    parser.add_argument("pr", type=int)
    parser.set_defaults(handler=pr_status)

    parser = subparsers.add_parser("pr-checks", help="combined status and check runs")
    parser.add_argument("pr", type=int)
    parser.set_defaults(handler=pr_checks)
```

`skills/github-curl/ghlib/comments.py`:

```python
"""Review threads and comments: reads, plus the resolve mutations."""

import json

from . import errors, http, repo

_THREADS_QUERY = """
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated path line
          comments(first:50) { nodes { id body author { login } } }
        }
      }
    }
  }
}
"""


_RESOLVE = """
mutation($id:ID!) {
  resolveReviewThread(input:{threadId:$id}) { thread { id isResolved } }
}
"""

_UNRESOLVE = """
mutation($id:ID!) {
  unresolveReviewThread(input:{threadId:$id}) { thread { id isResolved } }
}
"""

_MINIMIZED = """
query($id:ID!) { node(id:$id) { ... on IssueComment { isMinimized } } }
"""


def pr_threads(args):
    owner, name = repo.owner_repo()
    data = http.graphql(_THREADS_QUERY, {"owner": owner, "name": name, "number": int(args.pr)})
    nodes = (
        ((data.get("repository") or {}).get("pullRequest") or {})
        .get("reviewThreads") or {}
    ).get("nodes", [])
    return nodes


def pr_comments(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "GET", "/repos/%s/%s/pulls/%s/comments" % (owner, name, args.pr), paginate=True
    )


def pr_issue_comments(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "GET", "/repos/%s/%s/issues/%s/comments" % (owner, name, args.pr), paginate=True
    )


def pr_reviews(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "GET", "/repos/%s/%s/pulls/%s/reviews" % (owner, name, args.pr), paginate=True
    )


def comment_resolved(args):
    return http.graphql(_MINIMIZED, {"id": args.node_id})


def comments_resolved_batch(args):
    try:
        with open(args.json_file, encoding="utf-8") as fh:
            ids = json.load(fh)
    except (OSError, ValueError) as exc:
        raise errors.UsageError("cannot read %s: %s" % (args.json_file, exc))
    if not isinstance(ids, list):
        raise errors.UsageError("%s must hold a JSON array of node ids" % args.json_file)
    return {node_id: http.graphql(_MINIMIZED, {"id": node_id}) for node_id in ids}


def thread_resolve(args):
    return http.graphql(_RESOLVE, {"id": args.thread_id})


def comment_resolve(args):
    return http.graphql(_RESOLVE, {"id": args.node_id})


def comment_unresolve(args):
    return http.graphql(_UNRESOLVE, {"id": args.node_id})


def register(subparsers):
    for cmd, handler, arg in (
        ("pr-threads", pr_threads, "pr"),
        ("pr-comments", pr_comments, "pr"),
        ("pr-issue-comments", pr_issue_comments, "pr"),
        ("pr-reviews", pr_reviews, "pr"),
        ("comment-resolved", comment_resolved, "node_id"),
        ("thread-resolve", thread_resolve, "thread_id"),
        ("comment-resolve", comment_resolve, "node_id"),
        ("comment-unresolve", comment_unresolve, "node_id"),
    ):
        parser = subparsers.add_parser(cmd)
        # A PR number is validated by argparse, which routes a bad value through
        # the overridden error() to a mapped usage exit instead of a traceback.
        parser.add_argument(arg, type=int if arg == "pr" else str)
        parser.set_defaults(handler=handler)

    parser = subparsers.add_parser("comments-resolved-batch")
    parser.add_argument("json_file", help="file holding a JSON array of node ids")
    parser.set_defaults(handler=comments_resolved_batch)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib tests/run-tests.sh
git commit -m "Port the sixteen existing calls without renaming any of them

The skills that will be extracted next refer to these names throughout, so
the vocabulary survives the move to Python and only the pipe into a second
script disappears."
```

---

### Task 8: Body-file plumbing and the review write subcommands

This is the task the design exists for. The regression test in step 1 is the point of the whole rewrite.

**Files:**
- Create: `skills/github-curl/ghlib/bodies.py`
- Modify: `skills/github-curl/ghlib/reviews.py`, `skills/github-curl/ghlib/comments.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `http.rest`, `repo.owner_repo`, `errors`.
- Produces:
  - `bodies.py`: `read(path: str) -> str` returning the file's exact bytes decoded as UTF-8 with no stripping, no newline translation and no shell interpretation; raises `errors.UsageError` when the file is missing or empty.
  - `reviews.py`: `review-submit <pr> --event {COMMENT,APPROVE,REQUEST_CHANGES} [--body-file P] [--comments-file P]`.
  - `comments.py` gains: `thread-reply <thread_id> --body-file P`, `pr-comment <pr> --body-file P`, `comment-edit <comment_id> --body-file P`, `comment-delete <comment_id>`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `invalid choice: 'pr-comment'`.

- [ ] **Step 3: Write minimal implementation**

`skills/github-curl/ghlib/bodies.py`:

```python
"""Read a text body from a file.

Bodies never travel as command-line arguments: multi-line markdown with
backticks, quotes and $VAR sequences does not survive shell quoting intact,
and that failure is silent -- the request succeeds with mangled text.
"""

from . import errors


def read(path):
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            content = fh.read()
    except OSError as exc:
        raise errors.UsageError("cannot read --body-file %s: %s" % (path, exc))
    if not content.strip():
        raise errors.UsageError("--body-file %s is empty" % path)
    return content
```

`skills/github-curl/ghlib/reviews.py`:

```python
"""Submit a review, optionally with inline comments."""

import json

from . import bodies, errors, http, repo


def review_submit(args):
    owner, name = repo.owner_repo()
    payload = {"event": args.event}
    if args.body_file:
        payload["body"] = bodies.read(args.body_file)
    if args.comments_file:
        try:
            with open(args.comments_file, encoding="utf-8") as fh:
                payload["comments"] = json.load(fh)
        except (OSError, ValueError) as exc:
            raise errors.UsageError("cannot read --comments-file: %s" % exc)
    if args.event != "APPROVE" and "body" not in payload and "comments" not in payload:
        raise errors.UsageError("a %s review needs --body-file or --comments-file" % args.event)
    return http.rest("POST", "/repos/%s/%s/pulls/%s/reviews" % (owner, name, args.pr), payload)


def register(subparsers):
    parser = subparsers.add_parser("review-submit", help="submit a review")
    parser.add_argument("pr", type=int)
    parser.add_argument("--event", required=True, choices=("COMMENT", "APPROVE", "REQUEST_CHANGES"))
    parser.add_argument("--body-file", dest="body_file", default=None)
    parser.add_argument(
        "--comments-file",
        dest="comments_file",
        default=None,
        help="JSON array of {path, line, side, body} objects",
    )
    parser.set_defaults(handler=review_submit)
```

Append to `skills/github-curl/ghlib/comments.py`:

```python
def thread_reply(args):
    body = bodies.read(args.body_file)
    return http.graphql(
        """
        mutation($id:ID!, $body:String!) {
          addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id, body:$body}) {
            comment { id url }
          }
        }
        """,
        {"id": args.thread_id, "body": body},
    )


def pr_comment(args):
    owner, name = repo.owner_repo()
    body = bodies.read(args.body_file)
    return http.rest(
        "POST", "/repos/%s/%s/issues/%s/comments" % (owner, name, args.pr), {"body": body}
    )


def comment_edit(args):
    owner, name = repo.owner_repo()
    body = bodies.read(args.body_file)
    return http.rest(
        "PATCH", "/repos/%s/%s/issues/comments/%s" % (owner, name, args.comment_id), {"body": body}
    )


def comment_delete(args):
    owner, name = repo.owner_repo()
    return http.rest("DELETE", "/repos/%s/%s/issues/comments/%s" % (owner, name, args.comment_id))
```

Add `bodies` to `comments.py`'s imports (`from . import bodies, http, repo`), then extend its `register` with:

```python
    parser = subparsers.add_parser("thread-reply", help="reply inside a review thread")
    parser.add_argument("thread_id")
    parser.add_argument("--body-file", dest="body_file", required=True)
    parser.set_defaults(handler=thread_reply)

    parser = subparsers.add_parser("pr-comment", help="post a general PR comment")
    parser.add_argument("pr", type=int)
    parser.add_argument("--body-file", dest="body_file", required=True)
    parser.set_defaults(handler=pr_comment)

    parser = subparsers.add_parser("comment-edit")
    parser.add_argument("comment_id")
    parser.add_argument("--body-file", dest="body_file", required=True)
    parser.set_defaults(handler=comment_edit)

    parser = subparsers.add_parser("comment-delete")
    parser.add_argument("comment_id")
    parser.set_defaults(handler=comment_delete)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib tests/run-tests.sh
git commit -m "Carry every text body by file so markdown survives intact

The previous scripts documented a broken GraphQL payload as a known error and
told the reader to check their shell escaping. A body containing backticks,
quotes and a dollar sign now round-trips byte for byte, and the test that
proves it feeds all three at once."
```

---

### Task 9: PR content reads

**Files:**
- Modify: `skills/github-curl/ghlib/pr.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `http.rest`, `repo.owner_repo`.
- Produces: `pr-diff <pr>` (returns `{"diff": "<unified diff text>"}` using the `application/vnd.github.v3.diff` accept header), `pr-files <pr>` (paginated, paths and patches), `pr-commits <pr>` (paginated), `file-at-ref <path> <ref>` (returns `{"path", "ref", "content"}` with content already base64-decoded).

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
echo "== pr content =="

printf '%s' '[{"filename":"src/a.py","status":"modified","patch":"@@ -1 +1 @@"}]' \
  > "$F3/GET_repos_acme_thing_pulls_7_files.json"
check "pr-files lists changed paths" "src/a.py" \
  "$(gh3 pr-files 7 --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["filename"])')"

printf '%s' '{"content":"aGVsbG8=","encoding":"base64"}' \
  > "$F3/GET_repos_acme_thing_contents_README.md__ref=main.json"
check "file-at-ref decodes base64 content" "hello" \
  "$(gh3 file-at-ref README.md main --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)["content"])')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `invalid choice: 'pr-files'`.

- [ ] **Step 3: Write minimal implementation**

Add `import base64` to the import block at the top of
`skills/github-curl/ghlib/pr.py`, then append:

```python
def pr_diff(args):
    owner, name = repo.owner_repo()
    result = http.rest(
        "GET",
        "/repos/%s/%s/pulls/%s" % (owner, name, args.pr),
        accept="application/vnd.github.v3.diff",
    )
    return {"diff": result if isinstance(result, str) else result.get("diff", "")}


def pr_files(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/pulls/%s/files" % (owner, name, args.pr), paginate=True)


def pr_commits(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/pulls/%s/commits" % (owner, name, args.pr), paginate=True)


def file_at_ref(args):
    owner, name = repo.owner_repo()
    data = http.rest(
        "GET", "/repos/%s/%s/contents/%s?ref=%s" % (owner, name, args.path, args.ref)
    )
    raw = data.get("content", "")
    if data.get("encoding") == "base64":
        raw = base64.b64decode(raw).decode("utf-8", "replace")
    return {"path": args.path, "ref": args.ref, "content": raw}
```

Extend `pr.py`'s `register`:

```python
    for cmd, handler in (("pr-diff", pr_diff), ("pr-files", pr_files), ("pr-commits", pr_commits)):
        parser = subparsers.add_parser(cmd)
        parser.add_argument("pr", type=int)
        parser.set_defaults(handler=handler)

    parser = subparsers.add_parser("file-at-ref", help="read a file at a ref")
    parser.add_argument("path")
    parser.add_argument("ref")
    parser.set_defaults(handler=file_at_ref)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib/pr.py tests/run-tests.sh
git commit -m "Read a pull request's contents without checking it out

A review of someone else's branch previously leaned on local git state, which
means the working copy had to be moved to look at a diff. Fetching the files
and their patches directly removes that constraint."
```

---

### Task 10: PR metadata, issues and search

**Files:**
- Modify: `skills/github-curl/ghlib/meta.py`, `skills/github-curl/ghlib/issues.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `http.rest`, `http.graphql`, `bodies.read`, `repo.owner_repo`.
- Produces: in `meta.py` — `pr-update <pr> [--title T] [--body-file P] [--base B] [--state {open,closed}]`, `pr-ready <pr>`, `label-add <pr> <label>...`, `label-remove <pr> <label>`, `reviewer-add <pr> <user>...`, `reviewer-remove <pr> <user>...`, `assignee-add <pr> <user>...`, `assignee-remove <pr> <user>...`. In `issues.py` — `issue-view <n>`, `issue-list`, `issue-search <query>`, `pr-linked-issues <pr>`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
echo "== metadata and issues =="

printf '%s' '{"number":7,"title":"New"}' > "$F3/PATCH_repos_acme_thing_pulls_7.json"
gh3 pr-update 7 --title "New" >/dev/null
title=$(python3 -c "
import json
for line in open('$F3/sent.jsonl'):
    row = json.loads(line)
    if row['method'] == 'PATCH' and row['path'].endswith('/pulls/7'):
        print(row['body']['title'])
")
check "pr-update sends only the given fields" "New" "$title"

check_status "pr-update with no field exits 1" 1 gh3 pr-update 7

printf '%s' '[{"name":"bug"}]' > "$F3/POST_repos_acme_thing_issues_7_labels.json"
check "label-add returns the label set" "bug" \
  "$(gh3 label-add 7 bug --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])')"

printf '%s' '{"number":3,"title":"An issue"}' > "$F3/GET_repos_acme_thing_issues_3.json"
check "issue-view fetches the issue" "An issue" \
  "$(gh3 issue-view 3 --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"

printf '%s' '{"items":[{"number":9}]}' > "$F3/GET_search_issues__q=repo:acme_thing+bug.json"
check "issue-search queries the search API" "9" \
  "$(gh3 issue-search bug --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["number"])')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `invalid choice: 'pr-update'`.

- [ ] **Step 3: Write minimal implementation**

`skills/github-curl/ghlib/meta.py`:

```python
"""Pull request metadata: title, body, base, state, labels, people."""

from . import bodies, errors, http, repo

_READY = """
mutation($id:ID!) {
  markPullRequestReadyForReview(input:{pullRequestId:$id}) {
    pullRequest { number isDraft }
  }
}
"""


def pr_update(args):
    owner, name = repo.owner_repo()
    payload = {}
    if args.title:
        payload["title"] = args.title
    if args.body_file:
        payload["body"] = bodies.read(args.body_file)
    if args.base:
        payload["base"] = args.base
    if args.state:
        payload["state"] = args.state
    if not payload:
        raise errors.UsageError("pr-update needs at least one of --title/--body-file/--base/--state")
    return http.rest("PATCH", "/repos/%s/%s/pulls/%s" % (owner, name, args.pr), payload)


def pr_ready(args):
    owner, name = repo.owner_repo()
    pull = http.rest("GET", "/repos/%s/%s/pulls/%s" % (owner, name, args.pr))
    return http.graphql(_READY, {"id": pull["node_id"]})


def label_add(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "POST", "/repos/%s/%s/issues/%s/labels" % (owner, name, args.pr), {"labels": args.names}
    )


def label_remove(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "DELETE", "/repos/%s/%s/issues/%s/labels/%s" % (owner, name, args.pr, args.names[0])
    )


def reviewer_add(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "POST",
        "/repos/%s/%s/pulls/%s/requested_reviewers" % (owner, name, args.pr),
        {"reviewers": args.names},
    )


def reviewer_remove(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "DELETE",
        "/repos/%s/%s/pulls/%s/requested_reviewers" % (owner, name, args.pr),
        {"reviewers": args.names},
    )


def assignee_add(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "POST", "/repos/%s/%s/issues/%s/assignees" % (owner, name, args.pr), {"assignees": args.names}
    )


def assignee_remove(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "DELETE",
        "/repos/%s/%s/issues/%s/assignees" % (owner, name, args.pr),
        {"assignees": args.names},
    )


def register(subparsers):
    parser = subparsers.add_parser("pr-update", help="change title, body, base or state")
    parser.add_argument("pr", type=int)
    parser.add_argument("--title", default=None)
    parser.add_argument("--body-file", dest="body_file", default=None)
    parser.add_argument("--base", default=None)
    parser.add_argument("--state", default=None, choices=("open", "closed"))
    parser.set_defaults(handler=pr_update)

    parser = subparsers.add_parser("pr-ready", help="mark a draft PR ready for review")
    parser.add_argument("pr", type=int)
    parser.set_defaults(handler=pr_ready)

    for cmd, handler in (
        ("label-add", label_add),
        ("label-remove", label_remove),
        ("reviewer-add", reviewer_add),
        ("reviewer-remove", reviewer_remove),
        ("assignee-add", assignee_add),
        ("assignee-remove", assignee_remove),
    ):
        parser = subparsers.add_parser(cmd)
        parser.add_argument("pr", type=int)
        parser.add_argument("names", nargs="+")
        parser.set_defaults(handler=handler)
```

`skills/github-curl/ghlib/issues.py`:

```python
"""Issues and cross-repository search."""

from . import http, repo

_LINKED = """
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      closingIssuesReferences(first:20) { nodes { number title url } }
    }
  }
}
"""


def issue_view(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/issues/%s" % (owner, name, args.number))


def issue_list(args):
    owner, name = repo.owner_repo()
    return http.rest(
        "GET", "/repos/%s/%s/issues?state=%s" % (owner, name, args.state), paginate=True
    )


def issue_search(args):
    query = "repo:%s %s" % (repo.nwo(), " ".join(args.terms))
    return http.rest("GET", "/search/issues?q=" + query.replace(" ", "+"))


def pr_linked_issues(args):
    owner, name = repo.owner_repo()
    data = http.graphql(_LINKED, {"owner": owner, "name": name, "number": int(args.pr)})
    return (
        ((data.get("repository") or {}).get("pullRequest") or {})
        .get("closingIssuesReferences") or {}
    )


def register(subparsers):
    parser = subparsers.add_parser("issue-view")
    parser.add_argument("number")
    parser.set_defaults(handler=issue_view)

    parser = subparsers.add_parser("issue-list")
    parser.add_argument("--state", default="open", choices=("open", "closed", "all"))
    parser.set_defaults(handler=issue_list)

    parser = subparsers.add_parser("issue-search")
    parser.add_argument("terms", nargs="+")
    parser.set_defaults(handler=issue_search)

    parser = subparsers.add_parser("pr-linked-issues")
    parser.add_argument("pr", type=int)
    parser.set_defaults(handler=pr_linked_issues)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib tests/run-tests.sh
git commit -m "Cover the rest of a pull request's lifecycle

Labels, reviewers, assignees, draft promotion and the title or base a PR was
opened against were all still manual steps outside the toolkit, which meant a
workflow that could review a change could not finish preparing it."
```

---

### Task 11: Image upload

**Files:**
- Modify: `skills/github-curl/ghlib/assets.py`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `http.rest`, `repo.owner_repo`, `errors`.
- Produces: `image-upload <file> [--branch pr-assets]`, returning `{"url", "markdown", "path", "reused"}`. Filename is `<sha256 of the bytes>.<original extension, lowercased>`. If the path already exists on the branch, no write happens and `reused` is `true`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
echo "== image upload =="

printf 'not really a png' > "$WORK/shot.png"
SHA=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$WORK/shot.png")

printf '%s' '{"__status":404,"message":"Not Found"}' > "$F3/GET_repos_acme_thing_contents_${SHA}.png__ref=pr-assets.json"
printf '%s' '{"ref":"refs/heads/pr-assets"}' > "$F3/GET_repos_acme_thing_git_ref_heads_pr-assets.json"
printf '%s' '{"content":{"path":"'"$SHA"'.png"}}' > "$F3/PUT_repos_acme_thing_contents_${SHA}.png.json"

out=$(gh3 image-upload "$WORK/shot.png" --format raw)
check "url points at the assets branch" \
  "https://raw.githubusercontent.com/acme/thing/pr-assets/$SHA.png" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
check "markdown is ready to paste" \
  "![](https://raw.githubusercontent.com/acme/thing/pr-assets/$SHA.png)" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["markdown"])')"

# An identical file already on the branch is not re-uploaded.
printf '%s' '{"sha":"abc","path":"'"$SHA"'.png"}' > "$F3/GET_repos_acme_thing_contents_${SHA}.png__ref=pr-assets.json"
check "an existing asset is reused" "True" \
  "$(gh3 image-upload "$WORK/shot.png" --format raw | python3 -c 'import json,sys; print(json.load(sys.stdin)["reused"])')"

check_status "a missing image exits 1" 1 gh3 image-upload "$WORK/absent.png"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `invalid choice: 'image-upload'`.

- [ ] **Step 3: Write minimal implementation**

`skills/github-curl/ghlib/assets.py`:

```python
"""Store an image in the repository and return a URL that renders in a PR.

The GitHub web upload endpoint would produce a user-attachments URL, but it is
authenticated by browser session cookies rather than by a scoped token, so it
is deliberately not used here.
"""

import base64
import hashlib
import os

from . import errors, http, repo


def _blob_name(path):
    with open(path, "rb") as fh:
        payload = fh.read()
    if not payload:
        raise errors.UsageError("image file is empty: " + path)
    digest = hashlib.sha256(payload).hexdigest()
    ext = os.path.splitext(path)[1].lower() or ".bin"
    return digest + ext, payload


def _ensure_branch(owner, name, branch):
    try:
        http.rest("GET", "/repos/%s/%s/git/ref/heads/%s" % (owner, name, branch))
        return
    except errors.NotFound:
        pass
    default = http.rest("GET", "/repos/%s/%s" % (owner, name)).get("default_branch", "main")
    head = http.rest("GET", "/repos/%s/%s/git/ref/heads/%s" % (owner, name, default))
    http.rest(
        "POST",
        "/repos/%s/%s/git/refs" % (owner, name),
        {"ref": "refs/heads/" + branch, "sha": head["object"]["sha"]},
    )


def image_upload(args):
    if not os.path.isfile(args.file):
        raise errors.UsageError("no such image file: " + args.file)
    owner, name = repo.owner_repo()
    blob, payload = _blob_name(args.file)
    branch = args.branch

    reused = False
    try:
        http.rest("GET", "/repos/%s/%s/contents/%s?ref=%s" % (owner, name, blob, branch))
        reused = True
    except errors.NotFound:
        _ensure_branch(owner, name, branch)
        http.rest(
            "PUT",
            "/repos/%s/%s/contents/%s" % (owner, name, blob),
            {
                "message": "Add review asset " + blob,
                "content": base64.b64encode(payload).decode(),
                "branch": branch,
            },
        )

    url = "https://raw.githubusercontent.com/%s/%s/%s/%s" % (owner, name, branch, blob)
    return {"url": url, "markdown": "![](%s)" % url, "path": blob, "reused": reused}


def register(subparsers):
    parser = subparsers.add_parser("image-upload", help="store an image and return its URL")
    parser.add_argument("file")
    parser.add_argument("--branch", default="pr-assets")
    parser.set_defaults(handler=image_upload)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/ghlib/assets.py tests/run-tests.sh
git commit -m "Attach an image to a review with a scoped token

The browser flow for attachments needs whole-account session cookies stored on
disk, so an image is committed to an orphan branch instead and addressed by
the hash of its bytes, which also makes uploading the same screenshot twice a
no-op."
```

---

### Task 12: The github-curl skill document

**Files:**
- Create: `skills/github-curl/SKILL.md`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: every subcommand registered in Tasks 7-11.
- Produces: the skill document that other skills read to learn the tool. Must document all subcommands and all `--format` names, and use `${CLAUDE_PLUGIN_ROOT}` paths exclusively.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
echo "== skill documents =="

SKILLDOC="$ROOT/skills/github-curl/SKILL.md"

# Every registered subcommand must appear in the document.
undocumented=$(python3 - "$GHDIR" "$SKILLDOC" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import gh
parser = gh.build_parser()
actions = [a for a in parser._actions if hasattr(a, "choices") and a.dest == "command"]
names = sorted(actions[0].choices) if actions else []
doc = open(sys.argv[2]).read()
print(" ".join(n for n in names if n not in doc))
PY
)
check "every subcommand is documented" "" "$undocumented"

# No relative .claude/skills path may survive the move into a plugin.
stale=$(grep -rn '\.claude/skills/' "$ROOT/skills" || true)
check "no relative skill paths" "" "$stale"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `SKILL.md` does not exist, so every subcommand is reported undocumented.

- [ ] **Step 3: Write minimal implementation**

Write `skills/github-curl/SKILL.md` with frontmatter:

```markdown
---
name: github-curl
description: |
  Use when making GitHub API calls. Provides a stdlib Python tool covering
  pull requests, review threads, comments, reviews, metadata, issues and image
  attachments, without the gh CLI.
  WHEN: any GitHub API interaction (PRs, threads, comments, reviews, labels,
  issues, image upload).
  WHEN NOT: non-GitHub APIs.
---
```

The body must contain, at minimum:

1. An **Overview** naming `${CLAUDE_PLUGIN_ROOT}/skills/github-curl/gh.py` as the single entry point and stating that it uses only the Python standard library.
2. A **Preflight** line: every caller runs `bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh` first and stops on a non-zero exit.
3. A **Usage** section whose examples use the new form, for example:

```bash
GH="${CLAUDE_PLUGIN_ROOT}/skills/github-curl/gh.py"

PR=$(python3 "$GH" pr-get --format pr-number)
python3 "$GH" pr-threads "$PR" --format thread-summary

cat > /tmp/comment.md <<'EOF'
Multi-line markdown with `backticks` is safe here.
EOF
python3 "$GH" pr-comment "$PR" --body-file /tmp/comment.md
```

4. A **Subcommands** table listing every name produced by Tasks 7-11 with its arguments and one-line description.
5. A **Formatters** table listing every `--format` name from Task 6.
6. A **Bodies** section stating the rule: bodies are always passed with `--body-file`; there is no `--body` form; write the text to a file first.
7. An **Exit codes** table matching Global Constraints.
8. An **Image upload** section explaining the orphan `pr-assets` branch, the hash-based filename, and that push access is required.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/github-curl/SKILL.md tests/run-tests.sh
git commit -m "Document the tool and let the suite enforce the documentation

A subcommand that exists but is not written down is a subcommand no skill will
ever call, so the test reads the parser and fails when a name is missing from
the document rather than trusting the author to remember."
```

---

### Task 13: Extract start-review and auto-fix-loop

**Files:**
- Create: `skills/start-review/SKILL.md`, `skills/auto-fix-loop/SKILL.md`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: the `github-curl` skill document and `scripts/preflight.sh`.
- Produces: two plugin skills whose frontmatter `name` is `start-review` and `auto-fix-loop` (no `pr-review-toolkit:` prefix — the plugin supplies the namespace).

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
for skill in start-review auto-fix-loop; do
  doc="$ROOT/skills/$skill/SKILL.md"
  check "$skill frontmatter name" "$skill" \
    "$(awk '/^name:/ {print $2; exit}' "$doc" 2>/dev/null)"
  check "$skill runs the preflight" "1" \
    "$(grep -c 'scripts/preflight.sh' "$doc" 2>/dev/null || echo 0)"
  check "$skill has no old namespace prefix" "" \
    "$(grep -o 'pr-review-toolkit:[a-z-]*' "$doc" 2>/dev/null | grep -v 'pr-review-toolkit:review-pr' || true)"
  check "$skill has no hard-coded French rule" "" \
    "$(grep -niE '^\| .*\| \*\*French\*\*' "$doc" 2>/dev/null || true)"
done
```

Note: `pr-review-toolkit:review-pr` is excluded because it is the upstream command this plugin legitimately depends on.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — the three documents do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Copy the sources, then apply the six portability changes from `docs/design.md` §6:

```bash
mkdir -p skills/start-review skills/auto-fix-loop
cp ~/dev/www/geonative-api/.claude/skills/pr-review-toolkit:start-review/SKILL.md skills/start-review/SKILL.md
cp ~/dev/www/geonative-api/.claude/skills/pr-review-toolkit:auto-fix-loop/SKILL.md skills/auto-fix-loop/SKILL.md
```

Then edit each document by hand:

1. Frontmatter `name:` becomes `start-review` / `auto-fix-loop`.
2. Add, immediately after the Overview, the line: `**Preflight:** run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh` as the first action. A non-zero exit stops the skill; print its output verbatim and do nothing else.`
3. Replace the Language Rules table in `start-review` with:

```markdown
## Language Rules

| Output | Language |
|--------|----------|
| Chat prose and analysis | the language the user writes in |
| Draft comment shown in chat | the user's language **and** English, side by side |
| Comment actually posted to the PR | **English, always** |
| Anything written to a file (code, comments, commits, PR bodies) | **English only** |

Never ask which language to post in. Everything that lands on GitHub is English.
```

4. Replace every `.claude/skills/github-curl/gh-api.sh` reference with `${CLAUDE_PLUGIN_ROOT}/skills/github-curl/gh.py`, and every `bash gh-api.sh X | python3 gh-parse.py Y` example with `python3 "$GH" X --format Y`.
5. Make `norms.md` and project-`CLAUDE.md` references conditional: prefix each with "If the repository has one,".
6. Announcement strings become `/pr-review:start-review` and `/pr-review:auto-fix-loop`. The reference to `/pr-review-toolkit:review-pr` in start-review §1.1 is left unchanged: that is the upstream command this plugin depends on.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, with 8 new `ok` lines (4 checks for each of the two skills).

- [ ] **Step 5: Commit**

```bash
git add skills/start-review skills/auto-fix-loop tests/run-tests.sh
git commit -m "Move the walkthrough and the fix loop out of one repository

Both existed in several drifted copies with no single newest one; the version
kept here is the revised walkthrough that treats a draft comment, not a code
change, as the default deliverable. The language table now follows the reader
instead of naming French, while everything published stays English."
```

---

### Task 14: Extract process-comments

**Files:**
- Create: `skills/process-comments/SKILL.md`, `skills/process-comments/scripts/filter_reviews.py`, `skills/process-comments/scripts/extract_user_login.py`, `skills/process-comments/scripts/extract_paths.py`
- Test: `tests/run-tests.sh` — extend the Task 13 loop to cover this skill

**Interfaces:**
- Consumes: `github-curl`, `scripts/preflight.sh`.
- Produces: the `process-comments` skill, taken from `geonative-front-office` (the copy with the triage tiering), not from `geonative-api`.

- [ ] **Step 1: Confirm the source is a superset**

Run:

```bash
diff ~/dev/www/geonative-api/.claude/skills/pr-review-toolkit:process-comments/SKILL.md \
     ~/dev/www/geonative-front-office/.claude/skills/pr-review-toolkit:process-comments/SKILL.md \
  | grep '^<' | head -40
```

Expected: only lines that also appear, reworded, in the front-office copy. If a substantive rule exists only in the `geonative-api` copy, port it into the extracted document before continuing, and say so in the commit body.

- [ ] **Step 2: Extend the skill loop, then run it to verify it fails**

Change the loop header added in Task 13 from

```bash
for skill in start-review auto-fix-loop; do
```

to

```bash
for skill in start-review auto-fix-loop process-comments; do
```

Run: `bash tests/run-tests.sh`
Expected: FAIL on the four new `process-comments` checks.

- [ ] **Step 3: Write minimal implementation**

```bash
mkdir -p skills/process-comments/scripts
SRC=~/dev/www/geonative-front-office/.claude/skills/pr-review-toolkit:process-comments
cp "$SRC/SKILL.md" skills/process-comments/SKILL.md
cp "$SRC"/*.py skills/process-comments/scripts/
```

Apply the same six portability changes as Task 13, plus:

- The frontmatter `name:` in the source reads `pr-review-toolkit-process-comments`; it becomes `process-comments`.
- Step 0's parallel fetch block: replace the four `bash gh-api.sh …` calls with `python3 "$GH" …` calls carrying the matching `--format`, where `GH="${CLAUDE_PLUGIN_ROOT}/skills/github-curl/gh.py"`.
- The script paths used inside the document become `${CLAUDE_PLUGIN_ROOT}/skills/process-comments/scripts/<name>.py`.
- The "REQUIRED SUB-SKILL: Use `github-curl`" line stays, since that skill ships in this same plugin.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add skills/process-comments tests/run-tests.sh
git commit -m "Keep the copy that triages before it works

Four generations of this document were in circulation and the newest was not
in the repository that held the newest walkthrough. The one kept here
announces the workload first and makes the expensive context-building steps
conditional on there being three or more comments to process."
```

---

### Task 15: Install command, doctor command, README and CLAUDE.md

**Files:**
- Create: `install.sh`, `commands/install.md`, `commands/doctor.md`, `README.md`, `CLAUDE.md`
- Test: `tests/run-tests.sh` (append)

**Interfaces:**
- Consumes: `scripts/preflight.sh`.
- Produces: `/pr-review:install` and `/pr-review:doctor`, both running the same diagnostic. `install.sh` writes nothing; it runs the preflight and prints a summary.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
echo "== install =="

check_status "install.sh succeeds when dependencies are met" 0 \
  env HOME="$WORK" PR_REVIEW_SETTINGS="$WORK/cfg/settings.json" PR_REVIEW_SKIP_AUTH=1 \
    sh -c "cd '$WORK/repo' && bash '$ROOT/install.sh'"

settings '{"enabledPlugins":{}}'
check_status "install.sh fails when a dependency is absent" 10 \
  env HOME="$WORK" PR_REVIEW_SETTINGS="$WORK/cfg/settings.json" PR_REVIEW_SKIP_AUTH=1 \
    sh -c "cd '$WORK/repo' && bash '$ROOT/install.sh'"

# install.sh must not write anywhere outside the repository.
before=$(find "$WORK/cfg" -type f | sort)
env HOME="$WORK" PR_REVIEW_SETTINGS="$WORK/cfg/settings.json" PR_REVIEW_SKIP_AUTH=1 \
  sh -c "cd '$WORK/repo' && bash '$ROOT/install.sh'" >/dev/null 2>&1
check "install.sh writes nothing" "$before" "$(find "$WORK/cfg" -type f | sort)"

check "every command file declares a description" "2" \
  "$(grep -l '^description:' "$ROOT"/commands/*.md | wc -l | tr -d ' ')"
```

Restore the passing settings after this block:

```bash
settings '{"enabledPlugins":{"pr-review-toolkit@claude-plugins-official":true,"code-review@claude-plugins-official":true}}'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `install.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

`install.sh`:

```bash
#!/usr/bin/env bash
# Verify only. This plugin writes nothing outside its own directory, so there
# is nothing to install and nothing to undo.
set -u

ROOT=$(cd "$(dirname "$0")" && pwd)

if bash "$ROOT/scripts/preflight.sh"; then
  echo "pr-review: all dependencies satisfied."
  echo "Skills available: /pr-review:start-review, /pr-review:process-comments, /pr-review:auto-fix-loop"
  exit 0
fi

code=$?
echo "pr-review: not ready. Fix the item above and run /pr-review:doctor again." >&2
exit "$code"
```

`commands/install.md`:

```markdown
---
description: Check that this plugin's dependencies are installed, enabled and authenticated
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/install.sh:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/install.sh` and report its output to the user verbatim.

The script writes nothing. It verifies that the two upstream plugins this one
builds on are installed **and** enabled, that python3, curl and a GitHub token
are available, and that the working directory is a GitHub repository clone. On
failure it prints the exact command that fixes the first problem it found.

$ARGUMENTS
```

`commands/doctor.md`: same frontmatter `allowed-tools`, `description: Re-run the dependency diagnostic for this plugin`, and a body that runs the same script and explains the exit codes (10 dependency, 11 tool, 12 auth, 13 repository).

`README.md`: purpose, the three skills with one line each, the `github-curl` tool, installation via the marketplace, the dependency requirement stated up front, and the body-file rule.

`CLAUDE.md`: repository conventions for anyone working on the plugin itself — stdlib only, bodies by file, subcommand names are a public interface, tests are offline, commit style is imperative prose with no trailers.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `0 failed`, and the new checks from this task all report `ok`. Do not assert a cumulative total: it changes as later tasks add checks.

- [ ] **Step 5: Commit**

```bash
git add install.sh commands README.md CLAUDE.md tests/run-tests.sh
git commit -m "Make the dependency check something a person can run on demand

Installation here is a diagnosis, not a change: the script touches nothing
outside this directory, and a test asserts that by comparing the file listing
before and after it runs."
```

---

### Task 16: Full-suite verification and phase gate

**Files:**
- Modify: none
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: everything.
- Produces: a green suite and a written statement of what is deliberately untested.

- [ ] **Step 1: Run the whole suite from a clean checkout**

```bash
cd "$(mktemp -d)" && git clone ~/dev/claude-review check && cd check && bash tests/run-tests.sh
```

Expected: `0 failed` and an exit code of 0. Record the passing count here as the suite baseline; this is the first point at which a total is meaningful.

- [ ] **Step 2: Verify no network call is possible offline**

```bash
grep -rn 'urlopen\|api.github.com' skills/github-curl/ghlib/ | grep -v 'http.py'
```

Expected: no output — every outbound call goes through `http.py`, which the fixture mode intercepts.

- [ ] **Step 3: Verify the phase boundary was respected**

```bash
git -C ~/dev/claude-review log --oneline | head -20
git -C ~/dev/claude-review remote -v
ls ~/dev/www/geonative-api/.claude/skills/ | grep -c 'pr-review-toolkit:'
```

Expected: commits present, **no remote configured**, and the consumer repository still holding its 3 skill directories untouched.

- [ ] **Step 4: Record what is untested**

Append to `docs/design.md` a short "Known gaps at end of phase 1" section listing: no live API call has been made; `pr-diff`'s diff media type is only exercised through a fixture; the orphan-branch creation path in `assets.py` is exercised only via the 404 branch; the three skill documents are checked structurally, not behaviourally.

- [ ] **Step 5: Commit**

```bash
git add docs/design.md
git commit -m "Record what phase 1 did not prove

The suite is offline by construction, so nothing here demonstrates that a real
call to GitHub succeeds. Naming that plainly is what makes the first live run
in phase 2 a test rather than a formality."
```

---

## Phase gate

Phase 1 ends here. **Do not** push to GitHub, add the plugin to the `lounisbou` marketplace, install it, or remove any skill directory from any repository under `~/dev/www/`. Those are phases 2 and 3, and they start only after the user has reviewed a green suite.
