import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: SynthModel
    @State private var presetSheet: PresetAction?
    @State private var presetName = ""
    @State private var confirmDelete = false
    @State private var libraryShown = false

    enum PresetAction: String, Identifiable { case save, rename; var id: String { rawValue } }

    var body: some View {
        HStack(spacing: 0) {
            WoodRail()
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.line).frame(height: 1)
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        InstrumentLayout(availableHeight: viewport.size.height - 16) {
                            VStack(spacing: 12) {
                                presetBar
                                HStack(alignment: .top, spacing: 14) {
                                    OperatorPanel(modulator: false).frame(maxWidth: .infinity)
                                    OperatorPanel(modulator: true).frame(maxWidth: .infinity)
                                    OutputPanel(audio: model.audio).frame(width: 270)
                                }
                                effectsRack
                            }
                            if model.showKeyboard { InstrumentKeyboard(audio: model.audio) }
                        }.padding(.horizontal, 18).padding(.vertical, 8)
                    }
                }
                footer
            }.background(Palette.cream)
            WoodRail()
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.wood)
        .frame(minWidth: 1100, minHeight: 650)
        .preferredColorScheme(.light)
        .sheet(item: $presetSheet) { action in
            PresetNameSheet(action: action, name: $presetName,
                            cancel: { presetSheet = nil }, commit: { commitPreset(action) })
        }
        .alert("Delete this preset?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deletePreset() }
        } message: { Text("“\(model.patch.name)” will be removed from your saved sounds.") }
        .alert("FM Synth", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.releaseLocalNotes() }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Screw()
            Text("FM Synth").font(.system(size: 32, weight: .medium, design: .serif)).tracking(-1)
            Rectangle().fill(Palette.line).frame(width: 1, height: 28).padding(.horizontal, 4)
            Text("TWO OPERATOR SYNTHESIZER")
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5)
                .foregroundStyle(Palette.secondary)
            Spacer()
            Toggle(isOn: $model.showHints) { Text("Hints").font(.system(size: 11)) }
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
                .accessibilityIdentifier("showHintsToggle")
                .hint("Show or hide short explanations when you hover over a control.", enabled: model.showHints)
            AudioPowerButton(audio: model.audio)
            Screw()
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var presetBar: some View {
        HStack(spacing: 10) {
            Button { libraryShown.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SOUND LIBRARY").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1)
                            .foregroundStyle(Palette.secondary)
                        HStack(spacing: 7) {
                            Text(model.patch.name).font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(1)
                            if model.dirty {
                                Circle().fill(Palette.orange).frame(width: 5, height: 5).accessibilityLabel("Edited")
                            }
                        }
                    }
                    Spacer(minLength: 16)
                    Text(model.patch.category).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 13).frame(height: 48)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(libraryShown ? Palette.orange : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Browse sounds: \(model.patch.name)")
            .accessibilityIdentifier("soundLibraryButton")
            .popover(isPresented: $libraryShown, arrowEdge: .bottom) {
                SoundLibraryBrowser().environmentObject(model)
            }
            HStack(spacing: 3) {
                Button { model.adjacentPreset(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous sound")
                Button { model.adjacentPreset(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next sound")
            }.buttonStyle(InstrumentButtonStyle())
            if !model.patch.isFactory {
                Button("SAVE") { model.updatePreset() }
                    .buttonStyle(InstrumentButtonStyle(accent: model.dirty)).disabled(!model.dirty)
                    .accessibilityLabel("Save changes to current sound")
            }
            Button("SAVE AS…") { presetName = model.patch.name + (model.patch.isFactory ? " edit" : " copy"); presetSheet = .save }
                .buttonStyle(InstrumentButtonStyle()).accessibilityIdentifier("savePresetButton")
            Menu {
                Button("Revert to saved sound") {
                    if let original = model.patches.first(where: { $0.id == model.selectedID }) { model.select(original) }
                }.disabled(!model.dirty)
                if !model.patch.isFactory {
                    Divider()
                    Button("Rename…") { presetName = model.patch.name; presetSheet = .rename }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 25) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Sound actions")
        }
    }

    private var effectsRack: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("EFFECTS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.8)
                Rectangle().fill(Palette.line).frame(height: 1)
                Text("DISTORTION  ›  CHORUS  ›  PHASER  ›  DELAY  ›  REVERB")
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(Palette.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(Effect.allCases, id: \.self) { effect in EffectPanel(effect: effect).frame(maxWidth: .infinity) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            MIDIStatus(audio: model.audio)
            Spacer()
            Text("SHIFT + DRAG FOR FINE CONTROL").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.5).foregroundStyle(Palette.secondary)
            Button { model.releaseAll() } label: { Text("ALL NOTES OFF").font(.system(size: 9, weight: .medium, design: .monospaced)) }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).accessibilityLabel("All notes off")
                .hint("Release all sounding notes if a note gets stuck. Existing echoes and reverb can finish naturally. Escape is the shortcut.", enabled: model.showHints)
            Divider().frame(height: 14)
            Button { model.showKeyboard.toggle() } label: {
                Label(model.showKeyboard ? "Hide keyboard" : "Show keyboard", systemImage: "pianokeys")
                    .font(.system(size: 11))
            }.buttonStyle(.plain).accessibilityIdentifier("toggleKeyboardButton")
        }.padding(.horizontal, 22).padding(.vertical, 11)
            .background(Palette.panel.opacity(0.5))
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func commitPreset(_ action: PresetAction) {
        guard !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if action == .save { model.savePreset(name: presetName) }
        else { model.renamePreset(name: presetName) }
        presetSheet = nil
    }
}

/// Measure the controls once per layout pass, then give the keyboard all
/// remaining height. No state feedback loop or fixed screen-size assumptions.
private struct InstrumentLayout: Layout {
    var availableHeight: CGFloat
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1100
        let controls = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let minimum = controls.height + (subviews.count > 1 ? spacing + 128 : 0)
        return CGSize(width: width, height: subviews.count > 1 ? max(minimum, availableHeight) : minimum)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let controls = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: controls.height))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + controls.height + spacing),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width,
                                  height: max(128, bounds.height - controls.height - spacing)))
        }
    }
}

