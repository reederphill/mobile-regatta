import Foundation
import RegattaCore

/// A hint's id (#23, #129): its row in `HintCatalogue`, its progress keys (`HintProgressStore`) and the `hint`
/// property of its `hint_retired` analytics event (#128). Snake case, never one of `RuleSeenStore`'s keys.
enum HintID: String, CaseIterable, Codable, Sendable {
    case raceStart = "race_start"
    case startSequence = "start_sequence"
    case ocs
    case noGo = "no_go"
    case windShift = "wind_shift"
    case puff
    case windShadow = "wind_shadow"
    case layline
    case redGlow = "red_glow"
    case greenGlow = "green_glow"
    case ruleCall = "rule_call"
    case markZone = "mark_zone"
    case lettingGo = "letting_go"
    case centredRudder = "centred_rudder"
    case grooveTick = "groove_tick"
}

/// What a hint's thin leader line points at (#23): the scene resolves it to a point on the water each frame.
enum HintTarget: Equatable, Sendable {
    /// Your boat.
    case myBoat
    /// Your wind vane and its groove tick, drawn on your boat.
    case vane
    /// Another boat, by seat.
    case boat(Int)
    /// A place on the water, metres: a puff's centre, a mark, the nearest point of a layline.
    case point(Vec2)
}

/// Who shows a catalogue row's words.
enum HintDelivery: Equatable, Sendable {
    /// The hint engine: scheduled in the notice slot, gated by Settings' Hints, retired per device.
    case engine
    /// `RaceEventPresenter`'s own notice (#124): the OCS notice and a rule's first plain words with the penalty line,
    /// which Hints off doesn't silence and which keep their own seen state. Kept here as data so the catalogue is the
    /// whole list (#23, #171); never scheduled.
    case presenter
}

/// How a hint is learned (#23, ruling 2): the player has done the thing, so it stops early. Every engine hint also
/// stops once it has shown twice.
enum HintLearning: Equatable, Sendable {
    /// Only by showing twice.
    case never
    /// Held the rudder each way (the steering hint).
    case steeredBothWays
    /// Tacked (the no-go hint).
    case tacked
    /// Rounded a mark (the mark-zone hint).
    case rounded
    /// The autohelm took over: a groove snap, or the rudder let go long enough for it to hold (letting go).
    case autohelmHeld
    /// Its one showing: a line that teaches by being read (the centred-rudder hint, #436).
    case shown
}

/// A hint's line in each steering scheme: the same words unless the scheme changes them.
struct HintText: Equatable, Sendable {
    var halves: String
    var tiller: String

    init(_ both: String) {
        halves = both
        tiller = both
    }

    init(halves: String, tiller: String) {
        self.halves = halves
        self.tiller = tiller
    }

    func text(for steering: DeviceSettings.Steering) -> String {
        switch steering {
        case .halves: halves
        case .tiller: tiller
        }
    }
}

/// A hint's situation is up, and where its leader line points (nil for none).
struct HintFiring: Equatable, Sendable {
    var leader: HintTarget?
}

/// One hint (#23): "an id, a trigger on public sim state, text, an optional leader target and a retire condition".
/// Its trigger reads a `HintSnapshot` only, never the race or any scheduler state, so the 1.2 tutorial can reuse it.
struct Hint {
    let id: HintID
    let delivery: HintDelivery
    let text: HintText
    /// The words are a placeholder until the copy pass (#171) settles them: it clears this as it does.
    let isPlaceholderCopy: Bool
    let learning: HintLearning
    /// Whether the situation is up now, and where the leader points: nil while it isn't.
    let trigger: @MainActor (HintSnapshot, HintTuning) -> HintFiring?
}

/// Every hint (#23, #129), in the order they win when several are up at once. The words live here alone, so the copy
/// pass (#171) edits one table. Short words, no numbers (sparse, descriptive UI). The two presenter rows' words are
/// `RuleWords`'.
enum HintCatalogue {
    // TODO-COPY (#171): every line below.
    static let all: [Hint] = [
        Hint(id: .raceStart, delivery: .engine,
             text: HintText(halves: "Hold left or right to steer. Tiller is in Settings.",
                            tiller: "Slide sideways to steer. Halves is in Settings."),
             isPlaceholderCopy: true, learning: .steeredBothWays, trigger: HintTriggers.raceStart),
        Hint(id: .ocs, delivery: .presenter, text: HintText(RuleWords.ocs), isPlaceholderCopy: true,
             learning: .never, trigger: { _, _ in nil }),
        Hint(id: .ruleCall, delivery: .presenter, text: HintText(RuleWords.penaltyLine), isPlaceholderCopy: true,
             learning: .never, trigger: { _, _ in nil }),
        Hint(id: .startSequence, delivery: .engine, text: HintText(halves: "Hold both sides to ease.",
                                                                    tiller: "Pull down to ease."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.startSequence),
        Hint(id: .noGo, delivery: .engine, text: HintText("Too close to the wind. Let go, or tap Tack."),
             isPlaceholderCopy: true, learning: .tacked, trigger: HintTriggers.noGo),
        Hint(id: .markZone, delivery: .engine, text: HintText("Round the mark on the arrow's side."),
             isPlaceholderCopy: true, learning: .rounded, trigger: HintTriggers.markZone),
        Hint(id: .redGlow, delivery: .engine, text: HintText("Red glow: keep clear of her."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.redGlow),
        Hint(id: .greenGlow, delivery: .engine, text: HintText("Green glow: she keeps clear of you."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.greenGlow),
        Hint(id: .lettingGo, delivery: .engine, text: HintText("Let go and she holds her angle to the wind"),
             isPlaceholderCopy: true, learning: .autohelmHeld, trigger: HintTriggers.lettingGo),
        Hint(id: .centredRudder, delivery: .engine, text: HintText("A centred rudder sails straight on."),
             isPlaceholderCopy: true, learning: .shown, trigger: HintTriggers.centredRudder),
        Hint(id: .grooveTick, delivery: .engine, text: HintText("The tick on the vane is her best angle."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.grooveTick),
        Hint(id: .windShift, delivery: .engine, text: HintText("A shift turns your boat. The vane shows the wind."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.windShift),
        Hint(id: .puff, delivery: .engine, text: HintText("Dark water is more wind."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.puff),
        Hint(id: .windShadow, delivery: .engine, text: HintText("Less wind behind another boat."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.windShadow),
        Hint(id: .layline, delivery: .engine, text: HintText("The yellow line: tack here to reach the mark."),
             isPlaceholderCopy: true, learning: .never, trigger: HintTriggers.layline),
    ]

    /// The rows the engine schedules, in priority order.
    static let engine: [Hint] = all.filter { $0.delivery == .engine }

    static func hint(_ id: HintID) -> Hint {
        // Every id has a row (`HintCatalogueTests`).
        all.first { $0.id == id }!
    }
}
