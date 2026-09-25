/// The segment `axis[upper - 1] ... axis[upper]` of an ascending axis (at least two entries) that
/// holds `x`, and how far along it `x` lies, clamped to 0...1. Past either end it's the end segment,
/// with `t` at 0 or 1. A value exactly on an interior node lands at `t == 1` of the segment below it.
func axisSegment(_ axis: [Double], _ x: Double) -> (upper: Int, t: Double) {
    var i = 1
    while i < axis.count - 1 && axis[i] < x { i += 1 }
    let a0 = axis[i - 1], a1 = axis[i]
    return (i, ((x - a0) / (a1 - a0)).clamped(to: 0...1))
}
