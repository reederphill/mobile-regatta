import SceneKit
import SpriteKit
import RegattaCore

/// The fleet, the buoys and the committee boat standing up (#596, #597): one SceneKit scene in one `SK3DNode` on the
/// camera, drawn by an orthographic camera at the scene's tilt, so a ground point lands where the squashed flat world
/// draws it (`ChartGeometry.obliqueSquash`) and every standing thing rises off the water. The only render path for the
/// boats at every tilt: what lies flat under them (heel shadow, glows, wakes) stays `BoatNode`'s. One light, fixed on
/// the screen, plus ambient; no cheaper tier (#597: within 2 fps and a draw of the flat fleet at 10 boats). The
/// thermal tiers' sail cut (`SailDetail.farReduced`) drops a far boat's flutter, luff shiver and belly pump; her hull,
/// heel, mast, boom and trim never change by tier. Units are world points (`GameScene.pointsPerMeter` a metre); the
/// ground is XZ, Y up, screen-up is -Z. The flat buoy bodies and the committee boat's ellipse in `ChartLayer` stay as
/// footprints under the standing shapes, and take the same `ChartMarks` tone.
final class Fleet3D {
    let node: SK3DNode
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let camera = SCNCamera()
    private var boats: [Boat3D] = []
    private struct Buoy {
        var mark: CourseLayout.Mark
        var isPin: Bool
        var node: SCNNode
        var material: SCNMaterial
    }
    private var buoys: [Buoy] = []
    private let committee: SCNNode
    private let committeePosition: CGPoint
    private let course: CourseLayout
    private let ppm: CGFloat
    /// The tilt the camera is pitched to, radians off vertical.
    private var tilt: Double = .nan
    /// The nodes the scene holds besides the boats and the buoys: the camera, the sun, the ambient light and the
    /// committee boat's hull and cabin.
    static let fixedNodeCount = 5

    init(boats roster: [Boat], colors: [UIColor], boatClass: BoatClass, course: CourseLayout, pointsPerMeter ppm: CGFloat,
         tiltDegrees: Double, sceneSize: CGSize) {
        self.course = course
        self.ppm = ppm
        node = SK3DNode(viewportSize: sceneSize)
        node.scnScene = scene
        node.autoenablesDefaultLighting = false
        scene.background.contents = UIColor.clear

        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 40_000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        node.pointOfView = cameraNode

        // One light, fixed on the screen: from its upper left, and high.
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1700
        sun.color = UIColor(white: 1, alpha: 1)
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = SCNVector3(-1, 1.6, -0.8)
        sunNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sunNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 750
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let geometry = Boat3D.Geometry(boatClass: boatClass, ppm: ppm)
        for (i, boat) in roster.enumerated() {
            let b = Boat3D(geometry: geometry, color: colors[i], seat: boat.id)
            boats.append(b)
            scene.rootNode.addChildNode(b.root)
        }

        let style = ChartStyle.standard
        let hull = style.committeeHull
        // A low hull and a small cabin on it, so she reads as a boat, not a block.
        let box = SCNBox(width: hull.width * ppm * 0.8, height: 0.9 * ppm, length: hull.height * ppm, chamferRadius: 0.35 * ppm)
        // White, as the flat chart drew her: the light shades her sides.
        box.materials = [Fleet3D.lambert(UIColor(white: 0.93, alpha: 1))]
        committee = SCNNode(geometry: box)
        let cabinBox = SCNBox(width: hull.width * ppm * 0.5, height: 0.9 * ppm, length: hull.height * ppm * 0.4,
                              chamferRadius: 0.2 * ppm)
        cabinBox.materials = [Fleet3D.lambert(UIColor(white: 0.97, alpha: 1))]
        let cabin = SCNNode(geometry: cabinBox)
        cabin.position = SCNVector3(0, Float(0.9 * ppm), -Float(hull.height * ppm * 0.1))
        committee.addChildNode(cabin)
        let position = course.startLine.committee.position
        committeePosition = CGPoint(x: position.x * ppm, y: position.y * ppm)
        scene.rootNode.addChildNode(committee)
        let height = 1.2 * ppm
        func buoy(_ mark: CourseLayout.Mark, isPin: Bool) -> Buoy {
            let radius = max(CGFloat(mark.radius) * ppm, style.minimumBuoyRadius)
            let cylinder = SCNCylinder(radius: radius, height: height)
            cylinder.radialSegmentCount = 16
            let material = Fleet3D.lambert(.orange)
            cylinder.materials = [material]
            let node = SCNNode(geometry: cylinder)
            scene.rootNode.addChildNode(node)
            return Buoy(mark: mark, isPin: isPin, node: node, material: material)
        }
        buoys = ChartMarks.buoys(of: course).map { buoy($0.mark, isPin: false) }
        buoys.append(buoy(course.startLine.pin, isPin: true))
        Self.fixDrawOrder(of: scene.rootNode)
        pitch(toDegrees: tiltDegrees)
    }

