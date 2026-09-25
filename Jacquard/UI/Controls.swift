import SwiftUI

// The pieces every panel is built from. Ported from Assets/Jacquard/UI/Controls.cs, in
// its touch profile, which is the one a phone and a tablet get.
//
// A panel draws no outline and cuts no corners: what tells it from the plane is a lighter
// ground with air around it. A corner radius means one thing here — something a hand
// picks up. A panel is spaced out of three numbers, gap, inset and group gap.

enum Controls {
    static let rowHeight: CGFloat = 30
    static let fontSize: CGFloat = 13
    static let labelWidth: CGFloat = 88
    static let panelWidth: CGFloat = 248
    static let radius: CGFloat = 5

    static let gap: CGFloat = 3
    static let inset: CGFloat = 10
    static let groupGap: CGFloat = gap * 2
    static let panelGap: CGFloat = 12

    static let transportRowHeight: CGFloat = rowHeight + 16

    // How long after a press a second one still reads as the same gesture, everywhere.
    static let doubleClick: TimeInterval = 0.4

    static let mouseFontSize: CGFloat = 11

    // A width given in the mouse profile's terms, stretched to hold the same words at the
    // touch profile's larger type, and never narrower than a row is tall.
    static func width(_ width: CGFloat) -> CGFloat {
        max((width * fontSize / mouseFontSize).rounded(), rowHeight)
    }

    // A square switch sized so `perRow` of them fill a panel's width.
    static func switchSize(_ perRow: Int) -> CGFloat {
        ((panelWidth - inset * 2 + gap) / CGFloat(perRow)).rounded(.down) - gap
    }
}

// A panel: its subject as the header, then its rows.
struct Panel<Content: View>: View {
    let title: String
    var width: CGFloat? = Controls.panelWidth
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Style.font(Controls.fontSize))
                .foregroundColor(Style.noteText)
                .frame(height: Controls.rowHeight, alignment: .leading)
                .padding(.bottom, Controls.gap)
            content()
        }
        .padding(.horizontal, Controls.inset)
        .padding(.top, Controls.inset)
        .padding(.bottom, Controls.inset - Controls.gap)
        .frame(width: width, alignment: .leading)
        .background(Style.panel)
    }
}

// A group's name, with the one rule inside a panel under it.
struct Heading: View {
    let text: String
    var follows = false

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(Style.font(Controls.fontSize))
                .foregroundColor(Style.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Rectangle().fill(Style.panelLine).frame(height: 1)
        }
        .frame(height: Controls.rowHeight)
        .padding(.top, follows ? Controls.groupGap : 0)
        .padding(.bottom, Controls.gap)
    }
}

struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Style.font(Controls.fontSize))
            .foregroundColor(Style.label)
            .lineLimit(1)
            .frame(width: Controls.labelWidth, height: Controls.rowHeight, alignment: .leading)
    }
}

// A name beside a bar that takes the row back on a double tap.
struct ActionCaption: View {
    let text: String
    var bright = false
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(Style.font(Controls.fontSize))
            .foregroundColor(bright ? Style.noteText : Style.label)
            .lineLimit(1)
            .frame(width: Controls.labelWidth, height: Controls.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: action)
    }
}

// A caption and a bar: a row of a panel.
struct BarRow: View {
    let caption: String
    let range: BarRange
    let revision: Int
    let get: () -> Float
    let set: (Float) -> Void
    var settled: (() -> Void)? = nil
    var reset: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            if let reset {
                ActionCaption(text: caption, action: reset)
            } else {
                Caption(text: caption)
            }
            ValueBar(range: range, get: get, set: set, settled: settled, revision: revision)
        }
        .padding(.bottom, Controls.gap)
    }
}

// A button: grey ground, or the light ground with dark bold ink when it is on.
struct PushButton: View {
    let label: String
    var width: CGFloat? = nil
    var active = false
    var height: CGFloat = Controls.rowHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ButtonFace(label: label, active: active, width: width, height: height)
        }
        .buttonStyle(.plain)
    }
}

