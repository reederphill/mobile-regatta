import CoreGraphics
import Foundation
import RegattaCore
import SceneKit
import SpriteKit
import UIKit

/// #604 round 4 probe: lit water. J a physically based plane in the standing fleet's SceneKit scene, K the same light
/// as one SpriteKit shader. Both: an animated height field (four deep-water waves, wavelengths 1.2–5.3 m, travelling
/// downwind at their own speeds, plus two octaves of drifting chop) gives the normals; the sun is the fleet's light,
/// the sky a gradient brighter toward it; the local wind (the 40×40 gust map) sets the roughness: puffs rough, lulls
/// glassy. PROBE: never merged.
enum LitWater {
    /// What the water draws this frame, written by `WaterNode.update` before `Fleet3D.update` reads it.
    struct Frame {
        /// The gust map over `gustRect` (world points): red 0.5 at the course wind, 1 a quarter more, 0 a quarter less.
        var gust: CGImage?
        var gustRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        /// Downwind, a unit vector in the world frame.
        var downwind = SIMD2<Float>(0, -1)
        /// The course wind's strength 0…1 (6…22 kn) and the foam's 0…1 (10…20 kn).
        var wind: Float = 0.5
        var foam: Float = 0
        /// Race seconds, wrapped at 600.
        var clock: Float = 0
        /// World points per screen point.
        var scale: Float = 1
    }
    nonisolated(unsafe) static var frame = Frame()
    /// The tilt drawn, radians off vertical (`GameScene` writes it each frame before the water draws).
    nonisolated(unsafe) static var tilt: Double = .pi / 4

    /// The venue's depth as a texture: red the shallows' weight (0 deep … 1 at the shallow limit and on land), green
    /// depth over the venue's deepest; `map0` (grid origin in metres, column axis) and `map1` (cell size, columns, rows,
    /// 1 when there is a grid) place it. A flat deep texel when the venue has no current.
    struct Depth {
        var image: CGImage
        var map0 = SIMD4<Float>(0, 0, 1, 0)
        var map1 = SIMD4<Float>(1, 1, 1, 0)
    }
    nonisolated(unsafe) static var depth = Depth(image: LitWater.image(bytes: [0, 255, 0, 255], width: 1, height: 1))

    static func setDepth(_ current: Venue.Current?) {
        guard let current else { return }
        let grid = current.grid
        var bytes: [UInt8] = []
        bytes.reserveCapacity(grid.nodeCount * 4)
        for imageRow in 0..<grid.rows {
            let row = grid.rows - 1 - imageRow
            for column in 0..<grid.columns {
                let d = current.depth(column: column, row: row)
                let weight = ChartGeometry.shallowsWeight(depth: d, maxDepth: current.maxDepth,
                                                          fraction: ChartStyle.standard.shallowFraction)
                let deep = current.maxDepth > 0 ? (d / current.maxDepth).clamped(to: 0...1) : 1
                bytes += [UInt8((weight * 255).rounded()), UInt8((deep * 255).rounded()), 0, 255]
            }
        }
        let axis = grid.columnAxis
        depth = Depth(image: image(bytes: bytes, width: grid.columns, height: grid.rows),
                      map0: SIMD4(Float(grid.origin.x), Float(grid.origin.y), Float(axis.x), Float(axis.y)),
                      map1: SIMD4(Float(grid.cellSize), Float(grid.columns), Float(grid.rows), 1))
    }

    /// The puffs' and lulls' sprites over the lit water, a share of today's alpha (`REGATTA_LIT_PUFFS`, default 0.5;
    /// 0 leaves them to the roughness alone).
    static let puffAlpha: CGFloat = {
        if let v = ProcessInfo.processInfo.environment["REGATTA_LIT_PUFFS"], let x = Double(v) { return CGFloat(x) }
        return WaterLook.current.isCel || WaterLook.current.isToon ? 0 : 0.5
    }()

    /// The sun, a unit vector in the screen's frame (x right, y up the screen, z up off the water): its bearing
    /// clockwise from screen-up and its elevation, degrees (`REGATTA_SUN` "bearing,elevation"); by default the fleet's
    /// light as it was, from the upper left and high.
    static let sun: SIMD3<Float> = {
        var bearing = -51.3, elevation = 51.3
        if let v = ProcessInfo.processInfo.environment["REGATTA_SUN"] {
            let parts = v.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { bearing = parts[0]; elevation = parts[1] }
        }
        let b = bearing * .pi / 180, e = elevation * .pi / 180
        return SIMD3(Float(sin(b) * cos(e)), Float(cos(b) * cos(e)), Float(sin(e)))
    }()

    nonisolated static func image(bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider, let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { preconditionFailure("lit water image") }
        return image
    }

    // MARK: - K: the SpriteKit shader

    static let kRect = SKUniform(name: "u_rect", vectorFloat4: .zero)
    static let kDown = SKUniform(name: "u_down", vectorFloat2: SIMD2(0, -1))
    static let kCam = SKUniform(name: "u_cam", vectorFloat2: SIMD2(1, 0))
    static let kView = SKUniform(name: "u_view", vectorFloat3: SIMD3(0, -0.7, 0.7))
    static let kSun = SKUniform(name: "u_sun", vectorFloat3: sun)
    static let kScale = SKUniform(name: "u_scale", float: 1)
    static let kWind = SKUniform(name: "u_wind", vectorFloat2: SIMD2(0.5, 0))
    static let kDepth = SKUniform(name: "u_depth", texture: SKTexture(cgImage: depth.image))
    static let kMap0 = SKUniform(name: "u_dmap0", vectorFloat4: .zero)
    static let kMap1 = SKUniform(name: "u_dmap1", vectorFloat4: .zero)

