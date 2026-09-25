import SwiftUI

// The plane: the lattice, the rails, the chain and jump lines, the tiles, and the
// playheads over them. Ported from the drawing half of Assets/Jacquard/UI/ScoreView.cs
// and TileElement.cs.
//
// Two layers, as the original has: what is drawn from the score is redrawn when the
// score changes, and the playheads are redrawn every frame on top of it.

struct ScorePlaneView: View {
    let engine: JacquardEngine

    var body: some View {
        let size = Style.planeSize(columns: engine.planeColumns, rows: engine.planeRows)

        ZStack(alignment: .topLeading) {
            PlaneLayer(engine: engine, revision: engine.revision)
                .frame(width: size.width, height: size.height)

            PlayheadLayer(engine: engine)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .opacity(engine.locked ? Style.dimmedOpacity : 1)
        .contentShape(Rectangle())
        .onTapGesture { location in
            guard !engine.locked else { return }
            let cell = engine.project.score.at(Style.cellAt(location))
            engine.selectedLane = cell.lane
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
            drawSelection(&context, score)
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
            drawTile(&context, lane.head, lane.headPoint, off: off)
            drawTile(&context, Score.terminator, lane.termPoint, off: false)

            for (i, step) in lane.steps.enumerated() {
                for (d, tile) in step.tiles.enumerated() {
                    drawTile(&context, tile, lane.cellPoint(i, d), off: false)
                }
            }
        }
    }

    // Notes are outlined on the ground; flow tiles are filled in white with dark ink;
    // locks and gates sit on the grey control ground.
    private func drawTile(_ context: inout GraphicsContext, _ tile: Tile, _ point: GridPoint, off: Bool) {
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
    private func drawNoteLabel(_ context: inout GraphicsContext, _ note: NoteTile, _ rect: CGRect) {
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

    // The lane under the hand, whose channel the visualizer follows.
    private func drawSelection(_ context: inout GraphicsContext, _ score: Score) {
        guard let lane = engine.selectedLane, score.lanes.contains(where: { $0 === lane }) else { return }
        let rect = Style.cellRect(lane.headPoint)
        context.stroke(Path(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: Style.radius + 2),
                       with: .color(Style.cursor), lineWidth: 1)
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
