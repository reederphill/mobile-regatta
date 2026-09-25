#if canImport(Glibc)
import Glibc
#endif

// ADR 0002: a race log is replayed by the simulation version that produced it, and the server's
// Swift toolchain and C library are part of that version. Trig comes from the platform libm
// (glibc on the server), so libm is pinned with the C library rather than replaced by our own.

/// Bumped by hand whenever simulation output changes: physics, rules, wind, tick rate, or
/// anything else a golden digest would see. Add the new row to `Tests/Goldens.json` with it.
/// The golden replays a fixed input log with no bot brains (ADR 0002), so retuning bots never moves it.
///
/// 2: the wind is keyed by its own seed, not the race seed; held inputs are int8 (#59).
/// 3: keyed wind (#75). The wind is a `WindField` of the public `WindSetup` (classic-oscillating@2, stub
///    pairing; the course laid square to its mean direction) and the key chain `WindKeyGenerator` makes
///    from the wind seed by HMAC-SHA256. Window origin: `WindWindows(startSequenceTicks:)`, 900 ·
///    (⌈startSequenceTicks / 900⌉ + 1) ticks before the gun, so knots fall on whole windows from the gun
///    and the race starts in window 1. First knot: `WindField.firstKnot` (no shift, base strength, level)
///    at the origin, never sampled by a race. No puffs until #76.
/// 4: boats carry no names (bot names moved to the roster outside the sim), so the digest no longer
///    hashes them; bot brains left `Race` for RegattaBots' seat controllers (#60).
/// 5: boats sail their class file (#70): `BoatDynamics` with the class's momentum, steering, rudder
///    drag and slew, head-to-wind fall-off and ease; the polar table, hull outline, shadow cone and
///    contact factors of ilca-dinghy@1.
/// 6: the boom (#71). Each boat has a boom side and her tack follows it; the boom crosses at head to wind
///    or past the class's by-the-lee limit, and by the lee she sails the mirrored polar less the class's
///    penalty. The tap steers to the same wind angle with the boom on the other side. Tacked and gybed
///    events. Boats sail ilca-dinghy@2 (turn rate curve, rudder drag and no-go time constant retuned).
public let simulationRevision = 6

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
