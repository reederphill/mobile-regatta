import Foundation

/// The offline censor list (#152, owner 2026-10-11): it always applies, whatever becomes of the classifier.
///
/// A message is blocked when one of its words is on the list. Words are compared folded (case, diacritics, width)
/// and whole: "Scunthorpe", "classic" and "cockpit" pass. Three disguises are seen through:
///
/// - look-alikes: digits and symbols standing for letters (`sh1t`, `a$$`, `@ss`);
/// - for list words of `squashLength` letters or more only: letters split by punctuation (`b.i.t.c.h`) or by spaces
///   (`b i t c h`), and stretched letters (`biiitch`). Shorter words aren't matched this way: "he'll" would be one.
///
/// List entries of several words match as a run of whole words. Entries in scripts written without spaces (Han,
/// kana) match anywhere. Best-effort by design: moderation (#153) is the backstop.
public struct ChatWordList: Sendable {
    public static let squashLength = 5

    private let words: Set<String>
    /// Words of `squashLength` or more, with stretched letters collapsed.
    private let squashed: Set<String>
    private let phrases: [String]
    private let unspaced: [String]

    /// How many entries it holds.
    public var count: Int { words.count + phrases.count + unspaced.count }
    public var isEmpty: Bool { count == 0 }

    /// A list of `entries` (one word or phrase each), less the entries of `allowed`.
    public init(entries: [String], allowed: [String] = []) {
        let allowed = Set(allowed.map(Self.fold))
        var words: Set<String> = [], squashed: Set<String> = [], phrases: [String] = [], unspaced: [String] = []
        for entry in entries {
            let folded = Self.fold(entry).trimmingCharacters(in: .whitespaces)
            guard !folded.isEmpty, !allowed.contains(folded) else { continue }
            if folded.unicodeScalars.contains(where: Self.isUnspacedScript) {
                unspaced.append(folded.filter { !$0.isWhitespace })
                continue
            }
            let plain = Self.tokens(folded, mapping: false), mapped = Self.tokens(folded, mapping: true)
            if plain.count > 1 {
                phrases.append(" " + plain.joined(separator: " ") + " ")
                continue
            }
            for word in plain + (mapped.count == 1 ? mapped : []) where !allowed.contains(word) {
                words.insert(word)
                if word.count >= Self.squashLength { squashed.insert(Self.collapse(word)) }
            }
        }
        self.words = words
        self.squashed = squashed
        self.phrases = phrases
        self.unspaced = unspaced
    }

    /// The list and `more` together.
    public func adding(_ more: [String]) -> ChatWordList { ChatWordList(self, ChatWordList(entries: more)) }

    private init(_ a: ChatWordList, _ b: ChatWordList) {
        words = a.words.union(b.words)
        squashed = a.squashed.union(b.squashed)
        phrases = a.phrases + b.phrases
        unspaced = a.unspaced + b.unspaced
    }

    public static let empty = ChatWordList(entries: [])

    // MARK: Matching

    /// Whether the list blocks `text`.
    public func blocks(_ text: String) -> Bool {
        guard !isEmpty else { return false }
        let folded = Self.fold(text)
        let chunks = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var plain: [String] = []
        var letters: [String] = []
        for chunk in chunks {
            let plainTokens = Self.tokens(chunk, mapping: false)
            plain += plainTokens
            var candidates = plainTokens + Self.tokens(chunk, mapping: true)
            // "shit!!": the trailing symbols are punctuation, not letters.
            let trimmed = String(chunk.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed())
            if trimmed.count != chunk.count { candidates += Self.tokens(trimmed, mapping: true) }
            if candidates.contains(where: words.contains) { return true }
            // Split by punctuation inside one chunk, or stretched.
            let joined = Self.tokens(chunk, mapping: true).joined()
            for candidate in candidates + [joined] where candidate.count >= Self.squashLength {
                if squashed.contains(Self.collapse(candidate)) { return true }
            }
            letters.append(joined.count == 1 ? joined : " ")
        }
        // Spelled out with spaces: runs of single letters.
        for run in letters.joined().split(separator: " ") where run.count >= Self.squashLength {
            if squashed.contains(Self.collapse(String(run))) { return true }
        }
        if !phrases.isEmpty {
            let line = " " + plain.joined(separator: " ") + " "
            if phrases.contains(where: line.contains) { return true }
        }
        if !unspaced.isEmpty {
            let line = folded.filter { !$0.isWhitespace }
            if unspaced.contains(where: line.contains) { return true }
        }
        return false
    }

    // MARK: Normalising

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Digits and symbols that stand for a letter.
    static let lookAlikes: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i", "+": "t",
    ]

    /// The runs of letters and digits in `text`; with `mapping`, look-alikes read as their letters first.
    static func tokens(_ text: String, mapping: Bool) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            let read = mapping ? (lookAlikes[character] ?? character) : character
            if read.isLetter || read.isNumber {
                current.append(read)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// `word` with each run of one letter down to a single one.
    static func collapse(_ word: String) -> String {
        var out = ""
        for character in word where out.last != character { out.append(character) }
        return out
    }

    /// Han, hiragana, katakana: written without spaces between words.
    static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    // MARK: The bundled list

    public enum BundleError: Error, Equatable, Sendable, CustomStringConvertible {
        /// The build carries no word list: `Sources/ChatFilter/WordLists` has no `.txt` list files.
        case missing

        public var description: String { "the chat word list isn't bundled (Sources/ChatFilter/WordLists/*.txt)" }
    }

    /// The names of the list files a build must carry (the vendored list's languages); `allow.txt` is ours.
    public static let languages = ["en", "es", "fr", "ar", "zh", "ga"]
    static let allowFile = "allow"

    /// The list this build carries: every `<language>.txt` under `WordLists`, less the entries of `allow.txt`. One
    /// entry per line; blank lines and lines starting with `#` are skipped. Throws `missing` when there is none.
    public static func bundled() throws -> ChatWordList {
        guard let directory = Bundle.module.url(forResource: "WordLists", withExtension: nil) else { throw BundleError.missing }
        func lines(_ name: String) -> [String]? {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name + ".txt"), encoding: .utf8) else { return nil }
            return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
        }
        let entries = languages.compactMap(lines).flatMap { $0 }
        let list = ChatWordList(entries: entries, allowed: lines(allowFile) ?? [])
        guard !list.isEmpty else { throw BundleError.missing }
        return list
    }
}
