import Foundation

// The timbre, and the note event it is stamped into. Ported from
// Assets/Core/Synth/FmPatch.cs, which carries the argument for every number here.

// Exponential fades from 1 to 0 over x in [0,1], normalized to reach exactly 0 at 1.
// Snap is the same shape stood up steeper, for the pitch envelope.
enum FmCurve {
    static let curve: Float = 5.0
    static let tail: Float = 0.006737947 // exp(-curve)

    static let snapCurve: Float = 8.0
    static let snapTail: Float = 3.3546263e-4 // exp(-snapCurve)

    @inline(__always)
    static func fade(_ x: Float) -> Float {
        (FastMath.exp(-curve * x) - tail) / (1.0 - tail)
    }

    @inline(__always)
    static func snap(_ x: Float) -> Float {
        (FastMath.exp(-snapCurve * x) - snapTail) / (1.0 - snapTail)
    }
}

// Two operator FM: the carrier is an AR at the note frequency, the modulator a single
// decay at a ratio of it, plus a pitch envelope. Every field is a lock target.
struct FmPatch: Equatable {
    var transpose: Float       // Semitones the channel's notes are moved by

    var level: Float           // Output level in dB, full scale at 0
    var pan: Float             // -1 hard left to +1 hard right
    var unison: Float          // How wide the detuned pair sits [0,1]; 0 is one voice
    var gateScale: Float       // Multiplies the note's gate length

    var modulatorRatio: Float  // Modulator frequency as a ratio of frequency
    var modulationIndex: Float // Peak modulation depth in radians
    var feedback: Float        // Modulator self-feedback depth in radians
    var modulatorDecay: Float  // How steeply the modulation falls away [0,1]

    var carrierAttack: Float   // Time to reach full level (seconds)
    var carrierRelease: Float  // Time to fall to silence after the gate

    var pitchSweep: Float      // Depth of the pitch envelope in octaves
    var pitchDecay: Float      // Time for the pitch to arrive at frequency

    var reverbSend: Float      // How much of the note reaches the reverb [0,1]
    var delaySend: Float       // How much of it reaches the delay [0,1]

    // The nothing end of every bar: a plain sine. Not what a new score sounds like —
    // see Project.createInitial.
    static let `default` = FmPatch(
        transpose: 0, level: -2, pan: 0, unison: 0, gateScale: 1,
        modulatorRatio: 1, modulationIndex: 0, feedback: 0, modulatorDecay: 1,
        carrierAttack: 0.005, carrierRelease: 0.005,
        pitchSweep: 0, pitchDecay: 0.2,
        reverbSend: 0, delaySend: 0)

    static let minLevel: Float = -60
    static let maxLevel: Float = 6

    // The level as the gain a voice multiplies by. Silence at the bottom.
    static func amplitude(_ decibels: Float) -> Float {
        decibels <= minLevel ? 0 : powf(10, min(decibels, maxLevel) / 20)
    }
}

// A note-on event: the complete patch alongside pitch, timing and the exact sample to
// start on. Nothing about how it sounds is stored anywhere else.
struct FmNoteEvent {
    var startSample: Int64 = 0
    var frequency: Float = 440
    var level: Float = 0       // Peak output amplitude
    var pan: Float = 0
    var unison: Float = 0
    var duration: Float = 0    // Gate length in seconds; release follows it
    var priority: Int = 0      // Higher priority wins when voices are stolen

    // Which channel the note came from, 1..8, or 0 for none. Only the visualizer's
    // channel tap reads it.
    var channel: Int = 0

    var modulatorRatio: Float = 1
    var modulationIndex: Float = 0
    var feedback: Float = 0
    var modulatorDecay: Float = 1

    var carrierAttack: Float = 0.005
    var carrierRelease: Float = 0.005

    var pitchSweep: Float = 0
    var pitchDecay: Float = 0.2

    var reverbSend: Float = 0
    var delaySend: Float = 0

    // Total time the note occupies a voice, gate plus carrier release.
    @inline(__always)
    var totalDuration: Float { duration + carrierRelease }

    // Equal power pan, scaled so that the centre is unity.
    @inline(__always)
    func panGains() -> (Float, Float) { FmNoteEvent.gains(pan) }

