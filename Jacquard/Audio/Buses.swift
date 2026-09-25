import Foundation

// The effect and gain stages after the voices. Ported from Assets/Jacquard/Audio:
// DelayBus.cs, ReverbBus.cs, LimiterBus.cs, OutputBus.cs, and the runtime settings in
// FmSynthRealtime.cs. The order they are run in is FmSynthCore.render.

typealias Buffer = UnsafeMutablePointer<Float>

@inline(__always) private func saturate(_ x: Float) -> Float { min(max(x, 0), 1) }

// MARK: - Runtime settings (what the audio thread reads)

struct SendFxRuntime: Equatable {
    var reverbSize: Float = 0.5
    var reverbTone: Float = 0.5
    var reverbSpread: Float = 1
    var delaySamples: Float = 0
    var delayFeedback: Float = 0
    var delayTone: Float = 0.6
    var delaySpread: Float = 0

    static func from(_ fx: SendFx, tempo: Float, sampleRate: Float) -> SendFxRuntime {
        SendFxRuntime(reverbSize: fx.reverbSize, reverbTone: fx.reverbTone,
                      reverbSpread: fx.reverbSpread,
                      delaySamples: fx.delaySeconds(tempo) * sampleRate,
                      delayFeedback: fx.delayFeedback, delayTone: fx.delayTone,
                      delaySpread: fx.delaySpread)
    }
}

struct LimiterRuntime: Equatable {
    var ceiling: Float = 1 // Linear, what the gain holds the mix under
    var makeUp: Float = 1  // Linear, precisely what the ceiling took off
    var attack: Float = 1  // One pole coefficient, gain coming down
    var release: Float = 1 // And going back up

    static func from(_ limiter: Limiter, sampleRate: Float) -> LimiterRuntime {
        let ceiling = min(max(limiter.ceiling, Limiter.minCeiling), 0)
        return LimiterRuntime(
            ceiling: Limiter.gain(ceiling),
            makeUp: Limiter.gain(-ceiling),
            attack: coefficient(limiter.attack, sampleRate, Limiter.minAttack, Limiter.maxAttack),
            release: coefficient(limiter.release, sampleRate, Limiter.minRelease, Limiter.maxRelease))
    }

    private static func coefficient(_ seconds: Float, _ rate: Float, _ low: Float, _ high: Float) -> Float {
        1 - expf(-1 / (min(max(seconds, low), high) * rate))
    }
}

struct MixFxRuntime: Equatable {
    var sends = SendFxRuntime()
    var limiter = LimiterRuntime()
    var outputGain: Float = 1

    static func from(_ fx: SendFx, _ limiter: Limiter, volume: Float, tempo: Float,
                     sampleRate: Float) -> MixFxRuntime {
        MixFxRuntime(sends: .from(fx, tempo: tempo, sampleRate: sampleRate),
                     limiter: .from(limiter, sampleRate: sampleRate),
                     outputGain: OutputVolume.gain(volume))
    }
}

// The monitoring volume. Not the project's — it answers to the room rather than the
// piece — so it is kept in UserDefaults rather than in the file.
enum OutputVolume {
    static let defaultDecibels: Float = -1
    static let minVolume: Float = -60
    static let key = "Jacquard.OutputVolume"

    static var decibels: Float {
        get {
            let stored = UserDefaults.standard.object(forKey: key) as? Float ?? defaultDecibels
            return min(max(stored, minVolume), 0)
        }
        set { UserDefaults.standard.set(min(max(newValue, minVolume), 0), forKey: key) }
    }

    static func gain(_ decibels: Float) -> Float {
        decibels <= minVolume ? 0 : powf(10, decibels / 20)
    }
}

// MARK: - Delay

// A stereo line with a tone lowpass in the loop and a crossfeed that turns it into a
// ping-pong as the spread goes up. The tap glides towards a new time rather than jumps.
final class DelayBus {
    let capacity: Int

    init(sampleRate: Float) {
        capacity = Int(DelayTime.longestSeconds * sampleRate) + 4
        lines = .allocate(capacity: capacity * 2)
        lines.initialize(repeating: 0, count: capacity * 2)
    }

    deinit { lines.deallocate() }

    static let maxTapRate: Float = 0.25
    static let minTap: Float = 2

