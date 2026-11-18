import LaunchcheckCore
import SwiftUI

// MARK: Tokens

/// A color with a light and a dark value, resolved by whatever appearance the view is drawn in.
struct Paint: ShapeStyle {
    let light: Color
    let dark: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? dark : light
    }
}

extension Paint: View {
    var body: some View { Rectangle().fill(self) }
}

enum Tone {
    // Severity. The only hues in the app.
    static let error = Paint(light: Color(red: 0.84, green: 0.22, blue: 0.18), dark: Color(red: 0.98, green: 0.43, blue: 0.38))
    static let warning = Paint(light: Color(red: 0.80, green: 0.51, blue: 0.04), dark: Color(red: 0.96, green: 0.70, blue: 0.26))
    static let passed = Paint(light: Color(red: 0.12, green: 0.58, blue: 0.35), dark: Color(red: 0.35, green: 0.80, blue: 0.54))
    static let notice = Paint(light: Color(white: 0.56), dark: Color(white: 0.52))

    // Surfaces: neutrals leaning a little warm, so the window reads as paper rather than plastic.
    static let surface = Paint(light: Color(red: 0.992, green: 0.989, blue: 0.983), dark: Color(red: 0.108, green: 0.105, blue: 0.101))
    static let sidebar = Paint(light: Color(red: 0.957, green: 0.951, blue: 0.941), dark: Color(red: 0.078, green: 0.076, blue: 0.073))
    static let raised = Paint(light: .white, dark: Color(red: 0.150, green: 0.147, blue: 0.142))
    static let ink = Paint(light: Color(red: 0.10, green: 0.09, blue: 0.08), dark: Color(red: 0.95, green: 0.94, blue: 0.92))

    static let hairline = Color.primary.opacity(0.09)
    static let wash = Color.primary.opacity(0.045)
    static let lift = Color.primary.opacity(0.085)
    static let empty = Color.primary.opacity(0.11)

    static func of(_ severity: Severity) -> Paint {
        switch severity {
        case .error: return error
        case .warning: return warning
        case .notice: return notice
        }
    }

    static func of(_ level: Change.Level) -> Paint {
        switch level {
        case .critical: return error
        case .warning: return warning
        case .info: return notice
        }
    }

    /// Green, amber or red for a score out of 100.
    static func of(score: Int) -> Paint {
        score >= 90 ? passed : (score >= 60 ? warning : error)
    }
}

enum Motion {
    /// Quick and decisive: starts fast, settles gently.
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    static let move = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    static let reveal = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.7)
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

extension Severity {
    var label: String {
        switch self {
        case .error: return "Fix before launch"
        case .warning: return "Should fix"
        case .notice: return "Worth a look"
        }
    }
}

// MARK: Marks

/// Severity, told by shape as well as color: a disc must be fixed, a diamond should be, a small dot is worth a look.
struct Mark: View {
    enum Kind: Equatable {
        case error, warning, notice, passed, none

        init(_ severity: Severity) {
            switch severity {
            case .error: self = .error
            case .warning: self = .warning
            case .notice: self = .notice
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }
    init(_ severity: Severity) { kind = Kind(severity) }

    init(_ level: Change.Level) {
        switch level {
        case .critical: kind = .error
        case .warning: kind = .warning
        case .info: kind = .notice
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .error:
                Circle().fill(Tone.error).frame(width: 8, height: 8)
            case .warning:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Tone.warning).frame(width: 6.5, height: 6.5).rotationEffect(.degrees(45))
            case .notice:
                Circle().fill(Tone.notice).frame(width: 5, height: 5)
            case .passed:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tone.passed)
            case .none:
                Color.clear
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

// MARK: Text

/// A quiet heading above a list, in sentence case as the system writes them.
struct SectionLabel: View {
    let text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let count {
                Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Buttons

struct QuietButton: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent, compact: compact)
    }

    private struct Face: View {
        let configuration: Configuration
        let prominent: Bool
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let radius: CGFloat = compact ? 6 : 8
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(Tone.surface) : AnyShapeStyle(.primary))
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 24 : 30)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Tone.ink.opacity(hovering ? 0.86 : 1)) : AnyShapeStyle(hovering ? Tone.lift : Tone.wash))
                )
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Tone.hairline).opacity(prominent ? 0 : 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.press, value: configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A row that can be pointed at and picked: a wash under the pointer, a firmer one when chosen.
struct RowStyle: ButtonStyle {
    var selected = false
    var inset: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, selected: selected, inset: inset)
    }

    private struct Face: View {
        let configuration: Configuration
        let selected: Bool
        let inset: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, inset)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected || configuration.isPressed ? Tone.lift : (hovering ? Tone.wash : Color.clear))
                        // Rows that sit flush with their column still get a wash that clears the text.
                        .padding(.horizontal, inset == 0 ? -8 : 0)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Score

