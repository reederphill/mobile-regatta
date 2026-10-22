import RegattaCore
import RegattaServices
import SwiftUI

/// Home's lobby area (#25, #142): the gate panels before any lobby call, the hidden panel (the queue and the
/// leaderboard's top) for a player who doesn't see chat, the loading, unreachable and silent panels, and the open
/// lobby: the feed, newest at the bottom, over the composer. One element, `lobby-panel`, whatever it shows.
struct LobbyView: View {
    let state: LobbyPanelState
    /// Nil in previews and tests without an online status: the open lobby shows no lines.
    var model: LobbyModel?
    var leaderboardTop: (any LeaderboardTopSource)?
    var onSignIn: () -> Void = {}
    var onReviewTerms: () -> Void = {}
    var onShowLeaderboard: () -> Void = {}
    var onOpenCard: (LobbyAuthor) -> Void = { _ in }
    /// Block on a long-press, waiting for its confirm.
    @State private var blocking: LobbyAuthor?

    /// The open lobby fills the rest of Home (G1); the other panels are as tall as they need.
    var fills: Bool { state == .lobby }

    var body: some View {
        Group {
            if fills, let model {
                open(model)
            } else if fills {
                message("No messages yet", systemImage: nil)
            } else {
                // A panel taller than the room left scrolls in place.
                ViewThatFits(in: .vertical) {
                    panel
                    ScrollView { panel }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        // UI tests check it fits the window.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lobby-panel")
        .confirmationDialog(
            // TODO-COPY (#171)
            "Block \(blocking?.nickname ?? "")?",
            isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
            titleVisibility: .visible, presenting: blocking
        ) { author in
            // TODO-COPY (#171)
            Button("Block", role: .destructive) {
                Task { await model?.block(author.gamePlayerID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // TODO-COPY (#171)
            Text("You won't see each other's messages.")
        }
    }

    @ViewBuilder private var panel: some View {
        switch state {
        case .offline:
            // TODO-COPY (#171)
            message("Lobby needs a connection", systemImage: "wifi.slash")
        case .tryAgain(let line):
            // The words under Race online: neither line carries a date. Signing in again: with Game Center there
            // already, that is the session alone.
            message(line.text(now: .now),
                    systemImage: line == .unreachable ? "icloud.slash" : "person.crop.circle.badge.exclamationmark") {
                // TODO-COPY (#171)
                Button("Try again", action: onSignIn)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("lobby-retry")
            }
        case .signIn:
            message("Sign in to Game Center to chat", systemImage: "person.crop.circle.badge.checkmark") {
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("lobby-sign-in")
            }
        case .acceptTerms:
            message("Accept the terms to chat and race online", systemImage: "doc.text") {
                Button("Review terms", action: onReviewTerms)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("lobby-terms")
            }
        case .chatHidden(let queuedPlayers):
            LobbyHiddenPanel(queuedPlayers: queuedPlayers, source: leaderboardTop, showLeaderboard: onShowLeaderboard)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityIdentifier("lobby-loading")
        case .unreachable:
            // Before #164 a session's lobby is the unconnected fake, so this Try again can't succeed until then (T5).
            // TODO-COPY (#171)
            message("Can't reach the lobby", systemImage: "icloud.slash") {
                // TODO-COPY (#171)
                Button("Try again") { model?.retry() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("lobby-reopen")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lobby-unreachable")
        case .silent:
            // TODO-COPY (#171)
            Text("Back after your race")
                .font(MenuFont.heading(.headline))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("lobby-silent")
        case .lobby:
            EmptyView()
        }
    }

    /// The open lobby (row 8): the feed in its own scroll, the composer pinned under it.
    private func open(_ model: LobbyModel) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.feed.lines.isEmpty {
                        // TODO-COPY (#171)
                        Text("No messages yet")
                            .font(MenuFont.body(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.feed.lines) { line in
                        LobbyLineView(line: line, isOwn: line.message.post?.author.gamePlayerID == model.me,
                                      actions: model.actions(for: line.message),
                                      openCard: model.opensCard(line.message).map { author in { onOpenCard(author) } },
                                      report: { Task { await model.report(line.id) } },
                                      block: { blocking = line.message.post?.author })
                    }
                }
                .padding(16)
            }
            // Newest at the bottom, and it follows new lines while she is there (G1).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("lobby-feed")
            Divider()
            LobbyComposerView(model: model)
                .padding(12)
        }
    }

    /// One line in the panel, and its button if any.
    private func message(_ title: String, systemImage: String?, @ViewBuilder button: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(MenuFont.heading(.headline))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            button()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// A lobby line (G2): a system line centred in secondary, or a post's chip, nickname, rating and badge over its
/// words. Her own nickname is in the tint; her post the filter blocked is greyed and marked "Not sent". Another
/// player's post opens her card from the chip or name, and a long-press offers Report and Block.
struct LobbyLineView: View {
    let line: LobbyFeed.Line
    var isOwn = false
    var actions: [LobbyFeed.Action] = []
    var openCard: (() -> Void)?
    var report: () -> Void = {}
    var block: () -> Void = {}

    var body: some View {
        Group {
            switch line.message.kind {
            case .system(let system): systemLine(system)
            case .post(let post): postLine(post)
            }
        }
        .accessibilityIdentifier("lobby-line-\(line.id.rawValue)")
    }

    private func systemLine(_ system: SystemLine) -> some View {
        Label(Self.text(system), systemImage: Self.symbol(system))
            .font(MenuFont.body(.subheadline))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }

    private func postLine(_ post: LobbyPost) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let openCard {
                Button(action: openCard) { sailor(post.author) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lobby-line-\(line.id.rawValue)-sailor")
            } else {
                sailor(post.author)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.text(post.body))
                    .font(MenuFont.body())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if line.isNotSent {
                    // TODO-COPY (#171)
                    Text("Not sent")
                        .font(MenuFont.body(.caption))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("lobby-not-sent")
                }
            }
        }
        .opacity(line.isNotSent ? 0.5 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .contextMenu {
            if actions.contains(.report) {
                // TODO-COPY (#171)
                Button("Report", systemImage: "flag", action: report)
            }
            if actions.contains(.block) {
                // TODO-COPY (#171)
                Button("Block \(post.author.nickname)", systemImage: "nosign", role: .destructive, action: block)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Chip, nickname, rating and badge.
    private func sailor(_ author: LobbyAuthor) -> some View {
        HStack(spacing: 6) {
            LiveryChipView(chip: author.chip, diameter: 16)
            Text(author.nickname)
                .font(MenuFont.heading(.subheadline))
                .foregroundStyle(isOwn ? ChromePalette.tint : ChromePalette.text)
            // Verbatim: a rating is never grouped.
            Text(verbatim: "\(author.rating.value)")
                .font(MenuFont.number(.caption))
                .foregroundStyle(.secondary)
            if author.rating.isProvisional { ProvisionalBadge(font: MenuFont.body(.caption2)) }
        }
        .accessibilityElement(children: .combine)
    }

    // TODO-COPY (#171)
    static func text(_ system: SystemLine) -> String {
        switch system {
        case .gun(let venue, let boats, let humans):
            "Gun at \(venue) · \(boats) \(boats == 1 ? "boat" : "boats"), \(humans) \(humans == 1 ? "sailor" : "sailors")"
        case .winner(let venue, let nickname): "\(nickname) won at \(venue)"
        }
    }

    static func symbol(_ system: SystemLine) -> String {
        switch system {
        case .gun: "flag"
        case .winner: "trophy"
        }
    }

    static func text(_ body: PostBody) -> String {
        switch body {
        case .text(let text): text
        case .quickChat(let quickChat): quickChat.text
        }
    }
}

/// The "Provisional" capsule beside a rating (#139 G1, #142 G3).
struct ProvisionalBadge: View {
    var font = MenuFont.body(.subheadline)

    var body: some View {
        // TODO-COPY (#171)
        Text("Provisional")
            .font(font)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ChromePalette.tint.opacity(0.18), in: .capsule)
    }
}

/// The composer (rows a-f): a notice when she can't post, the quick-chat row, the field, its counter and Send.
struct LobbyComposerView: View {
    @Bindable var model: LobbyModel
    @FocusState private var isFocused: Bool

    var body: some View {
        // The 3 s rest and the cooldown end by themselves: the model marks the moment, and the field is never rebuilt
        // on a timer, which would drop what she types.
        content(now: max(model.refreshedAt, Date()))
        .onChange(of: model.isFieldFocused) { _, focused in if isFocused != focused { isFocused = focused } }
        .onChange(of: isFocused) { _, focused in if model.isFieldFocused != focused { model.isFieldFocused = focused } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lobby-composer")
    }

    private func content(now: Date) -> some View {
        let mode = model.mode(at: now)
        let composer = model.composer
        let fieldEnabled = composer.fieldEnabled(now: now)
        return VStack(alignment: .leading, spacing: 10) {
            switch mode {
            // TODO-COPY (#171)
            case .banned: NoticeRow(title: "Chat closed", id: "lobby-banned")
            // TODO-COPY (#171)
            case .muted(let until): NoticeRow(title: "Muted until \(Self.mutedText(until))", id: "lobby-muted")
            // TODO-COPY (#171)
            case .cooldown: NoticeRow(title: "Posting paused for a moment", id: "lobby-cooldown")
            case .resting, .locked, .open: EmptyView()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(QuickChat.allCases, id: \.self) { quickChat in
                        Button(quickChat.text) { Task { await model.post(quickChat) } }
                            .font(MenuFont.body(.subheadline))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .disabled(!composer.quickChatEnabled(now: now))
                            .accessibilityIdentifier("lobby-quick-\(quickChat.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            HStack(alignment: .center, spacing: 8) {
                // The placeholder wraps, where the field's own prompt would be cut to one line.
                ZStack(alignment: .leading) {
                    if model.text.isEmpty {
                        Text(Self.placeholder(canPostFreeText: composer.canPostFreeText))
                            .font(MenuFont.body())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField(Self.placeholder(canPostFreeText: composer.canPostFreeText), text: $model.text,
                              prompt: Text(""), axis: .vertical)
                        .font(MenuFont.body())
                        .lineLimit(1...4)
                        .focused($isFocused)
                        .disabled(!fieldEnabled)
                        .accessibilityIdentifier("lobby-field")
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ChromePalette.background, in: .rect(cornerRadius: 10))
                    .opacity(fieldEnabled ? 1 : 0.6)
                if fieldEnabled, composer.showsCounter {
                    Text(verbatim: "\(composer.remaining)")
                        .font(MenuFont.number(.caption))
                        .foregroundStyle(composer.remaining == 0 ? ChromePalette.errorText : .secondary)
                        .fixedSize()
                        .layoutPriority(1)
                        .accessibilityLabel("\(composer.remaining) characters left")
                        .accessibilityIdentifier("lobby-counter")
                }
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .disabled(!composer.canSend(now: now))
                // The page's text colour would otherwise keep a disabled Send looking live.
                .opacity(composer.canSend(now: now) ? 1 : 0.35)
                // TODO-COPY (#171)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("lobby-send")
            }
        }
    }

    // TODO-COPY (#171)
    static func placeholder(canPostFreeText: Bool) -> String {
        canPostFreeText ? "Say something" : "Free chat opens after your first online race"
    }

    /// A mute's end, with the day and the hour (G10): a 24 h mute needs both.
    static func mutedText(_ until: Date) -> String {
        until.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// The hidden panel (row 5, G12): the queued count while she's queued, the leaderboard's top five, and a row that
/// opens Game Center's board. Restricted players aren't told why. No lobby call ever.
struct LobbyHiddenPanel: View {
    let queuedPlayers: Int?
    let source: (any LeaderboardTopSource)?
    var showLeaderboard: () -> Void = {}
    @State private var entries: [LeaderboardEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let queuedPlayers {
                // TODO-COPY (#171)
                Label("\(queuedPlayers) in the queue", systemImage: "person.3")
                    .font(MenuFont.heading(.headline))
                    .padding(16)
                    .accessibilityIdentifier("lobby-queued")
                Divider()
            }
            if !entries.isEmpty {
                // TODO-COPY (#171)
                Text("Leaderboard")
                    .font(MenuFont.heading(.headline))
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(entries, id: \.rank) { entry in
                    HStack(spacing: 12) {
                        Text(verbatim: "\(entry.rank)")
                            .font(MenuFont.number(.body))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .leading)
                        Text(entry.name).font(MenuFont.body())
                        Spacer(minLength: 12)
                        Text(verbatim: "\(entry.rating)").font(MenuFont.number(.body))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("lobby-leaderboard-row-\(entry.rank)")
                }
                .padding(.bottom, 6)
                Divider()
            }
            Button(action: showLeaderboard) {
                HStack {
                    // TODO-COPY (#171)
                    Text("Leaderboard").font(MenuFont.body())
                    Spacer(minLength: 12)
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                }
                .padding(16)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Leaderboard")
            .accessibilityIdentifier("lobby-leaderboard")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lobby-hidden")
        // Read once each time the panel appears (T10).
        .task { entries = await source?.top(5) ?? [] }
    }
}

/// A lobby player's boat card (#25, G14): a half-height sheet with her boat, sail number, nickname, rating and badge,
/// and Report player and Block. The line's fields until the lobby's card answers; the render and sail number from it.
struct BoatCardSheet: View {
    let author: LobbyAuthor
    var model: LobbyModel?
    var close: () -> Void
    @State private var card: BoatCard?
    @State private var isLoading = true
    @State private var confirmsReport = false
    @State private var confirmsBlock = false
    @State private var reported = false
    @State private var blockFailed = false

    private var nickname: String { card?.nickname ?? author.nickname }
    private var rating: Rating { card?.rating ?? author.rating }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    boat
                    if let card {
                        // TODO-COPY (#171)
                        Text(verbatim: "Sail \(card.livery.sailNumber)")
                            .font(MenuFont.number(.subheadline))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("boatCard-sail")
                    }
                    Text(nickname)
                        .font(MenuFont.heading(.title2))
                        .accessibilityIdentifier("boatCard-nickname")
                    HStack(spacing: 8) {
                        Text(verbatim: "\(rating.value)")
                            .font(MenuFont.number(.title3))
                            .accessibilityLabel("Rating")
                            .accessibilityValue("\(rating.value)")
                            .accessibilityIdentifier("boatCard-rating")
                        if rating.isProvisional {
                            ProvisionalBadge().accessibilityIdentifier("boatCard-provisional")
                        }
                    }
                    HStack(spacing: 12) {
                        // TODO-COPY (#171)
                        Button(reported ? "Reported" : "Report player") { confirmsReport = true }
                            .disabled(reported)
                            .accessibilityIdentifier("boatCard-report")
                        // TODO-COPY (#171)
                        Button("Block", role: .destructive) { confirmsBlock = true }
                            .accessibilityIdentifier("boatCard-block")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 12)
                    if blockFailed {
                        // TODO-COPY (#171)
                        Text("Couldn't block. Try again later.")
                            .font(MenuFont.body(.footnote))
                            .foregroundStyle(ChromePalette.errorText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .menuBackground()
            // TODO-COPY (#171)
            .navigationTitle("Boat card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
            .confirmationDialog("Report \(nickname)?", isPresented: $confirmsReport, titleVisibility: .visible) {
                // TODO-COPY (#171)
                Button("Report") {
                    Task { reported = await model?.report(player: author.gamePlayerID) ?? false }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // TODO-COPY (#171)
                Text("For their chat or their nickname.")
            }
            .confirmationDialog("Block \(nickname)?", isPresented: $confirmsBlock, titleVisibility: .visible) {
                // TODO-COPY (#171)
                Button("Block", role: .destructive) {
                    Task {
                        if await model?.block(author.gamePlayerID) == true { close() } else { blockFailed = true }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // TODO-COPY (#171)
                Text("You won't see each other's messages.")
            }
        }
        .tint(ChromePalette.tint)
        .presentationDetents([.medium])
        .accessibilityIdentifier("sheet-boatCard")
        // One card read a sheet (T13).
        .task {
            card = await model?.boatCard(author.gamePlayerID)
            isLoading = false
        }
    }

    /// Her boat: the render once the card answers, a spinner until then, her chip if it gives none.
    @ViewBuilder private var boat: some View {
        Group {
            if let card {
                LiveryRenderView(livery: card.livery)
            } else if isLoading {
                ProgressView()
            } else {
                LiveryChipView(chip: author.chip, diameter: 72)
            }
        }
        .frame(height: LiveryRenderView.defaultSize.height)
        .accessibilityIdentifier("boatCard-render")
    }
}
