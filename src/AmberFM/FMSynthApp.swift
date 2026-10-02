import SwiftUI
import AppKit

@main
enum FMSynthMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--hint-self-test") {
            exit(HintPresenter.selfTest() ? 0 : 1)
        }
        FMSynthApplication.main()
    }
}

struct FMSynthApplication: App {
    @NSApplicationDelegateAdaptor(FMSynthAppDelegate.self) private var appDelegate
    @StateObject private var model = SynthModel()
    var body: some Scene {
        Window("FM Synth", id: "instrument") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.keyboard = ComputerKeyboard(model: model)
                    appDelegate.configureWindow()
                }
                .onChange(of: model.showKeyboard) { _, shown in appDelegate.resizeForKeyboard(shown) }
        }
        .defaultSize(width: 1220, height: 875)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Toggle("Show keyboard", isOn: $model.showKeyboard).keyboardShortcut("k", modifiers: [.command])
                Toggle("Show hover explanations", isOn: $model.showHints)
            }
            CommandMenu("Instrument") {
                Button(model.audio.isRunning ? "Stop audio" : "Start audio") {
                    if model.audio.isRunning { model.audio.stop() } else { model.audio.start() }
                }.keyboardShortcut(" ", modifiers: [.command])
                Button("All notes off") { model.releaseAll() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

@MainActor
final class FMSynthAppDelegate: NSObject, NSApplicationDelegate {
    var model: SynthModel?
    var keyboard: ComputerKeyboard?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        configureWindow()
    }
    func configureWindow() {
        guard let window = NSApp.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.925, green: 0.902, blue: 0.843, alpha: 1)
        window.isMovableByWindowBackground = false
    }
    func resizeForKeyboard(_ shown: Bool) {
        guard let window = NSApp.windows.first, !window.styleMask.contains(.fullScreen) else { return }
        let oldFrame = window.frame
        let limit = window.screen?.visibleFrame.height ?? 1200
        let height = min(limit, max(window.minSize.height, oldFrame.height + (shown ? 140 : -140)))
        window.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - height, width: oldFrame.width, height: height), display: true, animate: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        model?.persist()
        model?.releaseAll()
        model?.audio.stop()
    }
}

@MainActor
final class ComputerKeyboard {
    static let letters = ["a", "w", "s", "e", "d", "f", "t", "g", "y", "h", "u", "j", "k", "o", "l", "p", ";"]
    static let semitones = Array(0...16)
    private weak var model: SynthModel?
    private var monitor: Any?
    private var pressed: [UInt16: Int] = [:]

    init(model: SynthModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        if event.type == .keyUp, let note = pressed.removeValue(forKey: event.keyCode) {
            model.release(note, owner: "computer-\(event.keyCode)")
            return nil
        }
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              NSApp.keyWindow?.sheetParent == nil,
              NSApp.keyWindow?.attachedSheet == nil,
              !(NSApp.keyWindow?.firstResponder is NSTextView),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        if event.keyCode == 53 { pressed.removeAll(); model.releaseAll(); return nil }
        if key == "z" || key == "x" {
            if !event.isARepeat {
                pressed.removeAll(); model.releaseLocalNotes()
                model.octave = min(7, max(1, model.octave + (key == "z" ? -1 : 1)))
            }
            return nil
        }
        guard let index = Self.letters.firstIndex(of: key) else { return event }
        if !event.isARepeat {
            let note = model.octave * 12 + 12 + Self.semitones[index]
            if let prior = pressed[event.keyCode] { model.release(prior, owner: "computer-\(event.keyCode)") }
            pressed[event.keyCode] = note
            model.play(note, owner: "computer-\(event.keyCode)")
        }
        return nil
    }
}