    /// #602: gives every node its own `renderingOrder`, in the scene's own order (depth first, children in the order
    /// added), so SceneKit draws the scene in the same order at every launch. Where two surfaces meet at one depth
    /// (a deck's edge on its topsides' rim) the one drawn first wins the depth test; left to itself SceneKit orders
    /// nodes of one `renderingOrder` its own way, which changed between launches, so a frozen render fixture drew a
    /// pixel or three on a gunwale in the deck's tone at one launch and the far topsides' at the next (the thermal
    /// render test, which diffs three launches exactly).
    static func fixDrawOrder(of root: SCNNode) {
        var order = 0
        root.enumerateHierarchy { node, _ in
            node.renderingOrder = order
            order += 1
        }
    }

    /// Pitches the camera down from the horizontal by 90° − tilt: a ground point (x, 0, −y) lands on screen at
    /// (x, y·cos tilt), where the squashed flat world draws it (`ChartGeometry.obliqueSquash`).
    private func pitch(toDegrees degrees: Double) {
        let radians = degrees * .pi / 180
        guard radians != tilt else { return }
        tilt = radians
        cameraNode.eulerAngles = SCNVector3(-(Float.pi / 2 - Float(radians)), 0, 0)
        let back: Float = 10_000
        cameraNode.position = SCNVector3(0, back * Float(cos(radians)), back * Float(sin(radians)))
    }

    static func lambert(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = color
        return m
    }

    /// The boats, in seat order, for tests.
    var fleet: [Boat3D] { boats }
    /// Each buoy's colour as drawn, pin last, and the committee boat's, for tests.
    var buoyTones: [UIColor] { buoys.compactMap { $0.material.diffuse.contents as? UIColor } }
    var committeeColor: UIColor? { committee.geometry?.firstMaterial?.diffuse.contents as? UIColor }
    /// The nodes each frame places on the camera: every boat's root, the buoys and the committee boat, for tests.
    var standingNodes: [SCNNode] { boats.map(\.root) + buoys.map(\.node) + [committee] }
    /// The camera's zoom as written and as SceneKit draws it, for tests.
    var orthographicScale: Double { camera.orthographicScale }
    var presentedOrthographicScale: Double { cameraNode.presentation.camera?.orthographicScale ?? .nan }
    /// Every node's `renderingOrder`, root first, depth first in the scene's order, for tests.
    var drawOrders: [Int] {
        var orders: [Int] = []
        scene.rootNode.enumerateHierarchy { node, _ in orders.append(node.renderingOrder) }
        return orders
    }
    /// Every node in the SceneKit scene, the root's descendants, for tests.
    var sceneNodeCount: Int {
        func count(_ node: SCNNode) -> Int { node.childNodes.reduce(0) { $0 + 1 + count($1) } }
        return count(scene.rootNode)
    }

