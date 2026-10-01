# Amber FM verification

Verified on the development Mac on October 1, 2026.
The release app is `build/AmberFM.app`.

## Results

- Release compilation, bundle validation, and local ad-hoc signing passed.
- Independent DSP signal, stability, concurrent event, and render-allocation checks passed.
- Preset persistence, validation, recovery, preferences, and production MIDI parser checks passed.
- Real CoreMIDI injection into AVAudioEngine passed with 44.1 kHz output and observed 128-frame callbacks.
- Native interface checks covered playing and releasing notes, exact parameter entry, saving and renaming, cold-start restoration, hints, and keyboard visibility.
- Independent source reviews and UndefinedBehaviorSanitizer passed.

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
