import Foundation

/// When a render-fixture reference test (#62) records, compares, skips or fails, and where CI keeps a failing
/// test's render (#215). Pure, so `RegattaTests` compiles this file too and tests it without a simulator.
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

    // MARK: - Actuals for CI to upload (#215)

    /// The directory a reference test leaves its render in when the compare fails, for CI to upload as the
    /// `render-actuals` artifact and `scripts/adopt-references.sh` to copy into `References/`. The test runner
    /// sees it through `TEST_RUNNER_REFERENCE_ACTUALS_DIR` in `xcodebuild`'s environment; local runs don't set it.
    static let actualsDirectoryVariable = "REFERENCE_ACTUALS_DIR"

    /// The actuals directory `environment` names, or nil when it names none (unset or blank).
    static func actualsDirectory(environment: [String: String]) -> URL? {
        guard let path = environment[actualsDirectoryVariable]?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// How a reference test's compare came out.
    enum CompareOutcome: Equatable {
        /// The render matched the committed reference.
        case matched
        /// The render differed from the committed reference.
        case differed
        /// This device has no committed reference, or one that doesn't decode as a PNG.
        case noReference
    }

    /// Where a reference test's render goes in the actuals directory: `<device>/<name>.png`, the path its
    /// reference has under `References/`, so `scripts/adopt-references.sh` copies it across as is.
    static func actualRender(in directory: URL, device: String, name: String) -> URL {
        directory.appendingPathComponent(device, isDirectory: true).appendingPathComponent("\(name).png")
    }

    /// Where the diff goes: beside the render as `<name>-diff.png`, which `scripts/adopt-references.sh`
    /// skips, so a diff can't be adopted as a reference.
    static func actualDiff(in directory: URL, device: String, name: String) -> URL {
        directory.appendingPathComponent(device, isDirectory: true).appendingPathComponent("\(name)-diff.png")
    }

    /// What a reference test does with the actuals directory once its compare is done.
    enum ActualsAction: Equatable {
        /// No actuals directory (a local run): nothing to do.
        case nothing
        /// Write the render, and the diff when there was a reference to diff against.
        case write(render: URL, diff: URL?)
        /// The render matched: remove any render and diff an earlier, failed try of the test left (CI retries
        /// a failed test), so a flake that passed on retry can't be adopted.
        case remove([URL])
    }

    static func actualsAction(outcome: CompareOutcome, directory: URL?, device: String, name: String) -> ActualsAction {
        guard let directory else { return .nothing }
        let render = actualRender(in: directory, device: device, name: name)
        let diff = actualDiff(in: directory, device: device, name: name)
        switch outcome {
        case .matched: return .remove([render, diff])
        case .differed: return .write(render: render, diff: diff)
        case .noReference: return .write(render: render, diff: nil)
        }
    }
}