    /// Places everything for the camera of this frame: `center` (world points), `rotation` (`CameraRig.cameraRotation`)
    /// `cameraScale` and `tiltDegrees`. `sailDetail` is the sails' tier (#127): at `.farReduced` a boat more than
    /// `style.farBoatHulls` from yours draws no flutter, luff shiver or belly pump. `hidesSails` hides every sail
    /// (`-cuesOnly`).
    func update(_ world: RenderWorld, poses: [BoatPose], style: BoatStyle, center: CGPoint, rotation: CGFloat,
                cameraScale: CGFloat, tiltDegrees: Double, sceneSize: CGSize, sailDetail: SailDetail = .full,
                hidesSails: Bool = false, time: Double, dt: Double, settled: Bool) {
        // #602: every write lands in this frame's draw. SceneKit keeps writes made outside a transaction in an
        // implicit one that commits at the end of the run loop's turn, after SpriteKit has drawn this frame, so the
        // `SK3DNode` drew the last frame's places: the boats and buoys trailed every swing and pinch by a frame and
        // snapped home when the camera stopped. One explicit transaction, committed before the draw, with no
        // animation, puts the presentation tree on the model as SpriteKit draws.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0
        defer {
            SCNTransaction.commit()
            SCNTransaction.flush()
        }
        pitch(toDegrees: tiltDegrees)
        if node.viewportSize != sceneSize { node.viewportSize = sceneSize }
        let scale = Double(sceneSize.height / 2 * cameraScale)
        if camera.orthographicScale != scale { camera.orthographicScale = scale }
        let rho = -rotation
        let c = cos(rho), s = sin(rho)
        func ground(_ w: CGPoint) -> (x: Float, z: Float) {
            let dx = w.x - center.x, dy = w.y - center.y
            return (Float(dx * c - dy * s), -Float(dx * s + dy * c))
        }
        let me = world.me.position
        let hull = max(world.boatClass.hull.length, 1e-6)
        for (i, boat) in world.boats.enumerated() where i < boats.count && i < poses.count {
            let at = ground(CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm))
            let hullsFromYou = i == world.myBoatIndex ? 0 : (boat.position - me).length / hull
            boats[i].update(pose: poses[i], style: style, x: at.x, z: at.z, yaw: Float(-boat.heading + Double(rho)),
                            sailDetail: sailDetail, hullsFromYou: hullsFromYou, hidesSail: hidesSails,
                            time: time, dt: dt, settled: settled)
        }
        // The active leg's marks orange, the rest grey (#15), as the flat chart tones them.
        let mine = world.me
        let leg = ChartMarks.leg(in: course, status: mine.status, legIndex: mine.legIndex)
        let lineTone = ChartMarks.tone(isActive: ChartMarks.isLineActive(status: mine.status, leg: leg)).uiColor
        for buoy in buoys {
            let at = ground(CGPoint(x: buoy.mark.position.x * ppm, y: buoy.mark.position.y * ppm))
            buoy.node.position = SCNVector3(at.x, Float(0.6 * ppm), at.z)
            let tone = buoy.isPin ? lineTone
                : ChartMarks.tone(of: buoy.mark, in: course, status: mine.status, legIndex: mine.legIndex).uiColor
            // Only when the tone changes (a leg rounded): a material write each frame dirties it for SceneKit.
            if buoy.material.diffuse.contents as? UIColor != tone { buoy.material.diffuse.contents = tone }
        }
        let at = ground(committeePosition)
        committee.position = SCNVector3(at.x, Float(0.45 * ppm), at.z)
        committee.eulerAngles = SCNVector3(0, Float(rho), 0)
    }
}

/// One boat in `Fleet3D`: yaw ← heel ← hull and rig; the boom and sail swing about the mast.
final class Boat3D {
    /// The class's shapes, built once for the fleet.
    struct Geometry {
        var hull: SCNGeometry
        var deck: SCNGeometry
        var cockpit: SCNGeometry
        var sail: SCNGeometry
        var mastHeight: CGFloat
        var mastZ: CGFloat
        var freeboard: CGFloat
        var boomHeight: CGFloat
        var boomLength: CGFloat
        var spar: CGFloat
        /// The spinnaker (#311), on a class with one: the kite in its own frame and a pole one point long, and where
        /// the pole's foot sits (the drawn bow). Nil, and zero, on a class without.
        var kite: SCNGeometry?
        var pole: SCNGeometry?
        var poleFootZ: CGFloat = 0
        var poleY: CGFloat = 0
        var pointsPerMeter: CGFloat

        init(boatClass: BoatClass, ppm: CGFloat) {
            pointsPerMeter = ppm
            let l = CGFloat(boatClass.hull.length) * ppm, b = CGFloat(boatClass.hull.beam) * ppm
            // Fun before realism: the topsides drawn deeper than a dinghy's so they read at phone scale.
            freeboard = 0.3 * b
            mastHeight = 1.25 * l
            mastZ = -0.16 * l
            boomHeight = 0.1 * l
            boomLength = 0.62 * l
            spar = max(0.7, 0.035 * b)
            let outline = boatClass.hull.outline.map { CGPoint(x: CGFloat($0.x) * ppm, y: CGFloat($0.y) * ppm) }
            hull = Geometry.loft(outline, freeboard: freeboard)
            deck = Geometry.cap(outline, at: freeboard)
            let cockpitRect = [CGPoint(x: -0.26 * b, y: -0.42 * l), CGPoint(x: 0.26 * b, y: -0.42 * l),
                               CGPoint(x: 0.22 * b, y: -0.06 * l), CGPoint(x: -0.22 * b, y: -0.06 * l)]
            cockpit = Geometry.cap(cockpitRect, at: freeboard + 0.15)
            sail = Geometry.sail(length: boomLength, luff: (mastHeight - boomHeight) * 0.95,
                                 belly: 0.12 * l, columns: 8)
            if boatClass.spinnaker != nil {
                // The pole's foot a spar's width inside the drawn bow, so it meets the hull; on the deck.
                let bow = outline.map(\.y).max() ?? l / 2
                poleFootZ = -bow + spar * 2
                poleY = freeboard + spar
                // The tack sits at the pole's tip; the head stays forward of the mast however the kite is trimmed
                // (#311 gate round 2: no kite pose crosses the main), the clew above the boom.
                kite = Geometry.kite(foot: 0.7 * l, headHeight: 0.72 * mastHeight, headAft: 0.22 * l,
                                     clewHeight: boomHeight + 0.2 * l, belly: 0.3 * l)
                let box = SCNBox(width: spar * 1.6, height: spar * 1.6, length: 1, chamferRadius: 0)
                pole = box
            }
        }

