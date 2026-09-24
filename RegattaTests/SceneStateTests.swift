import SwiftUI
import Testing
import UIKit
@testable import Regatta

@MainActor @Suite struct SceneStateTests {
    @Test func orientationLocksOnlyWhileTheRaceSequenceShows() {
        let state = SceneState()
        let controller = RootHostingController(sceneState: state, screenSize: CGSize(width: 402, height: 874))
        #expect(!controller.isOrientationLocked)

        state.isRaceSequenceShowing = true
        #expect(controller.isOrientationLocked)
        if #available(iOS 26.0, *) { #expect(controller.prefersInterfaceOrientationLocked) }

        state.isRaceSequenceShowing = false
        #expect(!controller.isOrientationLocked)
        if #available(iOS 26.0, *) { #expect(!controller.prefersInterfaceOrientationLocked) }
    }

    @Test func mapsActivationStatesToPhases() {
        #expect(SceneState.phase(for: .foregroundActive) == .active)
        #expect(SceneState.phase(for: .foregroundInactive) == .inactive)
        #expect(SceneState.phase(for: .background) == .background)
        #expect(SceneState.phase(for: .unattached) == .background)
    }
}
