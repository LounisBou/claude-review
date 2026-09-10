# claude-review — design

Repository: `github.com/LounisBou/claude-review`
Plugin name: `pr-review` (this is the user-facing command/skill prefix)
Status: design approved 2026-09-08; phase 1 implemented 2026-09-09 (see docs/plan-phase-1.md and the gaps recorded at the end of this file). Phases 2 and 3 not started.

## 1. Purpose

Package the PR-review workflow that currently lives, duplicated and drifted, in
16 repositories under `~/dev/www/` into a single installable Claude Code plugin.

Today the same four skills are copy-pasted into 46 skill directories across those
repos, in as many as **five different generations** for a single skill. A fix made
in one repo never reaches the other fifteen. The plugin makes one copy
authoritative and installable.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Thin layer over the official plugins, not a fork | `pr-review-toolkit` (6 review agents + `/review-pr`) and `code-review` (confidence-scored review) stay upstream; we inherit their improvements. We ship only what is ours. |
| 2 | Hard dependency preflight that fails loudly | A thin layer is worthless if it degrades silently when a dependency is missing or disabled. |
| 3 | Repo `claude-review`, plugin `pr-review` | Matches the existing `claude-orchestrator` repo → `orchestrator` plugin precedent. `pr-review` is descriptive and cannot collide with the upstream `pr-review-toolkit`. |
| 4 | Prose follows the user's language; anything published stays English | The "everything on GitHub is English, never ask" rule is universally correct and saves a turn every time. Only the conversation language is personal, so it is not hard-coded. |
| 5 | Single Python tool (`gh.py`), bash only for preflight/install | The new capabilities are mostly writes with rich JSON payloads. Building those in bash industrialises a bug class the current skill already documents as a known error (`Expected VAR_SIGN`). |
| 6 | All text bodies pass via `--body-file`, never as CLI arguments | Multi-line markdown containing backticks and quotes is the exact input that breaks shell quoting. |
| 7 | Image upload via the Contents API, not GitHub's web upload endpoint | The web flow (`/upload/policies/assets`) requires full browser session cookies on disk, a scraped CSRF token, and frontend-version headers. It grants whole-account access, expires, and breaks on frontend changes. The Contents API uses the existing scoped `GH_TOKEN`, is stable and testable. |

### Rejected alternatives

- **Vendoring the upstream agents** — self-contained, but we would own six agent
  prompts and merge upstream changes by hand, forever.
- **Keeping bash with per-domain `lib/*.sh`** — shorter files, but the escaping
  fragility is spread across six files rather than removed.
- **GitHub web upload flow** — produces native `user-attachments` URLs, but
  requires storing session cookies. Rejected on security grounds; the rendered
  result in a PR is identical.

## 3. Repository layout

```
claude-review/
├── .claude-plugin/
│   ├── plugin.json               name "pr-review", version 0.1.0, MIT
│   └── marketplace.json          marketplace "claude-review"
├── commands/
│   ├── install.md                /pr-review:install → runs install.sh
│   └── doctor.md                 /pr-review:doctor  → same diagnostic on demand
├── skills/
│   ├── start-review/SKILL.md
│   ├── process-comments/
│   │   ├── SKILL.md
│   │   └── scripts/              filter_reviews.py, extract_user_login.py, extract_paths.py
│   ├── auto-fix-loop/SKILL.md
│   └── github-curl/
│       ├── SKILL.md
│       ├── gh.py                 CLI entry point and dispatch
│       └── ghlib/                see §5
├── scripts/preflight.sh          shared; run by install.sh and by every skill
├── install.sh                    verifies only; writes nothing
├── tests/run-tests.sh
├── docs/design.md                this file
├── README.md
├── CLAUDE.md
├── LICENSE                       MIT
└── .gitignore
```

There is deliberately **no `uninstall.sh`**. The other two plugins have one because
they write into `settings.json` and therefore have something to undo. This plugin
writes nothing outside its own directory; removing the plugin is the uninstall.

`docs/` is matched by a rule in the global `~/.gitignore`. As in
`claude-orchestrator`, the repository `.gitignore` carries a `!docs/` negation,
which takes precedence over a global exclude, so design docs are committed
normally with no `-f` flag.

## 4. Dependency preflight

