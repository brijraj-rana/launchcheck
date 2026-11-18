import Foundation

/// A text as it will be shown somewhere with limited room: all of it, or the part that fits.
public struct ClippedText: Equatable, Sendable {
    public let full: String
    public let shown: String

    public var isCut: Bool { shown != full }

    public init(full: String, shown: String) {
        self.full = full
        self.shown = shown
    }
}

/// Something worth saying about a preview: a tag that is missing, a text that gets cut, a value borrowed from elsewhere.
public struct PreviewNote: Equatable, Identifiable, Sendable {
    public enum Kind: Int, Comparable, Sendable {
        /// Nothing to show at all. A tag has to be added.
        case missing
        /// It shows, but not all of it.
        case cut
        /// It shows, with a value taken from another tag.
        case fallback
        /// Worth knowing, nothing to do.
        case info

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public let kind: Kind
    /// Two or three words, for a list: "No image".
    public let label: String
    /// The whole sentence, naming the tag to add.
    public let text: String
    /// The tag that would settle it, when there is one: "og:image".
    public let tag: String?

    public var id: String { label + "|" + text }

    public init(_ kind: Kind, _ label: String, _ text: String, tag: String? = nil) {
        self.kind = kind
        self.label = label
        self.text = text
        self.tag = tag
    }
}

/// A page as a Google result: the site, the address as a breadcrumb, the title and the description.
public struct SearchSnippet: Equatable, Sendable {
    public let siteName: String
    /// "https://www.acme.com › blog › launch-day"
    public let breadcrumb: String
    /// nil when the page has no title.
    public let title: ClippedText?
    /// nil when the page has no meta description.
    public let description: ClippedText?
    public let notes: [PreviewNote]
}

/// A page as a link card: what a chat app or X draws when the address is pasted.
public struct LinkCard: Equatable, Sendable {
    public enum Surface: Sendable {
        /// Messages, Slack, WhatsApp, LinkedIn: they read the Open Graph tags.
        case chat
        /// X reads its own twitter: tags first and the Open Graph ones after.
        case x
    }

    public enum Layout: Sendable {
        /// The picture across the top, the words beneath.
        case large
        /// A small square picture beside the words.
        case thumbnail
    }

    public let surface: Surface
    public let layout: Layout
    public let siteName: String
    public let title: String?
    public let description: String?
    /// The full address of the picture, when the page names one.
    public let image: String?
    public let notes: [PreviewNote]
}

public enum PagePreview {
    // MARK: Widths

    /// How much of a title Google shows on a desktop result, in ems: about 600 pixels of 20 pixel Arial.
    public static let titleWidth = 30.0
    /// The same for the description: two lines of 14 pixel Arial, which comes to about 155 characters of ordinary prose.
    public static let descriptionWidth = 74.0

    /// Google cuts by width, not by count: forty Ws are cut where sixty lowercase letters fit. This is the width of a
    /// text in ems, from Arial's widths gathered into a few classes. Near enough to say where the cut falls, give or
    /// take a word.
    public static func width(of text: String) -> Double {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of character: Character) -> Double {
        guard character.isASCII, let ascii = character.asciiValue else {
            // Accented Latin letters are about as wide as plain ones; scripts drawn in a square are a full em.
            guard let scalar = character.unicodeScalars.first else { return 0.56 }
            return scalar.value >= 0x1100 ? 1.0 : 0.56
        }
        switch Character(UnicodeScalar(ascii)) {
        case "i", "j", "l", "'", "|": return 0.22
        case " ", ".", ",", ":", ";", "!", "I", "f", "t", "/", "[", "]": return 0.28
        case "r", "-", "(", ")", "\"", "*": return 0.34
        case "c", "k", "s", "v", "x", "y", "z", "J": return 0.5
        case "m", "M": return 0.83
        case "w", "C", "D", "H", "N", "R", "U", "&": return 0.72
        case "W": return 0.94
        case "G", "O", "Q": return 0.78
        case "F", "T", "Z", "L": return 0.6
        case "A", "B", "E", "K", "P", "S", "V", "X", "Y": return 0.67
        case "%": return 0.89
        case "@": return 1.0
        default: return 0.56          // the other lowercase letters, digits and the common symbols
        }
    }

