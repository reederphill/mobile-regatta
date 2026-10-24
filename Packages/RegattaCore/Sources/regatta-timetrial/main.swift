// regatta-timetrial (#583): the oracle time trial. One boat, no fleet: the fastest lap a search finds on each seed, and
// where each tier and profile loses her time to it. See `TimeTrialOptions.usage`.
import BotSuite
import Foundation

exit(TimeTrial.main(arguments: Array(CommandLine.arguments.dropFirst())))