private struct PresetNameSheet: View {
    let action: ContentView.PresetAction
    @Binding var name: String
    let cancel: () -> Void
    let commit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action == .save ? "Save your sound" : "Rename preset")
                .font(.system(size: 22, weight: .medium, design: .serif))
            Text(action == .save ? "Save the current FM and effect settings as a new preset." : "Choose a new name for this preset.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("presetNameField").onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(action == .save ? "Save preset" : "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 400).background(Palette.panel)
    }
}

struct AudioPowerButton: View {
    @ObservedObject var audio: AudioController
    var body: some View {
        Button { if audio.isRunning { audio.stop() } else { audio.start() } } label: {
            HStack(spacing: 8) {
                Circle().fill(audio.isRunning ? Color(hex: 0xCAE8B4) : Palette.secondary).frame(width: 6, height: 6)
                Text(audio.isRunning ? "AUDIO ON" : "START AUDIO")
            }
        }.buttonStyle(InstrumentButtonStyle(accent: audio.isRunning))
            .accessibilityIdentifier("audioPowerButton")
            .accessibilityLabel(audio.isRunning ? "Stop audio" : "Start audio")
    }
}

struct OperatorPanel: View {
    @EnvironmentObject var model: SynthModel
    let modulator: Bool
    private var parameters: [Parameter] {
        modulator ? [.modAttack, .modDecay, .modSustain, .modRelease] : [.ampAttack, .ampDecay, .ampSustain, .ampRelease]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(modulator ? "02" : "01").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.orange)
                Text(modulator ? "Modulator" : "Carrier").font(.system(size: 21, weight: .medium, design: .serif))
                Spacer()
                Text(modulator ? "SHAPES THE TONE" : "MAKES THE NOTE")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced)).tracking(0.5).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 20) {
                Knob(title: "RATIO", parameter: modulator ? .modRatio : .carrierRatio,
                     value: model.binding(modulator ? .modRatio : .carrierRatio), diameter: 68, hints: model.showHints)
                if modulator {
                    Knob(title: "FM AMOUNT", parameter: .modIndex, value: model.binding(.modIndex), diameter: 68, hints: model.showHints)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SINE WAVE").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Palette.secondary)
                        SineIllustration().stroke(Palette.orange.opacity(0.8), lineWidth: 1.5).frame(height: 27)
                        Text("Modulator → Carrier → Effects").font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 94)
            HStack {
                Text(modulator ? "TONE ENVELOPE" : "VOLUME ENVELOPE").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Palette.secondary)
                Rectangle().fill(Palette.line.opacity(0.7)).frame(height: 1)
            }
            EnvelopeDisplay(attack: model.value(parameters[0]), decay: model.value(parameters[1]), sustain: model.value(parameters[2]), release: model.value(parameters[3]))
                .frame(height: 35)
            HStack(spacing: 0) {
                ForEach(Array(zip(["ATTACK", "DECAY", "SUSTAIN", "RELEASE"], parameters)), id: \.1) { title, parameter in
                    Knob(title: title, parameter: parameter, value: model.binding(parameter), diameter: 45, hints: model.showHints).frame(maxWidth: .infinity)
                }
            }
        }.etchedPanel()
    }
}

