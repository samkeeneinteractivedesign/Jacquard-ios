import SwiftUI

// The plane: the lattice, the rails, the chain and jump lines, the tiles, the cursor and
// the playheads, and what a hand does on it. Ported from Assets/Jacquard/UI/ScoreView.cs,
// ScrollArea.cs and TileElement.cs.
//
// A drag means whatever the cell under it holds: a tile or a lane head has something to
// carry, so a drag there carries it; free ground has nothing to carry, so a drag there
// moves the plane. Four points of travel separate a drag from a tap. A press sets the
// cursor, and a second press on the same cell inside the double click interval is a
// double click — copy, paste, or start and stop a lane.
//
// Layers, as the original has: what is drawn from the score is redrawn when the score
// changes, the cursor and what a drag would do over it, and the playheads every frame.

struct ScorePlaneView: View {
    let engine: JacquardEngine
    let editor: ScoreEditor

    static let dragThreshold: CGFloat = 4

    @State private var pressed = false
    @State private var grabbed: CellRef?
    @State private var dragging = false
    @State private var panning = false
    @State private var panStart = CGPoint.zero
    @State private var translation = CGSize.zero
    @State private var dropPoint = GridPoint(0, 0)
    @State private var dropCells: [GridPoint] = []
    @State private var lastPress: (GridPoint, Date)?
    @FocusState private var focused: Bool

    var body: some View {
        let size = Style.planeSize(columns: engine.planeColumns, rows: engine.planeRows)

        GeometryReader { geometry in
            let viewport = geometry.size

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    PlaneLayer(engine: engine, revision: engine.planeRevision)
                        .frame(width: size.width, height: size.height)

                    PlayheadLayer(engine: engine)
                        .frame(width: size.width, height: size.height)
                }
                .opacity(engine.locked ? Style.dimmedOpacity : 1)

                UpperLayer(engine: engine, editor: editor, grabbed: dragging ? grabbed : nil,
                           translation: translation, dropCells: dropCells,
                           revision: engine.planeRevision)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(x: -engine.pan.x, y: -engine.pan.y)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(gesture(size: size, viewport: viewport))
            .onChange(of: viewport) { clampPan(size, viewport) }
            .onChange(of: size) { clampPan(size, viewport) }
        }
        // A hardware keyboard: the arrows move the cursor, delete removes, return sounds
        // the note under the cursor, space plays.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { editor.handle(.left); return .handled }
        .onKeyPress(.rightArrow) { editor.handle(.right); return .handled }
        .onKeyPress(.upArrow) { editor.handle(.up); return .handled }
        .onKeyPress(.downArrow) { editor.handle(.down); return .handled }
        .onKeyPress(.delete) { editor.handle(.delete); return .handled }
        .onKeyPress(.return) { editor.handle(.enter); return .handled }
        .onKeyPress(.space) { engine.togglePlay(); return .handled }
    }

    // MARK: The hand

    private func gesture(size: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = planePoint(value.startLocation)

                if !pressed {
                    pressed = true
                    press(start)
                }

                translation = value.translation
                let distance = hypot(value.translation.width, value.translation.height)

                if let grabbed, !engine.locked {
                    if !dragging {
                        if distance < ScorePlaneView.dragThreshold { return }
                        dragging = true
                        dropPoint = GridPoint(-1, -1)
                    }
                    let point = Style.cellAt(planePoint(value.location))
                    if point != dropPoint {
                        dropPoint = point
                        resolveDrop(grabbed)
                    }
                    return
                }

                if !panning {
                    if distance < ScorePlaneView.dragThreshold { return }
                    panning = true
                    panStart = engine.pan
                }

                engine.pan = clamp(CGPoint(x: panStart.x - value.translation.width,
                                           y: panStart.y - value.translation.height), size, viewport)
            }
            .onEnded { value in
                // A quick tap can arrive as an end with no change before it.
                if !pressed { press(planePoint(value.startLocation)) }

                if dragging, let grabbed {
                    if grabbed.kind == .head, let lane = grabbed.lane {
                        editor.dropLane(lane, dropPoint)
                    } else {
                        editor.dropTiles(grabbed, dropPoint)
                    }
                }

                pressed = false
                grabbed = nil
                dragging = false
                panning = false
                translation = .zero
                dropCells = []
                focused = true
            }
    }

    // A press moves the cursor, counts toward a double click, and picks up what the
    // cell holds if it holds anything that can be carried.
    private func press(_ location: CGPoint) {
        guard !engine.locked else { return }

        let point = Style.cellAt(location)
        editor.setCursor(point)

        let now = Date()
        if let (last, time) = lastPress, last == point, now.timeIntervalSince(time) < Controls.doubleClick {
            lastPress = nil
            editor.doubleClick()
        } else {
            lastPress = (point, now)
        }

        let cell = engine.project.score.at(point)
        if cell.kind == .tile || cell.kind == .head { grabbed = cell }
    }

    // What dropping here would do: the cells a lane would land on, or the cells a run of
    // tiles would, or nothing when the ground will not have it.
    private func resolveDrop(_ grabbed: CellRef) {
        let score = engine.project.score
        dropCells = []

        if grabbed.kind == .head, let lane = grabbed.lane {
            guard score.canMoveLane(lane, head: dropPoint) else { return }
            let dx = dropPoint.x - lane.headX
            let dy = dropPoint.y - lane.y
            dropCells = lane.occupiedCells().map { $0.offset(dx, dy) }
        } else {
            let move = score.planMove(grabbed, dropPoint)
            guard let lane = move.lane else { return }
            dropCells = (0..<move.count).map { lane.cellPoint(move.step, move.depth + $0) }
        }
    }

    private func planePoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x + engine.pan.x, y: location.y + engine.pan.y)
    }

    private func clamp(_ pan: CGPoint, _ size: CGSize, _ viewport: CGSize) -> CGPoint {
        CGPoint(x: min(max(pan.x, 0), max(0, size.width - viewport.width)),
                y: min(max(pan.y, 0), max(0, size.height - viewport.height)))
    }

    private func clampPan(_ size: CGSize, _ viewport: CGSize) {
        let clamped = clamp(engine.pan, size, viewport)
        if clamped != engine.pan { engine.pan = clamped }
    }
}

