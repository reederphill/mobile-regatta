import Foundation

/// A sound the game plays, by its #53 manifest name (`docs/assets-manifest.md`, Audio): the bundled file
/// `<name>.caf` (`<name>.m4a` for the music) once #169 adds it, a generated placeholder until then (`SoundLibrary`).
nonisolated enum SoundAsset: String, CaseIterable, Sendable {
    case horn, gun, beep, whistle, bell
    case windLight = "wind-light"
    case windMedium = "wind-medium"
    case windStrong = "wind-strong"
    case waterSlow = "water-slow"
    case waterFast = "water-fast"
    case sailFlog = "sail-flog"
    case menuMusic = "menu-music"

    enum Kind: Sendable {
        /// Played once from the start, a cue (`SoundCue`).
        case oneShot
        /// Looped seamlessly under the race, an ambience layer (`AmbienceLayer`).
        case loop
        /// The menus' music, streamed from its file (`SystemMusicOutput`).
        case music
    }

    var kind: Kind {
        switch self {
        case .horn, .gun, .beep, .whistle, .bell: .oneShot
        case .windLight, .windMedium, .windStrong, .waterSlow, .waterFast, .sailFlog: .loop
        case .menuMusic: .music
        }
    }

    /// The manifest's file extension: loops and one-shots are LPCM, the music AAC.
    var fileExtension: String { kind == .music ? "m4a" : "caf" }
}

/// What the screen shows for a sound (#22: "audio never carries anything the screen doesn't"): every cue and
/// ambience layer has one (`SoundCueTests`).
enum VisualCounterpart: Equatable {
    /// The HUD's countdown clock (#114), yellow through the sequence.
    case hudClock
    /// The OCS notice (#114) and your place readout.
    case ocsNotice
    /// The rule call's dashed line on the water and its badge (#123).
    case ruleCallLine
    /// The active mark moves on to the next one (#114).
    case activeMarkAdvances
    /// Your finished place in the HUD, then the results (#24).
    case finishedPlace
    /// The sail flapping while Ease is on (#112).
    case sailFlutter
    /// The HUD's wind readout and the vane.
    case windReadout
    /// Your boat's wake.
    case wake
}

/// A one-shot the race plays (#22): the committee's start sequence, on the race clock (`SoundSchedule`), and your
/// boat's moments, from the presenter's cues (`init?(_:)`).
enum SoundCue: CaseIterable, Hashable {
    /// The committee's horn at 60 s and 30 s.
    case sequenceHorn
    /// One of the beeps at 5-4-3-2-1.
    case beep
    case gun
    /// You were over at the gun: one horn, the individual recall (RRS 29.1).
    case ocsHorn
    /// A rule call involving you: one umpire whistle.
    case whistle
    /// A soft bell as you round a mark.
    case bell
    /// You finished.
    case finishHorn

    var asset: SoundAsset {
        switch self {
        case .sequenceHorn, .ocsHorn, .finishHorn: .horn
        case .beep: .beep
        case .gun: .gun
        case .whistle: .whistle
        case .bell: .bell
        }
    }

    var visual: VisualCounterpart {
        switch self {
        case .sequenceHorn, .beep, .gun: .hudClock
        case .ocsHorn: .ocsNotice
        case .whistle: .ruleCallLine
        case .bell: .activeMarkAdvances
        case .finishHorn: .finishedPlace
        }
    }

    /// The sound a presenter cue plays, or nil. The sequence ticks and the gun are the race clock's
    /// (`SoundSchedule`): sounding the gun's event too would play it twice online. Calls between other boats
    /// never reach here (the presenter drops them), and protests, contact, a mark touch (rule 31), a served turn, a
    /// DSQ and the groove snap are felt and seen, not heard.
    // An exhaustive switch: a new `RaceCue` doesn't compile until it chooses.
    init?(_ cue: RaceCue) {
        switch cue {
        case .ocs: self = .ocsHorn
        case .callAgainstMe, .callForMe: self = .whistle
        case .rounding: self = .bell
        case .finish: self = .finishHorn
        case .sequenceTick, .gun, .markTouch, .penaltyDone, .protestFiled, .contact, .disqualified, .grooveSnap:
            return nil
        }
    }
}

/// A looping layer of the race's ambience (#22), mixed by `AmbienceMix`.
nonisolated enum AmbienceLayer: CaseIterable, Hashable, Sendable {
    case windLight, windMedium, windStrong
    case waterSlow, waterFast
    case sailFlog

    var asset: SoundAsset {
        switch self {
        case .windLight: .windLight
        case .windMedium: .windMedium
        case .windStrong: .windStrong
        case .waterSlow: .waterSlow
        case .waterFast: .waterFast
        case .sailFlog: .sailFlog
        }
    }
}

extension AmbienceLayer {
    var visual: VisualCounterpart {
        switch self {
        case .windLight, .windMedium, .windStrong: .windReadout
        case .waterSlow, .waterFast: .wake
        case .sailFlog: .sailFlutter
        }
    }
}
