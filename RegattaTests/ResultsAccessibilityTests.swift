import Foundation
import RegattaCore
import SwiftUI
import Testing
import UIKit
@testable import Regatta

/// The results row's sail number as the accessibility tree reads it (#163). The label was a `LocalizedStringKey`, whose
/// `Int` interpolation is formatted for the locale: "Sail number 3,097" under a row that shows 3097, so the e2e test
/// that finds her row by the briefing's sail number (`OnlineQueueRaceUITests`) missed it whenever the number was over
/// 999 (CI run 39991051895). The label says the digits the row shows.
@MainActor struct ResultsAccessibilityTests {
    /// Every accessibility label in `view`, in tree order. A row alone, not the sheet: the sheet's scroll view lays its
    /// rows out only on screen.
    static func labels(_ content: some View) -> [String] {
        InProcessAccessibility.on()
        defer { InProcessAccessibility.off() }
        let view = content
            .frame(width: 375)
            .environment(\.locale, Locale(identifier: "en_US"))
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        var labels: [String] = []
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 40 else { return }
            if let label = node.accessibilityLabel, !label.isEmpty { labels.append(label) }
            var children = node.accessibilityElements ?? []
            if children.isEmpty {
                // A container that hands its elements out one by one, as SwiftUI's scroll views do.
                let count = node.accessibilityElementCount()
                if count > 0 && count != NSNotFound {
                    children = (0..<count).compactMap { node.accessibilityElement(at: $0) }
                }
            }
            for child in children {
                if let child = child as? NSObject { walk(child, depth: depth + 1) }
            }
            if let view = node as? UIView {
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
        }
        walk(host.view, depth: 0)
        return labels
    }

    @Test func aFourDigitSailNumberIsLabelledAsItShows() {
        let livery = Livery(design: DesignID("skiff-plain"), colours: [], sailNumber: 3097)
        let row = RaceResultViewModel.Row(seat: 0, place: 6, name: "You", isBot: false, isPlayer: true, livery: livery,
                                          result: .ocs, flagged: false)
        let labels = Self.labels(ResultRowView(row: row))
        #expect(labels.contains("Sail number 3097"), "\(labels)")
        #expect(!labels.contains { $0.contains("3,097") }, "\(labels)")
    }

    /// The briefing's fleet rows read their render's label too ("Boat, sail number …"): the same digits.
    @Test func theRenderSaysItsSailNumberAsTheSailShowsIt() {
        let livery = Livery(design: DesignID("skiff-plain"), colours: [], sailNumber: 6487)
        let labels = Self.labels(LiveryRenderView(livery: livery, size: BriefingFleetList.renderSize))
        #expect(labels.contains("Boat, sail number 6487"), "\(labels)")
    }
}
