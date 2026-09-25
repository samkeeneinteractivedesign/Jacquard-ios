# Jacquard for iOS

A native iOS port of [keijiro/Jacquard](https://github.com/keijiro/Jacquard), the
tile-based music sequencer, in Swift, SwiftUI and Metal. The original is a Unity 6.6
project; this port follows its code file for file and keeps its file format, so a
`.jacquard` score written by either app opens in the other.

Ported from upstream commit `5f02d3d` (2026-09-15).

## What is here

| Upstream (Unity, C#) | Here (Swift) |
| --- | --- |
| `Assets/Core/Model` | `Jacquard/Core/Model` — pitch, scale, tiles, lanes, score, project |
| `Assets/Core/Serialization/ProjectFormat.cs` | `Jacquard/Core/Serialization/ProjectFormat.swift`, including the old-version conversions |
| `Assets/Core/Sequencer` | `Jacquard/Core/Sequencer` — runners, the downward pass, locks, the turn of the piece, live FX |
| `Assets/Core/Synth` | `Jacquard/Core/Synth` — `FmPatch`, `ParamTargets`, `FastMath`, bank, limiter and send settings |
| `Assets/Jacquard/Audio` (Burst job on the Scriptable Audio Pipeline) | `Jacquard/Audio` — the same voice, pool, reverb, delay, limiter and soft clip, driven by an `AVAudioSourceNode` |
| `Assets/Jacquard/Visual` (URP mesh) | `Jacquard/Visual` — the same two scope traces, drawn in an `MTKView` |
| `Assets/Jacquard/App` | `Jacquard/App` — the engine loop, `ScoreEditor`, `ProjectStore`, and the machine settings |
| `Assets/Jacquard/UI` (UI Toolkit) | `Jacquard/UI` — the plane and its gestures, value bars, the Tile panel, and the Channels, Send FX, Live FX, Global and System panels |
| `Assets/Jacquard/Scores` | `Jacquard/Scores` — the five bundled sample scores, unchanged |

The upstream code carries its reasoning in its comments. The port keeps shorter versions
of them and names the file each one came from, so the original is the place to read the
full argument.

## Using it

The gestures follow the original's manual (`Docs/manual.md` upstream): tap a cell to
move the cursor, and the Tile panel on the right offers what that cell will take. Drag a
tile to move it and what hangs below it, drag a `CHAN` or `JDST` cell to move its lane,
drag free ground to pan. Double tap a tile to copy its stack, double tap a free cell to
paste it, double tap a `CHAN` to start or stop its lane. Drag a bar right or up to set
it; double tap it to type a number; double tap a row's name to take it back. With a
hardware keyboard the arrows, delete, return and space work as on the desktop.

Scores live in `Documents/Scores`, which the Files app shows under On My iPhone (or iPad)
› Jacquard. A fresh install writes the five samples and nine empty slots there, as the
original does, and pick one with the arrows beside Save and Load.

## Not ported yet

- The three onboarding pages shown on first launch
- Measured clock calibration (`DspClock`); the driver uses a fixed lead of two IO buffers
- On a phone the panel columns overlap one another; the layout is the tablet's

## Building

Open `Jacquard.xcodeproj` in Xcode 26 and run the `Jacquard` scheme (iOS 18+). The
visualizer's shader is `Jacquard/Visual/Visualizer.metal`, which needs Xcode's Metal
Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).

On a simulator, `-load sample1 -autoplay` as launch arguments loads a score from the
folder and presses Play, and `-panels live,system` opens panels.

`Tools/core-check.sh` compiles the core for the Mac and checks every bundled score
round-trips byte-identical and plays.

## License

MIT, as upstream. Jacquard is © 2026 Keijiro Takahashi; see `LICENSE`. The Jura font
is under the SIL Open Font License (`Jacquard/Fonts/Jura-OFL.txt`).