struct ButtonFace: View {
    let label: String
    var active = false
    var width: CGFloat? = nil
    var height: CGFloat = Controls.rowHeight

    var body: some View {
        Text(label)
            .font(Style.font(Controls.fontSize, bold: active))
            .foregroundColor(active ? Style.background : Style.noteText)
            .lineLimit(1)
            .padding(.horizontal, width == nil ? 10 : 0)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: Controls.radius)
                .fill(active ? Style.noteLine : Style.controlBackground))
            .contentShape(Rectangle())
    }
}

// A labelled on/off row.
struct ToggleRow: View {
    let caption: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Caption(text: caption)
            PushButton(label: on ? "On" : "Off", width: Controls.width(44), active: on, action: action)
            Spacer(minLength: 0)
        }
        .padding(.bottom, Controls.gap)
    }
}

// A square switch, as the laps of a cycle gate and the keys are.
struct SquareSwitch: View {
    let size: CGFloat
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Controls.radius)
                .fill(on ? Style.noteLine : Style.controlBackground)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}

// One of a list, stepped through with an arrow either side.
struct Chooser: View {
    var caption: String? = nil
    let options: [String]
    let index: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: Controls.gap) {
            if let caption { Caption(text: caption) }

            arrow("‹", -1)

            Text(options.isEmpty ? "" : options[min(max(index, 0), options.count - 1)])
                .font(Style.font(Controls.fontSize))
                .foregroundColor(Style.noteText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Controls.rowHeight)

            arrow("›", 1)
        }
        .padding(.bottom, Controls.gap)
    }

    private func arrow(_ glyph: String, _ delta: Int) -> some View {
        PushButton(label: glyph, width: Controls.width(22)) {
            guard !options.isEmpty else { return }
            set((index + delta + options.count) % options.count)
        }
    }
}

// A number moved one at a time.
struct CountStepper: View {
    let caption: String
    let value: Int
    let change: (Int) -> Void

    var body: some View {
        HStack(spacing: Controls.gap) {
            Caption(text: caption)
            PushButton(label: "−", width: Controls.rowHeight) { change(-1) }
            Text("\(value)")
                .font(Style.font(Controls.fontSize))
                .foregroundColor(Style.noteText)
                .frame(maxWidth: .infinity, minHeight: Controls.rowHeight)
            PushButton(label: "+", width: Controls.rowHeight) { change(1) }
        }
        .padding(.bottom, Controls.gap)
    }
}

// A button that acts while it is held — a live effect.
struct HoldButton: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let press: () -> Void
    let release: () -> Void

    @State private var held = false

    var body: some View {
        ButtonFace(label: label, active: held, width: width, height: height)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !held { held = true; press() }
                }
                .onEnded { _ in
                    held = false
                    release()
                })
    }
}

// The twelve semitones as a keyboard: the letter half of a note's pitch and the scale
// both stand them in the same places. Ported from Keys.cs.
struct Keys: View {
    let lit: (Int) -> Bool
    let press: (Int) -> Void

    static let white = [0, 2, 4, 5, 7, 9, 11]
    static let black = [1, 3, 6, 8, 10]
    static let blackAfter = [0, 1, 3, 4, 5]

    var body: some View {
        let size = Controls.switchSize(Keys.white.count)
        let stride = size + Controls.gap

        ZStack(alignment: .topLeading) {
            ForEach(0..<Keys.black.count, id: \.self) { i in
                let degree = Keys.black[i]
                SquareSwitch(size: size, on: lit(degree)) { press(degree) }
                    .offset(x: stride * (CGFloat(Keys.blackAfter[i]) + 0.5))
            }

            HStack(spacing: Controls.gap) {
                ForEach(Keys.white, id: \.self) { degree in
                    SquareSwitch(size: size, on: lit(degree)) { press(degree) }
                }
            }
            .offset(y: size + Controls.gap)
        }
        .frame(height: size * 2 + Controls.gap, alignment: .topLeading)
        .padding(.bottom, Controls.gap)
    }
}