    /// The height field's slope (metres a metre) at `m` (metres): four waves and two octaves of chop. GLSL for K; J's
    /// Metal copy below is the same sums.
    static var kSource: String { """
    float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float vnoise(vec2 p) {
        vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
        float a = h21(i), b = h21(i + vec2(1.0, 0.0)), c = h21(i + vec2(0.0, 1.0)), d = h21(i + vec2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    vec3 sky(vec3 r, vec3 sun) {
        float up = clamp(r.z, 0.0, 1.0);
        vec3 horizon = vec3(0.80, 0.87, 0.93);
        vec3 zenith = vec3(0.28, 0.47, 0.74);
        vec3 c = mix(horizon, zenith, pow(up, 0.55));
        c += vec3(1.0, 0.93, 0.80) * 0.55 * pow(max(dot(r, sun), 0.0), 10.0);
        return c;
    }
    void main() {
        vec2 w = u_rect.xy + v_tex_coord * u_rect.zw;
        vec2 m = w / 8.0;
        float pxPerM = 8.0 / u_scale;
        vec2 guv = clamp((w - u_gust_origin) / u_gust_size, 0.0, 1.0);
        float g = texture2D(u_gust, guv).r * 2.0 - 1.0;
        float puff = max(g, 0.0), lull = max(-g, 0.0);
        float rough = clamp(u_wind.x * (1.0 + 0.9 * g), 0.04, 1.0);
        vec2 g_big = vec2(0.0);
        vec2 grad = vec2(0.0);
        float hgt = 0.0;
        {
        vec2 dn = u_down; float t = u_clock;
        vec2 dp = vec2(-dn.y, dn.x);
                        float amp = 0.5 + 0.7 * rough;
        for (int i = 0; i < 9; i++) {
            float fi = float(i);
            float lambda = 4.2 * pow(0.76, fi);
            // Directions spread about downwind (a hashed angle a wave, ±1.3 rad), short crests: each wave's
            // amplitude under its own drifting noise envelope about a wavelength across.
            float ang = (h21(vec2(fi, 3.7)) - 0.5) * 2.6 * (0.5 + 0.5 * h21(vec2(fi, 9.1)));
            if (i == 0) { ang = 0.0; }
            vec2 dir = dn * cos(ang) + dp * sin(ang);
            float k = 6.2831 / lambda;
            float om = sqrt(9.81 * k);
            float ca = cos(fi * 2.4), sa = sin(fi * 2.4);
            vec2 em = vec2(m.x * ca - m.y * sa, m.x * sa + m.y * ca) / (lambda * 1.4);
            float env = smoothstep(0.2, 0.85, vnoise(em + vec2(fi * 7.1, fi * 3.3) - dn * t * 0.12));
            float steep = (0.12 + 0.02 * fi) * amp * env * smoothstep(2.5, 6.0, lambda * pxPerM);
            float ph = k * dot(dir, m) - om * t + 6.2831 * h21(vec2(fi, 1.3));
            hgt += steep * sin(ph) * env;
            grad += steep * cos(ph) * dir;
            g_big += steep * cos(ph) * dir * smoothstep(\(Cel.bandLo), \(Cel.bandHi), lambda * pxPerM);
        }
        }
        vec3 wv = vec3(grad, hgt);
        vec3 nw = normalize(vec3(-wv.x, -wv.y, 1.0));
        vec3 n = vec3(nw.x * u_cam.x + nw.y * u_cam.y, -nw.x * u_cam.y + nw.y * u_cam.x, nw.z);
        vec3 v = u_view;
        vec3 l = u_sun;
        // Depth: the body colour, deep blue over the deepest water, the shallows' tint near the shallows and land.
        vec2 rel = m - u_dmap0.xy;
        vec2 ax = u_dmap0.zw;
        vec2 cr = vec2(dot(rel, ax), dot(rel, vec2(-ax.y, ax.x))) / u_dmap1.x;
        vec2 duv = (cr + 0.5) / u_dmap1.yz;
        vec4 dep = u_dmap1.w > 0.5 ? texture2D(u_depth, clamp(duv, 0.0, 1.0)) : vec4(0.0, 1.0, 0.0, 1.0);
        vec3 deepC = vec3(0.035, 0.17, 0.27);
        vec3 shallowC = vec3(0.09, 0.36, 0.40);
        vec3 body = mix(deepC, shallowC, dep.r) * (1.0 + 0.25 * dep.r);
        body *= 0.9 + 0.25 * max(dot(n, l), 0.0);
        body *= 1.0 - 0.3 * puff + 0.12 * lull;
        // Fresnel-weighted sky, exaggerated for the phone; rough water scatters the reflection (darker puffs),
        // glassy water mirrors the sky (lighter lulls).
        float ndv = max(dot(n, v), 0.0);
        float F = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
        vec3 r = reflect(-v, n);
        float cohere = clamp(1.15 - 0.55 * rough - 0.35 * puff + 0.45 * lull, 0.25, 1.6);
        vec3 refl = sky(r, l) * clamp(F * 6.0 + 0.04, 0.0, 1.0) * cohere;
        // Sun glitter: Blinn-Phong, sharper on glassy water.
        vec3 h = normalize(l + v);
        float shin = mix(600.0, 90.0, rough);
        float spec = pow(max(dot(n, h), 0.0), shin) * (shin + 8.0) / 25.0 * 0.22;
        vec3 col = body + refl + vec3(1.0, 0.96, 0.88) * spec * (1.0 - 0.5 * puff);
        // Foam on the highest crests above the foam wind, more in puffs.
        float patchy = smoothstep(0.78, 0.97, vnoise(m / 6.0 - u_down * u_clock * 0.4)) * smoothstep(0.5, 0.8, vnoise(m / 2.3 + vec2(5.0, 1.0) - u_down * u_clock * 0.7));
        float crest = patchy * smoothstep(0.45, 0.85, vnoise(m * 1.4 - u_down * u_clock * 0.8)) * smoothstep(0.0, 0.6, wv.z + 0.3);
        float foam = crest * u_wind.y * (0.3 + 0.9 * puff) * (1.0 - lull) * smoothstep(3.0, 8.0, pxPerM);
    \(finish)
    }
    """ }

    /// K's finish: the lighting as it comes, foam blended on.
    static let kFinish = """
        col = mix(col, vec3(0.92, 0.95, 0.97), clamp(foam * 0.8, 0.0, 0.7));
        gl_FragColor = vec4(min(col, vec3(1.0)), 1.0);
    """

    static var finish: String { WaterLook.current.isCel ? Cel.current.source : kFinish }

    /// #604 round 5: K cel-shaded. The light (K's body + sky, times a Lambert term from the fleet's sun) over what a
    /// flat surface in the course wind would show at the same place is the band scalar `s`: puffs (rougher, darker
    /// body, scattered sky) push it down, lulls up, wave faces toward the sun up. `s` is cut at the thresholds into
    /// flat tones of the flat surface's colour (gains, as Lambert scales a hull's colour), each edge a smoothstep
    /// `edge` screen pixels wide (`fwidth`); glitter is one flat tone where the sun's highlight passes `spec`; foam one
    /// flat white where K's foam passes `foam`; N adds a lighter rim `rim` pixels wide on the lit side of the top
    /// step. Knobs: `REGATTA_CEL` thresholds "t1,t2,…", `REGATTA_CEL_GAIN` "g0,g1,…" (one more than thresholds),
    /// `REGATTA_CEL_EDGE`, `REGATTA_CEL_SPEC`, `REGATTA_CEL_FOAM`, `REGATTA_CEL_RIM`, `REGATTA_CEL_LAMB`,
    /// `REGATTA_CEL_SKY` (the top band's mix toward the sky's colour).
    struct Cel {
        var thresholds: [Double]
        var gains: [Double]
        var edge = 0.75
        var spec = 0.9
        var foam = 0.35
        var rim = 0.0
        var rimGain = 1.18
        var lambert = 1.5
        var sky = 0.2
        /// The shortest wave (screen points) the bands follow (`REGATTA_CEL_BANDPX`).
        static let bandPx: Double = ProcessInfo.processInfo.environment["REGATTA_CEL_BANDPX"].flatMap(Double.init) ?? 9
        static let bandLo = String(format: "%.2f", bandPx * 0.6)
        static let bandHi = String(format: "%.2f", bandPx)

        static let current: Cel = {
            var c: Cel = switch WaterLook.current {
            case .m: Cel(thresholds: [1.0], gains: [0.78, 1.2])
            case .n: Cel(thresholds: [0.86, 1.0, 1.14], gains: [0.7, 0.88, 1.06, 1.26], rim: 1.5)
            default: Cel(thresholds: [0.9, 1.1], gains: [0.74, 1.0, 1.26])
            }
            let env = ProcessInfo.processInfo.environment
            func list(_ key: String) -> [Double]? {
                env[key].map { $0.split(separator: ",").compactMap { Double($0) } }
            }
            if let t = list("REGATTA_CEL"), !t.isEmpty { c.thresholds = t }
            if let g = list("REGATTA_CEL_GAIN"), !g.isEmpty { c.gains = g }
            while c.gains.count < c.thresholds.count + 1 { c.gains.append((c.gains.last ?? 1) * 1.2) }
            if let v = env["REGATTA_CEL_EDGE"].flatMap(Double.init) { c.edge = v }
            if let v = env["REGATTA_CEL_SPEC"].flatMap(Double.init) { c.spec = v }
            if let v = env["REGATTA_CEL_FOAM"].flatMap(Double.init) { c.foam = v }
            if let v = env["REGATTA_CEL_RIM"].flatMap(Double.init) { c.rim = v }
            if let v = env["REGATTA_CEL_RIMGAIN"].flatMap(Double.init) { c.rimGain = v }
            if let v = env["REGATTA_CEL_LAMB"].flatMap(Double.init) { c.lambert = v }
            if let v = env["REGATTA_CEL_SKY"].flatMap(Double.init) { c.sky = v }
            print("#604 cel \(WaterLook.current): \(c)")
            return c
        }()

