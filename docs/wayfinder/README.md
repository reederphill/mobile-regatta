# Wayfinding (local markdown tracker)

No hosted issue tracker is configured, so maps and tickets live here as markdown.

- `map.md` — the map (label `wayfinder:map`).
- `tickets/NN-slug.md` — child tickets of the map. Frontmatter carries:
  - `id` — identity; refer to tickets by **title** in prose, linking the file.
  - `labels` — `wayfinder:research | prototype | grilling | task`.
  - `status` — `open` or `closed`.
  - `assignee` — the claim. Empty = unclaimed. Set it **before** starting work.
  - `blocked_by` — ids of tickets that must be closed first (this tracker has no native blocking).
- On resolution: append a `## Resolution` section, set `status: closed`, and add a line to the map's
  **Decisions so far**. Assets (prototypes, research notes) are linked, not pasted.

**Frontier** = tickets that are `status: open`, have an empty `assignee`, and whose every
`blocked_by` id is closed. List it with:

```bash
python3 docs/wayfinder/frontier.py
```
