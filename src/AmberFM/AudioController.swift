import AVFoundation
import CDSP
import Combine
import CoreAudio
import CoreMIDI
import Darwin
import Foundation

/// Owns one render generation. The source node retains this object, so stopping or
/// replacing the engine cannot free memory still referenced by an audio callback.
private final class RenderGeneration: @unchecked Sendable {
    let synth: OpaquePointer
    let counters: UnsafeMutablePointer<Int64>
    let sampleRate: Double
    let nanosecondsPerTick: Double

    init?(sampleRate: Double) {
        guard let synth = fm_create(sampleRate) else { return nil }
        self.synth = synth
        self.sampleRate = sampleRate
        counters = .allocate(capacity: 3)
        counters.initialize(repeating: 0, count: 3)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
    }

    deinit {
        fm_destroy(synth)
        counters.deinitialize(count: 3)
        counters.deallocate()
    }
}

/// MIDI parsing and control calls may arrive on multiple CoreMIDI threads.
/// This lock is used only by control producers and UI snapshots, never by audio.
private final class MIDIControlBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: RenderGeneration?
    private var parsers: [MIDIEndpointRef: MIDIByteParser] = [:]
    private var pressed = [UInt64](repeating: 0, count: 32)
    private var sustain = [UInt8](repeating: 0, count: 16)
    private var bends = [Float](repeating: 0, count: 16)

    func install(_ next: RenderGeneration?) {
        lock.lock()
        generation = next
        clearPressed()
        // Audio generations do not delimit MIDI streams: retain running status
        // and controller values when the output device or sample rate changes.
        if let next {
            for channel in 0..<16 {
                fm_sustain(next.synth, Int32(channel), Int32(sustain[channel]))
                fm_pitch_bend(next.synth, Int32(channel), bends[channel])
            }
        }
        lock.unlock()
    }

    func addSource(_ endpoint: MIDIEndpointRef) {
        lock.lock()
        parsers[endpoint] = MIDIByteParser()
        lock.unlock()
    }

    func removeSource(_ endpoint: MIDIEndpointRef) {
        lock.lock()
        parsers.removeValue(forKey: endpoint)
        panicLocked()
        lock.unlock()
    }

    func setParameter(_ index: Int, _ value: Float) {
        lock.lock()
        if let generation { fm_set_parameter(generation.synth, Int32(index), value) }
        lock.unlock()
    }

    func noteOn(_ note: Int, velocity: Int) {
        guard (0...127).contains(note) else { return }
        lock.lock()
        receive(status: 0x90, first: UInt8(note), second: UInt8(max(0, min(127, velocity))))
        lock.unlock()
    }

    func noteOff(_ note: Int) {
        guard (0...127).contains(note) else { return }
        lock.lock()
        receive(status: 0x80, first: UInt8(note), second: 0)
        lock.unlock()
    }

    func panic() {
        lock.lock()
        panicLocked()
        lock.unlock()
    }

    func pressedNotes() -> Set<Int> {
        lock.lock()
        var result = Set<Int>()
        for note in 0..<128 {
            for channel in 0..<16 where pressed[channel * 2 + note / 64] & (UInt64(1) << (note % 64)) != 0 {
                result.insert(note)
                break
            }
        }
        lock.unlock()
        return result
    }

    func consume(_ list: UnsafePointer<MIDIPacketList>, source: MIDIEndpointRef) {
        lock.lock()
        defer { lock.unlock() }
        guard let parser = parsers[source] else { return }
        // Use offsets into the original variable-sized packet list. Copying the
        // MIDIPacket tuple would truncate packets whose payload exceeds 256 bytes.
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<list.pointee.numPackets {
            let bytes = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            for offset in 0..<Int(packet.pointee.length) {
                parser.consume(bytes[offset], bridge: self)
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
    }

    // Called only while the bridge lock is held.
    fileprivate func receive(status: UInt8, first: UInt8, second: UInt8) {
        let channel = Int(status & 0x0f)
        let command = status & 0xf0
        let note = Int(first)
        switch command {
        case 0x80, 0x90:
            let isOn = command == 0x90 && second > 0
            let word = channel * 2 + note / 64
            let mask = UInt64(1) << (note % 64)
            if isOn { pressed[word] |= mask } else { pressed[word] &= ~mask }
            if let generation {
                if isOn {
                    fm_note_on(generation.synth, Int32(channel), Int32(note), Int32(second))
                } else {
                    fm_note_off(generation.synth, Int32(channel), Int32(note))
                }
            }
        case 0xb0:
            if first == 64 {
                sustain[channel] = second >= 64 ? 1 : 0
                if let generation { fm_sustain(generation.synth, Int32(channel), Int32(sustain[channel])) }
            } else if first == 121 {
                sustain[channel] = 0
                bends[channel] = 0
                if let generation {
                    fm_sustain(generation.synth, Int32(channel), 0)
                    fm_pitch_bend(generation.synth, Int32(channel), 0)
                }
            } else if first == 120 || first == 123 {
                pressed[channel * 2] = 0
                pressed[channel * 2 + 1] = 0
                if let generation { fm_channel_all_notes_off(generation.synth, Int32(channel), first == 120 ? 1 : 0) }
            }
        case 0xe0:
            let bend = Int(first) | (Int(second) << 7)
            let semitones = Float(bend - 8192) * (2.0 / 8192.0)
            bends[channel] = semitones
            if let generation { fm_pitch_bend(generation.synth, Int32(channel), semitones) }
        default:
            break
        }
    }

    fileprivate func panicLocked() {
        if let generation { fm_all_notes_off(generation.synth) }
        clearPressed()
        for channel in 0..<16 {
            sustain[channel] = 0
            bends[channel] = 0
            if let generation { fm_pitch_bend(generation.synth, Int32(channel), 0) }
        }
    }

    private func clearPressed() {
        for index in pressed.indices { pressed[index] = 0 }
    }
}

private final class MIDIByteParser {
    private var runningStatus: UInt8 = 0
    private var pendingStatus: UInt8 = 0
    private var first: UInt8 = 0
    private var received = 0
    private var expected = 0
    private var inSysEx = false

    func reset() {
        runningStatus = 0
        pendingStatus = 0
        first = 0
        received = 0
        expected = 0
        inSysEx = false
    }

    func consume(_ byte: UInt8, bridge: MIDIControlBridge) {
        // Real-time bytes can appear inside any message, including SysEx.
        if byte >= 0xf8 {
            if byte == 0xff { bridge.panicLocked() }
            return
        }
        if byte & 0x80 != 0 {
            received = 0
            if byte >= 0xf0 {
                runningStatus = 0
                pendingStatus = byte
                inSysEx = byte == 0xf0
                expected = byte == 0xf2 ? 2 : ((byte == 0xf1 || byte == 0xf3) ? 1 : 0)
            } else {
                inSysEx = false
                runningStatus = byte
                pendingStatus = byte
                expected = (byte & 0xf0 == 0xc0 || byte & 0xf0 == 0xd0) ? 1 : 2
            }
            return
        }
        guard !inSysEx, expected > 0, pendingStatus != 0 else { return }
        if received == 0 { first = byte }
        received += 1
        if received == expected {
            if pendingStatus < 0xf0 {
                bridge.receive(status: pendingStatus, first: first, second: expected == 2 ? byte : 0)
            }
            received = 0
            pendingStatus = runningStatus
            if runningStatus == 0 { expected = 0 }
        }
    }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Audio off"
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var activeNotes: Set<Int> = []
    @Published private(set) var activeVoices = 0
    @Published private(set) var peakLevel: Float = 0
    @Published private(set) var cpuLoad: Double = 0
    /// Frame count of the most recent real audio render callback, not a requested
    /// buffer size or a measurement of end-to-end key-to-speaker latency.
    @Published private(set) var bufferFrames = 0
    @Published private(set) var waveform = [Float](repeating: 0, count: 256)
    @Published private(set) var droppedEvents: UInt32 = 0
    private(set) var sampleRate: Double = 48_000

    private let bridge = MIDIControlBridge()
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var generation: RenderGeneration?
    private var parameters: [Int: Float] = [:]
    private var timer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var configurationWork: DispatchWorkItem?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var recoveryAttempt = 0
    private var wantsAudio = false
    private var previousTicks: Int64 = 0
    private var previousFrames: Int64 = 0
    private var waveformScratch = [Float](repeating: 0, count: 256)
    private var midiClient: MIDIClientRef = 0
    private var midiPort: MIDIPortRef = 0
    private var connectedSources: Set<MIDIEndpointRef> = []
    private var midiError: String?

    init() {
        setupMIDI()
        setupOutputDeviceListener()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTelemetry() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    deinit {
        timer?.invalidate()
        configurationWork?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let outputDeviceListener {
            var address = Self.outputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputDeviceListener)
        }
        engine?.stop()
        if midiPort != 0 { MIDIPortDispose(midiPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
        bridge.install(nil)
    }

    func start() {
        wantsAudio = true
        guard !isRunning else { return }
        recoveryAttempt = 0
        configurationWork?.cancel()
        startEngine()
    }

    func stop() {
        wantsAudio = false
        configurationWork?.cancel()
        configurationWork = nil
        stopEngine()
        updateStatus()
    }

    func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Int(FM_PARAMETER_COUNT.rawValue), value.isFinite else { return }
        parameters[index] = value
        bridge.setParameter(index, value)
    }

    func noteOn(_ note: Int, velocity: Int = 100) {
        guard isRunning else { return }
        bridge.noteOn(note, velocity: velocity)
    }

    func noteOff(_ note: Int) { bridge.noteOff(note) }

    func panic() {
        bridge.panic()
        if !activeNotes.isEmpty { activeNotes = [] }
    }

    /// Exercises the production packet walker and byte parser without creating an
    /// audio engine, opening a MIDI device, or emitting sound.
    static func parserSelfTest() -> Bool {
        let control = MIDIControlBridge()
        let source: MIDIEndpointRef = 1
        control.addSource(source)
        func send(_ packets: [[UInt8]]) -> Bool {
            let capacity = 4096
            let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            defer { memory.deallocate() }
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
            let list = memory.assumingMemoryBound(to: MIDIPacketList.self)
            var packet = MIDIPacketListInit(list)
            for (index, bytes) in packets.enumerated() {
                let next = bytes.withUnsafeBufferPointer { buffer in
                    MIDIPacketListAdd(list, capacity, packet, MIDITimeStamp(index + 1), buffer.count, buffer.baseAddress!)
                }
                packet = next
            }
            guard list.pointee.numPackets == packets.count else { return false }
            control.consume(UnsafePointer(list), source: source)
            return true
        }
        func matches(_ notes: Set<Int>) -> Bool { control.pressedNotes() == notes }
        guard send([[0x90, 60, 100, 61, 70, 62, 0]]), matches([60, 61]),
              send([[0x80, 60, 0]]), matches([61]),
              send([[0x90, 62, 0xf8, 100]]), matches([61, 62]),
              send([[0xf0, 1, 2, 0xf8, 3, 0xf7, 63, 100]]), matches([61, 62]),
              send([[0x90, 64], [0xf8, 100]]), matches([61, 62, 64]),
              send([[0xf1, 0x7f, 65, 100]]), matches([61, 62, 64]),
              send([[0xc0, 3, 4, 5, 0x90, 66, 90]]), matches([61, 62, 64, 66]),
              send([[0x95, 61, 90, 0x80, 61, 0]]), matches([61, 62, 64, 66]),
              send([[0x85, 61, 0]]), matches([62, 64, 66]),
              send([[0xb4, 123, 0]]), matches([62, 64, 66]),
              send([[0xb0, 123, 0]]), matches([]) else { return false }
        guard send([[0x90, 60, 100]]), matches([60]) else { return false }
        control.install(nil)
        guard send([[61, 100]]), matches([61]),
              send([[0xb0, 120, 0]]), matches([]) else { return false }
        // The public MIDIPacket tuple declares 256 data bytes, but the packet's
        // actual storage can be larger. This guards against accidental truncation.
        let longPacket: [UInt8] = [0xf0] + Array(repeating: 1, count: 300) + [0xf7, 0x90, 67, 100]
        guard send([longPacket, [0xf8]]), matches([67]),
              send([[0x90, 69], [0xf8, 100, 70, 100]]), matches([67, 69, 70]),
              send([[0xf2, 0, 0, 71, 100]]), matches([67, 69, 70]),
              send([[0xff]]), matches([]),
              send([[0x9f, 127, 127]]), matches([127]),
              send([[0x9f, 127, 0]]), matches([]) else { return false }
        // Render into memory to verify that controller messages reach the DSP,
        // including sustain release and channel modes. No speaker output occurs.
        guard let render = RenderGeneration(sampleRate: 48_000) else { return false }
        control.install(render)
        control.setParameter(Int(FM_AMP_ATTACK.rawValue), 0.002)
        control.setParameter(Int(FM_AMP_RELEASE.rawValue), 0.01)
        control.setParameter(Int(FM_MOD_RELEASE.rawValue), 0.01)
        control.setParameter(Int(FM_AMP_SUSTAIN.rawValue), 1)
        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        func renderTail() {
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    for _ in 0..<100 { fm_render(render.synth, leftBuffer.baseAddress, rightBuffer.baseAddress, 256) }
                }
            }
        }
        guard send([[0x90, 60, 100, 0xb0, 64, 127, 0x80, 60, 0]]) else { return false }
        renderTail()
        guard fm_active_voices(render.synth) == 1,
              send([[0xb0, 121, 0]]) else { return false }
        renderTail()
        guard fm_active_voices(render.synth) == 0,
              send([[0x90, 60, 100, 0x91, 65, 100]]) else { return false }
        renderTail()
        guard fm_active_voices(render.synth) == 2,
              send([[0xb0, 120, 0]]) else { return false }
        renderTail()
        guard fm_active_voices(render.synth) == 1, matches([65]),
              send([[0xb1, 64, 127, 123, 0]]) else { return false }
        renderTail()
        guard fm_active_voices(render.synth) == 1, matches([]),
              send([[0xb1, 121, 0]]) else { return false }
        renderTail()
        guard fm_active_voices(render.synth) == 0 else { return false }
        control.install(nil)
        control.removeSource(source)
        return send([[0x90, 60, 100]]) && matches([])
    }

    private func startEngine() {
        let newEngine = AVAudioEngine()
        requestLowLatencyBuffer(on: newEngine.outputNode)
        let output = newEngine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2),
              let render = RenderGeneration(sampleRate: output.sampleRate) else {
            status = "No audio output available"
            scheduleRecoveryAttempt()
            return
        }
        for (index, value) in parameters { fm_set_parameter(render.synth, Int32(index), value) }
        // The callback captures one immutable owner. All sample storage and atomic
        // counters were allocated above; it never enters the MIDI/UI lock.
        let node = AVAudioSourceNode(format: format) { [render] silence, _, frameCount, audioBufferList in
            let began = mach_absolute_time()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                silence.pointee = true
                return noErr
            }
            fm_render(render.synth, left, right, frameCount)
            silence.pointee = false
            let elapsed = mach_absolute_time() - began
            OSAtomicAdd64Barrier(Int64(bitPattern: elapsed), render.counters)
            OSAtomicAdd64Barrier(Int64(frameCount), render.counters.advanced(by: 1))
            let quantumCounter = render.counters.advanced(by: 2)
            let previousQuantum = OSAtomicAdd64Barrier(0, quantumCounter)
            if previousQuantum != Int64(frameCount) {
                OSAtomicCompareAndSwap64Barrier(previousQuantum, Int64(frameCount), quantumCounter)
            }
            return noErr
        }
        newEngine.attach(node)
        newEngine.connect(node, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = 1
        do {
            newEngine.prepare()
            try newEngine.start()
            engine = newEngine
            sourceNode = node
            generation = render
            sampleRate = render.sampleRate
            previousTicks = 0
            previousFrames = 0
            bridge.install(render)
            isRunning = true
            recoveryAttempt = 0
            let engineIdentity = ObjectIdentifier(newEngine)
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let currentEngine = self.engine,
                          ObjectIdentifier(currentEngine) == engineIdentity else { return }
                    self.scheduleAudioRestart()
                }
            }
            updateStatus()
        } catch {
            newEngine.stop()
            status = "Audio could not start: \(error.localizedDescription)"
            scheduleRecoveryAttempt()
        }
    }

    private func requestLowLatencyBuffer(on output: AVAudioOutputNode) {
        guard let audioUnit = output.audioUnit else { return }
        var requested: UInt32 = 128
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let rangeResult = AudioUnitGetProperty(audioUnit, kAudioDevicePropertyBufferFrameSizeRange,
                                               kAudioUnitScope_Global, 0, &range, &rangeSize)
        if rangeResult == noErr,
           !(range.mMinimum...range.mMaximum).contains(Double(requested)) { return }
        // Apple TN2321 documents this AUHAL request as the application's I/O
        // buffer choice. It does not change the system default device, sample
        // rate, or any global AudioObject property. A rejection is nonfatal: the
        // engine keeps its supported size, and bufferFrames reports reality.
        _ = AudioUnitSetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize,
                                 kAudioUnitScope_Global, 0, &requested,
                                 UInt32(MemoryLayout<UInt32>.size))
    }

    private func stopEngine(resetControllers: Bool = true) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if resetControllers { bridge.panic() }
        engine?.stop()
        bridge.install(nil)
        if let sourceNode { engine?.detach(sourceNode) }
        sourceNode = nil
        engine = nil
        generation = nil
        if isRunning { isRunning = false }
        if !activeNotes.isEmpty { activeNotes = [] }
        if activeVoices != 0 { activeVoices = 0 }
        if peakLevel != 0 { peakLevel = 0 }
        if cpuLoad != 0 { cpuLoad = 0 }
        if bufferFrames != 0 { bufferFrames = 0 }
        if droppedEvents != 0 { droppedEvents = 0 }
        if waveform.contains(where: { $0 != 0 }) { waveform = [Float](repeating: 0, count: 256) }
    }

    private func scheduleAudioRestart() {
        guard wantsAudio else { return }
        recoveryAttempt = 0
        configurationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsAudio else { return }
            self.stopEngine(resetControllers: false)
            self.startEngine()
        }
        configurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func scheduleRecoveryAttempt() {
        guard wantsAudio, recoveryAttempt < 5 else { return }
        recoveryAttempt += 1
        configurationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsAudio, !self.isRunning else { return }
            self.startEngine()
        }
        configurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(recoveryAttempt) * 0.5, execute: work)
    }

    private nonisolated static var outputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func setupOutputDeviceListener() {
        var address = Self.outputDeviceAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleAudioRestart() }
        }
        let result = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        if result == noErr { outputDeviceListener = listener }
    }

    private func refreshTelemetry() {
        let notes = bridge.pressedNotes()
        if notes != activeNotes { activeNotes = notes }
        guard let generation, isRunning else { return }
        let voices = Int(fm_active_voices(generation.synth))
        if voices != activeVoices { activeVoices = voices }
        let peak = fm_peak_level(generation.synth)
        if peak != peakLevel { peakLevel = peak }
        let dropped = fm_dropped_events(generation.synth)
        if dropped != droppedEvents { droppedEvents = dropped }
        waveformScratch.withUnsafeMutableBufferPointer { samples in
            _ = fm_copy_waveform(generation.synth, samples.baseAddress, UInt32(samples.count))
        }
        if waveformScratch != waveform { waveform = waveformScratch }
        let quantum = Int(OSAtomicAdd64Barrier(0, generation.counters.advanced(by: 2)))
        if quantum != bufferFrames { bufferFrames = quantum }
        let ticks = OSAtomicAdd64Barrier(0, generation.counters)
        let frames = OSAtomicAdd64Barrier(0, generation.counters.advanced(by: 1))
        let elapsedTicks = ticks - previousTicks
        let elapsedFrames = frames - previousFrames
        previousTicks = ticks
        previousFrames = frames
        if elapsedFrames > 0 {
            let audioDuration = Double(elapsedFrames) / generation.sampleRate
            let processingDuration = Double(max(0, elapsedTicks)) * generation.nanosecondsPerTick / 1_000_000_000
            let measuredLoad = processingDuration / audioDuration * 100
            // Match the UI's tenth-of-a-percent precision so invisible jitter
            // does not invalidate the entire observable object every 40 ms.
            let displayedLoad = (measuredLoad * 10).rounded() / 10
            if displayedLoad != cpuLoad { cpuLoad = displayedLoad }
        }
    }

    private func setupMIDI() {
        let clientResult = MIDIClientCreateWithBlock("FM Synth" as CFString, &midiClient) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMIDISources() }
        }
        guard clientResult == noErr else {
            midiError = "MIDI unavailable (\(clientResult))"
            updateStatus()
            return
        }
        let bridge = bridge
        let portResult = MIDIInputPortCreateWithBlock(midiClient, "Keyboard input" as CFString, &midiPort) { list, sourceContext in
            guard let sourceContext else { return }
            bridge.consume(list, source: MIDIEndpointRef(UInt(bitPattern: sourceContext)))
        }
        guard portResult == noErr else {
            midiError = "MIDI input unavailable (\(portResult))"
            updateStatus()
            return
        }
        refreshMIDISources()
    }

    private func refreshMIDISources() {
        guard midiPort != 0 else { return }
        var available: Set<MIDIEndpointRef> = []
        var names: [MIDIEndpointRef: String] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            var offline: Int32 = 0
            _ = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { continue }
            available.insert(endpoint)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name {
                names[endpoint] = name.takeRetainedValue() as String
            } else {
                names[endpoint] = "MIDI keyboard"
            }
        }
        for endpoint in connectedSources.subtracting(available) {
            MIDIPortDisconnectSource(midiPort, endpoint)
            bridge.removeSource(endpoint)
            connectedSources.remove(endpoint)
        }
        for endpoint in available.subtracting(connectedSources) {
            bridge.addSource(endpoint)
            let result = MIDIPortConnectSource(midiPort, endpoint, UnsafeMutableRawPointer(bitPattern: UInt(endpoint)))
            if result == noErr {
                connectedSources.insert(endpoint)
            } else {
                bridge.removeSource(endpoint)
                midiError = "Could not connect MIDI input (\(result))"
            }
        }
        if connectedSources == available { midiError = nil }
        let sourceNames = connectedSources.compactMap { names[$0] }.sorted()
        if sourceNames != midiSources { midiSources = sourceNames }
        updateStatus()
    }

    private func updateStatus() {
        let nextStatus: String
        if let midiError {
            nextStatus = isRunning ? "Audio on · \(midiError)" : midiError
        } else if isRunning {
            nextStatus = midiSources.isEmpty ? "Audio on · waiting for MIDI" : "Audio on · MIDI connected"
        } else {
            nextStatus = midiSources.isEmpty ? "Audio off · connect your keyboard" : "Audio off · MIDI ready"
        }
        if nextStatus != status { status = nextStatus }
    }
}
