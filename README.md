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
| `Assets/Jacquard/UI` (UI Toolkit) | `Jacquard/App` — so far the plane (tiles, icons, rails, links, playheads), transport, live FX and mutes |
| `Assets/Jacquard/Scores` | `Jacquard/Scores` — the five bundled sample scores, unchanged |

The upstream code carries its reasoning in its comments. The port keeps shorter versions
of them and names the file each one came from, so the original is the place to read the
full argument.

## Not ported yet

- Editing: placing, dragging and deleting tiles and lanes, and the tile inspector
- The Sound, Send FX, Global, Channels and System panels
- Saving to and loading from the Files app score folder; onboarding; Stage Mode
- Measured clock calibration (`DspClock`); the driver uses a fixed lead of two IO buffers

## Building

Open `Jacquard.xcodeproj` in Xcode 26 and run the `Jacquard` scheme (iOS 18+). The
visualizer's shader is `Jacquard/Visual/Visualizer.metal`, which needs Xcode's Metal
Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).

On a simulator, `-load sample1 -autoplay` as launch arguments loads a bundled score
and presses Play.

`Tools/core-check.sh` compiles the core for the Mac and checks every bundled score
round-trips byte-identical and plays.

## License

MIT, as upstream. Jacquard is © 2026 Keijiro Takahashi; see `LICENSE`. The Jura font
is under the SIL Open Font License (`Jacquard/Fonts/Jura-OFL.txt`).
