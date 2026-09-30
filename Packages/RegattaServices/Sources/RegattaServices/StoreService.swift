import RegattaCore

// Paid livery designs (#21, #25): StoreKit 2 on the device proves ownership, Family Sharing is on, there's no
// gifting and no subscription in v1.0. A paid design is bought per boat class. Ownership is cached on the device,
// so My boat and offline practice races show owned designs with no network.

/// An App Store product id.
public struct ProductID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// The three prices, set by how much a design shows (#21).
public enum PriceTier: Int, CaseIterable, Sendable {
    /// $0.99.
    case tier1 = 1
    /// $1.99.
    case tier2 = 2
    /// $2.99.
    case tier3 = 3
}

/// A paid design on sale.
public struct StoreProduct: Equatable, Sendable {
    public var id: ProductID
    public var design: DesignID
    public var boatClass: String
    public var tier: PriceTier
    /// The price in the player's storefront, as the App Store formats it ("Buy $1.99").
    public var displayPrice: String

    public init(id: ProductID, design: DesignID, boatClass: String, tier: PriceTier, displayPrice: String) {
        self.id = id
        self.design = design
        self.boatClass = boatClass
        self.tier = tier
        self.displayPrice = displayPrice
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    /// Bought, or already owned: the design is the player's.
    case purchased(DesignID)
    /// Waiting on Ask to Buy: the design arrives on `ownershipUpdates()` if approved.
    case pending
    /// The player cancelled the payment sheet.
    case cancelled
}

public enum StoreError: Error, Equatable, Sendable {
    case unknownProduct
    /// The App Store can't be reached. Owned designs still come from the device's cache.
    case offline
}

public protocol StoreService: Sendable {
    /// The paid designs on sale. Throws `StoreError.offline` with no connection.
    func products() async throws -> [StoreProduct]
    /// The paid designs the player owns, from the device's cache: works offline.
    func ownedDesigns() async -> Set<DesignID>
    /// Buys a product. Buying one already owned returns `.purchased` and charges nothing.
    func purchase(_ product: ProductID) async throws -> PurchaseOutcome
    /// Restores purchases from the Apple ID (Settings → Restore purchases) and returns what's owned.
    func restore() async throws -> Set<DesignID>
    /// The owned designs now, then each change: a pending purchase approved, a refund or revocation, a family
    /// member's purchase shared.
    func ownershipUpdates() -> AsyncStream<Set<DesignID>>
}
