import Foundation
import SwiftUI
import CDSP

enum Parameter: Int, CaseIterable, Codable {
    case master, carrierRatio, modRatio, modIndex
    case ampAttack, ampDecay, ampSustain, ampRelease
    case modAttack, modDecay, modSustain, modRelease
    case velocity, drive, driveMix, chorusRate, chorusDepth, chorusMix
    case phaserRate, phaserDepth, phaserMix, delayTime, delayFeedback, delayMix
    case reverbSize, reverbDamp, reverbMix

    var range: ClosedRange<Double> {
        switch self {
        case .carrierRatio: return 0.25...8
        case .modRatio: return 0.25...16
        case .modIndex: return 0...12
        case .ampAttack, .modAttack: return 0.002...5
        case .ampDecay, .modDecay: return 0.01...8
        case .ampRelease, .modRelease: return 0.01...12
        case .chorusRate: return 0.05...5
        case .phaserRate: return 0.03...5
        case .delayTime: return 0.04...1.5
        case .delayFeedback: return 0...0.85
        default: return 0...1
        }
    }

    var defaultValue: Double {
        switch self {
        case .master: return 0.65
        case .carrierRatio, .modRatio: return 1
        case .modIndex: return 2
        case .ampAttack: return 0.008
        case .ampDecay: return 1.3
        case .ampSustain: return 0.35
        case .ampRelease: return 0.7
        case .modAttack: return 0.005
        case .modDecay: return 0.7
        case .modSustain: return 0.15
        case .modRelease: return 0.35
        case .velocity: return 0.65
        case .drive: return 0.3
        case .driveMix, .chorusMix, .phaserMix, .delayMix, .reverbMix: return 0.25
        case .chorusRate: return 0.7
        case .chorusDepth: return 0.35
        case .phaserRate: return 0.22
        case .phaserDepth: return 0.6
        case .delayTime: return 0.33
        case .delayFeedback: return 0.35
        case .reverbSize: return 0.65
        case .reverbDamp: return 0.5
        }
    }

    var isLogarithmic: Bool {
        switch self {
        case .ampAttack, .ampDecay, .ampRelease, .modAttack, .modDecay, .modRelease,
             .chorusRate, .phaserRate, .delayTime: return true
        default: return false
        }
    }

    func display(_ value: Double) -> String {
        switch self {
        case .carrierRatio, .modRatio: return String(format: "%.2f×", value)
        case .modIndex: return String(format: "%.2f", value)
        case .ampAttack, .ampDecay, .ampRelease, .modAttack, .modDecay, .modRelease, .delayTime:
            return value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.2f s", value)
        case .chorusRate, .phaserRate: return String(format: "%.2f Hz", value)
        default: return String(format: "%.0f%%", value * 100)
        }
    }

    var explanation: String {
        switch self {
        case .master: return "The final output level. This does not change your saved sound."
        case .carrierRatio: return "The audible operator's frequency relative to the key you play. 1× follows the keyboard; 2× is one octave higher."
        case .modRatio: return "The modulator's frequency relative to the key. Whole-number ratios tend to sound harmonic; fractional ratios can turn metallic."
        case .modIndex: return "How strongly the modulator bends the carrier's phase. Zero is a pure sine; higher values add brightness and complexity."
        case .ampAttack: return "How long the note takes to reach full loudness after you press a key."
        case .ampDecay: return "How long the volume takes to fall from its peak to the sustain level."
        case .ampSustain: return "The volume held while you keep a key pressed."
        case .ampRelease: return "How long the sound fades after you release the key or sustain pedal."
        case .modAttack: return "How quickly the tone reaches its full FM amount. Longer values let brightness grow into the note."
        case .modDecay: return "How quickly the initial bright tone settles into the sustained tone."
        case .modSustain: return "The fraction of FM amount held while the key is pressed. Low values let the note soften over time."
        case .modRelease: return "How quickly modulation fades when you release the note."
        case .velocity: return "How much a harder key strike changes the loudness and brightness of the sound."
        case .drive: return "How hard the signal is pushed into a saturating curve. More drive adds harmonics and grit."
        case .driveMix: return "Blend between the original sound and the distorted signal."
        case .chorusRate: return "How fast the chorus copies drift in pitch. Slow rates give gentle movement."
        case .chorusDepth: return "How far the delayed chorus copies drift, adding thickness and stereo spread."
        case .chorusMix: return "Blend in the chorus's shifting copies of the original sound."
        case .phaserRate: return "How quickly the phaser sweeps through the tone."
        case .phaserDepth: return "How far the phase-shifting filters sweep, creating the characteristic swirl."
        case .phaserMix: return "Blend in the phase-shifted signal. Mixing it with the original creates moving notches in the spectrum."
        case .delayTime: return "The time between echoes, in milliseconds or seconds."
        case .delayFeedback: return "How much each echo feeds into the next. Higher values make echoes last longer."
        case .delayMix: return "The level of the repeated echoes."
        case .reverbSize: return "The apparent size and decay of the space around the sound."
        case .reverbDamp: return "How quickly high frequencies fade in the reverb tail. More damping creates a warmer space."
        case .reverbMix: return "Blend the room reflections into the direct sound."
        }
    }