`scripts/preflight.sh` runs the checks below in order and stops at the first
failure, printing the exact command to run. Every skill invokes it as its first
instruction; `install.sh` and `/pr-review:doctor` run the same script.

| Check | Method | Remedy printed on failure |
|---|---|---|
| `pr-review-toolkit` installed **and enabled** | `enabledPlugins["pr-review-toolkit@claude-plugins-official"] === true` in `~/.claude/settings.json` | `/plugin install pr-review-toolkit@claude-plugins-official`, then enable it |
| `code-review` installed **and enabled** | `enabledPlugins["code-review@claude-plugins-official"] === true` | `/plugin install code-review@claude-plugins-official`, then enable it |
| `python3` >= 3.9 | `python3 -V` | install python3 |
| `curl` present | `command -v curl` | install curl |
| GitHub token available | `gh auth token` exits 0 and is non-empty | `gh auth login` |
| Git repo with a GitHub `origin` remote | `git remote get-url origin` matches github.com | run from a GitHub repository |

**Enabled, not merely installed.** The authoritative source is
`~/.claude/settings.json → enabledPlugins`, keyed `<plugin>@<marketplace>`, not the
presence of files under `~/.claude/plugins/cache/`, which retains orphaned versions.
On the development machine at design time, `code-review@claude-plugins-official`
is installed but set to `false` — a file-presence check would have reported success
and then failed at use.

Preflight exit codes: `0` ok, `10` missing/disabled plugin dependency, `11` missing
system tool, `12` auth failure, `13` not a GitHub repository.

## 5. `gh.py` architecture

Python 3 standard library only (`urllib`); no packages to install. Organised as
short modules rather than one large file:

```
ghlib/errors.py     typed failures, each carrying its process exit code
ghlib/bodies.py     reads a --body-file verbatim, refusing missing or empty files
ghlib/http.py       REST + GraphQL transport, auth, automatic pagination,
                    retry on 403/429 with Retry-After, typed errors
ghlib/repo.py       owner/repo detection from the origin remote, ref handling,
                    --repo owner/name override
ghlib/pr.py         PR reads
ghlib/comments.py   review threads, comments, resolve/unresolve
ghlib/reviews.py    review submission with inline comments
ghlib/meta.py       labels, reviewers, assignees, ready-for-review, PR update
ghlib/issues.py     issues and search
ghlib/assets.py     image upload
ghlib/fmt.py        output formatters selected by --format
```

### Compatibility with the current scripts

The 16 existing subcommand names are kept verbatim, so the skills' vocabulary does
not change. What changes is that formatting becomes a flag instead of a second
script in a pipe:

```
# before
bash gh-api.sh pr-threads 1611 | python3 gh-parse.py thread-summary
# after
python3 gh.py pr-threads 1611 --format thread-summary
```

`--format raw` is the default on reads, preserving the current property that the
unprocessed JSON stays inspectable between fetch and interpretation.

### Subcommand surface

Carried over unchanged: `auth-check`, `pr-get`, `pr-list`, `pr-threads`,
`pr-comments`, `pr-issue-comments`, `pr-reviews`, `pr-status`, `pr-checks`,
`comment-resolved`, `comments-resolved-batch`, `thread-resolve`, `comment-resolve`,
`comment-unresolve`, `pr-create`, `pr-merge`.

New:

| Group | Subcommands |
|---|---|
| Review writes | `thread-reply`, `pr-comment`, `review-submit` (`--event COMMENT\|APPROVE\|REQUEST_CHANGES`, `--comments-file` for inline comments), `comment-edit`, `comment-delete` |
| PR content | `pr-diff`, `pr-files` (paths and patches, paginated), `pr-commits`, `file-at-ref` |
| PR metadata | `pr-update` (title/body/base/state), `pr-ready`, `label-add`, `label-remove`, `reviewer-add`, `reviewer-remove`, `assignee-add`, `assignee-remove` |
| Issues and search | `issue-view`, `issue-list`, `issue-search`, `pr-linked-issues` |
| Assets | `image-upload` |

**Body rule.** `thread-reply`, `pr-comment`, `review-submit`, `comment-edit` and
`pr-update` accept their text exclusively through `--body-file <path>`. There is no
`--body "text"` form; omitting it is what makes multi-line markdown reliable.