    func process(_ input: Buffer, _ wetL: Buffer, _ wetR: Buffer, _ frameCount: Int,
                 tapSamples: Float, feedback rawFeedback: Float, tone: Float, spread rawSpread: Float) {
        let target = min(max(tapSamples, DelayBus.minTap), Float(capacity) - DelayBus.minTap)
        if tap <= 0 { tap = target }

        let feedback = min(max(rawFeedback, 0), SendFx.maxFeedback)
        let spread = saturate(rawSpread)

        let bright = saturate(tone)
        let cutoff = bright * bright * 0.94 + 0.06

        for frame in 0..<frameCount {
            tap += min(max(target - tap, -DelayBus.maxTapRate), DelayBus.maxTapRate)

            var read = Float(write) - tap
            if read < 0 { read += Float(capacity) }

            let left = self.read(0, read)
            let right = self.read(capacity, read)

            lowpassL += (left - lowpassL) * cutoff
            lowpassR += (right - lowpassR) * cutoff

            wetL[frame] += lowpassL
            wetR[frame] += lowpassR

            let backL = lowpassL * feedback
            let backR = lowpassR * feedback
            let dry = input[frame]

            lines[write] = dry + backL * (1 - spread) + backR * spread
            lines[capacity + write] = dry * (1 - spread) + backR * (1 - spread) + backL * spread

            write += 1
            if write >= capacity { write = 0 }
        }
    }

    @inline(__always)
    private func read(_ origin: Int, _ position: Float) -> Float {
        let index = Int(position)
        let frac = position - Float(index)
        var next = index + 1
        if next >= capacity { next -= capacity }
        return lines[origin + index] * (1 - frac) + lines[origin + next] * frac
    }

    private let lines: Buffer
    private var write = 0
    private var tap: Float = 0
    private var lowpassL: Float = 0
    private var lowpassR: Float = 0
}

// MARK: - Reverb

// Freeverb's topology: eight damped combs into four allpasses per side, the right side's
// lines a little longer, with size, tone and spread smoothed across blocks.
final class ReverbBus {
    static let combCount = 8
    static let allpassCount = 4
    static let perChannel = combCount + allpassCount
    static let lineCount = perChannel * 2

    static let combTuning = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    static let allpassTuning = [556, 441, 341, 225]
    static let stereoSpread = 23
    static let referenceRate: Float = 44100

    static let minFeedback: Float = 0.70
    static let feedbackSpan: Float = 0.28
    static let dampSpan: Float = 0.4
    static let allpassFeedback: Float = 0.5
    static let inputGain: Float = 0.015
    static let outputGain: Float = 3.0
    static let smoothingSeconds: Float = 0.03

    init(sampleRate: Float) {
        starts = .allocate(capacity: ReverbBus.lineCount + 1)
        cursors = .allocate(capacity: ReverbBus.lineCount)
        cursors.initialize(repeating: 0, count: ReverbBus.lineCount)
        stores = .allocate(capacity: ReverbBus.combCount * 2)
        stores.initialize(repeating: 0, count: ReverbBus.combCount * 2)

        var total = 0
        for line in 0..<ReverbBus.lineCount {
            starts[line] = total
            total += ReverbBus.length(line, sampleRate)
        }
        starts[ReverbBus.lineCount] = total

        lines = .allocate(capacity: total)
        lines.initialize(repeating: 0, count: total)
    }

    deinit {
        lines.deallocate()
        starts.deallocate()
        cursors.deallocate()
        stores.deallocate()
    }

    private static func length(_ line: Int, _ sampleRate: Float) -> Int {
        let channel = line / perChannel
        let index = line % perChannel
        let tuning = index < combCount ? combTuning[index] : allpassTuning[index - combCount]
        let scaled = Int(Float(tuning) * sampleRate / referenceRate) + channel * stereoSpread
        return max(scaled, 1)
    }

