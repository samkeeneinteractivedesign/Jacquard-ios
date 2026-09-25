import SwiftUI

// The icons drawn on a cell. Ported from Assets/Jacquard/UI/TileIcons.cs.
//
// Drawn in a 15x15 box at a stroke width of 1 with coordinates on half-integers, so the
// centre of a stroke lands on a pixel boundary.

enum TileIcons {
    static let size: CGFloat = 15
    static let top: CGFloat = 1.5
    static let bottom: CGFloat = 13.5

    static func hasIcon(_ tile: Tile) -> Bool {
        tile is ParamTile || tile is GateTile || tile is TerminatorTile ||
        tile is JumpTile || tile is JumpDestTile
    }

    // Draws the icon for a tile into a cell whose top left is at `cell`.
    static func draw(_ context: inout GraphicsContext, _ tile: Tile, at cell: CGPoint, color: Color) {
        let o = CGPoint(x: cell.x + ((Style.cellWidth - size) / 2).rounded(.down),
                        y: cell.y + ((Style.cellHeight - size) / 2).rounded(.down))
        let stroke = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)

        switch tile {
        case is AbsoluteParamTile:
            var path = Path()
            fader(&path, o, 7.5, 6)
            context.stroke(path, with: .color(color), style: stroke)

        case is RelativeParamTile:
            var path = Path()
            fader(&path, o, 4.5, 6)
            upDown(&path, o, 11.5)
            context.stroke(path, with: .color(color), style: stroke)

        case let cycle as CycleGateTile:
            drawCycle(&context, cycle, cell, color, stroke)

        case let prob as ProbGateTile:
            drawProb(&context, prob.percent, cell, color, stroke)

        case is TerminatorTile:
            let (y0, y1, xr): (CGFloat, CGFloat, CGFloat) = (2.5, 10.5, 9.5)
            var path = Path()
            line(&path, o, 2.5, y0, xr, y0)
            path.addArc(center: p(o, xr, (y0 + y1) / 2), radius: (y1 - y0) / 2,
                        startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            line(&path, o, xr, y1, 4.4, y1)
            context.stroke(path, with: .color(color), style: stroke)
            arrowHead(&context, o, 2.0, 5.0, y1, 2.4, color)

        case is JumpTile:
            let (y0, y1): (CGFloat, CGFloat) = (3.5, 10.5)
            let (x0, x1, x2, x3): (CGFloat, CGFloat, CGFloat, CGFloat) = (2.5, 10.5, 4.5, 10.4)
            let r: CGFloat = 1.7
            let length = sqrt((x2 - x1) * (x2 - x1) + (y1 - y0) * (y1 - y0))
            let ux = (x2 - x1) / length * r
            let uy = (y1 - y0) / length * r
            var path = Path()
            path.move(to: p(o, x0, y0))
            path.addLine(to: p(o, x1 - r, y0))
            path.addQuadCurve(to: p(o, x1 + ux, y0 + uy), control: p(o, x1, y0))
            path.addLine(to: p(o, x2 - ux, y1 - uy))
            path.addQuadCurve(to: p(o, x2 + r, y1), control: p(o, x2, y1))
            path.addLine(to: p(o, x3, y1))
            context.stroke(path, with: .color(color), style: stroke)
            arrowHead(&context, o, x3 + 3, x3, y1, 2.2, color)

        case is JumpDestTile:
            let (cy, x): (CGFloat, CGFloat) = (7.5, 2.5)
            var path = Path()
            line(&path, o, x, 3.5, x, 11.5)
            line(&path, o, x, cy, 10.4, cy)
            context.stroke(path, with: .color(color), style: stroke)
            arrowHead(&context, o, 13.4, 10.4, cy, 2.2, color)

        default:
            break
        }
    }

    // MARK: Shapes

    private static func fader(_ path: inout Path, _ o: CGPoint, _ cx: CGFloat, _ cy: CGFloat) {
        let (kw, kh): (CGFloat, CGFloat) = (6, 3)
        let t = cy - kh / 2
        let b = cy + kh / 2
        line(&path, o, cx, top, cx, t)
        line(&path, o, cx, b, cx, bottom)
        box(&path, o, cx - kw / 2, t, kw, kh)
    }

    private static func upDown(_ path: inout Path, _ o: CGPoint, _ cx: CGFloat) {
        let (hw, hh): (CGFloat, CGFloat) = (2, 2.8)
        line(&path, o, cx, top, cx, bottom)
        chevron(&path, o, cx, top, top + hh, hw)
        chevron(&path, o, cx, bottom, bottom - hh, hw)
    }

