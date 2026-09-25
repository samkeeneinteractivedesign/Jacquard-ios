import SwiftUI

// The panels the transport row raises. Ported from ChannelsPanel.cs, SendPanel.cs,
// GlobalPanel.cs, SystemPanel.cs and LivePanel.cs in Assets/Jacquard/UI.

// MARK: - Channels

// A row per channel: Solo, Mute, and Select, which puts the cursor on the CHAN tile that
// names it. A solo overrules every mute. Under them, the Swap group, which exchanges
// everything two channel numbers key — and goes with the plane while a score waits, and
// with Stage Mode.
struct ChannelsPanel: View {
    let engine: JacquardEngine
    let editor: ScoreEditor
    let stageMode: Bool

    @State private var a = 1
    @State private var b = 2

    var body: some View {
        let _ = engine.panelRevision
        let mutes = engine.project.mutes
        let soloing = mutes.anySoloed

        Panel(title: "Channels") {
            ForEach(1...PatchBank.channels, id: \.self) { channel in
                HStack(spacing: Controls.gap) {
                    Text("\(channel)")
                        .font(Style.font(Controls.fontSize))
                        .foregroundColor(Style.label)
                        .frame(width: Controls.fontSize, height: Controls.rowHeight, alignment: .leading)

                    PushButton(label: "Solo", width: Controls.width(40), active: mutes.isSoloed(channel)) {
                        mutes.setSoloed(channel, !mutes.isSoloed(channel))
                        editor.touch()
                    }

                    PushButton(label: "Mute", width: Controls.width(40), active: mutes.isMuted(channel)) {
                        if mutes.anySoloed { return }
                        mutes.setMuted(channel, !mutes.isMuted(channel))
                        editor.touch()
                    }
                    .opacity(soloing ? Style.dimmedOpacity : 1)

                    PushButton(label: "Select") {
                        if let head = headOf(channel) { editor.setCursor(head) }
                    }
                    .opacity(headOf(channel) == nil ? Style.dimmedOpacity : 1)
                }
                .padding(.bottom, Controls.gap)
            }

            if !stageMode { swap }
        }
    }

    private func headOf(_ channel: Int) -> GridPoint? {
        engine.project.score.channelLanes.first { $0.channel?.channel == channel }?.headPoint
    }

    private var swap: some View {
        let numbers = (1...PatchBank.channels).map(String.init)
        return VStack(spacing: 0) {
            Heading(text: "Swap", follows: true)
            HStack(spacing: Controls.gap) {
                Chooser(options: numbers, index: a - 1) { a = $0 + 1 }
                    .frame(maxWidth: .infinity)
                Text("⇄")
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.label)
                Chooser(options: numbers, index: b - 1) { b = $0 + 1 }
                    .frame(maxWidth: .infinity)
            }
            PushButton(label: "Swap") { editor.swapChannels(a, b) }
                .opacity(a == b ? Style.dimmedOpacity : 1)
                .padding(.bottom, Controls.gap)
        }
        .opacity(engine.locked ? Style.dimmedOpacity : 1)
        .allowsHitTesting(!engine.locked)
    }
}

// MARK: - Send FX

// One reverb and one delay for the whole project; how much of a channel reaches each is
// the last two rows of its sound.
struct SendPanel: View {
    let engine: JacquardEngine
    let editor: ScoreEditor

    static let unit = BarRange.amount(0, 1)
    static let feedbackRange = BarRange.amount(0, SendFx.maxFeedback)

    var body: some View {
        let revision = engine.panelRevision
        let project = engine.project

        Panel(title: "Send FX") {
            Heading(text: "Reverb")
            BarRow(caption: "Size", range: SendPanel.unit, revision: revision,
                   get: { project.fx.reverbSize }, set: { project.fx.reverbSize = $0; editor.touch() })
            BarRow(caption: "Tone", range: SendPanel.unit, revision: revision,
                   get: { project.fx.reverbTone }, set: { project.fx.reverbTone = $0; editor.touch() })
            BarRow(caption: "Spread", range: SendPanel.unit, revision: revision,
                   get: { project.fx.reverbSpread }, set: { project.fx.reverbSpread = $0; editor.touch() })

            Heading(text: "Delay", follows: true)
            Chooser(caption: "Time", options: DelayTime.names,
                    index: DelayTime.nearest(project.fx.delayBeats)) {
                project.fx.delayBeats = DelayTime.beats[$0]
                editor.touch()
            }
            BarRow(caption: "Feedback", range: SendPanel.feedbackRange, revision: revision,
                   get: { project.fx.delayFeedback }, set: { project.fx.delayFeedback = $0; editor.touch() })
            BarRow(caption: "Tone", range: SendPanel.unit, revision: revision,
                   get: { project.fx.delayTone }, set: { project.fx.delayTone = $0; editor.touch() })
            BarRow(caption: "Spread", range: SendPanel.unit, revision: revision,
                   get: { project.fx.delaySpread }, set: { project.fx.delaySpread = $0; editor.touch() })
        }
    }
}

