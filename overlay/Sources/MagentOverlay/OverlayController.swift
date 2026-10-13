import AppKit

/// Routes protocol messages and hotkeys into the model, windows, and agent signals.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private lazy var windows = OverlayWindows(model: model)
    private let confirm = ConfirmCoordinator()
    private let prompt = PromptCoordinator()
    private var agent: AgentControl?
    /// Daemon mode: the agent executable, started with the daemon and kept for every request.
    /// Nil when the agent launched us (`--pid`) or in the demo.
    private let agentPath: String?
    /// The agent we started (daemon mode), and a counter so a late line or exit from an
    /// earlier agent is never mistaken for the current one.
    private var process: AgentProcess?
    private var generation = 0
    /// Daemon mode: prompts sent to the agent that it hasn't finished yet (one done/error each).
    private var pendingPrompts = 0
    /// Bumped whenever a finished state is shown or a new request starts, so a stale
    /// "go idle" timer from an earlier request does nothing.
    private var finishSeq = 0
    /// True while the agent is paused only because the prompt bar is open.
    private var pausedForPrompt = false
    /// A status that arrived while paused. It was written before the SIGSTOP, so applying it
    /// right away would show "Running" (or "Done") for an agent that is actually stopped.
    private var statusAfterResume: AgentState?

    init(agent: AgentControl?, agentPath: String? = nil) {
        self.agent = agent
        self.agentPath = agentPath
        if agentPath != nil {
            model.state = .idle
            Outbound.setTarget(nil)
        }
    }

    var isDaemon: Bool { agentPath != nil }

    func start() {
        windows.rebuild()

        confirm.onDecision = { [weak self] request, approved in
            Outbound.send("confirm", request.id, approved ? "allow" : "deny")
            self?.model.append("\(approved ? "Approved" : "Denied"): \(request.text)", level: approved ? .ok : .warn)
        }
        confirm.onRejectedClick = { [weak self] sourcePID in
            self?.model.append("Ignored non-hardware click on Allow (source pid \(sourcePID))", level: .warn)
        }
        prompt.onClose = { [weak self] text in
            self?.promptClosed(text)
        }
        prompt.onRejectedSubmit = { [weak self] sourcePID in
            self?.model.append("Ignored non-hardware Return in the prompt bar (source pid \(sourcePID))", level: .warn)
        }

        let okPause = HotKeyCenter.shared.register(id: 1, keyCode: HotKeys.pauseKeyCode, modifiers: HotKeys.modifiers) {
            MainActor.assumeIsolated { self.togglePause() }
        }
        let okKill = HotKeyCenter.shared.register(id: 2, keyCode: HotKeys.killKeyCode, modifiers: HotKeys.modifiers) {
            // Signal first, before any UI work, so the kill lands as fast as possible.
            self.agent?.kill()
            MainActor.assumeIsolated { self.didKill() }
        }
        let okPrompt = HotKeyCenter.shared.register(id: 3, keyCode: HotKeys.promptKeyCode, modifiers: HotKeys.modifiers) {
            MainActor.assumeIsolated { self.togglePrompt() }
        }
        if !okPause || !okKill || !okPrompt {
            model.append("Failed to register a global hotkey (taken by another app?)", level: .error)
        }

        // Start the agent now so it has loaded its models before the first request.
        if isDaemon { spawnAgent() }
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
        // Anything arriving after a kill was buffered before the signal; ignore it.
        if model.state == .killed || model.state == .idle { return }

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
            if let s = m.state.flatMap(AgentState.init(rawValue:)), s != .killed, s != .paused, s != .idle {
                if isDaemon && (s == .done || s == .error) {
                    finishPrompt(s)
                } else if model.state == .paused {
                    statusAfterResume = s
                } else {
                    apply(s)
                }
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

    private func apply(_ s: AgentState) {
        model.state = s
        if s == .done { model.clearTargets() }
    }

    // MARK: Daemon mode

    /// Starts the agent without a request. It stays up across requests until it exits or
    /// is killed; the next request after that starts a new one.
    private func spawnAgent() {
        guard let agentPath, process == nil else { return }
        generation += 1
        let gen = generation
        do {
            let proc = try AgentProcess(
                path: agentPath,
                onLine: { [weak self] line in
                    guard let self, self.generation == gen else { return }
                    self.handle(line: line)
                },
                onExit: { [weak self] status in
                    self?.agentExited(generation: gen, status: status)
                }
            )
            guard let control = AgentControl(pid: proc.pid) else {
                model.append("Agent exited immediately", level: .error)
                return
            }
            process = proc
            agent = control
            Outbound.setTarget(proc.toAgent)
        } catch {
            model.append("Couldn't start agent: \(error)", level: .error)
        }
    }

    /// Sends a request to the agent, starting one first if there is none.
    private func sendRequest(_ text: String) {
        spawnAgent()
        guard process != nil else { return }
        if model.state != .running && model.state != .paused {
            model.state = .running
            statusAfterResume = nil
        }
        pendingPrompts += 1
        finishSeq += 1
        Outbound.sendPrompt(text)
    }

    /// The agent finished one prompt. Show the result only once every prompt sent so far is
    /// finished; a request typed while another was running keeps the overlay running.
    private func finishPrompt(_ s: AgentState) {
        pendingPrompts = max(0, pendingPrompts - 1)
        if pendingPrompts > 0 {
            model.append(s == .done ? "Request done" : "Request failed", level: s == .done ? .ok : .error)
        } else if model.state == .paused {
            statusAfterResume = s
        } else {
            showFinished(s)
        }
    }

    /// Shows done/error for 3 s, then goes idle. The agent stays up for the next request.
    private func showFinished(_ s: AgentState) {
        apply(s)
        finishSeq += 1
        let seq = finishSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.finishSeq == seq, self.pendingPrompts == 0,
                  self.model.state == .done || self.model.state == .error else { return }
            self.model.state = .idle
            self.model.clearTargets()
        }
    }

    private func agentExited(generation gen: Int, status: Int32) {
        guard gen == generation else { return }
        Outbound.setTarget(nil)
        process = nil
        agent = nil
        pendingPrompts = 0
        pausedForPrompt = false
        statusAfterResume = nil
        confirm.dismissAll()

        let ok = AgentProcess.succeeded(status: status)
        if model.state != .killed {
            model.append("Agent \(AgentProcess.describe(status: status))", level: ok ? .ok : .error)
            // The daemon's agent is meant to stay up, so any exit we didn't cause is an error,
            // even one after the last request finished.
            model.state = .error
        }
        // Leave the final state up briefly, then go back to idle unless a new request
        // started in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == gen, self.process == nil else { return }
            self.model.state = .idle
            self.model.clearTargets()
        }
    }

    // MARK: Agent launched us

    func agentDisconnected() {
        guard model.state != .killed else { return }
        model.append("Agent disconnected", level: .warn)
        quitSoon()
    }

    // MARK: Controls

    var isPaused: Bool { model.state == .paused }

    func togglePause() {
        guard !model.state.isFinal else { return }
        // The user has taken over; closing the prompt bar must not undo their choice.
        pausedForPrompt = false
        if model.state == .paused {
            resume(note: "Resumed by user")
        } else {
            pause(note: "Paused by user")
        }
    }

    private func pause(note: String) {
        agent?.pause()
        model.state = .paused
        model.append(note, level: .warn)
        Outbound.send("paused")
    }

    private func resume(note: String) {
        agent?.resume()
        model.state = .running
        model.append(note, level: .info)
        if let s = statusAfterResume {
            statusAfterResume = nil
            if isDaemon && (s == .done || s == .error) {
                // A request typed while paused may still be pending; then stay running.
                if pendingPrompts == 0 { showFinished(s) }
            } else {
                apply(s)
            }
        }
        // The screen may have changed while paused; the agent should re-observe before acting.
        Outbound.send("resumed")
    }

    func togglePrompt() {
        if prompt.isShown { prompt.dismiss(); return }
        guard model.state != .killed else { return }
        // The bar takes keyboard focus, so a running agent's keystrokes would land in it and
        // the user's typing could reach the agent's target. Hold the agent until it closes.
        if model.state == .running {
            pause(note: "Paused while you type a request")
            pausedForPrompt = true
        }
        prompt.show()
    }

    private func promptClosed(_ text: String?) {
        if let text {
            model.append("Request: \(text)", level: .action)
            if isDaemon {
                // Sent before "resumed", so the agent reads the request first.
                sendRequest(text)
            } else {
                // Sent before "resumed", so the agent reads the request first.
                Outbound.sendPrompt(text)
            }
        }
        if pausedForPrompt {
            pausedForPrompt = false
            if model.state == .paused { resume(note: "Resumed") }
        }
    }

    private func didKill() {
        // Idle with an agent still counts: the daemon's warm agent was just killed.
        guard model.state != .killed, model.state != .idle || agent != nil else { return }
        model.state = .killed
        model.clearTargets()
        model.caption = "Agent killed"
        model.append("Killed by user", level: .error)
        confirm.dismissAll()
        pausedForPrompt = false
        prompt.dismiss()
        // A daemon stays up for the next request; agentExited() takes it back to idle.
        if !isDaemon { quitSoon() }
    }

    /// Called when launchd (or Ctrl-C) stops a daemon: don't leave an agent running with no
    /// overlay and no kill switch.
    func shutdown() {
        agent?.kill()
        exit(0)
    }

    private func quitSoon() {
        // Brief delay so the final state is visible, then leave no UI behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
    }
}
