import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Regatta

/// The lobby area's accessibility tree (#142): UI tests find each panel by its own identifier inside `lobby-panel`.
/// SwiftUI folds a container whose only child is a container into one element under the outer identifier, so the
/// hidden panel (`lobby-hidden`) and "Can't reach the lobby" (`lobby-unreachable`) were missing in CI (run
/// 39906505332), where only `lobby-panel` held their children.
@MainActor struct LobbyAccessibilityTests {
    /// An identifier in the tree and how deep it sits.
    struct Node: Equatable {
        let id: String
        let depth: Int
    }

    /// The identified accessibility elements of `LobbyView` showing `state`, in tree order.
    static func tree(_ state: LobbyPanelState) -> [Node] {
        InProcessAccessibility.on()
        defer { InProcessAccessibility.off() }
        let host = UIHostingController(rootView: LobbyView(state: state).frame(width: 360))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        var nodes: [Node] = []
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 40 else { return }
            let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
            if node.responds(to: getter), let id = node.perform(getter)?.takeUnretainedValue() as? String, !id.isEmpty {
                nodes.append(Node(id: id, depth: depth))
            }
            for child in node.accessibilityElements ?? [] {
                if let child = child as? NSObject { walk(child, depth: depth + 1) }
            }
            if let view = node as? UIView {
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
        }
        walk(host.view, depth: 0)
        return nodes
    }

    /// Expects `inner` in the tree below `outer`.
    static func expectInside(_ inner: String, _ outer: String, in nodes: [Node], _ comment: Comment) {
        let outerIndex = nodes.firstIndex { $0.id == outer }
        let innerIndex = nodes.firstIndex { $0.id == inner }
        guard let outerIndex, let innerIndex else {
            Issue.record("\(comment): \(nodes.map(\.id))")
            return
        }
        #expect(innerIndex > outerIndex && nodes[innerIndex].depth > nodes[outerIndex].depth, comment)
    }

    @Test func theHiddenPanelIsItsOwnElementInTheLobbyPanel() {
        let nodes = Self.tree(.chatHidden(queuedPlayers: nil))
        Self.expectInside("lobby-hidden", "lobby-panel", in: nodes, "no lobby-hidden in lobby-panel")
        Self.expectInside("lobby-leaderboard", "lobby-hidden", in: nodes, "no Leaderboard row in the hidden panel")
    }

    @Test func theUnreachablePanelIsItsOwnElementInTheLobbyPanel() {
        let nodes = Self.tree(.unreachable)
        Self.expectInside("lobby-unreachable", "lobby-panel", in: nodes, "no lobby-unreachable in lobby-panel")
        Self.expectInside("lobby-reopen", "lobby-unreachable", in: nodes, "no Try again in the unreachable panel")
    }

    @Test func theLoadingAndSilentPanelsAreInTheLobbyPanel() {
        Self.expectInside("lobby-loading", "lobby-panel", in: Self.tree(.loading), "no lobby-loading in lobby-panel")
        Self.expectInside("lobby-silent", "lobby-panel", in: Self.tree(.silent), "no lobby-silent in lobby-panel")
    }
}

/// Turns accessibility on in this process while a test reads the tree, as VoiceOver or XCUITest would (the way the
/// AccessibilitySnapshot library does): SwiftUI builds its accessibility elements only then. Test-only.
@MainActor enum InProcessAccessibility {
    private typealias SetEnabled = @convention(c) (Bool) -> Void

    private static let setEnabled: SetEnabled? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()

    static func on() {
        guard let setEnabled else {
            Issue.record("libAccessibility's _AXSApplicationAccessibilitySetEnabled isn't there")
            return
        }
        setEnabled(true)
        RunLoop.main.run(until: .now.addingTimeInterval(0.2))
    }

    static func off() { setEnabled?(false) }
}
