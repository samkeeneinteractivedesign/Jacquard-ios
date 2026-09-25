import Foundation

// The score folder. Ported from Assets/Jacquard/App/ProjectStore.cs.
//
// Every score is a plain text file in one folder, Documents/Scores, which the Files app
// shows under On My iPhone (or On My iPad) as Jacquard's own. The list the chooser shows
// is that folder read out rather than anything the app remembers, so a file dropped in
// from outside simply appears.

final class ProjectStore {
    var name = ProjectStore.slotName(1)

    var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scores", isDirectory: true)
    }

    func url(of name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(ProjectFormat.fileExtension)
    }

    func save(_ project: Project) -> String {
        do {
            try write(name, project)
            remember()
            return "saved " + name
        } catch {
            return "could not save: " + error.localizedDescription
        }
    }

    func load() -> (Project?, String) {
        let url = url(of: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (nil, "no file called " + name)
        }

        do {
            let project = try ProjectFormat.read(String(contentsOf: url, encoding: .utf8))
            remember()
            return (project, "loaded " + name)
        } catch {
            return (nil, "could not read \(name): \(error.localizedDescription)")
        }
    }

    func slots() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == ProjectFormat.fileExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // A copy of the app that has saved nothing yet writes fourteen scores for itself:
    // the five samples, and nine bars with a note on each beat to work in. So every name
    // on the chooser is a file that is really there.
    @discardableResult
    func seed(samples: Int, sample: (Int) -> Project?) -> Bool {
        guard slots().isEmpty else { return false }

        do {
            for index in 1...samples {
                if let project = sample(index) { try write(ProjectStore.sampleName(index), project) }
            }
            for slot in 1...ProjectStore.slotCount {
                try write(ProjectStore.slotName(slot), Project.createInitial())
            }
            return true
        } catch {
            return false
        }
    }

    // Whichever was last saved or loaded, and on the very first launch the first on the
    // list, which is sample1.
    func opening() -> String {
        let slots = slots()
        let last = UserDefaults.standard.string(forKey: ProjectStore.lastKey) ?? ""
        if slots.contains(last) { return last }
        return slots.first ?? ProjectStore.slotName(1)
    }

    static let slotCount = 9
    static func slotName(_ slot: Int) -> String { "score\(slot)" }
    static func sampleName(_ index: Int) -> String { "sample\(index)" }
    static let lastKey = "Jacquard.Score"

    private func remember() {
        UserDefaults.standard.set(name, forKey: ProjectStore.lastKey)
    }

    private func write(_ name: String, _ project: Project) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProjectFormat.write(project).write(to: url(of: name), atomically: true, encoding: .utf8)
    }
}
