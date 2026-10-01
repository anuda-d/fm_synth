#!/bin/bash
set -euo pipefail

synth_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
synth_output="$synth_root/build/midi-tests"
export DEVELOPER_DIR="${MIDI_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
synth_sdk="$(/usr/bin/xcrun --show-sdk-path)"
synth_cxx="${MIDI_CXX:-$DEVELOPER_DIR/usr/bin/clang++}"
synth_swift="${MIDI_SWIFTC:-$DEVELOPER_DIR/usr/bin/swiftc}"

mkdir -p "$synth_output"
"$synth_cxx" -std=c++17 -O2 -mmacosx-version-min=14.0 -isysroot "$synth_sdk" \
    -I "$synth_root/src/CDSP/include" -c "$synth_root/src/CDSP/FMSynth.cpp" \
    -o "$synth_output/FMSynth.o"
"$synth_swift" -parse-as-library -O -sdk "$synth_sdk" \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$synth_root/build/ModuleCache" \
    -I "$synth_root/src/CDSP/include" "$synth_root/src/AmberFM/AudioController.swift" \
    "$synth_root/scripts/midi-probe.swift" "$synth_output/FMSynth.o" -lc++ \
    -o "$synth_output/midi-probe"

# Uses the real default output and a temporary CoreMIDI source. Notes are quiet.
# Failure to access an output device is a failed test, never a simulated pass.
"$synth_output/midi-probe"
