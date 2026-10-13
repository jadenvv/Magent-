import XCTest
@testable import MagentOverlay

@MainActor
final class AgentProcessTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes an executable /bin/sh script standing in for the agent.
    private func stubAgent(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("agent.sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testRoundTripAndExitStatus() async throws {
        let path = try stubAgent("""
        read line
        echo "{\\"type\\":\\"log\\",\\"text\\":\\"got $line\\"}"
        exit 3
        """)
        let gotLine = expectation(description: "line")
        let exited = expectation(description: "exit")
        var line = ""
        var status: Int32 = -1
        let proc = try AgentProcess(path: path, onLine: {
            line = $0
            gotLine.fulfill()
        }, onExit: {
            status = $0
            exited.fulfill()
        })
        try proc.toAgent.write(contentsOf: Data("prompt open notes\n".utf8))
        await fulfillment(of: [gotLine, exited], timeout: 5)

        XCTAssertEqual(line, #"{"type":"log","text":"got prompt open notes"}"#)
        XCTAssertEqual(AgentProcess.describe(status: status), "exited 3")
        XCTAssertFalse(AgentProcess.succeeded(status: status))
    }

    /// The agent must lead its own group, so a kill also takes out what it spawned.
    func testKillReachesAgentChildren() async throws {
        let path = try stubAgent("""
        sleep 30 &
        echo $!
        wait
        """)
        let gotPID = expectation(description: "child pid")
        let exited = expectation(description: "exit")
        var childPID: pid_t = 0
        var status: Int32 = -1
        let proc = try AgentProcess(path: path, onLine: {
            childPID = pid_t($0) ?? 0
            gotPID.fulfill()
        }, onExit: {
            status = $0
            exited.fulfill()
        })
        await fulfillment(of: [gotPID], timeout: 5)
        XCTAssertEqual(getpgid(proc.pid), proc.pid, "agent should lead its own process group")
        XCTAssertNotEqual(getpgid(proc.pid), getpgrp(), "agent must not share the overlay's group")

        let control = try XCTUnwrap(AgentControl(pid: proc.pid))
        control.kill()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(AgentProcess.describe(status: status), "killed by signal 9")

        // The orphaned sleep is reaped by launchd shortly after it dies.
        var alive = true
        for _ in 0..<50 where alive {
            alive = Darwin.kill(childPID, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertFalse(alive, "agent's child survived the kill")
    }

    func testImmediateExitIsDeliveredAfterInitialization() async throws {
        let path = try stubAgent("exit 0\n")
        let exited = expectation(description: "exit")
        exited.assertForOverFulfill = true
        var initialized = false
        let proc = try AgentProcess(path: path, onLine: { _ in }, onExit: { status in
            XCTAssertTrue(initialized)
            XCTAssertTrue(AgentProcess.succeeded(status: status))
            exited.fulfill()
        })
        initialized = true
        await fulfillment(of: [exited], timeout: 5)
        withExtendedLifetime(proc) {}
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try AgentProcess(path: dir.appendingPathComponent("nope").path, onLine: { _ in }, onExit: { _ in }))
    }
}
