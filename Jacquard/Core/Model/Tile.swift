import Foundation

// The tile hierarchy. Ported from Assets/Core/Model/Tile.cs.
//
// Four categories, as laid out in sequencer-spec.md: notes sound, parameter locks
// operate on the timbre, gates decide whether what hangs below them fires, and flow
// tiles steer the sequence. Tiles are classes because the model relies on identity: a
// branch lane answers to one particular JumpTile.

class Tile {
    // The four character code a tile is spelled with.
    var token: String { "" }

    // A tile of the same kind holding the same thing, or nil for a tile that cannot be
    // had twice (the flow tiles). Having no copy is what keeps a tile out of a copied
    // stack.
    func copy() -> Tile? { nil }
}

// MARK: - Notes

// Length is measured in steps, defaulting to one.
final class NoteTile: Tile {
    var note: Int = 60
    var length: Float = 1.0

    init(note: Int = 60, length: Float = 1.0) {
        self.note = note
        self.length = length
    }

    var hasDefaultLength: Bool { abs(length - 1.0) < 1e-4 }

    override var token: String {
        hasDefaultLength ? Pitch.toName(note)
                         : Pitch.toName(note) + "/" + Format.short(length, places: 3)
    }

    override func copy() -> Tile? { NoteTile(note: note, length: length) }
}

// MARK: - Parameter locks

// A lock carries a slot per ParamTargets index. A parameter nothing has engaged is left
// entirely alone, which is why a lock that engages nothing does nothing at all.
class ParamTile: Tile {
    func isEngaged(_ target: Int) -> Bool {
        ParamTile.inRange(target) && engaged[target]
    }

    // What the lock moves the target to, or by. Zero when it has not taken hold of it.
    subscript(target: Int) -> Float {
        ParamTile.inRange(target) && engaged[target] ? amounts[target] : 0
    }

    // The one thing refused is a value that is not a number.
    func engage(_ target: Int, _ amount: Float) {
        guard ParamTile.inRange(target), amount.isFinite else { return }
        engaged[target] = true
        amounts[target] = amount
    }

    // Letting go forgets the amount as well.
    func release(_ target: Int) {
        guard ParamTile.inRange(target) else { return }
        engaged[target] = false
        amounts[target] = 0
    }

    var isEmpty: Bool { !engaged.contains(true) }

    func copyInto<T: ParamTile>(_ copy: T) -> T {
        for target in 0..<ParamTargets.count where engaged[target] {
            copy.engage(target, amounts[target])
        }
        return copy
    }

    private var engaged = [Bool](repeating: false, count: ParamTargets.count)
    private var amounts = [Float](repeating: 0, count: ParamTargets.count)

    static func inRange(_ target: Int) -> Bool { target >= 0 && target < ParamTargets.count }
}

final class AbsoluteParamTile: ParamTile {
    override var token: String { "PABS" }
    override func copy() -> Tile? { copyInto(AbsoluteParamTile()) }
}

final class RelativeParamTile: ParamTile {
    override var token: String { "PREL" }
    override func copy() -> Tile? { copyInto(RelativeParamTile()) }
}

// MARK: - Gates

// A gate ends the walk down its stack when it does not fire, so it governs everything
// below it in the step and nothing above it.
class GateTile: Tile {
    // pass counts how many times the runner has been round its own channel.
    func evaluate(pass: Int, random: inout SystemRandomNumberGenerator) -> Bool { true }
}

// Fires on whichever laps of the cycle are switched on. The laps live in the bits of
// one mask, so laps above the period are kept rather than cleared.
final class CycleGateTile: GateTile {
    static let minPeriod = 2, maxPeriod = 32

    var period: Int {
        get { _period }
        set { _period = min(max(newValue, CycleGateTile.minPeriod), CycleGateTile.maxPeriod) }
    }

    init(period: Int = 4, pattern: String? = nil) {
        super.init()
        self.period = period
        if let pattern { self.pattern = pattern }
    }

    func fires(_ lap: Int) -> Bool { (mask & CycleGateTile.bit(lap)) != 0 }

    func setFires(_ lap: Int, _ fires: Bool) {
        mask = fires ? mask | CycleGateTile.bit(lap) : mask & ~CycleGateTile.bit(lap)
    }

    // The laps of the current period as one digit each, the first lap leftmost.
    var pattern: String {
        get { String((1..._period).map { fires($0) ? "1" : "0" }) }
        set {
            mask = 0
            for (i, c) in newValue.enumerated() { setFires(i + 1, c == "1") }
        }
    }

    override func evaluate(pass: Int, random: inout SystemRandomNumberGenerator) -> Bool {
        fires(((pass % _period) + _period) % _period + 1)
    }

    override var token: String { "GCYC\(_period):" + pattern }

    override func copy() -> Tile? {
        let copy = CycleGateTile(period: _period)
        copy.mask = mask
        return copy
    }

    private var _period = 4
    private var mask: UInt32 = 1

    static func bit(_ lap: Int) -> UInt32 {
        lap < 1 || lap > maxPeriod ? 0 : UInt32(1) << UInt32(lap - 1)
    }
}

// Fires with the given chance. Any percentage is allowed.
final class ProbGateTile: GateTile {
    var percent: Float {
        get { _percent }
        set { _percent = min(max(newValue, 0), 100) }
    }

    init(percent: Float = 50) {
        super.init()
        self.percent = percent
    }

    override func evaluate(pass: Int, random: inout SystemRandomNumberGenerator) -> Bool {
        Double.random(in: 0..<1, using: &random) * 100.0 < Double(_percent)
    }

    override var token: String { "GPRB:" + Format.short(_percent, places: 1) }

    override func copy() -> Tile? { ProbGateTile(percent: _percent) }

    private var _percent: Float = 50
}

// MARK: - Flow

class FlowTile: Tile {}

// Start of a channel's stream. Division is the note value of one step as a denominator,
// so 16 means a sixteenth note. The channel number picks the timbre as well as the
// stream. Enabled is whether this stream runs at all — not a mute.
final class ChannelTile: FlowTile {
    var channel: Int {
        get { _channel }
        set { _channel = PatchBank.clamp(newValue) }
    }

    var division: Int {
        get { _division }
        set { _division = ChannelTile.clampDivision(newValue) }
    }

    var enabled = true

    init(channel: Int = 1, division: Int = 16) {
        super.init()
        self.channel = channel
        self.division = division
    }

    override var token: String { "CHAN:\(_channel)" }

    // Seconds taken by one step at the given tempo.
    func stepSeconds(_ tempo: Float) -> Float {
        60.0 / max(tempo, 1.0) * 4.0 / Float(_division)
    }

    private var _channel = 1
    private var _division = 16

    // Powers of two from a whole note to a sixty-fourth, plus the triplet denominators.
    static let divisions = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    static func clampDivision(_ value: Int) -> Int {
        var best = 16
        for d in divisions where abs(d - value) < abs(best - value) { best = d }
        return best
    }
}

// End of a lane. Never stored: it is implied one column past the last step.
final class TerminatorTile: FlowTile {
    override var token: String { "TERM" }
}

// Leaves this lane for the one lane that answers to it.
final class JumpTile: FlowTile {
    override var token: String { "JUMP" }
}

// Where a jump lands, and the head of a branch lane.
final class JumpDestTile: FlowTile {
    override var token: String { "JDST" }
}

// MARK: - Number formatting shared by tokens and the file format

enum Format {
    // The equivalent of C#'s "0.###" style: up to `places` decimals, trailing zeros
    // trimmed, invariant culture.
    static func short(_ value: Float, places: Int) -> String {
        var text = String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value))
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text
    }
}
