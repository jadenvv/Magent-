import Foundation
import Virtualization

struct SharedFolder: Equatable {
    let name: String
    let url: URL
    let readOnly: Bool

    /// Parses NAME=PATH or NAME=PATH:ro
    static func parse(_ arg: String) throws -> SharedFolder {
        guard let eq = arg.firstIndex(of: "=") else { throw CLIError.usage("--share expects NAME=PATH[:ro]") }
        let name = String(arg[..<eq])
        var path = String(arg[arg.index(after: eq)...])
        var readOnly = false
        if path.hasSuffix(":ro") {
            readOnly = true
            path.removeLast(3)
        }
        try VMBundle.validate(name: name)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError.usage("--share \(name): \(url.path) is not a directory")
        }
        return SharedFolder(name: name, url: url, readOnly: readOnly)
    }
}

enum VMConfiguration {
    static func make(bundle: VMBundle, spec: VMSpec, shares: [SharedFolder] = []) throws -> VZVirtualMachineConfiguration {
        guard let model = VZMacHardwareModel(dataRepresentation: spec.hardwareModel), model.isSupported else {
            throw CLIError.failed("\(bundle.name): hardware model is missing or not supported on this Mac")
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: spec.machineIdentifier) else {
            throw CLIError.failed("\(bundle.name): machine identifier is corrupt")
        }
        guard let mac = VZMACAddress(string: spec.macAddress) else {
            throw CLIError.failed("\(bundle.name): MAC address '\(spec.macAddress)' is invalid")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxURL)

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = spec.cpus
        config.memorySize = spec.memoryBytes

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: spec.display.width, heightInPixels: spec.display.height, pixelsPerInch: spec.display.ppi
        )]
        config.graphicsDevices = [graphics]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = mac
        config.networkDevices = [network]

        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        if !shares.isEmpty {
            // macOS guests automount this tag at /Volumes/My Shared Files/<name>.
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fs.share = VZMultipleDirectoryShare(directories: Dictionary(uniqueKeysWithValues: shares.map {
                ($0.name, VZSharedDirectory(url: $0.url, readOnly: $0.readOnly))
            }))
            config.directorySharingDevices = [fs]
        }

        try config.validate()
        return config
    }
}
