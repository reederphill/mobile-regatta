import Foundation
import Testing

/// The render-fixture record/compare guard (#62) and where CI keeps a failing reference test's render (#215):
/// `ReferencePolicy.swift` is the UI tests' own file, compiled into this target too.
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

    // MARK: - Actuals for CI to upload (#215)

    let actuals = URL(fileURLWithPath: "/runner/work/render-actuals", isDirectory: true)

    @Test func theActualsDirectoryIsWhateverTheEnvironmentNamesNotWhetherItsCI() {
        #expect(ReferencePolicy.actualsDirectory(environment: ["REFERENCE_ACTUALS_DIR": "/runner/work/render-actuals"])?.path
            == "/runner/work/render-actuals")
        // ios27.yml's app job doesn't mark itself CI, and still sets the directory.
        #expect(ReferencePolicy.actualsDirectory(environment: ["REFERENCE_ACTUALS_DIR": "/a"]) != nil)
        #expect(ReferencePolicy.actualsDirectory(environment: ["CI": "true", "GITHUB_ACTIONS": "true"]) == nil)
        #expect(ReferencePolicy.actualsDirectory(environment: [:]) == nil)
        #expect(ReferencePolicy.actualsDirectory(environment: ["REFERENCE_ACTUALS_DIR": "  "]) == nil)
    }

    @Test func theRenderLandsWhereItsReferenceLivesUnderReferences() {
        let render = ReferencePolicy.actualRender(in: actuals, device: "iPhone 17", name: "prestart")
        #expect(render.path == "/runner/work/render-actuals/iPhone 17/prestart.png")
        // The same <device>/<name>.png as References/iPhone 17/prestart.png, so adopting is a plain copy.
        #expect(render.pathComponents.suffix(2) == ["iPhone 17", "prestart.png"])
    }

    @Test func theDiffCanNotBeMistakenForAReference() {
        let render = ReferencePolicy.actualRender(in: actuals, device: "iPhone 17", name: "prestart")
        let diff = ReferencePolicy.actualDiff(in: actuals, device: "iPhone 17", name: "prestart")
        #expect(diff.path == "/runner/work/render-actuals/iPhone 17/prestart-diff.png")
        #expect(diff != render)
        // scripts/adopt-references.sh skips *-diff.png.
        #expect(diff.lastPathComponent.hasSuffix("-diff.png"))
        #expect(!render.lastPathComponent.hasSuffix("-diff.png"))
    }

    @Test func aFailedCompareLeavesTheRenderAndItsDiff() {
        #expect(ReferencePolicy.actualsAction(outcome: .differed, directory: actuals, device: "iPhone 17", name: "prestart")
            == .write(render: ReferencePolicy.actualRender(in: actuals, device: "iPhone 17", name: "prestart"),
                      diff: ReferencePolicy.actualDiff(in: actuals, device: "iPhone 17", name: "prestart")))
    }

    @Test func aMissingReferenceLeavesTheRenderAlone() {
        #expect(ReferencePolicy.actualsAction(outcome: .noReference, directory: actuals, device: "iPhone 17", name: "prestart")
            == .write(render: ReferencePolicy.actualRender(in: actuals, device: "iPhone 17", name: "prestart"), diff: nil))
    }

    @Test func aMatchClearsWhatAFailedEarlierTryLeft() {
        #expect(ReferencePolicy.actualsAction(outcome: .matched, directory: actuals, device: "iPhone 17", name: "prestart")
            == .remove([ReferencePolicy.actualRender(in: actuals, device: "iPhone 17", name: "prestart"),
                        ReferencePolicy.actualDiff(in: actuals, device: "iPhone 17", name: "prestart")]))
    }

    @Test func nothingIsLeftWithoutAnActualsDirectory() {
        for outcome in [ReferencePolicy.CompareOutcome.matched, .differed, .noReference] {
            #expect(ReferencePolicy.actualsAction(outcome: outcome, directory: nil, device: "iPhone 17", name: "prestart") == .nothing)
        }
    }
}
