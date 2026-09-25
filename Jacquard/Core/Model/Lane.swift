// Grid coordinates, steps and lanes. Ported from Assets/Core/Model/Lane.cs.

// A grid coordinate. Cells are addressed in whole steps and rows; nothing in the model
// knows about pixels.
struct GridPoint: Hashable, CustomStringConvertible {
    var x: Int
    var y: Int

    init(_ x: Int, _ y: Int) { (self.x, self.y) = (x, y) }

    func offset(_ dx: Int, _ dy: Int) -> GridPoint { GridPoint(x + dx, y + dy) }

    var description: String { "\(x),\(y)" }
}

// One column of a lane: everything that happens at the same instant, stacked downwards.
// The stack has no fixed depth.
final class Step {
    var tiles: [Tile] = []

    var depth: Int { tiles.count }
    var isEmpty: Bool { tiles.isEmpty }

    func at(_ depth: Int) -> Tile? {
        depth >= 0 && depth < tiles.count ? tiles[depth] : nil
    }

    func find<T: Tile>(_ type: T.Type) -> T? {
        for tile in tiles { if let match = tile as? T { return match } }
        return nil
    }
}

// A row of steps placed anywhere on the plane. What kind of lane it is comes from its
// head cell and never from where it sits; the one thing position decides is the order
// the runners execute in, which reads off the vertical position of the CHAN tile.
final class Lane {
    // Grid position of the first step. The head sits one column to the left and the
    // terminator one column past the last step.
    var x: Int
    var y: Int

    var head: FlowTile

    var steps: [Step] = []

    // For a branch lane, the jump that reaches it. One to one by construction.
    var jumpSource: JumpTile?

    init(x: Int, y: Int, head: FlowTile) {
        (self.x, self.y, self.head) = (x, y, head)
    }

    var channel: ChannelTile? { head as? ChannelTile }
    var isBranch: Bool { head is JumpDestTile }

    var headX: Int { x - 1 }
    var termX: Int { x + steps.count }

    var headPoint: GridPoint { GridPoint(headX, y) }
    var termPoint: GridPoint { GridPoint(termX, y) }

    func cellPoint(_ step: Int, _ depth: Int) -> GridPoint { GridPoint(x + step, y + depth) }

    func stepAt(_ index: Int) -> Step? {
        index >= 0 && index < steps.count ? steps[index] : nil
    }

    @discardableResult
    func addStep() -> Step {
        let step = Step()
        steps.append(step)
        return step
    }

    // Every cell this lane owns: the whole rail row, and whatever hangs under it. An
    // empty step is still this lane's to write on.
    func occupiedCells() -> [GridPoint] {
        var cells: [GridPoint] = []
        for cx in headX...termX { cells.append(GridPoint(cx, y)) }
        for (i, step) in steps.enumerated() where step.depth > 1 {
            for d in 1..<step.depth { cells.append(cellPoint(i, d)) }
        }
        return cells
    }

    func owns(_ point: GridPoint) -> Bool {
        if isOnRail(point) { return true }

        let step = point.x - x
        let depth = point.y - y

        return step >= 0 && step < steps.count && depth >= 1 && depth < steps[step].depth
    }

    // The row the rail runs along, from the head to the terminator inclusive.
    func isOnRail(_ point: GridPoint) -> Bool {
        point.y == y && point.x >= headX && point.x <= termX
    }
}
