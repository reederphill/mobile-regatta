import Foundation
import RegattaCore
@testable import RegattaProtocol
import Testing

/// A data file's ref on the wire (ADR 0004): its id, version and hash, and never a tuned copy's tune.
@Suite struct FileRefCodecTests {
    /// Tuned copies sail practice races only, never online (#229): a ref with a tune is refused before
    /// anything is written, in a `Hello` and in a `RaceStart`'s setup alike. The same file untuned goes
    /// through and comes back untuned.
    @Test func tunedRefIsRejected() throws {
        let bundled = RaceFiles.defaults.boatClass.ref
        let tuned = FileRef(id: bundled.id, version: bundled.version, hash: ContentHash(of: Data("tuned".utf8)), tune: 1)
        let untuned = FileRef(id: tuned.id, version: tuned.version, hash: tuned.hash)

        var w = WireWriter()
        #expect(throws: WireError.outOfRange("file.tune")) { try tuned.encode(to: &w) }
        #expect(w.bytes.isEmpty)

        #expect(throws: WireError.outOfRange("file.tune")) {
            try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "1.0 (1)", files: [bundled, tuned]))).encoded()
        }
        let hello = Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "1.0 (1)", files: [bundled, untuned])))
        #expect(try Frame(decoding: hello.encoded()) == hello)

        let roster = [RosterEntry(name: "Ann", colorIndex: 0), RosterEntry(name: "Gannet", colorIndex: 1)]
        let tunedSetup = try RaceSetup(raceSeed: RaceSeed(239), seats: [.human, .bot], boatClass: tuned)
        #expect(throws: WireError.outOfRange("file.tune")) {
            try Frame(seq: 1, tick: 0, message: .raceStart(RaceStart(yourSeat: 0, setup: tunedSetup, roster: roster))).encoded()
        }
        let setup = try RaceSetup(raceSeed: RaceSeed(239), seats: [.human, .bot], boatClass: untuned)
        let start = Frame(seq: 1, tick: 0, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: roster)))
        let decoded = try Frame(decoding: start.encoded())
        #expect(decoded == start)
        guard case .raceStart(let back) = decoded.message else { return }
        #expect(back.setup.boatClass.tune == nil)
    }
}