struct SineIllustration: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...100 {
            let x = Double(i) / 100
            let point = CGPoint(x: x * rect.width, y: rect.midY - sin(x * .pi * 4) * rect.height * 0.42)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct OutputPanel: View {
    @EnvironmentObject var model: SynthModel
    @ObservedObject var audio: AudioController
    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("OUTPUT").tracking(1.8)
                    Spacer()
                    Circle().fill(audio.isRunning ? Palette.amber : Palette.secondary).frame(width: 4, height: 4)
                    Text(audio.isRunning ? "LIVE" : "STANDBY")
                }.font(.system(size: 9, weight: .medium, design: .monospaced))
                WaveformDisplay(samples: audio.waveform, running: audio.isRunning).frame(height: 76)
                HStack(spacing: 2) {
                    ForEach(0..<30) { index in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(Float(index) / 30 < min(1, audio.peakLevel) ? (index > 25 ? Palette.orange : Palette.amber) : Palette.screenText.opacity(0.11))
                            .frame(height: 4)
                    }
                }
                HStack {
                    Text(String(format: "%02d VOICES", audio.activeVoices))
                    Spacer()
                    Text(String(format: "DSP %.1f%%", audio.cpuLoad))
                }.font(.system(size: 8, weight: .medium, design: .monospaced)).monospacedDigit()
                .hint("DSP is the audio render time as a percentage of its deadline. The remaining time is headroom, not total Mac CPU usage.", enabled: model.showHints)
            }
            .foregroundStyle(Palette.screenText)
            .padding(16)
            .background(Palette.screen, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.3), lineWidth: 2))
            HStack(spacing: 34) {
                Knob(title: "VELOCITY", parameter: .velocity, value: model.binding(.velocity), diameter: 57, hints: model.showHints)
                Knob(title: "MASTER", parameter: .master, value: model.binding(.master), diameter: 57, hints: model.showHints)
            }.frame(maxWidth: .infinity)
            HStack {
                Text("STEREO").tracking(1)
                Spacer()
                Text(audio.isRunning ? String(format: "%.1f kHz · %d FR", audio.sampleRate / 1000, audio.bufferFrames) : "AUDIO READY")
                    .hint("The actual audio buffer size in frames. A smaller buffer reduces scheduling delay; this is not a measurement of total key-to-sound latency.", enabled: model.showHints)
            }.font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(Palette.secondary)
        }.padding(14)
            .background(Palette.panel.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
    }
}

