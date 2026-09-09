"""Count open PR comments and print the protocol tier.

Reads the filtered files produced by Step 0 Phase 3 and reports how much work
actually remains, so the agent can announce the workload before building any
context. Threads where the user replied last are auto-passed and do NOT count
toward the tier.

Usage: python3 count_open.py <USER_LOGIN>
"""

import json
import os
import sys

USER = sys.argv[1] if len(sys.argv) > 1 else ""


def load(path):
    """Load a JSON list, tolerating a missing or malformed file."""
    if not os.path.exists(path):
        return []
    try:
        with open(path) as handle:
            return json.load(handle) or []
    except (ValueError, OSError):
        return []


threads = load("/tmp/claude/open-threads.json")
issue_comments = load("/tmp/claude/open-issue-comments.json")
reviews = load("/tmp/claude/open-reviews.json")

# A thread whose last reply is the user's is awaiting the reviewer: auto-passed.
auto_passed = []
pending_threads = []
for thread in threads:
    nodes = thread.get("comments", {}).get("nodes", [])
    last_author = nodes[-1].get("author", {}).get("login", "") if nodes else ""
    if last_author == USER:
        auto_passed.append(thread)
    else:
        pending_threads.append(thread)

pending = len(pending_threads) + len(issue_comments) + len(reviews)

if pending == 0:
    tier = "EXIT"
elif pending <= 2:
    tier = "FAST"
else:
    tier = "FULL"

print(f"PENDING={pending}")
print(f"TIER={tier}")
print(f"  review threads:       {len(pending_threads)}")
print(f"  issue comments:       {len(issue_comments)}")
print(f"  review body comments: {len(reviews)}")
print(f"  auto-passed threads:  {len(auto_passed)} (you replied last)")
