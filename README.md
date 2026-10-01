# Amber FM

A native macOS instrument for exploring FM synthesis, with a warm analog interface and an independently tested C++ audio engine.
It runs locally without a DAW, browser, network service, or third-party package dependencies.

## Play

Open `build/AmberFM.app`, click **Start audio**, and choose a sound from the library.
Use a connected MIDI keyboard, click the on-screen keys, or play the computer keyboard with **A W S E D F T G Y H U J K O L P ;**.
**Z / X** move the computer keyboard down or up an octave.
**Escape** releases all sounding notes; existing reverb and delay tails finish naturally.

Drag knobs vertically and hold **Shift** for fine adjustments.
Click a knob's numeric value to enter an exact value, or double-click the knob to reset it.
Arrow keys and accessibility increment/decrement actions adjust a focused knob.
The **Hints** switch controls hover explanations.
**Hide keyboard**, or **Command-K**, collapses the keyboard and remembers the preference.

Factory sounds cover electric piano, bass, gritty lead, atmospheric pad, bell, and a pure sine starting point.
**Save As** creates a local user preset containing the FM and effect settings.
The preset actions menu can update, rename, delete, or revert a saved sound.
Master volume is kept separately so changing presets does not jump the output level.
The current edit and preset library are written atomically to `~/Library/Application Support/AmberFM/session.json`.
Malformed sessions are preserved in a recovery copy; if backup fails, further writes are suspended to protect the original.

## Yamaha PSR-I425

The Yamaha supplies MIDI note and controller messages; Amber generates its own audio through the Mac's selected output.
CoreMIDI sources connect automatically and the footer reports available inputs.
Velocity, sustain pedal, pitch bend with a fixed two-semitone range, and per-channel note controls are supported.

The PSR-I425 manual specifies Yamaha's USB-MIDI driver and Keyboard Out enabled.
Its PC2 setting uses Local Off and Keyboard Out On, allowing the keys to control software without also sounding the Yamaha internally.
See the [Yamaha manual](https://usa.yamaha.com/files/download/other_assets/0/335670/psri425_en_om_a0.pdf) and [official Mac driver](https://usa.yamaha.com/support/updates/usb_midi_driver_for_mac.html).
The physical Yamaha connection is intentionally unverified until the required adapter is available.

## Build

Requires macOS 14 or newer and an installed Apple Swift/C++ toolchain.
The script uses the installed Command Line Tools when `DEVELOPER_DIR` has not been set.
It does not accept Xcode licenses or change the system's selected developer directory.

```sh
bash scripts/build-app.sh
```

The output is a locally ad-hoc-signed application at `build/AmberFM.app`.
This is a local development build, not a notarized distribution for other Macs.
Apple's `iconutil` and native audio/MIDI services need access to host services; restrictive command sandboxes can prevent them from working even when the input files are valid.

## Engine and performance

`Sources/CDSP/FMSynth.cpp` implements two sine operators using phase modulation, the conventional digital implementation of FM synthesis.
The core voice is `A(t) × sin(carrierPhase + I(t) × sin(modulatorPhase))`, with independent volume and modulation envelopes.
Pitch uses equal temperament around A4 = 440 Hz.
Twenty-four voices support chords, with eight short, bounded release tails to soften voice stealing.

Oscillators and distortion run at twice the output sample rate, followed by a 31-tap windowed-sinc decimation filter.
An interpolated sine table reduces per-sample transcendental calculations.
Parameter and pitch-bend smoothing reduce discontinuities.
All audio storage is allocated before rendering, and a bounded multi-producer event queue connects controls to the audio thread.
The callback contains no blocking locks, file I/O, logging, or heap allocation.
Telemetry uses lock-free atomics, with the interface refreshed at 25 Hz.

The fixed effects order is distortion, chorus, phaser, stereo delay, then an eight-line feedback reverb.
Every effect is independently bypassable while retaining its settings.
The DSP meter shows rendering time as a percentage of the callback deadline, not total Mac CPU usage or end-to-end latency.
The engine requests a 128-frame buffer through its own output AudioUnit and gracefully retains the supported size if the request is rejected.
The output panel reports the actual callback size.
On the development Mac this reduced the observed render quantum from 512 to 128 frames at 44.1 kHz, or 2.90 ms of audio per callback.
This does not remove the output device's own latency and is not a measured key-to-sound latency claim.
Oversampling reduces aliasing, but extreme FM ratios and modulation amounts are not fully band limited.

## Verification

```sh
bash scripts/test-dsp.sh
bash scripts/test-dsp.sh --ubsan --no-benchmark
build/AmberFM.app/Contents/MacOS/AmberFM --self-test
bash scripts/test-midi.sh
```

The DSP harness checks silence, pitch, sine purity, Bessel-predicted FM sidebands, envelopes, velocity, chords, sustain, pitch bend, channel isolation, queue overflow, voice stealing, effect signatures and tails, sample-rate behavior, block-size consistency, concurrent producers, and C++ render allocations.
Its release benchmark measures 6,000 callbacks per case at 48 kHz and 128 frames, including 24 voices with all five effects.
It requires p99 processing below 25% of the callback budget and the observed maximum below the full deadline.
These are measured host results, not a hard realtime scheduling guarantee.

The model self-test verifies saved sounds, renamed and updated presets, preferences, invalid-data recovery, and the production MIDI parser.
The MIDI integration probe creates a temporary CoreMIDI source and exercises the real AVAudioEngine at quiet volume, including rendered pitch measurements, sustain, channel controls, audio restart, and device-disconnect cleanup.
It fails if native services or an audio output are unavailable.

On the development host, UndefinedBehaviorSanitizer and concurrent stress pass.
AddressSanitizer and ThreadSanitizer abort before `main`, including in independent minimal programs, so they are not claimed as successful checks.
Their optional script modes remain available for compatible toolchains.
Physical keyboard input, physical output-device unplug/replug, and loopback key-to-sound latency need hardware verification.

Recording, DAW plug-in packaging, and additional operator topologies are future work.
