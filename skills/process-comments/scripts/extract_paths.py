"""Extract unique file paths from open review threads."""

import json
import os

TMP = os.environ.get("PR_REVIEW_TMP", "/tmp/claude")

try:
    threads = json.load(open(os.path.join(TMP, "open-threads.json")))
except (OSError, ValueError):
    threads = []

paths = sorted(set(t.get("path", "") for t in threads if t.get("path")))
for p in paths:
    print(p)