struct ScoreRing: View {
    let score: Int
    var blocked = false
    var size: CGFloat = 84
    var line: CGFloat = 6

    @State private var shown: CGFloat = 0
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = blocked ? Tone.error : Tone.of(score: score)
        let target = max(0.012, CGFloat(score) / 100)
        ZStack {
            Circle().stroke(Tone.empty, lineWidth: line)
            Circle()
                .trim(from: 0, to: isSnapshot || size < 40 ? target : shown)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if size >= 44 {
                Text("\(score)")
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard size >= 40 else { return }
            if reduceMotion { shown = target } else { withAnimation(Motion.reveal) { shown = target } }
        }
        .onChange(of: score) { _, _ in
            if reduceMotion { shown = target } else { withAnimation(Motion.reveal) { shown = target } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(score) of 100")
    }
}

struct ScoreBar: View {
    let score: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Tone.empty)
                Capsule().fill(Tone.of(score: score)).frame(width: max(3, geometry.size.width * CGFloat(score) / 100))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// The score over the last few checks: a line, with the latest point marked.
struct Trend: View {
    let scores: [Int]
    var color: Paint = Tone.notice

    var body: some View {
        GeometryReader { geometry in
            let points = Self.points(for: scores, in: geometry.size)
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                ForEach(Array(points.dropLast().enumerated()), id: \.offset) { _, point in
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 3, height: 3).position(point)
                }
                if let last = points.last {
                    Circle().fill(Tone.surface).frame(width: 9, height: 9).position(last)
                    Circle().fill(color).frame(width: 6, height: 6).position(last)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score over the last \(scores.count) checks: \(scores.map(String.init).joined(separator: ", "))")
    }

    static func points(for scores: [Int], in size: CGSize) -> [CGPoint] {
        guard scores.count > 1 else { return scores.isEmpty ? [] : [CGPoint(x: size.width - 5, y: size.height / 2)] }
        let low = Double(scores.min() ?? 0), high = Double(scores.max() ?? 100)
        let span = max(8, high - low)
        let middle = (high + low) / 2
        let inset: CGFloat = 5
        return scores.enumerated().map { index, score in
            let x = inset + (size.width - inset * 2) * CGFloat(index) / CGFloat(scores.count - 1)
            let y = size.height / 2 - CGFloat((Double(score) - middle) / span) * (size.height - inset * 2)
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: Containers

/// A scroll view on screen; a plain stack when drawing README images.
struct Scroller<Content: View>: View {
    /// The id of a row to keep in view, for moving through a list with the arrow keys.
    var target: String?
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // Takes the space it is offered, as a scroll view would, and lets the rest run off the bottom.
            Color.clear.overlay(alignment: .top) { content }.clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView { content }
                    .onChange(of: target) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
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
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tone.wash))
    }
}

/// Two or three choices side by side, the chosen one lifted.
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: selection == value ? .semibold : .medium))
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Tone.raised)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                .opacity(selection == value ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tone.wash))
    }
}

/// A label and its value, for the facts about a page.
struct Fact: View {
    let label: String
    let value: String
    var tone: Paint?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(tone.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

extension Date {
    /// "just now", "3 h ago", "12 Nov".
    var ago: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d ago" }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}
