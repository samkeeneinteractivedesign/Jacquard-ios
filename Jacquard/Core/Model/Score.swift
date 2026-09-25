// One grid plane holding every lane. Ported from Assets/Core/Model/Score.cs.
//
// Channels are not split across planes: several CHAN lanes on the same channel simply
// sit next to each other here.

// What a grid cell turns out to be. Rail means a cell on a lane's own rail row whose
// step holds nothing: that is where the pass-through marker shows up.
enum CellKind { case empty, rail, head, term, tile }

struct CellRef {
    var kind: CellKind
    var lane: Lane?
    var step: Int
    var depth: Int
    var tile: Tile?

    static let empty = CellRef(kind: .empty, lane: nil, step: 0, depth: 0, tile: nil)

    var isFlowCell: Bool { kind == .head || kind == .term }
}

// A tile drag resolved against the score: the stack it would land in, where in that
// stack, and how many tiles travel with it.
struct TileMove {
    var lane: Lane?
    var step: Int
    var depth: Int
    var count: Int

    var isValid: Bool { lane != nil }

    static let none = TileMove(lane: nil, step: 0, depth: 0, count: 0)
}

final class Score {
    var lanes: [Lane] = []

    // MARK: Lookup

    // Head, terminator, then the step stack, taking the first lane that claims it.
    func at(_ point: GridPoint) -> CellRef {
        for lane in lanes {
            if point == lane.headPoint {
                return CellRef(kind: .head, lane: lane, step: -1, depth: 0, tile: lane.head)
            }

            if point == lane.termPoint {
                return CellRef(kind: .term, lane: lane, step: lane.steps.count, depth: 0,
                               tile: Score.terminator)
            }

            let step = point.x - lane.x
            let depth = point.y - lane.y

            if step < 0 || step >= lane.steps.count || depth < 0 { continue }

            if let tile = lane.steps[step].at(depth) {
                return CellRef(kind: .tile, lane: lane, step: step, depth: depth, tile: tile)
            }

            if depth == 0 {
                return CellRef(kind: .rail, lane: lane, step: step, depth: 0, tile: nil)
            }
        }

        return .empty
    }

    // Ground no lane has a claim on. One lane can be excused.
    func isFree(_ point: GridPoint, except: Lane? = nil) -> Bool {
        for lane in lanes where lane !== except && lane.owns(point) { return false }
        return true
    }

    func hasRoomToGrow(_ lane: Lane) -> Bool {
        isFree(lane.termPoint.offset(1, 0), except: lane)
    }

    func locate(_ tile: Tile) -> GridPoint? {
        for lane in lanes {
            if lane.head === tile { return lane.headPoint }
            for (i, step) in lane.steps.enumerated() {
                if let depth = step.tiles.firstIndex(where: { $0 === tile }) {
                    return lane.cellPoint(i, depth)
                }
            }
        }
        return nil
    }

    func laneOf(_ tile: Tile) -> Lane? {
        for lane in lanes {
            if lane.head === tile { return lane }
            for step in lane.steps where step.tiles.contains(where: { $0 === tile }) {
                return lane
            }
        }
        return nil
    }

    // Which channel a lane sounds on. A branch lane takes the channel of whatever jumps
    // into it, following the chain until a CHAN lane turns up. Bounded so that a ring
    // cannot hang the editor.
    func channelOf(_ lane: Lane?) -> Int {
        var lane = lane
        var guardCount = 0
        while let current = lane, guardCount < 64 {
            if let channel = current.channel { return channel.channel }
            guard let source = current.jumpSource else { break }
            lane = laneOf(source)
            guardCount += 1
        }
        return 1
    }

    // The branch lane a jump hands over to. One to one.
    func destinationOf(_ jump: JumpTile) -> Lane? {
        lanes.first { $0.jumpSource === jump }
    }

    // Runners are born from CHAN lanes, and a runner higher on the plane runs before
    // one that sits lower. A stable sort, like LINQ's OrderBy/ThenBy.
    var channelLanes: [Lane] {
        lanes.enumerated()
            .filter { $0.element.channel != nil }
            .sorted {
                let (a, b) = ($0.element, $1.element)
                if a.y != b.y { return a.y < b.y }
                if a.x != b.x { return a.x < b.x }
                return $0.offset < $1.offset
            }
            .map { $0.element }
    }

