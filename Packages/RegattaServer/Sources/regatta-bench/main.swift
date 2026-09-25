// regatta-bench (#69): times the race server's tick with bot fleets and, with --gate, fails when it misses
// the budget (#27). See `BenchOptions.usage`.
import Bench
import Foundation

exit(BenchCommand.main(arguments: Array(CommandLine.arguments.dropFirst())))
