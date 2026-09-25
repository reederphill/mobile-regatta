import Crypto
import Foundation
import RaceHost
import RegattaCore
import RegattaDevAPI
@testable import RegattaServerKit
import Testing

/// #67: the race is handed off by a signed race token, and each race owns its own state (#31).
struct RaceTokenTests {
    let key = SymmetricKey(size: .bits256)
    let token = RaceToken(raceID: UUID(), seat: 7, expiresAt: 2_000_000_000)

    @Test func aSignedTokenVerifiesToItself() throws {
        let bytes = token.signed(with: key)
        #expect(bytes.count == RaceToken.size)
        #expect(try RaceToken.verify(bytes, key: key, now: 1_900_000_000) == token)
        #expect(try RaceToken.verify(bytes, key: key, now: token.expiresAt) == token)
    }

    @Test func anyChangedByteBreaksTheSignature() {
        let bytes = token.signed(with: key)
        for index in 1..<bytes.count {
            var tampered = bytes
            tampered[index] ^= 0x01
            #expect(throws: RaceTokenError.badSignature) { try RaceToken.verify(tampered, key: key, now: 0) }
        }
    }

    @Test func anotherServersKeyExpiryAndMalformedTokensAreRefused() {
        let bytes = token.signed(with: key)
        #expect(throws: RaceTokenError.badSignature) { try RaceToken.verify(bytes, key: SymmetricKey(size: .bits256), now: 0) }
        #expect(throws: RaceTokenError.expired) { try RaceToken.verify(bytes, key: key, now: token.expiresAt + 1) }
        #expect(throws: RaceTokenError.malformed) { try RaceToken.verify(Array(bytes.dropLast()), key: key, now: 0) }
        #expect(throws: RaceTokenError.malformed) { try RaceToken.verify([], key: key, now: 0) }
        var otherVersion = bytes
        otherVersion[0] = 2
        #expect(throws: RaceTokenError.malformed) { try RaceToken.verify(otherVersion, key: key, now: 0) }
    }
}

/// The instant race's fleet: 1…16 clients, bots up to 10 seats.
struct InstantRaceTests {
    @Test func botsFillTheFleetToTenAndNoFurther() throws {
        for (clients, fleet) in [(1, 10), (2, 10), (9, 10), (10, 10), (11, 11), (16, 16)] {
            let session = try RaceSession.instant(InstantRaceRequest(clients: clients, seed: 67))
            #expect(session.setup.fleetSize == fleet)
            #expect(session.humanSeats == Set(0..<clients))
            #expect(session.setup.seats.filter { $0 == .bot }.count == fleet - clients)
        }
    }

    @Test func theRequestIsValidated() throws {
        #expect(try InstantRaceRequest(query: "") == InstantRaceRequest(clients: 1))
        #expect(try InstantRaceRequest(query: "clients=16&raceSeconds=20&startSeconds=5&seed=9")
                == InstantRaceRequest(clients: 16, raceSeconds: 20, startSeconds: 5, seed: 9))
        for bad in ["clients=0", "clients=17", "clients=x", "raceSeconds=0", "startSeconds=61", "seed=-1", "laps=3"] {
            #expect(throws: InstantRaceRequestError.self) { try InstantRaceRequest(query: bad) }
        }
    }

    @Test func theRaceLengthOverrideClosesTheRaceAfterThatManySecondsFromTheGun() throws {
        let session = try RaceSession.instant(InstantRaceRequest(clients: 1, raceSeconds: 20, startSeconds: 5, seed: 1))
        #expect(session.setup.startSequenceTicks == 5 * Race.tickRate)
        #expect(session.closeAtTick == 20 * Race.tickRate)
        #expect(try RaceSession.instant(InstantRaceRequest(clients: 1, seed: 1)).closeAtTick == nil)
    }

    /// #31: each race has its own host, and ending one leaves the others as they were.
    @Test func eachRaceOwnsItsState() async throws {
        let registry = RaceRegistry()
        let short = try RaceSession.instant(InstantRaceRequest(clients: 1, raceSeconds: 1, startSeconds: 1, seed: 1))
        let long = try RaceSession.instant(InstantRaceRequest(clients: 1, startSeconds: 60, seed: 1))
        #expect(short.host !== long.host)
        #expect(short.id != long.id)
        try await registry.start(short)
        try await registry.start(long)
        #expect(await registry.count == 2)
        while await registry.session(short.id) != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await short.host.outcome != nil)
        #expect(await long.host.outcome == nil)
        #expect(await registry.session(long.id) != nil)
        await registry.closeAll()
        #expect(await long.host.outcome != nil)
        #expect(await registry.count == 0)
    }

    @Test func windKeysAreRevealedASecondAheadOfTheirWindow() throws {
        let session = try RaceSession.instant(InstantRaceRequest(clients: 1, seed: 3))
        let reveal = RaceSession.windKeyReveal(setup: session.setup, windSeed: WindSeed(3))
        let race = Race(setup: session.setup, windSeed: WindSeed(3))
        let windows = race.wind.windows
        let first = reveal(-session.setup.startSequenceTicks)
        #expect(!first.isEmpty)
        let next = first.count
        let due = windows.start(of: next) - Race.tickRate
        #expect(reveal(due - 1).isEmpty)
        #expect(reveal(due).map(\.window) == [next])
    }
}
