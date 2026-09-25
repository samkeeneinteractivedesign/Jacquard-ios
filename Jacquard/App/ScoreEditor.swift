import Foundation
import Observation

// Every operation that writes the score. Ported from Assets/Jacquard/App/ScoreEditor.cs.
//
// The cursor is the answer to where: a tile is placed from the panel onto the cell the
// cursor is on, so the only cells that offer a tile are the cells that will take one.
// Every edit ends in commit(), which resyncs the sequencer and redraws the plane.

enum TileKind: CaseIterable {
    case note, absoluteLock, relativeLock, cycleGate, chanceGate, jump
}

@Observable
final class ScoreEditor {
    @ObservationIgnored unowned let engine: JacquardEngine

    init(engine: JacquardEngine) { self.engine = engine }

    var project: Project { engine.project }
    var score: Score { project.score }
    var locked: Bool { engine.locked }

    // MARK: The cursor

    private(set) var cursor = GridPoint(1, 1)

    func setCursor(_ point: GridPoint) {
        let clamped = GridPoint(min(max(point.x, 0), engine.planeColumns - 1),
                                min(max(point.y, 0), engine.planeRows - 1))
        if clamped != cursor { cursor = clamped }
    }

    func moveCursor(_ dx: Int, _ dy: Int) { setCursor(cursor.offset(dx, dy)) }

    // Carried along when the score is carried across the plane.
    func offsetCursor(_ dx: Int, _ dy: Int) { cursor = cursor.offset(dx, dy) }

    var cell: CellRef { score.at(cursor) }
    var selected: Tile? { cell.tile }

    // The lane the cursor is on: the one whose cell it is, or whose rail it stands on.
    var selectedLane: Lane? {
        if let lane = cell.lane { return lane }
        return score.lanes.first { $0.isOnRail(cursor) }
    }

    var channel: Int { score.channelOf(selectedLane) }

    var canPlace: Bool {
        let kind = cell.kind
        if kind == .tile || kind == .head { return false }
        return score.placementLane(cursor) != nil
    }

    // MARK: Placing and removing

    func put(_ kind: TileKind) {
        if locked { return }

        let tile: Tile
        switch kind {
        case .absoluteLock: tile = AbsoluteParamTile()
        case .relativeLock: tile = RelativeParamTile()
        case .cycleGate: tile = CycleGateTile(period: 4, pattern: "1000")
        case .chanceGate: tile = ProbGateTile(percent: 50)
        case .jump: tile = JumpTile()
        case .note: tile = NoteTile(note: notePitch, length: noteLength)
        }

        guard canPlace, score.place(cursor, tile) else { return }

        // A jump brings its destination lane in the same action, below everything, so
        // the one to one rule is true at every moment of editing.
        if let jump = tile as? JumpTile {
            let below = GridPoint(max(score.minX + 1, cursor.x - 4), score.height + 1)
            score.addBranchLane(jump, near: below, steps: 4)
        }

        if let note = tile as? NoteTile { preview(note.note) }

        commit()
    }

    func delete() {
        if locked { return }

        let cell = self.cell
        if cell.kind == .head, let lane = cell.lane {
            score.removeLane(lane)
            commit()
            return
        }

        if score.remove(cursor) { commit() }
    }

    // A double click means whatever the cell holds: a CHAN starts or stops its lane, a
    // tile is copied with what hangs under it, and anywhere else the copy is pasted.
    func doubleClick() {
        let cell = self.cell
        if cell.kind == .head, cell.lane?.channel != nil { toggleChannel() }
        else if cell.kind == .tile { copyStack() }
        else { pasteStack() }
    }

    func toggleChannel() {
        guard !locked, let channel = cell.lane?.channel else { return }
        channel.enabled.toggle()
        commit()
    }

    // MARK: Copy and paste

    private(set) var flashCells: [GridPoint] = []
    @ObservationIgnored private var copied: [Tile]?

