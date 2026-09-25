import SwiftUI

// A number is a bar, not a field. Ported from Assets/Jacquard/UI/ValueBar.cs and
// ParamRanges.cs.
//
// A drag right or up moves it, measured from where the press landed, over 160 points of
// travel; a double tap opens a field to type into (not in Stage Mode), and a typed number
// may go past the ends of the bar — the model decides what it keeps, and the bar reads
// the answer back. It reports every value a scrub passes through, and once more when it
// settles, for whatever should sound.

struct BarRange {
    var low: Float
    var high: Float
    var curve: Float = 1
    var snap: Float = 0      // Quantum a drag lands on, 0 to scrub freely
    var scale: Float = 1     // Value to readout multiplier
    var unit: String? = nil
    var digits = 2
    var floor: Float = 0     // Where a geometric run starts, 0 to use curve
    var display: ((Float) -> String)? = nil
    var bipolar: Bool

    init(_ low: Float, _ high: Float, curve: Float = 1, snap: Float = 0, scale: Float = 1,
         unit: String? = nil, digits: Int = 2, display: ((Float) -> String)? = nil,
         floor: Float = 0, bipolar: Bool? = nil) {
        (self.low, self.high, self.curve, self.snap, self.scale) = (low, high, curve, snap, scale)
        (self.unit, self.digits, self.display, self.floor) = (unit, digits, display, floor)
        self.bipolar = bipolar ?? (low < 0 && high > 0)
    }

    var geometric: Bool { floor > 0 }
    private var root: Float { low > floor ? low : floor }

    private static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
    private static func sign(_ x: Float) -> Float { x > 0 ? 1 : x < 0 ? -1 : 0 }

    func toValue(_ position: Float) -> Float {
        if geometric {
            if !bipolar { return position <= 0 ? low : root * powf(high / root, position) }
            let offset = position * 2 - 1
            let reach = offset < 0 ? -low : high
            return offset == 0 ? 0 : BarRange.sign(offset) * floor * powf(reach / floor, abs(offset))
        }

        if !bipolar { return low + (high - low) * powf(position, curve) }

        let signed = position * 2 - 1
        let depth = powf(abs(signed), curve)
        return (signed < 0 ? low : high) * depth
    }

    func toPosition(_ value: Float) -> Float {
        if geometric {
            if !bipolar {
                return value <= root ? 0 : BarRange.clamp01(logf(value / root) / logf(high / root))
            }
            let size = abs(value)
            let reach = value < 0 ? -low : high
            let away = size <= floor ? 0 : BarRange.clamp01(logf(size / floor) / logf(reach / floor))
            return (BarRange.sign(value) * away + 1) * 0.5
        }

        if !bipolar {
            return high == low ? 0 : powf(BarRange.clamp01((value - low) / (high - low)), 1 / curve)
        }

        let depth = BarRange.clamp01(value / (value < 0 ? low : high))
        let signed = BarRange.sign(value) * powf(depth, 1 / curve)
        return (signed + 1) * 0.5
    }

    func round(_ value: Float) -> Float {
        snap > 0 ? (value / snap).rounded() * snap : value
    }

    func toText(_ value: Float) -> String {
        if let display { return display(value) }
        return unit == nil ? toNumber(value) : toNumber(value) + " " + unit!
    }

    func toNumber(_ value: Float) -> String {
        let shown = value * scale
        return String(format: "%.\(places(shown))f", locale: Locale(identifier: "en_US_POSIX"),
                      Double(shown))
    }

    private func places(_ shown: Float) -> Int {
        if !geometric { return digits }
        let size = abs(shown)
        return size <= 0 ? 0 : size < 10 ? 2 : size < 100 ? 1 : 0
    }

