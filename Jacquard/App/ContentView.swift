import SwiftUI

// The screen. Ported from the layout half of Assets/Jacquard/UI/JacquardUI.cs.
//
// The visualizer behind everything; the plane over it; the transport row along the top
// on a ground of its own; and the panels — standing on the plane in columns on a tablet,
// as upstream, and sharing a dock under it on a phone. Everything the transport row
// switches starts off.

struct ContentView: View {
    @State private var engine = JacquardEngine()
    @State private var stageMode = StageMode.on
    @State private var raised: [PanelKind] = []
    @Environment(\.scenePhase) private var scenePhase

    enum PanelKind: String { case channels, send, live, global, system }

    // Below this width two columns of panels cannot stand side by side without covering
    // the plane, so the phone layout takes over.
    static let dockBelow: CGFloat = 600

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < ContentView.dockBelow

            ZStack {
                if engine.visualizerOn {
                    VisualizerView(engine: engine)
                        .ignoresSafeArea()
                } else {
                    Style.background.ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    TransportRow(engine: engine, stageMode: stageMode,
                                 isShown: { raised.contains($0) }, toggle: toggle)

                    if compact {
                        phoneBody(height: geometry.size.height)
                    } else {
                        tabletBody
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
                    if let kind = PanelKind(rawValue: String(name)) { raised.append(kind) }
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

    private func toggle(_ kind: PanelKind) {
        if let index = raised.firstIndex(of: kind) { raised.remove(at: index) }
        else { raised.append(kind) }
    }

    @ViewBuilder
    private func panel(_ kind: PanelKind) -> some View {
        let editor = engine.editor!
        switch kind {
        case .channels: ChannelsPanel(engine: engine, editor: editor, stageMode: stageMode)
        case .send: SendPanel(engine: engine, editor: editor)
        case .global: GlobalPanel(engine: engine, editor: editor)
        case .system: SystemPanel(engine: engine, editor: editor, stageMode: $stageMode)
        case .live: LivePanel(engine: engine)
        }
    }

    // MARK: Tablet

    // Each column is laid over the plane without taking any room from it or from the
    // others: the Tile panel in the right column outermost with Send FX inside it,
    // Channels on the left, Global and System in the centre, Live FX across the bottom.
    private var tabletBody: some View {
        let editor = engine.editor!

        return ZStack(alignment: .top) {
            ScorePlaneView(engine: engine, editor: editor)

            Color.clear
                .overlay(alignment: .topTrailing) {
                    HStack(alignment: .top, spacing: Controls.panelGap) {
                        PanelColumn {
                            if raised.contains(.send) { panel(.send) }
                        }
                        PanelColumn {
                            InspectorPanel(engine: engine, editor: editor)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    PanelColumn {
                        if raised.contains(.global) { panel(.global) }
                        if raised.contains(.system) { panel(.system) }
                    }
                }
                .overlay(alignment: .topLeading) {
                    PanelColumn {
                        if raised.contains(.channels) { panel(.channels) }
                    }
                }
                .padding(Controls.panelGap)

            if raised.contains(.live) {
                VStack {
                    Spacer()
                    ScrollView(.horizontal) { panel(.live) }
                        .scrollIndicators(.hidden)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Controls.panelGap)
                        .padding(.bottom, Controls.panelGap)
                }
            }
        }
    }

    // MARK: Phone

    // A phone has room for the plane or for a column, not both side by side, so the
    // panels share a dock along the bottom and the plane keeps everything above it. The
    // dock shows one panel at a time: the one a switch raised last, or, with none raised,
    // the Tile panel, which is what follows the cursor. Letting a switch go hands the dock
    // back to whatever was raised before it. Live FX stands over the dock rather than in
    // it, since it is played while the plane is watched and not instead of the Tile panel.
    private func phoneBody(height: CGFloat) -> some View {
        let editor = engine.editor!
        let docked = raised.last { $0 != .live }

        return VStack(spacing: 0) {
            ScorePlaneView(engine: engine, editor: editor)

            if raised.contains(.live) {
                ScrollView(.horizontal) { panel(.live) }
                    .scrollIndicators(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Style.panel)
                    .overlay(alignment: .top) { Rectangle().fill(Style.panelLine).frame(height: 1) }
            }

            ScrollView(.vertical) {
                Group {
                    if let docked { panel(docked) } else { InspectorPanel(engine: engine, editor: editor) }
                }
                .environment(\.panelWidth, nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(height: height * ContentView.dockShare)
            .background(Style.panel.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Style.panelLine).frame(height: 1) }
        }
    }

    // How much of a phone's height the dock takes.
    static let dockShare: CGFloat = 0.4
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
    let isShown: (ContentView.PanelKind) -> Bool
    let toggle: (ContentView.PanelKind) -> Void

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
        PushButton(label: label, width: Controls.width(62), active: isShown(kind)) { toggle(kind) }
    }

    private var separator: some View {
        Rectangle().fill(Style.panelLine).frame(width: 1, height: Controls.rowHeight - 2)
            .padding(.horizontal, 8)
    }
}
