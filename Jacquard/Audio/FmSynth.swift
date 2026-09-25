import AVFoundation
import Synchronization

// The synth: the DSP core and the iOS driver around it. Ported from
// Assets/Jacquard/Audio/FmSynthCore.cs, FmSynthScope.cs, FmSynth.cs and the pipeline
// driver.
//
// The original splits "two drivers, one DSP": FmSynthCore is asked only to fill so many
// frames starting at so many samples, and everything platform-shaped lives around it.
// Here the one driver is an AVAudioSourceNode pulling on the audio thread, against a
// sample counter the render callback itself advances — so the clock the sequencer
// schedules against is, by construction, the clock the voices are rendered against.

// MARK: - Scope

// The finished mix and the watched channel's dry tap, written into two rings the
// visualizer reads from the main thread. As in the original, the reads are not
// synchronized with the writes: a torn read is a column of a waveform drawn one sample
// off, which nobody can see.
final class FmSynthScope {
    let length: Int

    init(frames: Int) {
        length = frames
        wave = .allocate(capacity: frames)
        wave.initialize(repeating: 0, count: frames)
        tap = .allocate(capacity: frames)
        tap.initialize(repeating: 0, count: frames)
    }

    deinit {
        wave.deallocate()
        tap.deallocate()
    }

    var watch: Int {
        get { watchChannel.load(ordering: .relaxed) }
        set { watchChannel.store(newValue, ordering: .relaxed) }
    }

    var head: Int { cursor.load(ordering: .acquiring) }

    func at(_ index: Int) -> Float {
        var i = index % length
        if i < 0 { i += length }
        return wave[i]
    }

    func tapAt(_ index: Int) -> Float {
        var i = index % length
        if i < 0 { i += length }
        return tap[i]
    }

    // The channel's tap is staged by the same master gain as the mix, so the two lines
    // share one vertical axis.
    func write(_ left: Buffer, _ right: Buffer, _ tapIn: Buffer, tapGain: Float, _ frameCount: Int) {
        var at = cursor.load(ordering: .relaxed)
        for frame in 0..<frameCount {
            wave[at] = (left[frame] + right[frame]) * 0.5
            tap[at] = tapIn[frame] * tapGain
            at += 1
            if at >= length { at = 0 }
        }
        cursor.store(at, ordering: .releasing)
    }

    private let wave: Buffer
    private let tap: Buffer
    private let cursor = Atomic<Int>(0)
    private let watchChannel = Atomic<Int>(0)
}

// MARK: - Core

// Holds the voices, the buses and the scratch buffers, and renders one block. The whole
// chain is written out in order in render(), as FmSynthCore.RenderJob.Execute is.
final class FmSynthCore {
    let pool: FmVoicePool
    let reverb: ReverbBus
    let delay: DelayBus
    let limiter = LimiterBus()
    let output = OutputBus()
    let scope: FmSynthScope

    let sampleRate: Float
    let maxFrames: Int
    let masterGain: Float

    let outL: Buffer   // Wet, then the finished mix
    let outR: Buffer

    init(sampleRate: Float, maxFrames: Int, maxVoices: Int, queueCapacity: Int,
         masterGain: Float, scopeFrames: Int) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self.masterGain = masterGain

        pool = FmVoicePool(voices: maxVoices, queueCapacity: queueCapacity)
        reverb = ReverbBus(sampleRate: sampleRate)
        delay = DelayBus(sampleRate: sampleRate)
        scope = FmSynthScope(frames: scopeFrames)

        func buffer() -> Buffer {
            let b = Buffer.allocate(capacity: maxFrames)
            b.initialize(repeating: 0, count: maxFrames)
            return b
        }

