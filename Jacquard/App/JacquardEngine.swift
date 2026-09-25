import Foundation
import QuartzCore
import Observation

// The app: the project, the sequencer, the live effects and the synth, the score folder,
// and the frame that runs them. Ported from the parts of Assets/Jacquard/App/JacquardApp.cs
// that are not Unity plumbing.
//
// The sequencer runs its full lookahead ahead of the audio clock every frame and parks
// what it produces with the live effects; a note is handed to the synth only once it is
// nearly due, so a live effect pressed now is heard on the next note.

@Observable
final class JacquardEngine {
    // How far ahead of the audio clock the sequencer runs.
    @ObservationIgnored var lookahead: Float = 0.12

    // The floor of the handover window. See handoverSeconds.
    @ObservationIgnored var liveLead: Float = 0.03

    static let maxVoices = 24

    private(set) var project: Project
    @ObservationIgnored let sequencer = Sequencer()
    @ObservationIgnored let live = LiveFx()
    @ObservationIgnored let store = ProjectStore()
    @ObservationIgnored private(set) var synth: FmSynth?

    @ObservationIgnored private(set) var editor: ScoreEditor!

    // Bumped whenever the plane has to be redrawn from the score, and whenever a panel
    // has to read the model again. The model is plain classes, so these are what tell
    // SwiftUI something under it moved.
    private(set) var planeRevision = 0
    private(set) var panelRevision = 0

    private(set) var isPlaying = false
    private(set) var isSwitchPending = false
    private(set) var message = ""

    // Not observed, so it does not redraw the screen every frame.
    @ObservationIgnored private(set) var status = FmSynthStatus()

    var visualizerOn = VisualizerSetting.on {
        didSet { VisualizerSetting.on = visualizerOn }
    }

    // The plane is held still while a score waits for the turn of the piece.
    var locked: Bool { isSwitchPending }

    // The pan across the plane, in points.
    var pan: CGPoint = .zero

    init() {
        project = Project()

        store.seed(samples: 5) { index in
            guard let url = Bundle.main.url(forResource: ProjectStore.sampleName(index),
                                            withExtension: ProjectFormat.fileExtension),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return try? ProjectFormat.read(text)
        }

        store.name = store.opening()
        project = store.load().0 ?? Project.createInitial()

        editor = ScoreEditor(engine: self)

        reframe(arrived: true)
        showScore()

        sequencer.project = project
        sequencer.switched = { [weak self] at in self?.onSwitched(at) }

        DspBuffer.applied = DspBuffer.requested
        synth = FmSynth(maxVoices: JacquardEngine.maxVoices, bufferFrames: DspBuffer.applied)

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

    var tempo: Float {
        get { project.tempo }
        set { project.tempo = newValue; touchPanels() }
    }

    // MARK: Scores

    func slots() -> [String] { store.slots() }

    func save() {
        message = store.save(project)
        touchPanels()
    }

    func load() {
        if locked { return }
        let (loaded, text) = store.load()
        message = text
        if let loaded { bringIn(loaded, message: text) }
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

    // For running on a simulator without a hand: `-load sample1` loads a score from the
    // folder and `-autoplay` presses Play.
    func followLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-load"), i + 1 < arguments.count {
            store.name = arguments[i + 1]
            load()
        }
        if arguments.contains("-autoplay") && !isPlaying { togglePlay() }
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
        reframe(arrived: true)

        isSwitchPending = sequencer.isSwitchPending
        planeRevision += 1
        panelRevision += 1
    }

    // MARK: Live effects

    func press(_ fx: LiveEffect) {
        guard let synth else { return }
        live.press(fx, sample: synth.currentSample)
    }

    func release(_ fx: LiveEffect) { live.release(fx) }

    // MARK: Redrawing

    // After an edit: carry the score in if it has come too near an edge, then redraw.
    func rebuild() {
        reframe(arrived: false)
        planeRevision += 1
        panelRevision += 1
    }

    func touchPanels() { panelRevision += 1 }

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
        // a reading of the score, and the visualizer is not allowed to take one. Nothing,
        // with the visualizer switched off.
        let lane = editor.selectedLane
        synth.watchChannel(lane != nil && visualizerOn ? project.score.channelOf(lane) : 0)

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

    // The plane keeps ten columns and eight rows of empty ground past the score. To the
    // right and below that is the plane's own size; to the left and above the score is
    // carried further in instead, and the pan and the cursor move with it so nothing on
    // screen jumps. A score arriving is not a score moving, and takes up no pan.
    static let padColumns = 10
    static let padRows = 8

    private func reframe(arrived: Bool) {
        let score = project.score
        guard !score.lanes.isEmpty else { return }

        let dx = max(0, JacquardEngine.padColumns - score.minX)
        let dy = max(0, JacquardEngine.padRows - score.minY)
        if dx == 0 && dy == 0 { return }

        score.translate(dx, dy)
        if arrived { return }

        editor.offsetCursor(dx, dy)
        pan.x += CGFloat(dx) * Style.strideX
        pan.y += CGFloat(dy) * Style.strideY
    }

    // Opens on the score, with the cursor on its master lane's head.
    private func showScore() {
        let score = project.score
        if let master = score.masterLane { editor.setCursor(master.headPoint) }
        pan = CGPoint(x: max(0, Style.cellOrigin(GridPoint(score.minX, 0)).x - Style.strideX),
                      y: max(0, Style.cellOrigin(GridPoint(0, score.minY)).y - Style.strideY))
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
