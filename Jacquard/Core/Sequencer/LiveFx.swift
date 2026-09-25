import Foundation

// The live effect buttons. Ported from Assets/Core/Sequencer/LiveFx.cs.
//
// A performance layer over notes that have already been made: the sequencer runs its
// full lookahead ahead and parks what it produces here, and a note is handed to the
// synth only once it is nearly due, so a press is heard on the next note. None of it is
// held by the score and none of it is saved.

enum LiveEffect: Int, CaseIterable {
    case reverb, delay
    case stab, sustain
    case octaveDown, octaveUp
    case fall, rise
    case roll1, roll2
    case roll3, roll4

    var label: String {
        switch self {
        case .reverb: return "Reverb"
        case .delay: return "Delay"
        case .stab: return "Stab"
        case .sustain: return "Sustain"
        case .octaveDown: return "Oct −"
        case .octaveUp: return "Oct +"
        case .fall: return "Fall"
        case .rise: return "Rise"
        case .roll1: return "Roll 1"
        case .roll2: return "Roll 2"
        case .roll3: return "Roll 3"
        case .roll4: return "Roll 4"
        }
    }
}

final class LiveFx {
    func isHeld(_ fx: LiveEffect) -> Bool { held[fx.rawValue] }

    func press(_ fx: LiveEffect, sample: Int64) {
        held[fx.rawValue] = true
        pressed[fx.rawValue] = sample
        presses += 1
        sequence[fx.rawValue] = presses
    }

    func release(_ fx: LiveEffect) {
        held[fx.rawValue] = false
        rolls[fx.rawValue] = nil
    }

    func start(originSample: Int64) {
        stop()
        origin = originSample
        handedTo = originSample
        for i in 0..<LiveFx.count where held[i] { pressed[i] = originSample }
    }

    func stop() {
        queue.removeAll()
        history.removeAll()
        sounding.removeAll()
        for i in 0..<LiveFx.count { rolls[i] = nil }
    }

    func enqueue(_ notes: [FmNoteEvent]) { queue.append(contentsOf: notes) }

    // Hands over everything due before the horizon, coloured by what is held.
    func handOver(horizon: Int64, tempo: Float, sampleRate: Int,
                  output: inout [FmNoteEvent]) {
        let sixteenth = LiveFx.sixteenth(tempo, sampleRate)
        if sixteenth <= 0 { return }

        arm(sixteenth)

        sounding.removeAll(keepingCapacity: true)

        let roll = owner()
        let standing = roll != nil && !roll!.notes.isEmpty

        var kept: [FmNoteEvent] = []
        for note in queue {
            if note.startSample >= horizon {
                kept.append(note)
                continue
            }
            if !standing || note.startSample < roll!.end { sounding.append(note) }
        }
        queue = kept

        if let roll { repeatRoll(roll, horizon, sixteenth) }

        for note in sounding {
            record(note)
            history.append(note)
            output.append(colour(note, sixteenth, sampleRate))
        }

        forget(horizon - Int64(sixteenth * Double(LiveFx.historyLaps)))
        handedTo = horizon
    }

    // MARK: Private

    static let count = LiveEffect.allCases.count
    static let stabGate: Float = 0.1
    static let minimumGate: Float = 0.005
    static let stabRelease: Float = 0.01
    static let rampLaps = 32
    static let historyLaps = 8

    private var held = [Bool](repeating: false, count: LiveFx.count)
    private var pressed = [Int64](repeating: 0, count: LiveFx.count)
    private var sequence = [Int](repeating: 0, count: LiveFx.count)
    private var rolls = [Roll?](repeating: nil, count: LiveFx.count)

    private var queue: [FmNoteEvent] = []
    private var history: [FmNoteEvent] = []
    private var sounding: [FmNoteEvent] = []

    private var presses = 0
    private var origin: Int64 = 0
    private var handedTo: Int64 = 0

    private final class Roll {
        var index: Int64 = 0
        var steps = 0
        var start: Int64 = 0
        var end: Int64 = 0
        var caught: Int64 = 0
        var emittedTo: Int64 = 0
        var notes: [FmNoteEvent] = []
    }

    private static func rollSteps(_ fx: LiveEffect) -> Int {
        switch fx {
        case .roll1: return 1
        case .roll2: return 2
        case .roll3: return 3
        case .roll4: return 4
        default: return 0
        }
    }

    private static func sixteenth(_ tempo: Float, _ sampleRate: Int) -> Double {
        60.0 / Double(max(tempo, 1)) / 4.0 * Double(sampleRate)
    }

