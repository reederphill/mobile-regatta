import RegattaCore
import SpriteKit
import SwiftUI

struct RaceView: View {
    let session: GameSession
    var onRestart: () -> Void
    var onExit: () -> Void

    private var debugOptions: SpriteView.DebugOptions {
        #if DEBUG
        [.showsFPS, .showsNodeCount, .showsDrawCount]
        #else
        []
        #endif
    }

    var body: some View {
        ZStack {
            SpriteView(scene: session.scene, preferredFramesPerSecond: 120, options: [.ignoresSiblingOrder], debugOptions: debugOptions)
                .ignoresSafeArea()

            HUDView(hud: session.hud, messages: session.messages, instrumentsInset: lab.steer == .dial ? 200 : 160)
                .allowsHitTesting(false)

            TillerIndicator(lab: lab)
                .ignoresSafeArea()

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
        .onChange(of: lab.steer) { session.showSteeringHint() }
    }

    private var lab: ControlLab { session.scene.lab }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    session.setPaused(true)
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer()

            HStack(alignment: .bottom) {
                VStack(spacing: 10) {
                    if session.hud.penaltyTurns > 0 { SpinButton(lab: lab) }
                    HoldButton(title: "EASE") { lab.isEased = $0 }
                }
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
                if lab.steer == .dial {
                    HeadingDial(lab: lab, heading: session.hud.heading, windDirection: session.hud.windDirection)
                } else {
                    RudderGauge(lab: lab)
                }
            }
            .padding(.horizontal, 20)

            #if DEBUG
            ControlLabBar(lab: lab)
                .padding(.top, 10)
            #endif
        }
        .padding(.bottom, 8)
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
