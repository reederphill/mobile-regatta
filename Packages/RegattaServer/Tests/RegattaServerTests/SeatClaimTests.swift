import Foundation
import RaceHost
import RegattaDevAPI
@testable import RegattaServerKit
import Synchronization
import Testing

/// #67: one token can reach the server on two sockets at once; exactly one of them gets the seat.
struct SeatClaimTests {
    @Test func concurrentJoinsForOneSeatSeatExactlyOneAndTheLosersLeavingKeepsTheWinner() async throws {
        for seed in 1...200 {
            let session = try RaceSession.instant(InstantRaceRequest(clients: 1, startSeconds: 60, seed: UInt64(seed)))
            let transports = (0..<8).map { _ in ClosingTransport() }
            let results = await withTaskGroup(of: (ClosingTransport, RaceSession.JoinRefusal?).self) { group in
                for transport in transports { group.addTask { (transport, await Self.join(session, transport)) } }
                return await group.reduce(into: []) { $0.append($1) }
            }

            let winners = results.filter { $0.1 == nil }.map(\.0)
            #expect(winners.count == 1, "seed \(seed): \(winners.count) joins took the seat")
            #expect(results.filter { $0.1 == .seatTaken }.count == transports.count - 1)
            guard winners.count == 1 else { continue }
            let winner = winners[0]

            for loser in transports where loser !== winner { await session.leave(seat: 0, transport: loser) }
            #expect(await session.host.isAttached(seat: 0), "seed \(seed): a loser's goodbye cut the winner")
            #expect(!winner.isClosed)

            // The winner's own goodbye still frees the seat, and a later join takes it back.
            await session.leave(seat: 0, transport: winner)
            #expect(await !session.host.isAttached(seat: 0))
            #expect(await Self.join(session, ClosingTransport()) == nil)
            await session.host.close()
        }
    }

    private static func join(_ session: RaceSession, _ transport: any SeatTransport) async -> RaceSession.JoinRefusal? {
        do { try await session.join(seat: 0, transport: transport); return nil } catch { return error }
    }
}

private final class ClosingTransport: SeatTransport {
    private let closed = Mutex(false)
    func send(_ frame: [UInt8]) {}
    func close() { closed.withLock { $0 = true } }
    var isClosed: Bool { closed.withLock { $0 } }
}
