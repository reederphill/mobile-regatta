import RegattaServices

/// A `-fakeServices` queue at a pace a person can watch (#140). A scripted queue gives its states as fast as they are
/// read and ends its stream at the end of its script; this gives one state every `interval` and keeps the stream
/// open, as a real one is, reading on when a join or a leave starts the next script. The pace is the app's: the
/// services package keeps no clock.
nonisolated final class PacedQueueService: QueueService {
    private let base: any QueueService
    private let interval: Duration
    private let scripts = Scripts()

    init(_ base: any QueueService, interval: Duration) {
        self.base = base
        self.interval = interval
    }

    func stateUpdates() -> AsyncStream<QueueState> {
        let (stream, continuation) = AsyncStream.makeStream(of: QueueState.self)
        let task = Task { [base, interval, scripts] in
            var last: QueueState?
            while !Task.isCancelled {
                let script = await scripts.count
                for await state in base.stateUpdates() where state != last {
                    if last != nil { try? await Task.sleep(for: interval) }
                    // A join or a leave meanwhile started another script: this state is the old one's.
                    if await scripts.count != script || Task.isCancelled { break }
                    last = state
                    continuation.yield(state)
                }
                await scripts.wait(after: script)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func join() async throws {
        try await base.join()
        await scripts.next()
    }

    func leave() async throws {
        try await base.leave()
        await scripts.next()
    }

    /// Counts the scripts a join or a leave has started, and wakes the streams waiting for the next.
    private actor Scripts {
        private(set) var count = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func next() {
            count += 1
            let woken = waiting
            waiting = []
            for continuation in woken { continuation.resume() }
        }

        func wait(after seen: Int) async {
            guard count == seen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}
