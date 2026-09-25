import SwiftUI

// The screen: the visualizer behind everything, the plane scrolling over it, and the
// transport row along the bottom on a ground of its own, since a row of controls with a
// waveform running behind it has to be read through something.
//
// This is the first cut of the interface. The Unity app's panels — the tile inspector,
// the Sound, Send FX, Global, Channels and System panels, and editing by drag — are the
// next part of the port; see README.md.

struct ContentView: View {
    @State private var engine = JacquardEngine()
    @State private var position = ScrollPosition(edge: .top)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            VisualizerView(engine: engine)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    ScorePlaneView(engine: engine)
                }
                .scrollIndicators(.hidden)
                .scrollPosition($position)
                .onAppear { revealScore() }
                .onChange(of: engine.project.score.lanes.count) { revealScore() }

                TransportBar(engine: engine)
            }
        }
        .task { engine.followLaunchArguments() }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: engine.suspend()
            case .active: engine.resume()
            default: break
            }
        }
    }
}

extension ContentView {
    // Opens on the score rather than on the free ground the plane keeps above and to the
    // left of it.
    fileprivate func revealScore() {
        let score = engine.project.score
        let corner = Style.cellOrigin(GridPoint(score.minX, score.minY))
        position.scrollTo(point: CGPoint(x: max(0, corner.x - Style.strideX),
                                         y: max(0, corner.y - Style.strideY)))
    }
}

private struct TransportBar: View {
    let engine: JacquardEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PanelButton(label: engine.isPlaying ? "Stop" : "Play", active: engine.isPlaying) {
                    engine.togglePlay()
                }

                Menu {
                    Button("New score") { engine.loadInitial() }
                    Button("Spec example") { engine.loadSpecExample() }
                    Divider()
                    ForEach(JacquardEngine.bundledScores, id: \.self) { name in
                        Button(name) { engine.loadBundled(name) }
                    }
                } label: {
                    PanelLabel(text: "Load", active: false)
                }
                .disabled(engine.locked)

                Text("\(Format.short(engine.project.tempo, places: 1)) BPM")
                    .font(Style.font(Style.controlSize))
                    .foregroundColor(Style.label)

                Spacer(minLength: 0)

                Text(engine.message)
                    .font(Style.font(Style.controlSize))
                    .foregroundColor(Style.label)
                    .lineLimit(1)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(LiveEffect.allCases, id: \.self) { fx in
                        LiveButton(fx: fx, engine: engine)
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 6) {
                ForEach(1...PatchBank.channels, id: \.self) { channel in
                    MuteButton(channel: channel, engine: engine)
                }
            }
        }
        .padding(.horizontal, Style.padding)
        .padding(.vertical, 12)
        .background(Style.panel.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Style.panelLine).frame(height: 1)
        }
    }
}

// A live effect lasts only as long as a hand is on it.
private struct LiveButton: View {
    let fx: LiveEffect
    let engine: JacquardEngine
    @State private var held = false

    var body: some View {
        PanelLabel(text: fx.label, active: held)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !held {
                            held = true
                            engine.press(fx)
                        }
                    }
                    .onEnded { _ in
                        held = false
                        engine.release(fx)
                    })
    }
}

// Silent but running: the laps go on being counted.
private struct MuteButton: View {
    let channel: Int
    let engine: JacquardEngine

    var body: some View {
        let _ = engine.revision
        let muted = engine.project.mutes.isMuted(channel)
        PanelButton(label: "CH\(channel)", active: !muted) {
            engine.setMuted(channel, !muted)
        }
    }
}

private struct PanelButton: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { PanelLabel(text: label, active: active) }
            .buttonStyle(.plain)
    }
}

private struct PanelLabel: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(Style.font(Style.controlSize, bold: active))
            .foregroundColor(active ? Style.background : Style.noteText)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: Style.radius)
                .fill(active ? Style.noteLine : Style.controlBackground))
    }
}
