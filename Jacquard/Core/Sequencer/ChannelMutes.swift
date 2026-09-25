// Which channels are heard. Ported from Assets/Core/Sequencer/ChannelMutes.cs.
//
// A mute is silent but running; asked at the last moment, at a note's exit, so nothing
// above the note is skipped. Any solo overrides every mute.

final class ChannelMutes {
    func isMuted(_ channel: Int) -> Bool { muted[index(channel)] }
    func setMuted(_ channel: Int, _ value: Bool) { muted[index(channel)] = value }

    func isSoloed(_ channel: Int) -> Bool { soloed[index(channel)] }
    func setSoloed(_ channel: Int, _ value: Bool) { soloed[index(channel)] = value }

    var anySoloed: Bool { soloed.contains(true) }

    func sounds(_ channel: Int) -> Bool {
        anySoloed ? isSoloed(channel) : !isMuted(channel)
    }

    func swap(_ a: Int, _ b: Int) {
        let (mutedA, mutedB) = (isMuted(a), isMuted(b))
        let (soloedA, soloedB) = (isSoloed(a), isSoloed(b))
        setMuted(a, mutedB)
        setMuted(b, mutedA)
        setSoloed(a, soloedB)
        setSoloed(b, soloedA)
    }

    private func index(_ channel: Int) -> Int { PatchBank.clamp(channel) - 1 }

    private var muted = [Bool](repeating: false, count: PatchBank.channels)
    private var soloed = [Bool](repeating: false, count: PatchBank.channels)
}
