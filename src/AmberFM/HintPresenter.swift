import AppKit
import SwiftUI

/// The AppKit view keeps its tracking area when SwiftUI redraws a control.
struct HintRegion: NSViewRepresentable {
    let text: String
    let enabled: Bool

    func makeNSView(context: Context) -> HintTrackingView { HintTrackingView() }
    func updateNSView(_ view: HintTrackingView, context: Context) { view.configure(text: text, enabled: enabled) }
    static func dismantleNSView(_ view: HintTrackingView, coordinator: ()) { view.detach() }
}

@MainActor final class HintTrackingView: NSView {
    private(set) var hintText = ""
    private(set) var hintEnabled = false
    private var hintTrackingArea: NSTrackingArea?
    private var previousScreenRect: NSRect?
    var presenter = HintPresenter.shared

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }

    func configure(text: String, enabled: Bool) {
        let changed = hintText != text || hintEnabled != enabled
        hintText = text
        hintEnabled = enabled
        guard changed else { return }
        presenter.cancel(owner: self)
        if enabled { presenter.enter(owner: self) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hintTrackingArea == nil {
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hintTrackingArea = area
        }
        checkGeometry()
    }

    override func layout() {
        super.layout()
        checkGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        previousScreenRect = screenRect
        if window == nil { detach() }
    }

    override func mouseEntered(with event: NSEvent) { presenter.enter(owner: self) }
    override func mouseMoved(with event: NSEvent) { presenter.enter(owner: self) }
    override func mouseExited(with event: NSEvent) { presenter.cancel(owner: self) }

    func detach() { presenter.cancel(owner: self) }

    var screenRect: NSRect? {
        guard let window, !visibleRect.isEmpty else { return nil }
        return window.convertToScreen(convert(visibleRect, to: nil))
    }

    private func checkGeometry() {
        let rect = screenRect
        if let previousScreenRect, previousScreenRect != rect { presenter.cancel(owner: self) }
        previousScreenRect = rect
    }
}

private final class HintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One passive panel, one cancellable dwell timer, and one event monitor for the app.
/// Nothing in this path observes audio telemetry or consumes an input event.
@MainActor final class HintPresenter {
    static let shared = HintPresenter()
    static let dwell: TimeInterval = 0.35

