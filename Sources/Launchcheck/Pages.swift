import LaunchcheckCore
import SwiftUI

/// Every page on the left; the picked one on the right, shown the way a search engine and a chat app will show it.
struct PagesTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        let worst = PageMap.worst(in: report)
        let counts = Dictionary(report.findings.compactMap(\.url).map { ($0, 1) }, uniquingKeysWith: +)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchField(prompt: "Filter \(report.pages.count) pages", text: $model.pageSearch)
                    SortMenu(sort: $model.pageSort)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                Tone.hairline.frame(height: 1)
                Scroller(target: model.selectedPage) {
                    VStack(spacing: 1) {
                        let pages = model.visiblePages
                        if pages.isEmpty {
                            Text(report.pages.isEmpty ? "This report has no page details. Check the site again to collect them." : "No page matches “\(model.pageSearch)”.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                        }
                        ForEach(pages) { page in
                            PageRow(page: page, site: report.site, severity: worst[page.url], issues: counts[page.url] ?? 0, sort: model.pageSort,
                                    selected: model.selectedPage == page.url) {
                                Motion.run(Motion.swap) { model.selectedPage = page.url }
                            }
                            .id(page.url)
                            .contextMenu {
                                Button("Open in Browser") { model.open(page.url) }
                                Button("Copy Address") { model.copy(page.url) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
            Tone.hairline.frame(width: 1)
            Group {
                if let page = report.pages.first(where: { $0.url == model.selectedPage }) {
                    PageInspector(model: model, report: report, page: page)
                        .id(page.url)
                        .transition(.soft)
                } else {
                    Text("Pick a page").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 420)
        }
    }
}

struct PageRow: View {
    let page: PageSummary
    let site: String
    let severity: Severity?
    let issues: Int
    let sort: AuditModel.PageSort
    let selected: Bool
    let action: () -> Void

    /// The figure the list is sorted by, so the order explains itself.
    private var figure: String? {
        switch sort {
        case .issues, .path: return issues > 0 ? "\(issues)" : nil
        case .slowest: return page.milliseconds > 0 ? "\(page.milliseconds) ms" : nil
        case .thinnest: return "\(page.words.formatted()) words"
        case .deepest: return page.depth.map { $0 == 1 ? "1 click" : "\($0) clicks" }
        }
    }

    var body: some View {
        let path = ReportFormat.short(page.url, site: site)
        Button(action: action) {
            HStack(spacing: 10) {
                Mark(severity.map(Mark.Kind.init) ?? .passed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(page.title ?? "No title")
                        .font(.system(size: 11.5))
                        .foregroundStyle((page.title ?? "").isEmpty ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if !page.indexable {
                    Text("noindex")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Tone.error)
                }
                if let figure {
                    Text(figure)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                }
            }
            .frame(height: 44)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel("\(path), \(page.title ?? "no title"), \(issues == 0 ? "clear" : "\(issues) issues")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Inspector

struct PageInspector: View {
    @ObservedObject var model: AuditModel
    let report: Report
    let page: PageSummary

    var body: some View {
        let findings = report.findings(on: page.url)
        Scroller {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ReportFormat.short(page.url, site: report.site))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Stepper(model: model)
                    Button("Open") { model.open(page.url) }.buttonStyle(QuietButton(compact: true)).help("Open this page in the browser")
                }
                let snippet = PagePreview.search(for: page, host: report.host)
                block("In search") {
                    VStack(alignment: .leading, spacing: 8) {
                        SearchResult(snippet: snippet, compact: true)
                        HStack(spacing: 14) {
                            Meter(label: "Title", text: snippet.title, limit: 60)
                            Meter(label: "Description", text: snippet.description, limit: 158)
                        }
                    }
                }
                block("When shared") { CardView(card: PagePreview.card(for: page, host: report.host, on: .chat), compact: true) }
                Button { model.showPreview(page.url) } label: {
                    Text("Larger, with X and what to add").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        + Text("  ›").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, -12)
                if !findings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "To fix on this page", count: findings.count)
                        VStack(spacing: 0) {
                            ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                                if index > 0 { Tone.hairline.frame(height: 1) }
                                issue(finding)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Details")
                    details
                }
            }
            .padding(22)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            content()
        }
    }

    private func issue(_ finding: Finding) -> some View {
        let check = Check.named(finding.check)
        return Button { if let check { model.reveal(check) } } label: {
            HStack(alignment: .center, spacing: 10) {
                Mark(check.map { Mark.Kind($0.severity) } ?? .notice)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check?.title ?? finding.check).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if let detail = finding.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(RowStyle(inset: 0))
        .help("See this issue")
    }

    private var details: some View {
        let slow = page.milliseconds > 800
        let rows: [(String, String, Paint?)] = [
            ("Status", "\(page.status)\(page.indexable ? "" : ", noindex")", page.indexable && (200..<300).contains(page.status) ? nil : Tone.error),
            ("Canonical", page.canonical.map { ReportFormat.short($0, site: report.site) } ?? "None", nil),
            ("H1", page.h1.first ?? "None", page.h1.isEmpty ? Tone.warning : nil),
            ("Words", page.words.formatted(), nil),
            ("Images", "\(page.images)", nil),
            ("Answered in", page.milliseconds > 0 ? "\(page.milliseconds) ms" : "Not measured", slow ? Tone.warning : nil),
            ("HTML size", page.bytes > 0 ? "\(Int((Double(page.bytes) / 1000).rounded())) KB" : "Not measured", nil),
            ("Clicks from home", page.depth.map(String.init) ?? "Not reached by links", nil),
            ("Linked from", page.inboundLinks == 1 ? "1 page" : "\(page.inboundLinks) pages", page.inboundLinks == 0 ? Tone.warning : nil),
            ("Structured data", page.schemaTypes.isEmpty ? "None" : page.schemaTypes.joined(separator: ", "), nil),
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Tone.hairline.frame(height: 1) }
                Fact(label: row.0, value: row.1, tone: row.2)
            }
        }
    }
}

// MARK: Previews

/// How much of a text a search result shows, and whether it runs over.
struct Meter: View {
    let label: String
    /// nil when the page has no such text.
    let text: ClippedText?
    /// About how many characters fit, for the length of the bar.
    let limit: Int

    var body: some View {
        let count = text?.full.count ?? 0
        let over = text?.isCut ?? false
        let tone: Paint = count == 0 ? Tone.error : (over ? Tone.warning : Tone.passed)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(count == 0 ? "missing" : (over ? "\(count), cut at \(max(0, (text?.shown.count ?? 0) - 4))" : "\(count), fits"))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(count == 0 || over ? AnyShapeStyle(tone) : AnyShapeStyle(.secondary))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tone.empty)
                    Capsule().fill(tone).frame(width: max(count == 0 ? 0 : 3, geometry.size.width * (over ? 1 : min(1, CGFloat(count) / CGFloat(limit)))))
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(count == 0 ? "missing" : "\(count) characters, \(over ? "cut" : "fits")")")
    }
}

/// How the page list is ordered.
struct SortMenu: View {
    @Binding var sort: AuditModel.PageSort
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(AuditModel.PageSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort the pages")
            .accessibilityLabel("Sort by \(sort.rawValue)")
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .medium))
            Text(sort.rawValue).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tone.wash))
    }
}

/// "3 of 20" with a step either way: where you are in the list, and the way to the next one.
struct Stepper: View {
    @ObservedObject var model: AuditModel

    var body: some View {
        StepControl(position: model.position) { model.move(by: $0) }
    }
}

struct StepControl: View {
    let position: (index: Int, count: Int)?
    let move: (Int) -> Void

    var body: some View {
        if let position {
            HStack(spacing: 2) {
                Text("\(position.index) of \(position.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                step("chevron.up", "Previous", by: -1, enabled: position.index > 1)
                step("chevron.down", "Next", by: 1, enabled: position.index < position.count)
            }
            .fixedSize()
        }
    }

    private func step(_ symbol: String, _ label: String, by amount: Int, enabled: Bool) -> some View {
        Button { move(amount) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Tone.wash))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help("\(label) (\(amount < 0 ? "↑" : "↓"))")
        .accessibilityLabel(label)
    }
}