        var source: String {
            func f(_ x: Double) -> String { String(format: "%.4f", x) }
            var bands = "    vec3 col0 = base0 * \(f(gains[0]));\n"
            for (i, t) in thresholds.enumerated() {
                let top = i == thresholds.count - 1
                let tone = top ? "mix(base0 * \(f(gains[i + 1])), skyC, \(f(sky)))" : "base0 * \(f(gains[i + 1]))"
                bands += "    col0 = mix(col0, \(tone), smoothstep(\(f(t)) - fw, \(f(t)) + fw, s));\n"
            }
            let top = thresholds.last ?? 1
            let rimCode = rim > 0 ? """
                float dpx = (s - \(f(top))) / max(fwidth(s), 1e-5);
                float rimA = smoothstep(-0.5, 0.5, dpx) * (1.0 - smoothstep(\(f(rim)) - 0.5, \(f(rim)) + 0.5, dpx));
                col0 = mix(col0, mix(base0 * \(f(gains.last! * rimGain)), skyC, \(f(sky))), rimA);
            """ : ""
            return """
                vec3 lw = vec3(0.2126, 0.7152, 0.0722);
                vec3 body0 = mix(deepC, shallowC, dep.r) * (1.0 + 0.25 * dep.r) * (0.9 + 0.25 * max(l.z, 0.0));
                float F0 = 0.02 + 0.98 * pow(1.0 - max(v.z, 0.0), 5.0);
                float coh0 = clamp(1.15 - 0.55 * u_wind.x, 0.25, 1.6);
                vec3 base0 = body0 + sky(reflect(-v, vec3(0.0, 0.0, 1.0)), l) * clamp(F0 * 6.0 + 0.04, 0.0, 1.0) * coh0;
                vec3 skyC = sky(vec3(0.0, 0.5, 0.866), l) * 0.75;
                // The bands follow the waves a few screen points long and up (`bandPx`); the shorter ones only glitter.
                vec3 nbw = normalize(vec3(-g_big.x, -g_big.y, 1.0));
                vec3 nb = vec3(nbw.x * u_cam.x + nbw.y * u_cam.y, -nbw.x * u_cam.y + nbw.y * u_cam.x, nbw.z);
                float FB = 0.02 + 0.98 * pow(1.0 - max(dot(nb, v), 0.0), 5.0);
                vec3 reflB = sky(reflect(-v, nb), l) * clamp(FB * 6.0 + 0.04, 0.0, 1.0) * cohere;
                float lam = max(dot(nb, l), 0.0) / max(l.z, 0.05);
                float s = dot(body + reflB, lw) / max(dot(base0, lw), 1e-3) * pow(lam, \(f(lambert)));
                float fw = max(fwidth(s), 1e-5) * \(f(edge));
            \(bands)\(rimCode)
                float sp = spec * (1.0 - 0.5 * puff);
                float fws = max(fwidth(sp), 1e-5) * \(f(edge));
                col0 = mix(col0, vec3(1.0, 0.97, 0.88), smoothstep(\(f(spec)) - fws, \(f(spec)) + fws, sp));
                float fwf = max(fwidth(foam), 1e-5) * \(f(edge));
                col0 = mix(col0, vec3(0.93, 0.96, 0.98), smoothstep(\(f(foam)) - fwf, \(f(foam)) + fwf, foam));
                gl_FragColor = vec4(min(col0, vec3(1.0)), 1.0);
            """
        }
    }

    static let kShader: SKShader = SKShader(
        source: WaterLook.current == .o6 ? Toon6.current.source : (WaterLook.current.isToon ? Toon.current.source : kSource),
        uniforms: [WaterNode.litClock, kRect, kDown, kCam, kView, kSun, kScale, kWind, kDepth, kMap0, kMap1,
                   WaterNode.litGust, WaterNode.litGustOrigin, WaterNode.litGustSize])

    // MARK: - J: the SceneKit plane

    /// The surface shader modifier: the world point under each fragment from its scene position, the same height
    /// field's normal turned into the scene and the view, the depth's body colour, the roughness from the gust map.
    static let jModifier = """
    float h21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float vnoise(float2 p) {
        float2 i = floor(p); float2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
        float a = h21(i), b = h21(i + float2(1.0, 0.0)), c = h21(i + float2(0.0, 1.0)), d = h21(i + float2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    float2 waveSlope(float2 m, float2 dn, float t, float rough, float pxPerM) {
        float2 dp = float2(-dn.y, dn.x);
        float2 grad = float2(0.0);
        float amp = 0.5 + 0.7 * rough;
        for (int i = 0; i < 9; i++) {
            float fi = float(i);
            float lambda = 4.2 * pow(0.76, fi);
            // Directions spread about downwind (a hashed angle a wave, ±1.3 rad), short crests: each wave's
            // amplitude under its own drifting noise envelope about a wavelength across.
            float ang = (h21(float2(fi, 3.7)) - 0.5) * 2.6 * (0.5 + 0.5 * h21(float2(fi, 9.1)));
            if (i == 0) { ang = 0.0; }
            float2 dir = dn * cos(ang) + dp * sin(ang);
            float k = 6.2831 / lambda;
            float om = sqrt(9.81 * k);
            float ca = cos(fi * 2.4), sa = sin(fi * 2.4);
            float2 em = float2(m.x * ca - m.y * sa, m.x * sa + m.y * ca) / (lambda * 1.4);
            float env = smoothstep(0.2, 0.85, vnoise(em + float2(fi * 7.1, fi * 3.3) - dn * t * 0.12));
            float steep = (0.12 + 0.02 * fi) * amp * env * smoothstep(2.5, 6.0, lambda * pxPerM);
            float ph = k * dot(dir, m) - om * t + 6.2831 * h21(float2(fi, 1.3));
            grad += steep * cos(ph) * dir;
        }
        return grad;
    }
    #pragma arguments
    float u_clock;
    float u_scale;
    float u_wind;
    float u_body;
    float u_roughPuff;
    float2 u_center;
    float2 u_rho;
    float2 u_down;
    float4 u_gustRect;
    float4 u_dmap0;
    float4 u_dmap1;
    texture2d<float> u_gust;
    texture2d<float> u_depth;
    #pragma body
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float3 sp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float ga = sp.x, gb = -sp.z;
    float2 w = u_center + float2(ga * u_rho.x + gb * u_rho.y, -ga * u_rho.y + gb * u_rho.x);
    float2 m = w / 8.0;
    float pxPerM = 8.0 / u_scale;
    float2 guv = clamp((w - u_gustRect.xy) / u_gustRect.zw, 0.0, 1.0);
    guv.y = 1.0 - guv.y;
    float g = u_gust.sample(lin, guv).r * 2.0 - 1.0;
    float puff = max(g, 0.0), lull = max(-g, 0.0);
    float rough = clamp(u_wind * (1.0 + 0.9 * g), 0.04, 1.0);
    float2 s = waveSlope(m, u_down, u_clock, rough, pxPerM);
    float3 nw = normalize(float3(-s.x, -s.y, 1.0));
    // World (east, north, up) to the scene: x = e·c − n·s, y = up, z = −(e·s + n·c), as `Fleet3D.ground`.
    float3 ns = float3(nw.x * u_rho.x - nw.y * u_rho.y, nw.z, -(nw.x * u_rho.y + nw.y * u_rho.x));
    _surface.normal = normalize((scn_frame.viewTransform * float4(ns, 0.0)).xyz);
    float2 rel = m - u_dmap0.xy;
    float2 ax = u_dmap0.zw;
    float2 cr = float2(dot(rel, ax), dot(rel, float2(ax.y, -ax.x) * -1.0)) / u_dmap1.x;
    float2 duv = (cr + 0.5) / u_dmap1.yz;
    duv.y = 1.0 - duv.y;
    float4 dep = u_dmap1.w > 0.5 ? u_depth.sample(lin, clamp(duv, 0.0, 1.0)) : float4(0.0, 1.0, 0.0, 1.0);
    float3 deepC = float3(0.035, 0.17, 0.27);
    float3 shallowC = float3(0.09, 0.36, 0.40);
    float3 body = mix(deepC, shallowC, dep.r) * (1.0 + 0.25 * dep.r) * u_body;
    body *= 1.0 - 0.3 * puff + 0.12 * lull;
    // The body's colour is light coming up out of the water, not the sun on a matte surface: emitted, no diffuse; the surface's own light is the sky's and the sun's reflection.
    _surface.emission = float4(body, 1.0);
    _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    _surface.metalness = 0.0;
    // Briefed: puffs rough (u_roughPuff 1, `REGATTA_ROUGH_PUFF`); with the sun ahead that spreads the glitter over
    // them and they read lighter, so by default the roughness follows the wind only gently.
    _surface.roughness = clamp(0.1 + 0.15 * rough + u_roughPuff * (0.5 * puff - 0.05 * lull), 0.04, 0.85);
    """

