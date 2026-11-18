import AppKit
import ImageIO
import LaunchcheckCore
import SwiftUI

/// Every page on the left; on the right, the picked one where people will meet it: as a Google result, as the card a
/// chat app draws from a pasted link, and as the card X draws.
struct PreviewsTab: View {
    @ObservedObject var model: AuditModel
    let report: Report

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(prompt: "Filter \(report.pages.count) pages", text: $model.previewSearch)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                Tone.hairline.frame(height: 1)
                Scroller(target: model.previewPage) {
                    VStack(spacing: 1) {
                        let pages = model.previewPages
                        if pages.isEmpty {
                            Text(report.pages.isEmpty ? "This report has no page details. Check the site again to collect them." : "No page matches “\(model.previewSearch)”.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                        }
                        ForEach(pages) { page in
                            PreviewRow(page: page, site: report.site, notes: PagePreview.notes(for: page, host: report.host), selected: model.previewPage == page.url) {
                                Motion.run(Motion.swap) { model.previewPage = page.url }
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
            .frame(width: 264)
            Tone.hairline.frame(width: 1)
            Group {
                if let page = report.pages.first(where: { $0.url == model.previewPage }) {
                    PreviewPane(model: model, report: report, page: page)
                        .id(page.url)
                        .transition(.soft)
                } else {
                    Text(report.pages.isEmpty ? "No pages to preview" : "Pick a page").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One page in the list, with the most pressing thing about how it will look.
private struct PreviewRow: View {
    let page: PageSummary
    let site: String
    let notes: [PreviewNote]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let path = ReportFormat.short(page.url, site: site)
        let first = notes.first { $0.kind != .info }
        Button(action: action) {
            HStack(spacing: 10) {
                Mark(first.map { Mark.Kind($0.kind) } ?? .passed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(first?.label ?? "Looks right everywhere")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .frame(height: 44)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel("\(path), \(first?.label ?? "looks right everywhere")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Mark.Kind {
    /// A missing tag is something to fix; a cut or borrowed text is worth a look.
    init(_ kind: PreviewNote.Kind) {
        switch kind {
        case .missing: self = .warning
        case .cut, .fallback: self = .notice
        case .info: self = .none
        }
    }
}

// MARK: The picked page

private struct PreviewPane: View {
    @ObservedObject var model: AuditModel
    let report: Report
    let page: PageSummary
    /// Sizes of the share pictures once they have loaded, by address, so the notes can speak about them.
    @State private var sizes: [String: CGSize] = [:]

    var body: some View {
        let snippet = PagePreview.search(for: page, host: report.host)
        let chat = PagePreview.card(for: page, host: report.host, on: .chat)
        let x = PagePreview.card(for: page, host: report.host, on: .x)
        Scroller {
            VStack(alignment: .leading, spacing: 26) {
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
                block("On Google", caption: "a desktop result") {
                    SearchResult(snippet: snippet)
                    Notes(notes: snippet.notes, clear: "The title and the description both fit.")
                }
                // Side by side where there is room, as wide as a chat bubble; one above the other in a narrow window.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { cards(chat, x, width: 300) }
                    HStack(alignment: .top, spacing: 24) { cards(chat, x, width: 248) }
                    VStack(alignment: .leading, spacing: 26) { cards(chat, x, width: 300) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func cards(_ chat: LinkCard, _ x: LinkCard, width: CGFloat) -> some View {
        block("In a chat", caption: "Messages, Slack, WhatsApp") {
            CardView(card: chat, width: width) { remember($0, for: chat) }
            Notes(notes: chat.notes + sizeNotes(for: chat), clear: "Every tag this card needs is there.")
        }
        .frame(width: width)
        block("On X", caption: x.layout == .large ? "large image card" : (PagePreview.tag("twitter:card", of: page) == nil ? "no twitter:card tag" : "small card")) {
            CardView(card: x, width: width) { remember($0, for: x) }
            Notes(notes: x.notes + sizeNotes(for: x), clear: x.layout == .large ? "The large card, as asked for." : "The small card, as asked for.")
        }
        .frame(width: width)
    }

    private func remember(_ size: CGSize, for card: LinkCard) {
        if let address = card.image, sizes[address] != size { sizes[address] = size }
    }

    private func sizeNotes(for card: LinkCard) -> [PreviewNote] {
        guard let address = card.image, let size = sizes[address] else { return [] }
        return PagePreview.imageNote(width: Int(size.width), height: Int(size.height), layout: card.layout).map { [$0] } ?? []
    }

    private func block<Content: View>(_ title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionLabel(text: title)
                Text(caption).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What there is to say under a preview: one line each, or a single line saying there is nothing.
private struct Notes: View {
    let notes: [PreviewNote]
    let clear: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if notes.isEmpty {
                line(.passed, clear)
            } else {
                ForEach(notes) { note in line(Mark.Kind(note.kind), note.text) }
            }
        }
        .padding(.top, 2)
    }

    private func line(_ mark: Mark.Kind, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if mark == .none {
                    Image(systemName: "info.circle").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(width: 12, height: 12)
                } else {
                    Mark(mark)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: The objects themselves

/// A sheet lifted off the page: the one place a box is the right shape, because it stands for a real object.
struct Sheet<Content: View>: View {
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
struct SearchResult: View {
    let snippet: SearchSnippet
    /// Smaller type, for the side of the Pages tab.
    var compact = false

    static let link = Paint(light: Color(red: 0.10, green: 0.05, blue: 0.67), dark: Color(red: 0.56, green: 0.72, blue: 0.98))

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack(spacing: compact ? 8 : 10) {
                    Circle().fill(Tone.lift).frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                        .overlay(Text(String(snippet.siteName.prefix(1)).uppercased()).font(.system(size: compact ? 10 : 11.5, weight: .semibold)))
                    VStack(alignment: .leading, spacing: compact ? 0 : 1) {
                        Text(snippet.siteName).font(.system(size: compact ? 11.5 : 12.5)).lineLimit(1)
                        Text(snippet.breadcrumb)
                            .font(.system(size: compact ? 10.5 : 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if let title = snippet.title {
                    // Already cut where Google would cut it, so it is kept to one line however narrow the window.
                    Text(title.shown)
                        .font(.system(size: compact ? 16 : 18))
                        .foregroundStyle(Self.link)
                        .lineLimit(compact ? 2 : 1)
                        .minimumScaleFactor(compact ? 1 : 0.75)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No title: Google will write one from the page")
                        .font(.system(size: compact ? 16 : 18))
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let description = snippet.description {
                    Text(description.shown)
                        .font(.system(size: compact ? 12 : 13))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No meta description: Google will pick a snippet from the page instead.")
                        .font(.system(size: compact ? 12 : 13))
                        .lineSpacing(2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(compact ? 14 : 18)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The page as a link card, in the shape the card asks for.
struct CardView: View {
    let card: LinkCard
    var compact = false
    /// How wide to draw it. The side of the Pages tab has one width; the Previews tab chooses.
    var width: CGFloat = 376
    /// Told the picture's size in pixels once it has loaded.
    var measured: (CGSize) -> Void = { _ in }

    var body: some View {
        Sheet {
            switch card.layout {
            case .large:
                VStack(alignment: .leading, spacing: 0) {
                    // Cards crop to about 1.91 to 1, whatever shape the picture is.
                    Color.clear
                        .frame(height: (width / 1.91).rounded())
                        .overlay { SharePicture(address: card.image, tag: card.surface == .x ? "twitter:image or og:image" : "og:image", measured: measured) }
                        .clipped()
                    Tone.hairline.frame(height: 1)
                    words.padding(.horizontal, 12).padding(.vertical, 10)
                }
            case .thumbnail:
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 92, height: 92)
                        .overlay { SharePicture(address: card.image, tag: nil, measured: measured) }
                        .clipped()
                    Tone.hairline.frame(width: 1, height: 92)
                    words.padding(.horizontal, 12)
                }
            }
        }
        .frame(maxWidth: compact ? .infinity : width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.siteName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            if let title = card.title {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(card.layout == .large ? 2 : 1).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No title").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.tertiary)
            }
            if let description = card.description {
                Text(description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("No description").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The share picture of a page, or an honest account of why there is none.
struct SharePicture: View {
    let address: String?
    /// The tag to name when there is no picture. nil where there is only room for an icon.
    let tag: String?
    var measured: (CGSize) -> Void = { _ in }

    @State private var state: PictureStore.Loaded?
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if let address {
            if isSnapshot {
                // README images cannot load from the network; stand in with something that reads as a product photograph.
                GeometryReader { geometry in
                    let unit = geometry.size.height / 168
                    ZStack {
                        Color(red: 0.93, green: 0.90, blue: 0.84)
                        Circle().fill(Color(red: 0.87, green: 0.36, blue: 0.22)).frame(width: 150 * unit).offset(x: geometry.size.width * 0.27, y: 22 * unit)
                        Rectangle().fill(Color(red: 0.16, green: 0.15, blue: 0.14)).frame(width: geometry.size.width * 0.54, height: 46 * unit)
                            .offset(x: -geometry.size.width * 0.2, y: 56 * unit)
                        Text("ACME").font(.system(size: 38 * unit, weight: .black)).tracking(-1).foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.14))
                            .fixedSize()
                            .offset(x: -geometry.size.width * 0.27, y: -22 * unit)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                Group {
                    switch state {
                    case .picture(let image, _):
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    case .failed(let reason):
                        gap(reason, tone: Tone.error)
                    case nil:
                        Tone.wash
                    }
                }
                .task(id: address) {
                    let loaded = await PictureStore.shared.load(address)
                    state = loaded
                    if case .picture(_, let size) = loaded { measured(size) }
                }
            }
        } else {
            gap(tag.map { "No picture. Add \($0)." } ?? "", tone: Tone.warning)
        }
    }

    private func gap(_ text: String, tone: Paint) -> some View {
        ZStack {
            Tone.wash
            if tag == nil {
                Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(tone)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(tone)
                    Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                }
                .padding(.horizontal, 14)
            }
        }
        .help(text)
    }
}

/// Nothing larger is downloaded. A share picture this heavy would be a finding of its own.
private let ceiling = 12_000_000

/// Loads share pictures for the previews: one request per address, a ceiling on size, and a small decoded copy kept
/// in memory. A share picture is whatever the site says it is, so nothing about it is taken on trust.
@MainActor
final class PictureStore {
    enum Loaded {
        /// The picture, scaled down for drawing, and its real size in pixels.
        case picture(NSImage, CGSize)
        case failed(String)
    }

    static let shared = PictureStore()

    private var kept: [String: Loaded] = [:]
    private var order: [String] = []
    private var waiting: [String: Task<Loaded, Never>] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (compatible; Launchcheck/0.1)", "Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    func load(_ address: String) async -> Loaded {
        if let known = kept[address] { return known }
        if let running = waiting[address] { return await running.value }
        let session = session
        let task = Task.detached(priority: .userInitiated) { await Self.fetch(address, with: session) }
        waiting[address] = task
        let result = await task.value
        waiting[address] = nil
        kept[address] = result
        order.append(address)
        // A few dozen pictures are plenty for stepping back and forth through a site.
        if order.count > 40 { kept[order.removeFirst()] = nil }
        return result
    }

    private nonisolated static func fetch(_ address: String, with session: URLSession) async -> Loaded {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return .failed("The address of the picture is not a web address.")
        }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failed("The picture did not load: the server answered \(http.statusCode).")
            }
            if response.expectedContentLength > Int64(ceiling) {
                return .failed("The picture is over \(ceiling / 1_000_000) MB, too heavy to preview.")
            }
            var data = Data()
            data.reserveCapacity(max(0, Int(min(response.expectedContentLength, Int64(ceiling)))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > ceiling { return .failed("The picture is over \(ceiling / 1_000_000) MB, too heavy to preview.") }
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else {
                let type = (response.mimeType ?? "").lowercased()
                return .failed(type.contains("svg") ? "The picture is an SVG. Most apps will not draw one on a card: use a PNG or a JPEG."
                                                    : "The picture could not be read as an image.")
            }
            // Decode a copy no larger than a card needs, however large the file is.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 1400]
            guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return .failed("The picture could not be read as an image.")
            }
            return .picture(NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height)), CGSize(width: width, height: height))
        } catch {
            return .failed("The picture did not load: \(error.localizedDescription)")
        }
    }
}
