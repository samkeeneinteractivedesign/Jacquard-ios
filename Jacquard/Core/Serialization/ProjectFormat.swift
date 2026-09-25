import Foundation

// The plain text a project is saved as. Ported from
// Assets/Core/Serialization/ProjectFormat.cs, including the conversions it makes for
// older versions of the format, so files written by the Unity app open here unchanged
// and files written here open there.

struct ProjectFormatError: LocalizedError {
    let line: Int
    let message: String
    var errorDescription: String? { "line \(line + 1): \(message)" }
}

enum ProjectFormat {
    static let version = 20
    static let fileExtension = "jacquard"

    // MARK: Writing

    static func write(_ project: Project) -> String {
        var text = ""
        text += "jacquard \(version)\n"
        text += "tempo \(f(project.tempo))\n"
        text += "meter \(project.beatsPerBar) \(project.beatUnit)\n"
        text += "fx \(writeFx(project.fx))\n"
        text += "limiter \(writeLimiter(project.limiter))\n"
        text += "mutes \(writeMutes(project.mutes))\n"
        text += "scale \(writeScale(project.scale))\n"

        for channel in 1...PatchBank.channels {
            text += "patch \(channel) \(writePatch(project.patches[channel]))\n"
        }

        for lane in project.score.lanes { writeLane(&text, project.score, lane) }

        return text
    }

    private static func writeLane(_ text: inout String, _ score: Score, _ lane: Lane) {
        text += "lane \(lane.x) \(lane.y) "

        if let channel = lane.channel {
            text += "CHAN:\(channel.channel) div=\(channel.division) on=\(channel.enabled ? 1 : 0)"
        } else {
            text += "JDST"
            if let source = lane.jumpSource, let point = score.locate(source) {
                text += " from=\(point.x),\(point.y)"
            }
        }

        text += "\n"

        for step in lane.steps {
            text += "  step"
            for tile in step.tiles { text += " " + writeTile(tile) }
            text += "\n"
        }
    }

    private static func writeTile(_ tile: Tile) -> String {
        switch tile {
        case let note as NoteTile:
            return note.hasDefaultLength ? Pitch.toName(note.note)
                                         : Pitch.toName(note.note) + "/" + f(note.length)
        case let p as AbsoluteParamTile: return "PABS" + writeLock(p)
        case let p as RelativeParamTile: return "PREL" + writeLock(p)
        case let g as CycleGateTile: return "GCYC:\(g.period),\(g.pattern)"
        case let g as ProbGateTile: return "GPRB:" + f(g.percent)
        case is JumpTile: return "JUMP"
        default: return tile.token
        }
    }

    private static func writeLock(_ tile: ParamTile) -> String {
        var text = ""
        for target in 0..<ParamTargets.count where tile.isEngaged(target) {
            text += (text.isEmpty ? ":" : ",") + ParamTargets.key(target) + "," + f(tile[target])
        }
        return text
    }

    private static func writePatch(_ p: FmPatch) -> String {
        "transpose=\(f(p.transpose)) level=\(f(p.level)) pan=\(f(p.pan))" +
        " uni=\(f(p.unison)) gate=\(f(p.gateScale)) mratio=\(f(p.modulatorRatio))" +
        " index=\(f(p.modulationIndex)) fb=\(f(p.feedback)) md=\(f(p.modulatorDecay))" +
        " ca=\(f(p.carrierAttack)) cr=\(f(p.carrierRelease)) ps=\(f(p.pitchSweep))" +
        " pd=\(f(p.pitchDecay)) rsend=\(f(p.reverbSend)) dsend=\(f(p.delaySend))"
    }

    private static func writeLimiter(_ l: Limiter) -> String {
        "ceiling=\(f(l.ceiling)) attack=\(f(l.attack)) release=\(f(l.release))"
    }

    private static func writeMutes(_ mutes: ChannelMutes) -> String {
        var text = "muted="
        for channel in 1...PatchBank.channels { text += mutes.isMuted(channel) ? "1" : "0" }
        text += " soloed="
        for channel in 1...PatchBank.channels { text += mutes.isSoloed(channel) ? "1" : "0" }
        return text
    }

