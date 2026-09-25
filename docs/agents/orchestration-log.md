# Build orchestration log

Running log from the implementation orchestrator working the [build plan map (#37)](https://github.com/reederphill/mobile-regatta/issues/37).
Loop per ticket: implement → review → validate (max 3 rounds), then squash-merge and close.
Since 66e37cd (`docs/agents/validation.md`): the local gate is `scripts/check.sh`, CI on the PR is the last gate, checked only right before merge (agents do not wait on it), and `linux-test.sh` runs only for a new golden row or when CI can't run. Review and validation use Sonnet; the mechanical acceptance check uses Haiku. Each gets only the diff, the ticket and the acceptance list.

## Needs your answer (parked tickets)

Each parked ticket is labelled `needs:human`, unassigned, and has the question as an issue comment.

| Ticket | Question | Suggested answer | Parked |
|---|---|---|---|
| #66 RaceHost seat lifecycle | Code complete in [#193](https://github.com/reederphill/mobile-regatta/pull/193) (CI green, review and acceptance passed) but not merged: run `scripts/check.sh` locally with Swift, then merge and close? Labelled `needs:swift-validation`, not `needs:human`. | Merge if `check.sh` passes; the review nits can ride along | 2026-09-25 |

## Answered by the orchestrator (high confidence)

| Ticket | Question | Answer given |
|---|---|---|
| all | No docker/podman on this Mac: how to meet Linux-only acceptance (`scripts/linux-test.sh`)? | Superseded 2026-09-23 22:54 PT: GitHub Actions is disabled (billing) and podman is installed. Linux checks run locally via `scripts/linux-test.sh` with podman. |
| #56 | The golden digest sails all seats with BotBrain, so a bot retune moves it (ADR 0002 wants bots retunable without a version bump). | Accept for #56. #59's brain-free race-log replay golden replaces it; add a note by `simulationRevision`. |
| #107 | Should the iPad orientation lock be always on, or only during the race sequence? | Only during the race sequence. G5 says menus adapt to any window; iPhone stays portrait via Info.plist. |
| #107 | The iOS 27 CI job (preview `xcode-27` runner, ~21 min, private repo, 10× macOS billing) was running on every push. | Now runs only on main pushes, manual dispatch, weekly, and PRs touching shipping paths. The iPad letterbox test moves into the regular app job. **You may want to set a macOS minutes budget** (`docs/prerequisites.md` says "Not recorded"). |
| #66 | What does "stub bot inputs from exactly tick + 15" mean, given BotDriver decides only every 3rd tick? | The host applies `BoatInput.neutral` at exactly T+15 (last held input, or the disconnect if later, + 15). That is the first stub-bot input. After it the bot decides on the seat's usual phase; there's no BotDriver flag. #150 can revisit this. |
| all | The pre-existing `objective-c-xcode.yml` "Build and Analyze" check fails on main. | Not a merge gate. Gates are the ticket's own CI jobs plus the acceptance items. |

## Completed

| Ticket | PR | Rounds | Notes |
|---|---|---|---|
| #56 Deterministic 30 Hz tick | [#178](https://github.com/reederphill/mobile-regatta/pull/178) | 1 (+ review nits) | Linux golden `0x14bb6b704c5211c5` on swift 6.3.3 / glibc 2.39 / x86_64 |
| #57 App test targets, launch options, signposts | [#179](https://github.com/reederphill/mobile-regatta/pull/179) | 1 (+ review nits) | New `app` CI job; `-uitesting` hides the Debug overlay |
| #107 Shipping config baseline | [#183](https://github.com/reederphill/mobile-regatta/pull/183) | 2 | UIKit SceneDelegate; `ios27.yml` path-filtered. iOS 27 evidence is from before the review fixes; Actions was blocked by billing for the final commits |
| #60 Bot seat controller | [#187](https://github.com/reederphill/mobile-regatta/pull/187) | 3 | RegattaBots target; sim revision 4 golden `0x60f517dc895ad1fb`. Rebased onto #63, which needed adapting. Folded in your sin/cos fix (`Trig.swift`) so macOS debug and release digests now match, plus trig source-scan guards |
| #61 Practice race driver | [#190](https://github.com/reederphill/mobile-regatta/pull/190) | 3 | `RaceDriver`/`PracticeDriver`/`VisualCorrection`. Review caught fleet wobble after the finish. Flaky UI runner (launch/terminate) fixed with `-retry-tests-on-failure` and app terminate in tearDown. Merged by you. First ticket on the new process (Sonnet review, Haiku acceptance, CI last) |
| #65 RaceHost core | [#191](https://github.com/reederphill/mobile-regatta/pull/191) | 1 | New `RegattaServer` package (`RaceHost` actor, injected clock and seat transports). CI green on head 0e690e3; Sonnet review had no blockers, nits left unfixed; Haiku acceptance passed all 6 items. Cap of 3 strikes/10 s before disconnect is a builder choice; results payload stays `.none` until #86 |
| #62 Render fixture replay and reference-image diff harness | [#192](https://github.com/reederphill/mobile-regatta/pull/192) | 2 | Resumed half-finished worktree work. Round 2 fixed blockers: missing reference fails (not skips) in CI, record guard also gates on GITHUB_ACTIONS (`ReferencePolicy`). CI green on 5348d41 (app, Linux golden, macOS packages); iOS 27 job still pending at merge. Reference PNG recorded locally (iPhone 17 only; iPad skips explicitly); no vision-filter reference fixture yet |
