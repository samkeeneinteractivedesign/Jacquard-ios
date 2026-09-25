// The FM oscillator and the voice pool. Ported from Assets/Core/Synth/FmVoiceState.cs
// and Assets/Jacquard/Audio/FmVoicePool.cs.
//
// Everything here runs on the audio thread and works on raw buffers, so nothing in it
// allocates or retains.

// One carrier and one modulator: what a unison pair has two of. The feedback memory
// is per partial, since two halves sharing it would modulate each other.
struct FmPartial {
    mutating func reset() {
        (carrierPhase, modulatorPhase) = (0, 0)
        (feedback1, feedback2) = (0, 0)
    }

    @inline(__always)
    mutating func next(_ increment: Float, _ ratio: Float, _ feedback: Float,
                       _ index: Float, _ amplitude: Float) -> Float {
        let mod = FastMath.sin(FastMath.twoPi * modulatorPhase +
                               feedback * (feedback1 + feedback2) * 0.5)
        (feedback2, feedback1) = (feedback1, mod)

        let output = FastMath.sin(FastMath.twoPi * carrierPhase + mod * index) * amplitude

        carrierPhase = FastMath.frac(carrierPhase + increment)
        modulatorPhase = FastMath.frac(modulatorPhase + increment * ratio)

        return output
    }

    private var carrierPhase: Float = 0   // Normalized phase [0,1)
    private var modulatorPhase: Float = 0
    private var feedback1: Float = 0      // The last two modulator outputs
    private var feedback2: Float = 0
}

// A unison pair is one voice and not two, so the pool's budget is in notes.
struct FmVoiceState {
    private(set) var note = FmNoteEvent()
    var active: Bool { isActive }

    mutating func trigger(_ event: FmNoteEvent, sampleRate: Float) {
        note = event
        isActive = true

        lower.reset()
        upper.reset()

        let increment = event.frequency / sampleRate
        let detune = event.detuneRatio

        incrementLower = increment / detune
        incrementUpper = increment * detune

        paired = event.unison > 0
        level = event.level * event.unisonGain
    }

    mutating func release() { isActive = false }

    func endSample(_ sampleRate: Float) -> Int64 {
        note.startSample + Int64(note.totalDuration * sampleRate)
    }

    @inline(__always)
    mutating func next(_ time: Float) -> (Float, Float) {
        let scale = note.pitchScale(time)
        let index = note.modulationIndex * note.modulatorLevel(time)
        let amplitude = level * note.carrierLevel(time)

        let a = lower.next(incrementLower * scale, note.modulatorRatio, note.feedback,
                           index, amplitude)

        let b = paired ? upper.next(incrementUpper * scale, note.modulatorRatio,
                                    note.feedback, index, amplitude) : 0

        return (a, b)
    }

    private var isActive = false
    private var paired = false
    private var lower = FmPartial()
    private var upper = FmPartial()
    private var incrementLower: Float = 0
    private var incrementUpper: Float = 0
    private var level: Float = 0
}

// The counters the pool reports back to the control side.
struct FmPoolCounters {
    var dropped = 0   // Lost because the schedule queue was full
    var stolen = 0    // Took a voice from a less important note
    var cancelled = 0 // Rejected because every voice outranked it
    var late = 0      // How late the worst note of the stretch was, in samples
    var started = 0
}

final class FmVoicePool {
    let voiceCount: Int
    let queueCapacity: Int

    private(set) var counters = FmPoolCounters()

    init(voices: Int, queueCapacity: Int) {
        self.voiceCount = voices
        self.queueCapacity = queueCapacity
        self.voices = .allocate(capacity: voices)
        self.voices.initialize(repeating: FmVoiceState(), count: voices)
        self.queue = .allocate(capacity: queueCapacity)
        self.queue.initialize(repeating: FmNoteEvent(), count: queueCapacity)
    }

    deinit {
        voices.deallocate()
        queue.deallocate()
    }

    func clearLateness() { (counters.late, counters.started) = (0, 0) }

    func activeVoiceCount() -> Int {
        var count = 0
        for i in 0..<voiceCount where voices[i].active { count += 1 }
        return count
    }

    var queuedCount: Int { count }

    func enqueue(_ note: FmNoteEvent) {
        guard count < queueCapacity else {
            counters.dropped += 1
            return
        }
        queue[count] = note
        count += 1
    }

    // Triggers every note due in this buffer in start order, then renders each voice
    // once and splits the sample to the dry pair, the two sends and the channel tap.
    func render(dryL: UnsafeMutablePointer<Float>, dryR: UnsafeMutablePointer<Float>,
                reverbIn: UnsafeMutablePointer<Float>, delayIn: UnsafeMutablePointer<Float>,
                tap: UnsafeMutablePointer<Float>, watch: Int,
                frameCount: Int, bufferStart: Int64, sampleRate: Float) {
        let bufferEnd = bufferStart + Int64(frameCount)

        while true {
            var next = -1
            for i in 0..<count where queue[i].startSample < bufferEnd {
                if next < 0 || queue[i].startSample < queue[next].startSample { next = i }
            }
            if next < 0 { break }

            let late = bufferStart - queue[next].startSample
            if late > Int64(counters.late) { counters.late = Int(min(late, Int64(Int32.max))) }
            counters.started += 1

            trigger(queue[next], sampleRate)

            count -= 1
            queue[next] = queue[count]
        }

        let dt = 1 / sampleRate

        for i in 0..<voiceCount where voices[i].active {
            let note = voices[i].note
            let total = note.totalDuration
            let (lowerL, lowerR, upperL, upperR) = note.unisonGains()
            let tapGain: Float = note.channel == watch ? 1 : 0

            for frame in 0..<frameCount {
                let time = Float(bufferStart + Int64(frame) - note.startSample) * dt
                if time < 0 { continue }                 // Starts later in this buffer
                if time >= total { voices[i].release(); break }

                let (lower, upper) = voices[i].next(time)
                let sample = lower + upper

                dryL[frame] += lower * lowerL + upper * upperL
                dryR[frame] += lower * lowerR + upper * upperR
                reverbIn[frame] += sample * note.reverbSend
                delayIn[frame] += sample * note.delaySend
                tap[frame] += sample * tapGain
            }
        }
    }

    // A free voice, or the least important sounding one — the lowest priority, and of
    // those the one that would end soonest. A note outranked by every voice is dropped.
    private func trigger(_ note: FmNoteEvent, _ sampleRate: Float) {
        var target = -1
        for i in 0..<voiceCount where !voices[i].active { target = i; break }

        if target < 0 {
            var lowest = Int.max
            var earliestEnd = Int64.max

            for i in 0..<voiceCount {
                let priority = voices[i].note.priority
                let end = voices[i].endSample(sampleRate)
                if priority > lowest { continue }
                if priority == lowest && end >= earliestEnd { continue }
                (target, lowest, earliestEnd) = (i, priority, end)
            }

            if note.priority < lowest {
                counters.cancelled += 1
                return
            }

            counters.stolen += 1
        }

        voices[target].trigger(note, sampleRate: sampleRate)
    }

    private let voices: UnsafeMutablePointer<FmVoiceState>
    private let queue: UnsafeMutablePointer<FmNoteEvent>
    private var count = 0
}
