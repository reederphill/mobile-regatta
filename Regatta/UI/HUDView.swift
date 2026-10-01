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
            // One row, so the readouts can't meet at any width (#114): the clock column is as wide as the widest
            // clock, the minimap is fixed, and the wind is centred in what is left between them.
            HStack(alignment: .top, spacing: HUDLayout.spacing) {
                clockAndPlace
                    .frame(width: HUDLayout.clockColumnWidth, alignment: .leading)
                wind
                    .frame(maxWidth: .infinity)
                MinimapView(hud: hud)
                    .frame(width: Self.minimapSize.width, height: Self.minimapSize.height)
                    .accessibilityElement()
                    .accessibilityLabel("Minimap")
                    .accessibilityIdentifier("race-minimap")
            }
            .padding(.leading, HUDLayout.edge + HUDLayout.pauseClearance)
            .padding(.trailing, HUDLayout.edge)
            .padding(.top, 4)

            NoticeLine(notice: notice)
                .frame(height: Self.noticeHeight, alignment: .top)
                .padding(.horizontal, HUDLayout.edge)
                .padding(.top, 8)

            Spacer()
        }
    }

    private var clockAndPlace: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.clockText)
                .font(HUDFont.number(size: HUDLayout.clockSize))
                .foregroundStyle(model.clockTone == .yellow ? CuePalette.yellow.color : .white)
                // UI tests read the tick to see the race advance at sub-second resolution.
                .accessibilityIdentifier("race-clock")
                .accessibilityValue(String(hud.tick))
            Text(model.placeText ?? " ")
                .font(HUDFont.number(size: HUDLayout.placeSize))
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
            // One line where it fits, "12 kn" over "from 352°" where it doesn't (an iPhone's width).
            ViewThatFits(in: .horizontal) {
                Text(model.windText)
                    .fixedSize()
                VStack(spacing: 0) {
                    Text(model.windParts.speed)
                    Text(model.windParts.from)
                }
                .fixedSize()
                VStack(spacing: 0) {
                    Text(model.windParts.speed)
                    Text(model.windParts.from)
                }
                .minimumScaleFactor(0.6)
            }
            .font(HUDFont.number(size: HUDLayout.windSize))
            .lineLimit(1)
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

/// The HUD's top row (#114): the clock column after the pause button, the minimap at the right, and the wind centred
/// between them in whatever width is left. Pure, so tests check it fits at every width the race gets.
enum HUDLayout {
    /// The side margin.
    static let edge: CGFloat = 16
    /// Clear of the pause button (16-56 pt from the race rect's leading edge, `RaceView`).
    static let pauseClearance: CGFloat = 60
    /// Between the clock column, the wind and the minimap.
    static let spacing: CGFloat = 8
    static let clockSize: CGFloat = 30
    static let placeSize: CGFloat = 17
    static let windSize: CGFloat = 15

    /// The widest clock and place the HUD shows: a sequence under ten minutes, the 16-min limit, a 16-boat fleet.
    static let widestClocks = ["-9:59", "15:59"]
    static let widestPlaces = ["16th/16", "OCS", "DSQ"]

    /// The clock column's width: the widest clock or place, so the wind doesn't move as the clock runs.
    static let clockColumnWidth: CGFloat = max(
        widestClocks.map { width(of: $0, size: clockSize) }.max() ?? 0,
        widestPlaces.map { width(of: $0, size: placeSize) }.max() ?? 0
    ).rounded(.up)

    /// The width the wind readout is centred in, for a race rect `width` points wide.
    static func windSpan(width: CGFloat) -> CGFloat {
        width - edge - pauseClearance - clockColumnWidth - spacing - spacing - HUDView.minimapSize.width - edge
    }

    /// `text`'s width in the HUD's number face at `size`.
    static func width(of text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: HUDFont.uiNumber(size: size)]).width
    }
}
