import LaunchcheckCore
import SwiftUI

struct ChangesTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 22) {
                if let comparison = model.comparison {
                    summary(comparison)
                    if comparison.isEmpty {
                        Text("Nothing has changed since then.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if !comparison.introduced.isEmpty { checks("New problems", comparison.introduced, fixed: false) }
                    if !comparison.fixed.isEmpty { checks("Fixed", comparison.fixed, fixed: true) }
                    if !comparison.changes.isEmpty { pages(comparison.changes) }
                    if !comparison.pagesAdded.isEmpty { addresses("Pages added", comparison.pagesAdded) }
                    if !comparison.pagesRemoved.isEmpty { addresses("Pages no longer found", comparison.pagesRemoved) }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This is the first check of \(report.host).")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Check it again after making changes and this tab will show what was fixed, what is new, and which pages changed their title, canonical, headings or structured data.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ comparison: Comparison) -> some View {
        let delta = comparison.scoreAfter - comparison.scoreBefore
        return HStack(alignment: .center, spacing: 18) {
            ScoreRing(score: comparison.scoreBefore, size: 54, line: 5).opacity(0.55)
            Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ScoreRing(score: comparison.scoreAfter, blocked: report.count(.error) > 0, size: 54, line: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(delta == 0 ? "Score unchanged" : "\(delta > 0 ? "Up" : "Down") \(abs(delta)) \(abs(delta) == 1 ? "point" : "points")")
                    .font(.system(size: 20, weight: .semibold))
                Text("Compared with the check \(comparison.since.ago)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
        }
    }

    private func checks(_ title: String, _ checks: [Check], fixed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "\(title) \(checks.count)")
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Tone.hairline.frame(height: 1) }
                        Button {
                            if !fixed { model.reveal(check) }
                        } label: {
                            HStack(spacing: 10) {
                                if fixed {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tone.passed).frame(width: 10)
                                } else {
                                    Circle().fill(Tone.of(check.severity)).frame(width: 7, height: 7).frame(width: 10)
                                }
                                Text(fixed ? check.passed : check.title).font(.system(size: 12.5, weight: .medium))
                                Spacer()
                                Text(check.category.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func pages(_ changes: [Change]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Page changes \(changes.count)")
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(changes.prefix(60).enumerated()), id: \.element.id) { index, change in
                        if index > 0 { Tone.hairline.frame(height: 1) }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(color(change.level)).frame(width: 7, height: 7).frame(width: 10).offset(y: -1)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 8) {
                                    Text(change.summary).font(.system(size: 12.5, weight: .medium))
                                    Text(ReportFormat.short(change.url, site: report.site))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if let detail = change.detail {
                                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func color(_ level: Change.Level) -> Color {
        switch level {
        case .critical: return Tone.error
        case .warning: return Tone.warning
        case .info: return Tone.notice
        }
    }

    private func addresses(_ title: String, _ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "\(title) \(list.count)")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(list.prefix(40), id: \.self) { address in
                    Text(ReportFormat.short(address, site: report.site)).font(.system(size: 12, design: .monospaced))
                }
                if list.count > 40 { Text("and \(list.count - 40) more").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
        }
    }
}
