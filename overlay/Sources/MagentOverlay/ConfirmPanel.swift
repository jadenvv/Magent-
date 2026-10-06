import AppKit
import SwiftUI

/// Interactive confirmation for destructive/outbound actions. Requests queue and are shown
/// one at a time. The panel is non-activating so the agent's target app keeps focus.
@MainActor
final class ConfirmCoordinator {
    struct Request { let id: String; let text: String }

    /// (request, approved)
    var onDecision: (Request, Bool) -> Void = { _, _ in }
    /// Called when a click is rejected as not coming from real hardware.
    var onRejectedClick: (Int64) -> Void = { _ in }

    private var queue: [Request] = []
    private var panel: NSPanel?

    func request(id: String, text: String) {
        queue.append(Request(id: id, text: text))
        showNextIfIdle()
    }

    func dismissAll() {
        panel?.close()
        panel = nil
        queue.removeAll()
    }

    private func showNextIfIdle() {
        guard panel == nil, let next = queue.first else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent needs confirmation"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ConfirmView(text: next.text) { [weak self] approved in
            self?.decide(approved)
        })
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func decide(_ approved: Bool) {
        // Deny is always honored; approval must come from a physical click.
        if approved {
            let (human, sourcePID) = Self.currentClickIsFromHardware()
            guard human else { onRejectedClick(sourcePID); return }
        }
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()
        panel?.close()
        panel = nil
        onDecision(request, approved)
        showNextIfIdle()
    }

    /// The agent can post synthetic mouse events, so without this check it could approve its own
    /// request. Hardware events carry source pid 0; CGEventPost'd events carry the poster's pid.
    /// Also requires the event to be fresh, so an AXPress that runs while a stale human event is
    /// still `currentEvent` doesn't pass. Defense in depth — the executor must enforce the gate too.
    private static func currentClickIsFromHardware() -> (Bool, Int64) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              let cg = event.cgEvent
        else { return (false, -1) }
        let source = cg.getIntegerValueField(.eventSourceUnixProcessID)
        let fresh = ProcessInfo.processInfo.systemUptime - event.timestamp < 1.0
        return (source == 0 && fresh, source)
    }
}

private struct ConfirmView: View {
    let text: String
    let decide: (Bool) -> Void
    /// Brief delay before Allow is clickable, so a click aimed at whatever was under the
    /// panel when it popped up can't approve by accident.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Deny") { decide(false) }
                Button("Allow") { decide(true) }
                    .disabled(!armed)
            }
            // Keep the buttons out of the AX tree so an AX-driven agent can't find and press them.
            .accessibilityHidden(true)
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true }
        }
    }
}
