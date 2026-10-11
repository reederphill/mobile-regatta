import ChatFilter
import Foundation
import Testing

/// #152: free text made safe to show, and the offline word list that always applies.
struct ChatTextTests {
    @Test func graphemeAndByteLimits() throws {
        #expect(try ChatText.clean(String(repeating: "b", count: 200)).count == 200)
        #expect(throws: ChatText.Refusal.tooLong) { try ChatText.clean(String(repeating: "a", count: 201)) }
        // 200 clusters, but each a family of four joined emoji: far over the byte limit.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(String(repeating: family, count: 40).count == 40)
        #expect(throws: ChatText.Refusal.tooLong) { try ChatText.clean(String(repeating: family, count: 40)) }
        // 200 two-byte letters fit both limits.
        #expect(try ChatText.clean(String(repeating: "é", count: 200)).utf8.count == 400)
        #expect(throws: ChatText.Refusal.empty) { try ChatText.clean("   \n\t ") }
        // Trimmed before it is measured.
        #expect(try ChatText.clean("  " + String(repeating: "c", count: 200) + "\n").count == 200)
    }

    @Test func controlAndBidiStripped() throws {
        // Bidi overrides and isolates, a zero-width space, a BOM, a bell and a private-use scalar all go.
        let dirty = "fair\u{202E} winds\u{2066}\u{2069}\u{200B}\u{FEFF}\u{07}\u{E000} all"
        #expect(try ChatText.clean(dirty) == "fair winds all")
        // Newlines and runs of whitespace are one space.
        #expect(try ChatText.clean("one\n\ntwo \t  three\u{2028}four") == "one two three four")
        // The joiner inside an emoji and the emoji variation selector stay.
        #expect(try ChatText.clean("ok \u{1F468}\u{200D}\u{1F469} \u{2764}\u{FE0F}") == "ok \u{1F468}\u{200D}\u{1F469} \u{2764}\u{FE0F}")
        // NFC: e + combining acute is one é.
        #expect(try ChatText.clean("cafe\u{301}") == "caf\u{E9}")
        // At most three combining marks on a base.
        let zalgo = "z" + String(repeating: "\u{0353}", count: 40) + "a"
        #expect(try ChatText.clean(zalgo).unicodeScalars.count == 5)
        // Only controls: nothing left.
        #expect(throws: ChatText.Refusal.empty) { try ChatText.clean("\u{202E}\u{200B}") }
    }

    @Test func contactsStripped() throws {
        let text = try ChatText.clean("race me https://example.com or mail sailor@example.com or call 5551234567")
        #expect(text == "race me or mail or call")
        #expect(try ChatText.clean("see www.example.org now") == "see now")
        // Only a link: nothing to post.
        #expect(throws: ChatText.Refusal.empty) { try ChatText.clean("https://example.com") }
        // Best-effort only (#314): the spaced-out forms pass.
        #expect(try ChatText.clean("5 5 5 1 2 3 4") == "5 5 5 1 2 3 4")
    }
}

struct ChatWordListTests {
    /// Stand-ins for a real list's entries: the matcher is what is tested here.
    static let list = ChatWordList(entries: ["shit", "ass", "cunt", "bitch", "asshole", "blow job", "Cabrón", "狗屎", "hell"], allowed: ["hell"])

    @Test func wholeWordsBlock() {
        for text in ["shit", "oh SHIT.", "what an ass", "you (bitch)", "cabron", "CABRÓN!"] {
            #expect(Self.list.blocks(text), "\(text)")
        }
        #expect(!Self.list.blocks("fair winds and a following sea"))
        #expect(!ChatWordList.empty.blocks("shit"))
    }

    /// Words that only contain a list word pass.
    @Test func scunthorpe() {
        for text in ["Scunthorpe", "assassin", "classic bass", "passing the glasses", "shitake", "Hitchcock", "cockpit", "assess", "he'll pass"] {
            #expect(!Self.list.blocks(text), "\(text)")
        }
    }

