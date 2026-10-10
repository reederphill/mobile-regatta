import RegattaCore
import SwiftUI

/// The race's bottom row (#15, #112): Tack/Gybe bottom centre, your speed to its left and the apparent wind to its
/// right (#457), HUD chrome, white on translucent black: orange is the active leg's alone (#22, G7). Nothing on the
/// water is tappable, since touching the water steers, and the instruments never are. Ease is a gesture (#453), so it
/// has no button; VoiceOver's Ease is an element with nothing to see (`EaseAccessibilityElement`).
struct RaceControls: View {
    let session: GameSession

    private var isRacing: Bool { session.hud.status.isRacingOrStarting }

    /// A control's height and the row's bottom padding, points.
    static let controlHeight: CGFloat = 56
    static let bottomPadding: CGFloat = 16
    /// How far the row reaches up from the bottom of the safe area: the edge arrow (#122) keeps above it.
    static let rowHeight = controlHeight + bottomPadding

    /// The row's side margin, Tack/Gybe's width, and the gap between it and each instrument.
    static let edge: CGFloat = 16
    static let tackWidth: CGFloat = 120
    static let spacing: CGFloat = 8

    var body: some View {
        InstrumentRow(hud: session.hud) {
            HoldButton(title: session.hud.tapTurn.label, width: Self.tackWidth, identifier: "race-tack",
                       isEnabled: isRacing, releases: session.controlReleases,
                       onPress: { session.pressTack(at: Self.now) }, onRelease: { session.releaseTack(at: Self.now) })
        }
        .padding(.horizontal, Self.edge)
        // Where the Ease button was, bottom left: in the side margin, clear of the speed instrument (#457).
        .overlay(alignment: .bottomLeading) {
            EaseAccessibilityElement(session: session, isEnabled: isRacing)
                .padding(.leading, 7)
        }
        .padding(.bottom, Self.bottomPadding)
    }

    /// A render fixture's bottom row (#457 `hud-instruments`): the instruments in their places, Tack/Gybe's slot
    /// empty, as the fixtures draw no controls.
    static func fixtureRow(hud: HUDState) -> some View {
        InstrumentRow(hud: hud) {
            Color.clear.frame(width: tackWidth, height: controlHeight)
        }
        .padding(.horizontal, edge)
        .padding(.bottom, bottomPadding)
    }

    // MARK: The instruments (#457)

    /// The instruments' widest: on a phone wider than an SE they stop here, either side of Tack/Gybe.
    static let instrumentMaxWidth: CGFloat = 104
    /// Inside an instrument, each side.
    static let instrumentInset: CGFloat = 6
    static let speedSize: CGFloat = 24
    static let unitSize: CGFloat = 11
    static let angleSize: CGFloat = HUDLayout.windSize
    static let sideSize: CGFloat = 10
    /// How far a line may shrink to fit before it would truncate.
    static let minimumScale: CGFloat = 0.7

    /// Each instrument's width in a race rect `rowWidth` points wide: what's left either side of Tack/Gybe, up to
    /// `instrumentMaxWidth`.
    static func instrumentWidth(rowWidth: CGFloat) -> CGFloat {
        min(instrumentMaxWidth, (rowWidth - 2 * edge - tackWidth - 2 * spacing) / 2)
    }

    /// The widest the apparent wind's first line reads: the angle in the number face, the side word beside it.
    static func apparentLineWidth(_ angle: Double) -> CGFloat {
        let (degrees, side) = HUDModel.apparentAngleParts(angle: angle)
        let number = HUDLayout.width(of: "\(degrees)°", size: angleSize)
        guard let side else { return number }
        return number + 3 + HUDLayout.width(of: side, size: sideSize, weight: .semibold)
    }

    /// Wall-clock seconds for the Tack/Gybe hold (#222): the hold is the player's, not the simulation's.
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
}

/// The bottom row (#457): your speed left, `center` (Tack/Gybe) in the middle, the apparent wind right, each
/// instrument as wide as `RaceControls.instrumentWidth` gives it. The instruments fade out once you're done
/// (`HUDModel.showsInstruments`) and keep their places, so Tack/Gybe never moves.
struct InstrumentRow<Center: View>: View {
    let hud: HUDState
    @ViewBuilder let center: Center

    private var model: HUDModel { HUDModel(hud) }

