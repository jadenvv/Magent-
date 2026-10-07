import Foundation
import Virtualization

/// Owns one running VM: start (from saved state when possible), graceful shutdown, and save.
@MainActor
final class VMRunner: NSObject, VZVirtualMachineDelegate {
    let bundle: VMBundle
    private(set) var vm: VZVirtualMachine
    private let configuration: VZVirtualMachineConfiguration
    private let saveOnQuit: Bool
    private var shuttingDown = false

    var onStatus: (String) -> Void = { _ in }
    var onExit: (Int32) -> Void = { exit($0) }

    init(bundle: VMBundle, spec: VMSpec, shares: [SharedFolder], saveOnQuit: Bool) throws {
        self.bundle = bundle
        self.saveOnQuit = saveOnQuit
        configuration = try VMConfiguration.make(bundle: bundle, spec: spec, shares: shares)
        if saveOnQuit {
            do { try configuration.validateSaveRestoreSupport() } catch {
                throw CLIError.failed("--save-on-quit isn't supported for this configuration: \(error.localizedDescription)")
            }
        }
        vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
    }

    /// Resumes from the bundle's saved state if there is one, otherwise cold boots.
    ///
    /// The saved state is deleted as soon as the VM starts running in either path: from then on
    /// the disk diverges from what the saved memory expects, and restoring that state later
    /// onto the changed disk could corrupt the guest's filesystem.
    func start(fresh: Bool) async throws {
        if bundle.hasSavedState, !fresh {
            onStatus("restoring")
            let started = Date()
            do {
                try await vm.restoreMachineStateFrom(url: bundle.stateURL)
                bundle.discardSavedState()
                try await vm.resume()
                log(String(format: "Restored saved state in %.1fs", Date().timeIntervalSince(started)))
                onStatus("running")
                return
            } catch {
                log("Restore failed (\(error.localizedDescription)); cold booting instead")
                if vm.state != .stopped {
                    vm = VZVirtualMachine(configuration: configuration)
                    vm.delegate = self
                }
            }
        }
        bundle.discardSavedState()
        onStatus("booting")
        try await vm.start()
        onStatus("running")
    }

    /// Saves state (with --save-on-quit) or asks the guest to shut down, forcing it after a timeout.
    func shutdown() {
        guard !shuttingDown else {
            // Second request while a graceful stop is pending: force it.
            log("Forcing stop")
            vm.stop { _ in MainActor.assumeIsolated { self.onExit(0) } }
            return
        }
        shuttingDown = true

        Task { @MainActor in
            if saveOnQuit, vm.state == .running {
                onStatus("saving")
                do {
                    try await vm.pause()
                    try await vm.saveMachineStateTo(url: bundle.stateURL)
                    log("Saved state to \(bundle.stateURL.path)")
                } catch {
                    bundle.discardSavedState()
                    log("Save failed (\(error.localizedDescription)); stopping without saving")
                }
                try? await vm.stop()
                onExit(0)
                return
            }

            onStatus("shutting down")
            if vm.canRequestStop, (try? vm.requestStop()) != nil {
                // Give the guest time to shut down cleanly; guestDidStop exits early if it does.
                try? await Task.sleep(for: .seconds(30))
                log("Guest didn't shut down within 30s; forcing stop")
            }
            if vm.canStop { try? await vm.stop() }
            onExit(0)
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            log("Guest shut down")
            onExit(0)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            log("VM stopped with error: \(error.localizedDescription)")
            onExit(1)
        }
    }
}
