<!-- machine-generated: for agents, not human readers -->
# Validation

## Order (stop at the first failure)

| # | what | where | when |
|---|------|-------|------|
| 1 | `scripts/check.sh` | local | after every edit batch; first thing after a rebase |
| 2 | CI on the PR | GitHub Actions | before merge; required |
| 3 | `scripts/linux-test.sh` | local podman | only if CI can't run, or a new golden row is needed |

- `check.sh`: compiles every affected package + tests (+ app tests if reached), then tests, then app unit tests. Affected = changed since merge base with `origin/main`. Tests build at `-O` (the simulation is ~15x faster); debug = release digests are CI's job. Each package has its own scratch dir, and check.sh fails a package if any of its test targets didn't run.
- CI: Linux golden + RegattaBots digests (debug/release), Linux build of every package, macOS package tests, digest stability, app unit + UI tests. Skips jobs the change can't reach.
- Golden / Linux: once, before merge, in CI. Never in the edit loop.

## Rules

- Rebase: `check.sh` before any test run. Compile errors from API drift are the usual rebase failure.
- Failure or flake: rerun only the failed step (`check.sh --packages <P>`, `scripts/heavy.sh swift test --filter <Suite> --package-path Packages/<P> --scratch-path .build/check/<P> -Xswiftc -O`). Never the whole gate.
- Locks: `check.sh` takes a machine-wide build lock per build/package-test step and a simulator lock for the app tests, shared by every worktree; it prints who holds one while it waits. Don't wrap it in another lock. Any other heavy command goes through `scripts/heavy.sh` (`--simulator` for xcodebuild tests).
- Timeouts: scripts enforce their own (`CHECK_STEP_TIMEOUT_MINUTES`, `LINUX_TEST_TIMEOUT_MINUTES`). Shell calls: never block without a timeout.
- Report what passed before starting a slow step.
- Reuse: `check.sh` records each passed test step keyed by the content it depends on (its package and those below it; for the app, its sources, tests, project and linked packages), shared by every worktree, and skips it (and its build) wherever that content recurs: a rebase or an unrelated commit reruns nothing. Validators and reviewers: `scripts/check.sh --status --rev <sha>` (exit 0 = everything the change reaches passed) and CI for the head SHA; don't rerun suites that passed.
- No direct `xcodebuild` or `swift test` except a `--filter`/`-only-testing` rerun of a step that failed, through `scripts/heavy.sh`. Everything else goes through `check.sh`, so it's recorded.
- UI tests (`RegattaUITests`, minutes each) run only in CI. Don't run them locally unless CI can't and the ticket's acceptance needs one.
- Long runs: `run_in_background` and one wait until it finishes. No `sleep` polling loops. Pipe output through `tail`/`grep`; never dump a full build log.

## Model routing

| role | model | input |
|------|-------|-------|
| review, validation (judgment) | Sonnet | diff, ticket, acceptance list |
| acceptance check (mechanical) | Haiku | diff, ticket, acceptance list |

- Give only those three. No session history.
- Acceptance check: map each item to its named test, then read its result; don't run it. Sources, in order: the `check.sh` record (`scripts/check.sh --status --rev <sha>` prints each step's `.tests` file, one passed `Target.Suite/test` per line: grep it), then CI for the head SHA (`gh pr checks`, `gh run view <id> --log | grep <test>`). Run a test only if neither covers it, and only through `check.sh` or a single `--filter` run. Report pass/fail per item with the source. Item without a named test: report `no test named`; don't judge it.
