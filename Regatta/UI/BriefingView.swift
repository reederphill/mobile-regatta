import RegattaCore
import SwiftUI

/// The briefing (#130, #16, #15): venue, conditions, a short wind and current description, the course in a line and
/// the fleet, full screen in the race sequence's dark cover. A practice briefing waits for Ready (with Back to the
/// setup); an online one counts down and advances itself, with no buttons.
///
/// Plain and scrolling, in the menus' chrome (`ChromePalette`, `MenuFont`), across the full window on iPad too.
struct BriefingView: View {
    let model: BriefingModel
    /// Ready, or the countdown run out.
    var onAdvance: () -> Void
    /// Practice's Back: out of the race sequence, to the setup.
    var onBack: () -> Void
    /// A locked fleet's briefing (#140): its Leave bar, the confirm, and the line while the connection is gone.
    var leave: BriefingLeave? = nil
    /// The takeover puts VoiceOver on the venue (#140): the briefing came unasked, over whatever she was reading.
    @AccessibilityFocusState private var isVenueFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.mode != .practice { countdown }
                section("Today") { // TODO-COPY (#171)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.windLines, id: \.self) { Text($0).font(MenuFont.body()) }
                        if let current = model.currentLine {
                            Text(current).font(MenuFont.body()).accessibilityIdentifier("briefing-current")
                        }
                        Text(model.courseLine).font(MenuFont.body())
                    }
                }
                section("Fleet") {
                    BriefingFleetList(rows: model.fleet)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            if model.mode == .practice { buttons } else if let leave { leaveBar(leave) }
        }
        .overlay {
            if let leave, leave.isConfirming { leaveConfirm(leave) }
        }
        .foregroundStyle(ChromePalette.text)
        .background(ChromePalette.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("briefing")
        .onAppear(perform: model.begin)
        .task {
            guard leave != nil else { return }
            // Once the cross-fade is done and the cover is VoiceOver's.
            try? await Task.sleep(for: .milliseconds(400))
            isVenueFocused = true
        }
        .task {
            guard model.mode != .practice else { return }
            while !Task.isCancelled {
                if model.advanceIfDue() {
                    onAdvance()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.venueName)
                .font(MenuFont.heading(.largeTitle))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isVenueFocused)
                .accessibilityIdentifier("briefing-venue")
            Text(model.conditionsName)
                .font(MenuFont.heading(.title3))
                .foregroundStyle(ChromePalette.tint)
                .accessibilityIdentifier("briefing-conditions")
        }
    }

    private var countdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let seconds = model.displayedSeconds ?? 0
                Text("Start sequence in \(seconds) s") // TODO-COPY (#171)
                    .font(MenuFont.number(.title3))
                    .accessibilityLabel("Start sequence in \(seconds) seconds")
                    .accessibilityValue(String(seconds))
                    .accessibilityIdentifier("briefing-countdown")
            }
            if leave?.isReconnecting == true {
                // The connection has been gone a moment (#140): the briefing runs on.
                Label("Reconnecting", systemImage: "wifi.exclamationmark") // TODO-COPY (#171)
                    .font(MenuFont.body(.subheadline))
                    .foregroundStyle(ChromePalette.text.opacity(0.7))
                    .accessibilityIdentifier("briefing-reconnecting")
            }
        }
    }

    /// The locked fleet's Leave (#140), where practice has Back: it asks first.
    private func leaveBar(_ leave: BriefingLeave) -> some View {
        HStack {
            Button(action: leave.ask) {
                Text("Leave").font(MenuFont.body()).padding(.vertical, 6).padding(.horizontal, 8) // TODO-COPY (#171)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("briefing-leave")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(ChromePalette.background.ignoresSafeArea())
        .overlay(alignment: .top) { Divider().overlay(ChromePalette.text.opacity(0.15)) }
    }

    /// "Leave the race?" (#140): over the briefing, whose countdown runs on behind it.
    private func leaveConfirm(_ leave: BriefingLeave) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                // TODO-COPY (#171)
                Text("Leave the race?").font(MenuFont.heading(.title3))
                Text("A bot takes your seat.").font(MenuFont.body()).foregroundStyle(ChromePalette.text.opacity(0.7))
                HStack(spacing: 12) {
                    Button(action: leave.confirm) {
                        Text("Leave").font(MenuFont.body()).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("briefing-leave-confirm")
                    Button(action: leave.stay) {
                        Text("Stay").font(MenuFont.heading(.headline)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("briefing-leave-stay")
                }
                .controlSize(.large)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: 360)
            .background(ChromePalette.surface, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Text("Back").font(MenuFont.body()).padding(.vertical, 6).padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("briefing-back")
            Button {
                if model.ready() { onAdvance() }
            } label: {
                Text("Ready")
                    .font(MenuFont.heading(.title3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("briefing-ready")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(ChromePalette.background.ignoresSafeArea())
        .overlay(alignment: .top) { Divider().overlay(ChromePalette.text.opacity(0.15)) }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(MenuFont.heading(.title3))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A locked fleet's briefing's Leave (#140): what the queue's takeover says of it, and what its buttons do.
struct BriefingLeave {
    /// "Leave the race?" is up.
    var isConfirming = false
    /// The connection has been gone 2 s.
    var isReconnecting = false
    /// Leave: asks first.
    var ask: () -> Void = {}
    /// The confirm's Leave: home, and a bot takes the seat.
    var confirm: () -> Void = {}
    var stay: () -> Void = {}
}
