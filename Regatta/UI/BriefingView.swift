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
            if model.mode == .practice { buttons }
        }
        .foregroundStyle(ChromePalette.text)
        .background(ChromePalette.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("briefing")
        .onAppear(perform: model.begin)
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
                .accessibilityIdentifier("briefing-venue")
            Text(model.conditionsName)
                .font(MenuFont.heading(.title3))
                .foregroundStyle(ChromePalette.tint)
                .accessibilityIdentifier("briefing-conditions")
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let seconds = model.displayedSeconds ?? 0
            Text("Start sequence in \(seconds) s") // TODO-COPY (#171)
                .font(MenuFont.number(.title3))
                .accessibilityLabel("Start sequence in \(seconds) seconds")
                .accessibilityValue(String(seconds))
                .accessibilityIdentifier("briefing-countdown")
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
