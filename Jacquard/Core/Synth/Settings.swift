import Foundation

// The patch bank, the limiter settings and the send effect settings. Ported from
// Assets/Core/Synth/PatchBank.cs, Limiter.cs and SendFx.cs.

// One patch per channel. The channel number picks the timbre as well as the stream.
final class PatchBank {
    static let channels = 8

    subscript(channel: Int) -> FmPatch {
        get { patches[PatchBank.clamp(channel) - 1] }
        set { patches[PatchBank.clamp(channel) - 1] = newValue }
    }

    static func clamp(_ channel: Int) -> Int { min(max(channel, 1), channels) }

    // Copies every patch from another bank, which is how the sequencer starts each
    // instant from the project's own values.
    func copy(from other: PatchBank) { patches = other.patches }

    private var patches = [FmPatch](repeating: .default, count: PatchBank.channels)
}

// The limiter across the finished mix. The ceiling is how hard the mix is squeezed, with
// the make-up derived from it.
struct Limiter: Equatable {
    var ceiling: Float // dB below full scale
    var attack: Float  // seconds
    var release: Float // seconds

    static let `default` = Limiter(ceiling: 0, attack: 0.005, release: 0.15)

    static let minCeiling: Float = -48
    static let minAttack: Float = 0.0002, maxAttack: Float = 0.05
    static let minRelease: Float = 0.01, maxRelease: Float = 1.0

    static func gain(_ decibels: Float) -> Float { powf(10, decibels / 20) }
}

// Delay times, synced to the tempo, as note values against the beat.
enum DelayTime {
    static let names = ["1/32", "1/16T", "1/16", "1/8T", "1/16D", "1/8", "1/4T", "1/8D", "1/4"]

    static let beats: [Float] = [0.125, 1.0 / 6.0, 0.25, 1.0 / 3.0, 0.375,
                                 0.5, 2.0 / 3.0, 0.75, 1.0]

    static let `default` = 5 // 1/8

    static let longestSeconds: Float = 3

    static func nearest(_ value: Float) -> Int {
        var (nearest, distance) = (DelayTime.default, Float.greatestFiniteMagnitude)
        for (i, b) in beats.enumerated() {
            let d = abs(b - value)
            if d >= distance { continue }
            (nearest, distance) = (i, d)
        }
        return nearest
    }
}

// One reverb and one delay for the whole project.
struct SendFx: Equatable {
    var reverbSize: Float
    var reverbTone: Float
    var reverbSpread: Float

    var delayBeats: Float
    var delayFeedback: Float
    var delayTone: Float
    var delaySpread: Float

    static let maxFeedback: Float = 0.95

    static let `default` = SendFx(
        reverbSize: 0.5, reverbTone: 0.5, reverbSpread: 1.0,
        delayBeats: DelayTime.beats[DelayTime.default],
        delayFeedback: 0.35, delayTone: 0.6, delaySpread: 0.0)

    func delaySeconds(_ tempo: Float) -> Float { delayBeats * 60 / max(tempo, 1) }
}
