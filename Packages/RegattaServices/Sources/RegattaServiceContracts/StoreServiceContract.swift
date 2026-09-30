import RegattaCore
import RegattaServices

/// What `StoreService` promises (#21, #25).
public struct StoreServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// Online, owning no paid design; buying completes.
        case nothingOwned
        /// Online; buying goes to Ask to Buy, and the guardian approves.
        case askToBuyApproved
        /// Online; the player cancels the payment sheet.
        case cancels
        /// Online, owning at least one design; a refund then revokes one.
        case refunded
        /// Offline, owning at least one design.
        case offline
    }

    public let name = "StoreService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any StoreService) async throws {
        try await buying(makeService(.nothingOwned))
        try await askToBuy(makeService(.askToBuyApproved))

        let cancels = try await makeService(.cancels)
        guard let product = try await cancels.products().first else { try fail("nothing on sale") }
        let before = await cancels.ownedDesigns()
        try await require(try await cancels.purchase(product.id) == .cancelled, "a cancelled payment sheet didn't come back as .cancelled")
        try await require(await cancels.ownedDesigns() == before, "a cancelled purchase changed what's owned")

        let refunded = try await makeService(.refunded)
        var updates = StreamReader(refunded.ownershipUpdates())
        guard let owned = await updates.next(), !owned.isEmpty else { try fail("the ownership stream doesn't open with what's owned") }
        try await require(owned == (await refunded.ownedDesigns()), "the ownership stream opens with \(owned), not what's owned")
        let (changes, lost) = await updates.read { !$0.isSuperset(of: owned) }
        try await require(lost, "the refund never arrived; it read \(changes)")
        try await require(await refunded.ownedDesigns() == changes.last, "ownedDesigns() doesn't show the refund")

        let offline = try await makeService(.offline)
        try await requireThrows(StoreError.offline, "products() offline") { try await offline.products() }
        try await requireThrows(StoreError.offline, "restore() offline") { try await offline.restore() }
        try await requireThrows(StoreError.offline, "purchase() offline") { try await offline.purchase(ProductID("contract-product")) }
        try await require(await !offline.ownedDesigns().isEmpty, "owned designs don't show offline")
    }

    /// The catalogue, a purchase, buying again, an unknown product, and restoring.
    private func buying(_ service: any StoreService) async throws {
        let products = try await service.products()
        try await require(!products.isEmpty, "nothing on sale")
        try await require(Set(products.map(\.id)).count == products.count, "a product is listed twice")
        try await require(products.allSatisfy { !$0.displayPrice.isEmpty }, "a product has no price")
        try await require(await service.ownedDesigns().isEmpty, "a player who bought nothing owns designs")

        let product = products[0]
        try await require(try await service.purchase(product.id) == .purchased(product.design), "buying \(product.id) didn't purchase it")
        try await require(await service.ownedDesigns() == [product.design], "the purchase isn't owned")
        try await require(try await service.purchase(product.id) == .purchased(product.design), "buying an owned design again didn't say it's owned")
        try await require(await service.ownedDesigns() == [product.design], "buying again changed what's owned")
        try await requireThrows(StoreError.unknownProduct, "buying an unknown product") { try await service.purchase(ProductID("contract-no-such-product")) }
        try await require(try await service.restore() == [product.design], "restore() lost the purchase")
    }

    /// Pending, owning nothing new, until the approval arrives on the stream.
    private func askToBuy(_ service: any StoreService) async throws {
        guard let product = try await service.products().first(where: { _ in true }) else { try fail("nothing on sale") }
        var updates = StreamReader(service.ownershipUpdates())
        let before = await updates.next() ?? []
        try await require(!before.contains(product.design), "the design to buy is already owned")
        try await require(try await service.purchase(product.id) == .pending, "Ask to Buy didn't come back as .pending")
        try await require(await !service.ownedDesigns().contains(product.design), "a pending purchase is owned already")
        let (changes, approved) = await updates.read { $0.contains(product.design) }
        try await require(approved, "the approval never arrived; it read \(changes)")
    }
}
