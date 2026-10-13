import AppKit
import Carbon.HIToolbox

/// Spotlight-style bar for giving the agent a request. Return submits; Esc, the hotkey again,
/// or clicking elsewhere cancels. Non-activating, so the app the agent works in stays frontmost.
@MainActor
final class PromptCoordinator {
    /// Called once per open: the submitted request (already one line), or nil if cancelled.
    var onClose: (String?) -> Void = { _ in }
    /// Called when Return came from a synthetic event instead of the keyboard.
    var onRejectedSubmit: (Int64) -> Void = { _ in }

    private var panel: NSPanel?
    private var field: NSTextField?
    private var hint: NSTextField?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    var isShown: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        let size = NSSize(width: 640, height: 92)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.sharingType = .none

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            return true
        }

        let icon = NSImageView(frame: NSRect(x: 20, y: 46, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = NSColor(red: 0.42, green: 0.55, blue: 1.0, alpha: 1)  // Theme.accent

        let field = NSTextField(frame: NSRect(x: 54, y: 42, width: 566, height: 32))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .light)
        field.placeholderString = "What should the agent do?"
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        let hint = NSTextField(labelWithString: "")
        hint.frame = NSRect(x: 54, y: 16, width: 566, height: 16)
        hint.font = .systemFont(ofSize: 11)

        background.addSubview(icon)
        background.addSubview(field)
        background.addSubview(hint)
        panel.contentView = background

        // Open on the display the user is looking at (the one with the mouse).
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.68))
        }

        self.panel = panel
        self.field = field
        self.hint = hint
        setHint(nil)

        // Return and Esc are handled here rather than by the text field: the field editor maps
        // Esc to autocomplete, and the raw event is needed to check where Return came from.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(submitting: nil) }
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func dismiss() { close(submitting: nil) }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            close(submitting: nil)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Let an input method (e.g. Japanese) use Return to commit its composition.
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            submit(event)
            return true
        default:
            return false
        }
    }

    /// The agent can post synthetic keystrokes, and on-screen text can tell it to. Requiring a
    /// hardware Return (source pid 0) keeps it from submitting requests to itself.
    private func submit(_ event: NSEvent) {
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        guard source == 0 else {
            setHint("Ignored a synthetic Return. Press Return on the keyboard.")
            onRejectedSubmit(source)
            return
        }
        let text = Outbound.singleLine(field?.stringValue ?? "")
        guard !text.isEmpty else { return }
        close(submitting: text)
    }

    private func setHint(_ warning: String?) {
        hint?.stringValue = warning ?? "↩ run      esc cancel"
        hint?.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
    }

    private func close(submitting text: String?) {
        guard let panel else { return }
        self.panel = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.orderOut(nil)
        field = nil
        hint = nil
        onClose(text)
    }
}

/// Borderless panels refuse key status by default, which would leave nowhere to type.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
