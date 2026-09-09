"""Extract unique file paths from open review threads."""

import json

threads = json.load(open("/tmp/claude/open-threads.json"))
paths = sorted(set(t.get("path", "") for t in threads if t.get("path")))
for p in paths:
    print(p)
