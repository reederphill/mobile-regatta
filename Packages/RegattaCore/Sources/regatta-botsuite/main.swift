// regatta-botsuite (#97): sails the headless bot-race matrix, writes the per-seat metrics as JSON, and
// exits non-zero when the run misses the thresholds (#19, #27). See `BotSuiteOptions.usage`.
// `regatta-botsuite results-seed`, `rounding-seed` and `ease-seed` are the UI tests' seed probes instead (#404,
// `ResultsSeedProbe`, `RoundingSeedProbe`, `EaseSeedProbe`).
import BotSuite
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "results-seed" { exit(ResultsSeedProbe.main(arguments: Array(arguments.dropFirst()))) }
if arguments.first == "rounding-seed" { exit(RoundingSeedProbe.main(arguments: Array(arguments.dropFirst()))) }
if arguments.first == "ease-seed" { exit(EaseSeedProbe.main(arguments: Array(arguments.dropFirst()))) }
exit(BotSuiteCommand.main(arguments: arguments))
