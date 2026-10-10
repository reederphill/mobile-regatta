#if DEBUG
import Foundation

/// The git identity of the checkout this build was made from (#473): the main menu's footer, Debug builds only, so a
/// build on a device or simulator says which commit it is. `scripts/build-id.sh` stamps it into the built app as
/// `BuildID.txt` on every Debug build (the Regatta target's "Stamp build identity" phase); nothing is written to the
/// source tree. `LaunchOptions.showsBuildIdentity` hides it from UI tests and render fixtures.
struct BuildIdentity: Equatable {
    /// HEAD's short hash; nil when the build had no git or wasn't made from a repository.
    var commit: String?
    /// Tracked files had uncommitted changes.
    var isDirty = false
    /// nil when HEAD was detached.
    var branch: String?

    init(commit: String? = nil, isDirty: Bool = false, branch: String? = nil) {
        self.commit = commit
        self.isDirty = isDirty
        self.branch = branch
    }

    /// Parses `build-id.sh`'s `key=value` lines. A missing stamp, or one without a commit, is an unknown build.
    init(stamp: String?) {
        var values: [String: String] = [:]
        for line in (stamp ?? "").split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        guard let commit = values["commit"], !commit.isEmpty, commit != "unknown" else { return }
        self.commit = commit
        isDirty = values["dirty"] == "1"
        if let branch = values["branch"], !branch.isEmpty { self.branch = branch }
    }

    /// The footer's text: `1998032 · build/461-default-skiff8`, `1998032-dirty · detached`, or `unknown`.
    var label: String {
        guard let commit else { return "unknown" }
        return "\(commit)\(isDirty ? "-dirty" : "") · \(branch ?? "detached")"
    }

    /// The built app's stamp.
    static let current = BuildIdentity(
        stamp: Bundle.main.url(forResource: "BuildID", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) })
}
#endif