    func parse(_ text: String) -> Float? {
        guard let typed = Float(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return typed / scale
    }

    // MARK: Kinds

    static func seconds(_ low: Float, _ high: Float) -> BarRange {
        BarRange(low, high, scale: 1000, unit: "ms", floor: 0.001)
    }

    static func amount(_ low: Float, _ high: Float, snap: Float = 0) -> BarRange {
        BarRange(low, high, snap: snap)
    }

    static func integer(_ low: Float, _ high: Float, display: ((Float) -> String)? = nil) -> BarRange {
        BarRange(low, high, snap: 1, digits: 0, display: display)
    }

    // MARK: The synth's parameters (ParamRanges.cs)

    static func of(_ target: Int) -> BarRange {
        let (low, high) = (ParamTargets.min(target), ParamTargets.max(target))

        switch target {
        case ParamTargets.carAttack, ParamTargets.carRelease, ParamTargets.pitchDecay:
            return seconds(low, high)
        case ParamTargets.modRatio, ParamTargets.feedback:
            return BarRange(low, high, curve: 2)
        case ParamTargets.gate:
            return BarRange(low, high, curve: 2, scale: 100, unit: "%", digits: 0)
        case ParamTargets.level:
            return BarRange(low, high, curve: 0.4, unit: "dB", digits: 1, display: quiet,
                            bipolar: false)
        case ParamTargets.pan:
            return BarRange(low, high, scale: 100, digits: 0, display: side)
        case ParamTargets.transpose:
            return integer(low, high, display: signed)
        default:
            return amount(low, high)
        }
    }

    // What a relative lock is dialled in: the width of the dial either way.
    static func relative(_ target: Int) -> BarRange {
        if target == ParamTargets.level { return BarRange(-24, 24, unit: "dB", digits: 1) }
        let range = of(target)
        let span = range.high - range.low
        return BarRange(-span, span, curve: range.curve, snap: range.snap, scale: range.scale,
                        unit: range.unit, digits: range.digits, floor: range.floor)
    }

    static func side(_ value: Float) -> String {
        let amount = Int((min(max(value, -1), 1) * 100).rounded())
        return amount == 0 ? "C" : (amount < 0 ? "L " : "R ") + String(abs(amount))
    }

    static func quiet(_ value: Float) -> String {
        value <= FmPatch.minLevel ? "off" : String(format: "%.1f dB", Double(value))
    }

    static func signed(_ value: Float) -> String {
        let amount = Int(value.rounded())
        return amount > 0 ? "+\(amount)" : "\(amount)"
    }
}

struct ValueBar: View {
    let range: BarRange
    let get: () -> Float
    let set: (Float) -> Void
    var settled: (() -> Void)? = nil

    // Read so the bar redraws when anything under it moves.
    var revision = 0

    @State private var dragging = false
    @State private var anchor: Float = 0
    @State private var dragged = false
    @State private var scrubbed = false
    @State private var lastClick = Date.distantPast
    @State private var editing = false
    @State private var text = ""

    static let dragDistance: CGFloat = 160
    static let dragThreshold: CGFloat = 2

    var body: some View {
        let value = get()
        let position = CGFloat(min(max(range.toPosition(value), 0), 1))
        let origin = range.bipolar ? CGFloat(min(max(range.toPosition(0), 0), 1)) : 0

        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(dragging ? Style.fillActive : Style.fill)
                    .frame(width: abs(position - origin) * width)
                    .offset(x: min(position, origin) * width)

                Text(range.toText(value))
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.noteText)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Controls.rowHeight)
        .background(Style.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: Controls.radius))
        .overlay(RoundedRectangle(cornerRadius: Controls.radius)
            .strokeBorder(Style.panelLine, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(drag(value))
        .alert("Value", isPresented: $editing) {
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
            Button("OK") { commitTyped() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func drag(_ value: Float) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { gesture in
                if !dragging {
                    dragging = true
                    dragged = false
                    anchor = min(max(range.toPosition(value), 0), 1)
                }

                let offset = gesture.translation
                if offset.width * offset.width + offset.height * offset.height >
                    ValueBar.dragThreshold * ValueBar.dragThreshold { dragged = true }
                guard dragged else { return }

                let travel = Float((offset.width - offset.height) / ValueBar.dragDistance)
                let next = range.round(range.toValue(min(max(anchor + travel, 0), 1)))
                if next != get() {
                    set(next)
                    scrubbed = true
                }
            }
            .onEnded { _ in
                dragging = false

                if scrubbed {
                    scrubbed = false
                    settled?()
                }

                if dragged {
                    lastClick = .distantPast
                    return
                }

                let now = Date()
                if now.timeIntervalSince(lastClick) < Controls.doubleClick && !StageMode.on {
                    lastClick = .distantPast
                    text = range.toNumber(get())
                    editing = true
                } else {
                    lastClick = now
                }
            }
    }

    private func commitTyped() {
        guard let typed = range.parse(text) else { return }
        set(range.round(typed))
        settled?()
    }
}
