import XCTest
@testable import MagentOverlay

final class ProtocolTests: XCTestCase {
    func testParsesActionWithRect() throws {
        let m = try InboundMessage.parse(#"{"type":"action","text":"Click \"Save\"","rect":{"x":10,"y":20,"w":30,"h":40}}"#)
        XCTAssertEqual(m.type, "action")
        XCTAssertEqual(m.text, #"Click "Save""#)
        XCTAssertEqual(m.rect?.cgRect, CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testNullRectClearsHighlight() throws {
        let m = try InboundMessage.parse(#"{"type":"highlight","rect":null}"#)
        XCTAssertNil(m.rect)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try InboundMessage.parse("not json"))
        XCTAssertThrowsError(try InboundMessage.parse(#"{"text":"missing type"}"#))
    }

    func testPrimaryScreenMapsToOrigin() {
        let tl = ScreenGeometry.topLeftFrame(CGRect(x: 0, y: 0, width: 1440, height: 900), primaryHeight: 900)
        XCTAssertEqual(tl, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testSecondaryScreenAboveAndLeft() {
        // AppKit: a 1920x1080 display sitting above-left of a 1440x900 primary.
        let tl = ScreenGeometry.topLeftFrame(CGRect(x: -1920, y: 900, width: 1920, height: 1080), primaryHeight: 900)
        XCTAssertEqual(tl, CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
    }

    func testRefusesDangerousPIDs() {
        XCTAssertNil(AgentControl(pid: 0))   // kill(0) would signal our own group
        XCTAssertNil(AgentControl(pid: 1))   // launchd
        XCTAssertNil(AgentControl(pid: -1))  // kill(-1) signals every process we can reach
        XCTAssertNil(AgentControl(pid: getpid()))
    }

    func testPauseResumeKill() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let control = try XCTUnwrap(AgentControl(pid: child.processIdentifier))

        control.pause()
        XCTAssertTrue(processState(child.processIdentifier).hasPrefix("T"), "expected stopped")
        control.resume()
        XCTAssertFalse(processState(child.processIdentifier).hasPrefix("T"), "expected running")

        control.kill()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    private func processState(_ pid: pid_t) -> String {
        usleep(50_000)
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "state=", "-p", "\(pid)"]
        ps.standardOutput = out
        try? ps.run()
        ps.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