// MARK: - Over the score

// The cursor, what a drop would land on, the cells a copy just took, and the tiles being
// carried, drawn where the hand has them.
private struct UpperLayer: View {
    let engine: JacquardEngine
    let editor: ScoreEditor
    let grabbed: CellRef?
    let translation: CGSize
    let dropCells: [GridPoint]
    let revision: Int

    var body: some View {
        Canvas { context, _ in
            let rect = Style.cellRect(editor.cursor)
            context.stroke(Path(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: Style.radius + 2),
                           with: .color(Style.cursor), lineWidth: 1)

            if !dropCells.isEmpty {
                var path = Path()
                for point in dropCells { path.addRoundedRect(in: Style.cellRect(point), cornerSize: CGSize(width: Style.radius, height: Style.radius)) }
                context.fill(path, with: .color(Style.cursor.opacity(0.14)))
                context.stroke(path, with: .color(Style.cursor.opacity(0.7)), lineWidth: 1)
            }

            if !editor.flashCells.isEmpty {
                var path = Path()
                for point in editor.flashCells { path.addRoundedRect(in: Style.cellRect(point), cornerSize: CGSize(width: Style.radius, height: Style.radius)) }
                context.fill(path, with: .color(Style.cursor.opacity(0.3)))
            }

            if let grabbed { drawGhosts(&context, grabbed) }
        }
        .allowsHitTesting(false)
    }

    private func drawGhosts(_ context: inout GraphicsContext, _ grabbed: CellRef) {
        guard let lane = grabbed.lane else { return }
        var ghost = context
        ghost.opacity = 0.85
        ghost.translateBy(x: translation.width, y: translation.height)

        if grabbed.kind == .head {
            TilePainter.draw(&ghost, lane.head, lane.headPoint, off: false)
            TilePainter.draw(&ghost, Score.terminator, lane.termPoint, off: false)
            for (i, step) in lane.steps.enumerated() {
                for (d, tile) in step.tiles.enumerated() {
                    TilePainter.draw(&ghost, tile, lane.cellPoint(i, d), off: false)
                }
            }
            return
        }

        let tiles = lane.steps[grabbed.step].tiles
        for depth in grabbed.depth..<tiles.count {
            TilePainter.draw(&ghost, tiles[depth], lane.cellPoint(grabbed.step, depth), off: false)
        }
    }
}

// MARK: - The score

private struct PlaneLayer: View {
    let engine: JacquardEngine
    let revision: Int

    var body: some View {
        Canvas { context, _ in
            let score = engine.project.score
            let columns = engine.planeColumns
            let rows = engine.planeRows

            drawLattice(&context, score, columns, rows)
            drawRails(&context, score)
            drawChains(&context, score)
            drawLinks(&context, score)
            drawMarkers(&context, score)
            drawTiles(&context, score)
        }
    }

    // A dot on every cell nothing claims.
    private func drawLattice(_ context: inout GraphicsContext, _ score: Score, _ columns: Int, _ rows: Int) {
        var path = Path()
        for y in 0..<rows {
            for x in 0..<columns {
                let point = GridPoint(x, y)
                if score.at(point).kind != .empty { continue }
                let c = Style.cellCenter(point)
                path.addRect(CGRect(x: c.x - Style.latticeDot / 2, y: c.y - Style.latticeDot / 2,
                                    width: Style.latticeDot, height: Style.latticeDot))
            }
        }
        context.fill(path, with: .color(Style.dot))
    }

