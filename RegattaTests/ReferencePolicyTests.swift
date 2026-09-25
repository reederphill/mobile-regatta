import Testing

/// The render-fixture record/compare guard (#62): `ReferencePolicy.swift` is the UI tests' own file,
/// compiled into this target too.
@Suite struct ReferencePolicyTests {
    @Test func recordsOnlyWhenAskedAndNotInCI() {
        #expect(ReferencePolicy.shouldRecord(flag: true, isCI: false))
        #expect(!ReferencePolicy.shouldRecord(flag: true, isCI: true))
        #expect(!ReferencePolicy.shouldRecord(flag: false, isCI: false))
        #expect(!ReferencePolicy.shouldRecord(flag: false, isCI: true))
    }

    @Test func recordingInCIIsRefusedNotIgnored() {
        #expect(ReferencePolicy.mode(flag: true, isCI: true) == .refused)
        #expect(ReferencePolicy.mode(flag: false, isCI: true) == .compare)
    }

    @Test func eitherCIOrGitHubActionsMarksCI() {
        #expect(ReferencePolicy.isCI(environment: ["CI": "true"]))
        #expect(ReferencePolicy.isCI(environment: ["GITHUB_ACTIONS": "true"]))
        #expect(ReferencePolicy.isCI(environment: ["CI": "1"]))
        #expect(ReferencePolicy.isCI(environment: ["CI": "false", "GITHUB_ACTIONS": "true"]))
        #expect(!ReferencePolicy.isCI(environment: [:]))
        #expect(!ReferencePolicy.isCI(environment: ["CI": "", "GITHUB_ACTIONS": "false"]))
        #expect(!ReferencePolicy.isCI(environment: ["CI": "0"]))
    }

    @Test func recordingIsAskedForByArgumentOrEnvironment() {
        #expect(ReferencePolicy.recordRequested(arguments: ["runner", "-recordReferences"], environment: [:]))
        #expect(ReferencePolicy.recordRequested(arguments: [], environment: ["RECORD_REFERENCES": "1"]))
        #expect(!ReferencePolicy.recordRequested(arguments: ["runner"], environment: ["RECORD_REFERENCES": "0"]))
    }

    @Test func aMissingReferenceFailsInCIAndSkipsLocally() {
        #expect(ReferencePolicy.missingReference(isCI: true) == .fail)
        #expect(ReferencePolicy.missingReference(isCI: false) == .skip)
    }
}