    @inline(__always)
    static func gains(_ position: Float) -> (Float, Float) {
        let p = position < -1 ? -1 : position > 1 ? 1 : position
        let angle = (p + 1) * (FastMath.halfPi * 0.5)
        return (FastMath.cos(angle) * root2, FastMath.sin(angle) * root2)
    }

    static let root2: Float = 1.41421356
    static let root2Inverse: Float = 0.70710678

    // Sixty cents from end to end at the top of the travel.
    static let maxDetuneCents: Float = 60

    @inline(__always)
    var detuneRatio: Float {
        unison <= 0 ? 1 : FastMath.pow2(unison * FmNoteEvent.maxDetuneCents / 2400)
    }

    static let spreadFull: Float = 0.3

    @inline(__always)
    var spread: Float {
        unison <= 0 ? 0 : unison >= FmNoteEvent.spreadFull ? 1 : unison / FmNoteEvent.spreadFull
    }

    // How far each half actually travels: the spread cut down by the room the pan has
    // left it, so pan always reaches the end of its travel.
    @inline(__always)
    var reach: Float {
        let distance = pan < 0 ? -pan : pan
        return distance >= 1 ? 0 : spread * (1 - distance)
    }

    // What each half is rendered at, so turning unison up is a change of width and not
    // of level — exact at both ends.
    @inline(__always)
    var unisonGain: Float {
        unison <= 0 ? 1 : 0.5 + (FmNoteEvent.root2Inverse - 0.5) * spread
    }

    @inline(__always)
    func unisonGains() -> (Float, Float, Float, Float) {
        if unison <= 0 {
            let (l, r) = panGains()
            return (l, r, 0, 0)
        }

        let r = reach
        let (la, ra) = FmNoteEvent.gains(pan - r)
        let (lb, rb) = FmNoteEvent.gains(pan + r)
        return (la, ra, lb, rb)
    }

    // Carrier level: rise over the attack, hold for the rest of the gate, then release
    // from whatever level was actually reached.
    @inline(__always)
    func carrierLevel(_ time: Float) -> Float {
        if time < duration { return attackLevel(time) }

        let t = time - duration
        if t >= carrierRelease { return 0 }

        return attackLevel(duration) * FmCurve.fade(t / carrierRelease)
    }

    @inline(__always)
    func attackLevel(_ time: Float) -> Float {
        time < carrierAttack ? time / carrierAttack : 1
    }

    // Modulation depth: full at the note start, falling away at whatever slope the patch
    // asks for. 0 is a plain sine, 1 holds full depth for the life of the note.
    @inline(__always)
    func modulatorLevel(_ time: Float) -> Float {
        if modulatorDecay >= 1 { return 1 }
        if modulatorDecay <= 0 { return 0 }

        return FastMath.exp(-time * (1 - modulatorDecay) /
                            (modulatorDecay * FmNoteEvent.decayUnit))
    }

    static let decayUnit: Float = 0.1

    // Pitch envelope, as a multiplier on the note frequency, in octaves.
    @inline(__always)
    func pitchScale(_ time: Float) -> Float {
        time >= pitchDecay ? 1 : FastMath.pow2(pitchSweep * FmCurve.snap(time / pitchDecay))
    }

    // Builds an event from a resolved patch — every lock already applied.
    static func fromPatch(_ patch: FmPatch, note: Int, gateSeconds: Float,
                          startSample: Int64, channel: Int) -> FmNoteEvent {
        let level = FmPatch.amplitude(patch.level)

        return FmNoteEvent(
            startSample: startSample,
            frequency: Pitch.toFrequency(Float(note)),
            level: level,
            pan: min(max(patch.pan, -1), 1),
            unison: min(max(patch.unison, 0), 1),
            duration: max(gateSeconds * patch.gateScale, 0.005),
            priority: Int((level * 8).rounded(.toNearestOrEven)),
            channel: channel,
            modulatorRatio: patch.modulatorRatio,
            modulationIndex: patch.modulationIndex,
            feedback: patch.feedback,
            modulatorDecay: patch.modulatorDecay,
            carrierAttack: patch.carrierAttack,
            carrierRelease: patch.carrierRelease,
            pitchSweep: patch.pitchSweep,
            pitchDecay: patch.pitchDecay,
            reverbSend: patch.reverbSend,
            delaySend: patch.delaySend)
    }
}
