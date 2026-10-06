import SwiftUI

enum AgentState: String {
    case running, paused, done, error, killed

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .running: Theme.accent
        case .paused: .orange
        case .done: .green
        case .error, .killed: .red
        }
    }

    /// Terminal states ignore pause/resume.
    var isFinal: Bool { self == .done || self == .killed }
}

enum LogLevel: String {
    case info, ok, warn, error, action

    var symbol: String {
        switch self {
        case .info: "·"
        case .ok: "✓"
        case .warn: "!"
        case .error: "✗"
        case .action: "→"
        }
    }

    var color: Color {
        switch self {
        case .info: .white.opacity(0.6)
        case .ok: .green
        case .warn: .orange
        case .error: .red
        case .action: Theme.accent
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    /// Seconds since the overlay started. Display only — not a measurement; the timing harness owns those.
    let elapsed: TimeInterval
    let level: LogLevel
    let text: String
}

struct ClickPulse: Equatable {
    let id: Int
    let point: CGPoint
}

enum Theme {
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let panel = Color.black.opacity(0.72)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: AgentState = .running
    @Published var caption = ""
    /// Global top-left coordinates (see Protocol.swift).
    @Published var cursor: CGPoint?
    @Published var highlight: CGRect?
    @Published var pulse: ClickPulse?
    @Published private(set) var log: [LogEntry] = []

    private let start = Date()
    private var pulseCounter = 0
    private let maxLog = 200

    func append(_ text: String, level: LogLevel = .info) {
        log.append(LogEntry(elapsed: Date().timeIntervalSince(start), level: level, text: text))
        if log.count > maxLog { log.removeFirst(log.count - maxLog) }
    }

    func click(at point: CGPoint) {
        cursor = point
        pulseCounter += 1
        pulse = ClickPulse(id: pulseCounter, point: point)
    }

    func clearTargets() {
        cursor = nil
        highlight = nil
        pulse = nil
        caption = ""
    }
}
