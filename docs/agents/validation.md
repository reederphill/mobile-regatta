<!-- machine-generated: for agents, not human readers -->
# Validation

## Order (stop at the first failure)

| # | what | where | when |
|---|------|-------|------|
| 1 | `scripts/check.sh` | local | after every edit batch; first thing after a rebase |
| 2 | CI on the PR | GitHub Actions | before merge; required |
| 3 | render references (`RegattaUITests/References/`) | CI app job's `render-actuals` artifact | a change that moves a render (e.g. a sim bump that moves `prestart.png`) fails the compare in CI, which uploads the render: `scripts/adopt-references.sh <PR>` copies it in; look at it, commit it, push; the next CI run passes the compare (no local re-records) |
| 4 | golden / RegattaBots rows | CI Linux job log | a sim change needs a new row: take `GOLDEN …` and `REGATTABOTS …` from the log and commit the row last, after review (no local podman since 2026-09-25) |

- `check.sh`: a few minutes. Compiles every affected package + tests (+ the app and its tests if reached), then tests only the packages the change touched. Downstream packages' tests and the app's unit tests are CI's (`--all` runs them locally). Affected = reached from files changed since merge base with `origin/main`. Tests build at `-O` (the simulation is ~15x faster); debug = release digests are CI's job. Each package has its own scratch dir, and check.sh fails a package if any of its test targets didn't run.
- CI: Linux golden + RegattaBots digests (debug/release), Linux build of every package, macOS package tests, digest stability, app unit + UI tests. Skips jobs the change can't reach. In the app job the render references run first, as their own step with no retry (a moved render fails the run early); the image-diff tool's self-tests run only when `ImageDiff`/`ReferencePolicy` change; the end-to-end run only when online code changes; the iPad letterbox test and the iOS 27 workflow run on main and nightly/weekly, not on a pull request. Every commit on main gets its full run (no cancel-in-progress there).
- Golden / Linux: once, before merge, in CI. Never in the edit loop.
- Render references: CI's render is the reference (renders are only reproducible on CI's pinned device and OS; a Mac recording drifted 0.2% in #209). A reference compare that fails, or has no reference, in the app job leaves the render in `render-actuals` (`<device>/<name>.png`, plus `<name>-diff.png` to look at; kept 5 days; uploaded only when the job fails). `scripts/adopt-references.sh <PR>` (or `--run <id>`) copies the renders, never the diffs, into `RegattaUITests/References/` and prints what changed. Nobody re-records locally; `-recordReferences` is refused in CI and isn't the route for a reference change.
- Sim revision: a sim-changing ticket takes the **next free** `simulationRevision` at merge time (rebase first; never reserve one in advance).

## Rules

- Rebase: `check.sh` before any test run. Compile errors from API drift are the usual rebase failure.
- Failure or flake: rerun only the failed step (`check.sh --packages <P>`, `scripts/heavy.sh swift test --filter <Suite> --package-path Packages/<P> --scratch-path .build/check/<P> -Xswiftc -O`). Never the whole gate.
- Locks: `check.sh` takes a machine-wide build lock per build/package-test step and a simulator lock for the app tests, shared by every worktree; it prints who holds one while it waits. Don't wrap it in another lock. Any other heavy command goes through `scripts/heavy.sh` (`--simulator` for xcodebuild tests).
- Timeouts: scripts enforce their own (`CHECK_STEP_TIMEOUT_MINUTES`, `LINUX_TEST_TIMEOUT_MINUTES`). Shell calls: never block without a timeout.
- Report what passed before starting a slow step.
- Reuse: `check.sh` records each passed test step keyed by the content it depends on (its package and those below it; for the app, its sources, tests, project and linked packages), shared by every worktree, and skips it (and its build) wherever that content recurs: a rebase or an unrelated commit reruns nothing. Validators and reviewers: `scripts/check.sh --status --rev <sha>` (exit 0 = everything the change reaches passed) and CI for the head SHA; don't rerun suites that passed.
- Implementers and fixers compile (`scripts/heavy.sh swift build --build-tests`, or `xcodebuild build` for the app) and run only their own new or changed tests (`--filter`, through `scripts/heavy.sh`); they don't run `check.sh`. The tester runs the gate (`check.sh`, recorded) and any targeted runs its plan calls for. No direct `xcodebuild` / `swift test` outside `scripts/heavy.sh`.
- UI tests (`RegattaUITests`, minutes each) run only in CI. Implementers never run them locally. The orchestrator may, only when CI can't and the ticket's acceptance needs one. A reference image comes from CI's `render-actuals` too, never a local recording (Render references, above).
- Long runs: run `check.sh` in the foreground with a 600000 ms timeout. If a run can outlast that, `run_in_background` and end your turn; the completion notification wakes you. Pipe output through `tail`/`grep`; never dump a full build log.
- Never poll: no `until`/`while`/`for` loop with `sleep`. Never `pgrep -f check.sh`: it matches every agent's run, not yours.
- `== waiting for check-build.lock` means another worktree holds the machine. Wait for your run; don't start a second one.

## Model routing

| role | model | input |
|------|-------|-------|
| tester (scopes and runs validation) | Sonnet, high effort | brief, diff, implementation note |
| review, validation (judgment) | Sonnet | diff, ticket, acceptance list |
| acceptance check (mechanical) | Haiku | diff, ticket, acceptance list |

- Give only those three. No session history.
- Acceptance check: map each item to its named test, then read its result; don't run it. Sources, in order: the `check.sh` record (`scripts/check.sh --status --rev <sha>` prints each step's `.tests` file, one passed `Target.Suite/test` per line: grep it), then CI for the head SHA (`gh pr checks`, `gh run view <id> --log | grep <test>`). Run a test only if neither covers it, and only through `check.sh` or a single `--filter` run. Report pass/fail per item with the source. Item without a named test: report `no test named`; don't judge it.
