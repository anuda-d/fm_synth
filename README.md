# FM Synth

FM Synth is a standalone FM synthesizer for macOS 14 or later.
Play it with a MIDI keyboard, your computer keyboard, or the on-screen keys.

- Two sine operators, 24 voices, and separate volume and modulation envelopes.
- Distortion, chorus, phaser, stereo delay, and reverb.
- Six factory sounds, including electric piano, bass, lead, pad, bell, and pure sine.
- Search factory sounds and your saved sounds in the sound library popover.
- Save, rename, and update your own presets locally.
- On-screen note names and boxed computer-key shortcuts.
- Optional hover explanations and popovers for exact parameter values.
- MIDI velocity, sustain pedal, and pitch bend support.

## Build and run

Requires Apple's Swift/C++ toolchain from Xcode or the Command Line Tools.
Run these commands from the project folder:

```sh
bash scripts/build-app.sh
open "build/FM Synth.app"
```

Click **Start audio**, choose a preset, and play.
Use **A W S E D F T G Y H U J K O L P ;** for notes, **Z / X** to change octaves, and **Escape** to release all notes.
Open **Sound Library** to search by name or category and switch between factory sounds and your own sounds.
Drag knobs to adjust the sound, hold Shift for fine control, or click a value to enter it precisely.
Use **Save As** to keep a new sound and **Save** to update an edited personal sound.
The **Hints** switch turns hover explanations on or off.
Keyboard labels show musical note names; boxed letters show the corresponding typing keys.

## Existing sounds and preferences

FM Synth keeps the original app identity and continues using `~/Library/Application Support/AmberFM/session.json`.
Saved presets, your current sound, master volume, keyboard visibility, and hover explanation preferences remain available after the rename.
