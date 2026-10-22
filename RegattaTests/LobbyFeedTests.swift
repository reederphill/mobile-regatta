import Foundation
import RegattaCore
import RegattaServices
import Testing
@testable import Regatta

/// The lobby's lines (#142): the newest 50 of the last hour by arrival, one per id, hidden at once, her not-sent
/// lines kept here only, and the long-press menu.
@MainActor @Suite struct LobbyFeedTests {
    static let start = Date(timeIntervalSince1970: 2_000_000_000)
    static let me = LobbyAuthor(gamePlayerID: GamePlayerID("G:me"), nickname: "Sailor", rating: Rating(value: 1500, isProvisional: true),
                                chip: LiveryChip(deck: SwatchID("sky-blue"), sail: SwatchID("white")))
    static let wren = LobbyAuthor(gamePlayerID: GamePlayerID("G:wren"), nickname: "Wren", rating: Rating(value: 1610, isProvisional: false),
                                  chip: LiveryChip(deck: SwatchID("charcoal"), sail: SwatchID("white")))

    static func post(_ id: String, by author: LobbyAuthor = wren, _ text: String = "hi", delivery: Delivery = .sent) -> LobbyMessage {
        LobbyMessage(id: MessageID(id), kind: .post(LobbyPost(author: author, body: .text(text), delivery: delivery)))
    }

    static func gun(_ id: String) -> LobbyMessage {
        LobbyMessage(id: MessageID(id), kind: .system(.gun(venue: "Fellmere", boats: 10, humans: 2)))
    }

    private func ids(_ feed: LobbyFeed) -> [String] { feed.lines.map(\.id.rawValue) }

    @Test func keepsTheNewestFifty() {
        var feed = LobbyFeed()
        feed.replace(with: (1...60).map { Self.post("m\($0)") }, at: Self.start)
        #expect(ids(feed) == (11...60).map { "m\($0)" })
        feed.receive(Self.post("m61"), at: Self.start.addingTimeInterval(5))
        #expect(feed.lines.count == 50)
        #expect(ids(feed).first == "m12" && ids(feed).last == "m61", "a 51st line drops the oldest")
    }

    @Test func dropsLinesPastTheHourOnTheNextChangeOrTick() {
        var feed = LobbyFeed()
        feed.replace(with: [Self.gun("old")], at: Self.start)
        feed.receive(Self.post("newer"), at: Self.start.addingTimeInterval(1800))
        feed.trim(now: Self.start.addingTimeInterval(3600))
        #expect(ids(feed) == ["old", "newer"], "an hour to the second still shows")
        feed.trim(now: Self.start.addingTimeInterval(3601))
        #expect(ids(feed) == ["newer"])
        feed.receive(Self.post("latest"), at: Self.start.addingTimeInterval(5401 + 1800))
        #expect(ids(feed) == ["latest"], "a change trims too")
    }

    @Test func herPostAndItsEchoAreOneLine() {
        var feed = LobbyFeed()
        let mine = Self.post("own-1", by: Self.me, "fair winds")
        feed.receive(mine, at: Self.start)
        feed.receive(mine, at: Self.start.addingTimeInterval(1))
        #expect(ids(feed) == ["own-1"])
        #expect(feed.lines[0].arrivedAt == Self.start)
    }

    @Test func aRemovedLineLeavesNoStub() {
        var feed = LobbyFeed()
        feed.replace(with: [Self.gun("g"), Self.post("a"), Self.post("b")], at: Self.start)
        feed.remove(MessageID("a"))
        #expect(ids(feed) == ["g", "b"])
        feed.remove(MessageID("unknown"))
        #expect(ids(feed) == ["g", "b"], "removing what isn't there is a no-op")
    }

    @Test func hidingAnAuthorDropsHerLinesNowAndLater() {
        var feed = LobbyFeed()
        let kestrel = LobbyAuthor(gamePlayerID: GamePlayerID("G:kestrel"), nickname: "Kestrel", rating: Rating(value: 1500, isProvisional: true),
                                  chip: Self.wren.chip)
        feed.replace(with: [Self.gun("g"), Self.post("w1"), Self.post("k1", by: kestrel), Self.post("w2")], at: Self.start)
        feed.hide(author: Self.wren.gamePlayerID)
        #expect(ids(feed) == ["g", "k1"])
        feed.receive(Self.post("w3"), at: Self.start)
        feed.merge(history: [Self.gun("g"), Self.post("w1"), Self.post("k1", by: kestrel)], at: Self.start)
        #expect(ids(feed) == ["g", "k1"], "nor from the feed or a history read")

        feed.hide(message: MessageID("k1"))
        #expect(ids(feed) == ["g"])
        feed.receive(Self.post("k1", by: kestrel), at: Self.start)
        #expect(ids(feed) == ["g"], "a reported line stays gone")
    }

