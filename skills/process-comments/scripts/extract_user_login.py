"""Extract the PR author login from pr.json.

Runs BEFORE the "is PR_NUM empty" check in the skill document: when the
current branch has no open PR, pr-get's raw response is an empty list, and
an unguarded pr_data[0] would raise IndexError here -- before the skill ever
gets a chance to tell the user there is no PR and stop. Print an empty
string in that case instead, exactly like an absent login would print.
"""

import json
import os

TMP = os.environ.get("PR_REVIEW_TMP", "/tmp/claude")

try:
    pr_data = json.load(open(os.path.join(TMP, "pr.json")))
except (OSError, ValueError):
    pr_data = []

if isinstance(pr_data, list):
    first = pr_data[0] if pr_data else {}
else:
    first = pr_data or {}

print((first.get("user") or {}).get("login", ""))
