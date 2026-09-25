import SwiftUI

// The screen. Ported from the layout half of Assets/Jacquard/UI/JacquardUI.cs.
//
// The visualizer behind everything; the plane over it; the transport row along the top
// on a ground of its own; and the panels standing on the plane — the Tile panel in the
// right column outermost with Send FX inside it, Channels on the left, Global and System
// in the centre, Live FX across the bottom. Everything the transport row switches starts
// off.

struct ContentView: View {
    @State private var engine = JacquardEngine()
    @State private var stageMode = StageMode.on
    @State private var shown: Set<PanelKind> = []
    @Environment(\.scenePhase) private var scenePhase

    enum PanelKind: String { case channels, send, live, global, system }

    var body: some View {
        let editor = engine.editor!

        ZStack {
            if engine.visualizerOn {
                VisualizerView(engine: engine)
                    .ignoresSafeArea()
            } else {
                Style.background.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                TransportRow(engine: engine, stageMode: stageMode, shown: $shown)

                ZStack(alignment: .top) {
                    ScorePlaneView(engine: engine, editor: editor)

                    // Each column is laid over the plane without taking any room from it
                    // or from the others. On a phone the columns meet, and a panel a
                    // switch raised stands in front of the Tile panel, since it is the one
                    // just asked for.
                    Color.clear
                        .overlay(alignment: .topTrailing) {
                            HStack(alignment: .top, spacing: Controls.panelGap) {
                                PanelColumn {
                                    if shown.contains(.send) { SendPanel(engine: engine, editor: editor) }
                                }
                                PanelColumn {
                                    InspectorPanel(engine: engine, editor: editor)
                                }
                            }
                        }
                        .overlay(alignment: .top) {
                            PanelColumn {
                                if shown.contains(.global) { GlobalPanel(engine: engine, editor: editor) }
                                if shown.contains(.system) {
                                    SystemPanel(engine: engine, editor: editor, stageMode: $stageMode)
                                }
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            PanelColumn {
                                if shown.contains(.channels) {
                                    ChannelsPanel(engine: engine, editor: editor, stageMode: stageMode)
                                }
                            }
                        }
                        .padding(Controls.panelGap)

                    if shown.contains(.live) {
                        VStack {
                            Spacer()
                            ScrollView(.horizontal) {
                                LivePanel(engine: engine)
                            }
                            .scrollIndicators(.hidden)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Controls.panelGap)
                            .padding(.bottom, Controls.panelGap)
                        }
                    }
                }
            }
        }
        .task {
            engine.followLaunchArguments()
            // `-panels live,system` opens panels at launch, for the simulator.
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "-panels"), i + 1 < arguments.count {
                for name in arguments[i + 1].split(separator: ",") {
                    if let kind = PanelKind(rawValue: String(name)) { shown.insert(kind) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: engine.suspend()
            case .active: engine.resume()
            default: break
            }
        }
    }
}

// A column of panels that is as tall as what it holds, and scrolls once that is more
// than the screen — without claiming the empty plane below it.
private struct PanelColumn<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: Controls.panelGap) { content() }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(height, geometry.size.height))
        }
        .frame(width: height > 0 ? Controls.panelWidth : 0)
    }
}

// Play and the tempo, the switches that raise the panels, and the score chooser with
// Save and Load — sliding sideways when it holds more than the screen.
private struct TransportRow: View {
    let engine: JacquardEngine
    let stageMode: Bool
    @Binding var shown: Set<ContentView.PanelKind>

    @State private var slots: [String] = []

    static let tempoRange = BarRange(20, 300, snap: 1, unit: "bpm", digits: 0)

    var body: some View {
        let revision = engine.panelRevision

        ScrollView(.horizontal) {
            HStack(spacing: Controls.gap) {
                PushButton(label: engine.isPlaying ? "Stop" : "Play", width: Controls.width(54),
                           active: engine.isPlaying) { engine.togglePlay() }

                ValueBar(range: TransportRow.tempoRange, get: { engine.tempo },
                         set: { engine.tempo = $0 }, revision: revision)
                    .frame(width: Controls.panelWidth - Controls.inset * 2 - Controls.labelWidth)

                separator

                toggle("Channels", .channels)
                toggle("Send FX", .send)
                toggle("Live FX", .live)
                toggle("Global", .global)
                toggle("System", .system)

                separator

                Chooser(options: slots, index: slots.firstIndex(of: engine.store.name) ?? 0) {
                    engine.store.name = slots[$0]
                    engine.touchPanels()
                }
                .padding(.bottom, -Controls.gap)
                .frame(width: 150)

                if !stageMode {
                    PushButton(label: "Save", width: Controls.width(44)) {
                        engine.save()
                        slots = engine.slots()
                    }
                }

                PushButton(label: "Load", width: Controls.width(44)) { engine.load() }
                    .opacity(engine.locked ? Style.dimmedOpacity : 1)

                Text(engine.message)
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.label)
                    .lineLimit(1)
                    .padding(.horizontal, Controls.inset)

                if !stageMode {
                    separator
                    PushButton(label: "?", width: Controls.rowHeight) {
                        if let url = URL(string: "https://www.keijiro.tokyo/jacquard-doc/") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            .padding(.horizontal, Controls.inset)
            .frame(height: Controls.transportRowHeight)
        }
        .scrollIndicators(.hidden)
        .background(Style.panel.ignoresSafeArea(edges: .top))
        .onAppear { slots = engine.slots() }
    }

    private func toggle(_ label: String, _ kind: ContentView.PanelKind) -> some View {
        PushButton(label: label, width: Controls.width(62), active: shown.contains(kind)) {
            if shown.contains(kind) { shown.remove(kind) } else { shown.insert(kind) }
        }
    }

    private var separator: some View {
        Rectangle().fill(Style.panelLine).frame(width: 1, height: Controls.rowHeight - 2)
            .padding(.horizontal, 8)
    }
}