    @Test func notSentLinesAreHersAloneAndKeptInOrder() {
        var feed = LobbyFeed()
        feed.replace(with: [Self.gun("g"), Self.post("a")], at: Self.start)
        feed.receive(Self.post("own-1", by: Self.me, "badword", delivery: .notSent), at: Self.start)
        feed.receive(Self.post("b"), at: Self.start)
        #expect(ids(feed) == ["g", "a", "own-1", "b"])
        #expect(feed.lines[2].isNotSent && !feed.lines[1].isNotSent)
        // A reopen's read never has it: it stays where it was.
        feed.merge(history: [Self.gun("g"), Self.post("a"), Self.post("b"), Self.post("c")], at: Self.start)
        #expect(ids(feed) == ["g", "a", "own-1", "b", "c"])
        // The read after the silence window starts again.
        feed.replace(with: [Self.post("c")], at: Self.start)
        #expect(ids(feed) == ["c"])
    }

    @Test func aReopensReadDropsWhatWasTakenDownMeanwhile() {
        var feed = LobbyFeed()
        feed.replace(with: [Self.post("a"), Self.post("b")], at: Self.start)
        let later = Self.start.addingTimeInterval(60)
        feed.merge(history: [Self.post("b"), Self.post("c")], at: later)
        #expect(ids(feed) == ["b", "c"])
        #expect(feed.lines[0].arrivedAt == Self.start && feed.lines[1].arrivedAt == later, "kept lines keep their time")
    }

    @Test func onlyAnotherPlayersSentPostHasAMenu() {
        let me = Self.me.gamePlayerID
        #expect(LobbyFeed.actions(for: Self.post("w"), me: me) == [.report, .block])
        #expect(LobbyFeed.actions(for: Self.post("o", by: Self.me), me: me).isEmpty, "her own line")
        #expect(LobbyFeed.actions(for: Self.post("n", by: Self.me, delivery: .notSent), me: me).isEmpty, "her not-sent line")
        #expect(LobbyFeed.actions(for: Self.post("n", by: Self.me, delivery: .notSent), me: nil).isEmpty)
        #expect(LobbyFeed.actions(for: Self.gun("g"), me: me).isEmpty, "a system line")
        #expect(LobbyFeed.actions(for: LobbyMessage(id: MessageID("w"), kind: .system(.winner(venue: "Fellmere", nickname: "Wren"))),
                                  me: me).isEmpty)
    }
}

/// The composer's limits and states (#142, rows a-f).
@MainActor @Suite struct LobbyComposerTests {
    static let start = Date(timeIntervalSince1970: 2_000_000_000)

    static func open() -> LobbyComposer {
        var composer = LobbyComposer()
        composer.canPostFreeText = true
        return composer
    }

    @Test func twoHundredCharactersFitAndTwoHundredAndOneDont() {
        var composer = Self.open()
        composer.type(String(repeating: "a", count: 200))
        #expect(composer.text.count == 200 && composer.remaining == 0)
        #expect(composer.canSend(now: Self.start))
        composer.type(String(repeating: "a", count: 201))
        #expect(composer.text.count == 200, "typing stops at 200")
        #expect(LobbyComposer.fits(String(repeating: "a", count: 200)))
        #expect(!LobbyComposer.fits(String(repeating: "a", count: 201)))
        #expect(LobbyComposer.fits("  " + String(repeating: "a", count: 200) + "  "), "counted after trimming")
    }

    @Test func eightHundredBytesCapItToo() {
        // 👋 is 4 bytes: 200 of them are 800, the server's byte cap.
        #expect(LobbyComposer.fits(String(repeating: "👋", count: 200)))
        // A family emoji is one character of 18 bytes: 45 are 810.
        let family = "👨‍👩‍👧"
        #expect(family.count == 1 && family.utf8.count == 18)
        #expect(LobbyComposer.fits(String(repeating: family, count: 44)))
        #expect(!LobbyComposer.fits(String(repeating: family, count: 45)), "45 characters, but 810 bytes")
        var composer = Self.open()
        composer.type(String(repeating: family, count: 45))
        #expect(composer.text.count == 44 && composer.remaining == 2, "cut to fit: 8 bytes left, two 4-byte characters at most")
    }

