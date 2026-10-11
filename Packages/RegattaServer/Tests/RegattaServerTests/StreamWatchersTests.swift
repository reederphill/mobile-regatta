import Foundation
@testable import RegattaServerKit
import Testing

/// #469: the services' stream tables. A stream is registered before it is handed out and removed the moment it ends,
/// so a stream dropped at once never leaves a watcher behind; a watcher hears changes only after its first words.
@Suite(.timeLimit(.minutes(1))) struct StreamWatchersTests {
    @Test func aStreamIsRegisteredAtOnceAndRemovedTheMomentItEnds() {
        let watchers = StreamWatchers<Int>()
        let closed = Kept<String>()
        var token = UUID()
        do {
            let opened = watchers.open("a", bufferingPolicy: .bufferingNewest(1)) { closed.append("a") }
            token = opened.token
            #expect(watchers.isWatched("a"))
            #expect(!watchers.hasPrimed("a"))
            withExtendedLifetime(opened.stream) {}
        }
        // Dropped: gone before anything else runs, and its owner hears it once.
        #expect(!watchers.isWatched("a"))
        #expect(watchers.keys.isEmpty)
        #expect(closed.all == ["a"])
        // First words for a stream that has gone are refused, so its owner can keep them.
        #expect(!watchers.prime("a", token, [1]))
        #expect(watchers.send(2, to: "a") == 0)
    }

    @Test func aWatcherHearsChangesOnlyAfterItsFirstWords() async {
        let watchers = StreamWatchers<Int>()
        let (stream, token) = watchers.open("a", bufferingPolicy: .unbounded)
        // A change before its first words passes it by.
        #expect(watchers.send(7, to: "a") == 0)
        #expect(watchers.prime("a", token, [1, 2]))
        #expect(watchers.send(3, to: "a") == 1)
        // Unchanged since the last it was sent: not sent again.
        watchers.sendIfChanged(3, to: "a")
        watchers.sendIfChanged(4, to: "a")
        watchers.send(5, to: "a", token)
        watchers.finish("a", last: 6)
        #expect(!watchers.isWatched("a"))
        var read: [Int] = []
        for await element in stream { read.append(element) }
        #expect(read == [1, 2, 3, 4, 5, 6])
    }

    @Test func finishEndsEveryStreamOfAKeyPrimedOrNot() async {
        let watchers = StreamWatchers<Int>()
        let primed = watchers.open("a", bufferingPolicy: .unbounded), unprimed = watchers.open("a", bufferingPolicy: .unbounded)
        let other = watchers.open("b", bufferingPolicy: .unbounded)
        watchers.prime("a", primed.token)
        watchers.finish("a", last: 9)
        for stream in [primed.stream, unprimed.stream] {
            var read: [Int] = []
            for await element in stream { read.append(element) }
            #expect(read == [9])
        }
        #expect(watchers.keys == ["b"])
        watchers.finish("b", other.token)
        watchers.finishAll()
        var read: [Int] = []
        for await element in other.stream { read.append(element) }
        #expect(read.isEmpty)
    }
}
