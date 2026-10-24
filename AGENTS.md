# Regatta

Native iOS sailing race game. The simulation lives in `Packages/RegattaCore` (pure Swift, tested with `swift test`); the app is `Regatta/` (SwiftUI + SpriteKit). See `README.md` for building.

## Agent skills

### Issue tracker

Issues, including the wayfinder design map, live in GitHub Issues on `reederphill/mobile-regatta` (use the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Workflow

One agent per ticket: change, `scripts/test.sh <Package>`, push, merge on green CI (about 15 min). Slow and behaviour-pinned checks run nightly and never block. See `docs/agents/workflow.md`.

### Domain docs

Single-context: `CONTEXT.md` glossary and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
