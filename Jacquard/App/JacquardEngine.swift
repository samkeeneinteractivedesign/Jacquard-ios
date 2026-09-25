import Foundation
import QuartzCore
import Observation

// The app: the project, the sequencer, the live effects and the synth, and the frame that
// runs them. Ported from the parts of Assets/Jacquard/App/JacquardApp.cs that are not
// Unity plumbing.
//
// The sequencer runs its full lookahead ahead of the audio clock every frame and parks
// what it produces with the live effects; a note is handed to the synth only once it is
// nearly due, so a live effect pressed now is heard on the next note.

@Observable
final class JacquardEngine {
    // How far ahead of the audio clock the sequencer runs.
    var lookahead: Float = 0.12

    // The floor of the handover window. See handoverSeconds.
    var liveLead: Float = 0.03

    static let maxVoices = 24

    private(set) var project: Project
    @ObservationIgnored let sequencer = Sequencer()
    @ObservationIgnored let live = LiveFx()
    @ObservationIgnored private(set) var synth: FmSynth?

    // Bumped whenever the plane has to be redrawn from the score.
    private(set) var revision = 0

    private(set) var isPlaying = false
    private(set) var isSwitchPending = false
    private(set) var message = ""
    private(set) var status = FmSynthStatus()

    // The lane under the hand, whose channel the visualizer's second trace follows.
    var selectedLane: Lane? { didSet { revision += 1 } }

    // The plane is held still while a score waits for the turn of the piece.
    var locked: Bool { isSwitchPending }

    init() {
        project = Project.createInitial()
        reframe()

        sequencer.project = project
        sequencer.switched = { [weak self] at in self?.onSwitched(at) }

        synth = FmSynth(maxVoices: JacquardEngine.maxVoices)

        displayLink = CADisplayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    // MARK: Transport

    func togglePlay() {
        guard let synth else { return }

        if sequencer.isPlaying {
            sequencer.stop()
            live.stop()
        } else {
            let now = synth.currentSample
            sequencer.play(currentSample: now, lookaheadSamples: lookaheadSamples)
            live.start(originSample: now + lookaheadSamples)
        }

        isPlaying = sequencer.isPlaying
        isSwitchPending = sequencer.isSwitchPending
    }

    // The app stops the transport when it goes away; nothing about a run survives the gap.
    func suspend() {
        if sequencer.isPlaying { togglePlay() }
    }

    func resume() { synth?.resume() }

    // MARK: Scores

    static let bundledScores = ["sample1", "sample2", "sample3", "sample4", "sample5"]

    func loadBundled(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ProjectFormat.fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            message = "could not find \(name)"
            return
        }
        load(text, name: name)
    }

    func loadInitial() { bringIn(Project.createInitial(), message: "new score") }

    func loadSpecExample() { bringIn(Project.createSample(), message: "spec example") }

    func load(_ text: String, name: String) {
        do {
            bringIn(try ProjectFormat.read(text), message: "loaded \(name)")
        } catch {
            message = "could not read \(name): \(error.localizedDescription)"
        }
    }

    // A load while playing waits for the turn of the piece, and cannot be taken back
    // except by Stop.
    private func bringIn(_ incoming: Project, message: String) {
        if locked { return }

        self.message = message
        sequencer.switchTo(incoming)

        isSwitchPending = sequencer.isSwitchPending
        if isSwitchPending { self.message = message + ", in at the turn of the piece" }
    }

    // The sequencer changes hands up to a lookahead before the seam is heard, so the
    // plane is adopted only once the clock reaches the sample the switch carried.
    private func onSwitched(_ sample: Int64) {
        adoptAt = sample
        followTheSwitch()
    }

    private func followTheSwitch() {
        guard let at = adoptAt, let synth, synth.currentSample >= at else { return }

        adoptAt = nil

        project = sequencer.project
        selectedLane = nil
        reframe()

        isSwitchPending = sequencer.isSwitchPending
        revision += 1
    }

