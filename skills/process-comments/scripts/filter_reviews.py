import json, sys

user = sys.argv[1] if len(sys.argv) > 1 else ""
reviews = json.load(open("/tmp/claude/reviews.json"))
open_reviews = [
    r
    for r in reviews
    if r.get("body", "").strip() and r.get("user", {}).get("login", "") != user
]
json.dump(open_reviews, open("/tmp/claude/open-reviews.json", "w"), indent=2)
print(f"Open review body comments: {len(open_reviews)}")
