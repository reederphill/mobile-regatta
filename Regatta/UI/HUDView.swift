import SwiftUI
import RegattaCore

/// The race HUD (#114, #15): the clock and your place top left, the ground wind top centre, the course-up minimap top
/// right, and one notice line under them. Nothing else: no start aids, no shadow readout; the speed and apparent wind
/// are the bottom row's (#457, `RaceControls`).
/// Its colours keep to the reserved-colour rule (#22, G7): the clock is the cue yellow in the start sequence and the
/// countdown to the close, and everything else is white on translucent black. Nothing reads by red or green (#5,
/// #15): a notice's tone is its symbol. Under the clock and place, from the gun to the close, the live leaderboard
/// (#268): it and the place are the HUD's only touch targets (a tap opens the board to the whole fleet); every other
/// touch passes through to steer.
struct HUDView: View {
    let hud: HUDState
    let notice: Notice?
    /// The scene's view heading (#113), read every frame so the wind arrow turns with the view, not after it.
    var heading: () -> Double = { 0 }
    /// Stops the per-frame redraw while the race is paused.
    var isPaused = false
    /// Settings' Live leaderboard (#268).
    var showsLeaderboard = false
    var isLeaderboardExpanded = false
    var toggleLeaderboard: () -> Void = {}

    /// The minimap's size, points.
    static let minimapSize = CGSize(width: 96, height: 132)

    /// The top of the notice line: under the minimap, and with the live leaderboard on, under the compact board too
    /// (#268), reserved for the whole race so the notice never jumps. The open board draws over it for its seconds.
    static func noticeTop(showsLeaderboard: Bool) -> CGFloat {
        max(4 + minimapSize.height, showsLeaderboard ? HUDLayout.boardBottomCompact : 0) + 8
    }
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
                .padding(.top, Self.noticeTop(showsLeaderboard: showsLeaderboard) - 4 - Self.minimapSize.height)

            Spacer()
        }
        // Touches pass through the readouts to steer; only the board and the place take a tap.
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            if showsLeaderboard && hud.leaderboard.isVisible {
                leaderboard
            }
        }
    }

    /// The live leaderboard under the clock and place, and a tap target over the place that opens it too (#268).
    private var leaderboard: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: HUDLayout.clockColumnWidth, height: HUDLayout.lineHeight(size: HUDLayout.placeSize))
                .contentShape(.rect)
                .onTapGesture(perform: toggleLeaderboard)
                .accessibilityHidden(true)
                .padding(.top, HUDLayout.placeTop)
            LeaderboardView(state: hud.leaderboard, isExpanded: isLeaderboardExpanded, isPaused: isPaused,
                            toggle: toggleLeaderboard)
                .padding(.top, HUDLayout.boardTop)
        }
        .padding(.leading, HUDLayout.edge + HUDLayout.pauseClearance)
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

/// The live leaderboard (#268): place, livery swatch and gap to the leader on each row, white on translucent black
/// (#22, G7), "you" in heavy weight inside a white outline, never by colour alone (#15). One shape of swatch for every
/// boat. Rows are keyed by seat, so a reorder slides them; the gaps don't animate.
private struct LeaderboardView: View {
    let state: LeaderboardState
    let isExpanded: Bool
    let isPaused: Bool
    let toggle: () -> Void

    var body: some View {
        let entries = state.entries(expanded: isExpanded)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .row(let row):
                    LeaderboardRow(row: row)
                case .separator:
                    Text("⋯")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: HUDLayout.boardRowWidth, height: HUDLayout.boardSeparatorHeight)
                        .opacity(0.7)
                }
            }
        }
        .padding(HUDLayout.boardPadding)
        .foregroundStyle(.white)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
        .animation(isPaused ? nil : .snappy(duration: 0.25), value: entries.map(\.id))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "compact")
        .accessibilityAction(.default, toggle)
        .accessibilityIdentifier("race-leaderboard")
    }
}

private struct LeaderboardRow: View {
    let row: LeaderboardState.Row

    var body: some View {
        HStack(spacing: HUDLayout.boardSpacing) {
            Text(String(row.place))
                .frame(width: HUDLayout.boardPlaceWidth, alignment: .trailing)
            Circle()
                .fill(Palette.boatColor(row.colorIndex))
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                .frame(width: HUDLayout.boardSwatch, height: HUDLayout.boardSwatch)
            Text(row.gap.text)
                .contentTransition(.identity)
                .frame(width: HUDLayout.boardGapWidth, alignment: .trailing)
        }
        .font(HUDFont.number(size: HUDLayout.boardSize, weight: row.isMe ? .heavy : .bold))
        .lineLimit(1)
        .padding(.horizontal, HUDLayout.boardRowInset)
        .frame(height: HUDLayout.boardRowHeight)
        .overlay {
            if row.isMe {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.5)
            }
        }
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
    static func width(of text: String, size: CGFloat, weight: UIFont.Weight = .bold) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: HUDFont.uiNumber(size: size, weight: weight)]).width
    }

    /// A line's height in the HUD's number face at `size`, whole points up.
    static func lineHeight(size: CGFloat, weight: UIFont.Weight = .bold) -> CGFloat {
        HUDFont.uiNumber(size: size, weight: weight).lineHeight.rounded(.up)
    }

    // MARK: The live leaderboard (#268)

    /// The top of the place line, under the clock.
    static let placeTop: CGFloat = 4 + lineHeight(size: clockSize)
    /// The bottom of the wind readout at its tallest (arrow over two lines, an iPhone's width).
    static let windBottom: CGFloat = 4 + 6 + UIFont.systemFont(ofSize: 18, weight: .bold).lineHeight.rounded(.up) + 2
        + 2 * lineHeight(size: windSize)
    /// The board's top: under the place, and under the wind, so a board wider than the clock column can't meet it.
    static let boardTop: CGFloat = max(placeTop + lineHeight(size: placeSize), windBottom) + 4

    static let boardSize: CGFloat = 13
    static let boardSwatch: CGFloat = 9
    /// Between a row's place, swatch and gap.
    static let boardSpacing: CGFloat = 5
    /// Round the rows, inside the panel.
    static let boardPadding: CGFloat = 4
    /// Each row's own side inset, inside your row's outline.
    static let boardRowInset: CGFloat = 4
    static let boardSeparatorHeight: CGFloat = 9
    static let boardRowHeight: CGFloat = lineHeight(size: boardSize, weight: .heavy) + 3

    /// The widest place and gap a row shows: a 16-boat fleet, a gap under 10 km, and the words.
    static let widestBoardPlaces = ["16"]
    static let widestGaps = ["+9995 m", "Leader", "Fin", "DSQ", "OCS", "—"]
    static let boardPlaceWidth: CGFloat = widestBoardPlaces.map { width(of: $0, size: boardSize, weight: .heavy) }
        .max()!.rounded(.up)
    static let boardGapWidth: CGFloat = widestGaps.map { width(of: $0, size: boardSize, weight: .heavy) }
        .max()!.rounded(.up)
    static let boardRowWidth: CGFloat = boardRowInset + boardPlaceWidth + boardSpacing + boardSwatch + boardSpacing
        + boardGapWidth + boardRowInset
    static let boardWidth: CGFloat = boardRowWidth + 2 * boardPadding

    /// The compact board's bottom at its tallest: four rows and a separator.
    static let boardBottomCompact: CGFloat = boardTop + 2 * boardPadding + 4 * boardRowHeight + boardSeparatorHeight
}
