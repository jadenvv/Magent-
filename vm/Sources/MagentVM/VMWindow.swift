import AppKit
import Virtualization

/// VM display view that drops all input unless `acceptsInput` is on, so glancing at or
/// hovering over the preview can't disturb what the agent is doing inside the VM.
final class GuardedVMView: VZVirtualMachineView {
    var acceptsInput = false
    var onDoubleClick: () -> Void = {}

    override var acceptsFirstResponder: Bool { acceptsInput && super.acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if acceptsInput { super.mouseDown(with: e) } else if e.clickCount == 2 { onDoubleClick() }
    }
    override func mouseUp(with e: NSEvent) { if acceptsInput { super.mouseUp(with: e) } }
    override func mouseDragged(with e: NSEvent) { if acceptsInput { super.mouseDragged(with: e) } }
    override func mouseMoved(with e: NSEvent) { if acceptsInput { super.mouseMoved(with: e) } }
    override func mouseEntered(with e: NSEvent) { if acceptsInput { super.mouseEntered(with: e) } }
    override func mouseExited(with e: NSEvent) { if acceptsInput { super.mouseExited(with: e) } }
    override func rightMouseDown(with e: NSEvent) { if acceptsInput { super.rightMouseDown(with: e) } }
    override func rightMouseUp(with e: NSEvent) { if acceptsInput { super.rightMouseUp(with: e) } }
    override func otherMouseDown(with e: NSEvent) { if acceptsInput { super.otherMouseDown(with: e) } }
    override func otherMouseUp(with e: NSEvent) { if acceptsInput { super.otherMouseUp(with: e) } }
    override func scrollWheel(with e: NSEvent) { if acceptsInput { super.scrollWheel(with: e) } }
    override func keyDown(with e: NSEvent) { if acceptsInput { super.keyDown(with: e) } }
    override func keyUp(with e: NSEvent) { if acceptsInput { super.keyUp(with: e) } }
    override func flagsChanged(with e: NSEvent) { if acceptsInput { super.flagsChanged(with: e) } }
}

/// Two presentations of the same VM display:
/// - corner: small floating preview in the bottom-left, view-only until "Interact" is ticked;
///   double-click or "Expand" toggles a large size. Bottom-left keeps clear of the overlay's log.
/// - window: an ordinary interactive window, for Setup Assistant and hands-on work.
@MainActor
final class VMWindowController: NSObject, NSWindowDelegate {
    enum Mode { case corner, window }

    let window: NSWindow
    private let vmView = GuardedVMView()
    private let mode: Mode
    private let aspect: CGSize
    private let name: String
    private var expanded = false
    private let interactToggle = NSButton(checkboxWithTitle: "Interact", target: nil, action: nil)

    var onCloseRequest: () -> Void = {}

    var status = "" {
        didSet { window.title = "\(name) · \(status)" }
    }

    init(vm: VZVirtualMachine, name: String, display: VMSpec.Display, mode: Mode) {
        self.mode = mode
        self.name = name
        self.aspect = CGSize(width: display.width, height: display.height)

        switch mode {
        case .corner:
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = panel
        case .window:
            window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
        }
        super.init()

        vmView.virtualMachine = vm
        vmView.automaticallyReconfiguresDisplay = false
        vmView.onDoubleClick = { [weak self] in self?.toggleExpanded() }
        window.contentView = vmView
        window.contentAspectRatio = aspect
        window.delegate = self
        window.isReleasedWhenClosed = false
        status = "starting"

        switch mode {
        case .corner:
            setInteractive(false)
            addCornerControls()
            window.setFrame(cornerFrame(), display: false)
            window.orderFrontRegardless()
        case .window:
            setInteractive(true)
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let width = min(CGFloat(display.width), visible.width * 0.9)
            window.setContentSize(NSSize(width: width, height: width * aspect.height / aspect.width))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    private func addCornerControls() {
        interactToggle.target = self
        interactToggle.action = #selector(interactToggled)
        interactToggle.controlSize = .small
        let expand = NSButton(title: "Expand", target: self, action: #selector(toggleExpanded))
        expand.controlSize = .small
        expand.bezelStyle = .accessoryBarAction
        let stack = NSStackView(views: [interactToggle, expand])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func interactToggled() {
        setInteractive(interactToggle.state == .on)
    }

    private func setInteractive(_ on: Bool) {
        vmView.acceptsInput = on
        vmView.capturesSystemKeys = on
        interactToggle.state = on ? .on : .off
        if on {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(vmView)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    @objc private func toggleExpanded() {
        expanded.toggle()
        window.setFrame(expanded ? expandedFrame() : cornerFrame(), display: true, animate: true)
    }

    private var visibleFrame: NSRect {
        (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func frame(contentWidth: CGFloat) -> NSRect {
        let content = NSRect(x: 0, y: 0, width: contentWidth, height: contentWidth * aspect.height / aspect.width)
        return window.frameRect(forContentRect: content)
    }

    private func cornerFrame() -> NSRect {
        var f = frame(contentWidth: 380)
        f.origin = NSPoint(x: visibleFrame.minX + 16, y: visibleFrame.minY + 16)
        return f
    }

    private func expandedFrame() -> NSRect {
        var f = frame(contentWidth: min(1280, visibleFrame.width * 0.8))
        f.origin = NSPoint(x: visibleFrame.midX - f.width / 2, y: visibleFrame.midY - f.height / 2)
        return f
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest()
        return false
    }
}
