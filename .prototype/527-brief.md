# #527 Part A — fouls probe: implementer brief

Prototype branch `prototype/527-fouls`, worktree `.claude/worktrees/t527`. **Nothing here merges.** Probe code only; brain
behaviour must stay bit-identical to main (the trace fields are write-only side channels).

The full ticket is `.prototype/527-issue.md` (read "Part A" and "Owner commands"; skip Part B).

## Already on the branch

- `origin/main` (0135bdae) + the #464 probe ported (commit "PROBE #464: brain decision trace..."):
  `Sources/RegattaBots/BotProbe.swift` (`BotProbeTrace`: `branch`, `evasion`, `keepClearRule`, `wantsOtherTack`,
  `cantTapWhy`, ...), written in `BotBrain.swift`, read through `BotDriver.probe`; `Sources/regatta-roundprobe/main.swift`.
- It builds: `scripts/heavy.sh swift build -c release --product regatta-roundprobe --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore`.

## Build

Add a `--fouls` mode to `regatta-roundprobe` (a new file in that target is fine; keep `main.swift`'s rounding mode working).

1. **Same races as the gate.** `regatta-roundprobe --fouls --profile-mix live --tier-mix national` must sail exactly the
   races `regatta-botsuite --profile-mix live --tier-mix national` sails: the bundled matrix (`BotMatrix.bundled()`,
   seeds 1–4, 2/5/10/16 boats, four venues = 160 races) filtered to that profile/tier mix, with the controllers,
   cautious seats, seat skills and profiles built as `BotRaceHarness.run(_:cautiousSeats:seatSkills:...)`
   (`Sources/BotSuite/Harness.swift:109`) builds them. The current roundprobe loop passes `profile: nil` and its own
   matrix: don't copy that. Also accept `--matrix <json>`, `--boat-class`, `--seeds`, `--fleet-size` for the playtest
   fleet later. **Gate check:** print total calls as offender (pre-start and racing) and compare with
   `regatta-botsuite --profile-mix live --tier-mix national --diagnose` (`pre-start calls a boat by rule`, penalty
   episodes); they must match. Ticket expects ~370 racing + ~265 pre-start calls.
2. **Every call as offender** (`RaceEvent` / `Incident` `.called(RuleCall)` — find where the diagnose records calls,
   `Diagnose.swift` `recordCall`) gets one record (JSON, `--json fouls.json`), with:
   - rule (10/11/12/13/15/16.1/18.2/21.2/31/other), the other boat's seat, phase (`PenaltyPhase.at`), tier/skill of both,
     whether the offender is cautious, class.
   - **Geometry** at the call tick and 3 s before: other boat's relative bearing (from offender's bow) and range; both
     headings relative to the wind (TWA signed) and speeds as share of polar; each boat's flags: turning (|yaw rate|
     over a threshold you name), `isTacking`, `isTakingPenalty`, stopped (< 0.30 polar), luffing at the line
     (pre-start, within ~2 lengths of the line, TWA < 35°); distance to the line, to the nearest mark; seat and range of
     any third boat within 2 hull lengths of the offender.
   - **Brain, 5 s before the call** (every decision tick, i.e. when the driver decides): `evasion`, `keepClearRule`,
     chosen vs desired heading delta, `isAboutToHit` fired (and lookahead used), `wantsOtherTack` / `cantTapWhy`,
     misjudged (`misjudges`). Add the fields you need to `BotProbeTrace` (write-only). Summarise per record:
     share of decisions with keep-clear evasion, whether evasion targeted the *other* boat of the call (first-boat-wins,
     limit 3: record which boat `ruleKeepClear` returned on vs the eventual foul boat), whether `crossesEarly` /
     line-fallback fired pre-start (limit 5), tap refused and why (limit 6), heading toggling (limit 4: count sign changes
     of the evasion offset).
   - **Cascade**: offender already `isTakingPenalty` at the call, or within 15 s of her previous call.
3. **Counterfactual manoeuvres.** Keep a ring of `race.exportSnapshot()` (every 0.5 s back 10.5 s) plus every seat's
   held input per tick (`race.heldInputs`). At each call: fork a fresh `Race` (same setup/files/mode) at T−5 s with
   `importSnapshot` (see `PackScenario.place`/`placedRace` for the pattern), drive every other seat with its recorded
   inputs, and the offender with each of: hold (rudder centred / autohelm heading held); luff 10°, 20°, 40°; bear away
   10°, 20°, 40° (heading targets relative to her heading at T−5 s, reached with her own class's helm); ease to half
   speed (sheet eased, course held); tack; gybe. Step to call tick + 1 s. "Avoided" = no call against the offender
   involving the same other boat in that window (also record whether *any* call against her fires, e.g. into a third
   boat). If none avoids it, repeat from T−10 s ("committed 5 s out" vs "committed 10 s out").
   - **Identity check first:** fork and replay the offender on her *recorded* inputs; the call must reproduce. Report
     the reproduction rate. If the snapshot lacks umpire recorder history (rules read up to 242 ticks back on
     fleet-rules@7) and that breaks reproduction, find the fix (e.g. fork further back and replay recorded inputs to
     T−5 s, then branch) and say what you did.
   - Others replay inputs, not positions: wind-shadow changes can move them slightly. Fine; note it.
4. **Classification** (printed table + in JSON): per rule × phase × dominant geometry (name a small set of geometry
   classes from the data: e.g. clear astern overtaking, port/starboard crossing, windward/leeward overlapped, luffing at
   the line, tacking too close, into a penalty turner, mark-room), share of fouls; per cell the share avoided by:
   (a) a heading change on her own tack within `clearingHeading`'s reach (luff/bear-away 10–20°, same tack — confirm the
   scan's actual range in `BotBrain+Conduct.swift` / `BotBrain.swift` and state it), (b) a manoeuvre the evaluator can't
   produce (ease, tack, gybe, 40° bear-away/luff beyond the scan), (c) weighing a second boat (avoidable only by a
   manoeuvre that the brain's evasion rejected because of / was steering for a different boat; define it from the trace),
   (d) nothing within 5 s (and how many of those are avoidable at 10 s). Separately: cascades count, pre-start
   line-over-rules fallbacks count.

## Rules

- Build with `scripts/heavy.sh` (8 GB Mac, one heavy job at a time; never run two builds). No `check.sh`, no bot matrix,
  no UI tests. No tests required for probe code; the identity check and the gate-count match are the validation.
- Determinism: the probe must not change any brain decision. Confirm with a quick diff of one race's final results
  probe vs `regatta-botsuite` (or the gate-count match).
- Commit locally on `prototype/527-fouls` as you go (`PROBE #527: ...`). Don't push.
- Context budget: stop near ~400K tokens / ~150 tool calls: WIP commit, handoff note in the commit message and in
  `.prototype/527-handoff.md` (done, next, gotchas, exact next command), and return.
- Long runs: the full 160-race run with counterfactuals may take a while; run it once at the end with `run_in_background`
  if it exceeds ~9 min, writing to `.prototype/527-fouls.json` and `.prototype/527-fouls.txt`. Debug on a few seeds first
  (`--seeds 1`, one fleet size).

## Return

Short note: what was built, the gate-count match, identity-check reproduction rate, runtime, the exact command, and the
printed classification table (or where it is). Don't interpret beyond the table; the orchestrator writes the findings.