    private struct Environment {
        var pointer: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
        var applicationActive: @MainActor () -> Bool = { NSApp.isActive }
        var windowActive: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow }
        var buttonsPressed: @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    }

    private let environment: Environment
    private weak var owner: HintTrackingView?
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var panel: HintPanel?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var displayedText = ""

    private init(environment: Environment = Environment(), monitorEvents: Bool = true) {
        self.environment = environment
        guard monitorEvents else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                  .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                                                  .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleInteraction(event.type) }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow, self.owner?.window === window else { return }
                    self.dismiss()
                }
            })
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
    }

    fileprivate func enter(owner next: HintTrackingView) {
        guard eligible(next, requireReleasedButtons: false) else { return }
        if environment.buttonsPressed() {
            dismiss()
            owner = next
            return
        }
        // Unchanged SwiftUI updates and mouse movement must not restart the dwell.
        if owner === next, timer != nil || panel?.isVisible == true { return }
        dismiss()
        owner = next
        let token = generation
        let timer = Timer(timeInterval: Self.dwell, repeats: false) { [weak self, weak next] _ in
            MainActor.assumeIsolated {
                guard let self, let next, self.generation == token, self.owner === next else { return }
                self.timer = nil
                guard self.eligible(next) else { self.dismiss(); return }
                self.present(next)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    fileprivate func cancel(owner source: HintTrackingView) {
        // AppKit does not guarantee enter/exit ordering for overlapping tracking areas.
        if owner === source { dismiss() }
    }

    private func eligible(_ source: HintTrackingView, requireReleasedButtons: Bool = true) -> Bool {
        guard source.hintEnabled, !source.hintText.isEmpty, !source.isHiddenOrHasHiddenAncestor,
              let window = source.window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              environment.applicationActive(), environment.windowActive(window),
              !requireReleasedButtons || !environment.buttonsPressed(),
              let rect = source.screenRect, rect.contains(environment.pointer()) else { return false }
        return true
    }

    private func handleInteraction(_ type: NSEvent.EventType) {
        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            if let owner { enter(owner: owner) }
        } else if type == .scrollWheel {
            dismiss()
        } else {
            // Keep only the candidate during a click so resting after mouse-up can show it.
            let candidate = owner
            dismiss()
            owner = candidate
        }
    }

    private func dismiss() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        owner = nil
        displayedText = ""
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func present(_ source: HintTrackingView) {
        guard let window = source.window, let anchor = source.screenRect else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let width: CGFloat = 300
        let label = NSTextField(wrappingLabelWithString: source.hintText)
        label.font = NSFont.systemFont(ofSize: 12)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.isSelectable = false
        label.textColor = NSColor(srgbRed: 0.208, green: 0.231, blue: 0.212, alpha: 1)
        label.setAccessibilityIdentifier("hoverHintText")
        // Measure the actual wrapping cell at the same width used for display.
        let textHeight = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 40) + 2
        let size = NSSize(width: width + 24, height: textHeight + 20)
        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.backgroundColor = NSColor(srgbRed: 0.965, green: 0.945, blue: 0.902, alpha: 1).cgColor
        background.layer?.borderColor = NSColor(srgbRed: 0.65, green: 0.64, blue: 0.58, alpha: 1).cgColor
        background.layer?.borderWidth = 1
        label.frame = NSRect(x: 12, y: 10, width: width, height: textHeight)
        background.addSubview(label)
        panel.contentView = background
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        panel.setFrame(Self.panelFrame(size: size, anchor: anchor, visible: visible), display: true)
        displayedText = source.hintText
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    private func makePanel() -> HintPanel {
        let panel = HintPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel("Control explanation")
        return panel
    }

    private static func panelFrame(size: NSSize, anchor: NSRect, visible: NSRect) -> NSRect {
        let margin: CGFloat = 8
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - size.height - margin
        if y < visible.minY + margin { y = anchor.maxY + margin }
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// Uses actual AppKit views, dwell timer, and panel, with an injected pointer.
    /// It does not inject system input; real tracking delivery is verified in the UI.
    static func selfTest() -> Bool {
        _ = NSApplication.shared
        var pointer = NSPoint.zero
        var active = true
        var pressed = false
        let presenter = HintPresenter(environment: Environment(pointer: { pointer }, applicationActive: { active },
                                                                 windowActive: { _ in true }, buttonsPressed: { pressed }), monitorEvents: false)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let first = HintTrackingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let second = HintTrackingView(frame: NSRect(x: 120, y: 0, width: 100, height: 100))
        first.presenter = presenter
        second.presenter = presenter
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        window.orderBack(nil)
        defer { presenter.dismiss(); window.close() }
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if !value() { failures.append(name); print("FAIL: hover hint \(name)") }
        }
        func wait(_ duration: TimeInterval) {
            let end = Date().addingTimeInterval(duration)
            while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
        }
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        first.configure(text: "First explanation", enabled: true)
        second.configure(text: "Second explanation", enabled: true)
        first.updateTrackingAreas()
        check(first.trackingAreas.count == 1, "native tracking installed")
        check(first.hitTest(NSPoint(x: 20, y: 20)) == nil, "tracking view passes clicks through")
        pointer = NSPoint(x: first.screenRect!.midX, y: first.screenRect!.midY)
        first.mouseEntered(with: event)
        wait(0.15)
        check(presenter.panel?.isVisible != true, "does not show before dwell")
        for _ in 0..<6 { first.configure(text: "First explanation", enabled: true); first.updateTrackingAreas(); wait(0.04) }
        check(presenter.panel?.isVisible == true && presenter.displayedText == "First explanation", "redraws preserve dwell and native presentation")
        check(presenter.panel?.canBecomeKey == false && presenter.panel?.ignoresMouseEvents == true, "panel preserves focus and input")
        wait(0.45)
        check(presenter.panel?.isVisible == true, "stays visible while hovering")
        first.mouseExited(with: event)
        check(presenter.panel?.isVisible != true, "exit hides panel")
        pressed = true
        first.mouseEntered(with: event)
        wait(0.4)
        check(presenter.panel?.isVisible != true, "does not show during click or drag")
        pressed = false
        presenter.handleInteraction(.leftMouseUp)
        wait(0.4)
        check(presenter.panel?.isVisible == true, "resting after click begins a fresh dwell")
        first.mouseExited(with: event)
        first.mouseEntered(with: event)
        pointer = NSPoint(x: second.screenRect!.midX, y: second.screenRect!.midY)
        second.mouseEntered(with: event)
        first.mouseExited(with: event)
        wait(0.4)
        check(presenter.panel?.isVisible == true && presenter.displayedText == "Second explanation", "late exit cannot cancel next target")
        second.configure(text: "Second explanation", enabled: false)
        check(presenter.panel?.isVisible != true, "disabling immediately hides")
        second.configure(text: "Second explanation", enabled: true)
        active = false
        wait(0.4)
        check(presenter.panel?.isVisible != true, "inactive app cannot present pending hint")
        active = true
        second.mouseEntered(with: event)
        wait(0.4)
        check(presenter.panel?.isVisible == true, "repeated hover presents again")
        presenter.handleInteraction(.scrollWheel)
        check(presenter.panel?.isVisible != true, "scroll immediately hides")
        second.mouseEntered(with: event)
        second.removeFromSuperview()
        wait(0.4)
        check(presenter.panel?.isVisible != true, "detached target cancels pending hint")
        let screen = NSRect(x: -1920, y: -100, width: 1920, height: 1080)
        let frame = panelFrame(size: NSSize(width: 324, height: 100), anchor: NSRect(x: -1915, y: -95, width: 30, height: 30), visible: screen)
        check(screen.contains(frame), "placement respects negative screen coordinates")
        if failures.isEmpty { print("FM_SYNTH_HINT_TESTS_PASS: native dwell, presentation, redraw, cancellation, placement, and passive input"); return true }
        return false
    }
}
