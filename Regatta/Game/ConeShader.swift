import SpriteKit
import RegattaCore

/// One boat's wind-shadow cone, drawn by a shader (#15, #10): a diagonal hatch whose strength is core's loss, so the
/// picture is the effect. The cone's near edge follows her heading (`ShadowCone.nearEdge`: the line from her bow to her
/// stern for a class that casts it from the hull), so its shape changes every frame and can't be baked into a texture;
/// the shader works it out per pixel from the four corners core cuts the shadow from, as `ShadowCone.span(at:)` does:
/// at each distance down the axis the cone reaches between the crossings of the segments joining those corners, and the
/// loss is full at her centre and falls straight to nothing at the far end and, across, to nothing at the sides
/// (`ConeShading.fade` is the same arithmetic in Swift).
///
/// The sprite is a fixed box, as large as the cone can be for her class, in the cone's frame (x across it, y down its
/// axis from the apex, in points); only the two near corners move. They are the sprite's own attribute (`a_near`), not
/// a uniform, so the fleet's cones share one shader, drawn in one pass: a shader per boat with its uniforms changed
/// every frame cost the simulator a frame's time over the fleet and slowed a practice race at `-timescale 32` to half
/// its pace (#354).
final class ConeShader {
    /// The sprite's size, points, and where the apex is in it.
    let size: CGSize
    let anchor: CGPoint
    /// Shared by every cone of the same class, scale and hatch (`shared`).
    let shader: SKShader
    /// The attribute holding the near edge's ends, points in the cone's frame: (a.x, a.y, b.x, b.y).
    static let nearAttribute = "a_near"

    private init(size: CGSize, anchor: CGPoint, shader: SKShader) {
        self.size = size
        self.anchor = anchor
        self.shader = shader
    }

    /// The cone shader for `shadow` at `ppm` in `style`'s hatch, built once per class, scale and hatch and then shared.
    static func shared(shadow: BoatClass.WindShadow, pointsPerMeter ppm: CGFloat, style: BoatStyle) -> ConeShader {
        let spacing = Float(max(style.hatchSpacing, 1)), width = Float(max(style.hatchLineWidth, 0.25))
        let key = Key(shadow: [shadow.coneLength, shadow.coneWidthAtBoat, shadow.coneWidthAtEnd, shadow.bowY,
                               shadow.sternCorner.x, shadow.sternCorner.y],
                      ppm: ppm, hatch: [spacing, width])
        if let shared = cache[key] { return shared }
        let box = ConeShading.box(shadow)
        let size = CGSize(width: box.width * Double(ppm), height: box.height * Double(ppm))
        let anchor = CGPoint(x: 0.5, y: box.upwind / box.height)
        let shader = SKShader(source: ConeShading.source, uniforms: [
            SKUniform(name: "u_size", vectorFloat2: vector_float2(Float(size.width), Float(size.height))),
            SKUniform(name: "u_anchorY", float: Float(anchor.y)),
            SKUniform(name: "u_far", vectorFloat2: vector_float2(Float(shadow.coneWidthAtEnd / 2 * Double(ppm)),
                                                                 Float(shadow.coneLength * Double(ppm)))),
            SKUniform(name: "u_hatch", vectorFloat2: vector_float2(spacing * Float(2).squareRoot(), width)),
        ])
        shader.attributes = [SKAttribute(name: nearAttribute, type: .vectorFloat4)]
        let made = ConeShader(size: size, anchor: anchor, shader: shader)
        cache[key] = made
        return made
    }

    /// Moves `sprite`'s near edge's ends, in metres in the cone's frame.
    static func update(_ sprite: SKSpriteNode, nearA a: Vec2, nearB b: Vec2, ppm: CGFloat) {
        let near = vector_float4(Float(a.x * Double(ppm)), Float(a.y * Double(ppm)),
                                 Float(b.x * Double(ppm)), Float(b.y * Double(ppm)))
        if let value = sprite.value(forAttributeNamed: nearAttribute) {
            value.vectorFloat4Value = near
        } else {
            sprite.setValue(SKAttributeValue(vectorFloat4: near), forAttribute: nearAttribute)
        }
    }

    /// `sprite`'s near edge's ends as the shader has them, points in the cone's frame.
    static func near(of sprite: SKSpriteNode) -> (a: vector_float2, b: vector_float2)? {
        guard let near = sprite.value(forAttributeNamed: nearAttribute)?.vectorFloat4Value else { return nil }
        return (vector_float2(near.x, near.y), vector_float2(near.z, near.w))
    }

    private struct Key: Hashable {
        var shadow: [Double]
        var ppm: CGFloat
        var hatch: [Float]
    }

    private static var cache: [Key: ConeShader] = [:]
}