    func process(_ input: Buffer, _ wetL: Buffer, _ wetR: Buffer, _ frameCount: Int,
                 sampleRate: Float, size: Float, tone: Float, spread: Float) {
        approach(size, tone, spread, Float(frameCount) / sampleRate)

        let feedback = ReverbBus.minFeedback + ReverbBus.feedbackSpan * saturate(smoothSize)
        let damping = ReverbBus.dampSpan * (1 - saturate(smoothTone))

        let image = saturate(smoothSpread)
        let direct = ReverbBus.outputGain * (image * 0.5 + 0.5)
        let crossed = ReverbBus.outputGain * (1 - image) * 0.5

        for frame in 0..<frameCount {
            let x = input[frame] * ReverbBus.inputGain

            var left: Float = 0
            var right: Float = 0

            for i in 0..<ReverbBus.combCount {
                left += comb(i, x, feedback, damping)
                right += comb(ReverbBus.perChannel + i, x, feedback, damping)
            }

            for i in 0..<ReverbBus.allpassCount {
                left = allpass(ReverbBus.combCount + i, left)
                right = allpass(ReverbBus.perChannel + ReverbBus.combCount + i, right)
            }

            wetL[frame] += left * direct + right * crossed
            wetR[frame] += right * direct + left * crossed
        }
    }

    private func approach(_ size: Float, _ tone: Float, _ spread: Float, _ blockSeconds: Float) {
        if smoothSize < 0 {
            (smoothSize, smoothTone, smoothSpread) = (size, tone, spread)
            return
        }

        let rate = 1 - expf(-blockSeconds / ReverbBus.smoothingSeconds)
        smoothSize += (size - smoothSize) * rate
        smoothTone += (tone - smoothTone) * rate
        smoothSpread += (spread - smoothSpread) * rate
    }

    @inline(__always)
    private func comb(_ line: Int, _ input: Float, _ feedback: Float, _ damping: Float) -> Float {
        let index = starts[line] + cursors[line]
        let output = lines[index]
        let s = ReverbBus.store(line)
        let store = output * (1 - damping) + stores[s] * damping
        stores[s] = store
        lines[index] = input + store * feedback
        advance(line)
        return output
    }

    @inline(__always)
    private func allpass(_ line: Int, _ input: Float) -> Float {
        let index = starts[line] + cursors[line]
        let buffered = lines[index]
        lines[index] = input + buffered * ReverbBus.allpassFeedback
        advance(line)
        return buffered - input
    }

    @inline(__always)
    private static func store(_ line: Int) -> Int { line / perChannel * combCount + line % perChannel }

    @inline(__always)
    private func advance(_ line: Int) {
        let cursor = cursors[line] + 1
        cursors[line] = cursor >= starts[line + 1] - starts[line] ? 0 : cursor
    }

    private let lines: Buffer
    private let starts: UnsafeMutablePointer<Int>
    private let cursors: UnsafeMutablePointer<Int>
    private let stores: Buffer
    private var smoothSize: Float = -1
    private var smoothTone: Float = 0
    private var smoothSpread: Float = 0
}

// MARK: - Limiter

// A peak follower and a one pole gain, with the make-up derived from the ceiling.
final class LimiterBus {
    func process(_ left: Buffer, _ right: Buffer, _ frameCount: Int, _ settings: LimiterRuntime) {
        var gain = self.gain
        if gain <= 0 { gain = 1 }
        var held = peak

        for frame in 0..<frameCount {
            let l = left[frame]
            let r = right[frame]

            let p = max(abs(l), abs(r))
            held = p > held ? p : held + (p - held) * settings.release

            let target = held > settings.ceiling ? settings.ceiling / held : 1
            gain += (target - gain) * (target < gain ? settings.attack : settings.release)

            let applied = gain * settings.makeUp
            left[frame] = l * applied
            right[frame] = r * applied
        }

        peak = held
        self.gain = gain
    }

    private var peak: Float = 0
    private var gain: Float = 0
}

// MARK: - Output volume

// The monitoring gain, ramped across a block when it moves.
final class OutputBus {
    func process(_ left: Buffer, _ right: Buffer, _ frameCount: Int, _ gain: Float) {
        var current = self.current
        if current < 0 { current = gain }

        if current == gain {
            if gain != 1 {
                for frame in 0..<frameCount {
                    left[frame] *= gain
                    right[frame] *= gain
                }
            }
        } else {
            let step = (gain - current) / Float(frameCount)
            for frame in 0..<frameCount {
                current += step
                left[frame] *= current
                right[frame] *= current
            }
            current = gain
        }

        self.current = current
    }

    private var current: Float = -1
}