        (dryL, dryR, reverbIn, delayIn, tapIn) = (buffer(), buffer(), buffer(), buffer(), buffer())
        (outL, outR) = (buffer(), buffer())
    }

    deinit {
        for b in [dryL, dryR, reverbIn, delayIn, tapIn, outL, outR] { b.deallocate() }
    }

    func render(bufferStart: Int64, frameCount: Int, fx: MixFxRuntime) {
        // One call per buffer rather than a loop over an array of them, which would
        // allocate on the audio thread.
        dryL.update(repeating: 0, count: frameCount)
        dryR.update(repeating: 0, count: frameCount)
        reverbIn.update(repeating: 0, count: frameCount)
        delayIn.update(repeating: 0, count: frameCount)
        tapIn.update(repeating: 0, count: frameCount)
        outL.update(repeating: 0, count: frameCount)
        outR.update(repeating: 0, count: frameCount)

        pool.render(dryL: dryL, dryR: dryR, reverbIn: reverbIn, delayIn: delayIn,
                    tap: tapIn, watch: scope.watch, frameCount: frameCount,
                    bufferStart: bufferStart, sampleRate: sampleRate)

        // The two sends, in parallel and not in series.
        delay.process(delayIn, outL, outR, frameCount,
                      tapSamples: fx.sends.delaySamples, feedback: fx.sends.delayFeedback,
                      tone: fx.sends.delayTone, spread: fx.sends.delaySpread)

        reverb.process(reverbIn, outL, outR, frameCount, sampleRate: sampleRate,
                       size: fx.sends.reverbSize, tone: fx.sends.reverbTone,
                       spread: fx.sends.reverbSpread)

        // The dry sum, staged so full scale is four notes.
        for frame in 0..<frameCount {
            outL[frame] = (dryL[frame] + outL[frame]) * masterGain
            outR[frame] = (dryR[frame] + outR[frame]) * masterGain
        }

        limiter.process(outL, outR, frameCount, fx.limiter)

        // The soft clip, now the limiter's backstop.
        for frame in 0..<frameCount {
            outL[frame] = FmSynthCore.softClip(outL[frame])
            outR[frame] = FmSynthCore.softClip(outR[frame])
        }

        // Deliberately above the volume: the drawing reads the mix, not the monitoring.
        scope.write(outL, outR, tapIn, tapGain: masterGain, frameCount)

        output.process(outL, outR, frameCount, fx.outputGain)
    }

    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let s = min(x * x, 9)
        return min(max(x * (27 + s) / (27 + 9 * s), -1), 1)
    }

    private let dryL: Buffer     // Every voice, placed by its own pan
    private let dryR: Buffer
    private let reverbIn: Buffer // What the notes sent to the reverb
    private let delayIn: Buffer  // What they sent to the delay
    private let tapIn: Buffer    // What the watched channel's notes put in
}

// MARK: - Status

struct FmSynthStatus {
    var dspSample: Int64 = 0
    var activeVoices = 0
    var queuedNotes = 0
    var droppedNotes = 0
    var stolenNotes = 0
    var cancelledNotes = 0
    var lateSamples = 0
    var startedNotes = 0
}

// MARK: - Driver

final class FmSynth {
    // The dry sum is staged so that full scale is four notes at full level.
    static let masterGain: Float = 0.25

    static let scopeFrames = 4096

    let maxVoices: Int
    private(set) var sampleRate: Int = 48000

    // Where the audio clock is: the first sample the next render will fill.
    var currentSample: Int64 { shared.clock.load(ordering: .acquiring) }

    // How far past the clock a note has to be placed to be heard on time: the render in
    // progress may already have read the inbox, so two IO buffers.
    private(set) var minimumLead: Int64 = 2048

    var scope: FmSynthScope? { core?.scope }

    // bufferFrames is the IO buffer asked of the session (DspBuffer), which the system
    // may round.
    init(maxVoices: Int, bufferFrames: Int = 1024, queueCapacity: Int = 512) {
        self.maxVoices = maxVoices
        self.bufferFrames = bufferFrames
        self.queueCapacity = queueCapacity
        start()
    }

    // Only a mix of zero is watched by nothing; the app asks for the channel under the
    // selection.
    func watchChannel(_ channel: Int) { core?.scope.watch = channel }

