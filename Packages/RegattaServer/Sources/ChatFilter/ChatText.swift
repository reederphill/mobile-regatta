import Foundation

/// Free text as the lobby takes it (#17, #152), before any filter: what a player typed, made safe to show.
///
/// `clean` runs in this order: Unicode clean-up (`sanitize`), then the length limits on that text, then links, email
/// addresses and phone numbers are stripped (`stripContacts`). Quick-chat never comes through here.
public enum ChatText {
    /// The limits a post must meet after `sanitize`: grapheme clusters, and UTF-8 bytes (so 200 clusters of stacked
    /// emoji can't carry kilobytes).
    public static let maxCharacters = 200
    public static let maxBytes = 800
    /// Combining marks kept after one base character; more are dropped ("zalgo" text).
    public static let maxCombiningMarks = 3

    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing left once cleaned.
        case empty
        /// Over `maxCharacters` or `maxBytes`.
        case tooLong
    }

    /// The text to filter, store and show. Throws when nothing is left or it is too long.
    public static func clean(_ raw: String) throws(Refusal) -> String {
        let text = sanitize(raw)
        guard !text.isEmpty else { throw .empty }
        guard text.count <= maxCharacters, text.utf8.count <= maxBytes else { throw .tooLong }
        let stripped = stripContacts(text)
        guard !stripped.isEmpty else { throw .empty }
        return stripped
    }

    /// NFC; control and format characters dropped (bidi controls among them) except the zero-width joiner; unassigned
    /// and private-use scalars dropped; every run of whitespace and newlines one space; at most `maxCombiningMarks`
    /// combining marks per base (the emoji variation selector doesn't count); trimmed.
    public static func sanitize(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var marks = 0
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace || scalar == "\u{2028}" || scalar == "\u{2029}" {
                pendingSpace = true
                continue
            }
            switch properties.generalCategory {
            case .control, .format:
                guard scalar == zeroWidthJoiner else { continue }
            case .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator:
                continue
            case .nonspacingMark, .spacingMark, .enclosingMark:
                if scalar != variationSelector16 {
                    marks += 1
                    guard marks <= maxCombiningMarks else { continue }
                }
            default:
                marks = 0
            }
            if pendingSpace {
                if !out.isEmpty { out.append(" ") }
                pendingSpace = false
                // A mark can't sit on a space.
                if marks > 0 { marks = maxCombiningMarks }
            }
            out.append(scalar)
        }
        return String(out)
    }

    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
    private static let variationSelector16: Unicode.Scalar = "\u{FE0F}"

    /// Drops the words that are links, email addresses or phone numbers (#17). Best-effort, by design (owner ruling,
    /// #314): spaced-out digits or "name at mail dot com" get through, and moderation (#153) is the backstop. The same
    /// rule as `ScriptedLobbyService.stripContacts`, which the app's UI tests run on.
    public static func stripContacts(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).filter { word in
            let lowered = word.lowercased()
            let isLink = lowered.contains("://") || lowered.hasPrefix("www.")
                || [".com", ".net", ".org", ".io"].contains { lowered.hasSuffix($0) || lowered.contains($0 + "/") }
            let isEmail = word.contains("@") && word.contains(".")
            let isPhone = word.filter(\.isNumber).count >= 7
            return !isLink && !isEmail && !isPhone
        }.joined(separator: " ")
    }
}
