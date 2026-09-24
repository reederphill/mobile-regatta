import SwiftUI
import Testing
@testable import Regatta

@MainActor @Suite struct RaceViewportPolicyTests {
    private let policy = RaceViewportPolicy.letterboxedPortrait
    /// iPhone 17 and iPad Air 13-inch (M4) screens, in points.
    private let iPhone = CGSize(width: 402, height: 874)
    private let iPad = CGSize(width: 1032, height: 1376)

    @Test func shipsLetterboxedPortrait() {
        #expect(RaceViewportPolicy.shipping == .letterboxedPortrait)
    }

    @Test func fullScreenPortraitFillsTheWindow() {
        let insets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        let layout = policy.layout(window: iPhone, safeAreaInsets: insets, screen: iPhone)
        #expect(layout.sceneSize == iPhone)
        #expect(layout.raceRect == CGRect(origin: .zero, size: iPhone))
        #expect(layout.safeAreaInsets == insets)
    }

    @Test func landscapeWindowLetterboxesThePortraitRace() {
        let window = CGSize(width: iPad.height, height: iPad.width)
        // The screen reports its bounds in the current orientation; the policy turns it portrait.
        let layout = policy.layout(window: window, screen: window)
        #expect(layout.sceneSize == iPad)
        #expect(abs(layout.raceRect.height - window.height) < 1e-9)
        #expect(abs(layout.raceRect.width / layout.raceRect.height - iPad.width / iPad.height) < 1e-9)
        #expect(abs(layout.raceRect.midX - window.width / 2) < 1e-9)
        #expect(layout.raceRect.minY == 0)
    }

    @Test func narrowWindowLetterboxesTopAndBottom() {
        let window = CGSize(width: 320, height: 1376)
        let layout = policy.layout(window: window, screen: iPad)
        #expect(layout.sceneSize == iPad)
        #expect(layout.raceRect.minX == 0 && layout.raceRect.width == 320)
        #expect(abs(layout.raceRect.height - 320 * iPad.height / iPad.width) < 1e-9)
        #expect(abs(layout.raceRect.midY - window.height / 2) < 1e-9)
    }

    @Test func everyWindowShowsTheSameWorldArea() {
        let windows = [iPad, CGSize(width: iPad.height, height: iPad.width), CGSize(width: 320, height: 1376),
                       CGSize(width: 700, height: 500)]
        for window in windows {
            #expect(policy.layout(window: window, screen: iPad).sceneSize == iPad)
        }
    }

    @Test func keepsOnlyTheInsetsInsideTheRaceRect() {
        let window = CGSize(width: iPad.height, height: iPad.width)
        let insets = EdgeInsets(top: 24, leading: 40, bottom: 20, trailing: 40)
        let layout = policy.layout(window: window, safeAreaInsets: insets, screen: iPad)
        // The rect spans the full height but sits well inside the side insets.
        #expect(layout.safeAreaInsets == EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0))
    }

    @Test func withoutAScreenTheRaceFillsTheWindow() {
        let window = CGSize(width: 500, height: 300)
        let layout = policy.layout(window: window, screen: nil)
        #expect(layout.sceneSize == window)
        #expect(layout.raceRect == CGRect(origin: .zero, size: window))
    }
}