struct WaveformDisplay: View {
    let samples: [Float]
    let running: Bool
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for i in 0...8 {
                let x = CGFloat(i) / 8 * size.width
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for i in 0...4 {
                let y = CGFloat(i) / 4 * size.height
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(Palette.screenText.opacity(0.09)), lineWidth: 0.5)
            var wave = Path()
            let values = samples.isEmpty ? [Float](repeating: 0, count: 128) : samples
            // A fixed display scale preserves the visual relationship between loudness and amplitude.
            for (i, sample) in values.enumerated() {
                let x = CGFloat(i) / CGFloat(max(1, values.count - 1)) * size.width
                let y = size.height / 2 - CGFloat(min(1, max(-1, sample))) * size.height * 0.46
                if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(wave, with: .color(Palette.amber.opacity(running ? 0.18 : 0.05)), lineWidth: 5)
            context.stroke(wave, with: .color(Palette.amber.opacity(running ? 1 : 0.35)), lineWidth: 1.2)
        }.accessibilityLabel("Live output waveform")
    }
}

struct EffectPanel: View {
    @EnvironmentObject var model: SynthModel
    let effect: Effect
    private var enabled: Bool { model.patch.enabledEffects.contains(effect) }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.toggle(effect) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(enabled ? Palette.orange : Palette.line).frame(width: 6, height: 6)
                        Text(effect.title).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.6)
                    }
                }.buttonStyle(.plain).accessibilityLabel("\(effect.title) \(enabled ? "on" : "bypassed")")
                    .hint("Switch \(effect.title.lowercased()) on or bypass it. Your settings are kept.", enabled: model.showHints)
                Spacer(minLength: 4)
                Text(enabled ? "ON" : "OFF").font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 0) {
                ForEach(effect.controls, id: \.1) { title, parameter in
                    Knob(title: title, parameter: parameter, value: model.binding(parameter), diameter: 42, hints: model.showHints).frame(maxWidth: .infinity)
                }
                if effect == .drive {
                    VStack(spacing: 5) {
                        DriveCurve(drive: model.value(.drive)).stroke(Palette.orange.opacity(0.8), lineWidth: 1.5).frame(width: 52, height: 40)
                        Text("SOFT CLIP").font(.system(size: 7, design: .monospaced)).foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }.opacity(enabled ? 1 : 0.5)
            HStack(spacing: 8) {
                Text("MIX").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(Palette.secondary)
                Slider(value: model.binding(effect.mix), in: 0...1).tint(Palette.orange).controlSize(.mini)
                    .accessibilityLabel("\(effect.title) mix")
                    .hint(effect.mix.explanation, enabled: model.showHints)
                Text(String(format: "%02.0f", model.value(effect.mix) * 100))
                    .font(.system(size: 9, design: .monospaced)).monospacedDigit().frame(width: 22)
            }.opacity(enabled ? 1 : 0.6)
        }.padding(12)
            .background(Palette.panel.opacity(enabled ? 0.72 : 0.3), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line, lineWidth: 1))
    }
}

struct DriveCurve: Shape {
    var drive: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...60 {
            let t = Double(i) / 60
            let x = t * 2 - 1
            let y = tanh(x * (1 + drive * 6))
            let point = CGPoint(x: t * rect.width, y: rect.midY - y * rect.height * 0.4)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct MIDIStatus: View {
    @EnvironmentObject var model: SynthModel
    @ObservedObject var audio: AudioController
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(audio.midiSources.isEmpty ? Palette.secondary.opacity(0.4) : Color(hex: 0x62815D)).frame(width: 5, height: 5)
            Text(audio.midiSources.isEmpty ? "MIDI · No keyboard connected" : "MIDI · " + audio.midiSources.joined(separator: ", "))
                .lineLimit(1)
        }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            .hint(audio.status, enabled: model.showHints)
    }
}

