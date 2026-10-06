import AppKit

// magent-overlay --pid <agent pid>   read protocol lines from stdin, control that process
// magent-overlay --demo              scripted session, no agent

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: magent-overlay --pid <agent-pid> | --demo\n".utf8))
    exit(2)
}

// A closed stdout must not kill the overlay (and with it the kill switch).
signal(SIGPIPE, SIG_IGN)

var args = CommandLine.arguments.dropFirst()
var demo = false
var agentPID: pid_t?
while let arg = args.popFirst() {
    switch arg {
    case "--demo": demo = true
    case "--pid":
        guard let value = args.popFirst(), let pid = pid_t(value) else { usage() }
        agentPID = pid
    default: usage()
    }
}
if demo == (agentPID != nil) { usage() }

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

    let controller = OverlayController(agent: agent)
    controller.start()

    if demo {
        Demo.run(controller)
    } else {
        InputReader.start(onLine: controller.handle(line:), onEOF: controller.agentDisconnected)
    }

    app.run()
}
