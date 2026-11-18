import LaunchcheckCore
import SwiftUI

struct IssuesTab: View {
    @ObservedObject var model: AuditModel
    let report: Report
    @State private var showPassed = false

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 20) {
                filters
                let groups = model.visibleGroups
                if groups.isEmpty {
                    Text(report.groups.isEmpty ? "Nothing to fix. Every check that applies passed." : "Nothing here matches.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                ForEach(Severity.allCases, id: \.self) { severity in
                    let matching = groups.filter { $0.check.severity == severity }
                    if !matching.isEmpty { section(severity, matching) }
                }
                passed
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchField(prompt: "Search issues and pages", text: $model.search)
                .frame(maxWidth: 320)
            Flow(spacing: 6) {
                chip("All", count: report.groups.count, selected: model.category == nil) { model.category = nil }
                ForEach(Category.allCases, id: \.self) { category in
                    let count = report.groups.filter { $0.check.category == category }.count
                    if count > 0 {
                        chip(category.title, count: count, selected: model.category == category) {
                            model.category = model.category == category ? nil : category
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor).opacity(0.7) : .secondary)
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(selected ? Color.primary : Tone.wash))
            .overlay(Capsule().strokeBorder(selected ? .clear : Tone.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func section(_ severity: Severity, _ groups: [Report.Group]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: severity.label)
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Tone.hairline.frame(height: 1) }
                        GroupRow(group: group, site: report.site, open: model.expanded.contains(group.id), onOpen: model.open) {
                            if model.expanded.contains(group.id) { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
                        }
                    }
                }
            }
        }
    }

    private var passed: some View {
        let checks = report.passedChecks.filter { model.category == nil || $0.category == model.category }
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                showPassed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Eyebrow(text: "Passed \(checks.count)")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showPassed ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showPassed {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(checks, id: \.id) { check in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Tone.passed)
                                .frame(width: 12)
                            Text(check.passed).font(.system(size: 12.5))
                        }
                    }
                }
            }
        }
    }
}

struct GroupRow: View {
    let group: Report.Group
    let site: String
    let open: Bool
    let onOpen: (String?) -> Void
    let toggle: () -> Void

    private let shown = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Circle().fill(Tone.of(group.check.severity)).frame(width: 7, height: 7)
                    Text(group.check.title)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text(group.check.category.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(group.findings.count)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.check.title), \(group.findings.count)")

            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.check.why)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.findings.prefix(shown)) { finding in
                            FindingRow(finding: finding, site: site, onOpen: onOpen)
                        }
                        if group.findings.count > shown {
                            Text("and \(group.findings.count - shown) more, in the exported report")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 29)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    let site: String
    let onOpen: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let url = finding.url {
                Button {
                    onOpen(url)
                } label: {
                    Text(ReportFormat.short(url, site: site))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(url)")
            }
            if let detail = finding.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}
