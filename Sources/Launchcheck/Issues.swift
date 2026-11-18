import LaunchcheckCore
import SwiftUI

/// Every failed check on the left, the one that is picked explained on the right.
struct IssuesTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        HStack(spacing: 0) {
            list.frame(minWidth: 340, maxWidth: .infinity)
            Tone.hairline.frame(width: 1)
            Group {
                if let group = report.groups.first(where: { $0.id == model.selectedIssue }) {
                    IssueInspector(model: model, report: report, group: group)
                } else {
                    VStack(spacing: 6) {
                        Text(report.groups.isEmpty ? "Nothing to fix" : "Pick an issue")
                            .font(.system(size: 13, weight: .medium))
                        Text(report.groups.isEmpty ? "Every check passed." : "Use the arrow keys to move through the list.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 400)
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(prompt: "Filter issues", text: $model.search)
                Segments(options: [(AuditModel.Grouping.severity, "Severity"), (.area, "Area")], selection: $model.grouping)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Tone.hairline.frame(height: 1)
            Scroller(target: model.selectedIssue) {
                VStack(alignment: .leading, spacing: 18) {
                    let groups = model.visibleGroups
                    if groups.isEmpty {
                        Text(model.search.isEmpty ? "Every check passed." : "No issue matches “\(model.search)”.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                    }
                    ForEach(sections(of: groups), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(text: section.title, count: section.groups.count).padding(.horizontal, 8)
                            VStack(spacing: 1) {
                                ForEach(section.groups) { group in
                                    IssueRow(group: group, showsArea: model.grouping == .severity, selected: model.selectedIssue == group.id) {
                                        model.selectedIssue = group.id
                                    }
                                    .id(group.id)
                                    .contextMenu {
                                        Button("Copy as Task") { model.copyTask(group) }
                                        if let first = group.findings.compactMap(\.url).first {
                                            Button("Open First Page in Browser") { model.open(first) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if model.search.isEmpty, !report.passedChecks.isEmpty { passed }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 14)
            }
        }
    }

    private func sections(of groups: [Report.Group]) -> [(title: String, groups: [Report.Group])] {
        switch model.grouping {
        case .severity:
            return [Severity.error, .warning, .notice].compactMap { severity in
                let matching = groups.filter { $0.check.severity == severity }
                return matching.isEmpty ? nil : (severity.label, matching)
            }
        case .area:
            return LaunchcheckCore.Category.allCases.compactMap { category in
                let matching = groups.filter { $0.check.category == category }
                return matching.isEmpty ? nil : (category.title, matching)
            }
        }
    }

    private var passed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.showsPassed.toggle() } label: {
                HStack(spacing: 6) {
                    SectionLabel(text: "Passed", count: report.passedChecks.count)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(model.showsPassed ? 90 : 0))
                    Spacer()
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            if model.showsPassed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.passedChecks, id: \.id) { check in
                        HStack(spacing: 10) {
                            Mark(.passed)
                            Text(check.passed).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(height: 26)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

struct IssueRow: View {
    let group: Report.Group
    let showsArea: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let pages = Set(group.findings.compactMap(\.url)).count
        Button(action: action) {
            HStack(spacing: 10) {
                Mark(group.check.severity)
                Text(group.check.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 10)
                if showsArea {
                    Text(group.check.category.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(max(pages, group.findings.count))")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
            }
            .frame(height: 34)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel("\(group.check.title), \(group.check.severity.label), \(group.check.category.title), \(group.findings.count) found")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Inspector

struct IssueInspector: View {
    @ObservedObject var model: AuditModel
    let report: Report
    let group: Report.Group

    var body: some View {
        let check = group.check
        Scroller {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Mark(check.severity)
                        Text(check.severity.label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(check.severity == .notice ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.of(check.severity)))
                        Text("·").foregroundStyle(.tertiary)
                        Text(check.category.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Text(check.title)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(check.why)
                        .font(.system(size: 13))
                        .lineSpacing(3.5)
                        .foregroundStyle(.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Done when")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Mark(.passed)
                        Text(check.passed).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Found", count: group.findings.count)
                    VStack(spacing: 0) {
                        ForEach(Array(group.findings.prefix(60).enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Tone.hairline.frame(height: 1) }
                            FindingRow(finding: finding, site: report.site, linked: report.pages.contains { $0.url == finding.url }) {
                                model.showPage(finding.url)
                            }
                            .contextMenu {
                                if let url = finding.url {
                                    Button("Open in Browser") { model.open(url) }
                                    Button("Copy Address") { model.copy(url) }
                                }
                            }
                        }
                    }
                    if group.findings.count > 60 {
                        Text("And \(group.findings.count - 60) more. Export the report for the full list.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }

                HStack(spacing: 8) {
                    Button(model.copied ? "Copied" : "Copy as task") { model.copyTask(group) }
                        .buttonStyle(QuietButton(compact: true))
                        .help("Copy this issue as a checklist for a ticket or a message")
                    if let first = group.findings.compactMap(\.url).first {
                        Button("Open page") { model.open(first) }.buttonStyle(QuietButton(compact: true))
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    let site: String
    let linked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.url.map { ReportFormat.short($0, site: site) } ?? "Whole site")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = finding.detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if linked {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(RowStyle(inset: 0))
        .disabled(!linked)
        .help(linked ? "See this page" : "")
    }
}
