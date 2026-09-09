"""Extract the PR author login from pr.json."""

import json

pr_data = json.load(open("/tmp/claude/pr.json"))
print(pr_data[0].get("user", {}).get("login", ""))
