import AppKit
import Virtualization

let usageText = """
usage:
  magent-vm install <name> [--ipsw PATH] [--cpus N] [--memory GB] [--disk GB]
  magent-vm run <name> [--window] [--fresh] [--save-on-quit] [--share NAME=PATH[:ro]]...
  magent-vm clone <source> <dest> [--keep-identity]
  magent-vm list
  magent-vm latest

  install        download the latest macOS this Mac supports and install it into a new VM
  run            boot the VM (resuming from saved state if present) in a corner preview;
                 --window opens a normal interactive window (use it for Setup Assistant)
                 --fresh discards any saved state and cold boots
                 --save-on-quit saves the running state on quit, so the next run resumes in seconds
                 --share exposes a host folder at /Volumes/My Shared Files/NAME in the guest
  clone          instant APFS copy; gets a new identity unless --keep-identity (which keeps saved state)
  latest         print the newest macOS installer this Mac supports

VMs live in ~/.magent/vms (override with MAGENT_VM_HOME).
Build with scripts/build.sh; `swift run` drops the virtualization entitlement.
"""

enum CLIError: LocalizedError {
    case usage(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let m): "\(m)\n\n\(usageText)"
        case .failed(let m): m
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func fail(_ error: Error) -> Never {
    log("magent-vm: \(error.localizedDescription)")
    exit(1)
}

/// Minimal flag parser: positional args plus --flags, some taking a value.
struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: [String]] = [:]

    init(_ raw: ArraySlice<String>, valued: Set<String>, boolean: Set<String>) throws {
        var rest = raw
        while let arg = rest.popFirst() {
            if valued.contains(arg) {
                guard let v = rest.popFirst() else { throw CLIError.usage("\(arg) needs a value") }
                values[arg, default: []].append(v)
            } else if boolean.contains(arg) {
                flags.insert(arg)
            } else if arg.hasPrefix("--") {
                throw CLIError.usage("unknown option \(arg)")
            } else {
                positional.append(arg)
            }
        }
    }

    func int(_ flag: String) throws -> Int? {
        guard let s = values[flag]?.last else { return nil }
        guard let v = Int(s), v > 0 else { throw CLIError.usage("\(flag) expects a positive integer") }
        return v
    }
}

@MainActor
func runVM(_ args: Args) throws {
    guard args.positional.count == 1 else { throw CLIError.usage("run takes one VM name") }
    let bundle = try VMBundle(name: args.positional[0])
    let spec = try bundle.loadSpec()
    let lock = try bundle.lock()
    _ = lock  // held until exit

    let shares = try (args.values["--share"] ?? []).map(SharedFolder.parse)
    let mode: VMWindowController.Mode = args.flags.contains("--window") ? .window : .corner

    let app = NSApplication.shared
    app.setActivationPolicy(mode == .window ? .regular : .accessory)

    let runner = try VMRunner(bundle: bundle, spec: spec, shares: shares, saveOnQuit: args.flags.contains("--save-on-quit"))
    let controller = VMWindowController(vm: runner.vm, name: bundle.name, display: spec.display, mode: mode)
    runner.onStatus = { controller.status = $0 }
    controller.onCloseRequest = { runner.shutdown() }

    // Ctrl-C / kill from the terminal go through the same graceful path; a second one forces it.
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { runner.shutdown() } }
        source.resume()
        signalSources.append(source)
    }

    Task { @MainActor in
        do {
            try await runner.start(fresh: args.flags.contains("--fresh"))
        } catch {
            fail(error)
        }
    }
    app.run()
}

var signalSources: [DispatchSourceSignal] = []

MainActor.assumeIsolated {
    let argv = CommandLine.arguments.dropFirst()
    guard let command = argv.first else {
        log(usageText)
        exit(2)
    }
    let rest = argv.dropFirst()

    do {
        switch command {
        case "install":
            let args = try Args(rest, valued: ["--ipsw", "--cpus", "--memory", "--disk"], boolean: [])
            guard args.positional.count == 1 else { throw CLIError.usage("install takes one VM name") }
            var options = InstallOptions(name: args.positional[0])
            options.ipsw = args.values["--ipsw"]?.last.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            options.cpus = try args.int("--cpus") ?? options.cpus
            options.memoryGB = try args.int("--memory") ?? options.memoryGB
            options.diskGB = try args.int("--disk") ?? options.diskGB
            Task { @MainActor in
                do { try await Installer.run(options); exit(0) } catch { fail(error) }
            }
            dispatchMain()

        case "run":
            try runVM(try Args(rest, valued: ["--share"], boolean: ["--window", "--fresh", "--save-on-quit"]))

        case "clone":
            let args = try Args(rest, valued: [], boolean: ["--keep-identity"])
            guard args.positional.count == 2 else { throw CLIError.usage("clone takes <source> <dest>") }
            let source = try VMBundle(name: args.positional[0])
            let dest = try VMBundle(name: args.positional[1])
            try source.clone(to: dest, keepIdentity: args.flags.contains("--keep-identity"))
            log("Cloned \(source.name) -> \(dest.name)")

        case "list":
            for b in VMBundle.list() {
                let spec = try? b.loadSpec()
                let desc = spec.map { "\($0.cpus) CPU  \($0.memoryBytes >> 30) GB RAM  \($0.diskBytes >> 30) GB disk" } ?? "unreadable spec"
                print("\(b.name)\t\(desc)\(b.hasSavedState ? "  [saved state]" : "")")
            }

        case "latest":
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image):
                    print("macOS \(image.operatingSystemVersion.string) (\(image.buildVersion))\n\(image.url.absoluteString)")
                    exit(0)
                case .failure(let error):
                    fail(error)
                }
            }
            dispatchMain()

        case "-h", "--help", "help":
            print(usageText)

        default:
            throw CLIError.usage("unknown command '\(command)'")
        }
    } catch {
        fail(error)
    }
}