    // The lane the piece's period is read off: the first channel one lane in the order
    // the runners are born in, or whoever runs first when there is none.
    var masterLane: Lane? {
        var first: Lane?
        for lane in channelLanes {
            if first == nil { first = lane }
            if lane.channel?.channel == 1 { return lane }
        }
        return first
    }

    var width: Int { lanes.isEmpty ? 0 : lanes.map(\.termX).max()! + 1 }
    var height: Int { lanes.isEmpty ? 0 : lanes.map(Score.bottomOf).max()! + 1 }
    var minX: Int { lanes.isEmpty ? 0 : lanes.map(\.headX).min()! }
    var minY: Int { lanes.isEmpty ? 0 : lanes.map(\.y).min()! }

    static func bottomOf(_ lane: Lane) -> Int {
        var depth = 1
        for step in lane.steps { depth = max(depth, step.depth) }
        return lane.y + depth - 1
    }

    func translate(_ dx: Int, _ dy: Int) {
        for lane in lanes { lane.x += dx; lane.y += dy }
    }

    // MARK: Editing

    // Places a tile, growing the lane by one step when the terminator cell is targeted.
    @discardableResult
    func place(_ point: GridPoint, _ tile: Tile) -> Bool {
        guard let (lane, step, depth) = placementLane(point) else { return false }

        if step == lane.steps.count { lane.addStep() }

        let target = lane.steps[step]
        if depth < target.tiles.count { target.tiles[depth] = tile }
        else { target.tiles.append(tile) }

        return true
    }

    // A copy of the tile at this point and of everything hanging under it.
    func copyStack(_ point: GridPoint, cells: inout [GridPoint]) -> [Tile]? {
        let cell = at(point)
        guard cell.kind == .tile, let lane = cell.lane, cell.tile?.copy() != nil
        else { return nil }

        let tiles = lane.steps[cell.step].tiles
        var copies: [Tile] = []

        for depth in cell.depth..<tiles.count {
            guard let copy = tiles[depth].copy() else { continue }
            copies.append(copy)
            cells.append(lane.cellPoint(cell.step, depth))
        }

        return copies
    }

    // Puts a run of tiles down as one stack, refused whole if it will not fit.
    @discardableResult
    func placeStack(_ point: GridPoint, _ tiles: [Tile]) -> Bool {
        guard !tiles.isEmpty, let (lane, step, depth) = placementLane(point) else { return false }

        if depth != (lane.stepAt(step)?.depth ?? 0) { return false }

        for i in tiles.indices.dropFirst() {
            if !isFree(lane.cellPoint(step, depth + i), except: lane) { return false }
        }

        if step == lane.steps.count { lane.addStep() }

        lane.steps[step].tiles.append(contentsOf: tiles)
        return true
    }

    // The lane that would take a tile at this point, if any.
    func placementLane(_ point: GridPoint) -> (Lane, Int, Int)? {
        for lane in lanes {
            let sx = point.x - lane.x
            let sy = point.y - lane.y

            if sx < 0 || sx > lane.steps.count || sy < 0 { continue }

            if sx == lane.steps.count {
                if sy != 0 { continue }
                if !hasRoomToGrow(lane) { continue }
                return (lane, sx, 0)
            }

            if sy > lane.steps[sx].depth { continue }
            if sy == lane.steps[sx].depth && !isFree(point, except: lane) { continue }

            return (lane, sx, sy)
        }

        return nil
    }

    // Removes whatever tile is at this point. A jump takes its branch lane with it.
    @discardableResult
    func remove(_ point: GridPoint) -> Bool {
        let cell = at(point)
        guard cell.kind == .tile, let lane = cell.lane else { return false }

        if let jump = cell.tile as? JumpTile, let branch = destinationOf(jump) {
            removeLane(branch, removeJumpSource: false)
        }

        lane.steps[cell.step].tiles.remove(at: cell.depth)
        return true
    }

    // MARK: Dragging

    private func sourceStep(_ source: CellRef) -> Step? {
        guard let step = source.lane?.stepAt(source.step),
              let tile = source.tile, step.at(source.depth) === tile
        else { return nil }
        return step
    }

    func dropLane(_ point: GridPoint) -> (Lane, Int, Int)? {
        for lane in lanes {
            let sx = point.x - lane.x
            let sy = point.y - lane.y

            if sx < 0 || sx > lane.steps.count || sy < 0 { continue }

            if sx == lane.steps.count {
                if sy != 0 { continue }
                if !hasRoomToGrow(lane) { continue }
                return (lane, sx, 0)
            }

            if sy > lane.steps[sx].depth { continue }

            return (lane, sx, sy)
        }

        return nil
    }