// MARK: - Global

// The scale, a switch per semitone laid out as a keyboard, and the limiter.
struct GlobalPanel: View {
    let engine: JacquardEngine
    let editor: ScoreEditor

    static let thresholdRange = BarRange(Limiter.minCeiling, 0, unit: "dB", digits: 1)
    static let attackRange = BarRange.seconds(Limiter.minAttack, Limiter.maxAttack)
    static let releaseRange = BarRange.seconds(Limiter.minRelease, Limiter.maxRelease)

    var body: some View {
        let revision = engine.panelRevision
        let project = engine.project

        Panel(title: "Global") {
            Heading(text: "Scale")
            Keys(lit: { project.scale.allows($0) }) { degree in
                project.scale.setAllowed(degree, !project.scale.allows(degree))
                editor.touch()
            }

            Heading(text: "Limiter", follows: true)
            BarRow(caption: "Threshold", range: GlobalPanel.thresholdRange, revision: revision,
                   get: { project.limiter.ceiling }, set: { project.limiter.ceiling = $0; editor.touch() })
            BarRow(caption: "Attack", range: GlobalPanel.attackRange, revision: revision,
                   get: { project.limiter.attack }, set: { project.limiter.attack = $0; editor.touch() })
            BarRow(caption: "Release", range: GlobalPanel.releaseRange, revision: revision,
                   get: { project.limiter.release }, set: { project.limiter.release = $0; editor.touch() })
        }
    }
}

// MARK: - System

// What is set about the app rather than the piece. Nothing here is saved with a project.
struct SystemPanel: View {
    let engine: JacquardEngine
    let editor: ScoreEditor
    @Binding var stageMode: Bool

    @State private var audition = Audition.on

    static let volumeRange = BarRange(OutputVolume.minVolume, 0, curve: 0.4, unit: "dB", digits: 1,
                                      display: { $0 <= OutputVolume.minVolume ? "off"
                                                 : String(format: "%.1f dB", Double($0)) })
    static let bufferRange = BarRange(Float(DspBuffer.min), Float(DspBuffer.max),
                                      snap: Float(DspBuffer.step), digits: 0)

    var body: some View {
        let revision = engine.panelRevision

        Panel(title: "System") {
            ToggleRow(caption: "Visualizer", on: engine.visualizerOn) { engine.visualizerOn.toggle() }
            ToggleRow(caption: "Audition", on: audition) {
                Audition.on.toggle()
                audition = Audition.on
            }

            BarRow(caption: "Volume", range: SystemPanel.volumeRange, revision: revision,
                   get: { OutputVolume.decibels }, set: { OutputVolume.decibels = $0; editor.touch() })

            BarRow(caption: "Buffer size", range: SystemPanel.bufferRange, revision: revision,
                   get: { Float(DspBuffer.requested) },
                   set: { DspBuffer.requested = Int($0.rounded()); editor.touch() })

            if DspBuffer.requested != DspBuffer.applied {
                Text("Applies at the next launch.")
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.label)
                    .padding(.bottom, Controls.gap)
            }

            ToggleRow(caption: "Stage Mode", on: stageMode) {
                StageMode.on.toggle()
                stageMode = StageMode.on
            }

            Text("Scores are in the Files app, under On My \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") › Jacquard › Scores.")
                .font(Style.font(Controls.fontSize))
                .foregroundColor(Style.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Controls.groupGap)
                .padding(.bottom, Controls.gap)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(Style.font(Controls.fontSize))
                .foregroundColor(Style.label)
                .padding(.top, Controls.groupGap)
                .padding(.bottom, Controls.gap)
        }
    }
}

// MARK: - Live FX

// Twelve buttons that act only while held, in two rows, the pairs one over the other.
struct LivePanel: View {
    let engine: JacquardEngine

    static let top: [LiveEffect] = [.reverb, .stab, .octaveDown, .fall, .roll1, .roll3]
    static let bottom: [LiveEffect] = [.delay, .sustain, .octaveUp, .rise, .roll2, .roll4]

    var body: some View {
        Panel(title: "Live FX", width: nil) {
            row(LivePanel.top)
            row(LivePanel.bottom)
        }
    }

    private func row(_ effects: [LiveEffect]) -> some View {
        HStack(spacing: Controls.gap) {
            ForEach(effects, id: \.self) { fx in
                HoldButton(label: fx.label, width: Controls.width(70), height: Controls.rowHeight * 1.5,
                           press: { engine.press(fx) }, release: { engine.release(fx) })
            }
        }
        .padding(.bottom, Controls.gap)
    }
}