    func copyStack() {
        var cells: [GridPoint] = []
        guard let copies = score.copyStack(cursor, cells: &cells) else { return }
        copied = copies
        flash(cells)
    }

    func pasteStack() {
        guard !locked, let copied, canPlace else { return }

        let tiles = copied.compactMap { $0.copy() }
        let point = cursor
        guard let (lane, step, _) = score.placementLane(point),
              score.placeStack(point, tiles)
        else { return }

        commit()

        setCursor(lane.cellPoint(step, lane.steps[step].depth - tiles.count))
        for case let note as NoteTile in tiles { preview(note.note) }
    }

    private func flash(_ cells: [GridPoint]) {
        flashCells = cells
        let marked = cells
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if self?.flashCells == marked { self?.flashCells = [] }
        }
    }

    // MARK: The note a new note arrives as

    // A new note arrives at the pitch and length of the last note edited.
    func rememberNote(_ note: NoteTile) { (notePitch, noteLength) = (note.note, note.length) }

    @ObservationIgnored private var notePitch = 60
    @ObservationIgnored private var noteLength: Float = 1

    func previewRemembered(_ channel: Int) { preview(notePitch, channel: channel, steps: noteLength) }

    // MARK: Lanes

    func newChannelLane() {
        if locked { return }
        let point = score.findFreeRow(cursor.offset(1, 0), steps: 16)
        let lane = score.addLane(x: point.x, y: point.y, head: ChannelTile(channel: channel), steps: 16)
        commit()
        setCursor(lane.headPoint)
    }

    func resizeLane(_ delta: Int) {
        guard !locked, let lane = selectedLane else { return }

        if delta > 0 {
            if !score.hasRoomToGrow(lane) { return }
            lane.addStep()
        } else if lane.steps.count > 1 {
            lane.steps.removeLast()
        }

        commit()
    }

    // MARK: Dragging

    func dropTiles(_ source: CellRef, _ target: GridPoint) {
        if locked { return }
        let move = score.planMove(source, target)
        guard score.applyMove(source, move), let lane = move.lane else { return }
        commit()
        setCursor(lane.cellPoint(move.step, move.depth))
    }

    func dropLane(_ lane: Lane, _ head: GridPoint) {
        guard !locked, score.moveLane(lane, head: head) else { return }
        commit()
        setCursor(lane.headPoint)
    }

    func swapChannels(_ a: Int, _ b: Int) {
        guard !locked, a != b else { return }
        project.swapChannels(a, b)
        commit()
    }

    // MARK: Sounding a note

    // What an edit volunteers, which the Audition switch can silence.
    func preview(_ note: Int) { preview(note, channel: channel) }

    func preview(_ note: Int, channel: Int, steps: Float = 1) {
        if Audition.on { sound(note, channel: channel, steps: steps) }
    }

    // What is asked for, which it cannot.
    func sound(_ note: Int) { sound(note, channel: channel) }

    func sound(_ note: Int, channel: Int, steps: Float = 1) {
        guard let synth = engine.synth else { return }
        let patch = project.patches[channel]
        let start = synth.currentSample + synth.minimumLead + Int64(synth.sampleRate / 20)
        let length = steps * 60 / max(project.tempo, 1) / 4
        synth.schedule(FmNoteEvent.fromPatch(patch, note: project.soundingPitch(patch, note),
                                             gateSeconds: length, startSample: start,
                                             channel: channel))
    }

    // MARK: Committing

    func commit() {
        engine.sequencer.resync()
        engine.rebuild()
    }

    // A panel edit that changes nothing on the plane.
    func touch() { engine.touchPanels() }

    // MARK: Keys

    enum Key { case left, right, up, down, delete, enter }

    func handle(_ key: Key) {
        if locked { return }
        switch key {
        case .left: moveCursor(-1, 0)
        case .right: moveCursor(1, 0)
        case .up: moveCursor(0, -1)
        case .down: moveCursor(0, 1)
        case .delete: delete()
        case .enter: if let note = selected as? NoteTile { sound(note.note) }
        }
    }
}
