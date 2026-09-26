// regatta-venue-png (#83): writes an overview PNG of every shipped venue × conditions pairing (land, race
// area at the mean direction and ±10°, marks, depth tint) into docs/venues/ for the venue art (#84). See
// `VenuePNGCommand.usage`.
import Foundation
import VenueTools

exit(VenuePNGCommand.main(arguments: Array(CommandLine.arguments.dropFirst())))
