import Foundation

// Note names and frequencies.
//
// Ported from Assets/Core/Model/Pitch.cs. Pitches are MIDI note numbers throughout,
// with 60 spelled C4. Only sharps are used: sequencer-spec.md drops flats so that one
// pitch has exactly one spelling and a cell therefore has exactly one look.

enum Pitch {
    static let lowest = 12   // C0
    static let highest = 120 // C9

    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func toName(_ note: Int) -> String {
        names[mod(note, 12)] + String(note / 12 - 1)
    }

    // Name without the octave, for the cell label where the two are typeset separately.
    static func toClassName(_ note: Int) -> String { names[mod(note, 12)] }

    // Divides rather than floors, so it is only right from note 0 up — which is every
    // note this program can hold. The same as the original.
    static func toOctave(_ note: Int) -> Int { note / 12 - 1 }

    static func toClass(_ note: Int) -> Int { mod(note, 12) }

    static func fromParts(octave: Int, pitchClass: Int) -> Int {
        (octave + 1) * 12 + pitchClass
    }

    static func isSharp(_ note: Int) -> Bool { names[mod(note, 12)].count > 1 }

    // Equal temperament, A4 = 440Hz.
    static func toFrequency(_ note: Float) -> Float {
        440.0 * powf(2.0, (note - 69.0) / 12.0)
    }

    // Parses a name such as "C4", "F#4" or "G#-1". Flats are rejected.
    static func parse(_ text: String) -> Int? {
        let chars = Array(text)
        guard let first = chars.first,
              var index = names.firstIndex(of: String(first).uppercased())
        else { return nil }

        var i = 1
        if i < chars.count && (chars[i] == "#" || chars[i] == "s") {
            index += 1
            i += 1
        }

        guard i < chars.count, let octave = Int(String(chars[i...])) else { return nil }

        let note = (octave + 1) * 12 + index
        return note >= 0 && note < 128 ? note : nil
    }

    // Floor modulo, so that negative note numbers still name correctly.
    static func mod(_ a: Int, _ b: Int) -> Int { (a % b + b) % b }
}
