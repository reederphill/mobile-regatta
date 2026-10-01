import SwiftUI
import RegattaCore

/// The race HUD (#114, #15): the clock and your place top left, the ground wind top centre, the course-up minimap top
/// right, and one notice line under them. Nothing else: no speed, no instruments, no start aids, no shadow readout.
/// Its colours keep to the reserved-colour rule (#22, G7): the clock is the cue yellow in the start sequence and the
/// countdown to the close, and everything else is white on translucent black. Nothing reads by red or green (#5,
/// #15): a notice's tone is its symbol. The left column below the place stays free for the leaderboard (#268).
struct HUDView: View {
    let hud: HUDState
    let notice: Notice?
    /// The scene's view heading (#113), read every frame so the wind arrow turns with the view, not after it.
    var heading: () -> Double = { 0 }
    /// Stops the per-frame redraw while the race is paused.
    var isPaused = false

    /// The minimap's size, points.
    static let minimapSize = CGSize(width: 96, height: 132)
    /// The top of the notice line, under the minimap.
    static let noticeTop: CGFloat = 4 + minimapSize.height + 8
    /// The notice line's reserved height: two lines of footnote, so the layout doesn't jump.
    static let noticeHeight: CGFloat = 44

    private var model: HUDModel { HUDModel(hud) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    clockAndPlace
                        .padding(.leading, 60)
                    Spacer()
                    MinimapView(hud: hud)
                        .frame(width: Self.minimapSize.width, height: Self.minimapSize.height)
                        .accessibilityElement()
                        .accessibilityLabel("Minimap")
                        .accessibilityIdentifier("race-minimap")
                }
                wind
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            NoticeLine(notice: notice)
                .frame(height: Self.noticeHeight, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer()
        }
    }

    private var clockAndPlace: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.clockText)
                .font(HUDFont.number(size: 30))
                .foregroundStyle(model.clockTone == .yellow ? CuePalette.yellow.color : .white)
                // UI tests read the tick to see the race advance at sub-second resolution.
                .accessibilityIdentifier("race-clock")
                .accessibilityValue(String(hud.tick))
            Text(model.placeText ?? " ")
                .font(HUDFont.number(size: 17))
                .foregroundStyle(.white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.placeText ?? "")
                .accessibilityValue(model.placeText == nil ? "hidden" : "shown")
                .accessibilityIdentifier("race-place")
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private var wind: some View {
        VStack(spacing: 2) {
            TimelineView(.animation(paused: isPaused)) { _ in
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .bold))
                    .rotationEffect(.radians(HUDModel.screenAngle(ofCompass: hud.windDirection, viewHeading: heading())))
            }
            Text(model.windText)
                .font(HUDFont.number(size: 15))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.top, 6)
        .shadow(color: .black.opacity(0.4), radius: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.windText)
        .accessibilityIdentifier("race-wind")
    }
}

/// The one notice line (#114, #15): always there at its reserved height, empty when there's no notice.
private struct NoticeLine: View {
    let notice: Notice?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let notice {
                Image(systemName: notice.symbol)
                    .accessibilityHidden(true)
                Text(notice.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, notice == nil ? 0 : 12)
        .padding(.vertical, notice == nil ? 0 : 6)
        .background(.black.opacity(notice == nil ? 0 : 0.55), in: .rect(cornerRadius: 10))
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice?.text ?? "")
        .accessibilityValue(notice?.kind.rawValue ?? "none")
        .accessibilityIdentifier("race-notice")
    }
}
