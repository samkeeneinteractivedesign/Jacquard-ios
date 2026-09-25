import Foundation

// The unit of file saving, sitting above the score. Ported from
// Assets/Core/Model/Project.cs.
//
// It holds what applies to everything: tempo and meter, the patch bank, the send
// effects, the limiter, the mutes and the scale.

final class Project {
    var tempo: Float = 120
    var beatsPerBar = 4
    var beatUnit = 4

    var fx = SendFx.default
    var limiter = Limiter.default

    var score = Score()
    let patches = PatchBank()
    let mutes = ChannelMutes()
    let scale = Scale()

    // What a written note actually sounds as: the channel moves it, and then the scale
    // decides whether it will have it there. The order is the whole of what this says.
    func soundingPitch(_ patch: FmPatch, _ note: Int) -> Int {
        scale.snap(note + Int(patch.transpose.rounded(.toNearestOrEven)))
    }

    // Exchanges everything a channel number keys, so that two channels trade places and
    // the piece goes on sounding as it did. Its own inverse.
    func swapChannels(_ a: Int, _ b: Int) {
        let (a, b) = (PatchBank.clamp(a), PatchBank.clamp(b))
        if a == b { return }

        let patch = patches[a]
        patches[a] = patches[b]
        patches[b] = patch

        mutes.swap(a, b)

        for lane in score.lanes {
            guard let channel = lane.channel else { continue }
            if channel.channel == a { channel.channel = b }
            else if channel.channel == b { channel.channel = a }
        }
    }

    // What a score starts as: one lane of sixteen steps with a C4 on every fourth, and
    // a tone to hear them in.
    static func createInitial() -> Project {
        let project = Project()
        let lane = project.score.addLane(x: 1, y: 1, head: ChannelTile(), steps: 16)

        for step in stride(from: 0, to: 16, by: 4) {
            fill(lane, step, NoteTile(note: n("C4")))
        }

        for channel in 1...PatchBank.channels {
            var patch = project.patches[channel]
            dialTheOpeningVoice(&patch)
            project.patches[channel] = patch
        }

        return project
    }

    // A modulator three times the carrier and a radian deep, its decay halfway, and a
    // hundred milliseconds of release. Settled by ear in the original.
    static func dialTheOpeningVoice(_ patch: inout FmPatch) {
        patch.modulatorRatio = 3
        patch.modulationIndex = 1
        patch.modulatorDecay = 0.5
        patch.carrierRelease = 0.1
    }

    // The worked example the specification was written against: three lanes, a
    // conditional jump into a variation, and an accent lane that has no notes of its own.
    static func createSample() -> Project {
        let project = Project()
        let score = project.score

        let accent = score.addLane(x: 1, y: 1, head: ChannelTile(channel: 1), steps: 4)
        fill(accent, 0, lock(RelativeParamTile(), ParamTargets.level, 2))
        fill(accent, 2, lock(RelativeParamTile(), ParamTargets.level, -5))

        let main = score.addLane(x: 1, y: 3, head: ChannelTile(channel: 1), steps: 16)

        fill(main, 0, NoteTile(note: n("C4"), length: 4), NoteTile(note: n("E4")),
             NoteTile(note: n("G4")))
        fill(main, 2, NoteTile(note: n("F#4"), length: 0.5))
        fill(main, 3, lock(AbsoluteParamTile(), ParamTargets.modIndex, 7),
             NoteTile(note: n("A4")))
        fill(main, 5, NoteTile(note: n("G4")))
        fill(main, 8, CycleGateTile(period: 4, pattern: "0010"),
             NoteTile(note: n("F4")),
             lock(RelativeParamTile(), ParamTargets.modIndex, 3),
             NoteTile(note: n("G#4"), length: 1.5),
             NoteTile(note: n("C5")))

        let jump = JumpTile()
        fill(main, 9, CycleGateTile(period: 4, pattern: "0001"), jump)

        fill(main, 10, NoteTile(note: n("A#4")))
        fill(main, 11, ProbGateTile(percent: 35), NoteTile(note: n("B4")),
             NoteTile(note: n("D5")))
        fill(main, 13, lock(RelativeParamTile(), ParamTargets.modDecay, 0.5),
             NoteTile(note: n("E5"), length: 2))

        let variation = score.addLane(x: 6, y: 9, head: JumpDestTile(), steps: 6)
        variation.jumpSource = jump

        fill(variation, 0, NoteTile(note: n("D#5")), NoteTile(note: n("C5")),
             NoteTile(note: n("G#4")))
        fill(variation, 2, NoteTile(note: n("A#4"), length: 0.5))
        fill(variation, 3, ProbGateTile(percent: 70), NoteTile(note: n("G4")))
        fill(variation, 4, NoteTile(note: n("F4")))

        return project
    }

    private static func fill(_ lane: Lane, _ step: Int, _ tiles: Tile...) {
        lane.steps[step].tiles.append(contentsOf: tiles)
    }

    private static func lock(_ tile: ParamTile, _ target: Int, _ amount: Float) -> ParamTile {
        tile.engage(target, amount)
        return tile
    }

    private static func n(_ name: String) -> Int { Pitch.parse(name) ?? 60 }
}
