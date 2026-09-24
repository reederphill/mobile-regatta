import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// ADR 0004: boat classes, venues, conditions and the rules configuration are immutable, versioned
// JSON data files. Every kind goes through this one loader: it reads the common header, refuses
// schema versions it doesn't know, hashes the exact bytes, and hands the rest to the kind's decoder.
// Files are loaded from `Data`, never from paths, so the server can load bytes it was sent.

/// SHA-256 of a data file's exact bytes. Client and server compare it at race start (ADR 0004).
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The 32 digest bytes.
    public let bytes: [UInt8]

    public init(of data: Data) {
        bytes = Array(SHA256.hash(data: data))
    }

    /// Parses 64 lowercase hex digits.
    public init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for k in stride(from: 0, to: 64, by: 2) {
            guard let high = Self.nibble(digits[k]), let low = Self.nibble(digits[k + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.bytes = bytes
    }

    /// 64 lowercase hex digits.
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(64)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    public var description: String { "sha256:" + hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let hash = ContentHash(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a SHA-256 hex digest: \(text)")
        }
        self = hash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}

/// Names one exact data file: what a race log records and what the server sends at race start.
public struct FileRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let id: String
    public let version: Int
    public let hash: ContentHash

    public init(id: String, version: Int, hash: ContentHash) {
        self.id = id
        self.version = version
        self.hash = hash
    }

    public var description: String { "\(id)@\(version) (\(hash))" }
}

/// The fields every data file starts with, whatever its kind.
public struct DataFileHeader: Sendable, Equatable, Decodable {
    /// The shape of the rest of the file. Each kind lists the schema versions it can decode.
    public let schemaVersion: Int
    /// Which file this is, e.g. `ilca-dinghy`. Lowercase letters, digits and hyphens.
    public let id: String
    /// The data version. A released version never changes; tuning ships the next one.
    public let version: Int
    /// JSON Pointers (RFC 6901) to values in this file that are placeholders awaiting tuning.
    /// The loader checks that each one points at something. Optional; empty when absent.
    public let placeholders: [String]

    public init(schemaVersion: Int, id: String, version: Int, placeholders: [String] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.placeholders = placeholders
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, version, placeholders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        placeholders = try c.decodeIfPresent([String].self, forKey: .placeholders) ?? []
    }
}

public enum DataFileError: Error, Equatable, CustomStringConvertible {
    /// Not JSON, or a field is missing or has the wrong type.
    case malformed(kind: String, reason: String)
    case unsupportedSchemaVersion(kind: String, found: Int, supported: [Int])
    case invalidHeader(kind: String, reason: String)
    /// The file decoded but its values break the kind's rules (e.g. a polar that isn't rectangular).
    case invalidContent(kind: String, id: String, reason: String)
    case unresolvedPlaceholder(kind: String, id: String, pointer: String)
    /// The bytes aren't the file the caller (the server, a race log) named.
    case refMismatch(expected: FileRef, found: FileRef)
    /// Two different files claim the same id and version. A released version never changes.
    case conflictingVersion(existing: FileRef, new: FileRef)
    case notBundled(kind: String, id: String, version: Int)

    public var description: String {
        switch self {
        case let .malformed(kind, reason): "malformed \(kind) file: \(reason)"
        case let .unsupportedSchemaVersion(kind, found, supported):
            "\(kind) file has schemaVersion \(found); this build reads \(supported.map(String.init).joined(separator: ", "))"
        case let .invalidHeader(kind, reason): "bad \(kind) file header: \(reason)"
        case let .invalidContent(kind, id, reason): "invalid \(kind) \(id): \(reason)"
        case let .unresolvedPlaceholder(kind, id, pointer): "\(kind) \(id): placeholder \(pointer) points at nothing"
        case let .refMismatch(expected, found): "expected \(expected), got \(found)"
        case let .conflictingVersion(existing, new): "\(new) conflicts with already loaded \(existing)"
        case let .notBundled(kind, id, version): "no bundled \(kind) \(id)@\(version)"
        }
    }
}

/// A kind of data file (boat class, and later venue, conditions, rules configuration).
public protocol DataFileContent: Sendable {
    /// Name used in errors, e.g. "boat class".
    static var kind: String { get }
    /// Folder of the bundled files, e.g. "boat-classes"; each file is named `<id>@<version>.json`.
    static var bundleDirectory: String { get }
    /// The schema versions this build decodes. Anything else throws before `init` is called.
    static var supportedSchemaVersions: [Int] { get }
    /// Decodes the body. `header.schemaVersion` is one of `supportedSchemaVersions`.
    /// Converts to code units (m/s, radians, metres) here, once.
    init(fileData: Data, header: DataFileHeader) throws
}

/// A loaded data file: its header, the ref naming its exact bytes, and its decoded content.
/// Values are independent, so any number of versions of one id can be loaded side by side.
public struct DataFile<Content: DataFileContent>: Sendable {
    public let header: DataFileHeader
    public let ref: FileRef
    public let content: Content

    public var id: String { header.id }
    public var version: Int { header.version }
    public var schemaVersion: Int { header.schemaVersion }

    /// Loads a file from its exact bytes.
    public init(data: Data) throws {
        let kind = Content.kind
        let header: DataFileHeader
        do {
            header = try JSONDecoder().decode(DataFileHeader.self, from: data)
        } catch {
            throw DataFileError.malformed(kind: kind, reason: "\(error)")
        }
        guard Content.supportedSchemaVersions.contains(header.schemaVersion) else {
            throw DataFileError.unsupportedSchemaVersion(
                kind: kind, found: header.schemaVersion, supported: Content.supportedSchemaVersions)
        }
        guard !header.id.isEmpty, header.id.utf8.allSatisfy(Self.isIDCharacter) else {
            throw DataFileError.invalidHeader(kind: kind, reason: "id \"\(header.id)\" must be lowercase letters, digits and hyphens")
        }
        guard header.version >= 1 else {
            throw DataFileError.invalidHeader(kind: kind, reason: "version \(header.version) must be at least 1")
        }
        if !header.placeholders.isEmpty {
            let document: JSONValue
            do {
                document = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw DataFileError.malformed(kind: kind, reason: "\(error)")
            }
            for pointer in header.placeholders where document.value(at: pointer) == nil {
                throw DataFileError.unresolvedPlaceholder(kind: kind, id: header.id, pointer: pointer)
            }
        }
        let content: Content
        do {
            content = try Content(fileData: data, header: header)
        } catch let error as DataFileError {
            throw error
        } catch {
            throw DataFileError.malformed(kind: kind, reason: "\(error)")
        }
        self.header = header
        self.ref = FileRef(id: header.id, version: header.version, hash: ContentHash(of: data))
        self.content = content
    }

    /// Loads a file and checks that it is exactly the one `expected` names (id, version and hash).
    public init(data: Data, expecting expected: FileRef) throws {
        try self.init(data: data)
        guard ref == expected else { throw DataFileError.refMismatch(expected: expected, found: ref) }
    }

    /// Loads `<id>@<version>.json` from this package's bundled resources.
    public static func bundled(id: String, version: Int) throws -> DataFile {
        guard let data = bundledData(id: id, version: version) else {
            throw DataFileError.notBundled(kind: Content.kind, id: id, version: version)
        }
        let file = try DataFile(data: data)
        guard file.id == id, file.version == version else {
            throw DataFileError.invalidHeader(
                kind: Content.kind, reason: "bundled \(id)@\(version).json says \(file.id)@\(file.version)")
        }
        return file
    }

    /// The exact bytes of a bundled file, or nil if this build doesn't ship it.
    public static func bundledData(id: String, version: Int) -> Data? {
        guard let url = Bundle.module.url(
            forResource: "\(id)@\(version)", withExtension: "json", subdirectory: Content.bundleDirectory
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func isIDCharacter(_ c: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
            || c == UInt8(ascii: "-")
    }
}

/// Every loaded version of one kind of file, looked up by ref or by id and version.
/// Holds an array, in load order, so nothing depends on hash order (ADR 0002).
public struct DataFileCatalog<Content: DataFileContent>: Sendable {
    public private(set) var files: [DataFile<Content>] = []

    public init() {}

    /// Adds a file. Adding the same bytes again does nothing; a different file with the same id and
    /// version throws, because a released version never changes (ADR 0004).
    @discardableResult
    public mutating func add(_ file: DataFile<Content>) throws -> FileRef {
        if let existing = self.file(id: file.id, version: file.version) {
            guard existing.ref == file.ref else {
                throw DataFileError.conflictingVersion(existing: existing.ref, new: file.ref)
            }
            return existing.ref
        }
        files.append(file)
        return file.ref
    }

    /// The file with exactly this id, version and hash.
    public func file(_ ref: FileRef) -> DataFile<Content>? {
        files.first { $0.ref == ref }
    }

    public func file(id: String, version: Int) -> DataFile<Content>? {
        files.first { $0.id == id && $0.version == version }
    }

    /// Loaded versions of `id`, ascending.
    public func versions(of id: String) -> [Int] {
        files.filter { $0.id == id }.map(\.version).sorted()
    }
}

/// Just enough of a JSON document to resolve a placeholder's JSON Pointer.
private indirect enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case scalar

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let members = try? container.decode([String: JSONValue].self) {
            self = .object(members)
        } else if let elements = try? container.decode([JSONValue].self) {
            self = .array(elements)
        } else {
            self = .scalar
        }
    }

    /// RFC 6901: "" is the whole document; "/a/0" is member "a", then element 0; "~1" is "/", "~0" is "~".
    func value(at pointer: String) -> JSONValue? {
        guard !pointer.isEmpty else { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var node = self
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch node {
            case .object(let members):
                guard let next = members[token] else { return nil }
                node = next
            case .array(let elements):
                guard !token.isEmpty, token.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                      token == "0" || !token.hasPrefix("0"),
                      let index = Int(token), index < elements.count
                else { return nil }
                node = elements[index]
            case .scalar:
                return nil
            }
        }
        return node
    }
}