    @Test func whitespaceCantSendAndTheCounterShowsInTheLastTwenty() {
        var composer = Self.open()
        composer.type("   \n ")
        #expect(!composer.canSend(now: Self.start))
        composer.type("hello")
        #expect(composer.canSend(now: Self.start))
        #expect(composer.remaining == 195 && !composer.showsCounter)
        composer.type(String(repeating: "a", count: 179))
        #expect(composer.remaining == 21 && !composer.showsCounter)
        composer.type(String(repeating: "a", count: 180))
        #expect(composer.remaining == 20 && composer.showsCounter)
    }

    @Test func aPostRestsTheComposerForThreeSeconds() {
        var composer = Self.open()
        composer.type("hello")
        composer.posted(at: Self.start, clearingText: true)
        #expect(composer.text.isEmpty)
        composer.type("again")
        for second in 0..<3 {
            let now = Self.start.addingTimeInterval(TimeInterval(second))
            #expect(composer.mode(now: now) == .resting)
            #expect(!composer.canSend(now: now) && !composer.quickChatEnabled(now: now))
            #expect(composer.fieldEnabled(now: now), "typing allowed")
        }
        let after = Self.start.addingTimeInterval(3)
        #expect(composer.mode(now: after) == .open)
        #expect(composer.canSend(now: after) && composer.quickChatEnabled(now: after))
    }

    @Test func aShortRefusalRestsAndALongOneIsTheCooldown() {
        var composer = Self.open()
        composer.type("kept")
        composer.refused(.rateLimited(retryAfterSeconds: 2), at: Self.start)
        #expect(composer.mode(now: Self.start.addingTimeInterval(1)) == .resting, "dimmed, no notice")
        #expect(composer.mode(now: Self.start.addingTimeInterval(2)) == .open)

        composer.refused(.rateLimited(retryAfterSeconds: 30), at: Self.start)
        for second in [0, 15, 29] {
            let now = Self.start.addingTimeInterval(TimeInterval(second))
            #expect(composer.mode(now: now) == .cooldown)
            #expect(!composer.fieldEnabled(now: now) && !composer.quickChatEnabled(now: now) && !composer.canSend(now: now))
        }
        #expect(composer.text == "kept", "her text is kept")
        #expect(composer.mode(now: Self.start.addingTimeInterval(30)) == .open)
        #expect(composer.nextChange(after: Self.start) == Self.start.addingTimeInterval(2), "the rest first")
        #expect(composer.nextChange(after: Self.start.addingTimeInterval(2)) == Self.start.addingTimeInterval(30))
    }

    @Test func mutedAndBannedTurnEverythingOff() {
        var composer = Self.open()
        let until = Self.start.addingTimeInterval(86_400)
        composer.standing = .muted(until: Int64(until.timeIntervalSince1970), isAutomatic: true)
        #expect(composer.mode(now: Self.start) == .muted(until: until))
        #expect(!composer.quickChatEnabled(now: Self.start) && !composer.fieldEnabled(now: Self.start))
        #expect(composer.mode(now: until) == .open, "the mute over")
        composer.standing = .banned
        #expect(composer.mode(now: Self.start) == .banned)
        #expect(!composer.quickChatEnabled(now: Self.start) && !composer.fieldEnabled(now: Self.start))
        // The server's answers say the same.
        var refused = Self.open()
        refused.refused(.banned, at: Self.start)
        #expect(refused.mode(now: Self.start) == .banned)
        refused = Self.open()
        refused.refused(.muted(until: Int64(until.timeIntervalSince1970)), at: Self.start)
        #expect(refused.mode(now: Self.start) == .muted(until: until))
    }

    @Test func lockedFreeTextLeavesQuickChat() {
        var composer = LobbyComposer()
        #expect(composer.mode(now: Self.start) == .locked)
        #expect(composer.quickChatEnabled(now: Self.start) && !composer.fieldEnabled(now: Self.start))
        composer.type("hello")
        #expect(!composer.canSend(now: Self.start))
        #expect(LobbyComposerView.placeholder(canPostFreeText: false) == "Free chat opens after your first online race")
    }

    @Test func theServersTooLongReadsZero() {
        var composer = Self.open()
        composer.type("hello")
        composer.refused(.tooLong(limit: 200), at: Self.start)
        #expect(composer.remaining == 0 && composer.showsCounter && !composer.canSend(now: Self.start))
        composer.type("hell")
        #expect(composer.remaining == 196 && composer.canSend(now: Self.start), "an edit clears it")
    }
}
