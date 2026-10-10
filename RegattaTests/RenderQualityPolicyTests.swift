import Foundation
import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The frame rate and effect tiers the race draws at, from the device's heat, Low Power Mode and screen (#127, #27).
@MainActor @Suite struct RenderQualityPolicyTests {
    private static let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    /// Every screen, ProMotion included, draws at 60 while nominal, fair or serious, Low Power Mode or not, and at 30
    /// when critical (owner, 2026-10-05: the sim ticks at 30 Hz, so frames past 60 only interpolate). The effects step
    /// down by thermal state only, each tier keeping the last's cuts: serious freezes the water and drops far boats'
    /// sail detail, critical also shortens the wakes.
    @Test func policyTable() {
        let fps: [ProcessInfo.ThermalState: Int] = [.nominal: 60, .fair: 60, .serious: 60, .critical: 30]
        for state in Self.states {
            for lowPower in [false, true] {
                for maxFPS in [60, 120] {
                    let policy = RenderQualityPolicy(thermalState: state, lowPower: lowPower, maxFPS: maxFPS)
                    #expect(policy.fps == fps[state], "\(state.rawValue) lowPower \(lowPower) maxFPS \(maxFPS)")

                    // Low Power Mode changes nothing past the frame rate.
                    let hot = state == .serious || state == .critical
                    #expect(policy.water == (hot ? .cheap : .full), "\(state.rawValue)")
                    #expect(policy.sail == (hot ? .farReduced : .full), "\(state.rawValue)")
                    #expect(policy.wake == (state == .critical ? .short : .full), "\(state.rawValue)")
                }
            }
        }
        // The named rows.
        #expect(RenderQualityPolicy(thermalState: .nominal, lowPower: false, maxFPS: 120).fps == 60)
        #expect(RenderQualityPolicy(thermalState: .fair, lowPower: false, maxFPS: 120).fps == 60)
        #expect(RenderQualityPolicy(thermalState: .nominal, lowPower: false, maxFPS: 60).fps == 60)
        #expect(RenderQualityPolicy(thermalState: .nominal, lowPower: true, maxFPS: 120).fps == 60)
        #expect(RenderQualityPolicy(thermalState: .serious, lowPower: false, maxFPS: 120).fps == 60)
        #expect(RenderQualityPolicy(thermalState: .critical, lowPower: false, maxFPS: 120).fps == 30)
        #expect(RenderQualityPolicy(thermalState: .critical, lowPower: true, maxFPS: 120).fps == 30)
        // A screen faster still draws at 60.
        #expect(RenderQualityPolicy(thermalState: .nominal, lowPower: false, maxFPS: 240).fps == 60)

        #if DEBUG
        // `-fps120` (Debug only): 120 on a cool ProMotion screen out of Low Power Mode, the shipped policy otherwise.
        func debug(_ state: ProcessInfo.ThermalState, lowPower: Bool = false, maxFPS: Int = 120) -> RenderQualityPolicy {
            RenderQualityPolicy(thermalState: state, lowPower: lowPower, maxFPS: maxFPS, fps120: true)
        }
        #expect(debug(.nominal).fps == 120 && debug(.fair).fps == 120)
        #expect(debug(.nominal, maxFPS: 60).fps == 60)
        #expect(debug(.nominal, lowPower: true).fps == 60)
        #expect(debug(.serious).fps == 60 && debug(.critical).fps == 30)
        #expect(debug(.nominal, maxFPS: 240).fps == 120)
        for state in Self.states {
            var expected = RenderQualityPolicy(thermalState: state, lowPower: false, maxFPS: 120)
            expected.fps = debug(state).fps
            #expect(debug(state) == expected, "-fps120 changes the frame rate only")
        }
        #endif
    }

    /// A boat is far beyond `farBoatHulls` and near again only inside 0.8 of it, so one sailing along the edge
    /// doesn't flicker.
    @Test func farBoatHasADeadBand() {
        let hulls = BoatStyle.standard.farBoatHulls
        #expect(hulls == 8)
        #expect(!FarBoat.isFar(hullsFromYou: 7.9, wasFar: false, hulls: hulls))
        #expect(FarBoat.isFar(hullsFromYou: 8.1, wasFar: false, hulls: hulls))
        #expect(FarBoat.isFar(hullsFromYou: 7, wasFar: true, hulls: hulls))
        #expect(!FarBoat.isFar(hullsFromYou: 6.3, wasFar: true, hulls: hulls))
    }

