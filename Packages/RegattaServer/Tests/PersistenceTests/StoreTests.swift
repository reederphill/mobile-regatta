import Foundation
import Persistence
import PostgresNIO
import RegattaCore
import Testing

private func file(_ id: String, _ version: Int, _ text: String) -> (FileRef, Data) {
    let content = Data(text.utf8)
    return (FileRef(id: id, version: version, hash: ContentHash(of: content)), content)
}

@Suite(TestDatabase.available) struct DataFileStoreTests {
    /// Acceptance (#144, #32): the store keeps every version, and a ref to an old version still gets its bytes.
    @Test func testDataFileStoreReturnsOldVersionByFileRef() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = DataFileStore(database)
            let (v1, content1) = file("skiff", 1, #"{"id":"skiff","version":1}"#)
            let (v2, content2) = file("skiff", 2, #"{"id":"skiff","version":2}"#)
            try await store.put(content1, as: v1)
            try await store.put(content2, as: v2)

            #expect(try await store.content(v1) == content1)
            #expect(try await store.content(v2) == content2)
            #expect(try await store.versions(of: "skiff") == [1, 2])
            #expect(try await store.ref(id: "skiff", version: 1) == v1)
            #expect(try await store.content(file("skiff", 3, "x").0) == nil)
        }
    }

    @Test func testReleasedVersionNeverChanges() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = DataFileStore(database)
            let (v1, content1) = file("skiff", 1, "first")
            try await store.put(content1, as: v1)
            try await store.put(content1, as: v1)  // the same file again: a no-op

            let (other, otherContent) = file("skiff", 1, "changed")
            await #expect(throws: PersistenceError.versionConflict(v1.key)) { try await store.put(otherContent, as: other) }
            await #expect(throws: PersistenceError.hashMismatch(v1.key)) { try await store.content(other) }
            await #expect(throws: PersistenceError.hashMismatch(v1.key)) { try await store.put(otherContent, as: v1) }
            let tuned = FileRef(id: "skiff", version: 1, hash: v1.hash, tune: 1)
            await #expect(throws: PersistenceError.tunedFile(v1.key)) { try await store.put(content1, as: tuned) }
            #expect(try await store.content(v1) == content1)

            // The table itself refuses to change or lose a version.
            await #expect(throws: (any Error).self) {
                try await database.client.query("DELETE FROM data_files WHERE id = 'skiff'")
            }
            await #expect(throws: (any Error).self) {
                try await database.client.query("UPDATE data_files SET content = '\\x00' WHERE id = 'skiff'")
            }
            #expect(try await store.content(v1) == content1)
        }
    }
}

@Suite(TestDatabase.available) struct RaceRegistryStoreTests {
    /// Acceptance (#144): create, read, list, close; a closed race can't close or be cancelled again.
    @Test func testRegistryCreateReadUpdateClose() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let files = DataFileStore(database)
            let (boat, boatContent) = file("skiff", 4, "boat")
            let (venue, venueContent) = file("harbour", 1, "venue")
            try await files.put(boatContent, as: boat)
            try await files.put(venueContent, as: venue)

            let registry = RaceRegistryStore(database)
            let id = UUID()
            let created = try await registry.create(id: id, files: [boat, venue])
            #expect(created.state == .running && created.endedAt == nil)
            #expect(created.files == [venue.key, boat.key])
            #expect(try await registry.race(id) == created)
            #expect(try await registry.races(in: .running).map(\.id) == [id])
            await #expect(throws: PersistenceError.raceExists(id)) { try await registry.create(id: id) }