    /// The sky for J's lighting environment: an equirectangular gradient, pale at the horizon, deep blue overhead,
    /// a glow toward the sun, dark below the horizon.
    static func skyImage() -> CGImage {
        let w = 256, h = 128
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let l = sun
        // The sun in the scene's frame: x right, y up, z toward the viewer (screen-down).
        let sunScene = SIMD3<Float>(l.x, l.z, -l.y)
        for y in 0..<h {
            let lat = (0.5 - (Float(y) + 0.5) / Float(h)) * .pi
            for x in 0..<w {
                let lon = ((Float(x) + 0.5) / Float(w)) * 2 * .pi - .pi
                let d = SIMD3<Float>(cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon))
                var c: SIMD3<Float>
                if lat >= 0 {
                    let up = pow(sin(lat), 0.55)
                    c = SIMD3(0.80, 0.87, 0.93) * (1 - up) + SIMD3(0.28, 0.47, 0.74) * up
                } else {
                    c = SIMD3(0.10, 0.16, 0.20)
                }
                c += SIMD3(1.0, 0.93, 0.80) * 0.6 * pow(max(simd_dot(d, sunScene), 0), 10)
                let k = (y * w + x) * 4
                bytes[k] = UInt8(min(c.x, 1) * 255)
                bytes[k + 1] = UInt8(min(c.y, 1) * 255)
                bytes[k + 2] = UInt8(min(c.z, 1) * 255)
                bytes[k + 3] = 255
            }
        }
        return image(bytes: bytes, width: w, height: h)
    }
}

/// J: the lit plane, in the fleet's scene but drawn by its own camera into its own `SK3DNode` under the water's
/// sprites (the fleet's `SK3DNode` sits over the chart, cues and shadows; an opaque plane there would hide them).
final class LitWaterPlane {
    let node: SK3DNode
    let cameraNode = SCNNode()
    let camera = SCNCamera()
    let plane = SCNPlane(width: 1, height: 1)
    let planeNode: SCNNode
    let material = SCNMaterial()
    private let gustProperty = SCNMaterialProperty(contents: LitWater.depth.image)
    private let depthProperty = SCNMaterialProperty(contents: LitWater.depth.image)
    static let category = 2

    init(scene: SCNScene, fleetCamera: SCNNode, sceneSize: CGSize) {
        node = SK3DNode(viewportSize: sceneSize)
        node.scnScene = scene
        node.autoenablesDefaultLighting = false
        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 40_000
        camera.categoryBitMask = Self.category
        cameraNode.camera = camera
        fleetCamera.addChildNode(cameraNode)
        node.pointOfView = cameraNode

        material.lightingModel = .physicallyBased
        material.writesToDepthBuffer = false
        material.diffuse.contents = UIColor(red: 0.04, green: 0.17, blue: 0.27, alpha: 1)
        material.emission.contents = UIColor(red: 0.04, green: 0.17, blue: 0.27, alpha: 1)
        material.metalness.contents = 0.0
        material.roughness.contents = 0.2
        material.shaderModifiers = [.surface: LitWater.jModifier]
        gustProperty.wrapS = .clamp
        gustProperty.wrapT = .clamp
        gustProperty.minificationFilter = .linear
        gustProperty.magnificationFilter = .linear
        depthProperty.minificationFilter = .linear
        depthProperty.magnificationFilter = .linear
        depthProperty.contents = LitWater.depth.image
        material.setValue(gustProperty, forKey: "u_gust")
        material.setValue(depthProperty, forKey: "u_depth")
        let d = LitWater.depth
        material.setValue(SCNVector4(d.map0.x, d.map0.y, d.map0.z, d.map0.w), forKey: "u_dmap0")
        material.setValue(SCNVector4(d.map1.x, d.map1.y, d.map1.z, d.map1.w), forKey: "u_dmap1")
        material.setValue(Self.bodyGain, forKey: "u_body")
        material.setValue(Self.roughPuff, forKey: "u_roughPuff")
        plane.materials = [material]
        planeNode = SCNNode(geometry: plane)
        planeNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        planeNode.categoryBitMask = Self.category
        scene.rootNode.addChildNode(planeNode)

        // The sun on the water: the fleet's light's direction, its own exposure, lighting only the plane.
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = Self.sunIntensity
        sun.categoryBitMask = Self.category
        let sunNode = SCNNode()
        sunNode.light = sun
        let l = LitWater.sun
        sunNode.position = SCNVector3(l.x, l.z, -l.y)
        sunNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sunNode)
        scene.lightingEnvironment.contents = LitWater.skyImage()
        scene.lightingEnvironment.intensity = Self.skyIntensity
    }

    static let skyIntensity: CGFloat = {
        if let v = ProcessInfo.processInfo.environment["REGATTA_SKY"], let x = Double(v) { return CGFloat(x) }
        return 3
    }()
    static let sunIntensity: CGFloat = {
        if let v = ProcessInfo.processInfo.environment["REGATTA_SUNI"], let x = Double(v) { return CGFloat(x) }
        return 14000
    }()
    static let roughPuff: NSNumber = {
        if let v = ProcessInfo.processInfo.environment["REGATTA_ROUGH_PUFF"], let x = Double(v) { return NSNumber(value: x) }
        return 0
    }()
    static let bodyGain: NSNumber = {
        if let v = ProcessInfo.processInfo.environment["REGATTA_BODY"], let x = Double(v) { return NSNumber(value: x) }
        return 1.0
    }()

    /// Inside `Fleet3D.update`'s transaction: the plane under the view, the uniforms for this frame.
    func update(center: CGPoint, rho: CGFloat, scale: Double, tilt: Double, sceneSize: CGSize, cameraScale: CGFloat) {
        if node.viewportSize != sceneSize { node.viewportSize = sceneSize }
        if camera.orthographicScale != scale { camera.orthographicScale = scale }
        let width = sceneSize.width * cameraScale
        let height = sceneSize.height * cameraScale / max(CGFloat(cos(tilt)), 0.2)
        let side = (hypot(width, height) * 1.15).rounded(.up)
        if plane.width != side { plane.width = side; plane.height = side }
        let f = LitWater.frame
        material.setValue(NSNumber(value: f.clock), forKey: "u_clock")
        material.setValue(NSNumber(value: f.scale), forKey: "u_scale")
        material.setValue(NSNumber(value: f.wind), forKey: "u_wind")
        material.setValue(NSValue(cgPoint: center), forKey: "u_center")
        material.setValue(NSValue(cgPoint: CGPoint(x: cos(rho), y: sin(rho))), forKey: "u_rho")
        material.setValue(NSValue(cgPoint: CGPoint(x: CGFloat(f.downwind.x), y: CGFloat(f.downwind.y))), forKey: "u_down")
        let r = f.gustRect
        material.setValue(SCNVector4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)), forKey: "u_gustRect")
        if let gust = f.gust { gustProperty.contents = gust }
    }
}