        /// The asymmetric spinnaker (#311) in its own frame, drawn at its deepest: the tack at the origin, the foot
        /// running aft along +z to the clew `foot` away and `clewHeight` up, the luff bowed forward up to the head
        /// `headHeight` up and `headAft` aft, the leech back down to the clew. Each point of the cloth bowed to +x by
        /// `belly`, deepest a third of the way up and a little forward of the middle, so it reads as a balloon. The
        /// node's x scale flips it to her side and sets its depth; its angle swings the whole kite about the tack.
        static func kite(foot: CGFloat, headHeight: CGFloat, headAft: CGFloat, clewHeight: CGFloat, belly: CGFloat,
                         columns: Int = 8, rows: Int = 6) -> SCNGeometry {
            func point(_ u: CGFloat, _ v: CGFloat) -> SIMD3<Float> {
                // The luff (u 0) and the leech (u 1) from the foot (v 0) to the head (v 1).
                let luffY = headHeight * v, luffZ = headAft * v - 0.16 * foot * sin(.pi * v)
                let leechY = clewHeight + (headHeight - clewHeight) * v
                let leechZ = foot + (headAft - foot) * v + 0.06 * foot * sin(.pi * v)
                let y = luffY + (leechY - luffY) * u, z = luffZ + (leechZ - luffZ) * u
                let across = sin(.pi * pow(u, 0.8)), up = sin(.pi * (0.22 + 0.78 * v))
                return SIMD3(Float(belly * across * up), Float(y), Float(z))
            }
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
            let e: CGFloat = 1e-3
            for j in 0...rows {
                for i in 0...columns {
                    let u = CGFloat(i) / CGFloat(columns), v = CGFloat(j) / CGFloat(rows)
                    let p = point(u, v)
                    let du = point(min(u + e, 1), v) - point(max(u - e, 0), v)
                    let dv = point(u, min(v + e, 1)) - point(u, max(v - e, 0))
                    var normal = simd_cross(du, dv)
                    normal = simd_length(normal) > 1e-9 ? simd_normalize(normal) : SIMD3(1, 0, 0)
                    // Outward, to the belly's side.
                    if normal.x < 0 { normal = -normal }
                    vertices.append(SCNVector3(p.x, p.y, p.z))
                    normals.append(SCNVector3(normal.x, normal.y, normal.z))
                    if i < columns, j < rows {
                        let a = Int32(j * (columns + 1) + i), b = a + Int32(columns + 1)
                        indices += [a, a + 1, b, b, a + 1, b + 1]
                    }
                }
            }
            return make(vertices, normals, indices)
        }

        /// The topsides: the outline at deck height down to a narrower keel line at the waterline, flat-shaded quads.
        static func loft(_ outline: [CGPoint], freeboard: CGFloat) -> SCNGeometry {
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
            func v3(_ p: CGPoint, _ y: CGFloat, kx: CGFloat, ky: CGFloat) -> SIMD3<Float> {
                SIMD3(Float(p.x * kx), Float(y), -Float(p.y * ky))
            }
            let n = outline.count
            for i in 0..<n {
                let p = outline[i], q = outline[(i + 1) % n]
                let a = v3(p, freeboard, kx: 1, ky: 1), b = v3(q, freeboard, kx: 1, ky: 1)
                let c = v3(q, 0, kx: 0.55, ky: 0.94), d = v3(p, 0, kx: 0.55, ky: 0.94)
                var normal = simd_normalize(simd_cross(b - a, d - a))
                // Outward: away from the centreline.
                let mid = (a + b) / 2
                if simd_dot(normal, SIMD3(mid.x, 0, mid.z)) < 0 { normal = -normal }
                let base = Int32(vertices.count)
                for v in [a, b, c, d] {
                    vertices.append(SCNVector3(v.x, v.y, v.z))
                    normals.append(SCNVector3(normal.x, normal.y, normal.z))
                }
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
            return make(vertices, normals, indices)
        }

        /// A flat cap at `y`: a fan from the centroid, normal up.
        static func cap(_ outline: [CGPoint], at y: CGFloat) -> SCNGeometry {
            let cx = outline.map(\.x).reduce(0, +) / CGFloat(outline.count)
            let cy = outline.map(\.y).reduce(0, +) / CGFloat(outline.count)
            var vertices = [SCNVector3(Float(cx), Float(y), -Float(cy))]
            vertices += outline.map { SCNVector3(Float($0.x), Float(y), -Float($0.y)) }
            let normals = Array(repeating: SCNVector3(0, 1, 0), count: vertices.count)
            var indices: [Int32] = []
            for i in 0..<outline.count {
                indices += [0, Int32(1 + i), Int32(1 + (i + 1) % outline.count)]
            }
            return make(vertices, normals, indices)
        }

        /// The mainsail in the boom's frame: luff up the mast at z 0, foot along the boom to +z, a short head at the
        /// leech; each column bowed to +x by `belly · sin(π t)` (the node's x scale flips and fills it).
        static func sail(length: CGFloat, luff: CGFloat, belly: CGFloat, columns: Int) -> SCNGeometry {
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
            let head = luff * 0.08
            for i in 0...columns {
                let t = CGFloat(i) / CGFloat(columns)
                let x = belly * sin(.pi * t)
                let z = t * length
                // Slope dx/dz of the camber; the surface normal is (1, 0, −slope).
                let slope = belly * .pi / length * cos(.pi * t)
                let normal = simd_normalize(SIMD3<Float>(1, 0, -Float(slope)))
                let top = luff * (1 - t) + head * t + luff * 0.12 * sin(.pi * t)
                vertices.append(SCNVector3(Float(x), 0, Float(z)))
                vertices.append(SCNVector3(Float(x * 0.6), Float(top), Float(z * (1 - 0.15 * t))))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
                if i < columns {
                    let a = Int32(i * 2)
                    indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
                }
            }
            return make(vertices, normals, indices)
        }

        /// Triangles from `vertices` and their `normals`; the materials say which faces draw (`isDoubleSided`).
        static func make(_ vertices: [SCNVector3], _ normals: [SCNVector3], _ indices: [Int32]) -> SCNGeometry {
            SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                        elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        }
    }

