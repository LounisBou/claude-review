# claude-review

An interactive pull-request review workflow, packaged as a plugin: walk through
review feedback one item at a time, process a PR's comments with a human deciding
each one, and run an autonomous review-fix loop.

The plugin is named `pr-review`, so its skills are `/pr-review:start-review`,
`/pr-review:process-comments` and `/pr-review:auto-fix-loop`.

## Requires two plugins

This is a thin layer, not a fork. It builds on two plugins and refuses to run
without them:

- `pr-review-toolkit@claude-plugins-official` — the review agents and `/review-pr`
- `github@lounisbou` — the GitHub API tool, see below

**Installed is not the same as enabled.** A plugin can sit on disk and be inert, so
the preflight reads the `enabledPlugins` map rather than looking for files. If any
dependency is missing or disabled, every skill stops before doing anything and prints
the command that fixes it.

The GitHub plugin is accepted under either of the two keys it can be installed
from — `github@lounisbou` from the aggregate marketplace, `github@claude-github`
from its own. Either one satisfies the dependency; only neither is a failure.

## Install

Add the marketplace, install the plugin, then check it:

```
/plugin marketplace add LounisBou/claude-review
/plugin install pr-review@claude-review
/pr-review:install
```

`/pr-review:install` writes nothing. It is a diagnostic: it verifies the two plugin
dependencies — `pr-review-toolkit@claude-plugins-official` and `github@lounisbou` —
plus python3 3.9+, curl, a GitHub token and a GitHub `origin` remote. Run
`/pr-review:doctor` any time to repeat it.

## The skills

**`/pr-review:start-review`** — an interactive walkthrough of review findings. It
builds a numbered list, then presents one item at a time and waits. The comments kept
along the way go into a single review left pending on the PR, which the author cannot
see until the user reads it, edits it and submits it on GitHub. Applying a fix
happens only on the explicit `fix` command, and publishing a comment on the spot only
on `post now`.

**`/pr-review:process-comments`** — works through a PR's existing comments with the
user deciding each one. It announces the workload first and only builds full project
context when there is enough to justify it. A reviewer asking for a change is not on
its own a reason to make it.

**`/pr-review:auto-fix-loop`** — the autonomous counterpart: review, fix, re-review,
until clean or until a pass limit. Use it when you want the cycle run for you rather
than presented to you.

## The GitHub tool

The skills talk to GitHub through `gh.py` — pull requests, review threads, comments,
reviews, labels, reviewers, issues, search and image attachments, Python standard
library only, no `gh` CLI. That tool is no longer carried here. It ships in its own
plugin, `github@lounisbou`, declared under `dependencies` in
`.claude-plugin/plugin.json` and installed along with this plugin rather than
separately.

The skills never hard-code where it lives. `${CLAUDE_PLUGIN_ROOT}` names this
plugin's own directory and cannot reach a sibling, and the plugin cache is not a
path to assemble by hand — installed versions are sometimes git SHAs rather than
versions. `scripts/resolve_github.py` reads the platform's own install record and
prints the sibling's root; every skill resolves through it and stops on an
`error:`/`fix:` pair when the dependency is absent.

Its documentation — the full subcommand and formatter surface, the body-file rule,
the exit codes — lives at
[github.com/LounisBou/claude-github](https://github.com/LounisBou/claude-github).

## Tests

```
bash tests/run-tests.sh
```

No network and no GitHub account. The tool's own behaviour is tested in the
`claude-github` repository, where it lives; what runs here is the manifests, the
preflight, the resolver, the skill documents, and a contract test that reads the
real installed parser and fails if a skill names a subcommand or formatter that
does not exist. Point `CLAUDE_GITHUB_ROOT` at a `claude-github` checkout to run
that contract test without the plugin installed:

```
CLAUDE_GITHUB_ROOT=~/dev/claude-github bash tests/run-tests.sh
```

## Licence

MIT.