    /// Cuts a text the way Google does: at the last whole word that fits, with " ..." after it.
    public static func clip(_ text: String, to limit: Double) -> ClippedText {
        let full = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard width(of: full) > limit else { return ClippedText(full: full, shown: full) }
        let ellipsis = " ..."
        let room = limit - width(of: ellipsis)
        var used = 0.0
        var kept: [Character] = []
        var lastBreak: Int?
        let characters = Array(full)
        for character in characters {
            let next = used + width(of: character)
            if next > room { break }
            if character == " " { lastBreak = kept.count }
            kept.append(character)
            used = next
        }
        // Back to the end of the last whole word, unless that would throw away most of the line (one very long word).
        let midWord = kept.count < characters.count && characters[kept.count] != " "
        if midWord, let lastBreak, lastBreak > kept.count / 2 { kept = Array(kept[..<lastBreak]) }
        let untidy: Set<Character> = [" ", ",", ";", ":", "-", "|", "·", "(", "/"]
        while let last = kept.last, untidy.contains(last) { kept.removeLast() }
        return ClippedText(full: full, shown: String(kept) + ellipsis)
    }

    // MARK: Search

    /// "https://www.acme.com › blog › launch-day": the address as Google writes it above a result.
    public static func breadcrumb(for address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        let parts = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        return (["\(url.scheme ?? "https")://\(host)"] + parts).joined(separator: " › ")
    }

    public static func search(for page: PageSummary, host: String) -> SearchSnippet {
        let title = tidy(page.title)
        let description = tidy(page.description)
        var notes: [PreviewNote] = []

        let shownTitle = title.map { clip($0, to: titleWidth) }
        if let shownTitle {
            if shownTitle.isCut {
                notes.append(PreviewNote(.cut, "Title cut", "The title is \(shownTitle.full.count) characters and Google shows about the first \(visibleCount(shownTitle)). Put the words that matter first, or shorten it."))
            }
        } else {
            notes.append(PreviewNote(.missing, "No title", "No title, so Google writes one from the page. Add a <title> tag.", tag: "title"))
        }

        let shownDescription = description.map { clip($0, to: descriptionWidth) }
        if let shownDescription {
            if shownDescription.isCut {
                notes.append(PreviewNote(.cut, "Description cut", "The description is \(shownDescription.full.count) characters and Google shows about the first \(visibleCount(shownDescription)). Say the main thing early."))
            }
        } else {
            notes.append(PreviewNote(.missing, "No description", "No meta description, so Google picks a snippet from the page. Add a meta description tag.", tag: "description"))
        }
        if !page.indexable {
            notes.append(PreviewNote(.info, "Noindex", "This page is set to noindex, so it will not appear in search at all."))
        }
        return SearchSnippet(siteName: tidy(tag("og:site_name", of: page)) ?? bare(host), breadcrumb: breadcrumb(for: page.url),
                             title: shownTitle, description: shownDescription, notes: notes)
    }

    private static func visibleCount(_ text: ClippedText) -> Int {
        max(0, text.shown.count - 4)
    }

    // MARK: Link cards

    /// One Open Graph or Twitter tag of a page. Reports kept before the tags were recorded only know three of them.
    public static func tag(_ name: String, of page: PageSummary) -> String? {
        if let tags = page.shareTags { return tags[name] }
        switch name {
        case "og:title": return page.shareTitle
        case "og:description": return page.shareDescription
        case "og:image": return page.shareImage
        default: return nil
        }
    }