    private func gridIndex(_ sample: Int64, _ sixteenth: Double) -> Int64 {
        Int64((Double(sample - origin) / sixteenth).rounded(.down))
    }

    private func gridSample(_ index: Int64, _ sixteenth: Double) -> Int64 {
        origin + Int64(Double(index) * sixteenth)
    }

    // The roll pressed most recently is the one that plays.
    private func owner() -> Roll? {
        var owner: Roll?
        var latest = 0
        for i in 0..<LiveFx.count {
            guard let roll = rolls[i], sequence[i] > latest else { continue }
            (owner, latest) = (roll, sequence[i])
        }
        return owner
    }

    private func arm(_ sixteenth: Double) {
        for fx in LiveEffect.allCases {
            let steps = LiveFx.rollSteps(fx)
            if steps > 0 { arm(fx, steps, sixteenth) }
        }
    }

    private func arm(_ fx: LiveEffect, _ steps: Int, _ sixteenth: Double) {
        let slot = fx.rawValue
        if !held[slot] { return }

        let open = rolls[slot]

        if let open {
            if open.end > handedTo || !open.notes.isEmpty { return }
            rolls[slot] = nil
        }

        let index = open.map { $0.index + Int64($0.steps) } ?? gridIndex(pressed[slot], sixteenth)

        let roll = Roll()
        roll.index = index
        roll.steps = steps
        roll.start = gridSample(index, sixteenth)
        roll.end = gridSample(index + Int64(steps), sixteenth)
        roll.caught = min(roll.end, handedTo)
        roll.emittedTo = max(roll.end, handedTo)

        for note in history where note.startSample >= roll.start && note.startSample < roll.caught {
            roll.notes.append(note)
        }

        rolls[slot] = roll
    }

    private func record(_ note: FmNoteEvent) {
        for roll in rolls { LiveFx.record(roll, note) }
    }

    private static func record(_ roll: Roll?, _ note: FmNoteEvent) {
        guard let roll else { return }
        if note.startSample < roll.caught || note.startSample >= roll.end { return }
        roll.notes.append(note)
    }

    private func repeatRoll(_ roll: Roll, _ horizon: Int64, _ sixteenth: Double) {
        if roll.end <= roll.start || roll.notes.isEmpty { return }

        let from = max(max(roll.emittedTo, roll.end), handedTo)
        if from >= horizon { return }

        let reached = (Double(from - origin) / sixteenth - Double(roll.index)) / Double(roll.steps)

        var n = max(1, Int64(reached) - 1)
        while true {
            let start = gridSample(roll.index + n * Int64(roll.steps), sixteenth)
            if start >= horizon { break }

            for note in roll.notes {
                let at = start + (note.startSample - roll.start)
                if at < from || at >= horizon { continue }
                var copy = note
                copy.startSample = at
                sounding.append(copy)
            }
            n += 1
        }

        roll.emittedTo = horizon
    }

    private func forget(_ before: Int64) {
        history.removeAll { $0.startSample < before }
    }

    private func colour(_ source: FmNoteEvent, _ sixteenth: Double, _ sampleRate: Int) -> FmNoteEvent {
        var note = source

        if held[LiveEffect.reverb.rawValue] { note.reverbSend = 1 }
        if held[LiveEffect.delay.rawValue] { note.delaySend = 1 }

        if held[LiveEffect.stab.rawValue] {
            note.duration = max(Float(sixteenth / Double(sampleRate)) * LiveFx.stabGate,
                                LiveFx.minimumGate)
            note.carrierRelease = min(note.carrierRelease, LiveFx.stabRelease)
        }

        if held[LiveEffect.sustain.rawValue] {
            note.duration *= 2
            note.carrierRelease *= 2
        }

        var semitones = 0
        if held[LiveEffect.octaveUp.rawValue] { semitones += 12 }
        if held[LiveEffect.octaveDown.rawValue] { semitones -= 12 }
        semitones += ramp(.rise, note.startSample, sixteenth)
        semitones -= ramp(.fall, note.startSample, sixteenth)

        if semitones != 0 { note.frequency *= powf(2, Float(semitones) / 12) }

        return note
    }

    private func ramp(_ fx: LiveEffect, _ sample: Int64, _ sixteenth: Double) -> Int {
        guard held[fx.rawValue] else { return 0 }
        let anchor = gridSample(gridIndex(pressed[fx.rawValue], sixteenth), sixteenth)
        let laps = Int64((Double(sample - anchor) / sixteenth).rounded(.down))
        let r = Int64(LiveFx.rampLaps)
        return Int(((laps % r) + r) % r)
    }
}
