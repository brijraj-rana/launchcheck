import LaunchcheckCore
import SwiftUI

struct OverviewTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 26) {
                headline
                if let comparison = model.comparison, !comparison.isEmpty { sinceLast(comparison) }
                HStack(alignment: .top, spacing: 24) {
                    areas
                    startHere
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    // MARK: Score and verdict

    private var headline: some View {
        HStack(alignment: .center, spacing: 26) {
            ScoreRing(score: report.score, blocked: report.count(.error) > 0)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.verdict)
                        .font(.system(size: 24, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(report.host) · \(ReportFormat.summary(report)) · \(report.date.ago)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    tally(report.count(.error), "Fix first", Tone.error)
                    tally(report.count(.warning), "Should fix", Tone.warning)
                    tally(report.count(.notice), "Worth a look", Tone.notice)
                    tally(report.passed.count, "Passed", Tone.passed)
                }
            }
        }
    }

    private func tally(_ count: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(count == 0 ? Color.secondary.opacity(0.6) : Color.primary)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, alignment: .leading)
    }

    // MARK: Since last check

    private func sinceLast(_ comparison: Comparison) -> some View {
        let delta = comparison.scoreAfter - comparison.scoreBefore
        return Button {
            model.tab = .changes
        } label: {
            Card(padding: 14) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow(text: "Since the last check, \(comparison.since.ago)")
                        HStack(spacing: 14) {
                            if delta != 0 {
                                Text("\(delta > 0 ? "+" : "−")\(abs(delta)) \(abs(delta) == 1 ? "point" : "points")")
                                    .foregroundStyle(delta > 0 ? Tone.passed : Tone.error)
                            }
                            if !comparison.fixed.isEmpty { Text("\(comparison.fixed.count) fixed") }
                            if !comparison.introduced.isEmpty { Text("\(comparison.introduced.count) new").foregroundStyle(Tone.error) }
                            if !comparison.changes.isEmpty { Text("\(comparison.changes.count) page \(comparison.changes.count == 1 ? "change" : "changes")") }
                        }
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Areas

    private var areas: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "By area")
            Card {
                VStack(spacing: 0) {
                    let scores = report.categoryScores.filter { $0.score != nil }
                    ForEach(Array(scores.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Tone.hairline.frame(height: 1) }
                        Button {
                            model.filter(by: entry.category)
                        } label: {
                            HStack(spacing: 12) {
                                Text(entry.category.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .frame(width: 108, alignment: .leading)
                                ScoreBar(score: entry.score ?? 0)
                                Text("\(entry.score ?? 0)")
                                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                    .frame(width: 28, alignment: .trailing)
                                Text(entry.failed == 0 ? "clear" : "\(entry.failed) to fix")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(entry.category.blurb)
                        .accessibilityLabel("\(entry.category.title), \(entry.score ?? 0) of 100")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Where to begin

    private var startHere: some View {
        let top = Array(report.groups.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: top.isEmpty ? "Nothing to fix" : "Start here")
            if top.isEmpty {
                Card(padding: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tone.passed)
                        Text("Every check that applies to this site passed.").font(.system(size: 12.5))
                    }
                }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { Tone.hairline.frame(height: 1) }
                            Button {
                                model.reveal(group.check)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(Tone.of(group.check.severity)).frame(width: 7, height: 7)
                                    Text(group.check.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("\(group.findings.count)")
                                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if report.groups.count > top.count {
                    Button("See all \(report.groups.count) issues") { model.tab = .issues }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
