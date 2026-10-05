import UIKit
import XCTest

/// Launches render fixtures (#62) and diffs their screenshots against reference images.
///
/// - Fixtures are `Fixtures/<name>.json` (a race log, freeze tick, camera and vision filter; see
///   `RenderFixture` in the app). The app reads them from this folder on the host, which the simulator can.
/// - References are `References/<device>/<name>.png`, one folder per simulator device name, because
///   renders are only reproducible on one device and OS (Apple's libm and GPU, ADR 0002). CI pins both.
/// - A new or moved reference comes from CI (#215): CI sets `TEST_RUNNER_REFERENCE_ACTUALS_DIR`, a reference
///   test whose compare fails (or that has no reference) leaves its render there as `<device>/<name>.png`,
///   CI uploads the folder as the `render-actuals` artifact, and `scripts/adopt-references.sh` copies it into
///   `References/`. See docs/agents/validation.md.
/// - To record by hand: run the UI tests with `-recordReferences` in the test runner's arguments, or with
///   `TEST_RUNNER_RECORD_REFERENCES=1` in `xcodebuild`'s environment. Each reference test then rewrites its
///   reference and fails, so a recording run can't pass for a real one. Recording in CI (`CI` or
///   `GITHUB_ACTIONS`, passed in as `TEST_RUNNER_CI` / `TEST_RUNNER_GITHUB_ACTIONS`) is refused, and in CI a
///   missing reference fails rather than skips. See `ReferencePolicy`.
class RenderFixtureTestCase: RaceUITestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("References")

    /// The simulator's device name, such as `iPhone 17`: the references folder for this device.
    static var deviceName: String {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name
    }

    /// Where this device's references live.
    static var deviceReferences: URL {
        references.appendingPathComponent(deviceName, isDirectory: true)
    }

    struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    static var isCI: Bool {
        ReferencePolicy.isCI(environment: ProcessInfo.processInfo.environment)
    }

    static var referenceMode: ReferencePolicy.Mode {
        let process = ProcessInfo.processInfo
        let flag = ReferencePolicy.recordRequested(arguments: process.arguments, environment: process.environment)
        return ReferencePolicy.mode(flag: flag, isCI: isCI)
    }

    /// A fixture's screenshot and the rows at its bottom that diffs leave out.
    struct FixtureRender {
        let image: PixelImage
        /// The home-indicator band: the race rect's bottom safe-area inset, which the app reports as the
        /// `render-fixture` element's value in points, in screenshot rows. The system dims and hides the
        /// indicator on its own timer (`persistentSystemOverlays(.hidden)`), so its pixels depend on when the
        /// screenshot lands and on the machine; every diff of a fixture ignores them.
        let homeIndicatorRows: Int
        /// A gallery fixture draws the system status bar, whose clock shows the wall-clock time, so diffs of it
        /// leave the clock's box out (`ImageDiff.ignoredClock`). A race fixture hides the status bar and draws
        /// its own HUD clock there, which diffs must compare.
        let showsStatusBar: Bool
    }

    /// Whether fixture `name` is a gallery (its JSON has a `gallery` key), which shows the status bar.
    private static func isGallery(_ name: String) -> Bool {
        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent("\(name).json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["gallery"] != nil
    }

    /// The rows of a screenshot of `scene` under the home indicator, from the bottom inset the app reports.
    @MainActor private func homeIndicatorRows(of scene: XCUIElement, imageRows: Int) throws -> Int {
        guard let value = scene.value as? String, let inset = Double(value) else {
            throw FixtureFailure(description: "render-fixture's value isn't its bottom inset in points: \(String(describing: scene.value))")
        }
        return ImageDiff.rows(coveringBottom: inset, ofFrame: Double(scene.frame.height), imageRows: imageRows)
    }

    /// Dismisses a system notification banner (a "Ready for Apple Intelligence" one has covered the top of a
    /// render in CI) and returns whether there was one. SpringBoard owns banners, so they are in its
    /// accessibility tree rather than the app's; querying it doesn't launch or activate it. A banner times out
    /// on its own after a few seconds, so when the swipe doesn't take, waiting for it to go is the fallback.
    @MainActor private func dismissSystemBanner() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.otherElements["NotificationShortLookView"].firstMatch
        guard banner.exists else { return false }
        banner.swipeUp()
        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: banner)], timeout: 15)
        return true
    }

    /// Launches `-fixture <name>` and returns its render once two screenshots in a row agree outside the
    /// home-indicator band, so the launch animation is over and the frozen frame is on screen, and no system
    /// banner was up before the first screenshot or after the last (one that stays across both would pass the
    /// two-in-a-row check, so a banner seen means starting the comparison over).
    @MainActor func renderFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> FixtureRender {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fixture", name]
        app.launchEnvironment["REGATTA_FIXTURE_DIR"] = Self.fixtures.path
        app.launch()

        let scene = app.descendants(matching: .any)["render-fixture"].firstMatch
        guard scene.waitForExistence(timeout: 60) else {
            let error = app.staticTexts["fixture-error"]
            let reason = error.exists ? error.label : "no render-fixture element"
            throw FixtureFailure(description: "fixture \(name) didn't render: \(reason)")
        }

        let showsStatusBar = Self.isGallery(name)
        var last: PixelImage?
        for _ in 0..<40 {
            if dismissSystemBanner() { last = nil }
            let data = scene.screenshot().pngRepresentation
            let image = try XCTUnwrap(PixelImage(pngData: data), "screenshot isn't a PNG", file: file, line: line)
            let rows = try homeIndicatorRows(of: scene, imageRows: image.height)
            if let last, ImageDiff(actual: image, reference: last, tolerance: .exact, ignoringBottomRows: rows,
                                           ignoringStatusBarClock: showsStatusBar).differingPixels == 0,
               !dismissSystemBanner() {
                return FixtureRender(image: image, homeIndicatorRows: rows, showsStatusBar: showsStatusBar)
            }
            last = image
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw FixtureFailure(description: "fixture \(name) never held still across two screenshots")
    }

    /// Diffs `actual` with `reference` outside their bottom `ignoringBottomRows` rows, attaching the actual,
    /// reference and diff PNGs when it fails.
    @discardableResult @MainActor
    func assertMatches(_ actual: PixelImage, _ reference: PixelImage, named name: String, tolerance: DiffTolerance = .standard,
                       ignoringBottomRows: Int = 0, ignoringStatusBarClock: Bool = false, file: StaticString = #filePath,
                       line: UInt = #line) -> ImageDiff {
        let diff = compare(actual, reference, named: name, tolerance: tolerance, ignoringBottomRows: ignoringBottomRows,
                           ignoringStatusBarClock: ignoringStatusBarClock)
        if !diff.passes { XCTFail(Self.differsMessage(name, diff), file: file, line: line) }
        return diff
    }

    /// `assertMatches` without the failure: diffs and, when the diff fails, attaches the actual, reference and
    /// diff PNGs, leaving the caller to fail the test once it has done whatever must come first.
    @MainActor func compare(_ actual: PixelImage, _ reference: PixelImage, named name: String,
                            tolerance: DiffTolerance = .standard, ignoringBottomRows: Int = 0,
                            ignoringStatusBarClock: Bool = false) -> ImageDiff {
        let diff = ImageDiff(actual: actual, reference: reference, tolerance: tolerance, ignoringBottomRows: ignoringBottomRows,
                             ignoringStatusBarClock: ignoringStatusBarClock)
        if !diff.passes { attachDiff(diff, actual: actual, reference: reference, named: name) }
        return diff
    }

    /// The failure a diff that doesn't pass reports.
    private static func differsMessage(_ name: String, _ diff: ImageDiff) -> String {
        "\(name) differs from its reference: \(diff.summary)"
    }

    /// Attaches `<name>-actual.png`, `<name>-reference.png` and `<name>-diff.png` to the result bundle.
    @discardableResult @MainActor
    func attachDiff(_ diff: ImageDiff, actual: PixelImage, reference: PixelImage, named name: String) -> [XCTAttachment] {
        let attachments = [("actual", actual), ("reference", reference), ("diff", diff.image)].compactMap { suffix, image in
            image.pngData.map { data in
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "\(name)-\(suffix).png"
                attachment.lifetime = .keepAlways
                return attachment
            }
        }
        for attachment in attachments { add(attachment) }
        return attachments
    }

    /// Renders fixture `name` and diffs it against this device's committed reference
    /// (`assertMatchesReference(_:render:)`).
    @MainActor func assertMatchesReference(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertMatchesReference(name, render: renderFixture(name, file: file, line: line), file: file, line: line)
    }

    /// Diffs `render`, fixture `name`'s, against this device's committed reference. With no reference
    /// for this device it attaches the render, then fails in CI and skips locally; while recording it
    /// writes the reference.
    ///
    /// Past the refusal of a recording run in CI, every path calls `saveActuals` before it fails, skips or
    /// throws: `RaceUITestCase` sets `continueAfterFailure = false`, so an `XCTFail` (or a throwing
    /// `XCTUnwrap`) ends the test on the spot and anything after it never runs. Failing first left no render
    /// for CI's `render-actuals` upload (#215). Hence `compare` rather than `assertMatches` here, and a caller
    /// that checks the render some other way first records that failure without ending the test.
    @MainActor func assertMatchesReference(_ name: String, render: FixtureRender, file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let mode = Self.referenceMode
        if mode == .refused {
            XCTFail("-recordReferences is refused in CI: a failing compare uploads CI's render as the render-actuals "
                + "artifact; adopt it with scripts/adopt-references.sh", file: file, line: line)
            return
        }
        let actual = render.image
        let url = Self.deviceReferences.appendingPathComponent("\(name).png")

        if mode == .record {
            let data = try XCTUnwrap(actual.pngData)
            try FileManager.default.createDirectory(at: Self.deviceReferences, withIntermediateDirectories: true)
            try data.write(to: url)
            XCTFail("recorded \(url.path); run again without -recordReferences to compare", file: file, line: line)
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            if let png = actual.pngData {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "\(name)-actual.png"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            saveActuals(name, outcome: .noReference, render: actual, diff: nil, file: file, line: line)
            let message = "no reference for \(Self.deviceName) at \(url.path): in CI, adopt the render-actuals artifact "
                + "with scripts/adopt-references.sh; locally, record one with -recordReferences"
            switch ReferencePolicy.missingReference(isCI: Self.isCI) {
            case .fail:
                XCTFail(message, file: file, line: line)
                return
            case .skip:
                throw XCTSkip(message)
            }
        }
        guard let reference = PixelImage(pngData: data) else {
            // A committed reference that doesn't decode is as good as none: leave the render to replace it.
            saveActuals(name, outcome: .noReference, render: actual, diff: nil, file: file, line: line)
            XCTFail("\(url.path) isn't a PNG: in CI, adopt the render-actuals artifact with scripts/adopt-references.sh",
                    file: file, line: line)
            return
        }
        // A reference recorded on any machine matches CI's render whatever state the home indicator was in and
        // whatever time the status bar's clock showed.
        let diff = compare(actual, reference, named: name, ignoringBottomRows: render.homeIndicatorRows,
                           ignoringStatusBarClock: render.showsStatusBar)
        saveActuals(name, outcome: diff.passes ? .matched : .differed, render: actual, diff: diff.image,
                    file: file, line: line)
        if !diff.passes { XCTFail(Self.differsMessage(name, diff), file: file, line: line) }
    }

    /// When CI names an actuals directory (`REFERENCE_ACTUALS_DIR`, #215), leaves a failing reference test's
    /// render and diff there for CI to upload as `render-actuals`, or clears what a failed earlier try left
    /// once the test passes. Only `assertMatchesReference` calls this, so the fixture self-tests that call
    /// `assertMatches` directly never write here.
    @MainActor private func saveActuals(_ name: String, outcome: ReferencePolicy.CompareOutcome, render: PixelImage,
                                        diff: PixelImage?, file: StaticString, line: UInt) {
        let directory = ReferencePolicy.actualsDirectory(environment: ProcessInfo.processInfo.environment)
        switch ReferencePolicy.actualsAction(outcome: outcome, directory: directory, device: Self.deviceName, name: name) {
        case .nothing:
            return
        case let .remove(urls):
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        case let .write(renderURL, diffURL):
            do {
                try FileManager.default.createDirectory(at: renderURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                guard let png = render.pngData else { throw FixtureFailure(description: "the render has no PNG") }
                try png.write(to: renderURL)
                if let diffURL, let diffPNG = diff?.pngData { try diffPNG.write(to: diffURL) }
            } catch {
                XCTFail("couldn't leave \(name)'s render in \(renderURL.path) for render-actuals: \(error)",
                        file: file, line: line)
            }
        }
    }
}
