// Polynomial sine and exponential. Ported from Assets/Core/Synth/FastMath.cs.
//
// The original spells these out because Burst could not compile MathF externs; Swift
// has no such constraint, but the DSP is ported with the same approximations so that
// the voice sounds the same, down to the error in the polynomials.

enum FastMath {
    static let pi: Float = 3.14159265
    static let twoPi: Float = 6.28318531
    static let halfPi: Float = 1.57079633

    // The original truncates through an int; rounding down is the same answer for every
    // finite value and cannot trap on a NaN or an out of range float in Swift.
    @inline(__always)
    static func floor(_ x: Float) -> Float { x.rounded(.down) }

    @inline(__always)
    static func frac(_ x: Float) -> Float { x - floor(x) }

    @inline(__always)
    static func sin(_ x: Float) -> Float {
        var turns = x * (1.0 / twoPi)
        turns -= floor(turns + 0.5)
        var r = turns * twoPi

        if r > halfPi { r = pi - r }
        else if r < -halfPi { r = -pi - r }

        let s = r * r
        return r * (1.0 + s * (-0.166666667 +
                    s * (0.00833333333 +
                    s * (-0.000198412698 +
                    s * 2.75573192e-6))))
    }

    @inline(__always)
    static func cos(_ x: Float) -> Float { sin(x + halfPi) }

    @inline(__always)
    static func exp(_ x: Float) -> Float {
        let t = x * 1.44269504 // log2(e)
        guard t.isFinite else { return t > 0 ? .greatestFiniteMagnitude : 0 }
        let clamped = max(min(t, 1_000_000), -1_000_000)
        let i = Int(floor(clamped))
        let f = clamped - Float(i)
        let p = 1.0 + f * (0.693147181 +
                f * (0.240226507 +
                f * (0.0555041087 +
                f * (0.00961812911 +
                f * 0.00133335581))))
        return p * exp2(i)
    }

    @inline(__always)
    static func exp2(_ exponent: Int) -> Float {
        if exponent > 64 { return .greatestFiniteMagnitude }
        if exponent < -64 { return 0 }
        var result: Float = 1
        var e = exponent
        while e > 0 { result *= 2; e -= 1 }
        while e < 0 { result *= 0.5; e += 1 }
        return result
    }

    @inline(__always)
    static func pow2(_ x: Float) -> Float { exp(x * 0.693147181) }
}
