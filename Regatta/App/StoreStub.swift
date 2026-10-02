import Foundation
import RegattaCore
import RegattaServices

/// The shop until StoreKit (#137 replaces this): sells every paid design of the boat class at its tier's price and keeps
/// what you own on the device. A purchase completes, for free, only in a Debug build (`completesPurchases`); a Release
/// build shows the prices and a disabled Buy.
///
/// Not the services' `ScriptedStoreService`: that sells one design and its ownership stream ends; this one's stays open.
actor StubStoreService: StoreService {
    /// Whether a purchase completes: Debug builds only, until #137.
    nonisolated static var completesPurchases: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static let ownedKey = "ownedDesigns"

    /// Each tier's price, as the App Store would format it in a US storefront (#21).
    nonisolated static func displayPrice(tier: Int) -> String {
        switch tier {
        case 1: "$0.99"
        case 2: "$1.99"
        default: "$2.99"
        }
    }

    /// Every paid design of `boatClass` as a product, at its tier's price.
    nonisolated static func products(boatClass: String, catalogue: LiveryCatalogue = .bundled) -> [StoreProduct] {
        catalogue.designs(for: boatClass).compactMap { design in
            guard case .paid(let product, let tier) = design.acquisition, let priceTier = PriceTier(rawValue: tier) else {
                return nil
            }
            return StoreProduct(id: ProductID(product), design: design.id, boatClass: boatClass, tier: priceTier,
                                displayPrice: displayPrice(tier: tier))
        }
    }

    private let suiteName: String?
    private let isOnline: Bool
    private let catalogue: [StoreProduct]
    private var owned: Set<DesignID>
    private var watchers: [UUID: AsyncStream<Set<DesignID>>.Continuation] = [:]

    /// `suiteName` names the defaults that keep what you own (nil: the app's own). `isOnline` false fails every
    /// purchase as offline (`-fakeServices offline`).
    init(boatClass: String, suiteName: String?, isOnline: Bool = true) {
        self.suiteName = suiteName
        self.isOnline = isOnline
        catalogue = Self.products(boatClass: boatClass)
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        owned = Set((defaults.stringArray(forKey: Self.ownedKey) ?? []).map(DesignID.init))
    }

    func products() throws -> [StoreProduct] {
        guard isOnline else { throw StoreError.offline }
        return catalogue
    }

    func ownedDesigns() -> Set<DesignID> { owned }

    func purchase(_ id: ProductID) throws -> PurchaseOutcome {
        guard isOnline else { throw StoreError.offline }
        guard let product = catalogue.first(where: { $0.id == id }) else { throw StoreError.unknownProduct }
        if owned.contains(product.design) { return .purchased(product.design) }
        guard Self.completesPurchases else { return .cancelled }
        owned.insert(product.design)
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        defaults.set(owned.map(\.rawValue).sorted(), forKey: Self.ownedKey)
        for watcher in watchers.values { watcher.yield(owned) }
        return .purchased(product.design)
    }

    func restore() throws -> Set<DesignID> {
        guard isOnline else { throw StoreError.offline }
        return owned
    }

    nonisolated func ownershipUpdates() -> AsyncStream<Set<DesignID>> {
        let (stream, continuation) = AsyncStream<Set<DesignID>>.makeStream()
        let id = UUID()
        Task { await self.watch(id, continuation) }
        continuation.onTermination = { _ in Task { await self.unwatch(id) } }
        return stream
    }

    private func watch(_ id: UUID, _ continuation: AsyncStream<Set<DesignID>>.Continuation) {
        watchers[id] = continuation
        continuation.yield(owned)
    }

    private func unwatch(_ id: UUID) {
        watchers[id] = nil
    }
}