    @Test func lookAlikes() {
        for text in ["sh1t", "$hit", "a$$", "@ss", "b!tch", "sh!t!!", "5h17", "ＳＨＩＴ"] {
            #expect(Self.list.blocks(text), "\(text)")
        }
        // A trailing "!" is punctuation.
        #expect(Self.list.blocks("shit!"))
    }

    /// Spelled out or stretched: only for list words of five letters or more.
    @Test func squashedForms() {
        for text in ["b.i.t.c.h", "b-i-t-c-h", "b i t c h", "biiiitch", "you a s s h o l e", "assssshole"] {
            #expect(Self.list.blocks(text), "\(text)")
        }
        // Shorter words aren't matched squashed: "a s s" and "s.h.i.t" pass, and so does "a bit chilly".
        for text in ["a s s", "s.h.i.t", "a bit chilly", "it's hit or miss"] {
            #expect(!Self.list.blocks(text), "\(text)")
        }
    }

    @Test func phrasesAndUnspacedScripts() {
        #expect(Self.list.blocks("a blow job then"))
        #expect(Self.list.blocks("BLOW, JOB"))
        #expect(!Self.list.blocks("blow the job"))
        #expect(Self.list.blocks("这是狗屎吗"))
    }

    @Test func allowedEntriesAndExtras() {
        #expect(!Self.list.blocks("hell of a race"))
        let more = Self.list.adding(["contract filtered phrase"])
        #expect(more.blocks("a Contract  filtered phrase here") && more.blocks("shit"))
        #expect(!Self.list.blocks("contract filtered phrase"))
    }

    /// The vendored list: it loads, blocks, and passes the Scunthorpe words and the quick-chat phrases.
    @Test func theBundledListLoads() throws {
        guard let list = try? ChatWordList.bundled() else {
            // The list isn't in this build yet (WordLists/VENDORED.md): a server outside dev refuses to start without it
            // (`LobbyEndpointTests.aBuildWithoutTheWordListStartsOnlyInDev`). Take this branch out once it is vendored.
            withKnownIssue("the vendored word list isn't in the build yet") {
                Issue.record("Sources/ChatFilter/WordLists has no <language>.txt")
            }
            return
        }
        #expect(list.count > 500)
        #expect(list.blocks("shit") && list.blocks("sh1t"))
        for text in ["Scunthorpe", "assassin", "classic", "cockpit", "fair winds", "good race", "one more?", "gg", "well sailed", "starboard!"] {
            #expect(!list.blocks(text), "\(text)")
        }
    }
}

struct CircuitBreakerTests {
    @Test func opensAfterFiveFailuresAndProbes() {
        var breaker = CircuitBreaker()
        var asked: [Bool] = []
        for _ in 0..<4 {
            asked.append(breaker.allows(at: 0))
            breaker.failed(at: 0)
        }
        asked.append(breaker.allows(at: 0))
        #expect(asked == [true, true, true, true, true] && !breaker.isOpen)
        breaker.failed(at: 0)
        #expect(breaker.isOpen)
        // Closed to every call for 30 s; then one probe, and a second call meanwhile is refused.
        asked = [breaker.allows(at: 1), breaker.allows(at: 29.9), breaker.allows(at: 30), breaker.allows(at: 30)]
        #expect(asked == [false, false, true, false])
        // The probe fails: open again, for another 30 s.
        breaker.failed(at: 31)
        asked = [breaker.allows(at: 60), breaker.allows(at: 61)]
        #expect(asked == [false, true])
        breaker.succeeded()
        let after = breaker.allows(at: 61)
        #expect(!breaker.isOpen && after)
    }

    @Test func aSuccessResetsTheCount() {
        var breaker = CircuitBreaker()
        for _ in 0..<4 { breaker.failed(at: 0) }
        breaker.succeeded()
        for _ in 0..<4 { breaker.failed(at: 0) }
        #expect(!breaker.isOpen)
    }
}
