import LaunchcheckCore
import SwiftUI

// MARK: Tokens

enum Tone {
    static let error = Color(red: 0.93, green: 0.30, blue: 0.27)
    static let warning = Color(red: 0.90, green: 0.62, blue: 0.14)
    static let notice = Color.secondary
    static let passed = Color(red: 0.22, green: 0.72, blue: 0.45)
    static let hairline = Color.primary.opacity(0.1)
    static let wash = Color.primary.opacity(0.045)
    static let lift = Color.primary.opacity(0.08)

    static func of(_ severity: Severity) -> Color {
        switch severity {
        case .error: return error
        case .warning: return warning
        case .notice: return notice
        }
    }

    /// Green, amber or red for a score out of 100.
    static func of(score: Int) -> Color {
        score >= 90 ? passed : (score >= 60 ? warning : error)
    }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering README images, where AppKit-backed controls cannot be drawn.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

// MARK: Small pieces

struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct QuietButton: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : .primary)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .background(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous).fill(prominent ? Color.primary : Tone.wash))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous).strokeBorder(prominent ? .clear : Tone.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// A box with a hairline edge: the one container shape in the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.wash))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ScoreRing: View {
    let score: Int
    var blocked = false
    var size: CGFloat = 132
    var line: CGFloat = 9

    var body: some View {
        let color = blocked ? Tone.error : Tone.of(score: score)
        ZStack {
            Circle().stroke(Tone.hairline, lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.01, CGFloat(score) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if size >= 44 {
                VStack(spacing: -2) {
                    Text("\(score)")
                        .font(.system(size: size * 0.33, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    if size >= 100 {
                        Text("of 100")
                            .font(.system(size: size * 0.085, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(score) of 100")
    }
}

struct ScoreBar: View {
    let score: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Tone.hairline)
                Capsule().fill(Tone.of(score: score)).frame(width: max(4, geometry.size.width * CGFloat(score) / 100))
            }
        }
        .frame(height: 4)
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A scroll view on screen; a plain stack when drawing README images.
struct Scroller<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // Takes the space it is offered, as a scroll view would, and lets the rest run off the bottom.
            Color.clear.overlay(alignment: .top) { content }.clipped()
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if isSnapshot {
                Text(text.isEmpty ? prompt : text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tone.wash))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tone.hairline))
    }
}

extension Date {
    /// "just now", "3 hours ago", "12 Nov".
    var ago: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d ago" }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}
