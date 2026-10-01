import Foundation
import CDSP

enum SelfTest {
    @MainActor static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message); print("FAIL: \(message)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-model-test-\(UUID().uuidString)", isDirectory: true)
        let suite = "AmberFM.SelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { print("FAIL: isolated defaults unavailable"); return false }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        check(Parameter.allCases.count == Int(FM_PARAMETER_COUNT.rawValue), "Swift/C parameter count matches")
        check(Parameter.reverbMix.rawValue == Int(FM_REVERB_MIX.rawValue), "Swift/C parameter ordering matches")
        check(Set(Patch.factory.map(\.id)).count == Patch.factory.count, "Factory IDs are unique")
        for patch in Patch.factory { check(patch.validated() != nil, "Factory preset \(patch.name) validates") }
        let model = SynthModel(storageDirectory: directory, defaults: defaults)
        check(model.showKeyboard && model.showHints, "First launch shows keyboard and hints")
        model.set(.modIndex, model.value(.modIndex))
        check(!model.dirty, "Unchanged parameter does not mark sound edited")
        model.set(.modRatio, 3.25)
        model.set(.modIndex, 5.4)
        model.toggle(.phaser)
        model.set(.phaserMix, 0.42)
        model.showKeyboard = false
        model.showHints = false
        model.master = 0.31
        model.savePreset(name: "  Copper test  ")
        check(model.userPatches.count == 1 && model.patch.name == "Copper test", "Save creates a named local preset")
        let savedID = model.selectedID
        model.renamePreset(name: "Renamed sound")
        check(model.selectedID == savedID && model.userPatches[0].name == "Renamed sound", "Rename preserves identity")
        model.set(.modIndex, 6.1)
        model.updatePreset()
        check(!model.dirty && model.userPatches[0].values[Parameter.modIndex.rawValue] == 6.1, "Update saves edits")
        model.persist()
        let restored = SynthModel(storageDirectory: directory, defaults: defaults)
        check(restored.selectedID == savedID && restored.patch.name == "Renamed sound", "Preset identity survives reconstruction")
        check(abs(restored.value(.modRatio) - 3.25) < 0.00001, "FM values survive reconstruction")
        check(abs(restored.value(.modIndex) - 6.1) < 0.00001, "Updated sound survives reconstruction")
        check(restored.patch.enabledEffects.contains(.phaser) && restored.value(.phaserMix) == 0.42, "Effect switch and mix survive reconstruction")
        check(!restored.showKeyboard && !restored.showHints, "Keyboard and hover preferences persist")
        check(abs(restored.master - 0.31) < 0.00001, "Master level persists separately")
        restored.set(.modIndex, .nan)
        check(restored.value(.modIndex) == 6.1, "Nonfinite parameter is rejected")
        restored.set(.modIndex, 1e9)
        check(restored.value(.modIndex) == Parameter.modIndex.range.upperBound, "Out-of-range parameter clamps")
        let savedMix = restored.value(.phaserMix)
        restored.toggle(.phaser)
        check(!restored.patch.enabledEffects.contains(.phaser) && restored.value(.phaserMix) == savedMix, "Bypass preserves mix")
        restored.select(Patch.factory[0])
        check(restored.master == 0.31, "Changing sounds does not change master volume")
        restored.select(restored.userPatches[0])
        restored.deletePreset()
        check(restored.userPatches.isEmpty && restored.patch.isFactory, "Delete returns to factory preset")
        let reread = SynthModel(storageDirectory: directory, defaults: defaults)
        check(reread.userPatches.isEmpty, "Deletion persists")
        var malformed = Patch.factory[0]
        malformed.values = [0]
        check(malformed.validated() == nil, "Malformed parameter vector rejected")
        malformed = Patch.factory[0]; malformed.values[0] = .nan
        check(malformed.validated() == nil, "Nonfinite stored preset rejected")
        malformed = Patch.factory[0]; malformed.name = "  "
        check(malformed.validated() == nil, "Blank preset name rejected")
        do {
            var invalidUser = Patch.factory[0]
            invalidUser.id = UUID()
            invalidUser.isFactory = false
            invalidUser.values = [0]
            let invalidSession = SessionState(patch: Patch.factory[0], userPatches: [invalidUser], selectedID: Patch.factory[0].id)
            let brokenBytes = try JSONEncoder().encode(invalidSession)
            let sessionURL = directory.appendingPathComponent("session.json")
            try brokenBytes.write(to: sessionURL)
            let recovered = SynthModel(storageDirectory: directory, defaults: defaults)
            check(recovered.errorMessage != nil, "Invalid library triggers visible recovery")
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("unreadable-") }
            check(backups.count == 1, "Invalid library is backed up before any replacement")
            if let backup = backups.first {
                let backupBytes = try Data(contentsOf: backup)
                check(backupBytes == brokenBytes, "Recovery backup preserves every original byte")
            }
            recovered.persist()
        } catch { failures.append("Recovery test: \(error)") }
        check(AudioController.parserSelfTest(), "MIDI packet parser edge cases")
        if failures.isEmpty { print("AMBER_MODEL_TESTS_PASS: persistence, preferences, validation, and MIDI parsing"); return true }
        print("\(failures.count) model test failures")
        return false
    }
}
