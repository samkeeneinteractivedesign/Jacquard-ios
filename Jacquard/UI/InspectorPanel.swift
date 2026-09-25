import SwiftUI

// The Tile panel: one panel shows what the cursor is on, and nothing is toggled. Ported
// from Assets/Jacquard/UI/InspectorPanel.cs.
//
// Everything the cell decides is a group on it — the tile's rows, the lane a head
// carries, the sound of the channel a CHAN names, the parameters a lock takes hold of. A
// cell that will take a tile offers the tiles; bare ground offers a lane. The header is
// the subject, not the panel's name.

struct InspectorPanel: View {
    let engine: JacquardEngine
    let editor: ScoreEditor

    var body: some View {
        let _ = engine.panelRevision
        let cell = editor.cell
        let tile = cell.tile

        Panel(title: InspectorPanel.title(editor.canPlace ? nil : tile)) {
            if editor.canPlace {
                palette
            } else if tile == nil {
                PushButton(label: "New lane", width: Controls.width(66)) { editor.newChannelLane() }
                    .padding(.bottom, Controls.gap)
            } else if let tile {
                tileRows(tile)

                if cell.kind == .head, let lane = cell.lane {
                    CountStepper(caption: "Lane steps", value: lane.steps.count) { editor.resizeLane($0) }
                }

                if let channel = tile as? ChannelTile {
                    SoundGroup(engine: engine, editor: editor, channel: channel.channel)
                }

                deleteRow(head: cell.kind == .head)
            }
        }
        .opacity(engine.locked ? Style.dimmedOpacity : 1)
        .allowsHitTesting(!engine.locked)
    }

    // MARK: Header

    static func title(_ tile: Tile?) -> String {
        guard let tile else { return "Empty Cell" }
        return name(tile) + " Tile"
    }

    static func name(_ tile: Tile) -> String {
        switch tile {
        case is NoteTile: return "Note"
        case is AbsoluteParamTile: return "Absolute Lock"
        case is RelativeParamTile: return "Relative Lock"
        case is CycleGateTile: return "Cycle Gate"
        case is ProbGateTile: return "Chance Gate"
        case is ChannelTile: return "Channel Start"
        case is TerminatorTile: return "Lane End"
        case is JumpTile: return "Jump"
        case is JumpDestTile: return "Jump Target"
        default: return "Unknown"
        }
    }

    // MARK: The palette

    static let palette: [(String, TileKind)] = [
        ("Note", .note), ("Jump", .jump),
        ("Absolute Lock", .absoluteLock), ("Relative Lock", .relativeLock),
        ("Cycle Gate", .cycleGate), ("Chance Gate", .chanceGate)]

    private var palette: some View {
        let width = Controls.width(82)
        return LazyVGrid(columns: [GridItem(.fixed(width), spacing: Controls.gap, alignment: .leading),
                                   GridItem(.fixed(width), spacing: Controls.gap, alignment: .leading)],
                         alignment: .leading, spacing: Controls.gap) {
            ForEach(InspectorPanel.palette, id: \.0) { label, kind in
                PushButton(label: label, width: width) { editor.put(kind) }
            }
        }
        .padding(.bottom, Controls.gap)
    }

    private func deleteRow(head: Bool) -> some View {
        PushButton(label: head ? "Delete lane" : "Delete",
                   width: Controls.width(head ? 74 : 54)) { editor.delete() }
            .padding(.top, Controls.groupGap - Controls.gap)
            .padding(.bottom, Controls.gap)
    }

    // MARK: A tile's own rows

    @ViewBuilder
    private func tileRows(_ tile: Tile) -> some View {
        switch tile {
        case let param as ParamTile:
            LockGroup(engine: engine, editor: editor, tile: param)
        case let note as NoteTile:
            noteRows(note)
        case let cycle as CycleGateTile:
            cycleRows(cycle)
        case let prob as ProbGateTile:
            BarRow(caption: "Chance", range: InspectorPanel.chanceRange, revision: engine.panelRevision,
                   get: { prob.percent }, set: { prob.percent = $0; editor.commit() })
        case let channel as ChannelTile:
            channelRows(channel)
        default:
            EmptyView()
        }
    }

    // The letter on a keyboard and the register on a bar, so either moves without
    // disturbing the other.
    @ViewBuilder
    private func noteRows(_ note: NoteTile) -> some View {
        Keys(lit: { $0 == Pitch.toClass(note.note) }) { degree in
            setPitch(note, Pitch.toOctave(note.note), degree)
            editor.preview(note.note)
        }
        .padding(.top, Controls.groupGap - Controls.gap)
        .padding(.bottom, Controls.groupGap - Controls.gap)

        BarRow(caption: "Octave", range: InspectorPanel.octaveRange, revision: engine.panelRevision,
               get: { Float(Pitch.toOctave(note.note)) },
               set: { setPitch(note, Int($0.rounded()), Pitch.toClass(note.note)) },
               settled: { editor.preview(note.note) })

        BarRow(caption: "Length", range: InspectorPanel.lengthRange, revision: engine.panelRevision,
               get: { note.length },
               set: {
                   note.length = min(max($0, 0.25), 64)
                   editor.rememberNote(note)
                   editor.commit()
               })
    }

