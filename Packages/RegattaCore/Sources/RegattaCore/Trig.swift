#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// RegattaCore's own `sin` and `cos`, which shadow the C library's everywhere in this module. Each is a
// separate call the optimizer can't see into, so it can never merge `sin(x)` and `cos(x)` into one
// `sincos` call. On Apple platforms optimized builds otherwise call `__sincos_stret`, whose sine is
// 1 ulp off `sin` for about 0.1% of inputs, and a race replayed in release drifts from the same race in
// debug. The replay platform doesn't merge them today (glibc's `sin` can set errno), so these
// wrappers leave its results unchanged. They also keep it from starting to merge them after an upgrade.
// A `@testable import RegattaCore` sees both these and the C library's, so tests write `RegattaCore.cos`.

@inline(never) func sin(_ x: Double) -> Double {
    #if canImport(Darwin)
    Darwin.sin(x)
    #else
    Glibc.sin(x)
    #endif
}

@inline(never) func cos(_ x: Double) -> Double {
    #if canImport(Darwin)
    Darwin.cos(x)
    #else
    Glibc.cos(x)
    #endif
}
