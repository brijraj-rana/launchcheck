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
                            PageRow(page: page, site: report.site, severity: worst[page.url], issues: counts[page.url] ?? 0,
                                    selected: model.selectedPage == page.url) {
                                model.selectedPage = page.url
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
    let selected: Bool
    let action: () -> Void

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
                if issues > 0 {
                    Text("\(issues)")
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
                    Button("Open") { model.open(page.url) }.buttonStyle(QuietButton(compact: true)).help("Open this page in the browser")
                }
                block("In search") { SearchPreview(page: page, host: report.host) }
                block("When shared") { SharePreview(page: page, host: report.host) }
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

/// A sheet lifted off the page: the one place a box is the right shape, because it stands for a real object.
private struct Sheet<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.raised))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.hairline))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// The page as a search result: what fits, and what gets cut.
struct SearchPreview: View {
    let page: PageSummary
    let host: String

    private static let link = Paint(light: Color(red: 0.10, green: 0.05, blue: 0.67), dark: Color(red: 0.56, green: 0.72, blue: 0.98))

    private func cut(_ text: String, to limit: Int) -> String {
        text.count > limit ? text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    var body: some View {
        let title = page.title ?? ""
        let description = page.description ?? ""
        let path = (URL(string: page.url)?.path ?? "").split(separator: "/").map(String.init)
        VStack(alignment: .leading, spacing: 8) {
            Sheet {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Circle().fill(Tone.lift).frame(width: 22, height: 22)
                            .overlay(Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(host).font(.system(size: 11.5))
                            Text((["https://\(host)"] + path).joined(separator: " › "))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(title.isEmpty ? "No title: the search engine will invent one" : cut(title, to: 60))
                        .font(.system(size: 16))
                        .foregroundStyle(title.isEmpty ? Tone.error : Self.link)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(description.isEmpty ? "No description: a snippet from the page will be used instead." : cut(description, to: 160))
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            HStack(spacing: 14) {
                Meter(label: "Title", count: title.count, limit: 60)
                Meter(label: "Description", count: description.count, limit: 160)
            }
        }
    }
}

/// How much of a length limit a text uses, and by how much it runs over.
struct Meter: View {
    let label: String
    let count: Int
    let limit: Int

    var body: some View {
        let over = count > limit
        let tone: Paint = count == 0 ? Tone.error : (over ? Tone.warning : Tone.passed)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(count == 0 ? "missing" : (over ? "\(count), cut at \(limit)" : "\(count) of \(limit)"))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(count == 0 || over ? AnyShapeStyle(tone) : AnyShapeStyle(.secondary))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tone.empty)
                    Capsule().fill(tone).frame(width: max(count == 0 ? 0 : 3, geometry.size.width * min(1, CGFloat(count) / CGFloat(limit))))
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(count == 0 ? "missing" : "\(count) characters, limit \(limit)")")
    }
}

/// The page as a link card in a chat or a social feed.
struct SharePreview: View {
    let page: PageSummary
    let host: String
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 168)
                    .overlay { image }
                    .clipped()
                Tone.hairline.frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text(page.shareTitle ?? page.title ?? "No title")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(page.shareDescription ?? page.description ?? "No description")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder private var image: some View {
        if isSnapshot, page.shareImage != nil {
            // README images cannot load from the network; stand in with something that reads as a product photograph.
            ZStack {
                Color(red: 0.93, green: 0.90, blue: 0.84)
                Circle().fill(Color(red: 0.87, green: 0.36, blue: 0.22)).frame(width: 150).offset(x: 96, y: 22)
                Rectangle().fill(Color(red: 0.16, green: 0.15, blue: 0.14)).frame(width: 190, height: 46).offset(x: -70, y: 56)
                Text("ACME").font(.system(size: 38, weight: .black)).tracking(-1).foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.14)).offset(x: -96, y: -22)
            }
        } else if let address = page.shareImage, let url = URL(string: address) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let picture): picture.resizable().aspectRatio(contentMode: .fill)
                case .failure: missing("The share image did not load", tone: Tone.error)
                default: Tone.wash
                }
            }
        } else {
            missing("No share image", tone: Tone.warning)
        }
    }

    private func missing(_ text: String, tone: Paint) -> some View {
        ZStack {
            Tone.wash
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(tone)
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}
