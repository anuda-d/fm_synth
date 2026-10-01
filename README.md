# Amber FM

Amber FM is a standalone FM synthesizer for macOS 14 or later.
Play it with a MIDI keyboard, your computer keyboard, or the on-screen keys.

- Two sine operators, 24 voices, and separate volume and modulation envelopes.
- Distortion, chorus, phaser, stereo delay, and reverb.
- Six factory sounds, including electric piano, bass, lead, pad, bell, and pure sine.
- Save, rename, and update your own presets locally.
- MIDI velocity, sustain pedal, and pitch bend support.

## Build and run

Requires Apple's Swift/C++ toolchain from Xcode or the Command Line Tools.
Run these commands from the project folder:

```sh
bash scripts/build-app.sh
open build/AmberFM.app
```

Click **Start audio**, choose a preset, and play.
Use **A W S E D F T G Y H U J K O L P ;** for notes, **Z / X** to change octaves, and **Escape** to release all notes.
Drag knobs to adjust the sound and use **Save As** to keep a preset.
