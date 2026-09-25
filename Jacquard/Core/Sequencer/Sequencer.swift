// Turns a score into note events. Ported from Assets/Core/Sequencer/Sequencer.cs.
//
// The model, as the original states it: timing rides the audio clock, and one instant
// is one downward pass — lanes in CHAN order, each stack from the rail row down. A lock
// lasts for the step it sits on and reaches only what is read after it. A score comes
// in on the turn of the piece, the instant the master lane's runner laps.

final class Sequencer {
    var project: Project! {
        didSet {
            (incoming, boundary) = (nil, Sequencer.noBoundary)
            master = findMaster()
        }
    }

    var isPlaying: Bool { playing }
    var runners: [Runner] { _runners }
    var masterRunner: Runner? { master }
    var isSwitchPending: Bool { incoming != nil }

    // The sample a switched score takes over at, or 0 when it took over while stopped.
    var switched: ((Int64) -> Void)?

    func switchTo(_ project: Project) {
        incoming = project
        settleIfIdle()
    }

    func play(currentSample: Int64, lookaheadSamples: Int64) {
        stop()
        populate(Double(currentSample + lookaheadSamples))
    }

    func stop() {
        playing = false
        _runners.removeAll()
        (master, boundary) = (nil, Sequencer.noBoundary)
        settleIfIdle()
    }

    // Every enabled CHAN lane starts at once; the master lane runs whatever its switch.
    private func populate(_ startSample: Double) {
        _runners.removeAll()

        let masterLane = project.score.masterLane
        var order = 0

        for lane in project.score.channelLanes {
            let running = lane === masterLane || lane.channel!.enabled
            _runners.append(Runner(origin: lane, order: order,
                                   startSample: running ? startSample : Runner.never))
            order += 1
        }

        master = findMaster()
        playing = !_runners.isEmpty
    }

    private static func start(_ runner: Runner, _ sample: Double) {
        runner.lane = runner.originLane
        runner.stepIndex = 0
        runner.pass = 0
        runner.nextSample = sample
        runner.beginHold(0)
    }

    // A CHAN switched on waits for the turn of the piece, and starts counting laps from
    // zero there.
    private func startPending(_ sample: Double) {
        for runner in _runners where !runner.running && runner.originLane.channel!.enabled {
            Sequencer.start(runner, sample)
        }
    }

    private func findMaster() -> Runner? {
        let lane = project?.score.masterLane
        for runner in _runners where runner.originLane === lane { return runner }
        return _runners.first
    }

    private func settleIfIdle() {
        guard !playing, let next = incoming else { return }
        project = next
        switched?(0)
    }

    // Follows an edit: keeps the runner of every lane that is still there, adds one that
    // waits for the turn for a lane newly drawn, and drops the rest.
    func resync() {
        guard playing else { return }

        let previous = _runners
        _runners.removeAll()

        var order = 0
        for lane in project.score.channelLanes {
            let runner = previous.first { $0.originLane === lane }
                ?? Runner(origin: lane, order: order, startSample: Runner.never)

            if !project.score.lanes.contains(where: { $0 === runner.lane }) {
                runner.lane = lane
            }
            if runner.stepIndex >= runner.lane.steps.count { runner.stepIndex = 0 }

            runner.order = order
            order += 1
            _runners.append(runner)
        }

        master = findMaster()
        playing = !_runners.isEmpty
        settleIfIdle()
    }

    // Runs every runner up to the horizon, a slice at a time, in sample order.
    func schedule(currentSample: Int64, lookaheadSamples: Int64, sampleRate: Int,
                  output: inout [FmNoteEvent]) {
        for runner in _runners { runner.advancePlayhead(currentSample) }

        guard playing, let master else { return }

        // While the transport runs, the master runner is running. An edit can break
        // that, and this is the place with a clock to repair it.
        if !master.running {
            Sequencer.start(master, Double(currentSample + lookaheadSamples))
        }

        let horizon = Double(currentSample + lookaheadSamples)

        for _ in 0..<1024 {
            let limit = boundary < horizon ? boundary - Sequencer.tolerance : horizon

            var next = Double.greatestFiniteMagnitude
            for runner in _runners where runner.nextSample < next { next = runner.nextSample }

            if next < limit {
                guard let current = self.master else { break }
                let watching = incoming != nil && !hasBoundary
                let lap = current.pass

                runSlice(next, sampleRate, &output)

                if current.pass != lap {
                    if watching { boundary = current.nextSample }
                    else if !hasBoundary { startPending(current.nextSample) }
                }
                continue
            }

            if boundary >= horizon { break }

            takeOver()
        }

        if !didSwitch { return }
        didSwitch = false
        switched?(switchedAt)
    }