    // The dotted time axis from head to terminator.
    private func drawRails(_ context: inout GraphicsContext, _ score: Score) {
        var path = Path()
        for lane in score.lanes {
            let from = Style.cellCenter(lane.headPoint).x
            let to = Style.cellCenter(lane.termPoint).x
            let y = Style.cellCenter(lane.headPoint).y.rounded(.down) - Style.railDot / 2
            var x = from
            while x < to {
                path.addRect(CGRect(x: x, y: y, width: Style.railDot, height: Style.railDot))
                x += Style.railStep
            }
        }
        context.fill(path, with: .color(Style.noteLine.opacity(Style.railOpacity)))
    }

    // The 1px line joining a stack, drawn only between cells of the same stack.
    private func drawChains(_ context: inout GraphicsContext, _ score: Score) {
        var path = Path()
        for lane in score.lanes {
            for (i, step) in lane.steps.enumerated() where step.depth > 1 {
                for d in 1..<step.depth {
                    let origin = Style.cellOrigin(lane.cellPoint(i, d))
                    let x = origin.x + (Style.cellWidth / 2).rounded(.down) + 0.5
                    path.move(to: CGPoint(x: x, y: origin.y - Style.gap - 1))
                    path.addLine(to: CGPoint(x: x, y: origin.y + 1))
                }
            }
        }
        context.stroke(path, with: .color(Style.noteLine), lineWidth: 1)
    }

    // The grey path of a jump, offset from the cell centres so it reads as a layer of
    // its own.
    private func drawLinks(_ context: inout GraphicsContext, _ score: Score) {
        for lane in score.lanes {
            guard let source = lane.jumpSource, let from = score.locate(source) else { continue }

            let a = Style.cellCenter(from)
            let b = Style.cellCenter(lane.headPoint)
            let midY = Style.cellCenter(lane.headPoint.offset(0, -1)).y + Style.linkOffset

            let points = [CGPoint(x: a.x + Style.linkOffset, y: a.y),
                          CGPoint(x: a.x + Style.linkOffset, y: midY),
                          CGPoint(x: b.x + Style.linkOffset, y: midY),
                          CGPoint(x: b.x + Style.linkOffset, y: b.y)]

            context.stroke(roundedPath(points, Style.linkRadius), with: .color(Style.link),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }

    // A polyline with its corners rounded, the radius shrinking where a leg is short.
    private func roundedPath(_ points: [CGPoint], _ radius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        for i in 1..<points.count {
            let p = points[i]
            if i == points.count - 1 {
                path.addLine(to: p)
                break
            }
            let prev = points[i - 1], next = points[i + 1]
            let lenIn = hypot(p.x - prev.x, p.y - prev.y)
            let lenOut = hypot(next.x - p.x, next.y - p.y)
            let r = min(radius, lenIn / 2, lenOut / 2)
            path.addArc(tangent1End: p, tangent2End: next, radius: r)
        }
        return path
    }

    // The pass-through marker on an empty step of the rail.
    private func drawMarkers(_ context: inout GraphicsContext, _ score: Score) {
        var path = Path()
        for lane in score.lanes {
            for (i, step) in lane.steps.enumerated() where step.isEmpty {
                let c = Style.cellOrigin(lane.cellPoint(i, 0))
                let o = CGPoint(x: c.x + ((Style.cellWidth - 7) / 2).rounded(.down),
                                y: c.y + ((Style.cellHeight - 9) / 2).rounded(.down))
                path.move(to: o)
                path.addLine(to: CGPoint(x: o.x + 7, y: o.y + 4.5))
                path.addLine(to: CGPoint(x: o.x, y: o.y + 9))
                path.closeSubpath()
            }
        }
        context.fill(path, with: .color(Style.marker))
    }

    private func drawTiles(_ context: inout GraphicsContext, _ score: Score) {
        let master = score.masterLane

        for lane in score.lanes {
            let off = (lane.channel.map { !$0.enabled } ?? false) && lane !== master
            TilePainter.draw(&context, lane.head, lane.headPoint, off: off)
            TilePainter.draw(&context, Score.terminator, lane.termPoint, off: false)

            for (i, step) in lane.steps.enumerated() {
                for (d, tile) in step.tiles.enumerated() {
                    TilePainter.draw(&context, tile, lane.cellPoint(i, d), off: false)
                }
            }
        }
    }
}

// A tile on its cell: notes outlined on the ground, flow tiles filled in white with dark
// ink, locks and gates on the grey control ground. Ported from TileElement.cs.
enum TilePainter {
    // Notes are outlined on the ground; flow tiles are filled in white with dark ink;
    // locks and gates sit on the grey control ground.
    static func draw(_ context: inout GraphicsContext, _ tile: Tile, _ point: GridPoint, off: Bool) {
        let rect = Style.cellRect(point)
        let shape = Path(roundedRect: rect, cornerRadius: Style.radius)

        let inverted = tile is FlowTile && !off
        let outlined = tile is NoteTile
        let ink = inverted ? Style.background : Style.noteText

        let ground = outlined ? Style.background : inverted ? Style.noteLine : Style.controlBackground
        context.fill(shape, with: .color(ground))

        if outlined {
            context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: Style.radius - 0.5),
                           with: .color(Style.noteLine), lineWidth: 1)
        }

        if let note = tile as? NoteTile {
            drawNoteLabel(&context, note, rect)
        } else if let channel = tile as? ChannelTile {
            let text = Text("CH\(channel.channel)")
                .font(Style.font(Style.controlSize, bold: inverted))
                .foregroundColor(ink)
            context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
        }

        if TileIcons.hasIcon(tile) {
            TileIcons.draw(&context, tile, at: rect.origin, color: ink)
        }
    }

