import SwiftUI

// Colours and metrics. Ported from Assets/Jacquard/UI/Style.cs.
//
// The look is flat and monochrome: one ramp of greys, no gradients, no shadows, nothing
// coloured to carry meaning. What a thing is saying is said by where it sits on the
// ramp and by how much air is around it.

enum Style {
    static let cellWidth: CGFloat = 30
    static let cellHeight: CGFloat = 32
    static let gap: CGFloat = 4
    static let radius: CGFloat = 5
    static let padding: CGFloat = 18
    static let strideX = cellWidth + gap
    static let strideY = cellHeight + gap

    static let noteSize: CGFloat = 13
    static let lengthSize: CGFloat = 9
    static let controlSize: CGFloat = 11
    static let accidentalGutter: CGFloat = 5

    static let railDot: CGFloat = 2
    static let railStep: CGFloat = 7
    static let railOpacity: Double = 0.35
    static let linkOffset: CGFloat = 7.5
    static let linkRadius: CGFloat = 6
    static let latticeDot: CGFloat = 2
    static let dimmedOpacity: Double = 0.45

    static let background = grey(0x16)
    static let noteLine = grey(0xe8)
    static let noteText = grey(0xf2)
    static let marker = grey(0x9a)
    static let dot = grey(0x4e)
    static let controlBackground = grey(0x34)
    static let controlHover = grey(0x44)
    static let link = grey(0x86)
    static let fill = grey(0x6c)
    static let fillActive = grey(0x84)
    static let panel = grey(0x1e)
    static let panelLine = grey(0x3a)
    static let label = grey(0x9a)
    static let frontLine = grey(0x5a)
    static let cursor = grey(0xf2)
    static let playhead = grey(0xf2)

    // The UI face, as in the original: Jura, bundled under the OFL and registered at
    // launch (JacquardApp). Bold is how ink on a light ground is set.
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom("Jura", size: size).weight(bold ? .bold : .regular)
    }

    static func grey(_ value: UInt8) -> Color {
        let v = Double(value) / 255
        return Color(.sRGB, red: v, green: v, blue: v, opacity: 1)
    }

    // The same grey as a raw sRGB value, for the Metal side.
    static func greyValue(_ value: UInt8) -> Float { Float(value) / 255 }

    static func cellOrigin(_ point: GridPoint) -> CGPoint {
        CGPoint(x: padding + CGFloat(point.x) * strideX, y: padding + CGFloat(point.y) * strideY)
    }

    static func cellCenter(_ point: GridPoint) -> CGPoint {
        let o = cellOrigin(point)
        return CGPoint(x: o.x + cellWidth / 2, y: o.y + cellHeight / 2)
    }

    static func cellRect(_ point: GridPoint) -> CGRect {
        CGRect(origin: cellOrigin(point), size: CGSize(width: cellWidth, height: cellHeight))
    }

    static func cellAt(_ position: CGPoint) -> GridPoint {
        GridPoint(Int(((position.x - padding) / strideX).rounded(.down)),
                  Int(((position.y - padding) / strideY).rounded(.down)))
    }

    static func planeSize(columns: Int, rows: Int) -> CGSize {
        CGSize(width: padding * 2 + CGFloat(columns) * strideX - gap,
               height: padding * 2 + CGFloat(rows) * strideY - gap)
    }
}