    /// The SceneKit nodes one boat adds to the fleet's scene: `root`, `heelNode`, the hull, deck, cockpit and mast, the
    /// boom pivot, the boom and the sail.
    static let nodeCount = 9
    /// And on a class with a spinnaker (#311): the pole and the kite.
    static let kiteNodeCount = 2
    /// The nodes this boat adds: `nodeCount`, plus `kiteNodeCount` on a class with a spinnaker.
    var drawnNodeCount: Int { Self.nodeCount + (kiteNode == nil ? 0 : Self.kiteNodeCount) }
    let root = SCNNode()
    private let heelNode = SCNNode()
    private let boomPivot = SCNNode()
    private let sailNode: SCNNode
    private let hullNode: SCNNode
    private let mastNode: SCNNode
    /// Her spinnaker (#311), on a class with one: flown from the tip of `poleNode`, a spar on her centreline at the
    /// bow that runs out with the hoist and in with the drop and never swings. Both hidden while it is down. Nil for
    /// a class without.
    private let kiteNode: SCNNode?
    private let poleNode: SCNNode?
    private let poleFootZ: Float
    private let poleY: Float
    private let pointsPerMeter: Float
    /// The main's target last frame, and, while the boom swings across (a gybe or a tack), how far out it stood when
    /// the swing began: the clock the kite crosses on (#311 gate round 3).
    private var sailTarget: Float = 0
    private var sailSwingFrom: Float?
    /// The kite's drawn angle out from her centreline, unsigned, and its drawn depth: each eased (#311).
    private var kiteTrim: Float = 0
    private var kiteFill: Float = 0
    private var kiteEased = false
    /// Every material she draws with: a ghost fades them all (`BoatStyle.ghostAlpha`).
    private var materials: [SCNMaterial] = []
    /// Her seat: each boat's flutter swings on its own phase (`BoatStyle.flutterPhaseStep`), so a flapping fleet
    /// doesn't flap in step.
    private let seat: Int
    private var sailAngle: Float = 0
    /// Her heel as drawn, radians about her fore-and-aft axis, eased to the pose's at `BoatStyle.heelEaseRate`.
    private(set) var heelAngle: Float = 0
    /// Whether she has drawn a pose yet: her first frame takes the pose's heel outright, so a race start, a scene
    /// rebuild or a resume doesn't ease her in from upright (#602).
    private var hasPose = false
    /// Her heel at the pose's full heel (1): 28°.
    static let fullHeel: Float = 28 * .pi / 180
    /// Whether she is far from your boat (`FarBoat`), kept across frames for its dead band.
    private(set) var isFar = false
    /// How much of her sail animation detail draws, 0…1: eased to 0 while she is far at `SailDetail.farReduced` and
    /// back to 1 otherwise, so a boat crossing the line doesn't pop (#127).
    private(set) var sailDetailShare: Double = 1

