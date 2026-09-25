// What a parameter lock can point at. Ported from Assets/Core/Synth/ParamTargets.cs.
//
// The set is exactly the fields of FmPatch. The order is the order the Sound and Lock
// panels read in; the keys keep the file's older spellings.

enum ParamTargets {
    static let transpose = 0
    static let gate = 1
    static let level = 2
    static let pan = 3
    static let unison = 4
    static let modRatio = 5
    static let modIndex = 6
    static let feedback = 7
    static let modDecay = 8
    static let carAttack = 9
    static let carRelease = 10
    static let pitchSweep = 11
    static let pitchDecay = 12
    static let reverbSend = 13
    static let delaySend = 14

    static let count = 15

    static let names = [
        "Transpose", "Gate ratio", "Level", "Pan", "Unison", "Ratio",
        "Amount", "Feedback", "Decay", "Attack", "Release",
        "Depth", "Decay", "Reverb", "Delay"]

    static func name(_ target: Int) -> String {
        target >= 0 && target < count ? names[target] : "?"
    }

    static let groups: [(first: Int, name: String)] = [
        (transpose, "Note"), (level, "Mix"), (modRatio, "FM"),
        (carAttack, "Amp envelope"), (pitchSweep, "Pitch envelope"),
        (reverbSend, "Sends")]

    static func groupAt(_ target: Int) -> String? {
        groups.first { $0.first == target }?.name
    }

    // Spelling used in a saved file.
    static let keys = [
        "transpose", "gate", "level", "pan", "unison", "ratio", "index",
        "feedback", "moddecay", "carattack", "carrelease", "pitchsweep",
        "pitchdecay", "rsend", "dsend"]

    static func key(_ target: Int) -> String {
        target >= 0 && target < count ? keys[target] : "level"
    }

    static func parse(_ key: String) -> Int { keys.firstIndex(of: key) ?? -1 }

    // The dial: where a bar spends its travel.
    static func min(_ target: Int) -> Float {
        switch target {
        case modRatio: return 0.05
        case gate: return 0.05
        case carAttack: return 0.001
        case transpose: return -24
        case pan: return -1
        case pitchSweep: return -8
        case level: return FmPatch.minLevel
        default: return 0
        }
    }

    static func max(_ target: Int) -> Float {
        switch target {
        case transpose: return 24
        case level: return FmPatch.maxLevel
        case gate: return 4
        case modIndex: return 12
        case modRatio: return 8
        case feedback: return 8
        case carAttack: return 2
        case carRelease: return 4
        case pitchSweep: return 8
        case pitchDecay: return 2
        default: return 1
        }
    }

    // What the synth will accept, which is a wider question than what the bar is for.
    static func bound(_ target: Int, _ value: Float) -> Float {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(v, lo), hi) }

        switch target {
        case transpose: return clamp(value, -pitchSpan, pitchSpan)
        case carAttack, carRelease, pitchDecay: return clamp(value, 0, longestTime)
        case gate: return clamp(value, 0.01, 16)
        case modRatio: return clamp(value, 0, 64)
        case modIndex, feedback: return clamp(value, 0, 100)
        case pitchSweep: return clamp(value, -32, 32)
        default: return clamp(value, min(target), max(target))
        }
    }

    static let pitchSpan = Float(Pitch.highest - Pitch.lowest)
    static let longestTime: Float = 16

    static func get(_ patch: FmPatch, _ target: Int) -> Float {
        switch target {
        case transpose: return patch.transpose
        case level: return patch.level
        case pan: return patch.pan
        case unison: return patch.unison
        case gate: return patch.gateScale
        case modIndex: return patch.modulationIndex
        case modRatio: return patch.modulatorRatio
        case feedback: return patch.feedback
        case modDecay: return patch.modulatorDecay
        case carAttack: return patch.carrierAttack
        case carRelease: return patch.carrierRelease
        case pitchSweep: return patch.pitchSweep
        case pitchDecay: return patch.pitchDecay
        case reverbSend: return patch.reverbSend
        case delaySend: return patch.delaySend
        default: return 0
        }
    }

    // A number that is not one is not an edit, and is refused where every write meets it.
    static func set(_ patch: inout FmPatch, _ target: Int, _ raw: Float) {
        guard raw.isFinite else { return }

        let value = bound(target, raw)

        switch target {
        case transpose: patch.transpose = value
        case level: patch.level = value
        case pan: patch.pan = value
        case unison: patch.unison = value
        case gate: patch.gateScale = value
        case modIndex: patch.modulationIndex = value
        case modRatio: patch.modulatorRatio = value
        case feedback: patch.feedback = value
        case modDecay: patch.modulatorDecay = value
        case carAttack: patch.carrierAttack = value
        case carRelease: patch.carrierRelease = value
        case pitchSweep: patch.pitchSweep = value
        case pitchDecay: patch.pitchDecay = value
        case reverbSend: patch.reverbSend = value
        case delaySend: patch.delaySend = value
        default: break
        }
    }

    static func add(_ patch: inout FmPatch, _ target: Int, _ delta: Float) {
        set(&patch, target, get(patch, target) + delta)
    }
}
