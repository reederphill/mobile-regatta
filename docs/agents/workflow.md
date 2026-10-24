# Workflow

The game is a prototype: speed of iteration beats coverage. One agent per ticket, no separate tester, fixer, reviewer or acceptance roles.

## A ticket

1. Read the issue (`gh issue view <n> --comments`) and only the code and ADRs it touches.
2. Write the change. Add or update unit tests in the package you touched when the logic is worth pinning. Don't write tests that pin tunable behaviour (bot choices, seeds, exact timings, pixels).
3. `scripts/test.sh <Package>` for what you touched. If you touched the app, it compiles in CI; build it locally only if you're unsure.
4. Anything drawn or felt: attach a local screenshot (below) for the owner. That is the visual check.
5. Commit, push, open the PR. CI (about 15 min) green → squash-merge. Red → fix and push again.
6. A change that moves the simulation takes the next free `simulationRevision`. The nightly golden confirms it, and its log gives the new `Goldens.json` row.

## What runs where

- **CI (`ci.yml`, blocks merge):** `scripts/test.sh` (every package, the bot suites skipped) and the app with its test targets compiled.
- **Nightly (`nightly.yml`, never blocks):** the golden and digests on the pinned Linux image, the server image under load, Postgres, every package with the bot suites (`scripts/test.sh --bots`), the app's unit tests on the simulator, and the online end to end (`scripts/e2e.sh`). If it's red, open a ticket and fix it when convenient.
- **Nightly / weekly:** `botsuite.yml` (bot quality gates), `ios27.yml` (iOS 27 SDK).
- **By hand:** `regatta-botsuite` (and `--diagnose`), `scripts/bot-matrix.sh` and `scripts/record-fixtures.sh` are tools you use while tuning, not gates.

## Local screenshot

Build (`xcodebuild build -scheme Regatta -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/preview-dd`), `xcrun simctl install`, then `xcrun simctl launch --terminate-running-process <udid> com.phillreeder.regatta -demo -seed <n> -startSeconds 10 -timescale 4`, or `-uitesting -fixture <name>` with `SIMCTL_CHILD_REGATTA_FIXTURE_DIR` pointing at `RegattaUITests/Fixtures`. Then `xcrun simctl io <udid> screenshot <file>`.

## Rules

- Never poll with `sleep` loops. Run long commands in the foreground with a timeout, or in the background and wait for the notification.
- Don't read `docs/history/`; it's the old process, kept for reference only.
