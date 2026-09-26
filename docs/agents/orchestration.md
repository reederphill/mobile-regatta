<!-- machine-generated: for agents, not human readers -->
# Orchestration

Rules for the implementation orchestrator working the build map (#37). State lives in `docs/agents/orchestration-log.md` and issue labels, not in the orchestrator's context.

## Session scope

- Start each ticket from the orchestration log and `gh issue view <n>`; end it by updating the log. Don't carry earlier tickets' history (in a loop, compact between tickets).
- Read the map (#37) with `--jq` filters for the decisions a ticket cites, not the full body and comments.

## Throughput

The Mac has 8 GB of RAM: one heavy build or test run at a time. Parallel local work queues on the build lock, swaps, fills the disk, and makes the wall-clock tests fail.
- One orchestrator per machine. Don't start a second orchestrator session while one is running.
- One local slot: at most one implementer building or running `check.sh` at a time. Everything else waits in CI or review, which cost the machine nothing.
- Pipeline: when a ticket's PR is pushed, claim the next ticket and start its implementer. The pushed PR's CI, review and acceptance check run alongside. At most two tickets in flight: one in the local slot, one in CI/review.
- A fix round for the older PR takes the local slot next, ahead of a new ticket.
- Push once per round. Every push restarts the whole CI run.

## Merging

Squash-merge without asking when all of these hold for the head SHA:
- CI green on every job the change reaches.
- The acceptance check passes every item.
- The review has no blockers (nits may stay unfixed; list them in the log).

Ask the human only for: a blocker you'd leave unfixed, a scope change, a `needs:human` item, or a reference-image change you can't take from CI.

## Implementer brief

The orchestrator writes a brief of about 2K tokens; the implementer doesn't re-derive it. Include:
- The ticket's Build and Acceptance lists (quoted).
- The files and types to touch, and the merged tickets it builds on (one line each).
- The map decisions and ADR paragraphs that apply, quoted. Not "read ADR 0002"; quote the lines.
- `docs/agents/validation.md` by reference.

Implementer reading rules: `grep -n` / `sed -n <range>p` or the codebase-memory graph, not `cat` of whole files. Never read transcripts or tool-output files from other agents.

## Agent lifetime

- The implementer stops after it pushes the PR with the acceptance → test map in the body. It doesn't wait on CI.
- The orchestrator waits on CI with one background `gh run watch <id> --exit-status` (or the PR monitor), not a polling loop.
- Review fixes: a fresh implementer with the PR number, the findings, and the brief. Don't `SendMessage` more rounds into the original implementer.
- Any agent past ~150K context: stop it and hand off with a short state summary.

## Roles

Model and inputs per `docs/agents/validation.md` (Model routing). Reviewers and acceptance checks get the brief, the diff, and the PR number; nothing else.