struct InstrumentKeyboard: View {
    @EnvironmentObject var model: SynthModel
    @ObservedObject var audio: AudioController
    // Keep all computer-key mappings visible when changing octave.
    private var notes: [Int] {
        let first = max(0, min(7, model.octave - 1)) * 12 + 12
        return Array(first...(first + 35))
    }
    private var whites: [Int] { notes.filter { !isBlack($0) } }
    private func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(note % 12) }
    private func keyLabel(_ note: Int) -> String {
        if let index = ComputerKeyboard.semitones.firstIndex(of: note - model.octave * 12 - 12) { return ComputerKeyboard.letters[index].uppercased() }
        return ""
    }
    var body: some View {
        GeometryReader { keyboard in
            let keyHeight = max(104, keyboard.size.height - 24)
            VStack(spacing: 8) {
            HStack(spacing: 9) {
                Text("KEYBOARD").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                Text("Note names · boxed letters are typing keys").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                Text(audio.isRunning ? "" : "Start audio to play.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Text("COMPUTER OCTAVE").font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.secondary)
                Button { model.releaseLocalNotes(); model.octave = max(1, model.octave - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.plain).accessibilityLabel("Computer keyboard octave down")
                Text("\(model.octave)").font(.system(size: 10, design: .monospaced)).frame(width: 14)
                Button { model.releaseLocalNotes(); model.octave = min(7, model.octave + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("Computer keyboard octave up")
            }.frame(height: 16)
            GeometryReader { proxy in
                let keyWidth = proxy.size.width / CGFloat(whites.count)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 1) {
                        ForEach(whites, id: \.self) { note in
                            PianoKey(note: note, black: false, label: keyLabel(note), held: model.heldNotes.contains(note) || audio.activeNotes.contains(note))
                        }
                    }
                    ForEach(notes.filter(isBlack), id: \.self) { note in
                        let whiteCount = whites.filter { $0 < note }.count
                        PianoKey(note: note, black: true, label: keyLabel(note), held: model.heldNotes.contains(note) || audio.activeNotes.contains(note))
                            .frame(width: keyWidth * 0.6, height: keyHeight * 0.64)
                            .offset(x: CGFloat(whiteCount) * keyWidth - keyWidth * 0.3)
                    }
                }.background(Palette.ink)
            }.frame(height: keyHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.ink.opacity(0.5), lineWidth: 1))
            }
        }.frame(minHeight: 128)
    }
}

struct PianoKey: View {
    @EnvironmentObject var model: SynthModel
    let note: Int
    let black: Bool
    let label: String
    let held: Bool
    @State private var pressed = false
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: held ? [Palette.orange.opacity(0.8), Palette.orange] : (black ? [Color(hex: 0x40453D), Color(hex: 0x242A25)] : [Color(hex: 0xFAF7ED), Color(hex: 0xE3DECE)]), startPoint: .top, endPoint: .bottom))
            VStack(spacing: 4) {
                Text("\(["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][note % 12])\(note / 12 - 1)")
                    .font(.system(size: black ? 10 : 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(held ? Palette.panel : (black ? Palette.panel : Palette.ink))
                Text(label.isEmpty ? " " : label)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .frame(width: 17, height: 14)
                    .background((black ? Color.white : Palette.ink).opacity(label.isEmpty ? 0 : 0.08), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke((black ? Palette.panel : Palette.ink).opacity(label.isEmpty ? 0 : 0.2), lineWidth: 0.5))
                    .foregroundStyle(held ? Palette.panel : (black ? Palette.panel.opacity(0.8) : Palette.secondary))
            }.padding(.bottom, black ? 6 : 9)
        }.shadow(color: .black.opacity(black ? 0.3 : 0), radius: 1, y: 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                if !pressed { pressed = true; model.play(note, owner: "mouse-\(note)") }
            }.onEnded { _ in pressed = false; model.release(note, owner: "mouse-\(note)") })
            .onDisappear { if pressed { model.release(note, owner: "mouse-\(note)"); pressed = false } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(["C", "C sharp", "D", "D sharp", "E", "F", "F sharp", "G", "G sharp", "A", "A sharp", "B"][note % 12]) \(note / 12 - 1)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.play(note, owner: "accessible-\(note)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.release(note, owner: "accessible-\(note)") }
            }
    }
}
