// Which of the twelve pitch classes are allowed to sound.
//
// Ported from Assets/Core/Model/Scale.cs. A switch per semitone rather than a key and a
// mode; this is not an edit — a written note keeps its pitch, and this decides what that
// pitch sounds as, snapping rather than dropping. Everything on is the default and the
// same as no scale at all; nothing on leaves every note where it is.

final class Scale {
    static let degrees = 12

    func allows(_ note: Int) -> Bool { allowed[Scale.degree(note)] }

    func setAllowed(_ note: Int, _ value: Bool) { allowed[Scale.degree(note)] = value }

    // The nearest note this scale will take. Down before up at each distance, so a note
    // exactly between two of them takes the lower.
    func snap(_ note: Int) -> Int {
        if allows(note) { return note }

        for distance in 1...(Scale.degrees / 2) {
            if allows(note - distance) { return note - distance }
            if allows(note + distance) { return note + distance }
        }

        return note
    }

    static func degree(_ note: Int) -> Int { (note % degrees + degrees) % degrees }

    private var allowed = [Bool](repeating: true, count: Scale.degrees)
}
