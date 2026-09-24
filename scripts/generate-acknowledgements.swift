#!/usr/bin/env swift
// Generates Regatta/Acknowledgements.plist, the third-party licences Settings → About lists (#25, #107).
//
// Sources:
//   - every remote Swift package the Regatta scheme resolves, with the licence file from its checkout. This
//     includes packages only linked on other platforms (swift-crypto is Linux only), which errs on the safe side.
//   - every folder under ThirdParty/ (fonts, sounds, art that isn't a Swift package): ThirdParty/<Name>/LICENSE*,
//     plus an optional one-line ThirdParty/<Name>/VERSION
// Local packages (Packages/*) are ours and aren't listed.
//
//   swift scripts/generate-acknowledgements.swift          # rewrite the plist
//   swift scripts/generate-acknowledgements.swift --check  # fail if the committed plist is out of date (CI)
import Foundation

struct Acknowledgement: Encodable {
    var name: String
    var version: String?
    var license: String
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Regatta/Acknowledgements.plist")
let check = CommandLine.arguments.contains("--check")
let fileManager = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-acknowledgements: \(message)\n".utf8))
    exit(1)
}

func licenseText(in folder: URL) -> String? {
    guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }
    let candidates = names.filter { $0.uppercased().hasPrefix("LICENSE") || $0.uppercased().hasPrefix("LICENCE") || $0.uppercased().hasPrefix("COPYING") }
    guard let name = candidates.sorted().first,
          let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Remote packages resolved for the app, via xcodebuild into a scratch folder.
func packageAcknowledgements() -> [Acknowledgement] {
    let scratch = fileManager.temporaryDirectory.appendingPathComponent("regatta-acknowledgements-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: scratch) }

    let xcodebuild = Process()
    xcodebuild.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    xcodebuild.arguments = ["xcodebuild", "-resolvePackageDependencies", "-project", root.appendingPathComponent("Regatta.xcodeproj").path,
                            "-scheme", "Regatta", "-clonedSourcePackagesDirPath", scratch.path]
    xcodebuild.standardOutput = FileHandle.nullDevice
    do { try xcodebuild.run() } catch { fail("couldn't run xcodebuild: \(error)") }
    xcodebuild.waitUntilExit()
    guard xcodebuild.terminationStatus == 0 else { fail("xcodebuild -resolvePackageDependencies failed") }

    struct State: Decodable {
        struct Object: Decodable { var dependencies: [Dependency] }
        struct Dependency: Decodable {
            struct Ref: Decodable { var kind: String; var name: String }
            var packageRef: Ref
            var subpath: String
        }
        var object: Object
    }
    let stateFile = scratch.appendingPathComponent("workspace-state.json")
    guard let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(State.self, from: data) else {
        fail("couldn't read \(stateFile.path)")
    }
    return state.object.dependencies.filter { $0.packageRef.kind.hasPrefix("remote") }.map { dependency in
        let checkout = scratch.appendingPathComponent("checkouts").appendingPathComponent(dependency.subpath)
        guard let license = licenseText(in: checkout) else { fail("no licence file in package \(dependency.packageRef.name)") }
        // No version: Package.resolved isn't committed, so versions float and would make --check flaky.
        return Acknowledgement(name: dependency.packageRef.name, version: nil, license: license)
    }
}

/// Anything else we ship that someone else made: ThirdParty/<Name>/.
func vendoredAcknowledgements() -> [Acknowledgement] {
    let folder = root.appendingPathComponent("ThirdParty")
    guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
    return names.filter { !$0.hasPrefix(".") }.map { name in
        let item = folder.appendingPathComponent(name)
        guard let license = licenseText(in: item) else { fail("no LICENSE file in ThirdParty/\(name)") }
        let version = (try? String(contentsOf: item.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Acknowledgement(name: name, version: version, license: license)
    }
}

let acknowledgements = (packageAcknowledgements() + vendoredAcknowledgements())
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
let encoder = PropertyListEncoder()
encoder.outputFormat = .xml
guard let plist = try? encoder.encode(acknowledgements) else { fail("couldn't encode the list") }

if check {
    guard let committed = try? Data(contentsOf: output), committed == plist else {
        fail("Regatta/Acknowledgements.plist is out of date: run swift scripts/generate-acknowledgements.swift")
    }
    print("Acknowledgements up to date (\(acknowledgements.count) entries).")
} else {
    do { try plist.write(to: output) } catch { fail("couldn't write \(output.path): \(error)") }
    print("Wrote \(acknowledgements.count) acknowledgements to Regatta/Acknowledgements.plist.")
}
