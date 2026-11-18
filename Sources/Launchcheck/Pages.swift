import LaunchcheckCore
import SwiftUI

struct PagesTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(prompt: "Filter \(report.pages.count) pages", text: $model.pageSearch)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Tone.hairline.frame(height: 1)
                Scroller {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visiblePages) { page in
                            PageRow(page: page, findings: report.findings(on: page.url), site: report.site, selected: model.selectedPage == page.url) {
                                model.selectedPage = page.url
                            }
                            Tone.hairline.frame(height: 1).padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Tone.hairline.frame(width: 1)
            Group {
                if let page = report.pages.first(where: { $0.url == model.selectedPage }) {
                    PageInspector(page: page, findings: report.findings(on: page.url), report: report, onOpen: model.open)
                } else {
                    Text("Choose a page to see how it looks in search and when shared.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 372)
        }
    }
}

struct PageRow: View {
    let page: PageSummary
    let findings: [Finding]
    let site: String
    let selected: Bool
    let action: () -> Void

    private var worst: Severity? {
        findings.compactMap { Check.named($0.check)?.severity }.min()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(worst.map(Tone.of) ?? Tone.passed).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ReportFormat.short(page.url, site: site))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(page.title ?? "No title")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(findings.isEmpty ? "clear" : "\(findings.count)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(selected ? Tone.lift : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ReportFormat.short(page.url, site: site)), \(findings.count) issues")
    }
}

struct PageInspector: View {
    let page: PageSummary
    let findings: [Finding]
    let report: Report
    let onOpen: (String?) -> Void

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ReportFormat.short(page.url, site: report.site))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Open") { onOpen(page.url) }.buttonStyle(QuietButton(compact: true))
                }
                block("In search") { SearchPreview(page: page, host: report.host) }
                block("When shared") { SharePreview(page: page, host: report.host) }
                block("Details") { details }
                block(findings.isEmpty ? "Nothing to fix on this page" : "On this page") {
                    if !findings.isEmpty { issues }
                }
            }
            .padding(18)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: title)
            content()
        }
    }

    private var details: some View {
        let rows: [(String, String)] = [
            ("Status", "\(page.status)\(page.indexable ? "" : " · noindex")"),
            ("Words", page.words.formatted()),
            ("Images", "\(page.images)"),
            ("Answered in", page.milliseconds > 0 ? "\(page.milliseconds) ms" : "–"),
            ("HTML size", page.bytes > 0 ? "\(Int((Double(page.bytes) / 1000).rounded())) KB" : "–"),
            ("Clicks from home", page.depth.map(String.init) ?? "–"),
            ("Linked from", page.inboundLinks == 1 ? "1 page" : "\(page.inboundLinks) pages"),
            ("H1", page.h1.first ?? "None"),
            ("Structured data", page.schemaTypes.isEmpty ? "None" : page.schemaTypes.joined(separator: ", ")),
        ]
        return Card {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.0).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var issues: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    let check = Check.named(finding.check)
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(check.map { Tone.of($0.severity) } ?? Tone.notice).frame(width: 6, height: 6).offset(y: -1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check?.title ?? finding.check).font(.system(size: 12, weight: .medium))
                            if let detail = finding.detail {
                                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
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

// MARK: Previews

/// The page as a search result: what fits, and what gets cut.
struct SearchPreview: View {
    let page: PageSummary
    let host: String
    @Environment(\.colorScheme) private var scheme

    private func cut(_ text: String, to limit: Int) -> String {
        text.count > limit ? text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    var body: some View {
        let title = page.title ?? ""
        let description = page.description ?? ""
        let path = (URL(string: page.url)?.path ?? "").split(separator: "/").map(String.init)
        Card(padding: 14) {
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
                    .font(.system(size: 15.5))
                    .foregroundStyle(title.isEmpty ? Tone.error : (scheme == .dark ? Color(red: 0.54, green: 0.71, blue: 0.97) : Color(red: 0.10, green: 0.05, blue: 0.67)))
                    .fixedSize(horizontal: false, vertical: true)
                Text(description.isEmpty ? "No description: a snippet from the page will be used instead." : cut(description, to: 160))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    measure("Title", title.count, limit: 60)
                    measure("Description", description.count, limit: 160)
                }
                .padding(.top, 4)
            }
        }
    }

    private func measure(_ label: String, _ count: Int, limit: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(count == 0 ? Tone.error : (count > limit ? Tone.warning : Tone.passed)).frame(width: 5, height: 5)
            Text(count > limit ? "\(label) \(count), cut at \(limit)" : "\(label) \(count)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// The page as a link card in a chat or a social feed.
struct SharePreview: View {
    let page: PageSummary
    let host: String
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 176)
                    .overlay { image }
                    .clipped()
                Tone.hairline.frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.uppercased()).font(.system(size: 9.5, weight: .medium)).tracking(0.4).foregroundStyle(.secondary)
                    Text(page.shareTitle ?? page.title ?? "No title")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(page.shareDescription ?? page.description ?? "No description")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
    }

    @ViewBuilder private var image: some View {
        if isSnapshot, page.shareImage != nil {
            // README images cannot load from the network; stand in with something that reads as a picture.
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.32), Color(red: 0.86, green: 0.22, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.22)).frame(width: 180).offset(x: 110, y: -50)
                Circle().fill(.black.opacity(0.14)).frame(width: 220).offset(x: -130, y: 80)
            }
        } else if let address = page.shareImage, let url = URL(string: address) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let picture): picture.resizable().aspectRatio(contentMode: .fill)
                case .failure: missing("The share image did not load")
                default: Tone.wash
                }
            }
        } else {
            missing("No share image")
        }
    }

    private func missing(_ text: String) -> some View {
        ZStack {
            Tone.wash
            VStack(spacing: 5) {
                Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(.secondary)
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
