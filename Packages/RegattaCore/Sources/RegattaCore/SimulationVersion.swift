#if canImport(Glibc)
import Glibc
#endif

// ADR 0002: a race log is replayed by the simulation version that produced it, and the server's
// Swift toolchain and C library are part of that version. Trig comes from the platform libm
// (glibc on the server), so libm is pinned with the C library rather than replaced by our own.

/// Bumped by hand whenever simulation output changes: physics, rules, wind, tick rate, or
/// anything else a golden digest would see. Add the new row to `Tests/Goldens.json` with it.
public let simulationRevision = 1

/// The race server's platform: the pinned image in `scripts/linux-test.sh`
/// (`swift:6.3.3-noble`, `linux/amd64`, glibc 2.39). Only results on this platform are
/// authoritative; clients just have to be close enough for prediction.
public let replayPlatform = "swift-6.3.3/glibc-2.39/x86_64"

/// The toolchain, C library and architecture this build runs on.
public let simulationPlatform = "\(toolchainID)/\(libcID)/\(architectureID)"

/// Tags every race log. A replay needs a build whose version matches exactly.
public let simulationVersion = "\(simulationRevision)/\(simulationPlatform)"

/// Whether this build's results are the authoritative ones that golden digests pin.
public var isReplayPlatform: Bool { simulationPlatform == replayPlatform }

private let toolchainID: String = {
    #if compiler(>=6.3.3) && compiler(<6.3.4)
    return "swift-6.3.3"
    #else
    return "swift-unpinned"
    #endif
}()

private let libcID: String = {
    #if canImport(Glibc)
    var buffer = [CChar](repeating: 0, count: 64)
    let length = confstr(Int32(truncatingIfNeeded: _CS_GNU_LIBC_VERSION), &buffer, buffer.count)
    guard length > 0, length <= buffer.count else { return "glibc-unknown" }
    let name = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return String(name.map { $0 == " " ? "-" : $0 }) // "glibc 2.39" → "glibc-2.39"
    #elseif canImport(Darwin)
    return "darwin"
    #else
    return "libc-unknown"
    #endif
}()

private let architectureID: String = {
    #if arch(x86_64)
    return "x86_64"
    #elseif arch(arm64)
    return "arm64"
    #else
    return "arch-unknown"
    #endif
}()