Exit codes: `0` success, `1` usage, `2` auth, `3` API error, `4` not found,
`5` rate limited after retries.

### Image upload

`image-upload <file> [--branch pr-assets]`:

1. Compute the file's SHA-256; the blob is stored as `<sha256>.<ext>`, which makes
   re-uploading the same image idempotent.
2. Create the branch `pr-assets` if absent, forked from the default branch's current
   tip. It is a dedicated branch, not an orphan one: it shares the default branch's
   history at creation time; nothing but asset writes lands on it afterward.
3. `PUT /repos/{owner}/{repo}/contents/<sha256>.<ext>` with the base64 content on
   that branch. If the path already exists, skip the write and reuse it.
4. Print both the raw URL and the ready-to-paste markdown:
   `![](https://raw.githubusercontent.com/{owner}/{repo}/pr-assets/<sha256>.<ext>)`

Requires push access to the repository. The command states this in its failure
message when the token lacks it.

## 6. Skills

### Reference sources

The four skills exist in several drifted generations. The authoritative copy is
**not the same repository for every skill**:

| Skill | Authoritative source | Size | Older generations to discard |
|---|---|---|---|
| `start-review` | `geonative-api` | 13 632 B | 2 (6 667 · 6 507) |
| `process-comments` | `geonative-front-office` | 48 792 B | 4 (45 023 · 16 595 · 14 643 · 11 482) |
| `auto-fix-loop` | `geonative-api` | 6 961 B | none (5 identical copies) |
| `github-curl` | `geonative-api` | 4 769 B | 2 (3 608 · 3 537) |

`geonative-front-office` wins for `process-comments` because it adds a tiering
system ("Triage — Announce the Workload FIRST") that makes the expensive steps
conditional (`Full tier only — 3+ comments`). Before extraction, diff the two
candidates in full to confirm the front-office copy is a superset.

### Portability changes applied during extraction

1. Hard-coded `.claude/skills/github-curl/` paths become
   `${CLAUDE_PLUGIN_ROOT}/skills/github-curl/gh.py`.
2. `bash gh-api.sh X | python3 gh-parse.py Y` becomes `python3 gh.py X --format Y`.
3. The hard-coded French language table becomes the generic rule: prose in the
   user's language, drafts shown in the user's language plus English, everything
   published to GitHub or written to a file in English.
4. References to `norms.md` and project-specific `CLAUDE.md` conventions become
   conditional ("if present"), so the skills work in a repo that has neither.
5. Each skill calls `scripts/preflight.sh` as its first instruction.
6. Skill directory names drop the `pr-review-toolkit:` prefix; the plugin supplies
   the namespace, yielding `/pr-review:start-review` and so on.

### Behaviour preserved

The iron rules are not relaxed by the new write capabilities. `start-review` still
produces a draft comment as its default deliverable and applies a change only on
the literal `fix` command. Nothing is posted to GitHub without explicit approval;
`gh.py` gaining `pr-comment` removes a technical limitation, not a guard rail.

## 7. Testing

`tests/run-tests.sh`, bash, matching the other two plugins. No network access.

- JSON fixtures drive parsing and every `--format` output.
- Payload construction is asserted for each write subcommand.
- A dedicated test feeds `--body-file` multi-line markdown containing backticks,
  double quotes, single quotes, `$VAR` sequences and CRLF, and asserts the body
  arrives byte-identical. This is the regression test for the bug class the design
  exists to remove.
- Pagination is exercised against a fixture with a `Link` header.
- Error mapping is asserted for 401, 403 rate-limited, 404 and 422.
- `preflight.sh` is run against synthetic `settings.json` files covering: both
  dependencies enabled, one disabled, one absent, and a malformed file.

## 8. Migration plan

Three phases, strictly ordered. Nothing on the machine changes before phase 2.

**Phase 1 — build.** Create the repository, extract and adapt the four skills,
write `gh.py` and the tests, get the suite green. The 16 consumer repos are
untouched and keep working off their local copies throughout.