    private static func writeScale(_ scale: Scale) -> String {
        "notes=" + (0..<Scale.degrees).map { scale.allows($0) ? "1" : "0" }.joined()
    }

    private static func writeFx(_ fx: SendFx) -> String {
        "rsize=\(f(fx.reverbSize)) rtone=\(f(fx.reverbTone)) rspread=\(f(fx.reverbSpread))" +
        " dbeats=\(f(fx.delayBeats)) dfb=\(f(fx.delayFeedback)) dtone=\(f(fx.delayTone))" +
        " dspread=\(f(fx.delaySpread))"
    }

    private static func f(_ value: Float) -> String { Format.short(value, places: 5) }

    // MARK: Reading

    static func read(_ text: String) throws -> Project {
        let project = Project()
        let score = project.score
        var lane: Lane?
        var links: [(Lane, GridPoint)] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var version = self.version

        for (number, line) in lines.enumerated() {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
                             .map(String.init)

            guard let keyword = tokens.first, !keyword.hasPrefix("#") else { continue }

            switch keyword {
            case "jacquard":
                if tokens.count > 1 { version = readInt(tokens[1]) }
                if version > self.version {
                    throw ProjectFormatError(line: number, message: "file is from a newer version")
                }

            case "tempo":
                project.tempo = readFloat(try arg(tokens, 1, number))

            case "meter":
                project.beatsPerBar = readInt(try arg(tokens, 1, number))
                project.beatUnit = readInt(try arg(tokens, 2, number))

            case "fx":
                readFx(&project.fx, tokens, version)

            case "limiter":
                readLimiter(&project.limiter, tokens, version)

            case "mutes":
                readMutes(project.mutes, tokens)

            case "scale":
                readScale(project.scale, tokens)

            case "patch":
                readPatchLine(project, tokens, version)

            case "lane":
                lane = try readLane(score, tokens, number, &links)

            case "step":
                guard let lane else {
                    throw ProjectFormatError(line: number, message: "step outside a lane")
                }
                try readStep(lane.addStep(), tokens, number, version)

            default:
                throw ProjectFormatError(line: number, message: "unknown keyword " + keyword)
            }
        }

        // Links last, since a jump may be written after the lane it leads to.
        for (branch, point) in links {
            if let jump = score.at(point).tile as? JumpTile { branch.jumpSource = jump }
        }

        if version < 17 { project.limiter.ceiling = stagedThreshold(project.limiter.ceiling) }
        if version < 18 { levelShifts(project) }

        return project
    }

    private static func readLane(_ score: Score, _ tokens: [String], _ number: Int,
                                 _ links: inout [(Lane, GridPoint)]) throws -> Lane {
        let x = readInt(try arg(tokens, 1, number))
        let y = readInt(try arg(tokens, 2, number))
        let head = try arg(tokens, 3, number)

        let tile: FlowTile

        if head.hasPrefix("CHAN") {
            let channel = ChannelTile()
            if let colon = head.firstIndex(of: ":") {
                channel.channel = readInt(String(head[head.index(after: colon)...]))
            }
            tile = channel
        } else if head == "JDST" {
            tile = JumpDestTile()
        } else {
            throw ProjectFormatError(line: number, message: "a lane head must be CHAN or JDST")
        }

        let lane = score.addLane(x: x, y: y, head: tile, steps: 0)

        for token in tokens.dropFirst(4) {
            let (key, value) = split(token)
            if key == "div", let ch = tile as? ChannelTile { ch.division = readInt(value) }
            else if key == "on", let ch = tile as? ChannelTile { ch.enabled = readInt(value) != 0 }
            else if key == "from" { links.append((lane, try readPoint(value, number))) }
        }

        return lane
    }

    private static func readStep(_ step: Step, _ tokens: [String], _ number: Int,
                                 _ version: Int) throws {
        for token in tokens.dropFirst() {
            if let tile = try readTile(token, number, version) { step.tiles.append(tile) }
        }
    }