    var accessibilityName: String {
        switch self {
        case .carrierRatio: return "Carrier ratio"
        case .modRatio: return "Modulator ratio"
        case .modIndex: return "Modulator FM amount"
        case .ampAttack: return "Carrier attack"
        case .ampDecay: return "Carrier decay"
        case .ampSustain: return "Carrier sustain"
        case .ampRelease: return "Carrier release"
        case .modAttack: return "Modulator attack"
        case .modDecay: return "Modulator decay"
        case .modSustain: return "Modulator sustain"
        case .modRelease: return "Modulator release"
        case .master: return "Master volume"
        case .velocity: return "Velocity sensitivity"
        case .drive: return "Distortion drive"
        case .driveMix: return "Distortion mix"
        case .chorusRate: return "Chorus rate"
        case .chorusDepth: return "Chorus depth"
        case .chorusMix: return "Chorus mix"
        case .phaserRate: return "Phaser rate"
        case .phaserDepth: return "Phaser depth"
        case .phaserMix: return "Phaser mix"
        case .delayTime: return "Delay time"
        case .delayFeedback: return "Delay feedback"
        case .delayMix: return "Delay mix"
        case .reverbSize: return "Reverb size"
        case .reverbDamp: return "Reverb damping"
        case .reverbMix: return "Reverb mix"
        }
    }
}

enum Effect: String, CaseIterable, Codable {
    case drive, chorus, phaser, delay, reverb
    var title: String { self == .drive ? "DISTORTION" : rawValue.uppercased() }
    var mix: Parameter {
        switch self {
        case .drive: return .driveMix
        case .chorus: return .chorusMix
        case .phaser: return .phaserMix
        case .delay: return .delayMix
        case .reverb: return .reverbMix
        }
    }
    var controls: [(String, Parameter)] {
        switch self {
        case .drive: return [("DRIVE", .drive)]
        case .chorus: return [("RATE", .chorusRate), ("DEPTH", .chorusDepth)]
        case .phaser: return [("RATE", .phaserRate), ("DEPTH", .phaserDepth)]
        case .delay: return [("TIME", .delayTime), ("FEEDBACK", .delayFeedback)]
        case .reverb: return [("SIZE", .reverbSize), ("DAMP", .reverbDamp)]
        }
    }
}

