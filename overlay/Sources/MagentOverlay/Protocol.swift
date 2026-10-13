import Foundation

// Wire protocol between the agent core and the overlay. See overlay/README.md.
//
// Agent -> overlay (stdin): one JSON object per line. Easy to emit from C with fprintf.
// Overlay -> agent (stdout): space-separated tokens per line, so a C agent can sscanf
// them without a JSON parser, e.g. "confirm del-1 allow", "paused", "resumed".
// The one exception is "prompt <text>", whose text runs to the end of the line.
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
    /// Where events go: our stdout when the agent launched us, the agent's stdin when we
    /// launched it (daemon mode), nil while no agent is running. Only touched on `queue`.
    nonisolated(unsafe) private static var target: FileHandle? = .standardOutput

    /// Switches the destination. Ordered with `send`, so nothing meant for the old agent
    /// reaches the new one.
    static func setTarget(_ handle: FileHandle?) {
        queue.async { target = handle }
    }

    /// Writes one line of space-separated tokens. Tokens must not contain whitespace.
    /// Fire-and-forget; ignored if the agent has closed its end of the pipe.
    static func send(_ tokens: String...) {
        let line = tokens.joined(separator: " ") + "\n"
        queue.async {
            try? target?.write(contentsOf: Data(line.utf8))
        }
    }

    /// `prompt <text>`: a request typed into the prompt bar.
    static func sendPrompt(_ text: String) {
        send("prompt", singleLine(text))
    }

    private static let lineBreaks = CharacterSet.newlines
        .union(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x1F)))
        .union(CharacterSet(charactersIn: "\u{7F}"))

    /// Newlines and C0 controls become spaces so a request is always exactly one line.
    /// (Not all of Cc/Cf: that would also strip the zero-width joiners inside emoji.)
    static func singleLine(_ text: String) -> String {
        return text.components(separatedBy: lineBreaks)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

enum InputReader {
    /// Reads `fd` on a background thread and delivers lines on the main queue, in order.
    /// Takes ownership of `fd` and closes it at EOF.
    static func start(fd: Int32 = STDIN_FILENO, onLine: @escaping @MainActor (String) -> Void, onEOF: @escaping @MainActor () -> Void) {
        let thread = Thread {
            if let file = fdopen(fd, "r") {
                var buffer: UnsafeMutablePointer<CChar>?
                var capacity = 0
                while true {
                    let count = getline(&buffer, &capacity, file)
                    guard count > 0, let buffer else { break }
                    // getline's length includes embedded NULs; do not silently truncate them.
                    let bytes = UnsafeRawBufferPointer(start: buffer, count: count)
                    let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
                    DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
                }
                free(buffer)
                fclose(file)
            } else {
                close(fd)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { onEOF() } }
        }
        thread.name = "magent.overlay.input"
        thread.start()
    }
}