    // The letter, a raised sharp only when there is one, the octave, and the length
    // underneath when it is not one step.
    static func drawNoteLabel(_ context: inout GraphicsContext, _ note: NoteTile, _ rect: CGRect) {
        let name = Pitch.toClassName(note.note)
        let sharp = name.count > 1
        let letter = String(name.prefix(1))
        let octave = String(Pitch.toOctave(note.note))

        let font = Style.font(Style.noteSize)
        let letterText = context.resolve(Text(letter).font(font).foregroundColor(Style.noteText))
        let octaveText = context.resolve(Text(octave).font(font).foregroundColor(Style.noteText))

        let letterSize = letterText.measure(in: rect.size)
        let octaveSize = octaveText.measure(in: rect.size)
        let gutter = sharp ? Style.accidentalGutter : 0
        let width = letterSize.width + gutter + octaveSize.width

        var centerY = rect.midY
        var lengthText: GraphicsContext.ResolvedText?
        var lengthHeight: CGFloat = 0

        if !note.hasDefaultLength {
            let resolved = context.resolve(Text(Format.short(note.length, places: 3))
                .font(Style.font(Style.lengthSize))
                .foregroundColor(Style.noteText.opacity(0.7)))
            lengthHeight = resolved.measure(in: rect.size).height - 2
            lengthText = resolved
            centerY -= lengthHeight / 2
        }

        var x = rect.midX - width / 2
        context.draw(letterText, at: CGPoint(x: x, y: centerY), anchor: .leading)
        x += letterSize.width

        if sharp {
            let top = centerY - Style.noteSize / 2
            var path = Path()
            let o = CGPoint(x: x, y: top)
            func seg(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                path.move(to: CGPoint(x: o.x + x1, y: o.y + y1))
                path.addLine(to: CGPoint(x: o.x + x2, y: o.y + y2))
            }
            let (t, b): (CGFloat, CGFloat) = (1, 8.5)
            seg(1.5, t + 0.6, 1.5, b)
            seg(3.5, t, 3.5, b - 0.6)
            seg(0.5, 4.2, 4.5, 3.4)
            seg(0.5, 6.4, 4.5, 5.6)
            context.stroke(path, with: .color(Style.noteText), lineWidth: 1)
            x += gutter
        }

        context.draw(octaveText, at: CGPoint(x: x, y: centerY), anchor: .leading)

        if let lengthText {
            context.draw(lengthText, at: CGPoint(x: rect.midX, y: centerY + letterSize.height / 2 + lengthHeight / 2 - 1))
        }
    }
}

// MARK: - The playheads

// A 3pt bar in the gap to the left of the step being heard, as tall as its stack.
private struct PlayheadLayer: View {
    let engine: JacquardEngine

    var body: some View {
        TimelineView(.animation(paused: !engine.isPlaying)) { timeline in
            Canvas { context, _ in
                // Read so the canvas is redrawn on every tick of the timeline.
                _ = timeline.date
                var path = Path()
                for (lane, step) in engine.playheads() {
                    guard step >= 0 && step < lane.steps.count else { continue }
                    let origin = Style.cellOrigin(lane.cellPoint(step, 0))
                    let depth = max(1, lane.steps[step].depth)
                    let height = CGFloat(depth) * Style.strideY - Style.gap
                    path.addRect(CGRect(x: origin.x - Style.gap + 1, y: origin.y, width: 3, height: height))
                }
                context.fill(path, with: .color(Style.playhead))
            }
        }
    }
}
