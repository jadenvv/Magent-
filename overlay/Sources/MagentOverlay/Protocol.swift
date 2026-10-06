import Foundation

// Wire protocol between the agent core and the overlay. See overlay/README.md.
//
// Agent -> overlay (stdin): one JSON object per line. Easy to emit from C with fprintf.
// Overlay -> agent (stdout): space-separated tokens per line, so a C agent can sscanf
// them without a JSON parser, e.g. "confirm del-1 allow", "paused", "resumed".
//
// All coordinates are global screen points with a top-left origin at the primary
// display (the same space CGEvent and AXUIElement frames use).

struct WireRect: Decodable, Equatable {
    let x: Double, y: Double, w: Double, h: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct WirePoint: Decodable, Equatable {
    let x: Double, y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// One inbound message. Flat with optional fields so new message types don't need new structs.
struct InboundMessage: Decodable, Equatable {
    let type: String
    let text: String?
    let level: String?
    let state: String?
    let id: String?
    let rect: WireRect?
    let cursor: WirePoint?
    let x: Double?
    let y: Double?

    var point: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func parse(_ line: String) throws -> InboundMessage {
        try JSONDecoder().decode(InboundMessage.self, from: Data(line.utf8))
    }
}

enum Outbound {
    private static let queue = DispatchQueue(label: "magent.overlay.outbound")

    /// Writes one line of space-separated tokens. Tokens must not contain whitespace.
    /// Fire-and-forget; ignored if the agent has closed its end of the pipe.
    static func send(_ tokens: String...) {
        let line = tokens.joined(separator: " ") + "\n"
        queue.async {
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }
    }
}

enum InputReader {
    /// Reads stdin on a background thread and delivers lines on the main queue, in order.
    static func start(onLine: @escaping @MainActor (String) -> Void, onEOF: @escaping @MainActor () -> Void) {
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { onEOF() } }
        }
        thread.name = "magent.overlay.stdin"
        thread.start()
    }
}
