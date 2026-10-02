import AVFoundation
import CDSP
import Combine
import CoreMIDI
import Foundation

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class VirtualKeyboard {
    let name = "FM Synth Integration Probe"
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0

    init() throws {
        let clientStatus = MIDIClientCreateWithBlock(name as CFString, &client) { _ in }
        guard clientStatus == noErr else { throw ProbeFailure(description: "MIDI client creation failed: \(clientStatus)") }
        let sourceStatus = MIDISourceCreate(client, name as CFString, &source)
        guard sourceStatus == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw ProbeFailure(description: "Virtual MIDI source creation failed: \(sourceStatus)")
        }
    }

    deinit {
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func send(_ bytes: [UInt8]) throws {
        guard source != 0, !bytes.isEmpty, bytes.count <= 256 else {
            throw ProbeFailure(description: "Invalid test packet or disconnected source")
        }
        var list = MIDIPacketList()
        let result = withUnsafeMutablePointer(to: &list) { listPointer in
            let first = MIDIPacketListInit(listPointer)
            bytes.withUnsafeBufferPointer { buffer in
                _ = MIDIPacketListAdd(listPointer, MemoryLayout<MIDIPacketList>.size, first, 0,
                                      buffer.count, buffer.baseAddress!)
            }
            return MIDIReceived(source, listPointer)
        }
        guard result == noErr else { throw ProbeFailure(description: "MIDI injection failed: \(result)") }
    }

    func disconnect() throws {
        guard source != 0 else { return }
        let result = MIDIEndpointDispose(source)
        source = 0
        guard result == noErr else { throw ProbeFailure(description: "MIDI disconnect failed: \(result)") }
    }
}

