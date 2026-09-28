import RegattaCore
import SpriteKit
import SwiftUI

struct RaceView: View {
    let session: GameSession
    var onRestart: () -> Void
    var onExit: () -> Void
    #if DEBUG
    /// The debug tuning panel (#232), over a paused practice race: its render values show live behind it.
    @Environment(TuningModel.self) private var tuning: TuningModel?
    @State private var showsTuning = false
    #endif

    private var debugOptions: SpriteView.DebugOptions {
        #if DEBUG
        LaunchOptions.current.showsDebugStats ? [.showsFPS, .showsNodeCount, .showsDrawCount] : []
        #else
        []
        #endif
    }

    var body: some View {
        RaceViewport { layout in
            race(layout)
                .onChange(of: layout.sceneSize, initial: true) { _, size in session.scene.size = size }
        }
        // One colour-vision filter over everything the race draws, live or a fixture: the scene at any camera
        // scale, the HUD and overlays, and the letterbox (#111).
        .vision(session.vision)
        #if DEBUG
        .sheet(isPresented: $showsTuning) {
            if let tuning {
                NavigationStack {
                    TuningView(model: tuning)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsTuning = false }
                            }
                        }
                }
                .tint(ChromePalette.tint)
                .presentationDetents([.medium, .large])
            }
        }
        #endif
    }

    @ViewBuilder private func race(_ layout: RaceViewportPolicy.Layout) -> some View {
        if session.driver.isFrozen {
            fixture(bottomInset: layout.safeAreaInsets.bottom)
        } else {
            live
        }
    }

    // Ignoring sibling order, SpriteKit draws nodes that share a z in an order of its own, which can change
    // from launch to launch: every node the scene draws has a z of its own, or a render fixture isn't
    // repeatable (#62, `DrawOrder`).
    private var scene: some View {
        SpriteView(scene: session.scene, preferredFramesPerSecond: 120, options: [.ignoresSiblingOrder], debugOptions: debugOptions)
            .ignoresSafeArea()
    }

    /// A frozen render fixture (#62): the scene alone, no HUD or controls, so a UI test's screenshot of
    /// `render-fixture` is the render and nothing else. Its accessibility value is `bottomInset`, the
    /// safe-area inset at the bottom of the race rect in points: the home-indicator band, which the UI
    /// tests leave out of the diff because the system dims and hides the indicator on its own timer.
    private func fixture(bottomInset: CGFloat) -> some View {
        scene
            .accessibilityElement()
            .accessibilityLabel("Render fixture")
            .accessibilityValue(String(Double(bottomInset)))
            .accessibilityIdentifier("render-fixture")
            .persistentSystemOverlays(.hidden)
    }

    private var live: some View {
        ZStack {
            scene

            HUDView(hud: session.hud, messages: session.messages)
                .allowsHitTesting(false)

            #if DEBUG
            if session.isTuned {
                // Its own overlay (#232), under the minimap, clear of the clock and the controls.
                VStack {
                    HStack {
                        Spacer()
                        TunedBadge()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 142)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            #endif

            controls

            // The tuning panel hides the pause menu, so the water shows undimmed behind it.
            if session.isPaused && !showsTuningPanel {
                PauseMenu(
                    onResume: { session.setPaused(false) },
                    onRestart: onRestart,
                    onExit: onExit,
                    onTuning: tuningAction
                )
            }

            if session.playerDone {
                ResultsView(rows: session.results, onRestart: onRestart, onExit: onExit)
            }
        }
    }

    private var showsTuningPanel: Bool {
        #if DEBUG
        showsTuning
        #else
        false
        #endif
    }

    /// Opens the tuning panel over the paused race: Debug builds, practice races, and not in UI tests.
    private var tuningAction: (() -> Void)? {
        #if DEBUG
        guard tuning != nil, session.driver.isPausable, !LaunchOptions.current.uiTesting else { return nil }
        return { showsTuning = true }
        #else
        return nil
        #endif
    }

    private var controls: some View {
        VStack {
            HStack {
                if session.driver.isPausable {
                    Button {
                        session.setPaused(true)
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Pause")
                    .accessibilityIdentifier("race-pause")
                }
                Spacer()
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer()

            HStack(alignment: .bottom) {
                VStack(spacing: 16) {
                    SteerHint(systemImage: "chevron.left", label: "Port")
                    EaseButton(isEasing: Binding(get: { session.isEasing }, set: { session.isEasing = $0 }))
                        .disabled(!session.hud.status.isRacingOrStarting)
                }
                Spacer()
                Button {
                    session.tackOrGybe()
                } label: {
                    Text(session.hud.isUpwind ? "TACK" : "GYBE")
                        .font(.headline.weight(.heavy))
                        .tracking(1.5)
                        .frame(width: 120, height: 56)
                        // HUD chrome is white on translucent black: orange is the active leg's alone (#22).
                        .background(.black.opacity(0.5), in: .capsule)
                        .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
                        .foregroundStyle(.white)
                        .shadow(radius: 6, y: 3)
                }
                .disabled(!session.hud.status.isRacingOrStarting)
                Spacer()
                SteerHint(systemImage: "chevron.right", label: "Starboard")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

/// Hold to ease the sheets: the boat slows without changing course (#13). A hold, not a tap, so it
/// reads its own touch rather than a `Button`'s.
private struct EaseButton: View {
    @Binding var isEasing: Bool

    var body: some View {
        Text("EASE")
            .font(.subheadline.weight(.heavy))
            .tracking(1.2)
            .frame(width: 76, height: 48)
            .background(.black.opacity(isEasing ? 0.75 : 0.5), in: .capsule)
            .overlay(Capsule().strokeBorder(.white, lineWidth: isEasing ? 3 : 2))
            .foregroundStyle(.white)
            .shadow(radius: 6, y: 3)
            .scaleEffect(isEasing ? 0.94 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isEasing { isEasing = true } }
                    .onEnded { _ in isEasing = false }
            )
            .accessibilityElement()
            .accessibilityLabel("Ease")
            .accessibilityHint("Hold to let the sheets out and slow down")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("race-ease")
    }
}

private struct SteerHint: View {
    let systemImage: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title2.weight(.bold))
            Text(label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.35))
        .frame(width: 70)
        .allowsHitTesting(false)
    }
}

private struct PauseMenu: View {
    var onResume: () -> Void
    var onRestart: () -> Void
    var onExit: () -> Void
    /// The debug tuning panel (#232), when the race offers it.
    var onTuning: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Paused").font(.title.bold())
                Button("Resume", action: onResume).buttonStyle(.borderedProminent)
                Button("Restart race", action: onRestart).buttonStyle(.bordered)
                if let onTuning {
                    Button("Tuning", action: onTuning)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pause-tuning")
                }
                Button("Quit to menu", role: .destructive, action: onExit).buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(28)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        }
    }
}

extension BoatStatus {
    var isRacingOrStarting: Bool { self == .prestart || self == .ocs || self == .racing }
}
