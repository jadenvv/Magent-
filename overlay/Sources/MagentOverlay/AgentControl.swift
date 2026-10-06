import Darwin

/// Pauses and kills the agent with signals, so the controls work even if the agent is
/// blocked in a model request or its loop is hung — it never has to cooperate.
final class AgentControl {
    let pid: pid_t
    /// Set when the agent leads its own process group; signals then also reach
    /// anything it spawned (shell commands, osascript, etc.).
    private let group: pid_t?

    /// Returns nil for pids that would make kill() dangerous (0, 1, negative, or ourselves).
    init?(pid: pid_t) {
        guard pid > 1, pid != getpid(), Darwin.kill(pid, 0) == 0 else { return nil }
        self.pid = pid

        let agentGroup = getpgid(pid)
        // If the agent launched us we inherited its group; leave it so a group kill doesn't take us out too.
        if agentGroup == getpgrp() { _ = setpgid(0, 0) }
        if agentGroup == pid, agentGroup > 1, getpgrp() != agentGroup {
            group = agentGroup
        } else {
            group = nil
        }
    }

    @discardableResult
    func send(_ signal: Int32) -> Bool {
        if let group { return killpg(group, signal) == 0 }
        return Darwin.kill(pid, signal) == 0
    }

    func pause() { send(SIGSTOP) }
    func resume() { send(SIGCONT) }
    func kill() { send(SIGKILL) }
}
