/// Names one version of an immutable data file (ADR 0004): a boat class, venue, conditions or
/// rules configuration. `hash` is the content hash of the file's exact bytes. The loader that
/// resolves a reference is #58; `RaceSetup` only carries the references until #81 resolves them.
public struct FileRef: Codable, Hashable, Sendable {
    public var id: String
    public var version: Int
    public var hash: String

    public init(id: String, version: Int, hash: String) {
        self.id = id
        self.version = version
        self.hash = hash
    }
}
