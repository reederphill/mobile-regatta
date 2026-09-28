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

Ask the human only for: a blocker you'd leave unfixed, a scope change, or a `needs:human` item. A reference-image change isn't one: since #215 it routes through CI, not a human re-record. The failing compare uploads `render-actuals`; adopt it with `scripts/adopt-references.sh <PR>`, look at it, commit, push (validation.md, Render references).

## Implementer brief

The orchestrator writes a brief of about 2K tokens; the implementer doesn't re-derive it. Include:
- The ticket's Build and Acceptance lists (quoted).
- The files and types to touch, and the merged tickets it builds on (one line each).
- The map decisions and ADR paragraphs that apply, quoted. Not "read ADR 0002"; quote the lines.
- What the change may move (digests, bot behaviour, render references), for the tester. Validation itself is the tester's call; `docs/agents/validation.md` by reference.

Implementer reading rules: `grep -n` / `sed -n <range>p` or the codebase-memory graph, not `cat` of whole files. Never read transcripts or tool-output files from other agents.

## The ticket loop (owner, 2026-09-27)

A ticket's local-slot work is a loop of separate agents, each fresh:

1. **Implementer: implementation coding only.** It writes the code and the acceptance tests, compiles what it touched with its tests (`scripts/heavy.sh swift build --build-tests …`), and runs only its own new or changed tests (`scripts/heavy.sh swift test --filter …`, failing first where it can). No `check.sh`, no suites, no bot matrix. It commits locally (no push) and writes an implementation note: what changed, acceptance → test, what it expects to move.
2. **Tester: decides and runs the minimal validation.** It writes a test plan first: what could break, the checks that cover it, what it deliberately doesn't run and why. Then it runs the plan (`check.sh` at least once on the final code, the recorded gate the acceptance check reads; digest comparisons for sim changes; the bot matrix only when bot behaviour or rule-call rates should move). Every failure is rerun once and checked against the base: only a failure the change causes is a regression. It never edits code, and it reports verdict, findings and repro commands.
3. **Fixer: fresh per round.** It gets the tester's regressions and repros, fixes, compiles, confirms each repro, and commits locally. The tester then re-tests only what the fix could affect.
4. The loop runs until the tester passes, up to 3 rounds; after that it goes to the orchestrator with the history.
5. **Publisher:** squashes WIP commits, pushes once, and opens the PR (acceptance → test map, the tester's validation, sim revision, deviations). Review, CI and the acceptance check then run as before. Their findings re-enter the loop as a fixer round, then tester, then a push onto the PR.

## Agent lifetime

- No agent waits on CI. The orchestrator waits with one background `gh run watch <id> --exit-status` (or the PR monitor), not a polling loop.
- Every round is a fresh agent. Don't `SendMessage` more rounds into an earlier one.
- Context budget (owner, 2026-09-27): no agent runs past ~400K tokens of context (about 150 tool calls). Near it, the agent commits its work in progress locally (no push onto an open PR), writes a handoff note (done, next, gotchas, exact next command) and returns; a fresh agent continues from the note in the same worktree.

## Roles

Model and inputs per `docs/agents/validation.md` (Model routing). Reviewers and acceptance checks get the brief, the diff, and the PR number; nothing else.
