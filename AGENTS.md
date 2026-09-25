# Regatta

Native iOS sailing race game. The simulation lives in `Packages/RegattaCore` (pure Swift, tested with `swift test`); the app is `Regatta/` (SwiftUI + SpriteKit). See `README.md` for building.

## Agent skills

### Issue tracker

Issues, including the wayfinder design map, live in GitHub Issues on `reederphill/mobile-regatta` (use the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Validation

`scripts/check.sh` locally, CI before merge; the golden runs only in CI. See `docs/agents/validation.md`.

### Orchestration

One ticket per session, short briefs, fresh agents per round. See `docs/agents/orchestration.md`.

### Domain docs

Single-context: `CONTEXT.md` glossary and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