    // A rectangle per lap, filled where it fires, at most four to a line, and past eight
    // six with an ellipsis.
    private static let columns = 4, shown = 8, elided = 6
    private static let margin: CGFloat = 5
    private static let space: CGFloat = 2
    private static let dotPitch: CGFloat = 3
    private static let dotSpan: CGFloat = dotPitch * 2 + 1

    private static func drawCycle(_ context: inout GraphicsContext, _ cycle: CycleGateTile,
                                  _ cell: CGPoint, _ color: Color, _ stroke: StrokeStyle) {
        let period = cycle.period
        let isElided = period > shown
        let count = isElided ? elided : period
        let cols = min(count, columns)
        let rows = (count + columns - 1) / columns
        let span = Style.cellWidth - margin * 2
        let w = min(5, ((span + space) / CGFloat(cols)).rounded(.down) - space)
        let h: CGFloat = rows > 1 ? 6 : 8
        let width = CGFloat(cols) * (w + space) - space + 1
        let height = CGFloat(rows) * (h + space) - space + 1
        let o = CGPoint(x: cell.x + ((Style.cellWidth - width) / 2).rounded(.down),
                        y: cell.y + ((Style.cellHeight - height) / 2).rounded(.down))

        var filled = Path()
        var hollow = Path()

        for i in 0..<count {
            let x = CGFloat(i % columns) * (w + space) + 0.5
            let y = CGFloat(i / columns) * (h + space) + 0.5
            if cycle.fires(i + 1) { box(&filled, o, x, y, w, h) } else { box(&hollow, o, x, y, w, h) }
        }

        context.fill(filled, with: .color(color))
        context.stroke(hollow, with: .color(color), style: stroke)

        guard isElided else { return }

        let last = count - columns
        let free = CGFloat(columns - last) * (w + space) - space + 1
        var dots = Path()
        for i in 0..<3 {
            box(&dots, o,
                CGFloat(last) * (w + space) + ((free - dotSpan) / 2).rounded(.down) + CGFloat(i) * dotPitch,
                CGFloat(rows - 1) * (h + space) + (h / 2).rounded(.down), 1, 1)
        }
        context.fill(dots, with: .color(color))
    }

    // A pie chart of the percentage.
    private static func drawProb(_ context: inout GraphicsContext, _ percent: Float,
                                 _ cell: CGPoint, _ color: Color, _ stroke: StrokeStyle) {
        let (c, r): (CGFloat, CGFloat) = (5.5, 5)
        let o = CGPoint(x: cell.x + ((Style.cellWidth - 11) / 2).rounded(.down),
                        y: cell.y + ((Style.cellHeight - 11) / 2).rounded(.down))
        let center = CGPoint(x: o.x + c, y: o.y + c)

        if percent >= 100 {
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                width: r * 2, height: r * 2)),
                         with: .color(color))
        } else if percent > 0 {
            var pie = Path()
            pie.move(to: center)
            pie.addLine(to: CGPoint(x: center.x, y: center.y - r))
            pie.addArc(center: center, radius: r, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + Double(percent) / 100 * 360), clockwise: false)
            pie.closeSubpath()
            context.fill(pie, with: .color(color))
        }

        context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(color), style: stroke)
    }

    // MARK: Primitives

    private static func p(_ o: CGPoint, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: o.x + x, y: o.y + y)
    }

    private static func line(_ path: inout Path, _ o: CGPoint, _ x1: CGFloat, _ y1: CGFloat,
                             _ x2: CGFloat, _ y2: CGFloat) {
        path.move(to: p(o, x1, y1))
        path.addLine(to: p(o, x2, y2))
    }

    private static func box(_ path: inout Path, _ o: CGPoint, _ x: CGFloat, _ y: CGFloat,
                            _ w: CGFloat, _ h: CGFloat) {
        path.move(to: p(o, x, y))
        path.addLine(to: p(o, x + w, y))
        path.addLine(to: p(o, x + w, y + h))
        path.addLine(to: p(o, x, y + h))
        path.closeSubpath()
    }

    private static func chevron(_ path: inout Path, _ o: CGPoint, _ cx: CGFloat, _ tipY: CGFloat,
                                _ baseY: CGFloat, _ hw: CGFloat) {
        path.move(to: p(o, cx - hw, baseY))
        path.addLine(to: p(o, cx, tipY))
        path.addLine(to: p(o, cx + hw, baseY))
    }

    private static func arrowHead(_ context: inout GraphicsContext, _ o: CGPoint, _ tipX: CGFloat,
                                  _ baseX: CGFloat, _ cy: CGFloat, _ hw: CGFloat, _ color: Color) {
        var path = Path()
        path.move(to: p(o, tipX, cy))
        path.addLine(to: p(o, baseX, cy - hw))
        path.addLine(to: p(o, baseX, cy + hw))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}