struct Patch: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var category: String
    var values: [Double]
    var enabledEffects: Set<Effect>
    var isFactory: Bool

    static func make(_ name: String, _ category: String, _ overrides: [Parameter: Double], _ effects: Set<Effect>) -> Patch {
        var values = Parameter.allCases.map(\.defaultValue)
        for (parameter, value) in overrides { values[parameter.rawValue] = value }
        // Factory identifiers are derived from their stable position by the caller.
        return Patch(id: UUID(), name: name, category: category, values: values, enabledEffects: effects, isFactory: true)
    }

    func validated() -> Patch? {
        guard values.count == Parameter.allCases.count, values.allSatisfy(\.isFinite),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var result = self
        result.name = String(name.prefix(80))
        for parameter in Parameter.allCases {
            result.values[parameter.rawValue] = min(parameter.range.upperBound, max(parameter.range.lowerBound, values[parameter.rawValue]))
        }
        return result
    }

    static let factory: [Patch] = {
        var patches: [Patch] = [
            .make("Velvet Tines", "ELECTRIC PIANO", [.modRatio: 1, .modIndex: 2.8, .ampDecay: 2.4, .ampSustain: 0.12, .ampRelease: 0.65, .modDecay: 0.65, .modSustain: 0.08, .chorusMix: 0.22, .reverbMix: 0.18, .reverbSize: 0.45], [.chorus, .reverb]),
            .make("Copper Bass", "BASS", [.modRatio: 1, .modIndex: 3.8, .ampAttack: 0.004, .ampDecay: 0.4, .ampSustain: 0.5, .ampRelease: 0.14, .modDecay: 0.22, .modSustain: 0.18, .modRelease: 0.12, .drive: 0.25, .driveMix: 0.2], [.drive]),
            .make("Burnished", "GRITTY LEAD", [.modRatio: 2, .modIndex: 3.5, .ampAttack: 0.012, .ampDecay: 0.5, .ampSustain: 0.7, .ampRelease: 0.3, .modSustain: 0.55, .drive: 0.62, .driveMix: 0.55, .phaserMix: 0.35, .delayMix: 0.18, .delayTime: 0.27, .delayFeedback: 0.28], [.drive, .phaser, .delay]),
            .make("Afterglow", "ATMOSPHERIC", [.modRatio: 0.5, .modIndex: 2.4, .ampAttack: 1.2, .ampDecay: 2, .ampSustain: 0.75, .ampRelease: 3.8, .modAttack: 2.2, .modDecay: 3, .modSustain: 0.5, .modRelease: 3, .chorusDepth: 0.55, .chorusMix: 0.4, .phaserRate: 0.08, .phaserMix: 0.25, .delayTime: 0.48, .delayFeedback: 0.48, .delayMix: 0.25, .reverbSize: 0.88, .reverbMix: 0.42], [.chorus, .phaser, .delay, .reverb]),
            .make("Glasshouse", "BELL", [.modRatio: 3.5, .modIndex: 4.2, .ampAttack: 0.002, .ampDecay: 3.2, .ampSustain: 0, .ampRelease: 1.2, .modDecay: 1.6, .modSustain: 0, .modRelease: 0.6, .delayMix: 0.15, .reverbMix: 0.3, .reverbSize: 0.7], [.delay, .reverb]),
            .make("First Principles", "PURE SINE", [.modIndex: 0, .ampAttack: 0.02, .ampDecay: 0.4, .ampSustain: 0.8, .ampRelease: 0.4, .velocity: 0.4], [])
        ]
        for i in patches.indices {
            patches[i].id = UUID(uuidString: String(format: "A8BE0000-0000-4000-8000-%012d", i + 1))!
        }
        return patches
    }()
}

struct SessionState: Codable {
    var version = 1
    var patch: Patch
    var userPatches: [Patch]
    var selectedID: UUID
}

