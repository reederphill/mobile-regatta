import Foundation

/// When a render-fixture reference test (#62) records, compares, skips or fails. Pure, so `RegattaTests`
/// compiles this file too and tests it without a simulator.
enum ReferencePolicy {
    /// What a reference test does with its render.
    enum Mode: Equatable {
        /// Diff the render against the committed reference.
        case compare
        /// Rewrite the reference (`-recordReferences`, local only).
        case record
        /// Recording was asked for in CI: fail, never write.
        case refused
    }

    /// What a reference test does when this device has no committed reference.
    enum MissingReference: Equatable {
        /// Locally: attach the render and skip, so a new fixture can be recorded.
        case skip
        /// In CI: fail, so a missing or misnamed reference can't pass silently.
        case fail
    }

    /// The environment variables that mark a CI run. The test runner sees them through `TEST_RUNNER_`
    /// variables in `xcodebuild`'s environment (ci.yml sets both).
    static let ciVariables = ["CI", "GITHUB_ACTIONS"]

    /// Whether `environment` is a CI run: any of `ciVariables` set to something other than empty, `0` or `false`.
    static func isCI(environment: [String: String]) -> Bool {
        ciVariables.contains { key in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
            return !["", "0", "false", "no"].contains(value)
        }
    }

    /// Whether the run asked to record: `-recordReferences` in the arguments or `RECORD_REFERENCES=1`.
    static func recordRequested(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("-recordReferences") || environment["RECORD_REFERENCES"] == "1"
    }

    /// Whether a reference test records: only when asked, and never in CI.
    static func shouldRecord(flag: Bool, isCI: Bool) -> Bool {
        mode(flag: flag, isCI: isCI) == .record
    }

    static func mode(flag: Bool, isCI: Bool) -> Mode {
        switch (flag, isCI) {
        case (false, _): .compare
        case (true, false): .record
        case (true, true): .refused
        }
    }

    static func missingReference(isCI: Bool) -> MissingReference {
        isCI ? .fail : .skip
    }
}
