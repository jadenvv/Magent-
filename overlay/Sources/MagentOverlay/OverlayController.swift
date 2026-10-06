import AppKit

/// Routes protocol messages and hotkeys into the model, windows, and agent signals.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private lazy var windows = OverlayWindows(model: model)
    private let confirm = ConfirmCoordinator()
    private let agent: AgentControl?

    init(agent: AgentControl?) {
        self.agent = agent
    }

    func start() {
        windows.rebuild()

        confirm.onDecision = { [weak self] request, approved in
            Outbound.send("confirm", request.id, approved ? "allow" : "deny")
            self?.model.append("\(approved ? "Approved" : "Denied"): \(request.text)", level: approved ? .ok : .warn)
        }
        confirm.onRejectedClick = { [weak self] sourcePID in
            self?.model.append("Ignored non-hardware click on Allow (source pid \(sourcePID))", level: .warn)
        }

        let okPause = HotKeyCenter.shared.register(id: 1, keyCode: HotKeys.pauseKeyCode, modifiers: HotKeys.modifiers) {
            MainActor.assumeIsolated { self.togglePause() }
        }
        let okKill = HotKeyCenter.shared.register(id: 2, keyCode: HotKeys.killKeyCode, modifiers: HotKeys.modifiers) {
            // Signal first, before any UI work, so the kill lands as fast as possible.
            self.agent?.kill()
            MainActor.assumeIsolated { self.didKill() }
        }
        if !okPause || !okKill {
            model.append("Failed to register a global hotkey (taken by another app?)", level: .error)
        }
    }

    // MARK: Inbound

    func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            handle(try InboundMessage.parse(trimmed))
        } catch {
            model.append("Bad message: \(trimmed.prefix(80))", level: .error)
        }
    }

    func handle(_ m: InboundMessage) {
        // While paused or killed the agent is stopped; anything still arriving was buffered
        // before the signal. Drop target visuals so they don't suggest live activity.
        if model.state == .killed { return }

        switch m.type {
        case "action":
            // Announces the next action: caption + log line, plus highlight/cursor if it has a target.
            let text = m.text ?? ""
            model.caption = text
            model.append(text, level: .action)
            model.highlight = m.rect?.cgRect
            if let c = m.cursor?.cgPoint ?? m.rect.map({ CGPoint(x: $0.cgRect.midX, y: $0.cgRect.midY) }) {
                model.cursor = c
            }
        case "cursor":
            if let p = m.point { model.cursor = p }
        case "click":
            if let p = m.point { model.click(at: p) }
        case "highlight":
            model.highlight = m.rect?.cgRect
        case "caption":
            model.caption = m.text ?? ""
        case "log":
            model.append(m.text ?? "", level: m.level.flatMap(LogLevel.init(rawValue:)) ?? .info)
        case "status":
            if let s = m.state.flatMap(AgentState.init(rawValue:)), s != .killed, s != .paused {
                model.state = s
                if s == .done { model.clearTargets() }
            }
        case "confirm":
            guard let id = m.id, !id.isEmpty, !id.contains(where: \.isWhitespace) else {
                model.append("confirm needs an id with no whitespace", level: .error)
                return
            }
            model.append("Waiting for confirmation: \(m.text ?? "")", level: .warn)
            confirm.request(id: id, text: m.text ?? "")
        case "clear":
            model.clearTargets()
        default:
            model.append("Unknown message type: \(m.type)", level: .warn)
        }
    }

    func agentDisconnected() {
        guard model.state != .killed else { return }
        model.append("Agent disconnected", level: .warn)
        quitSoon()
    }

    // MARK: Controls

    var isPaused: Bool { model.state == .paused }

    func togglePause() {
        guard !model.state.isFinal else { return }
        if model.state == .paused {
            agent?.resume()
            model.state = .running
            model.append("Resumed by user", level: .info)
            // The screen may have changed while paused; the agent should re-observe before acting.
            Outbound.send("resumed")
        } else {
            agent?.pause()
            model.state = .paused
            model.append("Paused by user", level: .warn)
            Outbound.send("paused")
        }
    }

    private func didKill() {
        guard model.state != .killed else { return }
        model.state = .killed
        model.clearTargets()
        model.caption = "Agent killed"
        model.append("Killed by user", level: .error)
        confirm.dismissAll()
        quitSoon()
    }

    private func quitSoon() {
        // Brief delay so the final state is visible, then leave no UI behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
    }
}
