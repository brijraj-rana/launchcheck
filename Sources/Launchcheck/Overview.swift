import LaunchcheckCore
import SwiftUI

struct OverviewTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 30) {
                headline
                Tally(report: report)
                PageMap(model: model, report: report)
                HStack(alignment: .top, spacing: 36) {
                    next.frame(maxWidth: .infinity, alignment: .leading)
                    areas.frame(width: 268)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 28)
        }
    }

    // MARK: Verdict, then score

    private var headline: some View {
        let blocked = report.count(.error) > 0
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.verdict)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(report.host) · \(ReportFormat.summary(report)) · \(report.date.ago)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if report.pagesFound > report.pagesChecked {
                    Text("The first \(report.pagesChecked) of \(report.pagesFound) pages were read. Raise the limit in the address bar to read them all.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(report.grade)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(blocked ? Tone.error : Tone.of(score: report.score))
                    if let comparison = model.comparison {
                        Button { model.tab = .changes } label: {
                            Text(Self.delta(comparison))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("See what changed")
                    } else {
                        Text("First check").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    if model.trail.count > 2 {
                        Trend(scores: model.trail, color: blocked ? Tone.error : Tone.of(score: report.score))
                            .frame(width: 92, height: 22)
                            .padding(.top, 3)
                    }
                }
                ScoreRing(score: report.score, blocked: blocked)
            }
        }
    }

    static func delta(_ comparison: Comparison) -> String {
        let change = comparison.scoreAfter - comparison.scoreBefore
        let when = comparison.since.ago
        if change == 0 { return "Same score as \(when)" }
        return "\(change > 0 ? "Up" : "Down") \(abs(change)) since \(when)"
    }

    // MARK: What to do next

    private var next: some View {
        let groups = report.groups
        let errors = groups.filter { $0.check.severity == .error }
        let rest = groups.filter { $0.check.severity == .warning }
        let shown = Array(rest.prefix(max(3, 7 - errors.count)))
        return VStack(alignment: .leading, spacing: 22) {
            if !errors.isEmpty { list("Fix before launch", errors) }
            if !shown.isEmpty { list(errors.isEmpty ? "Tidy up" : "Then tidy up", shown) }
            if errors.isEmpty, shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Nothing to fix")
                    Text(groups.isEmpty ? "Every check passed." : "Only small things are left. They are under Issues.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            if groups.count > errors.count + shown.count {
                Button { model.tab = .issues } label: {
                    Text("All \(groups.count) issues").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        + Text("  ›").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func list(_ title: String, _ groups: [Report.Group]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title, count: groups.count)
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    Button { model.reveal(group.check) } label: {
                        HStack(spacing: 10) {
                            Mark(group.check.severity)
                            Text(group.check.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 10)
                            Text(place(of: group))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(-1)
                        }
                        .frame(height: 36)
                    }
                    .buttonStyle(RowStyle(inset: 0))
                    .accessibilityLabel("\(group.check.title), \(group.findings.count) found")
                }
            }
        }
    }

    /// The first place a problem was found, and how many more.
    private func place(of group: Report.Group) -> String {
        let pages = group.findings.compactMap(\.url)
        guard let first = pages.first else { return "" }
        let more = Set(pages).count - 1
        return ReportFormat.short(first, site: report.site) + (more > 0 ? "  +\(more)" : "")
    }

    // MARK: Areas

    private var areas: some View {
        let scores = report.categoryScores.filter { $0.score != nil }
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "By area")
            VStack(spacing: 0) {
                ForEach(scores) { entry in
                    Button { model.filter(by: entry.category) } label: {
                        HStack(spacing: 10) {
                            Text(entry.category.title).font(.system(size: 12.5)).frame(width: 104, alignment: .leading)
                            ScoreBar(score: entry.score ?? 0)
                            Text("\(entry.score ?? 0)")
                                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                .frame(width: 28, alignment: .trailing)
                        }
                        .frame(height: 28)
                    }
                    .buttonStyle(RowStyle(inset: 0))
                    .disabled(entry.failed == 0)
                    .help(entry.failed == 0 ? "\(entry.category.blurb). Nothing to fix." : "\(entry.category.blurb). \(entry.failed) to fix.")
                    .accessibilityLabel("\(entry.category.title), \(entry.score ?? 0) of 100, \(entry.failed) to fix")
                }
            }
        }
    }
}