    /// The monitor follows the system's thermal and power notifications, and its policy with them; a fixture or UI
    /// test run, and `-thermal`, pin the state.
    @Test func monitorFollowsTheSystem() async {
        final class Device {
            var state = ProcessInfo.ThermalState.nominal
            var lowPower = false
        }
        let device = Device()
        let center = NotificationCenter()
        let monitor = RenderQualityMonitor(
            system: .init(thermalState: { device.state }, lowPower: { device.lowPower }), center: center)
        #expect(monitor.policy(maxFPS: 120) == RenderQualityPolicy(thermalState: .nominal, lowPower: false, maxFPS: 120))

        device.state = .serious
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await Self.settle { monitor.thermalState == .serious }
        #expect(monitor.policy(maxFPS: 120) == RenderQualityPolicy(thermalState: .serious, lowPower: false, maxFPS: 120))

        device.state = .nominal
        device.lowPower = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await Self.settle { monitor.lowPower }
        #expect(monitor.thermalState == .nominal)
        #expect(monitor.policy(maxFPS: 120) == RenderQualityPolicy(thermalState: .nominal, lowPower: true, maxFPS: 120))

        device.state = .critical
        monitor.refresh()
        #expect(monitor.policy(maxFPS: 60).fps == 30 && monitor.policy(maxFPS: 60).wake == .short)

        // A fixture or UI test draws at nominal (or `-thermal`'s state, Debug), never the device's.
        func options(_ arguments: String...) -> LaunchOptions { LaunchOptions(arguments: ["/path/to/Regatta"] + arguments) }
        #expect(options("-uitesting").renderThermalState == .nominal)
        #expect(options("-fixture", "cues").renderThermalState == .nominal)
        #expect(options().renderThermalState == nil)
        let pinned = RenderQualityMonitor(options: options("-uitesting"))
        #expect(pinned.thermalState == .nominal && !pinned.lowPower)
        #if DEBUG
        #expect(options("-uitesting", "-thermal", "critical").renderThermalState == .critical)
        #expect(options("-thermal", "serious").renderThermalState == .serious)
        #expect(RenderQualityMonitor(options: options("-fixture", "cues", "-thermal", "serious")).thermalState == .serious)
        #endif
    }

    /// Lets the main actor run the monitor's refresh, posted from the notification.
    private static func settle(until done: () -> Bool) async {
        for _ in 0..<1000 where !done() { await Task.yield() }
    }

    /// At `.farReduced` a boat far from yours draws her sail at its trim and fullness, with no flutter, luff shiver or
    /// belly pump; a near one, yours and every boat at `.full` still swing. Her heel is the same either way, and so
    /// is her wake.
    @Test func farBoatsDropSailDetailOnly() throws {
        let style = BoatStyle.standard
        let boatClass = WakeTests.boatClass
        let boat = WakeTests.boat(speed: 6)
        var pose = BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass, style: style)
        pose.flutter = 1
        pose.luffLift = 1
        let time = 1.3

        func drawn(_ detail: SailDetail, hulls: Double, pose: BoatPose) -> BoatNode {
            let node = BoatNode(boat: boat, isMine: false, color: .red, boatClass: boatClass, pointsPerMeter: 8, style: style)
            node.update(with: boat, pose: pose, style: style, sailDetail: detail, hullsFromYou: hulls, time: time,
                        dt: 0, settled: true)
            return node
        }
        let side: CGFloat = pose.sailSide == .port ? -1 : 1
        let trim = CGFloat(pose.sailTrim) * side, belly = side * CGFloat(pose.sailFullness)

        let far = drawn(.farReduced, hulls: 20, pose: pose)
        #expect(far.isFar)
        #expect(abs(far.sailLook.rotation - trim) < 1e-6 && abs(far.sailLook.xScale - belly) < 1e-6)
        for node in [drawn(.farReduced, hulls: 2, pose: pose), drawn(.full, hulls: 20, pose: pose),
                     drawn(.farReduced, hulls: 0, pose: pose)] {
            #expect(abs(node.sailLook.rotation - trim) > 1e-3, "a near boat, or the full tier, still flutters")
            #expect(abs(node.hullXScale - far.hullXScale) < 1e-9, "heel is the same at any distance")
        }

        // Her wake is the same far or near.
        let near = drawn(.farReduced, hulls: 2, pose: pose)
        #expect(far.effects.trail.alpha == near.effects.trail.alpha)
        #expect(far.effects.shape == near.effects.shape)