    func planMove(_ source: CellRef, _ target: GridPoint) -> TileMove {
        guard source.kind == .tile, let from = sourceStep(source),
              let (lane, step, landing) = dropLane(target)
        else { return .none }

        var depth = landing

        let tiles = from.tiles
        let same = lane === source.lane && step == source.step

        if same && depth == source.depth { return .none }

        let count = same ? 1 : tiles.count - source.depth

        if same {
            depth = min(depth, tiles.count - 1)
        } else {
            let grown = lane.stepAt(step)?.depth ?? 0
            for i in 0..<count where !isFree(lane.cellPoint(step, grown + i), except: lane) {
                return .none
            }
        }

        return TileMove(lane: lane, step: step, depth: depth, count: count)
    }

    @discardableResult
    func applyMove(_ source: CellRef, _ move: TileMove) -> Bool {
        guard move.isValid, let lane = move.lane, let from = sourceStep(source),
              source.depth + move.count <= from.tiles.count
        else { return false }

        let range = source.depth..<(source.depth + move.count)
        let moved = Array(from.tiles[range])
        from.tiles.removeSubrange(range)

        if move.step == lane.steps.count { lane.addStep() }

        let into = lane.steps[move.step]
        into.tiles.insert(contentsOf: moved, at: min(move.depth, into.tiles.count))
        return true
    }

    func canMoveLane(_ lane: Lane, head: GridPoint) -> Bool {
        guard lanes.contains(where: { $0 === lane }) else { return false }
        if head.x < 0 || head.y < 0 { return false }

        let dx = head.x - lane.headX
        let dy = head.y - lane.y
        if dx == 0 && dy == 0 { return false }

        for cell in lane.occupiedCells() where !isFree(cell.offset(dx, dy), except: lane) {
            return false
        }

        return true
    }

    @discardableResult
    func moveLane(_ lane: Lane, head: GridPoint) -> Bool {
        guard canMoveLane(lane, head: head) else { return false }
        lane.x = head.x + 1
        lane.y = head.y
        return true
    }

    @discardableResult
    func addLane(x: Int, y: Int, head: FlowTile, steps: Int) -> Lane {
        let lane = Lane(x: x, y: y, head: head)
        for _ in 0..<steps { lane.addStep() }
        lanes.append(lane)
        return lane
    }

    // Creates the branch lane a jump hands over to, in one action, so the one to one rule
    // holds at every moment of editing.
    @discardableResult
    func addBranchLane(_ jump: JumpTile, near: GridPoint, steps: Int) -> Lane {
        let point = findFreeRow(near, steps: steps)
        let lane = addLane(x: point.x, y: point.y, head: JumpDestTile(), steps: steps)
        lane.jumpSource = jump
        return lane
    }

    // Drops a lane. Branch lanes reachable from it go too; removing a branch lane
    // likewise takes out the jump that fed it.
    func removeLane(_ lane: Lane, removeJumpSource: Bool = true) {
        guard let index = lanes.firstIndex(where: { $0 === lane }) else { return }
        lanes.remove(at: index)

        if removeJumpSource, let source = lane.jumpSource, let point = locate(source) {
            let cell = at(point)
            if cell.kind == .tile, let owner = cell.lane {
                owner.steps[cell.step].tiles.remove(at: cell.depth)
            }
        }

        for step in lane.steps {
            for tile in step.tiles {
                if let jump = tile as? JumpTile, let branch = destinationOf(jump) {
                    removeLane(branch, removeJumpSource: false)
                }
            }
        }
    }

    // Somewhere the given lane length fits, searched downwards from a hint, with one
    // clear row above as well.
    func findFreeRow(_ hint: GridPoint, steps: Int) -> GridPoint {
        let x = max(1, hint.x)

        for y in max(1, hint.y)..<(hint.y + 256) {
            var free = true

            var i = -1
            while i <= steps + 1 && free {
                var dy = -1
                while dy <= 0 && free {
                    free = isFree(GridPoint(x - 1 + i, y + dy))
                    dy += 1
                }
                i += 1
            }

            if free { return GridPoint(x, y) }
        }

        return GridPoint(x, hint.y)
    }

    // The terminator carries no state and is never stored in a step.
    static let terminator = TerminatorTile()
}
