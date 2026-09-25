// The dynamic object that scans a lane. Ported from Assets/Core/Sequencer/Runner.cs.
//
// One per CHAN lane; a jump moves it rather than making another. Not running is said by
// the sample (Runner.never), never by a flag beside it.

final class Runner {
    let originLane: Lane
    var order: Int

    var channel: Int { originLane.channel?.channel ?? 1 }

    var lane: Lane
    var stepIndex = 0
    var pass = 0
    var nextSample: Double

    static let never = Double.greatestFiniteMagnitude

    var running: Bool { nextSample < Runner.never }

    // What the playhead shows: the step being heard now, a lookahead behind the step the
    // runner has scheduled.
    private(set) var playingLane: Lane?
    private(set) var playingStep = -1

    init(origin: Lane, order: Int, startSample: Double) {
        self.originLane = origin
        self.order = order
        self.nextSample = startSample
        self.lane = origin
    }

    func stepSeconds(_ tempo: Float) -> Float {
        originLane.channel?.stepSeconds(tempo) ?? 0.125
    }

    // The locks of the step this runner is standing on, put back at its own place in
    // the pass until the step ends.
    var heldLocks: [ParamTile] { held }
    private(set) var holdUntil: Double = 0

    func beginHold(_ until: Double) {
        held.removeAll(keepingCapacity: true)
        holdUntil = until
    }

    func hold(_ tile: ParamTile) { held.append(tile) }

    func record(_ sample: Int64, _ lane: Lane?, _ step: Int) {
        scheduled.append(Marker(sample: sample, lane: lane, step: step))
    }

    func advancePlayhead(_ currentSample: Int64) {
        while head < scheduled.count && scheduled[head].sample <= currentSample {
            let marker = scheduled[head]
            head += 1
            (playingLane, playingStep) = (marker.lane, marker.step)
        }

        // Compact now and then rather than dequeuing from the front of an array.
        if head > 64 {
            scheduled.removeFirst(head)
            head = 0
        }
    }

    func clearPlayhead() {
        scheduled.removeAll()
        head = 0
        (playingLane, playingStep) = (nil, -1)
    }

    private struct Marker {
        var sample: Int64
        var lane: Lane?
        var step: Int
    }

    private var scheduled: [Marker] = []
    private var head = 0
    private var held: [ParamTile] = []
}
