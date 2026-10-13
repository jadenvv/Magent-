import AppKit

// magent-overlay --pid <agent pid>    read protocol lines from stdin, control that process
// magent-overlay --daemon <agent>     stay up; start <agent> once and send it every request
// magent-overlay --demo               scripted session, no agent

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: magent-overlay --pid <agent-pid> | --daemon <agent-executable> | --demo\n".utf8))
    exit(2)
}

// A closed stdout must not kill the overlay (and with it the kill switch).
signal(SIGPIPE, SIG_IGN)

/// Kept alive for the life of the process.
var signalSources: [DispatchSourceSignal] = []

var args = CommandLine.arguments.dropFirst()
var demo = false
var agentPID: pid_t?
var agentPath: String?
while let arg = args.popFirst() {
    switch arg {
    case "--demo": demo = true
    case "--pid":
        guard let value = args.popFirst(), let pid = pid_t(value) else { usage() }
        agentPID = pid
    case "--daemon":
        guard let value = args.popFirst() else { usage() }
        agentPath = value
    default: usage()
    }
}
if [demo, agentPID != nil, agentPath != nil].filter({ $0 }).count != 1 { usage() }
if let agentPath, access(agentPath, X_OK) != 0 {
    FileHandle.standardError.write(Data("magent-overlay: \(agentPath) is not an executable file\n".utf8))
    exit(1)
}

MainActor.assumeIsolated {
    var agent: AgentControl?
    if let agentPID {
        guard let control = AgentControl(pid: agentPID) else {
            FileHandle.standardError.write(Data("magent-overlay: no controllable process with pid \(agentPID)\n".utf8))
            exit(1)
        }
        agent = control
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = OverlayController(agent: agent, agentPath: agentPath)
    controller.start()

    if demo {
        Demo.run(controller)
    } else if agentPath != nil {
        // launchd stops a job with SIGTERM. Kill the agent first so it never outlives the
        // overlay (and with it the kill switch).
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { controller.shutdown() } }
            source.resume()
            signalSources.append(source)
        }
    } else {
        InputReader.start(onLine: controller.handle(line:), onEOF: controller.agentDisconnected)
    }

    app.run()
}