            let closed = try await registry.close(id)
            #expect(closed.state == .closed && closed.endedAt != nil && closed.files == created.files)
            #expect(try await registry.race(id) == closed)
            #expect(try await registry.races(in: .running).isEmpty)
            #expect(try await registry.races(in: .closed).map(\.id) == [id])
            await #expect(throws: PersistenceError.raceNotInState(id, expected: .running, actual: .closed)) {
                try await registry.cancel(id)
            }
            await #expect(throws: PersistenceError.raceNotInState(id, expected: .cancelled, actual: .closed)) {
                try await registry.delete(id)
            }
            let missing = UUID()
            await #expect(throws: PersistenceError.raceNotFound(missing)) { try await registry.close(missing) }
            #expect(try await registry.race(missing) == nil)
        }
    }

    /// Acceptance (#144, #30): a running race is cancelled by hand or as an orphan; a cancelled race is deleted.
    @Test func testRegistryCreateReadUpdateCancel() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let registry = RaceRegistryStore(database)
            let cancelled = try await registry.create()
            let finished = try await registry.create()
            let orphans = [try await registry.create(), try await registry.create()].map(\.id)

            #expect(try await registry.cancel(cancelled.id).state == .cancelled)
            try await registry.close(finished.id)
            #expect(try await registry.cancelOrphans() == orphans.sorted { $0.uuidString < $1.uuidString })
            #expect(try await registry.cancelOrphans() == [])
            #expect(try await registry.races(in: .running).isEmpty)
            #expect(Set(try await registry.races(in: .cancelled).map(\.id)) == Set(orphans + [cancelled.id]))
            #expect(try await registry.race(finished.id)?.state == .closed)

            try await registry.delete(cancelled.id)
            #expect(try await registry.race(cancelled.id) == nil)
        }
    }

    @Test func testRaceMustNameStoredFiles() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let registry = RaceRegistryStore(database)
            let (boat, boatContent) = file("skiff", 4, "boat")
            await #expect(throws: PersistenceError.hashMismatch(boat.key)) { try await registry.create(files: [boat]) }
            try await DataFileStore(database).put(boatContent, as: boat)
            let other = file("skiff", 4, "another boat").0
            await #expect(throws: PersistenceError.hashMismatch(boat.key)) { try await registry.create(files: [other]) }
            #expect(try await registry.races(in: .running).isEmpty)
            #expect(try await registry.create(files: [boat]).files == [boat.key])
        }
    }

    @Test func testRaceLogIsStoredOnceAsBytes() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let registry = RaceRegistryStore(database)
            let logs = RaceLogStore(database)
            let race = try await registry.create()
            let log = Data((0..<4096).map { UInt8($0 % 251) })

            #expect(try await logs.log(for: race.id) == nil)
            try await logs.put(log, for: race.id)
            #expect(try await logs.log(for: race.id) == log)
            await #expect(throws: PersistenceError.raceLogExists(race.id)) { try await logs.put(Data([1]), for: race.id) }
            let unknown = UUID()
            await #expect(throws: PersistenceError.raceNotFound(unknown)) { try await logs.put(log, for: unknown) }
        }
    }
}

@Suite(TestDatabase.available) struct PlayerAndSessionStoreTests {
    @Test func testPlayersAreKeyedByGameCenterID() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let players = PlayerStore(database)
            let created = try await players.upsert(gameCenterID: "G:123", displayName: "Phill")
            #expect(created.gameCenterID == "G:123" && created.displayName == "Phill")
            let renamed = try await players.upsert(gameCenterID: "G:123", displayName: "Skipper")
            #expect(renamed.displayName == "Skipper" && renamed.createdAt == created.createdAt)
            #expect(try await players.player(gameCenterID: "G:123") == renamed)
            #expect(try await players.player(gameCenterID: "G:999") == nil)

            let sessions = SessionStore(database)
            let now = Date()
            let token = Data(repeating: 7, count: 32)
            let session = try await sessions.create(playerID: "G:123", tokenHash: token, expiresAt: now + 3600)
            #expect(try await sessions.session(tokenHash: token, at: now)?.id == session.id)
            #expect(try await sessions.session(tokenHash: token, at: now + 7200) == nil)
            await #expect(throws: (any Error).self) {
                try await sessions.create(playerID: "G:999", tokenHash: Data([1]), expiresAt: now)
            }
            #expect(try await sessions.deleteExpired(at: now + 7200) == 1)

            try await sessions.create(playerID: "G:123", tokenHash: token, expiresAt: now + 3600)
            #expect(try await players.delete(gameCenterID: "G:123"))
            #expect(try await sessions.session(tokenHash: token, at: now) == nil)
        }
    }
}
