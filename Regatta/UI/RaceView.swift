import RegattaCore
import SpriteKit
import SwiftUI

struct RaceView: View {
    let session: GameSession
    var onRestart: () -> Void
    var onExit: () -> Void

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
    }

    @ViewBuilder private func race(_ layout: RaceViewportPolicy.Layout) -> some View {
        if session.driver.isFrozen {
            fixture(bottomInset: layout.safeAreaInsets.bottom)
        } else {
            live
        }
    }

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

            controls

            if session.isPaused {
                PauseMenu(
                    onResume: { session.setPaused(false) },
                    onRestart: onRestart,
                    onExit: onExit
                )
            }

            if session.playerDone {
                ResultsView(rows: session.results, onRestart: onRestart, onExit: onExit)
            }
        }
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
                SteerHint(systemImage: "chevron.left", label: "Port")
                Spacer()
                Button {
                    session.tackOrGybe()
                } label: {
                    Text(session.hud.isUpwind ? "TACK" : "GYBE")
                        .font(.headline.weight(.heavy))
                        .tracking(1.5)
                        .frame(width: 120, height: 56)
                        .background(Color(uiColor: Palette.mark), in: .capsule)
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Paused").font(.title.bold())
                Button("Resume", action: onResume).buttonStyle(.borderedProminent)
                Button("Restart race", action: onRestart).buttonStyle(.bordered)
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