// MARK: Tally

/// Every check that ran, as one bar: how much failed at each level and how much passed.
struct Tally: View {
    let report: Report

    var body: some View {
        let parts: [(Mark.Kind, Int, String, AnyShapeStyle)] = [
            (.error, report.count(.error), "to fix before launch", AnyShapeStyle(Tone.error)),
            (.warning, report.count(.warning), "should fix", AnyShapeStyle(Tone.warning)),
            (.notice, report.count(.notice), "worth a look", AnyShapeStyle(Tone.notice)),
            (.passed, report.passed.count, "passed", AnyShapeStyle(Tone.passed.opacity(0.55))),
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let gap: CGFloat = 2
                let live = parts.filter { $0.1 > 0 }
                let usable = geometry.size.width - gap * CGFloat(max(0, live.count - 1))
                HStack(spacing: gap) {
                    ForEach(Array(live.enumerated()), id: \.offset) { _, part in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(part.3)
                            .frame(width: max(4, usable * CGFloat(part.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 20) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 6) {
                        Mark(part.0)
                        Text("\(part.1)").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        Text(part.2).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .opacity(part.1 == 0 ? 0.45 : 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.1) \($0.2)" }.joined(separator: ", "))
    }
}

// MARK: Page map

/// One square per page, colored by the worst thing found on it. The whole site at a glance.
struct PageMap: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        let worst = Self.worst(in: report)
        let pages = report.pages
        let troubled = pages.filter { worst[$0.url] != nil }.count
        if pages.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: "Pages", count: pages.count)
                    Text(troubled == 0 ? "all clear" : "\(troubled) with something to fix")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Tiles(spacing: 3, side: 14) {
                    // Past a few hundred pages the squares stop meaning anything; show the ones with problems first.
                    ForEach(Array(Self.ordered(pages, worst).prefix(390)), id: \.url) { page in
                        Tile(page: page, severity: worst[page.url], site: report.site) { model.showPage(page.url) }
                    }
                }
            }
        }
    }

    static func worst(in report: Report) -> [String: Severity] {
        var worst: [String: Severity] = [:]
        for finding in report.findings {
            guard let url = finding.url, let severity = Check.named(finding.check)?.severity else { continue }
            if let known = worst[url], rank(known) <= rank(severity) { continue }
            worst[url] = severity
        }
        return worst
    }

    static func rank(_ severity: Severity?) -> Int {
        switch severity {
        case .error: return 0
        case .warning: return 1
        case .notice: return 2
        case nil: return 3
        }
    }

    static func ordered(_ pages: [PageSummary], _ worst: [String: Severity]) -> [PageSummary] {
        pages.enumerated().sorted { a, b in
            let x = rank(worst[a.element.url]), y = rank(worst[b.element.url])
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    private struct Tile: View {
        let page: PageSummary
        let severity: Severity?
        let site: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            let path = ReportFormat.short(page.url, site: site)
            Button(action: action) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(severity.map { AnyShapeStyle(Tone.of($0)) } ?? AnyShapeStyle(Tone.empty))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.55 : 0), lineWidth: 1.5))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(severity.map { "\(path): \($0.label.lowercased())" } ?? "\(path): clear")
            .accessibilityLabel("\(path), \(severity?.label ?? "clear")")
        }
    }
}

/// Lays equal squares out in rows, wrapping at the edge.
struct Tiles: Layout {
    var spacing: CGFloat
    var side: CGFloat

    private func columns(in width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (side + spacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let rows = Int((Double(subviews.count) / Double(columns(in: width))).rounded(.up))
        return CGSize(width: width, height: CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let perRow = columns(in: bounds.width)
        for (index, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index % perRow) * (side + spacing)
            let y = bounds.minY + CGFloat(index / perRow) * (side + spacing)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: side, height: side))
        }
    }
}
