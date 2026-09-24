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
- Reuse: `check.sh` records passed steps per tree hash in `.build/check/passed/<tree>` and skips them on the same tree. Validators and reviewers read that record and CI for the head SHA; don't rerun suites on an unchanged tree.

## Model routing

| role | model | input |
|------|-------|-------|
| review, validation (judgment) | Sonnet | diff, ticket, acceptance list |
| acceptance check (mechanical) | Haiku | diff, ticket, acceptance list |

- Give only those three. No session history.
- Acceptance check: run each item's named test (`swift test --package-path Packages/<P> --filter <Suite.test>`), report pass/fail per item. Item without a named test: report `no test named`; don't judge it.