    private static func readTile(_ token: String, _ number: Int, _ version: Int) throws -> Tile? {
        let colon = token.firstIndex(of: ":")
        let head = colon.map { String(token[..<$0]) } ?? token
        let args = colon.map { String(token[token.index(after: $0)...]) } ?? ""

        switch head {
        case "PABS":
            return try readLock(AbsoluteParamTile(), args, number, version)
        case "PREL", "PACC":
            // PACC was retired; it reads as the relative lock it most resembles.
            return try readLock(RelativeParamTile(), args, number, version)
        case "GCYC":
            let parts = args.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let gate = CycleGateTile()
            if parts.count > 0 { gate.period = readInt(parts[0]) }
            if parts.count > 1 { readLaps(gate, parts[1]) }
            return gate
        case "GPRB":
            return ProbGateTile(percent: readFloat(args))
        case "JUMP":
            return JumpTile()
        default:
            break
        }

        let slash = token.firstIndex(of: "/")
        let name = slash.map { String(token[..<$0]) } ?? token

        guard let note = Pitch.parse(name) else {
            throw ProjectFormatError(line: number, message: "cannot read the tile " + token)
        }

        let length = slash.map { readFloat(String(token[token.index(after: $0)...])) } ?? 1
        return NoteTile(note: note, length: length)
    }

    // A pattern as long as the period, or an older single lap number.
    private static func readLaps(_ gate: CycleGateTile, _ text: String) {
        if text.count == gate.period && text.allSatisfy({ $0 == "0" || $0 == "1" }) {
            gate.pattern = text
            return
        }
        gate.pattern = ""
        gate.setFires(readInt(text), true)
    }

    // Targets that have left ParamTargets, which a file may still name.
    static let retired = ["detune", "cardecay", "carsustain"]

    private static func readLock(_ tile: ParamTile, _ args: String, _ number: Int,
                                 _ version: Int) throws -> ParamTile? {
        if args.isEmpty { return tile }

        let parts = args.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < parts.count {
            defer { i += 2 }

            let target = ParamTargets.parse(parts[i])
            if target < 0 {
                if !retired.contains(parts[i]) {
                    throw ProjectFormatError(line: number, message: "unknown lock target " + parts[i])
                }
                continue
            }

            var value: Float = i + 1 < parts.count ? readFloat(parts[i + 1]) : 0

            if version < 10 && target == ParamTargets.modDecay && tile is AbsoluteParamTile {
                value = decaySlope(value)
            }
            if version < 18 && target == ParamTargets.level && tile is AbsoluteParamTile {
                value = decibels(value)
            }

            tile.engage(target, value)
        }

        return tile.isEmpty ? nil : tile
    }

    private static func readPatchLine(_ project: Project, _ tokens: [String], _ version: Int) {
        if tokens.count > 1 && !tokens[1].contains("=") {
            let channel = PatchBank.clamp(readInt(tokens[1]))
            var patch = project.patches[channel]
            readPatch(&patch, tokens, 2, version)
            project.patches[channel] = patch
            return
        }

        // An older file has one patch line for every channel.
        for channel in 1...PatchBank.channels {
            var patch = project.patches[channel]
            readPatch(&patch, tokens, 1, version)
            project.patches[channel] = patch
        }
    }

    // Version 10: the FM decay became a slope. Converts a time to the same rate.
    private static func decaySlope(_ seconds: Float) -> Float { seconds / (5 * 0.1 + seconds) }

    private static func readPatch(_ patch: inout FmPatch, _ tokens: [String], _ from: Int,
                                  _ version: Int) {
        for token in tokens.dropFirst(from) {
            let (key, text) = split(token)
            let value = readFloat(text)

            switch key {
            case "transpose": patch.transpose = value
            case "level": patch.level = version < 18 ? decibels(value) : value
            case "pan": patch.pan = value
            case "uni": patch.unison = value
            case "gate": patch.gateScale = value
            case "mratio": patch.modulatorRatio = value
            case "index": patch.modulationIndex = value
            case "fb": patch.feedback = value
            case "md": patch.modulatorDecay = version < 10 ? decaySlope(value) : value
            case "ca": patch.carrierAttack = value
            case "cr": patch.carrierRelease = value
            case "ps": patch.pitchSweep = value
            case "pd": patch.pitchDecay = value
            case "rsend": patch.reverbSend = value
            case "dsend": patch.delaySend = value
            default: break
            }
        }
    }

