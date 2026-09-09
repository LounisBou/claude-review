---
name: auto-fix-loop
description: This skill should be used when the user asks to "review and fix PR", "review-pr-loop", "auto-fix PR issues", "review and correct everything", "fix all PR review issues", "keep reviewing until clean", "auto-review loop", "review-fix cycle", "review and fix everything automatically", or wants an autonomous review-fix-review cycle that automatically corrects all actionable bugs and suggestions, commits each fix, re-runs review, and loops until clean without asking for confirmation.
---

# Autonomous PR Review-Fix Loop

**Preflight:** run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh"` as the first
action. A non-zero exit stops the skill: print its output verbatim and do nothing else.

Run `/pr-review-toolkit:review-pr` in a loop. Fix issues. Re-run the review.
Keep looping. **ONLY TWO EXIT CONDITIONS EXIST:**

1. **The review found ZERO issues** (no Critical, no Important, no Suggestions — completely clean)
2. **5 passes reached** (safety limit)

**NOTHING ELSE stops the loop.** Not "all remaining are SKIP". Not "only suggestions left".
Not "fixes were applied". After EVERY pass where fixes were applied, you MUST re-run the
review to check if the fixes introduced new issues. After EVERY pass where issues were
found but skipped, increment the pass counter and re-run. The loop runs until one of
the two exit conditions is met.

## Loop Algorithm (MANDATORY — follow exactly)

```
pass_count = 0
seen_issues = set()
fix_log = []

LOOP:
  pass_count += 1

  # EXIT CHECK 1: safety limit
  if pass_count > 5:
      display exit summary
      STOP

  # Run review
  results = invoke /pr-review-toolkit:review-pr all

  # EXIT CHECK 2: completely clean
  if results has ZERO findings (no Critical, no Important, no Suggestions):
      display "CLEAN — no issues found"
      STOP

  # There ARE findings — process them
  for each finding:
      if finding is in seen_issues:
          mark as SKIP (already attempted)
          continue
      if finding is ACTIONABLE (Critical or Important with clear fix):
          read file, apply fix, commit, add to seen_issues
      else:
          mark as SKIP (suggestion/ambiguous)

  # Run tests after fixes
  if tests fail:
      revert last commit, add to seen_issues

  # MANDATORY: go back to LOOP — do NOT stop here
  # Even if all findings were SKIP, the pass counter increments
  # and we re-run the review. The review might find NEW issues
  # that weren't visible before, or confirm the code is clean.
  goto LOOP
```

**CRITICAL RULE:** After applying fixes, you MUST re-run the review. You cannot
assume the fixes are correct. You cannot assume no new issues were introduced.
The ONLY way to confirm "clean" is to run the review and get zero findings.

## What to Auto-Fix (no user confirmation needed)

**Always fix — issues labeled Critical or Important by review agents:**
- Bugs: logic errors, null handling, race conditions, security issues
- CLAUDE.md violations: explicit rule breaches detected by code-reviewer
- Silent failures: empty catch blocks, swallowed errors, missing logging
- Comment inaccuracies: factually wrong comments, outdated documentation
- Type design issues: missing invariant checks, weak encapsulation with clear fix
- Test defects: missing critical assertions, incorrect test logic
- Code simplification: redundant code, unnecessary complexity with clear simplification

**SKIP but do NOT stop the loop:**
- Architecture/design choices requiring broader context
- Issues where the "fix" is ambiguous or has multiple valid approaches
- Suggestions that would change public API or behavior significantly
- Style preferences not backed by CLAUDE.md rules
- Issues already in `seen_issues` (fix was attempted and either failed or reappeared)

## Step-by-Step Protocol

### Step 1: Initialize

```
- Identify changed files via `git diff --name-only` (or full codebase if user requests)
- Set pass_count = 0
- Set MAX_PASSES = 5
- Initialize seen_issues = set()
- Initialize fix_log = []
- Display: "Starting review-fix loop (max 5 passes)"
```

### Step 2: Increment pass counter and check safety limit

```
pass_count += 1
if pass_count > MAX_PASSES:
    → go to Step 7 (Exit Summary)
Display: "PASS {pass_count} — Running review..."
```

### Step 3: Run review

Invoke the review using the Skill tool or by launching review agents directly:
- Launch code-reviewer and silent-failure-hunter in parallel (minimum)
- Optionally add comment-analyzer, pr-test-analyzer, code-simplifier

Wait for ALL agents to complete. Aggregate results.

### Step 4: Check for clean exit

Count ALL findings across all agents (Critical + Important + Suggestions).

**If total findings == 0:**
→ go to Step 7 (Exit Summary) with exit_reason = "clean"

**If total findings > 0:**
→ go to Step 5 (Apply Fixes)

### Step 5: Apply fixes

For each finding, in order of severity (Critical first):

1. Build dedup key: `(file_path, issue_summary)`
2. If key in `seen_issues` → SKIP, continue to next
3. If finding is ACTIONABLE (Critical/Important with clear fix):
   - Read the affected file
   - Apply the fix using Edit tool
   - Verify no syntax errors
   - Stage and commit: `git add <file> && git commit -m "<message>"`
   - Add to `seen_issues`
   - Append to `fix_log`
4. If finding is NOT actionable (Suggestion/ambiguous):
   - Add to `seen_issues` (so we don't re-evaluate it next pass)
   - Note it for the exit summary

**Do NOT ask for confirmation.** Fix and commit autonomously.
**Do NOT exit after fixing.** Proceed to Step 6.

### Step 6: Run tests and loop back

Run tests: `python -m pytest tests/ -x -q`

If tests fail:
- Revert: `git revert HEAD --no-edit`
- Add the reverted issue to `seen_issues`
- Do NOT exit — continue

**MANDATORY: Go back to Step 2.** Do not stop. Do not display a summary.
Do not ask the user anything. Go directly to Step 2.

### Step 7: Exit Summary (ONLY reached from Step 2 or Step 4)

Display:

```markdown
## Review-Fix Loop Complete

**Passes:** {pass_count}
**Total fixes committed:** {fix_count}
**Exit reason:** {clean | max_passes}

### Fixes Applied
- {commit_hash}: {fix description}
- ...

### Skipped Issues (if any)
- {issue description} — Reason: {suggestion/ambiguous/already_attempted}
```

## Commit Convention

Follow the project's commit convention from CLAUDE.md (e.g., `vX.Y.Z: Description`).
If no convention, default to `fix: {description}`.
Never include `Co-Authored-By`, Claude, Anthropic, or AI references.

## Integration with Review Agents

| Agent | What it finds | Auto-fixable? |
|-------|--------------|---------------|
| code-reviewer | Bugs, CLAUDE.md violations, quality issues | Yes (Critical/Important) |
| silent-failure-hunter | Empty catches, swallowed errors, bad fallbacks | Yes |
| comment-analyzer | Inaccurate/outdated comments | Yes |
| pr-test-analyzer | Missing test coverage, weak assertions | Partially (clear gaps only) |
| type-design-analyzer | Weak invariants, poor encapsulation | Partially (clear fix only) |
| code-simplifier | Redundant code, unnecessary complexity | Yes |
