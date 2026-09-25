import Foundation
let dir = CommandLine.arguments[1]
for i in 1...5 {
    let text = try! String(contentsOfFile: "\(dir)/sample\(i).jacquard", encoding: .utf8)
    let p = try! ProjectFormat.read(text)
    let w = ProjectFormat.write(p)
    let p2 = try! ProjectFormat.read(w)
    let w2 = ProjectFormat.write(p2)
    let seq = Sequencer(); seq.project = p
    var out: [FmNoteEvent] = []
    seq.play(currentSample: 0, lookaheadSamples: 0)
    let rate = 48000
    var t: Int64 = 0
    while t < Int64(rate * 30) { seq.schedule(currentSample: t, lookaheadSamples: 5760, sampleRate: rate, output: &out); t += 800 }
    let norm = { (s: String) in s.split(separator: "\n").map { String($0) } }
    let orig = norm(text), mine = norm(w)
    let diff = zip(orig, mine).filter { $0 != $1 }
    print("sample\(i): lanes=\(p.score.lanes.count) roundtrip-stable=\(w == w2) linesDiffFromOriginal=\(diff.count)/\(orig.count) notes30s=\(out.count) master=\(seq.masterRunner?.pass ?? -1) laps")
    for d in diff.prefix(3) { print("  orig: \(d.0)\n  mine: \(d.1)") }
}
// sample project from code
let s = Project.createSample(); let seq = Sequencer(); seq.project = s
var out: [FmNoteEvent] = []; seq.play(currentSample: 0, lookaheadSamples: 0)
var t: Int64 = 0; while t < 48000*8 { seq.schedule(currentSample: t, lookaheadSamples: 5760, sampleRate: 48000, output: &out); t += 800 }
print("createSample: notes in 8s=\(out.count)")
print(ProjectFormat.write(s).split(separator:"\n").suffix(8).joined(separator:"\n"))
