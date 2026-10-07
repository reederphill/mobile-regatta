import Foundation
import PostgresNIO
import RegattaCore

/// Every released version of every data file (#32, ADR 0004), put and got by `FileRef`. A version, once stored,
/// never changes and is never deleted (the table's trigger refuses both), so every version a race log names
/// stays readable.
public struct DataFileStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Stores `content` as `ref`. Storing the same file again is a no-op; the same id and version with another
    /// hash is refused, as is content whose hash isn't `ref`'s or a tuned copy.
    public func put(_ content: Data, as ref: FileRef) async throws {
        guard ref.tune == nil else { throw PersistenceError.tunedFile(ref.key) }
        guard ContentHash(of: content) == ref.hash else { throw PersistenceError.hashMismatch(ref.key) }
        let hash = Data(ref.hash.bytes)
        try await database.transaction { connection in
            try await connection.query("""
                INSERT INTO data_files (id, version, hash, content) VALUES (\(ref.id), \(ref.version), \(hash), \(content))
                ON CONFLICT (id, version) DO NOTHING
                """, logger: database.logger)
            let stored = try await connection.query(
                "SELECT hash FROM data_files WHERE id = \(ref.id) AND version = \(ref.version)", logger: database.logger)
            for try await storedHash in stored.decode(Data.self) where storedHash != hash {
                throw PersistenceError.versionConflict(ref.key)
            }
        }
    }

    /// The content `ref` names, or nil if that id and version isn't stored. Throws if it's stored with another
    /// hash: the ref names a file this server never released.
    public func content(_ ref: FileRef) async throws -> Data? {
        guard ref.tune == nil else { throw PersistenceError.tunedFile(ref.key) }
        let rows = try await database.client.query(
            "SELECT hash, content FROM data_files WHERE id = \(ref.id) AND version = \(ref.version)",
            logger: database.logger)
        for try await (hash, content) in rows.decode((Data, Data).self) {
            guard hash == Data(ref.hash.bytes) else { throw PersistenceError.hashMismatch(ref.key) }
            return content
        }
        return nil
    }

    /// The ref of the stored `id@version`, if any.
    public func ref(id: String, version: Int) async throws -> FileRef? {
        let rows = try await database.client.query(
            "SELECT hash FROM data_files WHERE id = \(id) AND version = \(version)", logger: database.logger)
        for try await hash in rows.decode(Data.self) {
            guard let contentHash = ContentHash(hex: hash.map { String(format: "%02x", $0) }.joined()) else { return nil }
            return FileRef(id: id, version: version, hash: contentHash)
        }
        return nil
    }

    /// The stored versions of `id`, ascending.
    public func versions(of id: String) async throws -> [Int] {
        let rows = try await database.client.query(
            "SELECT version FROM data_files WHERE id = \(id) ORDER BY version", logger: database.logger)
        var versions: [Int] = []
        for try await version in rows.decode(Int.self) { versions.append(version) }
        return versions
    }
}