/// #604 round 6: O6 (was O; knobs now `REGATTA_TOON6_*`), the toon ocean after the owner's reference ("Toon Ocean Animation"): a calm sea in three flat
/// tones with large smooth pale islands and sparse four-point stars. The surface is a long swell only (three
/// components, 13–34 m, periods 5–8 s) under a slow noise warp, so the tones' regions are organic islands, not
/// stripes. Two scalars from the swell's slope (screen frame) and height: `pale` the sky term (faces tilted toward the
/// viewer, and the crests), `deep` the sun-shadow term (faces turned from the sun, and the troughs); each cut at a
/// threshold, the edge `soft` screen pixels wide. The shapes keep their screen size: the swell's scale steps by
/// octaves with the camera (blended before the cut). The local wind moves the thresholds: puffs grow the deep tone and
/// shrink the islands (and above ~12 kn add flat foam flecks), lulls the opposite. Stars: one candidate a cell of
/// about `cell` screen points, on a cycle of its own (1.4–2.4 s, fading in and out), shown when its spot is well
/// inside a pale island. Knobs (env): `REGATTA_TOON_DEEP|MID|PALE` hex tones, `REGATTA_TOON_SCALE` (O2 2),
/// `REGATTA_TOON_SOFT` px, `REGATTA_TOON_SPARKS` share of cells, `REGATTA_TOON_TP|TD` thresholds,
/// `REGATTA_TOON_PUFF` the wind's threshold shift, `REGATTA_TOON_WARP` metres, `REGATTA_TOON_REF` the camera scale
/// the shapes are sized at, `REGATTA_TOON_CELL` star cell (screen points). PROBE: never merged.
extension LitWater {
    struct Toon6 {
        var deep = SIMD3<Double>(0x0C, 0x32, 0x57) / 255
        var mid = SIMD3<Double>(0x17, 0x4D, 0x70) / 255
        var pale = SIMD3<Double>(0x7D, 0xB6, 0xC2) / 255
        var scale = 0.4
        var soft = 2.5
        var sparks = 0.9
        var tPale = 0.9
        var tDeep = 0.55
        var puff = 1.2
        var drift = 0.55
        var warp = 7.0
        var ref = 1.0
        var cell = 36.0

        static let current: Toon6 = {
            var t = Toon6()
            let env = ProcessInfo.processInfo.environment
            func hex(_ key: String) -> SIMD3<Double>? {
                guard let v = env[key], let n = Int(v.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
                return SIMD3(Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)) / 255
            }
            func num(_ key: String) -> Double? { env[key].flatMap(Double.init) }
            if let c = hex("REGATTA_TOON6_DEEP") { t.deep = c }
            if let c = hex("REGATTA_TOON6_MID") { t.mid = c }
            if let c = hex("REGATTA_TOON6_PALE") { t.pale = c }
            if let v = num("REGATTA_TOON6_SCALE") { t.scale = v }
            if let v = num("REGATTA_TOON6_SOFT") { t.soft = v }
            if let v = num("REGATTA_TOON6_SPARKS") { t.sparks = v }
            if let v = num("REGATTA_TOON6_TP") { t.tPale = v }
            if let v = num("REGATTA_TOON6_TD") { t.tDeep = v }
            if let v = num("REGATTA_TOON6_PUFF") { t.puff = v }
            if let v = num("REGATTA_TOON6_DRIFT") { t.drift = v }
            if let v = num("REGATTA_TOON6_WARP") { t.warp = v }
            if let v = num("REGATTA_TOON6_REF") { t.ref = v }
            if let v = num("REGATTA_TOON6_CELL") { t.cell = v }
            print("#604 toon6 \(WaterLook.current): \(t)")
            return t
        }()

