# FM Synth verification

Verified on the development Mac on October 1, 2026.
The release app is `build/FM Synth.app`.

## Results

- Release compilation, bundle validation, and local ad-hoc signing passed.
- Independent DSP signal, stability, concurrent event, and render-allocation checks passed.
- Preset persistence, validation, recovery, preferences, and production MIDI parser checks passed.
- Real CoreMIDI injection into AVAudioEngine passed with 44.1 kHz output and observed 128-frame callbacks.
- Native interface checks covered playing and releasing notes, exact parameter entry, saving and renaming, cold-start restoration, hints, and keyboard visibility.
- Independent source reviews and UndefinedBehaviorSanitizer passed.

## Interface revision

The FM Synth rename preserves the existing bundle identifier, preference domain, and preset storage location.
The release build completes without compiler warnings and passes bundle validation and signature verification.
The bundled `--self-test` passes preset persistence, preferences, validation, and MIDI parsing checks.
The bundled `--hint-self-test` passes native dwell timing, redraw persistence, click release, cancellation, placement, and passive-input checks.
The user confirmed that a real mouse hover shows an explanation and keeps it visible in the rebuilt app.
The original macOS `.help` failure mechanism was not conclusively isolated; the replacement uses explicit AppKit tracking and presentation.

Native interface checks verified the fullscreen keyboard fills the spare height, the compact window fits without scrolling, and keyboard hiding and showing resize the window.
All visible keys show note names and octaves, with smaller boxed typing shortcuts.
The displayed range follows octave changes so every typing shortcut remains visible.
The library search matched the bass category, the My Sounds filter retained Warm Tines, and loading a search result restored typing controls.
Audio starts successfully at 44.1 kHz with 128-frame buffers.
Independent source review found no new audio-thread work or polling introduced by the hint system.
The DSP implementation is unchanged by this interface revision; the benchmark below belongs to the original engine verification.

## Final processing benchmark

The release harness measured 6,000 callbacks per case at 48 kHz with 128-frame buffers.
Each callback has 2,666.67 microseconds available.

| Case | Median | p99 | Maximum | p99 budget | Maximum budget |
| --- | ---: | ---: | ---: | ---: | ---: |
| Idle, effects bypassed | 10.96 us | 13.88 us | 70.58 us | 0.52% | 2.65% |
| 8 voices, five effects | 25.75 us | 34.71 us | 87.42 us | 1.30% | 3.28% |
| 24 voices, five effects | 44.96 us | 137.38 us | 2,028.71 us | 5.15% | 76.08% |

All performance thresholds passed, and every render call was checked for C++ `new`/`new[]` allocations.
Timing includes scheduler interruptions and does not guarantee a hard realtime deadline under every system load.
The live DSP percentage measures callback processing time, not whole-app CPU use.
The 128-frame output buffer is not a measurement of total key-to-sound latency.

## Verification limits

Physical Yamaha testing is deferred at the user's request until an adapter is available.
Physical output-device unplug/replug and loopback latency remain unverified.
AddressSanitizer and ThreadSanitizer aborted before `main` on this host, including independent minimal programs; neither is claimed as a passed check.
Two-times oversampling reduces aliasing, but extreme modulation settings can still alias.

The completion ledger records 15 met gates, 0 unmet gates, and 1 abandoned gate for the explicitly deferred physical Yamaha check.
