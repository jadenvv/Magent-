import Darwin
import Foundation

/// Daemon mode: the overlay starts the agent itself and keeps it across requests. The agent reads overlay
/// events on stdin and writes protocol lines to stdout; its stderr goes wherever ours does.
@MainActor
final class AgentProcess {
    struct SpawnError: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    let pid: pid_t
    /// The agent's stdin (overlay -> agent).
    let toAgent: FileHandle
    private var exitSource: DispatchSourceProcess?
    private var reaped = false
    private let onExit: @MainActor (Int32) -> Void

    /// `onLine` gets each line the agent writes to stdout. `onExit` runs once with the raw
    /// wait status, after the process has been reaped.
    init(
        path: String,
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw SpawnError(call: "pipe", code: errno) }
        guard pipe(&fromChild) == 0 else {
            let code = errno
            close(toChild[0]); close(toChild[1])
            throw SpawnError(call: "pipe", code: code)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETPGROUP with group 0: the agent leads its own process group, so pause/kill reach
        // everything it spawns. CLOEXEC_DEFAULT: it inherits only the three fds above, not
        // our pipe ends to other agents. SETSIGDEF: we ignore SIGPIPE/SIGTERM/SIGINT, and
        // ignored signals survive exec, so put them back to default for the agent.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGTERM, SIGINT] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        close(toChild[0])
        close(fromChild[1])
        guard rc == 0 else {
            close(toChild[1])
            close(fromChild[0])
            throw SpawnError(call: "posix_spawn \(path)", code: rc)
        }

        self.pid = pid
        self.toAgent = FileHandle(fileDescriptor: toChild[1], closeOnDealloc: true)
        self.onExit = onExit
        InputReader.start(fd: fromChild[0], onLine: onLine, onEOF: {})

        // Exit is watched on the process, not on stdout EOF: the agent's children inherit
        // its stdout and can hold the pipe open after the agent itself is gone.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reap() }
        }
        exitSource = source
        source.resume()
        // An agent that exits before the source is armed would otherwise never be noticed.
        // Defer delivery until init returns, so the owner can store the new process before
        // an immediately exiting agent invokes onExit.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reap() }
        }
    }

    /// Until we reap it, the exited agent is a zombie, so its pid can't be reused and a
    /// late pause/kill can't hit an unrelated process.
    private func reap() {
        guard !reaped else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        guard result == pid else { return }
        reaped = true
        exitSource?.cancel()
        exitSource = nil
        onExit(status)
    }

    /// "exited 0", "exited 3", "killed by signal 9", from a raw wait status.
    static func describe(status: Int32) -> String {
        let signal = status & 0x7f
        return signal == 0 ? "exited \((status >> 8) & 0xff)" : "killed by signal \(signal)"
    }

    static func succeeded(status: Int32) -> Bool { status == 0 }
}