        var source: String {
            func f(_ x: Double) -> String { String(format: "%.4f", x) }
            func v3(_ c: SIMD3<Double>) -> String { "vec3(\(f(c.x)), \(f(c.y)), \(f(c.z)))" }
            return """
            float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
            float vnoise(vec2 p) {
                vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
                float a = h21(i), b = h21(i + vec2(1.0, 0.0)), c = h21(i + vec2(0.0, 1.0)), d = h21(i + vec2(1.0, 1.0));
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }
            // The swell at `m` (metres) for octave scale `S`: x the pale (sky) term, y the deep (sun-shadow) term, both
            // unit-ish. The deep term reads the same waves at other phases under the same warp, so its shapes are its own.
            vec2 swell(vec2 m, float S, float t, vec2 dn, vec2 cam, vec2 sunD) {
                vec2 dp = vec2(-dn.y, dn.x);
                vec2 mm = m / S;
                // The slow warp: two value-noise octaves, rotated apart, drifting downwind.
                vec2 q1 = mm / 31.0 - dn * t * 0.010;
                vec2 q2 = vec2(mm.x * 0.8 - mm.y * 0.6, mm.x * 0.6 + mm.y * 0.8) / 13.0 + dp * t * 0.012;
                vec2 wv = vec2(vnoise(q1) - 0.5, vnoise(q1 + vec2(7.3, 2.1)) - 0.5) * 2.0
                        + vec2(vnoise(q2 + vec2(3.1, 9.7)) - 0.5, vnoise(q2 + vec2(1.7, 4.4)) - 0.5) * 0.9;
                // A finer octave crinkles the islands' outlines (bays and capes), still smooth at the edge.
                vec2 q3 = vec2(mm.x * 0.5 + mm.y * 0.87, -mm.x * 0.87 + mm.y * 0.5) / 4.6 - dn * t * 0.02;
                wv += vec2(vnoise(q3) - 0.5, vnoise(q3 + vec2(6.6, 3.9)) - 0.5) * 0.45;
                vec2 q4 = vec2(mm.x * 0.94 - mm.y * 0.34, mm.x * 0.34 + mm.y * 0.94) / 1.9 + dp * t * 0.03;
                wv += vec2(vnoise(q4 + vec2(2.8, 0.4)) - 0.5, vnoise(q4 + vec2(8.1, 5.2)) - 0.5) * 0.16;
                vec2 p = mm + wv * \(f(warp));
                vec2 g = vec2(0.0); float h = 0.0;
                vec2 g2 = vec2(0.0); float h2 = 0.0;
                for (int i = 0; i < 3; i++) {
                    float fi = float(i);
                    float lambda = i == 0 ? 34.0 : (i == 1 ? 21.0 : 13.0);
                    float period = i == 0 ? 8.0 : (i == 1 ? 6.5 : 5.0);
                    float ang = i == 0 ? 0.0 : (i == 1 ? 0.5 : -0.42);
                    vec2 dir = dn * cos(ang) + dp * sin(ang);
                    float k = 6.2831 / lambda;
                    // Calm: the components glide at nearly one speed (`period` sets the spread), so the islands drift and
                    // slowly reshape instead of boiling.
                    float c = \(f(drift)) * (1.0 + 0.6 / period);
                    float ph = k * (dot(dir, p) - c * t) + 6.2831 * h21(vec2(fi, 1.3));
                    g += cos(ph) * dir;
                    h += sin(ph);
                    float ph2 = ph + 2.3 + 1.7 * fi;
                    g2 += cos(ph2) * dir;
                    h2 += sin(ph2);
                }
                vec2 gs = vec2(g.x * cam.x + g.y * cam.y, -g.x * cam.y + g.y * cam.x);
                vec2 gs2 = vec2(g2.x * cam.x + g2.y * cam.y, -g2.x * cam.y + g2.y * cam.x);
                return vec2(gs.y * 0.8 + h * 0.6, dot(gs2, sunD) * 0.8 - h2 * 0.55) / 1.7;
            }
            void main() {
                vec2 w = u_rect.xy + v_tex_coord * u_rect.zw;
                vec2 m = w / 8.0;
                float t = u_clock;
                vec2 guv = clamp((w - u_gust_origin) / u_gust_size, 0.0, 1.0);
                float gu = texture2D(u_gust, guv).r * 2.0 - 1.0;
                float puff = smoothstep(0.0, 0.8, gu), lull = smoothstep(0.0, 0.8, -gu);
                // The octave ladder: the shapes keep their screen size as the camera zooms.
                float z = log2(max(u_scale / \(f(ref)), 1.0));
                float zl = floor(z); float zf = fract(z);
                float S0 = \(f(scale)) * exp2(zl);
                vec2 sunD = normalize(u_sun.xy + vec2(1e-4, 0.0));
                // Blend the two octaves, keeping the variance (so the cut covers the same share mid-blend).
                float zb = smoothstep(0.3, 0.7, zf);
                float zn = inversesqrt((1.0 - zb) * (1.0 - zb) + zb * zb);
                vec2 sw = zb < 0.001 ? swell(m, S0, t, u_down, u_cam, sunD) : (zb > 0.999 ? swell(m, S0 * 2.0, t, u_down, u_cam, sunD)
                    : (swell(m, S0, t, u_down, u_cam, sunD) * (1.0 - zb) + swell(m, S0 * 2.0, t, u_down, u_cam, sunD) * zb) * zn);
                float pale = sw.x;
                float deep = sw.y;
                float tp = \(f(tPale)) + \(f(puff)) * puff - \(f(puff)) * 0.8 * lull;
                float td = \(f(tDeep)) - \(f(puff)) * puff + \(f(puff)) * 0.8 * lull;
                float ep = max(fwidth(pale), 1e-5) * \(f(soft)) * 0.5;
                float ed = max(fwidth(deep), 1e-5) * \(f(soft)) * 0.5;
                float pA = smoothstep(tp - ep, tp + ep, pale);
                float dA = smoothstep(td - ed, td + ed, deep);
                // Depth: a touch of the shallows' teal in every tone.
                vec2 rel = m - u_dmap0.xy;
                vec2 ax = u_dmap0.zw;
                vec2 cr = vec2(dot(rel, ax), dot(rel, vec2(-ax.y, ax.x))) / u_dmap1.x;
                vec2 duv = (cr + 0.5) / u_dmap1.yz;
                vec4 dep = u_dmap1.w > 0.5 ? texture2D(u_depth, clamp(duv, 0.0, 1.0)) : vec4(0.0, 1.0, 0.0, 1.0);
                vec3 deepC = \(v3(deep));
                vec3 midC = \(v3(mid));
                vec3 paleC = \(v3(pale));
                vec3 tealC = vec3(0.09, 0.36, 0.40);
                midC = mix(midC, deepC, 0.4 * puff);
                midC = mix(midC, paleC, 0.12 * lull);
                midC = mix(midC, tealC, 0.35 * dep.r);
                deepC = mix(deepC, tealC, 0.25 * dep.r);
                vec3 col = mix(midC, deepC, dA);
                col = mix(col, paleC, pA);
                // Foam flecks: flat, few, in the puffs above ~12 kn.
                vec2 fm = m / (0.9 * S0) - u_down * t * 0.25;
                float fl = vnoise(fm) * vnoise(fm * 0.37 + vec2(4.1, 8.3));
                float ft = 0.80 - 0.06 * smoothstep(0.2, 0.8, u_wind.y);
                float fe = max(fwidth(fl), 1e-5) * \(f(soft)) * 0.5;
                float foamA = smoothstep(ft - fe, ft + fe, fl) * smoothstep(0.15, 0.35, u_wind.y) * smoothstep(0.25, 0.6, puff);
                col = mix(col, vec3(0.90, 0.95, 0.97), foamA);
                // Stars: a candidate a cell (world-fixed, drifting downwind), its own cycle, inside the pale islands.
                float Sr = \(f(scale)) * exp2(zl + (zb > 0.5 ? 1.0 : 0.0));
                float cellM = \(f(cell)) * \(f(ref)) / 8.0 * Sr / \(f(scale));
                vec2 pm = m - u_down * t * 0.35;
                vec2 ci = floor(pm / cellM);
                float per = 1.4 + h21(ci + vec2(3.3, 7.7));
                float phase = t / per + h21(ci + vec2(9.1, 1.9));
                float cyc = floor(phase); float life = fract(phase);
                vec2 rnd = vec2(h21(ci + vec2(cyc, 5.5)), h21(ci + vec2(2.2, cyc)));
                vec2 sm = (ci + 0.22 + 0.56 * rnd) * cellM;
                float on = step(h21(ci + vec2(cyc * 1.7, 11.0)), \(f(sparks)));
                vec2 sw0 = sm + u_down * t * 0.35;
                if (on > 0.0) {
                    float sPale = swell(sw0, zb < 0.5 ? S0 : S0 * 2.0, t, u_down, u_cam, sunD).x;
                    on *= smoothstep(tp + 0.02, tp + 0.25, sPale);
                }
                vec2 dw = (sw0 - m) * 8.0 / u_scale;
                vec2 ds = vec2(dw.x * u_cam.x + dw.y * u_cam.y, -dw.x * u_cam.y + dw.y * u_cam.x);
                ds.y *= u_view.z;
                float fade = sin(3.14159 * life); fade *= fade;
                float core = exp(-(ds.x * ds.x * 0.35 + ds.y * ds.y) / 4.0);
                float glow = exp(-(ds.x * ds.x * 0.3 + ds.y * ds.y) / 30.0) * 0.4;
                float armX = exp(-abs(ds.x) / 8.0) * exp(-ds.y * ds.y / 0.7);
                float armY = exp(-abs(ds.y) / 3.8) * exp(-ds.x * ds.x / 0.7);
                float star = clamp((core * 1.6 + glow + armX + 0.8 * armY) * fade * on, 0.0, 1.0);
                col = mix(col, vec3(1.0, 0.99, 0.95), star);
                gl_FragColor = vec4(col, 1.0);
            }
            """
        }
    }
}

