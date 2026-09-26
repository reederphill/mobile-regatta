// regatta-botsuite (#97): sails the headless bot-race matrix, writes the per-seat metrics as JSON, and
// exits non-zero when the run misses the thresholds (#19, #27). See `BotSuiteOptions.usage`.
import BotSuite
import Foundation

exit(BotSuiteCommand.main(arguments: Array(CommandLine.arguments.dropFirst())))
