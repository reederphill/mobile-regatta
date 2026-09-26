import UIKit
import XCTest

/// Launches render fixtures (#62) and diffs their screenshots against reference images.
///
/// - Fixtures are `Fixtures/<name>.json` (a race log, freeze tick, camera and vision filter; see
///   `RenderFixture` in the app). The app reads them from this folder on the host, which the simulator can.
/// - References are `References/<device>/<name>.png`, one folder per simulator device name, because
///   renders are only reproducible on one device and OS (Apple's libm and GPU, ADR 0002). CI pins both.
/// - To record: run the UI tests with `-recordReferences` in the test runner's arguments, or with
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
    }

    /// The rows of a screenshot of `scene` under the home indicator, from the bottom inset the app reports.
    @MainActor private func homeIndicatorRows(of scene: XCUIElement, imageRows: Int) throws -> Int {
        guard let value = scene.value as? String, let inset = Double(value) else {
            throw FixtureFailure(description: "render-fixture's value isn't its bottom inset in points: \(String(describing: scene.value))")
        }
        return ImageDiff.rows(coveringBottom: inset, ofFrame: Double(scene.frame.height), imageRows: imageRows)
    }

    /// Launches `-fixture <name>` and returns its render once two screenshots in a row agree outside the
    /// home-indicator band, so the launch animation is over and the frozen frame is on screen.
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

        var last: PixelImage?
        for _ in 0..<20 {
            let data = scene.screenshot().pngRepresentation
            let image = try XCTUnwrap(PixelImage(pngData: data), "screenshot isn't a PNG", file: file, line: line)
            let rows = try homeIndicatorRows(of: scene, imageRows: image.height)
            if let last, ImageDiff(actual: image, reference: last, tolerance: .exact, ignoringBottomRows: rows).differingPixels == 0 {
                return FixtureRender(image: image, homeIndicatorRows: rows)
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
                       ignoringBottomRows: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> ImageDiff {
        let diff = ImageDiff(actual: actual, reference: reference, tolerance: tolerance, ignoringBottomRows: ignoringBottomRows)
        if !diff.passes {
            attachDiff(diff, actual: actual, reference: reference, named: name)
            XCTFail("\(name) differs from its reference: \(diff.summary)", file: file, line: line)
        }
        return diff
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

    /// Renders fixture `name` and diffs it against this device's committed reference. With no reference
    /// for this device it attaches the render, then fails in CI and skips locally; while recording it
    /// writes the reference.
    @MainActor func assertMatchesReference(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let mode = Self.referenceMode
        if mode == .refused {
            XCTFail("-recordReferences is refused in CI: record on a local simulator and commit the PNGs", file: file, line: line)
            return
        }
        let render = try renderFixture(name, file: file, line: line)
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
            let message = "no reference for \(Self.deviceName) at \(url.path): record one with -recordReferences, "
                + "or commit the attached \(name)-actual.png there"
            switch ReferencePolicy.missingReference(isCI: Self.isCI) {
            case .fail:
                XCTFail(message, file: file, line: line)
                return
            case .skip:
                throw XCTSkip(message)
            }
        }
        let reference = try XCTUnwrap(PixelImage(pngData: data), "\(url.path) isn't a PNG", file: file, line: line)
        // A reference recorded on any machine matches CI's render whatever state the home indicator was in.
        assertMatches(actual, reference, named: name, ignoringBottomRows: render.homeIndicatorRows, file: file, line: line)
    }
}