    private func takeOver() {
        let at = boundary
        project = incoming
        (incoming, boundary) = (nil, Sequencer.noBoundary)
        populate(at)
        (didSwitch, switchedAt) = (true, Int64(at))
    }

    // One instant: every runner that lands here or is still holding a step's locks, in
    // CHAN order, over a working copy of the bank.
    private func runSlice(_ time: Double, _ sampleRate: Int, _ output: inout [FmNoteEvent]) {
        let startSample = Int64(time)

        slice.removeAll(keepingCapacity: true)
        for runner in _runners
        where Sequencer.lands(runner, time) || Sequencer.holding(runner, time) {
            slice.append(runner)
        }
        slice.sort { $0.order < $1.order }

        working.copy(from: project.patches)

        for runner in slice {
            if Sequencer.lands(runner, time) {
                execute(runner, startSample, sampleRate, &output)
            } else {
                reapply(runner)
            }
        }
    }

    private static func lands(_ runner: Runner, _ time: Double) -> Bool {
        runner.nextSample < time + tolerance
    }

    private static func holding(_ runner: Runner, _ time: Double) -> Bool {
        time + tolerance <= runner.holdUntil
    }

    private func execute(_ runner: Runner, _ startSample: Int64, _ sampleRate: Int,
                         _ output: inout [FmNoteEvent]) {
        let stepSeconds = runner.stepSeconds(project.tempo)
        let lane = runner.lane
        let step = lane.stepAt(runner.stepIndex)
        let after = runner.nextSample + Double(stepSeconds) * Double(sampleRate)

        runner.record(startSample, lane, runner.stepIndex)
        runner.beginHold(after)

        let destination = step.flatMap {
            descend($0, runner, startSample, stepSeconds, &output)
        }

        if let destination {
            runner.lane = destination
            runner.stepIndex = 0
            runner.nextSample = after
            return
        }

        if advance(runner) {
            runner.nextSample = after
            return
        }

        runner.record(Int64(after), nil, -1)
        runner.nextSample = Runner.never
    }

    // The stack, top down. A gate that does not fire ends the walk; a lock colours what
    // follows; a note sounds in the state as it stands at that depth; a jump decides where
    // the next step is, the lowest reachable one winning.
    private func descend(_ step: Step, _ runner: Runner, _ startSample: Int64,
                         _ stepSeconds: Float, _ output: inout [FmNoteEvent]) -> Lane? {
        let channel = runner.channel
        var destination: Lane?

        for tile in step.tiles {
            if let gate = tile as? GateTile, !gate.evaluate(pass: runner.pass, random: &random) {
                break
            }

            switch tile {
            case let param as ParamTile:
                apply(param, channel)
                runner.hold(param)

            case let note as NoteTile:
                guard project.mutes.sounds(channel) else { break }
                let patch = working[channel]
                output.append(FmNoteEvent.fromPatch(
                    patch,
                    note: project.soundingPitch(patch, note.note),
                    gateSeconds: note.length * stepSeconds,
                    startSample: startSample,
                    channel: channel))

            case let jump as JumpTile:
                if let branch = project.score.destinationOf(jump), !branch.steps.isEmpty {
                    destination = branch
                }

            default:
                break
            }
        }

        return destination
    }

    // Reaching the terminator returns to the CHAN the runner started from, and is a lap —
    // unless the lane has been switched off, in which case it stops there.
    private func advance(_ runner: Runner) -> Bool {
        runner.stepIndex += 1
        if runner.stepIndex < runner.lane.steps.count { return true }

        runner.lane = runner.originLane
        runner.stepIndex = 0

        if runner !== master && !runner.originLane.channel!.enabled { return false }

        runner.pass += 1
        return true
    }

    private func reapply(_ runner: Runner) {
        let channel = runner.channel
        for tile in runner.heldLocks { apply(tile, channel) }
    }

    private func apply(_ param: ParamTile, _ channel: Int) {
        let absolute = param is AbsoluteParamTile
        var patch = working[channel]

        for target in 0..<ParamTargets.count where param.isEngaged(target) {
            if absolute { ParamTargets.set(&patch, target, param[target]) }
            else { ParamTargets.add(&patch, target, param[target]) }
        }

        working[channel] = patch
    }

    // Half a sample: the one tolerance asked in all three places.
    static let tolerance = 0.5
    static let noBoundary = Double.greatestFiniteMagnitude

    private var _runners: [Runner] = []
    private var slice: [Runner] = []
    private let working = PatchBank()
    private var random = SystemRandomNumberGenerator()

    private var incoming: Project?
    private var master: Runner?
    private var boundary = Sequencer.noBoundary
    private var hasBoundary: Bool { boundary < Sequencer.noBoundary }

    private var didSwitch = false
    private var switchedAt: Int64 = 0
    private var playing = false
}