    init(geometry g: Geometry, color: UIColor, seat: Int) {
        self.seat = seat
        let hullMaterial = Fleet3D.lambert(color)
        hullMaterial.isDoubleSided = true
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        let deckMaterial = Fleet3D.lambert(UIColor(hue: h, saturation: s * 0.55, brightness: min(1, br * 1.1 + 0.15), alpha: 1))
        deckMaterial.isDoubleSided = true
        let cockpitMaterial = Fleet3D.lambert(UIColor(hue: h, saturation: s * 0.5, brightness: br * 0.55, alpha: 1))
        let sailMaterial = Fleet3D.lambert(UIColor(white: 0.95, alpha: 1))
        sailMaterial.isDoubleSided = true
        let sparMaterial = Fleet3D.lambert(UIColor(white: 0.25, alpha: 1))

        materials = [hullMaterial, deckMaterial, cockpitMaterial, sailMaterial, sparMaterial]
        pointsPerMeter = Float(g.pointsPerMeter)
        poleFootZ = Float(g.poleFootZ)
        poleY = Float(g.poleY)
        if let kiteGeometry = g.kite?.copy() as? SCNGeometry, let poleGeometry = g.pole?.copy() as? SCNGeometry {
            // White like the main, its own material: the one seam a livery tint takes (#372).
            let kiteMaterial = Fleet3D.lambert(UIColor(white: 0.97, alpha: 1))
            kiteMaterial.isDoubleSided = true
            materials.append(kiteMaterial)
            kiteGeometry.materials = [kiteMaterial]
            let kite = SCNNode(geometry: kiteGeometry)
            // A touch see-through, as the flat kite was (0.88): her hull and main still read under it at 45°.
            kite.opacity = 0.88
            kite.isHidden = true
            kiteNode = kite
            poleGeometry.materials = [sparMaterial]
            let pole = SCNNode(geometry: poleGeometry)
            // The box is one point long about its middle: pivoted so it runs from its foot forward (−z), and its z
            // scale is its length.
            pole.pivot = SCNMatrix4MakeTranslation(0, 0, 0.5)
            pole.position = SCNVector3(0, poleY, poleFootZ)
            pole.isHidden = true
            poleNode = pole
        } else {
            kiteNode = nil
            poleNode = nil
        }
        let hull = SCNNode(geometry: g.hull.copy() as? SCNGeometry)
        hull.geometry?.materials = [hullMaterial]
        let deck = SCNNode(geometry: g.deck.copy() as? SCNGeometry)
        deck.geometry?.materials = [deckMaterial]
        let cockpit = SCNNode(geometry: g.cockpit.copy() as? SCNGeometry)
        cockpit.geometry?.materials = [cockpitMaterial]

        let mastGeometry = SCNCylinder(radius: g.spar, height: g.mastHeight)
        mastGeometry.radialSegmentCount = 6
        mastGeometry.materials = [sparMaterial]
        let mast = SCNNode(geometry: mastGeometry)
        mast.position = SCNVector3(0, Float(g.freeboard + g.mastHeight / 2), Float(g.mastZ))
        hullNode = hull
        mastNode = mast

        boomPivot.position = SCNVector3(0, Float(g.freeboard + g.boomHeight), Float(g.mastZ))
        let boomGeometry = SCNCylinder(radius: g.spar, height: g.boomLength)
        boomGeometry.radialSegmentCount = 6
        boomGeometry.materials = [sparMaterial]
        let boom = SCNNode(geometry: boomGeometry)
        boom.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        boom.position = SCNVector3(0, 0, Float(g.boomLength / 2))
        let sail = g.sail.copy() as? SCNGeometry
        sail?.materials = [sailMaterial]
        sailNode = SCNNode(geometry: sail)
        boomPivot.addChildNode(boom)
        boomPivot.addChildNode(sailNode)

        [hull, deck, cockpit, mast, boomPivot].forEach(heelNode.addChildNode)
        if let poleNode, let kiteNode { [poleNode, kiteNode].forEach(heelNode.addChildNode) }
        root.addChildNode(heelNode)
    }

