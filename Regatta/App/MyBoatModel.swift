import Foundation
import Observation
import RegattaCore
import RegattaServices

/// My boat (#136, #21): the livery editor and shop on one page. You pick a design, fill its slots from the safe palette
/// and set a sail number; any design can be tried on in your colours, but only one you own can be saved. The draft
/// lives here until Save; leaving the page discards it (`discardDraft`).
///
/// Long-lived (`AppModel.myBoat`), so a purchase started on the page finishes after it's gone (#25).
@Observable
final class MyBoatModel {
    /// The page's one button, and why.
    enum Action: Equatable {
        /// An owned design, a valid number, and something changed.
        case save
        /// Nothing to save.
        case saved
        /// A paid design you don't own: buy it at this price.
        case buy(price: String)
        /// A paid design you don't own, in a build that can't buy yet (Release until #137).
        case soon(price: String)
        /// An earned design: `completed` of `needed` online races so far.
        case locked(completed: Int, needed: Int)
        /// After fleet lock (#25): nothing changes until the race is over.
        case fleetLocked
        /// The sail number isn't 1 to 9999.
        case invalidNumber

        /// The button's words. TODO-COPY (#171)
        var title: String {
            switch self {
            case .save: "Save"
            case .saved: "Saved"
            case .buy(let price): "Buy \(price)"
            case .soon: "Soon"
            case .locked(let completed, let needed): "\(completed) / \(needed) races"
            case .fleetLocked: "Locked for this race"
            case .invalidNumber: "Save"
            }
        }

        var isEnabled: Bool {
            switch self {
            case .save, .buy: true
            case .saved, .soon, .locked, .fleetLocked, .invalidNumber: false
            }
        }
    }

    /// The page's parts, one shown at a time under the pinned render (owner review of #382). A catalogue design bundles
    /// a deck pattern and a sail graphic, so Decal picks the design and Sail shows its graphic with the sail colour
    /// (#169 may split them). TODO-COPY (#171)
    enum Section: String, CaseIterable, Codable {
        case decal, colours, sail, number

        var title: String {
            switch self {
            case .decal: "Decal"
            case .colours: "Colours"
            case .sail: "Sail"
            case .number: "Number"
            }
        }
    }

    /// The small symbol on a design you can't race in yet.
    enum Mark: Equatable {
        /// Paid, not owned.
        case price
        /// Earned, not enough races.
        case lock
    }

    let catalogue: LiveryCatalogue
    /// The boat class every design comes from: v1.0's one (CONTEXT: skiff).
    let boatClass: String
    /// Whether Buy completes a purchase (`StubStoreService.completesPurchases`); else it reads Soon.
    let canBuy: Bool
    /// Whether a design has art to show (`hasArt`); one without draws as a plain duplicate, so it isn't listed.
    let isDrawn: @MainActor (LiveryDesign) -> Bool

    /// The part shown under the render.
    var section: Section = .decal

    /// Your livery as saved.
    private(set) var saved: Livery
    /// The draft's design.
    private(set) var design: DesignID
    /// The draft's colours by slot. Every slot keeps a colour, so a 2-slot design keeps the accent for the next 3-slot one.
    private(set) var colours: [LiverySlot: SwatchID]
    /// The sail number as typed: kept as is, so a bad one shows and can be fixed.
    var numberText: String {
        get { typedNumber }
        set { if !isFleetLocked { typedNumber = newValue } }
    }
    private var typedNumber: String
    /// Paid designs you own.
    private(set) var owned: Set<DesignID>
    /// Online races completed, for earned designs.
    var completedRaces: Int
    /// After fleet lock: every control inert (`AppModel.isLiveryLocked`).
    var isFleetLocked = false
    /// A purchase in progress.
    private(set) var isBuying = false
    /// A purchase's outcome worth a line: waiting for approval, offline.
    private(set) var purchaseNote: String?
    /// Saves your livery: `AppModel.myLivery`.
    @ObservationIgnored var onSave: (Livery) -> Void = { _ in }

    @ObservationIgnored private let store: (any StoreService)?
    @ObservationIgnored private var purchaseTask: Task<Void, Never>?
    @ObservationIgnored private var ownershipTask: Task<Void, Never>?