    @discardableResult
    func schedule(_ note: FmNoteEvent) -> Bool {
        shared.inbox.withLock { $0.notes.append(note) }
        return true
    }

    @discardableResult
    func setFx(_ fx: MixFxRuntime) -> Bool {
        shared.inbox.withLock { $0.fx = fx }
        return true
    }

    func status() -> FmSynthStatus {
        shared.inbox.withLock { $0.status }
    }

    // MARK: Engine

    private func start() {
        configureSession()

        let session = AVAudioSession.sharedInstance()
        let rate = session.sampleRate > 0 ? session.sampleRate : 48000
        sampleRate = Int(rate)

        let ioFrames = max(Int(session.ioBufferDuration * rate), 256)
        minimumLead = Int64(ioFrames * 2)

        let maxFrames = 4096
        let core = FmSynthCore(sampleRate: Float(rate), maxFrames: maxFrames,
                               maxVoices: maxVoices, queueCapacity: queueCapacity,
                               masterGain: FmSynth.masterGain, scopeFrames: FmSynth.scopeFrames)
        self.core = core

        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let shared = self.shared
        var fx = MixFxRuntime()

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

            // Take what the main thread has handed over, unless it holds the lock this
            // instant — then it waits for the next block rather than the audio thread
            // waiting for it.
            _ = shared.inbox.withLockIfAvailable { state in
                for note in state.notes { core.pool.enqueue(note) }
                state.notes.removeAll(keepingCapacity: true)
                if let next = state.fx { fx = next; state.fx = nil }

                state.status = FmSynthStatus(
                    dspSample: shared.clock.load(ordering: .relaxed),
                    activeVoices: core.pool.activeVoiceCount(),
                    queuedNotes: core.pool.queuedCount,
                    droppedNotes: core.pool.counters.dropped,
                    stolenNotes: core.pool.counters.stolen,
                    cancelledNotes: core.pool.counters.cancelled,
                    lateSamples: core.pool.counters.late,
                    startedNotes: core.pool.counters.started)
                core.pool.clearLateness()
            }

            var done = 0
            while done < frames {
                let chunk = min(frames - done, core.maxFrames)
                let start = shared.clock.load(ordering: .relaxed)

                core.render(bufferStart: start, frameCount: chunk, fx: fx)

                for (channel, buffer) in buffers.enumerated() {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let from = channel == 0 ? core.outL : core.outR
                    (data + done).update(from: from, count: chunk)
                }

                shared.clock.store(start + Int64(chunk), ordering: .releasing)
                done += chunk
            }

            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1

        do {
            try engine.start()
        } catch {
            print("Jacquard: audio engine would not start: \(error)")
        }

        self.source = source
    }

    // Playback, mixing with others, and said again whenever something may have undone
    // it — what JacquardAudioSession.mm does for the Unity build. Without it a phone in
    // silent mode plays nothing.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(Double(bufferFrames) / 48000.0)
            try session.setActive(true)
        } catch {
            print("Jacquard: audio session refused playback: \(error)")
        }

        if observers.isEmpty {
            let centre = NotificationCenter.default
            observers.append(centre.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session,
                queue: .main) { [weak self] note in
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.resume() }
                })
        }
    }

    // Coming back after an interruption: say the category again and restart the engine.
    // The clock carries on from where it stopped, since it counts rendered samples.
    func resume() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
    }

    fileprivate struct Inbox {
        var notes: [FmNoteEvent] = []
        var fx: MixFxRuntime?
        var status = FmSynthStatus()

        init() { notes.reserveCapacity(1024) }
    }

    private let queueCapacity: Int
    private let bufferFrames: Int
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var core: FmSynthCore?
    private let shared = Shared()
    private var observers: [NSObjectProtocol] = []
}

// What the main thread and the audio thread share: the inbox and the clock. A class, so
// the render block can hold it; the two members are not copyable.
private final class Shared: Sendable {
    let inbox = Mutex(FmSynth.Inbox())
    let clock = Atomic<Int64>(0)
}