    /// Draws her in `pose` at ground point (`x`, `z`) turned `yaw`, at race time `time` (every flutter swings on it).
    /// `settled` trims the sail straight to its target (a frozen render fixture). At `sailDetail` `.farReduced` and
    /// `hullsFromYou` past `style.farBoatHulls` she draws her sail at its trim and fullness alone (#127); a ghost and
    /// your boat (0 hulls) always in full. `hidesSail` hides it and the boom (`-cuesOnly`), the boom at its trim alone
    /// whatever the tier, so a hidden rig draws the same near and far.
    func update(pose: BoatPose, style: BoatStyle, x: Float, z: Float, yaw: Float, sailDetail: SailDetail = .full,
                hullsFromYou: Double = 0, hidesSail: Bool = false, time: Double, dt: Double, settled: Bool) {
        root.position = SCNVector3(x, 0, z)
        root.eulerAngles = SCNVector3(0, yaw, 0)
        // Heel leans the whole rig toward her lee side (+x is starboard): 28° at full heel. Eased like the sail
        // (#602): the pose's heel steps to 0 as the sheets go out and back as they come in, and through upright on
        // a tack; the standing hull showed each step as a snap.
        let lee: Float = pose.leeSide == .starboard ? -1 : 1
        let heelTarget = lee * Float(pose.heel) * Self.fullHeel
        let snaps = settled || !hasPose
        heelAngle += (heelTarget - heelAngle) * (snaps ? 1 : min(1, Float(dt) * Float(style.heelEaseRate)))
        hasPose = true
        heelNode.eulerAngles = SCNVector3(0, 0, heelAngle)

        isFar = FarBoat.isFar(hullsFromYou: hullsFromYou, wasFar: isFar, hulls: style.farBoatHulls)
        let reduced = sailDetail == .farReduced && isFar && !pose.isGhost
        sailDetailShare += ((reduced ? 0 : 1) - sailDetailShare) * (settled ? 1 : min(1, dt * 2))
        let detail = sailDetailShare

        let side: Float = pose.sailSide == .port ? -1 : 1
        let target = Float(pose.sailTrim) * side
        // A swing across begins when the target crosses to the side opposite the drawn main (#311: the kite's clock).
        if settled || target == 0 {
            sailSwingFrom = nil
        } else if sailSwingFrom == nil, sailAngle != 0, (sailAngle > 0) != (target > 0) {
            sailSwingFrom = abs(sailAngle)
        }
        sailAngle += (target - sailAngle) * (settled ? 1 : min(1, Float(dt) * 8))
        sailTarget = target
        if sailSwingFrom != nil, (sailAngle > 0) == (target > 0), abs(sailAngle) > abs(target) * 0.995 {
            // Landed on the new side: the swing is over.
            sailSwingFrom = nil
        }
        let phase = Double(seat) * style.flutterPhaseStep
        // Hidden (`-cuesOnly`), the boom swings with no tier: at its trim.
        let swingDetail = hidesSail ? 0 : detail
        let swing = sin(time * style.flutterSwingRate + phase) * style.flutterDegrees * .pi / 180 * pose.flutter
            * swingDetail
        // Pinched (#219): the leading edge lifts, a small quick shiver at the luff on top of any flutter.
        let luff = sin(time * 37 + phase) * style.pinchLuffDegrees * .pi / 180 * pose.luffLift * swingDetail
        boomPivot.eulerAngles = SCNVector3(0, sailAngle + Float(swing + luff), 0)
        // A flapping sail loses its belly; a ghost's hangs limp. Pinched it flattens, footed it fills (#219).
        let belly = pose.isGhost ? style.ghostSailBelly
            : pose.sailFullness * (1 - style.flapBellyLoss * pose.flutter * detail
                * (0.5 + 0.5 * sin(time * style.flapBellyRate + phase)))
        sailNode.scale = SCNVector3(side * Float(max(belly, 0.05)), 1, 1)
        sailNode.isHidden = hidesSail
        boomPivot.isHidden = hidesSail
        updateKite(pose.spinnaker, style: style, detail: detail, hidesSail: hidesSail, time: time, dt: dt,
                   settled: settled)
        let transparency = pose.isGhost ? CGFloat(style.ghostAlpha) : 1
        for material in materials where material.transparency != transparency { material.transparency = transparency }
    }

    /// Where the drawn main stands between its sides, −1 (port) to 1 (starboard): ±1 settled on a side; through a
    /// swing across, its eased angle over how far out it stood when the swing began (on the old side) or over its
    /// target (on the new), so 0 exactly as the boom crosses her centreline. Nil head to wind (no side to read).
    private var boomShare: Float? {
        guard sailTarget != 0 else { return nil }
        let toSide: Float = sailTarget > 0 ? 1 : -1
        guard let from = sailSwingFrom else { return toSide }
        let onNewSide = (sailAngle > 0) == (sailTarget > 0)
        return min(1, max(-1, sailAngle / max(onNewSide ? abs(sailTarget) : from, 1e-6)))
    }