    private static func readFx(_ fx: inout SendFx, _ tokens: [String], _ version: Int) {
        for token in tokens.dropFirst() {
            let (key, text) = split(token)
            let value = readFloat(text)

            switch key {
            case "rsize": fx.reverbSize = value
            case "rtone": fx.reverbTone = value
            case "rspread": fx.reverbSpread = value
            case "rdamp": fx.reverbTone = 1 - value
            case "rwidth": fx.reverbSpread = value
            case "dbeats": fx.delayBeats = value
            case "dfb": fx.delayFeedback = value
            case "dspread": fx.delaySpread = value
            case "dtone": fx.delayTone = version < 19 ? 1 - value : value
            default: break
            }
        }
    }

    private static func readLimiter(_ limiter: inout Limiter, _ tokens: [String], _ version: Int) {
        var drive: Float = 0

        for token in tokens.dropFirst() {
            let (key, text) = split(token)
            let value = readFloat(text)

            switch key {
            case "drive": drive = value
            case "ceiling": limiter.ceiling = value
            case "attack": limiter.attack = value
            case "release": limiter.release = value
            default: break
            }
        }

        if version < 13 { limiter.ceiling = limiterSqueeze(limiter.ceiling, drive) }
    }

    private static func limiterSqueeze(_ ceiling: Float, _ drive: Float) -> Float {
        min(max(ceiling - drive, Limiter.minCeiling), 0)
    }

    // 20 log10(0.8 / 0.25): the quarter-scale staging of version 17.
    private static let stagedHeadroom: Float = 10.103

    private static func decibels(_ amplitude: Float) -> Float {
        amplitude <= 0 ? FmPatch.minLevel : 20 * log10f(amplitude)
    }

    // Version 18: the level went to decibels, and a relative level lock is converted
    // against the level of the channel it stands on, after the whole file is read.
    private static func levelShifts(_ project: Project) {
        let score = project.score

        for lane in score.lanes {
            let basis = FmPatch.amplitude(project.patches[score.channelOf(lane)].level)

            for step in lane.steps {
                for case let shift as RelativeParamTile in step.tiles
                where shift.isEngaged(ParamTargets.level) {
                    shift.engage(ParamTargets.level, levelShift(basis, shift[ParamTargets.level]))
                }
            }
        }
    }

    private static func levelShift(_ basis: Float, _ shift: Float) -> Float {
        decibels(min(max(basis + shift, 0), 1)) - decibels(basis)
    }

    private static func stagedThreshold(_ ceiling: Float) -> Float {
        min(max(ceiling - stagedHeadroom, Limiter.minCeiling), 0)
    }

    private static func readMutes(_ mutes: ChannelMutes, _ tokens: [String]) {
        for token in tokens.dropFirst() {
            let (key, text) = split(token)
            let muted = key == "muted"
            if !muted && key != "soloed" { continue }

            for (i, c) in text.prefix(PatchBank.channels).enumerated() {
                if muted { mutes.setMuted(i + 1, c == "1") } else { mutes.setSoloed(i + 1, c == "1") }
            }
        }
    }

    private static func readScale(_ scale: Scale, _ tokens: [String]) {
        for token in tokens.dropFirst() {
            let (key, text) = split(token)
            if key != "notes" { continue }
            for (degree, c) in text.prefix(Scale.degrees).enumerated() {
                scale.setAllowed(degree, c == "1")
            }
        }
    }

    // MARK: Tokens

    private static func split(_ token: String) -> (String, String) {
        guard let equals = token.firstIndex(of: "=") else { return (token, "") }
        return (String(token[..<equals]), String(token[token.index(after: equals)...]))
    }

    private static func arg(_ tokens: [String], _ index: Int, _ number: Int) throws -> String {
        guard index < tokens.count else {
            throw ProjectFormatError(line: number, message: "missing argument")
        }
        return tokens[index]
    }

    private static func readPoint(_ text: String, _ number: Int) throws -> GridPoint {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ProjectFormatError(line: number, message: "expected x,y")
        }
        return GridPoint(readInt(String(parts[0])), readInt(String(parts[1])))
    }

    private static func readInt(_ text: String) -> Int { Int(text) ?? 0 }

    private static func readFloat(_ text: String) -> Float {
        guard let value = Float(text), value.isFinite else { return 0 }
        return value
    }
}
