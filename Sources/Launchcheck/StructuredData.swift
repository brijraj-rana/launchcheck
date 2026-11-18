import LaunchcheckCore
import SwiftUI

/// The structured data inspector: every JSON-LD block of a page taken apart. What each item is, what it carries,
/// what its type asks for and it lacks, and the result it can earn. Core does the taking apart; this only draws it.
struct SchemaTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        HStack(spacing: 0) {
            // One page needs no list to pick from.
            if report.page == nil {
                list.frame(width: 264)
                Tone.hairline.frame(width: 1)
            }
            Group {
                if let page = report.pages.first(where: { $0.url == model.schemaPage }) {
                    SchemaPane(model: model, report: report, page: page)
                        .id(page.url)
                        .transition(.soft)
                } else {
                    Text(report.pages.isEmpty ? "No pages to inspect" : "Pick a page").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Filter by page or type", text: $model.schemaSearch)
                .padding(.horizontal, 16)
                .frame(height: 48)
            Tone.hairline.frame(height: 1)
            Scroller(target: model.schemaPage) {
                VStack(alignment: .leading, spacing: 16) {
                    let types = report.schemaTypesInUse
                    if !types.isEmpty, model.schemaSearch.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel(text: "Types in use", count: types.count).padding(.horizontal, 8).padding(.bottom, 2)
                            ForEach(types.prefix(7), id: \.type) { entry in
                                Button { model.schemaSearch = entry.type } label: {
                                    HStack(spacing: 8) {
                                        Text(entry.type).font(.system(size: 12.5)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(entry.pages == 1 ? "1 page" : "\(entry.pages) pages")
                                            .font(.system(size: 11.5).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(height: 26)
                                }
                                .buttonStyle(RowStyle())
                                .help("Show the pages that use \(entry.type)")
                            }
                            if types.count > 7 {
                                Text("And \(types.count - 7) more: \(types.dropFirst(7).map(\.type).joined(separator: ", "))")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        let pages = model.schemaPages
                        SectionLabel(text: "Pages", count: pages.count).padding(.horizontal, 8).padding(.bottom, 3)
                        if pages.isEmpty {
                            Text(report.pages.isEmpty ? "This report has no page details. Check the site again to collect them." : "No page matches “\(model.schemaSearch)”.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                        }
                        ForEach(pages) { page in
                            SchemaRow(page: page, site: report.site, selected: model.schemaPage == page.url) {
                                Motion.run(Motion.swap) { model.schemaPage = page.url }
                            }
                            .id(page.url)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
    }
}

/// How a page's structured data stands, as a mark: something required is missing, something is worth a look, or all is well.
private func standing(of page: PageSummary) -> Mark.Kind {
    let items = (page.schema ?? []).flatMap(\.items).flatMap(flattened)
    if (page.schema ?? []).contains(where: { !$0.parses }) || items.contains(where: { !$0.required.isEmpty }) { return .warning }
    if items.contains(where: { !$0.recommended.isEmpty || !$0.notes.isEmpty }) { return .notice }
    return page.schemaTypes.isEmpty ? .none : .passed
}

private func flattened(_ item: SchemaItem) -> [SchemaItem] {
    [item] + item.children.flatMap(flattened)
}

private struct SchemaRow: View {
    let page: PageSummary
    let site: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let path = ReportFormat.short(page.url, site: site)
        // The items that stand on their own say what the page is; what is nested inside them is detail.
        let own = (page.schema ?? []).flatMap(\.items).map(\.name)
        let types = own.isEmpty ? page.schemaTypes : own
        Button(action: action) {
            HStack(spacing: 10) {
                Mark(standing(of: page))
                VStack(alignment: .leading, spacing: 2) {
                    Text(path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(types.isEmpty ? "No structured data" : types.joined(separator: ", "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .opacity(types.isEmpty ? 0.6 : 1)
            .frame(height: 44)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel("\(path), \(types.isEmpty ? "no structured data" : types.joined(separator: ", "))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: The picked page

private struct SchemaPane: View {
    @ObservedObject var model: AuditModel
    let report: Report
    let page: PageSummary
    @State private var copied: Int?

    var body: some View {
        let blocks = page.schema
        Scroller {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ReportFormat.short(page.url, site: report.site))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Stepper(model: model)
                        Button("Open") { model.open(page.url) }.buttonStyle(QuietButton(compact: true)).help("Open this page in the browser")
                    }
                    Text(summary(blocks))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let blocks {
                    if blocks.isEmpty { nothing }
                    ForEach(blocks) { block in self.block(block) }
                } else {
                    // A report kept before blocks were recorded knows the types and nothing more.
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Types")
                        Text(page.schemaTypes.isEmpty ? "None." : page.schemaTypes.joined(separator: ", "))
                            .font(.system(size: 13))
                        Text("This check was kept before blocks were recorded. Check the site again to see each one taken apart.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "A second opinion")
                    HStack(spacing: 8) {
                        Button("Schema.org validator") { model.open("https://validator.schema.org/") }.buttonStyle(QuietButton(compact: true))
                        Button("Rich Results Test") { model.open("https://search.google.com/test/rich-results") }.buttonStyle(QuietButton(compact: true))
                    }
                    Text("These open in the browser. Nothing is sent there: copy a block and paste it in.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ blocks: [SchemaBlock]?) -> String {
        var parts: [String] = []
        if let blocks {
            let items = blocks.flatMap(\.items).flatMap(flattened).count
            parts.append(blocks.count == 1 ? "1 JSON-LD block" : "\(blocks.count) JSON-LD blocks")
            if items > 0 { parts.append(items == 1 ? "1 item" : "\(items) items") }
        }
        if let markup = page.markup, !markup.isEmpty { parts.append("\(markup.joined(separator: " and ")) also found, not checked here") }
        return parts.joined(separator: " · ")
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No JSON-LD on this page").font(.system(size: 19, weight: .semibold)).tracking(-0.2)
            Text((page.markup ?? []).isEmpty
                ? "Nothing here tells a search engine what the page is. Add a JSON-LD script for the type that fits: an Organization on the home page, an Article on a post, a Product on a product page."
                : "The page describes itself with \((page.markup ?? []).joined(separator: " and ")) in its markup. That is read by search engines, but it is not taken apart here.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func block(_ block: SchemaBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionLabel(text: "Block \(block.index)")
                Text(block.parses ? "parses" : "does not parse")
                    .font(.system(size: 11))
                    .foregroundStyle(block.parses ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Tone.warning))
                Spacer(minLength: 8)
                if let raw = block.raw {
                    Button {
                        model.copy(raw)
                        copied = block.index
                    } label: {
                        SwapText(text: model.copied && copied == block.index ? "Copied" : "Copy JSON-LD")
                    }
                    .buttonStyle(QuietButton(compact: true))
                    .help("Copy this block as it is written on the page")
                }
            }
            if let error = block.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Mark(Mark.Kind.warning).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text("\(error) A block that cannot be read is ignored whole.")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            ForEach(block.items) { item in
                SchemaItemView(item: item)
            }
        }
    }
}

/// One item: its type, the result it can earn, what it lacks, then every property it carries, then what is nested in it.
private struct SchemaItemView: View {
    let item: SchemaItem
    var depth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name).font(.system(size: depth == 0 ? 15 : 13, weight: .semibold)).lineLimit(1)
                if let role = item.role {
                    Text("as \(role)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let result = item.richResult {
                    Text("Can earn: \(result)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !(item.required + item.recommended + item.notes).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(item.required, id: \.self) { line(.warning, $0, "required") }
                    ForEach(item.recommended, id: \.self) { line(.notice, $0, "recommended") }
                    ForEach(item.notes, id: \.self) { line(.notice, $0, nil) }
                }
            } else if depth == 0, !item.types.isEmpty {
                line(.passed, "Nothing its type asks for is missing.", nil)
            }
            VStack(spacing: 0) {
                ForEach(Array(item.fields.enumerated()), id: \.offset) { index, field in
                    if index > 0 { Tone.hairline.frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(field.name).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 132, alignment: .leading).lineLimit(1).truncationMode(.middle)
                        Text(field.value).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .padding(.vertical, 5)
                }
            }
            if !item.children.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shown) { SchemaItemView(item: $0, depth: depth + 1) }
                    ForEach(folded, id: \.self) { line in
                        Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) { Tone.hairline.frame(width: 1) }
                .padding(.top, 2)
            }
        }
        .padding(.top, depth == 0 ? 10 : 0)
        .overlay(alignment: .top) { if depth == 0 { Tone.hairline.frame(height: 1) } }
        .accessibilityElement(children: .contain)
    }

    /// A list of twenty reviews or steps is twenty of the same thing: the first two of each are drawn, the rest counted.
    /// Anything with something wrong is always drawn.
    private var shown: [SchemaItem] {
        var met: [String: Int] = [:]
        return item.children.filter { child in
            let key = (child.role ?? "") + child.name
            met[key, default: 0] += 1
            return (met[key] ?? 0) <= 2 || !(child.required + child.recommended + child.notes).isEmpty
        }
    }

    private var folded: [String] {
        let drawn = Set(shown.map(\.id))
        var counts: [(String, Int)] = []
        for child in item.children where !drawn.contains(child.id) {
            let name = "\(child.name)\(child.role.map { " as \($0)" } ?? "")"
            if let index = counts.firstIndex(where: { $0.0 == name }) { counts[index].1 += 1 } else { counts.append((name, 1)) }
        }
        return counts.map { "And \($0.1) more \($0.0), with nothing missing." }
    }

    private func line(_ mark: Mark.Kind, _ text: String, _ kind: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Mark(mark).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            if let kind { Text(kind).font(.system(size: 11)).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
    }
}
