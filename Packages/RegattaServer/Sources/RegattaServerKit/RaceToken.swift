import Crypto
import Foundation

/// A race handed to one client (#67): which race, which seat, until when, signed by the server so a client
/// can't forge or alter one. The client carries it opaquely, in `JoinRace` (#18). For now the server that
/// signs it is the server that races it; the race session service (#143) will sign them later.
///
/// Wire layout, 58 bytes: `version` uint8 (1) | race id, 16 bytes | seat uint8 | expiry, Unix seconds,
/// int64 little-endian | HMAC-SHA256 of the 26 bytes before it, 32 bytes.
public struct RaceToken: Hashable, Sendable {
    public var raceID: UUID
    public var seat: Int
    /// Unix time, in seconds, after which the token no longer joins.
    public var expiresAt: Int64

    public static let version: UInt8 = 1
    static let bodySize = 26
    public static let size = bodySize + 32

    public init(raceID: UUID, seat: Int, expiresAt: Int64) {
        self.raceID = raceID
        self.seat = seat
        self.expiresAt = expiresAt
    }

    /// The token's bytes, signed with `key`, or nil if the seat doesn't fit the token's one byte (0…255).
    public func signed(with key: SymmetricKey) -> [UInt8]? {
        guard let seat = UInt8(exactly: seat) else { return nil }
        var body: [UInt8] = [Self.version]
        withUnsafeBytes(of: raceID.uuid) { body += $0 }
        body.append(seat)
        withUnsafeBytes(of: expiresAt.littleEndian) { body += $0 }
        return body + Array(HMAC<SHA256>.authenticationCode(for: body, using: key))
    }

    /// The token `bytes` carry, if `key` signed them and they haven't expired at `now` (Unix seconds).
    public static func verify(_ bytes: [UInt8], key: SymmetricKey, now: Int64) throws(RaceTokenError) -> RaceToken {
        guard bytes.count == size, bytes[0] == version else { throw .malformed }
        let body = bytes[0..<bodySize]
        let mac = bytes[bodySize...]
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(mac), authenticating: Data(body), using: key) else {
            throw .badSignature
        }
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes[1..<17]) }
        var expiry: Int64 = 0
        withUnsafeMutableBytes(of: &expiry) { $0.copyBytes(from: bytes[18..<26]) }
        let token = RaceToken(raceID: UUID(uuid: uuid), seat: Int(bytes[17]), expiresAt: Int64(littleEndian: expiry))
        guard now <= token.expiresAt else { throw .expired }
        return token
    }
}

public enum RaceTokenError: Error, Equatable, Sendable {
    case malformed
    case badSignature
    case expired
}
