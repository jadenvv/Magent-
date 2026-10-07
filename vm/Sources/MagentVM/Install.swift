import Foundation
import Virtualization

struct InstallOptions {
    var name: String
    var ipsw: URL?
    var cpus = 4
    var memoryGB = 8
    var diskGB = 64
    /// Non-Retina by default: the guest's points equal pixels, so agent screenshots and
    /// click coordinates share one space, and screenshots stay small.
    var display = VMSpec.Display(width: 1920, height: 1080, ppi: 80)
}

@MainActor
enum Installer {
    static func run(_ options: InstallOptions) async throws {
        let bundle = try VMBundle(name: options.name)
        guard !FileManager.default.fileExists(atPath: bundle.url.path) else {
            throw VMStoreError.alreadyExists(options.name)
        }

        // The installer image is cached outside the bundle so a failed install doesn't lose the download.
        let ipsw: URL
        if let local = options.ipsw { ipsw = local } else { ipsw = try await downloadLatestIPSW() }
        log("Loading \(ipsw.lastPathComponent)")
        let image = try await loadRestoreImage(ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw CLIError.failed("this installer image isn't supported on this Mac")
        }

        let spec = VMSpec(
            cpus: min(max(options.cpus, requirements.minimumSupportedCPUCount),
                      VZVirtualMachineConfiguration.maximumAllowedCPUCount),
            memoryBytes: min(max(UInt64(options.memoryGB) << 30, requirements.minimumSupportedMemorySize),
                             VZVirtualMachineConfiguration.maximumAllowedMemorySize),
            diskBytes: UInt64(options.diskGB) << 30,
            display: options.display,
            macAddress: VZMACAddress.randomLocallyAdministered().string,
            hardwareModel: requirements.hardwareModel.dataRepresentation,
            machineIdentifier: VZMacMachineIdentifier().dataRepresentation
        )

        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        let lock = try bundle.lock()
        defer { close(lock) }
        do {
            try createSparseDisk(at: bundle.diskURL, bytes: spec.diskBytes)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxURL, hardwareModel: requirements.hardwareModel, options: [])
            try bundle.saveSpec(spec)

            let vm = VZVirtualMachine(configuration: try VMConfiguration.make(bundle: bundle, spec: spec))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            log("Installing macOS \(image.operatingSystemVersion.string) (\(image.buildVersion)): \(spec.cpus) CPUs, \(spec.memoryBytes >> 30) GB RAM, \(spec.diskBytes >> 30) GB disk")
            let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                FileHandle.standardError.write(Data(String(format: "\r  %3.0f%%", progress.fractionCompleted * 100).utf8))
            }
            try await installer.install()
            observation.invalidate()
            FileHandle.standardError.write(Data("\n".utf8))
        } catch {
            // Only removes the bundle directory this install created.
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }

        log("""
        Installed '\(options.name)'. Next, finish Setup Assistant in a window:
          magent-vm run \(options.name) --window
        """)
    }

    private static func downloadLatestIPSW() async throws -> URL {
        let image = try await withCheckedThrowingContinuation { (c: CheckedContinuation<VZMacOSRestoreImage, Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { c.resume(with: $0) }
        }
        let cache = VMBundle.defaultRoot.appending(path: ".ipsw")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let dest = cache.appending(path: "\(image.buildVersion).ipsw")
        if FileManager.default.fileExists(atPath: dest.path) {
            log("Using cached installer \(dest.path)")
            return dest
        }

        // curl rather than URLSession: resumable (-C -) for a ~15 GB file, with its own progress bar.
        let partial = dest.appendingPathExtension("partial")
        log("Downloading macOS \(image.operatingSystemVersion.string) (\(image.buildVersion)) installer")
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--fail", "--location", "--progress-bar", "-C", "-", "-o", partial.path, image.url.absoluteString]
        try curl.run()
        await withCheckedContinuation { c in
            curl.terminationHandler = { _ in c.resume() }
        }
        guard curl.terminationStatus == 0 else {
            throw CLIError.failed("download failed (curl exit \(curl.terminationStatus)); rerun to resume")
        }
        try FileManager.default.moveItem(at: partial, to: dest)
        return dest
    }

    private static func loadRestoreImage(_ url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { c in
            VZMacOSRestoreImage.load(from: url) { c.resume(with: $0) }
        }
    }

    /// Sparse on APFS: the file reports its full size but only uses space as the guest writes.
    private static func createSparseDisk(at url: URL, bytes: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CLIError.failed("could not create \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }
}

extension OperatingSystemVersion {
    var string: String { "\(majorVersion).\(minorVersion).\(patchVersion)" }
}