    /// The card a pasted link turns into. Open Graph tags fall back to the page's own title and description;
    /// on X, the twitter: tags come first and fall back to the Open Graph ones.
    public static func card(for page: PageSummary, host: String, on surface: LinkCard.Surface) -> LinkCard {
        func value(_ name: String) -> String? { tidy(tag(name, of: page)) }
        let pageTitle = tidy(page.title), pageDescription = tidy(page.description)
        let siteName = value("og:site_name") ?? bare(host)
        var notes: [PreviewNote] = []

        let title = value("og:title") ?? pageTitle
        let description = value("og:description") ?? pageDescription
        let image = value("og:image")

        switch surface {
        case .chat:
            if value("og:title") == nil {
                notes.append(pageTitle == nil
                    ? PreviewNote(.missing, "No title", "No title to show. Add an og:title tag.", tag: "og:title")
                    : PreviewNote(.fallback, "Title borrowed", "No og:title, so the page title is used. Add og:title to choose the words.", tag: "og:title"))
            }
            if value("og:description") == nil {
                notes.append(pageDescription == nil
                    ? PreviewNote(.missing, "No description", "No description to show. Add an og:description tag.", tag: "og:description")
                    : PreviewNote(.fallback, "Description borrowed", "No og:description, so the meta description is used. Add og:description to choose the words.", tag: "og:description"))
            }
            if image == nil {
                notes.append(PreviewNote(.missing, "No image", "No picture, so the card is text only. Add an og:image tag: 1200 by 630 pixels works everywhere.", tag: "og:image"))
            }
            return LinkCard(surface: .chat, layout: .large, siteName: siteName, title: title, description: description, image: image, notes: notes)

        case .x:
            let card = value("twitter:card")?.lowercased()
            let ownImage = value("twitter:image")
            let shownImage = ownImage ?? image
            if card == nil {
                notes.append(PreviewNote(.fallback, "No twitter:card", "No twitter:card tag, so X draws the small card at best. Add twitter:card with summary_large_image for the large one.", tag: "twitter:card"))
            } else if card == "summary" {
                notes.append(PreviewNote(.info, "Small card", "twitter:card is summary, so X draws a small square picture. Use summary_large_image for the large one."))
            }
            if shownImage == nil {
                notes.append(PreviewNote(.missing, "No image", "No picture on X either. It reads twitter:image, then og:image.", tag: "og:image"))
            }
            let ownTitle = value("twitter:title"), ownDescription = value("twitter:description")
            var differs: [String] = []
            if let ownTitle, ownTitle != title { differs.append("title") }
            if let ownDescription, ownDescription != description { differs.append("description") }
            if let ownImage, ownImage != image, image != nil { differs.append("picture") }
            if !differs.isEmpty {
                notes.append(PreviewNote(.info, "Differs on X", "The twitter: tags give X a different \(list(differs)) from the one chat apps show."))
            }
            return LinkCard(surface: .x, layout: card == "summary_large_image" ? .large : .thumbnail, siteName: siteName,
                            title: ownTitle ?? title, description: ownDescription ?? description, image: shownImage, notes: notes)
        }
    }

    /// Everything to say about how a page will look, most pressing first. For a list that shows which pages need a look.
    public static func notes(for page: PageSummary, host: String) -> [PreviewNote] {
        let all = search(for: page, host: host).notes + card(for: page, host: host, on: .chat).notes + card(for: page, host: host, on: .x).notes
        var seen = Set<String>()
        return all.enumerated()
            .sorted { a, b in a.element.kind != b.element.kind ? a.element.kind < b.element.kind : a.offset < b.offset }
            .map(\.element)
            .filter { seen.insert($0.label).inserted }
    }

    /// What to say about a share picture once its size is known, or nil when it suits the card.
    public static func imageNote(width: Int, height: Int, layout: LinkCard.Layout) -> PreviewNote? {
        guard width > 0, height > 0 else { return nil }
        let size = "\(width) by \(height) pixels"
        switch layout {
        case .large:
            if width < 600 || height < 315 {
                return PreviewNote(.cut, "Small picture", "The picture is \(size). Under 600 by 315 it is drawn small or soft. 1200 by 630 works everywhere.")
            }
            let ratio = Double(width) / Double(height)
            if ratio < 1.6 || ratio > 2.2 {
                return PreviewNote(.cut, "Picture cropped", "The picture is \(size). Large cards are about twice as wide as they are tall, so its edges are cropped.")
            }
        case .thumbnail:
            if width < 144 || height < 144 {
                return PreviewNote(.cut, "Small picture", "The picture is \(size). X asks for at least 144 by 144.")
            }
        }
        return nil
    }

    // MARK: Pieces

    private static func tidy(_ text: String?) -> String? {
        guard let text else { return nil }
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func bare(_ host: String) -> String {
        host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func list(_ words: [String]) -> String {
        guard words.count > 1, let last = words.last else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }
}
