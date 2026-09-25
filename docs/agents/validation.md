<!-- machine-generated: for agents, not human readers -->
# Validation

## Order (stop at the first failure)

| # | what | where | when |
|---|------|-------|------|
| 1 | `scripts/check.sh` | local | after every edit batch; first thing after a rebase |
| 2 | CI on the PR | GitHub Actions | before merge; required |
| 3 | `scripts/linux-test.sh` | local podman | only if CI can't run, or a new golden row is needed |

- `check.sh`: compiles every affected package + tests (+ app tests if reached), then tests, then app unit tests. Affected = changed since merge base with `origin/main`.
- CI: Linux golden + RegattaBots digests (debug/release), Linux build of every package, macOS package tests, digest stability, app unit + UI tests. Skips jobs the change can't reach.
- Golden / Linux: once, before merge, in CI. Never in the edit loop.

## Rules

- Rebase: `check.sh` before any test run. Compile errors from API drift are the usual rebase failure.
- Failure or flake: rerun only the failed step (`check.sh --packages <P>`, `swift test --filter <Suite>`). Never the whole gate.
- Timeouts: scripts enforce their own (`CHECK_STEP_TIMEOUT_MINUTES`, `LINUX_TEST_TIMEOUT_MINUTES`). Shell calls: never block without a timeout.
- Report what passed before starting a slow step.
- Reuse: `check.sh` records passed steps per tree hash in `$(git rev-parse --git-common-dir)/check-passed/<tree>`, shared by every worktree, and skips them on the same tree. Validators and reviewers read that record and CI for the head SHA; don't rerun suites on an unchanged tree. Tree of a commit: `git rev-parse <sha>^{tree}`.
- No direct `xcodebuild` or `swift test` except a `--filter`/`-only-testing` rerun of a step that failed. Everything else goes through `check.sh`, so it's recorded.
- UI tests (`RegattaUITests`, minutes each) run only in CI. Don't run them locally unless CI can't and the ticket's acceptance needs one.
- Long runs: `run_in_background` and one wait until it finishes. No `sleep` polling loops. Pipe output through `tail`/`grep`; never dump a full build log.

## Model routing

| role | model | input |
|------|-------|-------|
| review, validation (judgment) | Sonnet | diff, ticket, acceptance list |
| acceptance check (mechanical) | Haiku | diff, ticket, acceptance list |

- Give only those three. No session history.
- Acceptance check: map each item to its named test, then read its result; don't run it. Sources, in order: CI for the head SHA (`gh pr checks`, `gh run view <id> --log | grep <test>`), then the `check.sh` record for the head's tree. Run a test only if neither covers it, and only through `check.sh` or a single `--filter` run. Report pass/fail per item with the source. Item without a named test: report `no test named`; don't judge it.