    init(saved: Livery, owned: Set<DesignID> = [], completedRaces: Int = 0, store: (any StoreService)? = nil,
         canBuy: Bool = StubStoreService.completesPurchases, catalogue: LiveryCatalogue = .bundled,
         boatClass: String = RaceFiles.defaults.boatClass.ref.id,
         isDrawn: @escaping @MainActor (LiveryDesign) -> Bool = MyBoatModel.hasArt) {
        self.catalogue = catalogue
        self.isDrawn = isDrawn
        self.boatClass = boatClass
        self.canBuy = canBuy
        self.saved = saved
        self.owned = owned
        self.completedRaces = completedRaces
        self.store = store
        design = saved.design
        typedNumber = String(saved.sailNumber)
        colours = Self.colours(of: saved, catalogue: catalogue)
        if let store {
            ownershipTask = Task { [weak self] in
                for await owned in store.ownershipUpdates() {
                    guard let self else { return }
                    self.owned = owned
                }
            }
        }
    }

    // MARK: - The catalogue

    /// The designs on the page: the class's, in catalogue order.
    var designs: [LiveryDesign] { catalogue.designs(for: boatClass) }

    /// The swatches that may fill `slot`, in palette order (off-white is sail only).
    func swatches(for slot: LiverySlot) -> [LiverySwatch] {
        catalogue.swatches.filter { $0.slots.contains(slot) }
    }

    var selectedDesign: LiveryDesign? { catalogue.design(design) }

    /// Whether you may race in `design`: free, earned with enough races, or paid and owned.
    func owns(_ design: LiveryDesign) -> Bool {
        switch design.acquisition {
        case .free: true
        case .earned(let needed): completedRaces >= needed
        case .paid: owned.contains(design.id)
        }
    }

