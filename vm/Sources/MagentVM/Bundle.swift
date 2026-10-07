import Foundation
import Virtualization

/// Everything needed to rebuild the VM's configuration. The hardware model and machine
/// identifier are the VM's identity: lose them and the disk won't boot.
struct VMSpec: Codable, Equatable {
    struct Display: Codable, Equatable {
        var width: Int
        var height: Int
        var ppi: Int
    }

    var cpus: Int
    var memoryBytes: UInt64
    var diskBytes: UInt64
    var display: Display
    var macAddress: String
    var hardwareModel: Data
    var machineIdentifier: Data
}

enum VMStoreError: LocalizedError {
    case invalidName(String)
    case notFound(String)
    case alreadyExists(String)
    case inUse(String)
    case cloneFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidName(let n): "invalid name '\(n)': use letters, digits, '.', '_' or '-'"
        case .notFound(let n): "no VM named '\(n)'"
        case .alreadyExists(let n): "a VM named '\(n)' already exists"
        case .inUse(let n): "VM '\(n)' is in use by another magent-vm process"
        case .cloneFailed(let file, let err):
            "could not clone \(file): \(String(cString: strerror(err))) (source and destination must be on the same APFS volume)"
        }
    }
}

/// A VM on disk: <root>/<name>/{disk.img, aux.img, spec.json, state.vzvmsave}.
struct VMBundle {
    let name: String
    let url: URL

    var diskURL: URL { url.appending(path: "disk.img") }
    var auxURL: URL { url.appending(path: "aux.img") }
    var specURL: URL { url.appending(path: "spec.json") }
    /// Saved memory/CPU state. Only valid together with the disk exactly as it was at save time.
    var stateURL: URL { url.appending(path: "state.vzvmsave") }
    private var lockURL: URL { url.appending(path: ".lock") }

    static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["MAGENT_VM_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".magent/vms")
    }

    static func validate(name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !name.isEmpty, !name.hasPrefix("."), name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw VMStoreError.invalidName(name)
        }
    }

    init(name: String, root: URL = VMBundle.defaultRoot) throws {
        try Self.validate(name: name)
        self.name = name
        self.url = root.appending(path: name)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: specURL.path) }
    var hasSavedState: Bool { FileManager.default.fileExists(atPath: stateURL.path) }

    func loadSpec() throws -> VMSpec {
        guard exists else { throw VMStoreError.notFound(name) }
        return try JSONDecoder().decode(VMSpec.self, from: Data(contentsOf: specURL))
    }

    func saveSpec(_ spec: VMSpec) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(spec).write(to: specURL, options: .atomic)
    }

    func discardSavedState() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Exclusive lock held for the life of the process (released by the OS on exit),
    /// so two processes can't run or clone the same disk at once.
    func lock() throws -> Int32 {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw VMStoreError.inUse(name)
        }
        return fd
    }

    /// APFS copy-on-write clone: instant and takes no extra space until the copies diverge.
    ///
    /// By default the clone gets a new machine identifier and MAC address (so two copies can
    /// run side by side without looking like the same Mac) and the saved state is dropped,
    /// because a saved state only restores into an identical configuration.
    /// `keepIdentity` keeps both, for throwaway per-task copies that should resume in seconds.
    func clone(to dest: VMBundle, keepIdentity: Bool) throws {
        guard exists else { throw VMStoreError.notFound(name) }
        guard !dest.exists, !FileManager.default.fileExists(atPath: dest.url.path) else {
            throw VMStoreError.alreadyExists(dest.name)
        }
        let sourceLock = try lock()
        defer { close(sourceLock) }

        try FileManager.default.createDirectory(at: dest.url, withIntermediateDirectories: true)
        do {
            var files = [(diskURL, dest.diskURL), (auxURL, dest.auxURL)]
            if keepIdentity, hasSavedState { files.append((stateURL, dest.stateURL)) }
            for (src, dst) in files {
                // CLONE_FORCE: fail rather than silently fall back to a full 50+ GB copy.
                guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 else {
                    throw VMStoreError.cloneFailed(src.lastPathComponent, errno)
                }
            }
            var spec = try loadSpec()
            if !keepIdentity {
                spec.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
                spec.macAddress = VZMACAddress.randomLocallyAdministered().string
            }
            try dest.saveSpec(spec)
        } catch {
            // Only removes the directory this call just created.
            try? FileManager.default.removeItem(at: dest.url)
            throw error
        }
    }

    static func list(root: URL = VMBundle.defaultRoot) -> [VMBundle] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { try? VMBundle(name: $0, root: root) }.filter(\.exists)
    }
}
