import LaunchcheckCore
import SwiftUI

/// What is different since the last check of this site.
struct ChangesTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        if let comparison = model.comparison {
            Scroller {
                VStack(alignment: .leading, spacing: 28) {
                    headline(comparison)
                    if comparison.isEmpty {
                        Text("Nothing changed between the two checks.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if !comparison.introduced.isEmpty { checks("New problems", comparison.introduced, fixed: false) }
                    if !comparison.fixed.isEmpty { checks("Fixed", comparison.fixed, fixed: true) }
                    if !comparison.changes.isEmpty { pages(comparison.changes) }
                    if !comparison.pagesAdded.isEmpty { addresses("Pages added", comparison.pagesAdded, linked: true) }
                    if !comparison.pagesRemoved.isEmpty { addresses("Pages no longer found", comparison.pagesRemoved, linked: false) }
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing to compare yet")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.3)
                Text("This is the first check of \(report.host). Check it again after the next deploy and this tab lists what was fixed, what is new, and which pages changed.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 480, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Score, then and now

    private func headline(_ comparison: Comparison) -> some View {
        let change = comparison.scoreAfter - comparison.scoreBefore
        let title = change == 0 ? "Same score" : "\(change > 0 ? "Up" : "Down") \(abs(change)) \(abs(change) == 1 ? "point" : "points")"
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.4)
                HStack(spacing: 6) {
                    Text("\(comparison.scoreBefore)").foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("\(comparison.scoreAfter)").fontWeight(.semibold)
                    Text("· compared with the check \(comparison.since.ago)").foregroundStyle(.secondary)
                }
                .font(.system(size: 12).monospacedDigit())
            }
            Spacer(minLength: 12)
            if model.trail.count > 1 {
                VStack(alignment: .trailing, spacing: 4) {
                    Trend(scores: model.trail, color: report.count(.error) > 0 ? Tone.error : Tone.of(score: report.score))
                        .frame(width: 180, height: 40)
                    Text("Last \(model.trail.count) checks")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Lists

    private func checks(_ title: String, _ checks: [Check], fixed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title, count: checks.count)
            VStack(spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    let row = HStack(spacing: 10) {
                        Mark(fixed ? .passed : Mark.Kind(check.severity))
                        Text(fixed ? check.passed : check.title)
                            .font(.system(size: 13, weight: fixed ? .regular : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 10)
                        Text(check.category.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .frame(height: 34)
                    if fixed {
                        row
                    } else {
                        Button { model.reveal(check) } label: { row }.buttonStyle(RowStyle(inset: 0))
                    }
                }
            }
        }
    }

    private func pages(_ changes: [Change]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Page changes", count: changes.count)
            VStack(spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    Button { model.showPage(change.url) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Mark(change.level).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(change.summary).font(.system(size: 13, weight: .medium))
                                    Text(ReportFormat.short(change.url, site: report.site))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if let detail = change.detail {
                                    Text(detail)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(RowStyle(inset: 0))
                }
            }
        }
    }

    private func addresses(_ title: String, _ list: [String], linked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title, count: list.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.prefix(40).enumerated()), id: \.offset) { index, address in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    Text(ReportFormat.short(address, site: report.site))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 30)
                        .textSelection(.enabled)
                }
            }
            if list.count > 40 {
                Text("And \(list.count - 40) more.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