/// #604 round 7: O, the toon ocean after the owner's second read of the reference: "the dark tone almost always
/// surrounds the light tone". A mid field with pale islands, each carrying its own deep fringe: the island's back face,
/// the same shape grown a little and pushed to its far side (screen-up, away from the viewer), so the deep hugs the
/// pale and fades back into mid; no free-standing deep. Islands come from three layers of warped noise cut high (cells
/// `size` × 30, 12, 5 m): mostly small flecks, some medium, a few large; a slow low-frequency field moves the layers'
/// cuts apart so neighbours differ in size and spacing. Zooming out the small layer, then the medium, close (their
/// cuts rise), and every cut rises a little more (`calm`), so the planing view is calmer than the start. Puffs: mid
/// toward deep, pale shrinks, fringes grow, flecks above ~12 kn. Lulls: pale grows, fringes thin, small flecks go
/// (glassy). Stars: larger and streakier, only inside the medium and large islands. Knobs (env): `REGATTA_TOON_DEEP|
/// MID|PALE` hex, `REGATTA_TOON_SIZE` (O2 2), `REGATTA_TOON_TA|TB|TC` the layers' cuts, `REGATTA_TOON_RIM` (deep
/// all round, in field units), `REGATTA_TOON_SHADOW` (the far-side fringe's growth), `REGATTA_TOON_OFF` (its push, a
/// share of the cell), `REGATTA_TOON_SOFT` px, `REGATTA_TOON_SPARKS`, `REGATTA_TOON_CELL` (star cell, scene points),
/// `REGATTA_TOON_PUFF`, `REGATTA_TOON_CALM`, `REGATTA_TOON_WARP` m, `REGATTA_TOON_DRIFT` m/s, `REGATTA_TOON_REF`
/// (the camera scale the sizes are set at). PROBE: never merged.
extension LitWater {
    struct Toon {
        var deep = SIMD3<Double>(0x2C, 0x48, 0x6E) / 255
        var mid = SIMD3<Double>(0x3A, 0x68, 0x88) / 255
        var pale = SIMD3<Double>(0x7C, 0xB4, 0xBE) / 255
        var size = 0.4
        var tA = 0.69
        var tB = 0.69
        var tC = 0.665
        var rim = 0.022
        var shadow = 0.05
        var off = 0.26
        var soft = 2.0
        var sparks = 0.9
        var cell = 44.0
        var stretch = 2.0
        var puff = 1.0
        var calm = 0.03
        var warp = 4.0
        var drift = 0.25
        var ref = 1.0

        static let current: Toon = {
            var t = Toon()
            if WaterLook.current == .o2 { t.size *= 2 }
            let env = ProcessInfo.processInfo.environment
            func hex(_ key: String) -> SIMD3<Double>? {
                guard let v = env[key], let n = Int(v.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
                return SIMD3(Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)) / 255
            }
            func num(_ key: String) -> Double? { env[key].flatMap(Double.init) }
            if let c = hex("REGATTA_TOON_DEEP") { t.deep = c }
            if let c = hex("REGATTA_TOON_MID") { t.mid = c }
            if let c = hex("REGATTA_TOON_PALE") { t.pale = c }
            if let v = num("REGATTA_TOON_SIZE") { t.size = v }
            if let v = num("REGATTA_TOON_TA") { t.tA = v }
            if let v = num("REGATTA_TOON_TB") { t.tB = v }
            if let v = num("REGATTA_TOON_TC") { t.tC = v }
            if let v = num("REGATTA_TOON_RIM") { t.rim = v }
            if let v = num("REGATTA_TOON_SHADOW") { t.shadow = v }
            if let v = num("REGATTA_TOON_OFF") { t.off = v }
            if let v = num("REGATTA_TOON_SOFT") { t.soft = v }
            if let v = num("REGATTA_TOON_SPARKS") { t.sparks = v }
            if let v = num("REGATTA_TOON_CELL") { t.cell = v }
            if let v = num("REGATTA_TOON_STRETCH") { t.stretch = v }
            if let v = num("REGATTA_TOON_PUFF") { t.puff = v }
            if let v = num("REGATTA_TOON_CALM") { t.calm = v }
            if let v = num("REGATTA_TOON_WARP") { t.warp = v }
            if let v = num("REGATTA_TOON_DRIFT") { t.drift = v }
            if let v = num("REGATTA_TOON_REF") { t.ref = v }
            print("#604 toon \(WaterLook.current): \(t)")
            return t
        }()

