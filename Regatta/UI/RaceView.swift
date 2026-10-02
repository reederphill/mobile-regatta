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

    /// A frozen render fixture (#62): the scene, and the HUD if the fixture asks for it (#114), never the
    /// controls, so a UI test's screenshot of `render-fixture` is the render and nothing else. Its
    /// accessibility value is `bottomInset`, the safe-area inset at the bottom of the race rect in points: the
    /// home-indicator band, which the UI tests leave out of the diff because the system dims and hides the
    /// indicator on its own timer.
    private func fixture(bottomInset: CGFloat) -> some View {
        ZStack {
            scene
            if session.showsFixtureHUD {
                hudView
            }
        }
            .accessibilityElement()
            .accessibilityLabel("Render fixture")
            .accessibilityValue(String(Double(bottomInset)))
            .accessibilityIdentifier("render-fixture")
            .persistentSystemOverlays(.hidden)
    }

    private var live: some View {
        ZStack {
            scene
                // In the scene view's own points, where the scene reads the touches (#112).
                .overlay { TillerIndicator(knob: session.tillerKnob).ignoresSafeArea() }

            if session.showsEdgeLabels {
                EdgeLabels()
            }

            hudView

            #if DEBUG
            if session.isTuned {
                // Its own overlay (#232), under the minimap and the notice line, clear of the clock and the controls.
                VStack {
                    HStack {
                        Spacer()
                        TunedBadge()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, HUDView.noticeTop(showsLeaderboard: session.controls.showsLeaderboard)
                             + HUDView.noticeHeight + 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            #endif

            controls

            if LaunchOptions.current.uiTesting {
                BoatSpeedProbe(session: session)
                CueProbe(session: session)
                PaceProbe(session: session)
                RaceStatusProbe(hud: session.hud)
            }

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

    /// The HUD over the race: touches pass through it to steer, but for the live leaderboard and the place, which
    /// open the board (#268).
    private var hudView: some View {
        HUDView(hud: session.hud, notice: session.notice, heading: { [scene = session.scene] in scene.viewHeading },
                isPaused: session.isPaused || session.driver.isFrozen,
                showsLeaderboard: session.controls.showsLeaderboard,
                isLeaderboardExpanded: session.isLeaderboardExpanded,
                toggleLeaderboard: { [session] in session.toggleLeaderboard() })
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

            RaceControls(session: session)
        }
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