    // For running on a simulator without a hand: `-load sample1` loads a bundled score
    // and `-autoplay` presses Play.
    func followLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-load"), i + 1 < arguments.count {
            loadBundled(arguments[i + 1])
        }
        if arguments.contains("-autoplay") && !isPlaying { togglePlay() }
    }

    // MARK: Live effects

    func press(_ fx: LiveEffect) {
        guard let synth else { return }
        live.press(fx, sample: synth.currentSample)
    }

    func release(_ fx: LiveEffect) { live.release(fx) }

    // MARK: Channels

    func setMuted(_ channel: Int, _ muted: Bool) {
        project.mutes.setMuted(channel, muted)
        revision += 1
    }

    // MARK: The frame

    func update(frameDuration: Double) {
        guard let synth else { return }

        smoothDelta += (frameDuration - smoothDelta) * 0.1

        followTheSwitch()

        let now = synth.currentSample

        pending.removeAll(keepingCapacity: true)
        sequencer.schedule(currentSample: now, lookaheadSamples: lookaheadSamples,
                           sampleRate: synth.sampleRate, output: &pending)
        live.enqueue(pending)

        released.removeAll(keepingCapacity: true)
        live.handOver(horizon: now + liveLeadSamples, tempo: project.tempo,
                      sampleRate: synth.sampleRate, output: &released)

        for note in released { synth.schedule(note) }

        // One comparison covers every way the mix settings can change.
        let fx = MixFxRuntime.from(project.fx, project.limiter, volume: OutputVolume.decibels,
                                   tempo: project.tempo, sampleRate: Float(synth.sampleRate))
        if fx != lastFx {
            synth.setFx(fx)
            lastFx = fx
        }

        // Which channel the visualizer's second trace is of: decided here, because it is
        // a reading of the score, and the visualizer is not allowed to take one.
        synth.watchChannel(selectedLane.map { project.score.channelOf($0) } ?? 0)

        status = synth.status()

        if isPlaying != sequencer.isPlaying { isPlaying = sequencer.isPlaying }
    }

    // MARK: Playheads

    // Where each runner's playhead is, as the runners report it for the clock now.
    func playheads() -> [(Lane, Int)] {
        guard sequencer.isPlaying else { return [] }
        return sequencer.runners.compactMap { runner in
            guard let lane = runner.playingLane, runner.playingStep >= 0 else { return nil }
            return (lane, runner.playingStep)
        }
    }

    // MARK: Plane

    // Keeps free ground on the left and above without a coordinate going negative.
    static let padColumns = 10
    static let padRows = 8

    private func reframe() {
        let score = project.score
        guard !score.lanes.isEmpty else { return }
        let dx = max(0, JacquardEngine.padColumns - score.minX)
        let dy = max(0, JacquardEngine.padRows - score.minY)
        if dx != 0 || dy != 0 { score.translate(dx, dy) }
    }

    var planeColumns: Int { max(48, project.score.width + JacquardEngine.padColumns) }
    var planeRows: Int { max(28, project.score.height + JacquardEngine.padRows) }

    // MARK: Windows

    private var lookaheadSamples: Int64 {
        guard let synth else { return 0 }
        return Int64(lookahead * Float(synth.sampleRate)) + synth.minimumLead
    }

    private var liveLeadSamples: Int64 {
        guard let synth else { return 0 }
        return Int64(handoverSeconds * Float(synth.sampleRate)) + synth.minimumLead
    }

    // Two frames, smoothed, unless LiveLead asks for more: the window has to be longer
    // than a frame, and a device that drops to thirty frames a second when warm makes
    // that a number to be read rather than written down.
    private var handoverSeconds: Float {
        min(max(2 * Float(smoothDelta), liveLead), lookahead)
    }

    @ObservationIgnored private var smoothDelta: Double = 1.0 / 60.0
    @ObservationIgnored private var adoptAt: Int64?
    @ObservationIgnored private var pending: [FmNoteEvent] = []
    @ObservationIgnored private var released: [FmNoteEvent] = []
    @ObservationIgnored private var lastFx = MixFxRuntime(outputGain: -1)
    @ObservationIgnored private var displayLink: CADisplayLink?
}

// The display link retains its target, so it holds this rather than the engine.
private final class DisplayTarget {
    weak var engine: JacquardEngine?

    init(_ engine: JacquardEngine) { self.engine = engine }

    @objc func tick(_ link: CADisplayLink) {
        engine?.update(frameDuration: link.targetTimestamp - link.timestamp)
    }
}