        var source: String {
            func f(_ x: Double) -> String { String(format: "%.4f", x) }
            func v3(_ c: SIMD3<Double>) -> String { "vec3(\(f(c.x)), \(f(c.y)), \(f(c.z)))" }
            let cA = 26 * size, cB = 12 * size, cC = 5 * size, w0 = warp * size / 0.4
            return """
            float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
            float vnoise(vec2 p) {
                vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
                float a = h21(i), b = h21(i + vec2(1.0, 0.0)), c = h21(i + vec2(0.0, 1.0)), d = h21(i + vec2(1.0, 1.0));
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }
            // One layer's island field at `p` (warped metres): two noise octaves, rotated by `r`, cell `C`, slowly morphing.
            // Stretched along the crests (across the wind), as the reference's islands lie along the swell.
            float isl(vec2 p, float C, vec2 r, vec2 sd, float t, vec2 dn) {
                vec2 a = vec2(dot(p, dn), dot(p, vec2(-dn.y, dn.x)) / \(f(stretch)));
                vec2 q = vec2(a.x * r.x - a.y * r.y, a.x * r.y + a.y * r.x) / C + sd + vec2(0.6, 0.35) * t * 0.012;
                return 0.62 * vnoise(q) + 0.26 * vnoise(q * 2.3 + sd.yx) + 0.12 * vnoise(q * 5.1 + sd);
            }
            // The warp: two octaves drifting their own ways, so no two neighbours share a size or spacing.
            vec2 warpAt(vec2 m, float t, vec2 dn) {
                vec2 dp = vec2(-dn.y, dn.x);
                vec2 q1 = m / \(f(26 * size)) + dp * t * 0.004;
                vec2 q2 = vec2(m.x * 0.8 - m.y * 0.6, m.x * 0.6 + m.y * 0.8) / \(f(8.5 * size)) - dp * t * 0.01;
                return vec2(vnoise(q1) - 0.5, vnoise(q1 + vec2(7.3, 2.1)) - 0.5) * 2.0 * \(f(w0))
                     + vec2(vnoise(q2 + vec2(3.1, 9.7)) - 0.5, vnoise(q2 + vec2(1.7, 4.4)) - 0.5) * \(f(w0 * 0.35));
            }
            #define CUT(F, T) smoothstep((T) - max(fwidth(F), 1e-5) * s, (T) + max(fwidth(F), 1e-5) * s, F)
            void main() {
                vec2 w = u_rect.xy + v_tex_coord * u_rect.zw;
                vec2 m = w / 8.0;
                float t = u_clock;
                vec2 dn = u_down;
                vec2 guv = clamp((w - u_gust_origin) / u_gust_size, 0.0, 1.0);
                float gu = texture2D(u_gust, guv).r * 2.0 - 1.0;
                float puff = smoothstep(0.0, 0.8, gu) * \(f(puff)), lull = smoothstep(0.0, 0.8, -gu) * \(f(puff));
                float z = max(log2(max(u_scale, 1e-3) / \(f(ref))), 0.0);
                // The water drifts downwind, all layers together, so the islands persist.
                vec2 pd = m - dn * t * \(f(drift));
                vec2 p = pd + warpAt(pd, t, dn);
                // A slow field sets the layers' cuts apart: here more large islands, there more flecks.
                float lo = vnoise(pd / \(f(55 * size)) + vec2(5.2, 1.3)) - 0.5;
                float zc = \(f(calm)) * z;
                float tA = \(f(tA)) + zc - 0.10 * lo + 0.05 * puff - 0.012 * lull;
                float tB = \(f(tB)) + zc + 0.04 * lo + 0.05 * puff - 0.008 * lull + 0.5 * smoothstep(1.3, 2.3, z);
                float tC = \(f(tC)) + zc + 0.03 * lo + 0.04 * puff + 0.05 * lull + 0.5 * smoothstep(0.5, 1.2, z);
                float rim = \(f(rim)) * (1.0 + 0.6 * puff - 0.6 * lull);
                float shd = \(f(shadow)) * (1.0 + 0.7 * puff - 0.9 * lull);
                // The far side, in world metres (screen-up under the camera's turn).
                vec2 up = vec2(-u_cam.y, u_cam.x);
                vec2 rA = vec2(0.94, 0.34), rB = vec2(0.5, -0.87), rC = vec2(-0.77, 0.64);
                vec2 sA = vec2(1.7, 9.2), sB = vec2(6.1, 3.3), sC = vec2(2.9, 7.7);
                float FA = isl(p, \(f(cA)), rA, sA, t, dn);
                float FB = isl(p, \(f(cB)), rB, sB, t, dn);
                float FC = isl(p, \(f(cC)), rC, sC, t, dn);
                float GA = isl(p - up * \(f(cA * off)), \(f(cA)), rA, sA, t, dn);
                float HA = isl(p - up * \(f(cA * off * 0.5)), \(f(cA)), rA, sA, t, dn);
                float HB = isl(p - up * \(f(cB * off * 0.5)), \(f(cB)), rB, sB, t, dn);
                float GB = isl(p - up * \(f(cB * off)), \(f(cB)), rB, sB, t, dn);
                float GC = isl(p - up * \(f(cC * off)), \(f(cC)), rC, sC, t, dn);
                float s = \(f(soft)) * 0.5;
                float pA = max(max(CUT(FA, tA), CUT(FB, tB)), CUT(FC, tC));
                // The fringe: the island swept a little to its far side (two steps), barely grown, so a deep shape
                // only exists where a pale island sits right next to it.
                float dA = max(max(max(CUT(FA, tA - rim), max(CUT(GA, tA - shd), CUT(HA, tA - shd))),
                                   max(CUT(FB, tB - rim), max(CUT(GB, tB - shd), CUT(HB, tB - shd)))),
                               max(CUT(FC, tC - rim), CUT(GC, tC - shd)));
                // Depth: a touch of the shallows' teal in every tone.
                vec2 rel = m - u_dmap0.xy;
                vec2 ax = u_dmap0.zw;
                vec2 cr = vec2(dot(rel, ax), dot(rel, vec2(-ax.y, ax.x))) / u_dmap1.x;
                vec2 duv = (cr + 0.5) / u_dmap1.yz;
                vec4 dep = u_dmap1.w > 0.5 ? texture2D(u_depth, clamp(duv, 0.0, 1.0)) : vec4(0.0, 1.0, 0.0, 1.0);
                vec3 deepC = \(v3(deep));
                vec3 midC = \(v3(mid));
                vec3 paleC = \(v3(pale));
                vec3 tealC = vec3(0.16, 0.44, 0.46);
                midC = mix(midC, deepC, 0.5 * puff);
                deepC = mix(deepC, deepC * 0.85, puff);
                midC = mix(midC, paleC, 0.16 * lull);
                midC = mix(midC, tealC, 0.35 * dep.r);
                deepC = mix(deepC, tealC, 0.25 * dep.r);
                vec3 col = mix(midC, deepC, dA);
                col = mix(col, paleC, pA);
                // Foam flecks: flat, few, in the puffs above ~12 kn.
                vec2 fm = pd / 1.6;
                float fl = vnoise(fm) * vnoise(fm * 0.37 + vec2(4.1, 8.3));
                float ft = 0.80 - 0.06 * smoothstep(0.2, 0.8, u_wind.y);
                float foamA = CUT(fl, ft) * smoothstep(0.15, 0.35, u_wind.y) * smoothstep(0.25, 0.6, puff);
                col = mix(col, vec3(0.90, 0.95, 0.97), foamA);
                // Stars: a candidate a cell (world-fixed, stepping by octaves with the zoom), its own cycle, only well
                // inside the medium and large islands.
                float cellM = \(f(cell)) * \(f(ref)) / 8.0 * exp2(floor(z));
                vec2 pm = m - dn * t * \(f(drift));
                vec2 ci = floor(pm / cellM);
                float per = 1.4 + h21(ci + vec2(3.3, 7.7));
                float phase = t / per + h21(ci + vec2(9.1, 1.9));
                float cyc = floor(phase); float life = fract(phase);
                vec2 rnd = vec2(h21(ci + vec2(cyc, 5.5)), h21(ci + vec2(2.2, cyc)));
                vec2 sm = (ci + 0.3 + 0.4 * rnd) * cellM;
                vec2 lc = pm / cellM - ci;
                float edge = min(min(lc.x, 1.0 - lc.x), min(lc.y, 1.0 - lc.y)) * cellM * 8.0 / u_scale;
                float on = step(h21(ci + vec2(cyc * 1.7, 11.0)), \(f(sparks)));
                vec2 sw0 = sm + dn * t * \(f(drift));
                if (on > 0.0) {
                    vec2 sp = sm + warpAt(sm, t, dn);
                    float inA = isl(sp, \(f(cA)), rA, sA, t, dn) - tA;
                    float inB = isl(sp, \(f(cB)), rB, sB, t, dn) - tB;
                    on *= smoothstep(0.01, 0.05, max(inA, inB));
                }
                vec2 dw = (sw0 - m) * 8.0 / u_scale;
                vec2 ds = vec2(dw.x * u_cam.x + dw.y * u_cam.y, -dw.x * u_cam.y + dw.y * u_cam.x);
                ds.y *= u_view.z;
                float fade = sin(3.14159 * life); fade *= fade;
                float core = exp(-(ds.x * ds.x * 0.12 + ds.y * ds.y) / 5.0);
                float glow = exp(-(ds.x * ds.x * 0.15 + ds.y * ds.y) / 25.0) * 0.4;
                float armX = exp(-abs(ds.x) / 9.0) * exp(-ds.y * ds.y / 0.9);
                float armY = exp(-abs(ds.y) / 4.5) * exp(-ds.x * ds.x / 0.8);
                float star = clamp((core * 1.6 + glow + armX + 0.7 * armY) * fade * on * smoothstep(0.0, 7.0, edge), 0.0, 1.0);
                col = mix(col, vec3(1.0, 0.99, 0.95), star);
                gl_FragColor = vec4(col, 1.0);
            }
            """
        }
    }
}
