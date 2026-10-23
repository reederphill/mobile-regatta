import SceneKit
import SpriteKit
import RegattaCore

/// #596 PROTOTYPE (probe branch, never merged): the fleet, the buoys and the committee boat as one SceneKit scene in
/// one `SK3DNode` on the camera, drawn by an orthographic camera at the scene's tilt, so a ground point lands where
/// the squashed flat world draws it (`ChartGeometry.obliqueSquash`) and every standing thing rises off the water.
/// Units are world points (`GameScene.pointsPerMeter` a metre); the ground is XZ, Y up, screen-up is -Z.
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
    private let tilt: Double

    init(boats roster: [Boat], colors: [UIColor], boatClass: BoatClass, course: CourseLayout, pointsPerMeter ppm: CGFloat,
         tiltDegrees: Double, sceneSize: CGSize) {
        self.course = course
        self.ppm = ppm
        tilt = tiltDegrees * .pi / 180
        node = SK3DNode(viewportSize: sceneSize)
        node.scnScene = scene
        node.autoenablesDefaultLighting = false
        scene.background.contents = UIColor.clear

        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 40_000
        cameraNode.camera = camera
        // Pitched down from the horizontal by 90° − tilt: a ground point (x, 0, −y) lands on screen at (x, y·cos tilt).
        cameraNode.eulerAngles = SCNVector3(-(Float.pi / 2 - Float(tilt)), 0, 0)
        let back: Float = 10_000
        cameraNode.position = SCNVector3(0, back * Float(cos(tilt)), back * Float(sin(tilt)))
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
        box.materials = [Fleet3D.lambert(UIColor(white: 0.82, alpha: 1))]
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

    }

    static func lambert(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = color
        return m
    }

    /// Places everything for the camera of this frame: `center` (world points), `rotation` (`CameraRig.cameraRotation`)
    /// and `cameraScale`.
    func update(_ world: RenderWorld, poses: [BoatPose], style: BoatStyle, center: CGPoint, rotation: CGFloat,
                cameraScale: CGFloat, sceneSize: CGSize, time: Double, dt: Double, settled: Bool) {
        node.viewportSize = sceneSize
        camera.orthographicScale = Double(sceneSize.height / 2 * cameraScale)
        let rho = -rotation
        let c = cos(rho), s = sin(rho)
        func ground(_ w: CGPoint) -> (x: Float, z: Float) {
            let dx = w.x - center.x, dy = w.y - center.y
            return (Float(dx * c - dy * s), -Float(dx * s + dy * c))
        }
        for (i, boat) in world.boats.enumerated() where i < boats.count {
            let at = ground(CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm))
            boats[i].update(pose: poses[i], style: style, x: at.x, z: at.z, yaw: Float(-boat.heading + Double(rho)),
                            time: time, dt: dt, settled: settled)
        }
        let me = world.me
        let leg = ChartMarks.leg(in: course, status: me.status, legIndex: me.legIndex)
        let lineTone = ChartMarks.tone(isActive: ChartMarks.isLineActive(status: me.status, leg: leg)).uiColor
        for buoy in buoys {
            let at = ground(CGPoint(x: buoy.mark.position.x * ppm, y: buoy.mark.position.y * ppm))
            buoy.node.position = SCNVector3(at.x, Float(0.6 * ppm), at.z)
            let tone = buoy.isPin ? lineTone
                : ChartMarks.tone(of: buoy.mark, in: course, status: me.status, legIndex: me.legIndex).uiColor
            buoy.material.diffuse.contents = tone
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

        init(boatClass: BoatClass, ppm: CGFloat) {
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
            return make(vertices, normals, indices, doubleSided: true)
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
            return make(vertices, normals, indices, doubleSided: true)
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
            return make(vertices, normals, indices, doubleSided: true)
        }

        static func make(_ vertices: [SCNVector3], _ normals: [SCNVector3], _ indices: [Int32],
                         doubleSided: Bool) -> SCNGeometry {
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                       elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
            return geometry
        }
    }

    let root = SCNNode()
    private let heelNode = SCNNode()
    private let boomPivot = SCNNode()
    private let sailNode: SCNNode
    private let seat: Int
    private var sailAngle: Float = 0

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
        root.addChildNode(heelNode)
    }

    func update(pose: BoatPose, style: BoatStyle, x: Float, z: Float, yaw: Float, time: Double, dt: Double,
                settled: Bool) {
        root.position = SCNVector3(x, 0, z)
        root.eulerAngles = SCNVector3(0, yaw, 0)
        // Heel leans the whole rig toward her lee side (+x is starboard): 28° at full heel.
        let lee: Float = pose.leeSide == .starboard ? -1 : 1
        heelNode.eulerAngles = SCNVector3(0, 0, lee * Float(pose.heel) * 28 * .pi / 180)

        let side: Float = pose.sailSide == .port ? -1 : 1
        let target = Float(pose.sailTrim) * side
        sailAngle += (target - sailAngle) * (settled ? 1 : min(1, Float(dt) * 8))
        let phase = Double(seat) * style.flutterPhaseStep
        let swing = sin(time * style.flutterSwingRate + phase) * style.flutterDegrees * .pi / 180 * pose.flutter
        boomPivot.eulerAngles = SCNVector3(0, sailAngle + Float(swing), 0)
        let belly = pose.isGhost ? style.ghostSailBelly
            : pose.sailFullness * (1 - style.flapBellyLoss * pose.flutter
                * (0.5 + 0.5 * sin(time * style.flapBellyRate + phase)))
        sailNode.scale = SCNVector3(side * Float(max(belly, 0.05)), 1, 1)
        root.opacity = pose.isGhost ? CGFloat(style.ghostAlpha) : 1
    }
}
