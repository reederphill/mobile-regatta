<!-- machine-generated: for agents, not human readers -->
# Orchestration

Rules for the implementation orchestrator working the build map (#37). State lives in `docs/agents/orchestration-log.md` and issue labels, not in the orchestrator's context.

## Session scope

- One ticket per orchestrator session. Start by reading the orchestration log and `gh issue view <n>`; end by updating the log. Don't carry earlier tickets' history.
- Read the map (#37) with `--jq` filters for the decisions a ticket cites, not the full body and comments.

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