    var body: some View {
        HStack(spacing: RaceControls.spacing) {
            SpeedInstrument(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            center
            ApparentWindInstrument(model: model)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// An instrument's face: figures, white on translucent black, the controls' height; never a tap target, and never a
/// tone of its own: no reserved cue colour, nothing read by colour (#22, #15, #454).
private struct InstrumentFace<Content: View>: View {
    let isShown: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .lineLimit(1)
            .minimumScaleFactor(RaceControls.minimumScale)
            .padding(.horizontal, RaceControls.instrumentInset)
            .frame(maxWidth: RaceControls.instrumentMaxWidth)
            .frame(height: RaceControls.controlHeight)
            .background(.black.opacity(0.5), in: .rect(cornerRadius: 14))
            .foregroundStyle(.white)
            .shadow(radius: 6, y: 3)
            .opacity(isShown ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: isShown)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(!isShown)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Your speed through the water (#457): "6.4" over "kn", one decimal.
private struct SpeedInstrument: View {
    let model: HUDModel

    var body: some View {
        InstrumentFace(isShown: model.showsInstruments) {
            VStack(spacing: -2) {
                Text(model.speedText)
                    .font(HUDFont.number(size: RaceControls.speedSize, weight: .heavy))
                Text("kn")
                    .font(HUDFont.number(size: RaceControls.unitSize, weight: .semibold))
            }
        }
        .accessibilityLabel("Speed")
        .accessibilityValue(model.speedAccessibilityValue)
        .accessibilityIdentifier("race-speed")
    }
}

/// The apparent wind (#457): its angle off the bow with the side it comes over, "38° port", over its speed, "21 kn".
/// Never "from" or a compass number, so it can't be taken for the ground wind at the top.
private struct ApparentWindInstrument: View {
    let model: HUDModel

    var body: some View {
        let (degrees, side) = HUDModel.apparentAngleParts(angle: model.hud.shownInstruments.apparentAngle)
        InstrumentFace(isShown: model.showsInstruments) {
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(degrees)°")
                        .font(HUDFont.number(size: RaceControls.angleSize))
                    if let side {
                        Text(side)
                            .font(HUDFont.number(size: RaceControls.sideSize, weight: .semibold))
                    }
                }
                Text(model.apparentSpeedText)
                    .font(HUDFont.number(size: RaceControls.angleSize))
            }
        }
        .accessibilityLabel("Apparent wind")
        .accessibilityValue(model.apparentAccessibilityValue)
        .accessibilityIdentifier("race-apparent-wind")
    }
}

/// One control's face: white on translucent black with a white stroke, brighter while held.
private struct ControlLabel: View {
    let title: String
    let width: CGFloat
    let isHeld: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .font(.headline.weight(.heavy))
            .tracking(1.5)
            .frame(width: width, height: RaceControls.controlHeight)
            .background(.black.opacity(isHeld ? 0.2 : 0.5), in: .capsule)
            .background(.white.opacity(isHeld ? 0.35 : 0), in: .capsule)
            .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.5)
            .shadow(radius: 6, y: 3)
    }
}

/// A button that reports its press and its release (#222 Tack/Gybe). A pause overlay steals the touch without ending
/// the gesture, so a pause (or the button going away or disabled) lets go of it too, without a release.
private struct HoldButton: View {
    let title: String
    let width: CGFloat
    let identifier: String
    let isEnabled: Bool
    /// `GameSession.controlReleases`: a change lets go without releasing (an overlay took the touches).
    let releases: Int
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isHeld = false
    /// A finger is on the button (reset by SwiftUI when the touch ends or is cancelled).
    @GestureState private var isTouching = false
    /// The controls were let go under a finger still down: that touch presses nothing until it lifts, so a press
    /// from before Help (or a pause) never comes back as a stale tack.
    @State private var ignoresTouch = false

    var body: some View {
        ControlLabel(title: title, width: width, isHeld: isHeld)
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { _ in
                        guard !isHeld, !ignoresTouch else { return }
                        isHeld = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard isHeld else { return }
                        isHeld = false
                        onRelease()
                    }
            )
            .disabled(!isEnabled)
            .onChange(of: releases) {
                isHeld = false
                ignoresTouch = isTouching
            }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled, isHeld else { return }
                isHeld = false
                ignoresTouch = isTouching
                onRelease()
            }
            .onChange(of: isTouching) { _, touching in
                if !touching { ignoresTouch = false }
            }
            .onDisappear {
                isHeld = false
                ignoresTouch = false
            }
            .accessibilityElement()
            .accessibilityLabel(title.capitalized)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            .accessibilityAction {
                onPress()
                onRelease()
            }
    }
}

/// VoiceOver's Ease (#453): Ease is a gesture on the water, which VoiceOver can't make, so this element (`race-ease`)
/// toggles it, its value On or Off. Nothing to see: a 2 pt square bottom left, where the Ease button was, in the
/// row's side margin clear of the speed instrument (#457), so a UI test's tap reaches it (XCUITest taps an element's
/// frame) and no thumb on the water ever does.
private struct EaseAccessibilityElement: View {
    let session: GameSession
    let isEnabled: Bool

