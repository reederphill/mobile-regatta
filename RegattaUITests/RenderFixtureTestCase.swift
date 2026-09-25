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

    /// Launches `-fixture <name>` and returns its render once two screenshots in a row agree, so the
    /// launch animation is over and the frozen frame is on screen.
    @MainActor func renderFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> PixelImage {
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
            if let last, ImageDiff(actual: image, reference: last, tolerance: .exact).differingPixels == 0 {
                return image
            }
            last = image
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw FixtureFailure(description: "fixture \(name) never held still across two screenshots")
    }

    /// Diffs `actual` with `reference`, attaching the actual, reference and diff PNGs when it fails.
    @discardableResult @MainActor
    func assertMatches(_ actual: PixelImage, _ reference: PixelImage, named name: String, tolerance: DiffTolerance = .standard,
                       file: StaticString = #filePath, line: UInt = #line) -> ImageDiff {
        let diff = ImageDiff(actual: actual, reference: reference, tolerance: tolerance)
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
        let actual = try renderFixture(name, file: file, line: line)
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
        assertMatches(actual, reference, named: name, file: file, line: line)
    }
}
