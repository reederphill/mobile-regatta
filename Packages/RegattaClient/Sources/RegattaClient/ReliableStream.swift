import RegattaProtocol

/// The server's reliable stream to this client, `Event` and `WindKey` frames numbered contiguously
/// (`MessageType.Stream.reliable`), put back in order.
///
/// A frame ahead of the next expected one waits here. If the gap it leaves isn't filled within
/// `gapTimeout`, or more than `capacity` frames wait, the stream is broken: a frame was lost, and only a
/// `Resync` (which restarts the stream at `EventState.nextEventSeq`) repairs it. Over a WebSocket that
/// never happens short of a reconnect; the fault-injecting link makes it happen.
///
/// It also remembers the last `recordLimit` frames it delivered since it last restarted. A `Resync`
/// states everything before its `nextEventSeq`; a frame at or after that one can reach the client
/// before the resync does, and the resync's state doesn't have it. The client re-applies those frames
/// from the record on top of the resync (`delivered(since:)`) rather than wait for frames the server
/// will never send again.
struct ReliableStream: Sendable {
    var gapTimeout: UInt64 = 500_000
    var capacity = 256
    var recordLimit = 256

    /// The sequence number of the next frame to deliver.
    private(set) var next: UInt32
    /// Frames past `next`, by sequence number.
    private var waiting: [Frame] = []
    /// When the current gap opened.
    private var gapSince: UInt64?
    /// The frames delivered since the last restart, oldest first, at most `recordLimit`.
    private var record: [Frame] = []

    init(next: UInt32) { self.next = next }

    /// Takes `frame`, received at `now`, and returns the frames now deliverable, in order. Duplicates
    /// and frames already delivered are dropped.
    mutating func receive(_ frame: Frame, now: UInt64) -> [Frame] {
        guard frame.seq >= next, !waiting.contains(where: { $0.seq == frame.seq }) else { return [] }
        waiting.append(frame)
        waiting.sort { $0.seq < $1.seq }
        let out = pop()
        if waiting.isEmpty {
            gapSince = nil
        } else if gapSince == nil || !out.isEmpty {
            gapSince = now
        }
        return out
    }

    /// Whether a gap has lasted past `gapTimeout` or too many frames wait.
    func isBroken(now: UInt64) -> Bool {
        waiting.count > capacity || gapSince.map { now - $0 >= gapTimeout } ?? false
    }

    /// The frames already delivered from `seq` on, when a `Resync` starting the stream at `seq` has
    /// arrived after them: nil if `seq` isn't behind the stream, or if the record no longer reaches back
    /// to it.
    func delivered(since seq: UInt32) -> [Frame]? {
        guard seq < next, let first = record.firstIndex(where: { $0.seq == seq }) else { return nil }
        return Array(record[first...])
    }

    /// Restarts the stream at `next`, after a `Resync`: the frames before it are in the resync.
    mutating func restart(at next: UInt32) {
        self.next = next
        waiting.removeAll { $0.seq < next }
        record.removeAll()
        gapSince = nil
    }

    /// Delivers what the restart made contiguous.
    mutating func drain(now: UInt64) -> [Frame] {
        let out = pop()
        gapSince = waiting.isEmpty ? nil : now
        return out
    }

    /// Takes the frames from `next` on that are waiting, in order, into the record.
    private mutating func pop() -> [Frame] {
        var out: [Frame] = []
        while let first = waiting.first, first.seq == next {
            out.append(waiting.removeFirst())
            next &+= 1
        }
        record += out
        if record.count > recordLimit { record.removeFirst(record.count - recordLimit) }
        return out
    }
}