    /// The designs listed under Decal: one plain list, owned first, then earned, then paid, in catalogue order within
    /// each (owner review of #382). A design with no art yet is left out (#169 draws them) unless it's the one tried
    /// on, so Try it still shows what it opened.
    var listedDesigns: [LiveryDesign] {
        let shown = designs.filter { isDrawn($0) || $0.id == design }
        return shown.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private func rank(_ design: LiveryDesign) -> Int {
        switch mark(for: design) {
        case nil: 0
        case .lock: 1
        case .price: 2
        }
    }

    /// Whether `design` draws as itself (`LiveryArt`): its pattern or its sail graphic has art, or it's meant to be
    /// plain. A name with no art yet draws plain, so such a design would look like the plain one.
    static func hasArt(_ design: LiveryDesign) -> Bool {
        let pattern = LiveryArt.Pattern(named: design.pattern), graphic = LiveryArt.SailGraphic(named: design.sailGraphic)
        if pattern != .plain || graphic != .plain { return true }
        return design.pattern == LiveryArt.Pattern.plain.rawValue && design.sailGraphic == LiveryArt.SailGraphic.plain.rawValue
    }

    /// The symbol on a design you can't race in yet: a price tag unowned, a lock earned and short of races.
    func mark(for design: LiveryDesign) -> Mark? {
        guard !owns(design) else { return nil }
        switch design.acquisition {
        case .free: return nil
        case .earned: return .lock
        case .paid: return .price
        }
    }

    /// A paid design's price if you don't own it.
    func price(of design: LiveryDesign) -> String? {
        guard case .paid(_, let tier) = design.acquisition, !owns(design) else { return nil }
        return StubStoreService.displayPrice(tier: tier)
    }

    /// What shows under a design's thumbnail: "n / N races" for an earned design short of races, only while it's
    /// selected; else nothing. TODO-COPY (#171)
    func caption(for design: LiveryDesign) -> String? {
        guard design.id == self.design, case .earned(let needed) = design.acquisition, !owns(design) else { return nil }
        return "\(min(completedRaces, needed)) / \(needed) races"
    }

    /// A placeholder name until #169/#171 name the designs: the pattern, in words.
    static func name(of design: LiveryDesign) -> String { words(design.pattern) }

    /// A sail graphic's name in words (Sail shows the design's graphic). TODO-COPY (#171)
    static func name(ofGraphic graphic: String) -> String { words(graphic) }

    /// A swatch's name in words, for VoiceOver.
    static func name(of swatch: SwatchID) -> String { words(swatch.rawValue) }

    /// A catalogue name in words: "sheer-line" reads "Sheer line".
    private static func words(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - The draft

    /// The sail number typed, if it's one you may pick (1 to 9999, digits only).
    var sailNumber: Int? { Livery.sailNumber(parsing: numberText) }

    /// The draft as a livery: the typed number if valid, else the saved one, so the render never shows a bad one.
    var draft: Livery {
        let slots = selectedDesign?.slots ?? []
        return Livery(design: design, colours: slots.map { colours[$0] ?? SwatchID("pale-grey") },
                      sailNumber: sailNumber ?? saved.sailNumber)
    }

    /// `draft` on `other`: the design thumbnails show every design in your colours.
    func draft(on other: LiveryDesign, sailNumber: Int) -> Livery {
        Livery(design: other.id, colours: other.slots.map { colours[$0] ?? SwatchID("pale-grey") }, sailNumber: sailNumber)
    }

    var action: Action {
        if isFleetLocked { return .fleetLocked }
        guard let design = selectedDesign else { return .saved }
        switch design.acquisition {
        case .free: break
        case .earned(let needed):
            if completedRaces < needed { return .locked(completed: completedRaces, needed: needed) }
        case .paid(_, let tier):
            if !owned.contains(design.id) {
                let price = StubStoreService.displayPrice(tier: tier)
                return canBuy ? .buy(price: price) : .soon(price: price)
            }
        }
        guard sailNumber != nil else { return .invalidNumber }
        return draft == saved ? .saved : .save
    }

    /// Tries `id` on in your colours. #128: try-on emitter
    func select(_ id: DesignID) {
        guard !isFleetLocked, catalogue.design(id)?.boatClass == boatClass else { return }
        design = id
        purchaseNote = nil
    }

    /// Fills `slot` with `swatch`, if the palette lets it.
    func setColour(_ swatch: SwatchID, for slot: LiverySlot) {
        guard !isFleetLocked, catalogue.swatch(swatch)?.slots.contains(slot) == true else { return }
        colours[slot] = swatch
    }

    /// Saves the draft as your livery. Never an unowned or locked design, a bad number, or after fleet lock.
    func save() {
        guard action == .save else { return }
        let livery = draft
        guard (try? catalogue.validate(livery, boatClass: boatClass)) != nil else { return }
        saved = livery
        // The field shows the number as saved: "0042" reads 42.
        typedNumber = String(livery.sailNumber)
        onSave(livery)
    }

    /// Back to the saved livery: leaving the page, or a new one saved elsewhere (#162).
    func discardDraft() {
        design = saved.design
        colours = Self.colours(of: saved, catalogue: catalogue, keeping: colours)
        typedNumber = String(saved.sailNumber)
        purchaseNote = nil
        section = .decal
    }

    /// `livery` saved elsewhere (#162's server copy): the draft starts over from it.
    func load(_ livery: Livery) {
        saved = livery
        discardDraft()
    }

    /// Opens on `id` tried on (Try it, `-myBoat`), from the saved livery.
    func open(trying id: DesignID?) {
        discardDraft()
        if let id { select(id) }
    }

    // MARK: - Buying

    /// Buys the selected paid design. The purchase is this model's, not the page's, so it outlives the page; a bought
    /// design is owned, and the button goes back to Save (no auto-save).
    func buy() {
        guard case .buy = action, !isBuying, let store, let design = selectedDesign,
              case .paid(let product, _) = design.acquisition else { return }
        isBuying = true
        purchaseNote = nil
        purchaseTask = Task { [weak self] in
            let note: String?
            var bought: DesignID?
            do {
                switch try await store.purchase(ProductID(product)) {
                case .purchased(let id): bought = id; note = nil
                case .pending: note = "Waiting for approval"  // TODO-COPY (#171)
                case .cancelled: note = nil
                }
            } catch StoreError.offline {
                note = "Offline"  // TODO-COPY (#171)
            } catch {
                note = "Try again"  // TODO-COPY (#171)
            }
            guard let self else { return }
            if let bought { self.owned.insert(bought) }
            self.purchaseNote = note
            self.isBuying = false
        }
    }

    /// Waits for the purchase in progress: for tests.
    func purchaseFinished() async {
        await purchaseTask?.value
    }

    // MARK: -

    /// `livery`'s colours by slot, keeping `keeping`'s for any slot its design lacks; an accent with none yet is the
    /// first accent swatch that isn't the deck colour.
    static func colours(of livery: Livery, catalogue: LiveryCatalogue,
                        keeping: [LiverySlot: SwatchID] = [:]) -> [LiverySlot: SwatchID] {
        var colours = keeping
        if let design = catalogue.design(livery.design) {
            for slot in LiverySlot.allCases {
                if let colour = livery.colour(slot, in: design) { colours[slot] = colour }
            }
        }
        for slot in LiverySlot.allCases where colours[slot] == nil {
            colours[slot] = catalogue.swatches.first { $0.slots.contains(slot) && $0.id != colours[.deck] }?.id
        }
        return colours
    }
}
