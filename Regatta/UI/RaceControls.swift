import RegattaCore
import SwiftUI

/// The race's bottom row (#15, #112): Ease bottom left, Tack/Gybe bottom centre, Protest bottom right. All three are
/// HUD chrome, white on translucent black: orange is the active leg's alone (#22, G7). Nothing on the water is
/// tappable, since touching the water steers.
struct RaceControls: View {
    let session: GameSession

    private var isRacing: Bool { session.hud.status.isRacingOrStarting }

    var body: some View {
        HStack(alignment: .bottom) {
            // Ease holds boats on the line before the gun too (#99).
            HoldButton(title: "EASE", width: 96, identifier: "race-ease", isEnabled: isRacing, isPaused: session.isPaused,
                       onPress: { session.setEase(true) }, onRelease: { session.setEase(false) },
                       accessibilityToggle: .init(isOn: session.isEasing, toggle: { session.toggleEase() }))
            Spacer()
            HoldButton(title: session.hud.isUpwind ? "TACK" : "GYBE", width: 120, identifier: "race-tack",
                       isEnabled: isRacing, isPaused: session.isPaused,
                       onPress: { session.pressTack(at: Self.now) }, onRelease: { session.releaseTack(at: Self.now) })
            Spacer()
            // A placeholder until #125 wires it to the protest picker: it brightens under the finger like the others.
            Button("Protest") {}
                .buttonStyle(ControlButtonStyle(title: "PROTEST", width: 96))
                .disabled(!isRacing)
                .accessibilityIdentifier("race-protest")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// Wall-clock seconds for the Tack/Gybe hold (#222): the hold is the player's, not the simulation's.
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
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
            .frame(width: width, height: 56)
            .background(.black.opacity(isHeld ? 0.2 : 0.5), in: .capsule)
            .background(.white.opacity(isHeld ? 0.35 : 0), in: .capsule)
            .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.5)
            .shadow(radius: 6, y: 3)
    }
}

/// A plain button's face: the control label, brighter while pressed.
private struct ControlButtonStyle: ButtonStyle {
    let title: String
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        ControlLabel(title: title, width: width, isHeld: configuration.isPressed)
    }
}

/// A button that reports its press and its release (#99 Ease, #222 Tack/Gybe). A pause overlay steals the touch
/// without ending the gesture, so a pause (or the button going away or disabled) lets go of it too, without a release.
private struct HoldButton: View {
    let title: String
    let width: CGFloat
    let identifier: String
    let isEnabled: Bool
    let isPaused: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    /// VoiceOver can't hold a button, so a hold that is a mode (Ease) is a toggle there, its value On or Off; nil
    /// (Tack/Gybe) makes the action a press and release.
    var accessibilityToggle: AccessibilityToggle?
    @State private var isHeld = false

    struct AccessibilityToggle {
        let isOn: Bool
        let toggle: () -> Void
    }

    var body: some View {
        ControlLabel(title: title, width: width, isHeld: isHeld || accessibilityToggle?.isOn == true)
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHeld else { return }
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
            .onChange(of: isPaused) { _, paused in if paused { isHeld = false } }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled, isHeld else { return }
                isHeld = false
                onRelease()
            }
            .onDisappear { isHeld = false }
            .accessibilityElement()
            .accessibilityLabel(title.capitalized)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(accessibilityToggle.map { $0.isOn ? "On" : "Off" } ?? "")
            .accessibilityAction {
                if let accessibilityToggle {
                    accessibilityToggle.toggle()
                } else {
                    onPress()
                    onRelease()
                }
            }
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
/// full-rudder throw and level with the origin (#112). Drawn in the scene view's own points; never hit-tested.
struct TillerIndicator: View {
    let knob: SteeringInterpreter.TillerKnob?

    var body: some View {
        ZStack {
            if let knob {
                Capsule().fill(.black.opacity(0.3))
                    .frame(width: 2 * SteeringInterpreter.tillerFullOffset + 12, height: 10)
                    .position(knob.origin)
                Circle().stroke(.white.opacity(0.6), lineWidth: 2).frame(width: 18, height: 18).position(knob.origin)
                Circle().fill(.white.opacity(0.9)).frame(width: 26, height: 26).position(knob.knob)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// UI tests only: your boat's speed in knots as an accessibility value (`race-boat-speed`), since the HUD shows no
/// speed number (#15), and her speed the moment Ease was last let go (`race-ease-release`, labelled with how many
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
