import SwiftUI

extension View {
    /// `filter` over this view's pixels, platform views included (#111). `RaceView` puts it over the whole race,
    /// so the SpriteKit scene at any camera scale, the HUD and overlays over it, and the letterbox read through
    /// one matrix, live (`-vision`, Debug builds) and in render fixtures alike. For `.none` the view is unchanged.
    @ViewBuilder func vision(_ filter: VisionFilter) -> some View {
        if filter == .none {
            self
        } else {
            self._colorMatrix(filter.colorMatrix)
        }
    }
}

extension VisionFilter {
    /// The filter as SwiftUI's colour matrix: row i gives output channel i from (r, g, b, a) plus the bias in
    /// column 5. SwiftUI's public per-pixel colour route is `colorEffect`, a Metal shader, and the build doesn't
    /// compile Metal (it needs Xcode's separate Metal toolchain); `_colorMatrix` is SwiftUI's own colour-matrix
    /// effect, underscored but public, and only this test harness uses it.
    var colorMatrix: _ColorMatrix {
        let m = matrix.map { $0.map(Float.init) }, bias = Float(self.bias)
        var out = _ColorMatrix()
        (out.m11, out.m12, out.m13, out.m15) = (m[0][0], m[0][1], m[0][2], bias)
        (out.m21, out.m22, out.m23, out.m25) = (m[1][0], m[1][1], m[1][2], bias)
        (out.m31, out.m32, out.m33, out.m35) = (m[2][0], m[2][1], m[2][2], bias)
        return out
    }
}
