/// A contract suite: the behaviour of one service protocol, written against the protocol alone, so any
/// implementation can be held to it: the scripted fake, #143's remote runner over a real server, the real
/// services. A suite reaches an implementation only through `makeService`, which puts a fresh service in the
/// asked-for situation: the fake from a scenario, the remote runner by arranging a test account. The
/// situations a suite asks for are its `Situation` cases, each documented on the suite.
public protocol ContractSuite: Sendable {
    /// The states a service is put in to check a behaviour.
    associatedtype Situation: Hashable, Sendable
    associatedtype Service: Sendable

    var name: String { get }

    /// Runs every check. Throws `ContractViolation` on the first that fails, and whatever `makeService` throws.
    func run(_ makeService: (Situation) async throws -> Service) async throws
}

/// A check the implementation failed.
public struct ContractViolation: Error, CustomStringConvertible, Sendable {
    public let suite: String
    public let message: String
    public let location: String

    public var description: String { "\(suite): \(message) (\(location))" }
}

extension ContractSuite {
    /// Fails the suite with `message` unless `condition` holds.
    func require(
        _ condition: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String,
        fileID: String = #fileID, line: Int = #line
    ) async throws {
        guard try await condition() else { throw ContractViolation(suite: name, message: message(), location: "\(fileID):\(line)") }
    }

    /// Fails the suite with `message`.
    func fail(_ message: String, fileID: String = #fileID, line: Int = #line) throws -> Never {
        throw ContractViolation(suite: name, message: message, location: "\(fileID):\(line)")
    }

    /// Runs `body`, which must throw an error equal to `expected`.
    func requireThrows<Failure: Error & Equatable, Result>(
        _ expected: Failure, _ what: String, fileID: String = #fileID, line: Int = #line,
        _ body: () async throws -> Result
    ) async throws {
        do {
            _ = try await body()
        } catch let error as Failure where error == expected {
            return
        } catch {
            throw ContractViolation(suite: name, message: "\(what) threw \(error), not \(expected)", location: "\(fileID):\(line)")
        }
        throw ContractViolation(suite: name, message: "\(what) didn't throw \(expected)", location: "\(fileID):\(line)")
    }
}

/// Reads a stream a piece at a time, so a suite can act between reads (join, then read what the queue says).
struct StreamReader<Element: Sendable> {
    private var iterator: AsyncStream<Element>.Iterator

    init(_ stream: AsyncStream<Element>) { iterator = stream.makeAsyncIterator() }

    /// The next element, or nil once the stream has ended.
    mutating func next() async -> Element? { await iterator.next() }

    /// The elements up to and including the first that satisfies `isLast`, and whether one did: false means
    /// the stream ended first. A stream that neither ends nor matches never returns; a runner puts a timeout
    /// around the test, since suites read no clock.
    mutating func read(through isLast: (Element) -> Bool) async -> (items: [Element], matched: Bool) {
        var items: [Element] = []
        while let item = await next() {
            items.append(item)
            if isLast(item) { return (items, true) }
        }
        return (items, false)
    }

    /// `read(through:)` on a stream nothing else reads.
    static func read(_ stream: AsyncStream<Element>, through isLast: (Element) -> Bool) async -> (items: [Element], matched: Bool) {
        var reader = StreamReader(stream)
        return await reader.read(through: isLast)
    }

    /// The first element of a stream nothing else reads.
    static func first(of stream: AsyncStream<Element>) async -> Element? {
        var reader = StreamReader(stream)
        return await reader.next()
    }
}
