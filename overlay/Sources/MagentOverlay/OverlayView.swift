import SwiftUI

/// Full-screen, click-through content for one display. Every display gets a copy so the
/// cursor and highlight follow the agent across monitors; only the primary shows the HUD.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    /// This screen's top-left corner in global top-left coordinates.
    let origin: CGPoint
    let size: CGSize
    let safe: EdgeInsets
    let isPrimary: Bool

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - origin.x, y: p.y - origin.y)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            StateBorder(state: model.state)

            if let r = model.highlight {
                let o = local(r.origin)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2.5))
                    .frame(width: r.width + 8, height: r.height + 8)
                    .position(x: o.x + r.width / 2, y: o.y + r.height / 2)
            }

            if let p = model.pulse {
                PulseRing().id(p.id).position(local(p.point))
            }

            if let c = model.cursor {
                let l = local(c)
                // The arrow's tip is the shape's (0,0); .position places the frame's center.
                GhostCursor()
                    .frame(width: 16, height: 22)
                    .position(x: l.x + 8, y: l.y + 11)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .top) {
            if isPrimary { StatusBar(model: model).padding(.top, safe.top + 8) }
        }
        .overlay(alignment: .bottomTrailing) {
            if isPrimary {
                ActionLog(entries: model.log.suffix(14))
                    .padding(.bottom, safe.bottom + 12)
                    .padding(.trailing, safe.trailing + 12)
            }
        }
        // Short animations: the overlay should keep up with the agent, not slow the viewer down.
        .animation(.easeOut(duration: 0.16), value: model.cursor)
        .animation(.easeOut(duration: 0.12), value: model.highlight)
        .animation(.easeOut(duration: 0.2), value: model.state)
    }
}

private struct StateBorder: View {
    let state: AgentState

    var body: some View {
        Rectangle()
            .strokeBorder(state.color, lineWidth: state == .paused ? 5 : 3)
            .opacity(state == .done ? 0.35 : 0.85)
            .allowsHitTesting(false)
    }
}

private struct StatusBar: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(model.state.color).frame(width: 8, height: 8)
                Text(model.state.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.state.color)
            }
            if !model.caption.isEmpty {
                Text(model.caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("⌃⌥⌘P pause   ⌃⌥⌘K kill")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(model.state.color.opacity(0.6), lineWidth: 1))
        .frame(maxWidth: 760)
    }
}

private struct ActionLog: View {
    let entries: ArraySlice<LogEntry>

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entries) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%6.1fs", e.elapsed))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(e.level.symbol)
                            .foregroundStyle(e.level.color)
                            .frame(width: 10)
                        Text(e.text)
                            .foregroundStyle(.white.opacity(e.level == .info ? 0.75 : 0.95))
                            .lineLimit(2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 380, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .animation(.easeOut(duration: 0.15), value: entries.last?.id)
        }
    }
}

/// Arrow distinct from the real cursor (colored fill) so the user can tell the two apart.
struct GhostCursor: View {
    var body: some View {
        ArrowShape()
            .fill(Theme.accent)
            .overlay(ArrowShape().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 13, sy = rect.height / 20
        let pts: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: 0, y: 17), .init(x: 4.5, y: 13), .init(x: 7.5, y: 20),
            .init(x: 10, y: 19), .init(x: 7, y: 12.5), .init(x: 13, y: 12.5),
        ]
        var p = Path()
        p.addLines(pts.map { CGPoint(x: rect.minX + $0.x * sx, y: rect.minY + $0.y * sy) })
        p.closeSubpath()
        return p
    }
}

private struct PulseRing: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(Theme.accent, lineWidth: 2)
            .frame(width: 36, height: 36)
            .scaleEffect(expanded ? 1.0 : 0.2)
            .opacity(expanded ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.35)) { expanded = true } }
    }
}
