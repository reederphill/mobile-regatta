import Foundation

// `regatta-admin`'s commands (#154), as the requests they make to the admin tool's routes. Foundation only, so the
// command line and the tests share it.

/// One request to the admin tool: a method, a path under `/admin`, and its query.
public struct AdminRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]

    public init(method: String, path: String, query: [URLQueryItem] = []) {
        self.method = method
        self.path = path
        self.query = query
    }

    /// The request's URL on the server at `base` (`http://host:port`).
    public func url(on base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath = components.percentEncodedPath.trimmingSuffix("/") + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}

public enum AdminCommandError: Error, Equatable, CustomStringConvertible {
    case usage(String)

    public var description: String {
        switch self {
        case .usage(let message): message
        }
    }
}

/// A command line's words as the request they make.
public enum AdminCommand {
    public static let usage = """
        usage: regatta-admin <command>
          queue [limit]                       what waits for a decision, the first due first
          report <report-id>                  a report, the reported player's penalties and reports, and a race report's race
          decide <report-id> <decision>       dismiss, uphold_chat, override_nickname, or a racing penalty
          player <player-id>                  a player's chat standing, penalties and the reports on her
          penalize <player-id> <penalty>      warning, suspension_24h, suspension_7d, permanent or rating_reset
          mute <player-id>                    the next step of the chat ladder
          nickname-override <player-id>       she shows as "Sailor" and her sail number
          lift <player-id> <penalty-id>       lifts one of her penalties
          audit [player-id]                   what admins did, newest first
        environment: REGATTA_ADMIN_URL (default http://127.0.0.1:8080), REGATTA_ADMIN_TOKEN (required)
        """

    public static func request(_ words: [String]) throws(AdminCommandError) -> AdminRequest {
        guard let command = words.first else { throw .usage(usage) }
        let args = Array(words.dropFirst())
        func need(_ count: Int) throws(AdminCommandError) {
            guard args.count == count else { throw .usage("\(command) takes \(count) argument\(count == 1 ? "" : "s")\n\n\(usage)") }
        }
        func id(_ text: String, _ what: String) throws(AdminCommandError) -> String {
            guard let number = Int64(text), number > 0 else { throw .usage("\(what) must be a number, not \(text)") }
            return String(number)
        }
        switch command {
        case "queue":
            guard args.count <= 1 else { throw .usage(usage) }
            return AdminRequest(method: "GET", path: "/admin/queue", query: args.first.map { [URLQueryItem(name: "limit", value: $0)] } ?? [])
        case "report":
            try need(1)
            return AdminRequest(method: "GET", path: "/admin/reports/\(try id(args[0], "a report id"))")
        case "decide":
            try need(2)
            return AdminRequest(method: "POST", path: "/admin/reports/\(try id(args[0], "a report id"))/decide",
                                query: [URLQueryItem(name: "decision", value: args[1])])
        case "player":
            try need(1)
            return AdminRequest(method: "GET", path: "/admin/players/\(segment(args[0]))")
        case "penalize":
            try need(2)
            return AdminRequest(method: "POST", path: "/admin/players/\(segment(args[0]))/penalize",
                                query: [URLQueryItem(name: "penalty", value: args[1])])
        case "mute":
            try need(1)
            return AdminRequest(method: "POST", path: "/admin/players/\(segment(args[0]))/mute")
        case "nickname-override":
            try need(1)
            return AdminRequest(method: "POST", path: "/admin/players/\(segment(args[0]))/nickname-override")
        case "lift":
            try need(2)
            return AdminRequest(method: "POST", path: "/admin/players/\(segment(args[0]))/penalties/\(try id(args[1], "a penalty id"))/lift")
        case "audit":
            guard args.count <= 1 else { throw .usage(usage) }
            return AdminRequest(method: "GET", path: "/admin/audit", query: args.first.map { [URLQueryItem(name: "player", value: $0)] } ?? [])
        default:
            throw .usage("unknown command \(command)\n\n\(usage)")
        }
    }

    /// A player id as one path segment: a teamPlayerID may hold any character.
    static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~:"))) ?? text
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