        // Off the edge, she eases back to full detail rather than popping.
        let easing = drawn(.farReduced, hulls: 20, pose: pose)
        easing.update(with: boat, pose: pose, style: style, sailDetail: .full, hullsFromYou: 20, time: time, dt: 0.1)
        let eased = abs(easing.sailLook.rotation - trim)
        let full = abs(drawn(.full, hulls: 20, pose: pose).sailLook.rotation - trim)
        #expect(eased > 1e-4 && eased < full)
    }

    /// The race cues draw the same at every thermal tier (#27): render fixtures drawn at nominal, serious and critical
    /// agree on every node but the ripple and whitecaps, the sails and the wakes; the puffs and the pressure tone are
    /// cues and draw the same (the tone's samples, and so its texture, too). The tiers did change what they own.
    @Test func cueLayersAgreeAcrossThermalTiers() throws {
        let size = CameraRigTests.iPhone
        var tieredChanged = false
        for name in ["cues", "rules-call", "rules-penalty", "water-pressure"] {
            let (fixture, log) = try RenderFixture.load(named: name, in: RenderFixtureTests.fixtures)
            let session = try GameSession(fixture: fixture, log: log)
            let scene = session.scene
            scene.size = size
            SKView(frame: CGRect(origin: .zero, size: size)).presentScene(scene)

            let water = try #require(scene.childNode(withName: "//water") as? WaterNode)
            var renders: [(cues: [String], tiered: [String])] = []
            var tones: [PressureTone?] = []
            for state in Self.states {
                scene.apply(RenderQualityPolicy(thermalState: state, lowPower: false, maxFPS: 120))
                scene.update(0)
                renders.append(Self.snapshot(scene))
                tones.append(water.pressure?.tone)
            }
            #expect(tones.allSatisfy { $0 == tones[0] }, "\(name): the pressure tone moved with the tier")
            if name == "water-pressure" { #expect(tones[0] != nil, "water-pressure drew no pressure tone") }
            #expect(renders[0].cues.count > 20, "\(name): \(renders[0].cues.count) cue nodes")
            for (state, render) in zip(Self.states, renders).dropFirst() {
                let moved = zip(renders[0].cues, render.cues).filter { $0 != $1 }.map(\.0)
                #expect(render.cues.count == renders[0].cues.count && moved.isEmpty,
                        "\(name) at \(state.rawValue): \(moved.prefix(3))")
            }
            if renders[0].tiered != renders[3].tiered { tieredChanged = true }
        }
        #expect(tieredChanged, "the tiers changed none of what they own")
    }

    /// Every node the scene draws, described, split into the ones the thermal tiers may change and the rest.
    private static func snapshot(_ scene: SKScene) -> (cues: [String], tiered: [String]) {
        var cues: [String] = [], tiered: [String] = []
        func visit(_ node: SKNode, path: String, isTiered: Bool) {
            let tiered_ = isTiered || ["ripple", "sail", "wake"].contains(node.name ?? "")
            let line = "\(path) \(describe(node))"
            if tiered_ { tiered.append(line) } else { cues.append(line) }
            for (i, child) in node.children.enumerated() {
                visit(child, path: "\(path)/\(child.name ?? String(i))", isTiered: tiered_)
            }
        }
        visit(scene, path: "", isTiered: false)
        return (cues, tiered)
    }

    private static func describe(_ node: SKNode) -> String {
        var parts = ["\(type(of: node))", "p\(node.position)", "z\(node.zPosition)", "r\(node.zRotation)",
                     "s\(node.xScale),\(node.yScale)", "a\(node.alpha)", "h\(node.isHidden)"]
        if let shape = node as? SKShapeNode {
            parts += ["path\(shape.path?.boundingBox ?? .null)", "\(shape.path.map(Self.points) ?? 0)",
                      "stroke\(shape.strokeColor)", "fill\(shape.fillColor)", "w\(shape.lineWidth)"]
        }
        if let sprite = node as? SKSpriteNode {
            parts += ["size\(sprite.size)", "color\(sprite.color)", "blend\(sprite.colorBlendFactor)",
                      "texture\(sprite.texture.map { "\(ObjectIdentifier($0))" } ?? "nil")"]
        }
        if let label = node as? SKLabelNode { parts.append("text\(label.text ?? "")") }
        return parts.joined(separator: " ")
    }

    /// A path's point count, so two paths with the same box but different shapes still differ.
    private static func points(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }
}