/// The cone shader's source, and its arithmetic in Swift for the tests (the shader can't run in them).
nonisolated enum ConeShading {
    /// The box the cone's sprite covers, metres in its frame: wide enough for the far end and for the hull across it, and
    /// from the hull's upwind end to the far end down the axis. `upwind` is how far above the apex it reaches.
    static func box(_ shadow: BoatClass.WindShadow) -> (width: Double, height: Double, upwind: Double) {
        let hull = max(shadow.bowY, abs(shadow.sternCorner.y), shadow.coneWidthAtBoat / 2)
        let half = max(shadow.coneWidthAtEnd / 2, hull)
        return (2 * half, shadow.coneLength + hull, hull)
    }

    /// The cone's strength at (`across`, `along`), 0...1: core's loss as a share of its full value (`ShadowCone`), the
    /// shader's formula. `nearA` and `nearB` are the near edge's ends.
    static func fade(across: Double, along: Double, nearA: Vec2, nearB: Vec2, halfEnd: Double, length: Double) -> Double {
        guard along < length else { return 0 }
        var lo = Double.infinity, hi = -Double.infinity
        func cross(_ p: Vec2, _ q: Vec2) {
            guard p.y != q.y, along >= min(p.y, q.y), along <= max(p.y, q.y) else { return }
            let x = p.x + (q.x - p.x) * (along - p.y) / (q.y - p.y)
            lo = min(lo, x)
            hi = max(hi, x)
        }
        cross(nearA, nearB)
        for corner in [Vec2(-halfEnd, length), Vec2(halfEnd, length)] {
            cross(nearA, corner)
            cross(nearB, corner)
        }
        guard hi > lo, across > lo, across < hi else { return 0 }
        let half = (hi - lo) / 2
        return (1 - min(max(along, 0), length) / length) * (1 - abs(across - (lo + hi) / 2) / half)
    }

    /// SpriteKit shader source, the same arithmetic as `fade` per pixel, times the diagonal hatch (lines `u_hatch.y`
    /// wide, `u_hatch.x` apart along the x axis, anti-aliased). The pixel's place in the cone's frame comes from the
    /// sprite's size and anchor, the near edge's ends from its `a_near`; the output is white at the strength, premultiplied.
    static let source = """
    void main() {
        vec2 u_a = a_near.xy;
        vec2 u_b = a_near.zw;
        vec2 p = vec2((v_tex_coord.x - 0.5) * u_size.x, (v_tex_coord.y - u_anchorY) * u_size.y);
        float lo = 1.0e9;
        float hi = -1.0e9;
        vec2 fl = vec2(-u_far.x, u_far.y);
        vec2 fr = vec2(u_far.x, u_far.y);
        if (u_a.y != u_b.y && p.y >= min(u_a.y, u_b.y) && p.y <= max(u_a.y, u_b.y)) {
            float x = u_a.x + (u_b.x - u_a.x) * (p.y - u_a.y) / (u_b.y - u_a.y);
            lo = min(lo, x); hi = max(hi, x);
        }
        if (u_a.y != fl.y && p.y >= min(u_a.y, fl.y) && p.y <= max(u_a.y, fl.y)) {
            float x = u_a.x + (fl.x - u_a.x) * (p.y - u_a.y) / (fl.y - u_a.y);
            lo = min(lo, x); hi = max(hi, x);
        }
        if (u_a.y != fr.y && p.y >= min(u_a.y, fr.y) && p.y <= max(u_a.y, fr.y)) {
            float x = u_a.x + (fr.x - u_a.x) * (p.y - u_a.y) / (fr.y - u_a.y);
            lo = min(lo, x); hi = max(hi, x);
        }
        if (u_b.y != fl.y && p.y >= min(u_b.y, fl.y) && p.y <= max(u_b.y, fl.y)) {
            float x = u_b.x + (fl.x - u_b.x) * (p.y - u_b.y) / (fl.y - u_b.y);
            lo = min(lo, x); hi = max(hi, x);
        }
        if (u_b.y != fr.y && p.y >= min(u_b.y, fr.y) && p.y <= max(u_b.y, fr.y)) {
            float x = u_b.x + (fr.x - u_b.x) * (p.y - u_b.y) / (fr.y - u_b.y);
            lo = min(lo, x); hi = max(hi, x);
        }
        float strength = 0.0;
        if (hi > lo && p.y < u_far.y && p.x > lo && p.x < hi) {
            float reach = (hi - lo) * 0.5;
            float across = abs(p.x - (lo + hi) * 0.5);
            float along = clamp(p.y, 0.0, u_far.y);
            strength = (1.0 - along / u_far.y) * (1.0 - across / reach);
        }
        float t = mod(p.x + p.y, u_hatch.x);
        float dist = min(t, u_hatch.x - t) / 1.41421356;
        float line = 1.0 - smoothstep(u_hatch.y * 0.5 - 0.5, u_hatch.y * 0.5 + 0.5, dist);
        gl_FragColor = vec4(strength * line);
    }
    """
}
