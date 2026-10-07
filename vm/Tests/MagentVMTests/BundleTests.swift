import Virtualization
import XCTest
@testable import MagentVM

final class BundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "magent-vm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFakeVM(_ name: String, withState: Bool = false) throws -> (VMBundle, VMSpec) {
        let bundle = try VMBundle(name: name, root: root)
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: bundle.diskURL)
        try Data("aux".utf8).write(to: bundle.auxURL)
        if withState { try Data("state".utf8).write(to: bundle.stateURL) }
        let spec = VMSpec(
            cpus: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30,
            display: .init(width: 1920, height: 1080, ppi: 80),
            macAddress: VZMACAddress.randomLocallyAdministered().string,
            hardwareModel: Data([1, 2, 3]),
            machineIdentifier: VZMacMachineIdentifier().dataRepresentation
        )
        try bundle.saveSpec(spec)
        return (bundle, spec)
    }

    func testNameValidation() {
        XCTAssertNoThrow(try VMBundle.validate(name: "golden-15.1_a"))
        for bad in ["", ".hidden", "../escape", "a/b", "has space", "~"] {
            XCTAssertThrowsError(try VMBundle.validate(name: bad), bad)
        }
    }

    func testSpecRoundTrip() throws {
        let (bundle, spec) = try makeFakeVM("vm")
        XCTAssertEqual(try bundle.loadSpec(), spec)
    }

    func testCloneGetsNewIdentityAndDropsState() throws {
        let (source, spec) = try makeFakeVM("golden", withState: true)
        let dest = try VMBundle(name: "task", root: root)
        try source.clone(to: dest, keepIdentity: false)

        let cloned = try dest.loadSpec()
        XCTAssertNotEqual(cloned.machineIdentifier, spec.machineIdentifier)
        XCTAssertNotEqual(cloned.macAddress, spec.macAddress)
        XCTAssertEqual(cloned.hardwareModel, spec.hardwareModel)
        XCTAssertFalse(dest.hasSavedState)
        XCTAssertEqual(try Data(contentsOf: dest.diskURL), Data("disk".utf8))
    }

    func testCloneKeepIdentityKeepsState() throws {
        let (source, spec) = try makeFakeVM("golden", withState: true)
        let dest = try VMBundle(name: "task", root: root)
        try source.clone(to: dest, keepIdentity: true)
        XCTAssertEqual(try dest.loadSpec(), spec)
        XCTAssertTrue(dest.hasSavedState)
    }

    func testCloneRefusesExistingDestination() throws {
        let (source, _) = try makeFakeVM("golden")
        let (dest, _) = try makeFakeVM("task")
        XCTAssertThrowsError(try source.clone(to: dest, keepIdentity: false))
        XCTAssertEqual(try Data(contentsOf: dest.diskURL), Data("disk".utf8), "existing VM must be untouched")
    }

    func testLockIsExclusive() throws {
        let (bundle, _) = try makeFakeVM("vm")
        let fd = try bundle.lock()
        XCTAssertThrowsError(try bundle.lock())
        let dest = try VMBundle(name: "copy", root: root)
        XCTAssertThrowsError(try bundle.clone(to: dest, keepIdentity: false), "can't clone a VM that's running")
        close(fd)
        XCTAssertNoThrow(try bundle.clone(to: dest, keepIdentity: false))
    }

    func testShareParsing() throws {
        let share = try SharedFolder.parse("work=\(root.path):ro")
        XCTAssertEqual(share.name, "work")
        XCTAssertEqual(share.url.path, root.standardizedFileURL.path)
        XCTAssertTrue(share.readOnly)
        XCTAssertFalse(try SharedFolder.parse("work=\(root.path)").readOnly)
        XCTAssertThrowsError(try SharedFolder.parse("no-equals"))
        XCTAssertThrowsError(try SharedFolder.parse("x=/definitely/not/here"))
    }
}