    /// The kite (#311), its tack at the pole's tip. Its size is fixed while it is up (it grows from the tack as it is
    /// hoisted and shrinks back as it drops, with the pole). Only two things change on it: its depth (deeper the
    /// further downwind, shallower soft and collapsed, never under `kiteDepthFloor` of its size) and its angle, never
    /// inside the main's. Through a gybe it swings across with the boom as one set animation: its side share is the
    /// drawn main's (`boomShare`), so it starts, crosses her centreline and lands with the boom, its belly flipping
    /// sides there. `detail` scales its flog and pump only (#127's far tier): a collapse, a hoist and its side always
    /// draw.
    private func updateKite(_ pose: SpinnakerPose, style: BoatStyle, detail: Double, hidesSail: Bool, time: Double,
                            dt: Double, settled: Bool) {
        guard let kiteNode, let poleNode else { return }
        let shown = pose.phase != .hidden && pose.hoisted > 0.001
        if settled || !kiteEased || !shown {
            // Nothing to ease from: a frozen frame, her first, or a kite coming out of the bag.
            kiteTrim = Float(pose.trim)
            kiteFill = Float(pose.fill)
            kiteEased = shown
        } else {
            // Its trim (collapsing forward, refilling) on the main's own rate; its depth on the soft kite's.
            kiteTrim += (Float(pose.trim) - kiteTrim) * min(1, Float(dt) * 8)
            let k = style.cornerWakeEaseRate > 0 ? 1 - exp(-max(dt, 0) * style.cornerWakeEaseRate) : 1
            kiteFill += (Float(pose.fill) - kiteFill) * Float(k)
        }
        let hidden = hidesSail || !shown
        if kiteNode.isHidden != hidden {
            kiteNode.isHidden = hidden
            poleNode.isHidden = hidden
        }
        guard !hidden else { return }

        // The pole runs out with the hoist and back in with the drop (the pose's progress, no easing); the kite's
        // tack rides its tip.
        let hoisted = Float(pose.hoisted)
        let poleLength = Float(max(style.kitePoleMetres, 0)) * pointsPerMeter * hoisted
        let overlap = abs(poleFootZ) > 0 ? Float(2) : 0
        poleNode.scale = SCNVector3(1, 1, max(overlap + poleLength, 0.01))
        kiteNode.position = SCNVector3(0, poleY, poleFootZ - overlap - poleLength)

        let share = boomShare ?? (pose.side == .port ? -1 : 1)
        let drawnSide: Float = share < 0 ? -1 : 1
        let phase = Double(seat) * style.flutterPhaseStep
        let flog = pose.flutter * detail
        let swing = Float(sin(time * style.flutterSwingRate + phase) * style.kiteFlutterDegrees * .pi / 180 * flog)
        // Never sheeted harder than the main, every frame (#311 gate round 4): its angle off the centreline on its
        // side is at least the drawn main's on that side, flog and the gybe's swing included.
        let free = (kiteTrim * share + swing * drawnSide) * drawnSide
        let angle = drawnSide * max(free, boomPivot.eulerAngles.y * drawnSide)
        kiteNode.eulerAngles = SCNVector3(0, angle, 0)
        let pump = Float(1 - style.flapBellyLoss * flog * (0.5 + 0.5 * sin(time * style.flapBellyRate + phase)))
        // The belly faces the side it is drawn on and keeps its depth through a gybe: at the centreline it flips
        // sides without passing through flat, and no state draws it shallower than the floor.
        let floor = Float(min(max(style.kiteDepthFloor, 0), 1))
        let depth = max(kiteFill * pump, floor)
        kiteNode.scale = SCNVector3(drawnSide * depth * hoisted, hoisted, hoisted)
    }

    /// Her kite as drawn (#311), nil while hidden, for tests: its angle off the bow aft (signed, + to starboard, as
    /// the boom's), its depth (signed by side, the x scale over its size), and its size (1 up: how far hoisted).
    var kiteLook: (angle: Float, depth: Float, size: Float)? {
        guard let kiteNode, !kiteNode.isHidden else { return nil }
        let size = kiteNode.scale.y
        return (kiteNode.eulerAngles.y, size > 0 ? kiteNode.scale.x / size : 0, size)
    }
    /// Her pole as drawn (#311), nil while hidden, for tests: where its tip stands (z, forward is −z, in her frame),
    /// its turn (always 0: it never swings) and its foot's x, and where the kite's tack is.
    var poleLook: (tipZ: Float, turn: Float, x: Float, kiteTack: SIMD3<Float>)? {
        guard let poleNode, let kiteNode, !poleNode.isHidden else { return nil }
        return (poleNode.position.z - poleNode.scale.z, poleNode.eulerAngles.y, poleNode.position.x,
                SIMD3<Float>(kiteNode.position))
    }

    /// What the tiers may change (#127): the boom's turn and the sail's belly, and whether the sail and the boom show.
    var sailLook: (boom: Float, belly: Float, isHidden: Bool, boomIsHidden: Bool) {
        (boomPivot.eulerAngles.y, sailNode.scale.x, sailNode.isHidden, boomPivot.isHidden)
    }
    /// What no tier changes: the hull's, mast's, boom's and sail's places in her frame, her heel and her trim.
    var standingLook: [SIMD3<Float>] {
        [root.position, root.eulerAngles, heelNode.eulerAngles, hullNode.position, mastNode.position,
         boomPivot.position, sailNode.position].map { SIMD3<Float>($0) }
    }
    /// Her materials' transparency (1 opaque), for tests.
    var transparency: [CGFloat] { materials.map(\.transparency) }
}