    var body: some View {
        // A UI test (`-uitesting`) gets a finger-sized target: XCUITest's tap missed the 2 pt one in CI (#467).
        let side: CGFloat = LaunchOptions.current.uiTesting ? 44 : 2
        Color.clear
            .frame(width: side, height: side)
            .contentShape(.rect)
            .onTapGesture { session.toggleEase() }
            .disabled(!isEnabled)
            .accessibilityElement()
            .accessibilityLabel("Ease")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("race-ease")
            .accessibilityValue(session.isEasing ? "On" : "Off")
            .accessibilityAction { session.toggleEase() }
    }
}

/// The halves' faint "‹ Port / Starboard ›" edge labels, at the screen's side edges (#23): first race and halves only.
struct EdgeLabels: View {
    var body: some View {
        HStack {
            EdgeLabel(systemImage: "chevron.left", label: "Port")
            Spacer()
            EdgeLabel(systemImage: "chevron.right", label: "Starboard")
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct EdgeLabel: View {
    let systemImage: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title2.weight(.bold))
            Text(label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.35))
        .frame(width: 70)
    }
}

/// The tiller's track under the touch-down point, a ring at the origin, and a knob under the finger, clamped to the
/// full-rudder throw (#112). A short stem runs down to the ease notch: the knob follows a pull down as far as the
/// notch, and the notch fills as Ease comes on (#453). HUD white, no text. Drawn in the scene view's own points;
/// never hit-tested.
struct TillerIndicator: View {
    let knob: SteeringInterpreter.TillerKnob?

    var body: some View {
        ZStack {
            if let knob {
                Capsule().fill(.black.opacity(0.3))
                    .frame(width: 2 * SteeringInterpreter.tillerFullOffset + 12, height: 10)
                    .position(knob.origin)
                Capsule().fill(.black.opacity(0.3))
                    .frame(width: 10, height: knob.easeLine + 10)
                    .position(x: knob.knob.x, y: knob.origin.y + knob.easeLine / 2)
                Capsule().fill(.white.opacity(knob.isEasing ? 0.9 : 0.6))
                    .frame(width: knob.isEasing ? 26 : 18, height: 3)
                    .position(x: knob.knob.x, y: knob.origin.y + knob.easeLine)
                Circle().stroke(.white.opacity(0.6), lineWidth: 2).frame(width: 18, height: 18).position(knob.origin)
                Circle().fill(.white.opacity(0.9)).frame(width: 26, height: 26).position(knob.knob)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// UI tests only: your boat's speed in knots as an accessibility value (`race-boat-speed`), unsmoothed to two decimals
/// (the HUD's speed instrument, `race-speed`, is smoothed to one, #457), and her speed the moment Ease was last let go (`race-ease-release`, labelled with how many
/// times it has been, #112). Read from the driver about four times a second, apart from the HUD's state (#114).
struct BoatSpeedProbe: View {
    let session: GameSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let boat = session.driver.currentFrame.boats[session.driver.myBoatIndex]
            let value = String(format: "%.2f", knots(metresPerSecond: boat.speed))
            let release = session.easeReleases
            let releaseValue = String(format: "%.2f", release.knots)
            VStack(spacing: 0) {
                Text(value)
                    .accessibilityLabel("Boat speed")
                    .accessibilityValue(value)
                    .accessibilityIdentifier("race-boat-speed")
                Text(releaseValue)
                    .accessibilityLabel("Ease released \(release.count)")
                    .accessibilityValue(releaseValue)
                    .accessibilityIdentifier("race-ease-release")
            }
            .font(.system(size: 1))
            .foregroundStyle(.clear)
        }
        .frame(width: 1, height: 2)
        .allowsHitTesting(false)
    }
}

/// UI tests only: which boat-side cues the scene draws (#122), as an accessibility value (`race-cues`), e.g.
/// `laylines=1 ladder=0 vane=1 arrow=0` (`GameScene.cueSummary`). Read about four times a second.
struct CueProbe: View {
    let session: GameSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let value = session.scene.cueSummary
            Text(value)
                .accessibilityLabel("Cues")
                .accessibilityValue(value)
                .accessibilityIdentifier("race-cues")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
}

/// UI tests only: how fast the race runs (#361), as an accessibility element (`race-pace`) whose label is
/// `GameScene.paceSummary` and whose value is the ticks run since the first frame. Read once a second: a UI test reads
/// it at the end of a watch, as each query steals main-thread time from the race.
struct PaceProbe: View {
    let session: GameSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let summary = session.scene.paceSummary
            Text(summary)
                .accessibilityLabel(summary)
                .accessibilityValue(String(session.scene.pace.ticks))
                .accessibilityIdentifier("race-pace")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
}
