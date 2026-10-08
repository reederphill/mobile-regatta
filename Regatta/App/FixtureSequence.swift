import Foundation

/// `-fixtures`' handshake with the render UI tests (#62's render job): several render fixtures in one launch, each
/// shown on a fresh window and model (`SceneDelegate.showWindow`), so a render is the one its own launch draws without
/// a launch's cost.
///
/// The UI test posts the Darwin notification `showName(i)` for the `i`th fixture (from 1: the 0th shows at launch)
/// and waits for `shownName(i)`, which the app posts once that fixture's window has replaced the last one's, so the
/// test never screenshots the fixture before. Darwin notifications cross from the test runner to the app on the
/// simulator; they carry no payload, hence a name per fixture. Only `-uitesting` launches listen.
@MainActor final class FixtureSequence {
    nonisolated static let namePrefix = "com.phillreeder.regatta.render-fixture"

    /// What the UI test posts to show the `index`th fixture of the sequence.
    nonisolated static func showName(_ index: Int) -> String { "\(namePrefix).show.\(index)" }

    /// What the app posts once the `index`th fixture's window is up.
    nonisolated static func shownName(_ index: Int) -> String { "\(namePrefix).shown.\(index)" }

    /// The sequence the Darwin callback reaches: the app's one scene's.
    private static weak var current: FixtureSequence?

    private let names: [String]
    private let show: @MainActor (String) -> Void

    /// Listens for the sequence's later fixtures; nil when `names` has no fixture after the first.
    init?(names: [String], show: @escaping @MainActor (String) -> Void) {
        guard names.count > 1 else { return nil }
        self.names = names
        self.show = show
        Self.current = self
        // The scene keeps the sequence for the process's life, so its observers are never removed; the callback
        // reaches it through `current`, never the observer pointer.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for index in names.indices.dropFirst() {
            CFNotificationCenterAddObserver(center, observer, fixtureSequenceNotified, Self.showName(index) as CFString,
                                            nil, .deliverImmediately)
        }
    }

    /// Shows the fixture `name` asks for, then tells the UI test it's up.
    fileprivate func received(_ name: String) {
        guard let index = names.indices.dropFirst().first(where: { Self.showName($0) == name }) else { return }
        show(names[index])
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.shownName(index) as CFString), nil, nil, true)
    }

    fileprivate static func received(_ name: String) {
        current?.received(name)
    }
}

/// The Darwin notification callback: a C function, so it hops to the main actor with the name alone. A nonisolated
/// closure literal, not a `func`: the app target's default main-actor isolation would make a `func` isolated, and a C
/// function pointer can't be formed from one.
nonisolated(unsafe) private let fixtureSequenceNotified: CFNotificationCallback = { _, _, name, _, _ in
    guard let raw = name?.rawValue else { return }
    let name = raw as String
    Task { @MainActor in FixtureSequence.received(name) }
}
