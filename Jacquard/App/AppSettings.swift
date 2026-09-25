import Foundation

// What is set about the app rather than about the piece, remembered for the machine it
// was set on and never saved with a project. Ported from Audition.cs, StageMode.cs,
// DspBuffer.cs and the visualizer switch on SystemPanel.cs.

// Whether an edit sounds the note it just made. Starts on.
enum Audition {
    static let key = "Jacquard.Audition"

    static var on: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// For playing to a room rather than working in one: takes away the controls a
// performance has no use for and an accident would cost something — Save, the guide,
// the Swap group, and typing into a bar. Starts off.
enum StageMode {
    static let key = "Jacquard.StageMode"

    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// The wash behind the score. Starts on.
enum VisualizerSetting {
    static let key = "Jacquard.Visualizer"

    static var on: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// How long a buffer the audio thread fills. iOS ships at the top of the bar, since a
// buffer shorter than the system's own breaks the screen recorder's audio track. Taken
// up at the next launch.
enum DspBuffer {
    static let min = 256
    static let max = 1024
    static let step = 128
    static let `default` = 1024
    static let key = "Jacquard.DspBuffer"

    static var requested: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: key) as? Int ?? `default`
            return Swift.min(Swift.max(stored, min), max)
        }
        set { UserDefaults.standard.set(Swift.min(Swift.max(newValue, min), max), forKey: key) }
    }

    // What this launch asked the session for.
    static var applied = `default`
}
