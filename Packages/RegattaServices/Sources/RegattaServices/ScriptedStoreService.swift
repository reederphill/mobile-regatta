import RegattaCore

/// What a `ScriptedStoreService` plays.
public struct StoreScenario: Sendable {
    /// How the payment sheet goes when the player buys something not yet owned.
    public enum Checkout: Equatable, Sendable {
        case completes
        /// Ask to Buy: pending, then the guardian's answer arrives on the ownership stream if approved.
        case askToBuy(approved: Bool)
        case cancels
    }

    public var products: [StoreProduct]
    public var owned: Set<DesignID>
    public var isOnline: Bool
    public var checkout: Checkout
    /// Ownership changes that arrive with no purchase, one per read of the stream: a refund, a revocation.
    public var background: [Set<DesignID>]

    public init(
        products: [StoreProduct], owned: Set<DesignID> = [], isOnline: Bool = true, checkout: Checkout = .completes,
        background: [Set<DesignID>] = []
    ) {
        self.products = products
        self.owned = owned
        self.isOnline = isOnline
        self.checkout = checkout
        self.background = background
    }
}

/// A `StoreService` that plays its scenario. The ownership stream gives the owned set, then one change per read,
/// finishing when there is none left (a real one stays open). Each stream reads the changes with its own cursor
/// (#314).
public actor ScriptedStoreService: StoreService {
    /// One ownership change. Purchases are queued as the design they add, not a snapshot, so two that arrive
    /// before a read both land (#314).
    private enum Change: Sendable {
        /// A refund or revocation from the scenario: the whole owned set.
        case owned(Set<DesignID>)
        case adds(DesignID)
    }

    private let scenario: StoreScenario
    private var owned: Set<DesignID>
    private let script: StreamScript<Change>
    /// The owned set after each change some stream has read, for the streams reading behind it.
    private var ownedAfter: [Set<DesignID>] = []

    public init(_ scenario: StoreScenario) {
        self.scenario = scenario
        owned = scenario.owned
        script = StreamScript(scenario.background.map(Change.owned))
    }

    public func products() throws -> [StoreProduct] {
        guard scenario.isOnline else { throw StoreError.offline }
        return scenario.products
    }

    public func ownedDesigns() -> Set<DesignID> { owned }

    public func purchase(_ id: ProductID) throws -> PurchaseOutcome {
        guard scenario.isOnline else { throw StoreError.offline }
        guard let product = scenario.products.first(where: { $0.id == id }) else { throw StoreError.unknownProduct }
        if owned.contains(product.design) { return .purchased(product.design) }
        switch scenario.checkout {
        case .completes:
            owned.insert(product.design)
            script.append(.adds(product.design))
            return .purchased(product.design)
        case .askToBuy(let approved):
            if approved { script.append(.adds(product.design)) }
            return .pending
        case .cancels:
            return .cancelled
        }
    }

    public func restore() throws -> Set<DesignID> {
        guard scenario.isOnline else { throw StoreError.offline }
        return owned
    }

    public nonisolated func ownershipUpdates() -> AsyncStream<Set<DesignID>> {
        let cursor = script.cursor()
        return AsyncStream { await self.next(cursor) }
    }

    private func next(_ cursor: StreamCursor) -> Set<DesignID>? {
        let loaded = cursor.load()
        var position = loaded.position
        guard loaded.hasStarted else {
            let (start, _) = script.steps(before: position)
            cursor.store(start)
            return start.index == 0 ? scenario.owned : ownedAfter[start.index - 1]
        }
        defer { cursor.store(position) }
        guard let (index, change, isFirstRead) = script.next(&position) else { return nil }
        if isFirstRead {
            switch change {
            case .owned(let designs): owned = designs
            case .adds(let design): owned.insert(design)
            }
            ownedAfter.append(owned)
        }
        return ownedAfter[index]
    }
}
