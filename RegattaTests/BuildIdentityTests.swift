#if DEBUG
import Foundation
import Testing
@testable import Regatta

/// The main menu's build identifier (#473): what the footer says for each stamp, and when it shows.
@MainActor @Suite struct BuildIdentityTests {
    @Test func aCleanBuildOnABranchShowsTheHashAndTheBranch() {
        let identity = BuildIdentity(stamp: "commit=1998032\ndirty=0\nbranch=build/461-default-skiff8\n")
        #expect(identity == BuildIdentity(commit: "1998032", branch: "build/461-default-skiff8"))
        #expect(identity.label == "1998032 · build/461-default-skiff8")
    }

    @Test func uncommittedChangesMarkTheHashDirty() {
        #expect(BuildIdentity(stamp: "commit=1998032\ndirty=1\nbranch=main\n").label == "1998032-dirty · main")
    }

    @Test func aDetachedHeadHasNoBranch() {
        let identity = BuildIdentity(stamp: "commit=1998032\ndirty=0\nbranch=\n")
        #expect(identity.branch == nil)
        #expect(identity.label == "1998032 · detached")
        #expect(BuildIdentity(stamp: "commit=1998032\ndirty=1\n").label == "1998032-dirty · detached")
    }

    @Test(arguments: [nil, "", "commit=unknown\ndirty=0\nbranch=\n", "commit=\ndirty=1\nbranch=main\n", "not a stamp"])
    func aBuildWithoutGitIsUnknown(stamp: String?) {
        #expect(BuildIdentity(stamp: stamp) == BuildIdentity())
        #expect(BuildIdentity(stamp: stamp).label == "unknown")
    }

    @Test func aBranchNameKeepsItsEqualsSigns() {
        #expect(BuildIdentity(stamp: "commit=abc1234\ndirty=0\nbranch=fix/a=b\n").label == "abc1234 · fix/a=b")
    }

    @Test func itShowsOnAPlainLaunchAndADemoRace() {
        #expect(LaunchOptions().showsBuildIdentity)
        #expect(LaunchOptions(arguments: ["Regatta", "-demo", "-seed", "3"]).showsBuildIdentity)
    }

    @Test(arguments: [["-uitesting"], ["-fixture", "fleet"], ["-uitesting", "-fixture", "menu-home"],
                      ["-uitesting", "-fixtures", "fleet,cues"]])
    func itHidesInUITestRunsAndRenderFixtures(arguments: [String]) {
        #expect(!LaunchOptions(arguments: ["Regatta"] + arguments).showsBuildIdentity)
    }

    /// The test host is a Debug build made by the same phase: its stamp is there and parses.
    @Test func theTestHostCarriesAStamp() {
        #expect(Bundle.main.url(forResource: "BuildID", withExtension: "txt") != nil)
        #expect(!BuildIdentity.current.label.isEmpty)
    }
}
#endif
