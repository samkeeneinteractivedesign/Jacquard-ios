#!/bin/sh
# Compiles the engine-free core (model, format, sequencer, synth settings) for the Mac
# and checks it against the bundled scores: every file is read, written back
# byte-identical to what the Unity app wrote, and played for thirty seconds.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${TMPDIR:-/tmp}/jacquard-core-check"
swiftc -O $(find "$root/Jacquard/Core" -name '*.swift') "$root/Tools/CoreCheck/main.swift" -o "$out"
"$out" "$root/Jacquard/Scores"
