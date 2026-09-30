import RegattaCore
import Synchronization

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
/// finishing when there is none left (a real one stays open).
public actor ScriptedStoreService: StoreService {
    private let scenario: StoreScenario
    private var owned: Set<DesignID>
    private var pending: [Set<DesignID>]

    public init(_ scenario: StoreScenario) {
        self.scenario = scenario
        owned = scenario.owned
        pending = scenario.background
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
            pending.append(owned)
            return .purchased(product.design)
        case .askToBuy(let approved):
            if approved { pending.append(owned.union([product.design])) }
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
        let started = Mutex(false)
        return AsyncStream {
            let first = started.withLock { started in
                defer { started = true }
                return !started
            }
            return await self.next(first: first)
        }
    }

    private func next(first: Bool) -> Set<DesignID>? {
        if first { return owned }
        guard !pending.isEmpty else { return nil }
        owned = pending.removeFirst()
        return owned
    }
}