@main
private enum AudioMIDIProbe {
    @MainActor
    static func main() {
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                fputs("AUDIO_MIDI_E2E_FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        // The production controller publishes through a Foundation Timer, just
        // as it does under NSApplication. Keep a real main run loop for this test.
        CFRunLoopRun()
    }

    @MainActor
    private static func waitFor(_ label: String, timeout: Double = 3,
                                _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw ProbeFailure(description: "Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func frequency(_ samples: [Float], sampleRate: Double) -> Double? {
        var crossings: [Double] = []
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if previous <= 0, current > 0 {
                crossings.append(Double(index - 1) + Double(-previous / (current - previous)))
            }
        }
        guard crossings.count >= 3, let first = crossings.first, let last = crossings.last else { return nil }
        // The DSP captures its scope at approximately 16 kHz.
        let divider = max(1, Int(sampleRate / 16_000))
        return sampleRate / Double(divider) * Double(crossings.count - 1) / (last - first)
    }

    @MainActor
    private static func run() async throws {
        guard AudioController.parserSelfTest() else { throw ProbeFailure(description: "Packet/parser regression test failed") }
        print("MIDI_PARSER_SELF_TEST_PASS")
        let audio = AudioController()
        defer { audio.stop() }
        let keyboard = try VirtualKeyboard()
        audio.setParameter(Int(FM_MASTER.rawValue), 0.03)
        audio.setParameter(Int(FM_CARRIER_RATIO.rawValue), 1)
        audio.setParameter(Int(FM_MOD_RATIO.rawValue), 1)
        audio.setParameter(Int(FM_MOD_INDEX.rawValue), 0)
        audio.setParameter(Int(FM_AMP_ATTACK.rawValue), 0.002)
        audio.setParameter(Int(FM_AMP_DECAY.rawValue), 0.05)
        audio.setParameter(Int(FM_AMP_SUSTAIN.rawValue), 1)
        audio.setParameter(Int(FM_AMP_RELEASE.rawValue), 0.04)
        audio.setParameter(Int(FM_MOD_RELEASE.rawValue), 0.04)
        for parameter in [FM_DRIVE_MIX, FM_CHORUS_MIX, FM_PHASER_MIX, FM_DELAY_MIX, FM_REVERB_MIX] {
            audio.setParameter(Int(parameter.rawValue), 0)
        }
        audio.start()
        guard audio.isRunning else { throw ProbeFailure(description: "Host audio engine unavailable: \(audio.status)") }
        try await waitFor("virtual MIDI source attachment") { audio.midiSources.contains(keyboard.name) }
        try await waitFor("actual render callback quantum") { audio.bufferFrames > 0 }
        print("PASS: real audio output running at \(Int(audio.sampleRate)) Hz; actual callback quantum \(audio.bufferFrames) frames; virtual MIDI source attached")

        try keyboard.send([0x9f, 60, 100, 64, 92, 67, 90])
        try await waitFor("running-status chord reaches audio render") {
            audio.activeVoices == 3 && audio.activeNotes == Set([60, 64, 67]) && audio.peakLevel > 0.0001
        }
        let soundingPeak = audio.peakLevel
        try keyboard.send([0xbf, 64, 127, 0x8f, 60, 0, 64, 0, 67, 0])
        try await waitFor("pedal holds released chord") { audio.activeNotes.isEmpty && audio.activeVoices == 3 }
        try await Task.sleep(nanoseconds: 200_000_000)
        guard audio.activeVoices == 3 else { throw ProbeFailure(description: "Sustain did not hold the chord") }
        try keyboard.send([0xbf, 121, 0])
        try await waitFor("reset controllers releases sustain") { audio.activeVoices == 0 }
        print("PASS: MIDI chord, running status, sustain and controller reset reach the renderer")

        try keyboard.send([0x9f, 69, 100])
        try await waitFor("A4 renders at 440 Hz") {
            frequency(audio.waveform, sampleRate: audio.sampleRate).map { abs($0 - 440) < 10 } ?? false
        }
        try keyboard.send([0xef, 127, 127])
        try await waitFor("positive pitch bend renders two semitones up") {
            frequency(audio.waveform, sampleRate: audio.sampleRate).map { abs($0 - 493.88) < 10 } ?? false
        }
        try keyboard.send([0xef, 0, 0])
        try await waitFor("negative pitch bend renders two semitones down") {
            frequency(audio.waveform, sampleRate: audio.sampleRate).map { abs($0 - 392) < 10 } ?? false
        }
        try keyboard.send([0x9f, 69, 0, 0xef, 0, 64])
        try await waitFor("zero-velocity note-on releases note") { audio.activeVoices == 0 && audio.activeNotes.isEmpty }
        print("PASS: rendered waveform verifies centered and +/-2 semitone pitch bend; velocity-zero releases")

        try keyboard.send([0x9e, 60, 100, 0x9f, 67, 100])
        try await waitFor("two MIDI channels sound") { audio.activeVoices == 2 }
        try keyboard.send([0xbe, 120, 0])
        try await waitFor("channel-scoped all sound off") { audio.activeVoices == 1 && audio.activeNotes == Set([67]) }
        try keyboard.send([0xbf, 64, 127, 123, 0])
        try await waitFor("all notes off respects sustain") { audio.activeVoices == 1 && audio.activeNotes.isEmpty }
        try await Task.sleep(nanoseconds: 150_000_000)
        guard audio.activeVoices == 1 else { throw ProbeFailure(description: "All notes off incorrectly defeated sustain") }
        try keyboard.send([0xbf, 64, 0])
        try await waitFor("pedal up releases channel") { audio.activeVoices == 0 }
        print("PASS: channel-scoped sound off and sustain-aware all notes off")

        audio.stop()
        guard !audio.isRunning else { throw ProbeFailure(description: "Audio Stop did not stop the engine") }
        audio.start()
        guard audio.isRunning else { throw ProbeFailure(description: "Audio restart failed: \(audio.status)") }
        try keyboard.send([0x9f, 72, 100])
        try await waitFor("note sounds after engine restart") { audio.activeVoices == 1 && audio.peakLevel > 0.0001 }
        try keyboard.disconnect()
        try await waitFor("disconnect removes source and releases held note") {
            !audio.midiSources.contains(keyboard.name) && audio.activeVoices == 0 && audio.activeNotes.isEmpty
        }
        guard audio.droppedEvents == 0, audio.cpuLoad.isFinite,
              audio.waveform.allSatisfy({ $0.isFinite }) else {
            throw ProbeFailure(description: "Non-finite telemetry or dropped MIDI events")
        }
        print("PASS: engine stop/start, MIDI disconnect cleanup, finite waveform and no dropped events")
        try await waitFor("silent telemetry settles") {
            audio.peakLevel == 0 && audio.waveform.allSatisfy { $0 == 0 }
        }
        var unchangedPublications = 0
        var observations = Set<AnyCancellable>()
        audio.$activeNotes.dropFirst().sink { _ in unchangedPublications += 1 }.store(in: &observations)
        audio.$activeVoices.dropFirst().sink { _ in unchangedPublications += 1 }.store(in: &observations)
        audio.$peakLevel.dropFirst().sink { _ in unchangedPublications += 1 }.store(in: &observations)
        audio.$waveform.dropFirst().sink { _ in unchangedPublications += 1 }.store(in: &observations)
        audio.$bufferFrames.dropFirst().sink { _ in unchangedPublications += 1 }.store(in: &observations)
        try await Task.sleep(nanoseconds: 240_000_000)
        guard unchangedPublications == 0 else { throw ProbeFailure(description: "Unchanged telemetry republished \(unchangedPublications) times") }
        observations.removeAll()
        print("PASS: silent note, voice, peak, waveform and quantum telemetry is not republished")
        print(String(format: "AUDIO_MIDI_E2E_PASS: rate=%.0f quantum=%d peak=%.5f cpu=%.1f%%", audio.sampleRate, audio.bufferFrames, soundingPeak, audio.cpuLoad))
    }
}