    private func setPitch(_ note: NoteTile, _ octave: Int, _ pitchClass: Int) {
        note.note = min(max(Pitch.fromParts(octave: octave, pitchClass: pitchClass), Pitch.lowest),
                        Pitch.highest)
        editor.rememberNote(note)
        editor.commit()
    }

    @ViewBuilder
    private func cycleRows(_ cycle: CycleGateTile) -> some View {
        BarRow(caption: "Period", range: InspectorPanel.periodRange, revision: engine.panelRevision,
               get: { Float(cycle.period) },
               set: { cycle.period = Int($0.rounded()); editor.commit() })

        Heading(text: "Fires on", follows: true)

        // A switch per lap, eight to a row: the same arrangement the cell draws, larger.
        let size = Controls.switchSize(InspectorPanel.lapsPerRow)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: Controls.gap),
                                 count: InspectorPanel.lapsPerRow),
                  alignment: .leading, spacing: Controls.gap) {
            ForEach(1...cycle.period, id: \.self) { lap in
                SquareSwitch(size: size, on: cycle.fires(lap)) {
                    cycle.setFires(lap, !cycle.fires(lap))
                    editor.commit()
                }
            }
        }
        .padding(.bottom, Controls.gap)
    }

    @ViewBuilder
    private func channelRows(_ channel: ChannelTile) -> some View {
        ToggleRow(caption: "Play", on: channel.enabled) {
            channel.enabled.toggle()
            editor.commit()
        }

        Chooser(caption: "Channel", options: (1...PatchBank.channels).map(String.init),
                index: channel.channel - 1) {
            channel.channel = $0 + 1
            editor.commit()
        }

        Chooser(caption: "Step length", options: ChannelTile.divisions.map { "1/\($0)" },
                index: ChannelTile.divisions.firstIndex(of: channel.division) ?? 0) {
            channel.division = ChannelTile.divisions[$0]
            editor.commit()
        }
    }

    static let octaveRange = BarRange.integer(0, 8)
    static let lengthRange = BarRange(0.25, 8, snap: 0.05, unit: "steps")
    static let chanceRange = BarRange(0, 100, snap: 1, unit: "%", digits: 0)
    static let periodRange = BarRange.integer(Float(CycleGateTile.minPeriod), Float(CycleGateTile.maxPeriod))
    static let lapsPerRow = 8
}

// The sound of the channel a CHAN names: every field of its patch, grouped as the list of
// targets is. Double tapping a name puts the row back where a fresh patch holds it.
struct SoundGroup: View {
    let engine: JacquardEngine
    let editor: ScoreEditor
    let channel: Int

    var body: some View {
        let _ = engine.panelRevision
        ForEach(0..<ParamTargets.count, id: \.self) { target in
            if let group = ParamTargets.groupAt(target) {
                Heading(text: group, follows: true)
            }
            BarRow(caption: ParamTargets.name(target), range: .of(target),
                   revision: engine.panelRevision,
                   get: { ParamTargets.get(engine.project.patches[channel], target) },
                   set: { set(target, $0) },
                   settled: { editor.previewRemembered(channel) },
                   reset: { set(target, ParamTargets.get(.default, target)) })
        }
    }

    private func set(_ target: Int, _ value: Float) {
        var patch = engine.project.patches[channel]
        ParamTargets.set(&patch, target, value)
        engine.project.patches[channel] = patch
        editor.touch()
    }
}

// A lock's rows: every target, the ones it has not taken hold of shown faintly with what
// the channel would be without it. Moving a bar takes hold; double tapping the name lets
// go (or takes hold at the value shown).
struct LockGroup: View {
    let engine: JacquardEngine
    let editor: ScoreEditor
    let tile: ParamTile

    var body: some View {
        let _ = engine.panelRevision
        let absolute = tile is AbsoluteParamTile
        let channel = editor.score.channelOf(editor.selectedLane)

        ForEach(0..<ParamTargets.count, id: \.self) { target in
            if let group = ParamTargets.groupAt(target) {
                Heading(text: group, follows: target > 0)
            }

            let engaged = tile.isEngaged(target)
            let released = absolute ? ParamTargets.get(engine.project.patches[channel], target) : 0

            HStack(spacing: 0) {
                ActionCaption(text: ParamTargets.name(target), bright: engaged) {
                    if engaged { tile.release(target) } else { tile.engage(target, released) }
                    editor.commit()
                }
                ValueBar(range: absolute ? .of(target) : .relative(target),
                         get: { tile.isEngaged(target) ? tile[target] : released },
                         set: { tile.engage(target, $0); editor.commit() },
                         revision: engine.panelRevision)
            }
            .opacity(engaged ? 1 : Style.dimmedOpacity)
            .padding(.bottom, Controls.gap)
        }
    }
}
