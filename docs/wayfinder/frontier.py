#!/usr/bin/env python3
"""Print the wayfinder frontier: open, unclaimed tickets whose blockers are all closed."""
import pathlib, re

tickets = {}
for path in sorted(pathlib.Path(__file__).parent.joinpath("tickets").glob("*.md")):
    front = path.read_text().split("---")[1]
    field = lambda k: (re.search(rf"^{k}:[ \t]*(.*)$", front, re.M).group(1).strip())
    blocked = [int(x) for x in re.findall(r"\d+", field("blocked_by"))]
    tickets[int(field("id"))] = dict(title=field("title"), status=field("status"),
                                     assignee=field("assignee"), blocked=blocked,
                                     label=field("labels"), path=path.name)

for tid, t in tickets.items():
    if t["status"] != "open":
        continue
    waiting = [b for b in t["blocked"] if tickets[b]["status"] != "closed"]
    state = "claimed by " + t["assignee"] if t["assignee"] else ("blocked by " + ", ".join(tickets[b]["title"] for b in waiting) if waiting else "FRONTIER")
    print(f"{t['title']:<62} {t['label']:<22} {state}")
