import SwiftUI

/// The queue bar (#140, #25): across the top of Home and every page pushed on it while you wait for fleet lock, in the
/// home chrome. The wait in a few words, the seconds to the lock, and Leave; about 10 s before the lock it is the
/// yellow-edged lock banner.
struct QueueBarView: View {
    let state: QueueBarState
    var leave: () -> Void

    var body: some View {
        // The seconds count down on the device between the server's pushes.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            bar(state.display(at: context.date))
        }
    }

    private func bar(_ display: QueueBarState.Display) -> some View {
        // Large text: Leave drops under the words.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                words(display)
                Spacer(minLength: 8)
                seconds(display)
                leaveButton(display)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    words(display)
                    Spacer(minLength: 8)
                    seconds(display)
                }
                leaveButton(display)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ChromePalette.text)
        .background {
            // The status area too, so nothing of the page shows above the bar.
            ChromePalette.surface.ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .leading) {
            if display.isBanner {
                // The lock banner's flag-yellow edge, as a notice has; decorative only.
                Rectangle()
                    .fill(ChromePalette.flagYellow)
                    .frame(width: 6)
                    .accessibilityIdentifier("queue-bar-banner")
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue-bar")
    }

    private func words(_ display: QueueBarState.Display) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(display.title)
                .font(MenuFont.heading(.headline))
                .monospacedDigit()
                .accessibilityIdentifier("queue-bar-status")
            if let detail = display.detail {
                Text(detail)
                    .font(MenuFont.body(.subheadline))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("queue-bar-count")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spoken)
    }

    @ViewBuilder private func seconds(_ display: QueueBarState.Display) -> some View {
        if let seconds = display.seconds {
            Text(seconds)
                .font(MenuFont.number(.title3))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func leaveButton(_ display: QueueBarState.Display) -> some View {
        if display.canLeave {
            // TODO-COPY (#171)
            Button("Leave", action: leave)
                .buttonStyle(.bordered)
                .tint(ChromePalette.tint)
                .accessibilityLabel("Leave queue")
                .accessibilityIdentifier("queue-bar-leave")
        }
    }
}

/// The queue's compact chip (#140): over a practice race and its briefing, so you can practise while you wait. A people
/// glyph, the count, the seconds and an "x" that leaves the queue at once.
struct QueueChip: View {
    let state: QueueBarState
    var leave: () -> Void

    /// The chip's drawn height; its row is taller, for the x's touch target.
    static let height: CGFloat = 32
    /// What the race HUD moves down by while the chip shows over it.
    static let hudInset: CGFloat = 32

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            chip(state.display(at: context.date))
        }
        // The race HUD is fixed-size: the chip doesn't grow past what fits beside the island.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func chip(_ display: QueueBarState.Display) -> some View {
        HStack(spacing: 6) {
            Image(systemName: display.kind == .connectionLost ? "wifi.slash" : "person.2.fill")
                .font(.footnote)
                .accessibilityHidden(true)
            Text(display.chip)
                .font(HUDFont.number(size: 14))
                .lineLimit(1)
            Button(action: leave) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Leave queue")
            .accessibilityIdentifier("queue-chip-leave")
            .padding(.trailing, -8)
        }
        .padding(.leading, 12)
        .foregroundStyle(.white)
        .frame(height: 44)
        .background {
            Capsule()
                .fill(.black.opacity(0.55))
                .overlay { Capsule().strokeBorder(display.isBanner ? ChromePalette.flagYellow : .white.opacity(0.25), lineWidth: display.isBanner ? 2 : 1) }
                .frame(height: Self.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.spoken)
        .accessibilityAction(named: "Leave queue", leave)
        .accessibilityIdentifier("queue-chip")
    }
}

extension View {
    /// The queue bar above this view while `queue` has one to show (#140): above a navigation bar, its background
    /// filling the status area. It fades in and out, unless Reduce Motion is on.
    func queueBar(_ queue: QueueController?) -> some View {
        modifier(QueueBarInset(queue: queue))
    }
}

private struct QueueBarInset: ViewModifier {
    let queue: QueueController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // A column, not a safe-area inset: a navigation bar stays at the top of the screen under an inset, and so
        // under the bar.
        VStack(spacing: 0) {
            if let queue, let bar = queue.bar {
                QueueBarView(state: bar, leave: queue.leave)
                    .transition(.opacity)
            }
            content
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: queue?.bar != nil)
    }
}

/// Where the chip sits over a practice race: top-centre with the HUD moved down, or, for the design gate's second
/// look (#140, `REGATTA_QUEUE_CHIP=B`, Debug builds), in the HUD's notice row with the HUD where it was.
enum QueueChipPlacement {
    case top, noticeRow

    static var current: QueueChipPlacement {
        #if DEBUG
        if ProcessInfo.processInfo.environment["REGATTA_QUEUE_CHIP"] == "B" { return .noticeRow }
        #endif
        return .top
    }
}
