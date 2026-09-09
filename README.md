# claude-review

An interactive pull-request review workflow, packaged as a plugin: walk through
review feedback one item at a time, process a PR's comments with a human deciding
each one, run an autonomous review-fix loop, and talk to the GitHub API from a single
Python tool with no dependencies.

The plugin is named `pr-review`, so its skills are `/pr-review:start-review`,
`/pr-review:process-comments` and `/pr-review:auto-fix-loop`.

## Requires two upstream plugins

This is a thin layer, not a fork. It builds on two plugins from the official
marketplace and refuses to run without them:

- `pr-review-toolkit@claude-plugins-official` — the review agents and `/review-pr`
- `code-review@claude-plugins-official` — confidence-scored review

**Installed is not the same as enabled.** A plugin can sit on disk and be inert, so
the preflight reads the `enabledPlugins` map rather than looking for files. If either
dependency is missing or disabled, every skill stops before doing anything and prints
the command that fixes it.

## Install

Add the marketplace, install the plugin, then check it:

```
/plugin marketplace add LounisBou/claude-review
/plugin install pr-review@claude-review
/pr-review:install
```

`/pr-review:install` writes nothing. It is a diagnostic: it verifies the two upstream
plugins, python3 3.9+, curl, a GitHub token and a GitHub `origin` remote. Run
`/pr-review:doctor` any time to repeat it.

## The skills

**`/pr-review:start-review`** — an interactive walkthrough of review findings. It
builds a numbered list, then presents one item at a time and waits. The default
deliverable is a draft comment for the PR author, not a code change; applying a fix
happens only on the explicit `fix` command. Nothing is ever posted without approval.

**`/pr-review:process-comments`** — works through a PR's existing comments with the
user deciding each one. It announces the workload first and only builds full project
context when there is enough to justify it. A reviewer asking for a change is not on
its own a reason to make it.

**`/pr-review:auto-fix-loop`** — the autonomous counterpart: review, fix, re-review,
until clean or until a pass limit. Use it when you want the cycle run for you rather
than presented to you.

## The GitHub tool

`skills/github-curl/gh.py` covers pull requests, review threads, comments, reviews,
labels, reviewers, issues, search and image attachments — 38 subcommands, Python
standard library only, no `gh` CLI. See `skills/github-curl/SKILL.md` for the full
surface.

Two rules shape it:

**Every text body travels by file.** There is no `--body "text"` form anywhere.
Multi-line markdown containing backticks, quotes and `$VAR` sequences does not survive
shell quoting, and the failure is silent — the request succeeds with mangled text. So
bodies are written to a file and passed with `--body-file`, and the bytes arrive
unchanged, CRLF included.

**Failures are exit codes, not tracebacks.** `1` usage, `2` auth, `3` API error, `4`
not found, `5` rate limited. A Python traceback is a bug.

Images are attached by committing them to a dedicated `pr-assets` branch through the
Contents API with the scoped token, named after the SHA-256 of their bytes so the
same screenshot uploads once. GitHub's own web upload endpoint would produce a
`user-attachments` URL, but it authenticates with browser session cookies rather than
a token — whole-account credentials on disk — so that route is deliberately not used.
The rendered result in a pull request is identical.

## Tests

```
bash tests/run-tests.sh
```

No network, no installed plugin, no GitHub account. Responses are served from fixture
files and every request the tool would have sent is recorded and asserted against.

## Licence

MIT.