@MainActor
final class SynthModel: ObservableObject {
    let audio = AudioController()
    @Published var patch = Patch.factory[0]
    @Published var userPatches: [Patch] = []
    @Published var selectedID = Patch.factory[0].id
    @Published var dirty = false
    @Published var errorMessage: String?
    @Published var octave = 4
    @Published var heldNotes: Set<Int> = []
    @Published var showKeyboard: Bool { didSet { defaults.set(showKeyboard, forKey: "showKeyboard") } }
    @Published var showHints: Bool { didSet { defaults.set(showHints, forKey: "showHints") } }
    @Published var master: Double { didSet { defaults.set(master, forKey: "master"); audio.setParameter(Parameter.master.rawValue, Float(master)) } }
    private let defaults: UserDefaults
    private let storageURL: URL
    private var saveTask: DispatchWorkItem?
    private var noteOwners: [Int: Set<String>] = [:]
    private var persistenceSuspended = false

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showKeyboard = defaults.object(forKey: "showKeyboard") == nil ? true : defaults.bool(forKey: "showKeyboard")
        showHints = defaults.object(forKey: "showHints") == nil ? true : defaults.bool(forKey: "showHints")
        let savedMaster = defaults.object(forKey: "master") as? Double ?? 0.6
        master = savedMaster.isFinite ? min(1, max(0, savedMaster)) : 0.6
        let base = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AmberFM", isDirectory: true)
        storageURL = base.appendingPathComponent("session.json")
        loadSession()
        applyPatch()
    }

    var patches: [Patch] { Patch.factory + userPatches }
    func value(_ parameter: Parameter) -> Double { parameter == .master ? master : patch.values[parameter.rawValue] }
    func binding(_ parameter: Parameter) -> Binding<Double> {
        Binding(get: { self.value(parameter) }, set: { self.set(parameter, $0) })
    }
    func set(_ parameter: Parameter, _ value: Double) {
        guard value.isFinite else { return }
        let safe = min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
        guard self.value(parameter) != safe else { return }
        if parameter == .master { master = safe; return }
        patch.values[parameter.rawValue] = safe
        dirty = true
        let enabled = Effect.allCases.first { $0.mix == parameter }.map { patch.enabledEffects.contains($0) } ?? true
        audio.setParameter(parameter.rawValue, enabled ? Float(safe) : 0)
        scheduleSave()
    }
    func toggle(_ effect: Effect) {
        if patch.enabledEffects.contains(effect) { patch.enabledEffects.remove(effect) }
        else { patch.enabledEffects.insert(effect) }
        audio.setParameter(effect.mix.rawValue, patch.enabledEffects.contains(effect) ? Float(value(effect.mix)) : 0)
        dirty = true
        scheduleSave()
    }
    func select(_ preset: Patch) {
        patch = preset
        selectedID = preset.id
        dirty = false
        applyPatch()
        scheduleSave()
    }
    func adjacentPreset(_ delta: Int) {
        let list = patches
        let current = list.firstIndex { $0.id == selectedID } ?? 0
        select(list[(current + delta + list.count) % list.count])
    }
    func savePreset(name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty else { return }
        var saved = patch
        saved.id = UUID()
        saved.name = trimmed
        saved.category = "USER PRESET"
        saved.isFactory = false
        userPatches.append(saved)
        patch = saved
        selectedID = saved.id
        dirty = false
        persist()
    }
    func renamePreset(name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty, let index = userPatches.firstIndex(where: { $0.id == selectedID }) else { return }
        userPatches[index].name = trimmed
        patch.name = trimmed
        persist()
    }
    func updatePreset() {
        guard let index = userPatches.firstIndex(where: { $0.id == selectedID }) else { return }
        userPatches[index] = patch
        dirty = false
        persist()
    }
    func deletePreset() {
        userPatches.removeAll { $0.id == selectedID }
        select(Patch.factory[0])
        persist()
    }
    func applyPatch() {
        for parameter in Parameter.allCases {
            let enabled = Effect.allCases.first { $0.mix == parameter }.map { patch.enabledEffects.contains($0) } ?? true
            audio.setParameter(parameter.rawValue, enabled ? Float(value(parameter)) : 0)
        }
    }
    func play(_ note: Int, owner: String, velocity: Int = 100) {
        guard audio.isRunning else { return }
        let wasEmpty = noteOwners[note, default: []].isEmpty
        noteOwners[note, default: []].insert(owner)
        heldNotes.insert(note)
        if wasEmpty { audio.noteOn(note, velocity: velocity) }
    }
    func release(_ note: Int, owner: String) {
        guard noteOwners[note]?.contains(owner) == true else { return }
        noteOwners[note]?.remove(owner)
        if noteOwners[note]?.isEmpty ?? true {
            noteOwners.removeValue(forKey: note)
            heldNotes.remove(note)
            audio.noteOff(note)
        }
    }
    func releaseAll() {
        noteOwners.removeAll()
        heldNotes.removeAll()
        audio.panic()
    }
    func releaseLocalNotes() {
        for note in noteOwners.keys { audio.noteOff(note) }
        noteOwners.removeAll()
        heldNotes.removeAll()
    }
    func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.persist() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }
    func persist() {
        saveTask?.cancel()
        guard !persistenceSuspended else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = SessionState(patch: patch, userPatches: userPatches, selectedID: selectedID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: storageURL, options: .atomic)
        } catch { errorMessage = "Could not save your sounds: \(error.localizedDescription)" }
    }
    private func loadSession() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let state = try JSONDecoder().decode(SessionState.self, from: data)
            guard state.version == 1, let restored = state.patch.validated() else {
                throw NSError(domain: "AmberFM", code: 1, userInfo: [NSLocalizedDescriptionKey: "The saved session uses an unsupported format."])
            }
            patch = restored
            guard state.userPatches.allSatisfy({ $0.validated() != nil }),
                  Set(state.userPatches.map(\.id)).count == state.userPatches.count,
                  Set(state.userPatches.map(\.id)).isDisjoint(with: Set(Patch.factory.map(\.id))) else {
                throw NSError(domain: "AmberFM", code: 2, userInfo: [NSLocalizedDescriptionKey: "The saved preset library contains invalid entries."])
            }
            userPatches = state.userPatches.map { entry in
                var valid = entry.validated()!
                valid.isFactory = false
                return valid
            }
            selectedID = state.selectedID
            if let original = patches.first(where: { $0.id == selectedID }) { dirty = original != patch }
            else { dirty = true }
        } catch {
            // Preserve an unreadable session before creating a new one.
            let backup = storageURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            patch = Patch.factory[0]
            userPatches = []
            selectedID = patch.id
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                errorMessage = "The previous session could not be read. Its original contents were kept at \(backup.path). Factory sounds are available."
            } catch {
                persistenceSuspended = true
                errorMessage = "The previous session could not be read or backed up. Saving is paused to preserve the original at \(storageURL.path). Check that folder's permissions before restarting."
            }
        }
    }
}
