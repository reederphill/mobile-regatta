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
        return WaterLook.current.isCel ? 0 : 0.5
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
        source: kSource,
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