**Phase 2 — publish and install.** Push to `github.com/LounisBou/claude-review`.
Add a third entry to the `lounisbou` marketplace, which lives in the
`claude-statusbar` repository, sourced from GitHub as the `orchestrator` entry
already is, and bump its `metadata.version` from 1.2.0 to 1.3.0. Install the
plugin, enable the two upstream dependencies, and validate against a real PR.

**Phase 3 — clean up.** Only once phase 2 is validated: remove the 46 duplicated
skill directories across the 16 repositories, and remove the references to them in
each repo's `CLAUDE.md` and `settings.json`.

Affected repositories: `geonative-api`, `geonative-api-bis`,
`geonative-api-documentation`, `geonative-back-office`, `geonative-eog`,
`geonative-eview`, `geonative-firebase-notifier`, `geonative-freddie`,
`geonative-front-office`, `geonative-geosecure-belt`, `geonative-infra`,
`geonative-speculoos`, `geonative-teltonika`, `geonative-ui`,
`geonative-vue3-leaflet`, `geonative-whereami`.

## 9. Out of scope

- Forking or modifying the upstream review agents.
- The GitHub web upload flow and any browser-cookie authentication.
- The `norms:*` and `implement:*` skills that also live in these repos; they are a
  separate concern and would widen this plugin past PR review.
- Migrating anything before the plugin is built, tested and validated.

## Live validation — 2026-09-10

The plugin was published and exercised against the real GitHub API for the first
time. What now has evidence behind it, beyond fixtures:

| Call | Result |
|---|---|
| `auth-check` | authenticated as the token's owner |
| `preflight.sh` on a real clone | exit 10 — correctly refused because `code-review` is installed but disabled, printing the exact remedy |
| `pr-list` | 7 open PRs on one repository, 13 on another |
| `pr-status --format pr-details` | number, title, state, draft, head, base, url |
| `pr-files` | changed paths returned through the paginated path |
| `pr-threads` (GraphQL) | round-trips; the whole GraphQL path was previously untested |
| `pr-issue-comments`, `open-threads`, `resolved-threads`, `thread-summary`, `issue-comments-summary` | all render |

The preflight result is the one worth noting: the guard refused to run on a real
machine for exactly the reason it was designed around — a dependency present on
disk and set to false — and said which command fixes it.

**Still unproven:** no PR with open review threads was found across the repositories
checked, so `thread-summary` and `open-threads` have only ever rendered an empty
set. The write paths — `pr-comment`, `thread-reply`, `review-submit`, `image-upload`,
`pr-create`, `pr-merge` — have never been fired at a live repository, deliberately:
they mutate someone's pull request.

## Known gaps at the end of phase 1

The suite is offline by construction, so nothing here demonstrates that a real call
to GitHub succeeds. Naming that plainly is what makes the first live run in phase 2
a test rather than a formality.

**Never exercised against the real API.** Every response in the suite comes from a
fixture file. No token has been used, no repository written to, no rate limit hit.
The first live run should cover at least: `auth-check`, `pr-get`, `pr-threads`,
`pr-comment` with a body containing backticks, and `image-upload` twice on the same
file to confirm the second is a no-op.

**`pr-diff`'s media type.** The transport now returns a plain-text body unparsed, but
only a mocked `urlopen` has ever produced one. GitHub's actual `application/vnd.github.v3.diff`
response has not been seen.

**Orphan-branch creation.** `image-upload` creates the `pr-assets` branch when it is
absent — a write to the user's repository — and no committed test exercises that
path; the fixtures always present an existing branch. Verified by reading only.

**Task 11 has no independent review.** Three reviewers stalled in succession, and its
findings in the ledger are the controller's own reading rather than a second opinion.
It is the only task in the phase closed this way.

**The three extracted skills are checked structurally, not behaviourally.** The suite
asserts their frontmatter, their preflight call, their namespace and their paths. It
does not run them. Whether the adapted `process-comments` still works end to end is a
phase 2 question.

**Deferred minors worth triaging before merge.** `label-remove` accepts several label
names, sends one DELETE and drops the rest silently — the parser advertises `nargs="+"`
while GitHub deletes one per call; either narrow the interface or loop. `pr_ready`'s
`node_id` guard has no regression test. `--repo ""` is treated as no override rather
than rejected. The retry loop retries every 403, not only rate-limited ones, so a
permission failure waits about three seconds before reporting.
