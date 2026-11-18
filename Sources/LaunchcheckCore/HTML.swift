import Foundation

public struct Heading: Equatable, Codable, Sendable {
    public var level: Int
    public var text: String
}

public struct ImageFact: Equatable, Sendable {
    public var source: String
    /// nil when the attribute is absent, "" when it is present and empty (a decorative image).
    public var alt: String?
    public var hasDimensions: Bool
    public var lazy: Bool
    public var decorative: Bool
    /// The file is only named in a data attribute, for a script to load later.
    public var deferred: Bool = false
}

public struct LinkFact: Equatable, Sendable {
    public var href: String
    /// The visible words, or the alt text of an image inside the link.
    public var text: String
    public var rel: Set<String>
    public var opensNewTab: Bool
}

public struct Alternate: Equatable, Sendable {
    public var hreflang: String
    public var href: String
}

/// What the audit needs to know about one HTML page.
public struct PageFacts: Equatable, Sendable {
    public var hasDoctype = false
    public var hasCharset = false
    public var title: String?
    public var titleCount = 0
    public var description: String?
    public var descriptionCount = 0
    /// Directives from every robots meta tag, lowercased ("noindex", "nofollow").
    public var robots: Set<String> = []
    public var canonical: String?
    public var canonicalCount = 0
    public var base: String?
    public var lang: String?
    public var hasViewport = false
    public var viewport: String?
    public var hasFavicon = false
    public var metaRefresh: String?
    public var generator: String?
    /// Open Graph and Twitter tags by name ("og:image", "twitter:card").
    public var social: [String: String] = [:]
    public var headings: [Heading] = []
    public var anchors: [LinkFact] = []
    public var images: [ImageFact] = []
    public var alternates: [Alternate] = []
    /// The contents of each JSON-LD script, unparsed.
    public var jsonLD: [String] = []
    public var hasMicrodata = false
    /// Files requested over plain http.
    public var insecureResources: [String] = []
    public var hasPlaceholderText = false
    /// Built with Webflow, where a link to a webflow.io address is almost always the site's own staging copy.
    public var isWebflow = false
    /// Words of visible text in the body.
    public var wordCount = 0
    public var scriptCount = 0
    /// External scripts in the head with no async, defer or module type: they hold up the first paint.
    public var blockingScripts: [String] = []
    public var stylesheetCount = 0
    public var hasPrevNext = false
    /// Has the empty mount point of a client-rendered app (id="root", "app", "__next" or "__nuxt").
    public var hasAppRoot = false
    public var iframeCount = 0
    /// The addresses of every stylesheet and external script, as written.
    public var stylesheets: [String] = []
    public var scripts: [String] = []
    /// A hash of the visible words of the body, lowercased: two pages with the same text have the same one.
    public var textFingerprint: UInt64 = 0
    /// Has a <time> element, the usual way a page marks up a date.
    public var hasTime = false
    /// Carries RDFa attributes (typeof, vocab): structured data written into the markup.
    public var hasRDFa = false

    public init() {}

    public var h1Count: Int { headings.filter { $0.level == 1 }.count }
    public var h1: String? { headings.first { $0.level == 1 }?.text }
    public var links: [String] { anchors.map(\.href) }
    public var imageCount: Int { images.count }
    public var imagesMissingAlt: [String] { images.filter { $0.alt == nil && !$0.decorative }.map(\.source) }
}

public enum HTMLScanner {
    /// Reads a page without building a tree: one pass over the tags, tolerant of whatever markup it finds.
    public static func scan(_ data: Data) -> PageFacts {
        scan(String(decoding: data, as: UTF8.self))
    }

    public static func scan(_ html: String) -> PageFacts {
        var facts = PageFacts()
        let bytes = Array(html.utf8)
        let count = bytes.count
        var i = 0

        var inTitle = false
        var titleBytes: [UInt8] = []
        var textBytes: [UInt8] = []                // the current run of text, for placeholder detection
        var inBody = false
        var inWord = false
        var hidden = 0                             // depth inside elements whose text nobody reads (svg, noscript, template)

        var fingerprint: UInt64 = 0xcbf2_9ce4_8422_2325        // FNV-1a over the words of the body
        var headingLevel = 0
        var headingBytes: [UInt8] = []
        var anchor: LinkFact?
        var anchorBytes: [UInt8] = []
        var inHead = true

        func flushText() {
            guard !textBytes.isEmpty else { return }
            if !facts.hasPlaceholderText, textBytes.count >= 11 {
                let text = String(decoding: textBytes, as: UTF8.self).lowercased()
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if text.contains("lorem ipsum") { facts.hasPlaceholderText = true }
            }
            textBytes.removeAll(keepingCapacity: true)
        }

        func text(_ byte: UInt8) {
            if inTitle {
                titleBytes.append(byte)
                return
            }
            guard hidden == 0 else { return }
            textBytes.append(byte)
            if headingLevel > 0 { headingBytes.append(byte) }
            if anchor != nil { anchorBytes.append(byte) }
            if inBody {
                let letter = byte >= 0x80 || isLetter(byte) || (byte >= 48 && byte <= 57)
                if letter, !inWord {
                    facts.wordCount += 1
                    fingerprint = (fingerprint ^ 32) &* 0x0000_0100_0000_01b3
                }
                if letter { fingerprint = (fingerprint ^ UInt64(isLetter(byte) ? byte | 0x20 : byte)) &* 0x0000_0100_0000_01b3 }
                inWord = letter || (inWord && (byte == UInt8(ascii: "'") || byte == UInt8(ascii: "-")))
            }
        }

        while i < count {
            let byte = bytes[i]
            guard byte == UInt8(ascii: "<") else {
                text(byte)
                i += 1
                continue
            }

            if starts(bytes, at: i, with: "<!--") {
                i = find(bytes, "-->", from: i + 4).map { $0 + 3 } ?? count
                continue
            }
            let next = i + 1 < count ? bytes[i + 1] : 0
            let closing = next == UInt8(ascii: "/")
            let nameStart = closing ? i + 2 : i + 1
            guard nameStart < count, isLetter(bytes[nameStart]) else {
                if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") {
                    if startsIgnoringCase(bytes, at: i, with: "<!doctype") { facts.hasDoctype = true }
                    i = find(bytes, ">", from: i + 1).map { $0 + 1 } ?? count
                } else {
                    text(byte)                    // a stray "<" in text
                    i += 1
                }
                continue
            }

            var j = nameStart
            while j < count, !isSpace(bytes[j]), bytes[j] != UInt8(ascii: ">"), bytes[j] != UInt8(ascii: "/") { j += 1 }
            let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()

            if closing {
                i = find(bytes, ">", from: j).map { $0 + 1 } ?? count
                switch name {
                case "title":
                    if inTitle {
                        inTitle = false
                        if facts.title == nil { facts.title = clean(String(decoding: titleBytes, as: UTF8.self)) }
                    }
                case "head":
                    inHead = false
                case "body":
                    inBody = false
                case "svg", "noscript", "template":
                    hidden = max(0, hidden - 1)
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    if headingLevel > 0 {
                        facts.headings.append(Heading(level: headingLevel, text: clean(String(decoding: headingBytes, as: UTF8.self))))
                        headingLevel = 0
                        headingBytes.removeAll(keepingCapacity: true)
                    }
                case "a":
                    if var finished = anchor {
                        let words = clean(String(decoding: anchorBytes, as: UTF8.self))
                        if !words.isEmpty { finished.text = words }
                        facts.anchors.append(finished)
                        anchor = nil
                        anchorBytes.removeAll(keepingCapacity: true)
                    }
                default:
                    break
                }
                if !isInline(name) {
                    inWord = false
                    flushText()
                }
                continue
            }

            let (attributes, end) = parseAttributes(bytes, from: j)
            i = end
            if !isInline(name) {
                // Text on either side of a block tag belongs to separate runs.
                inWord = false
                flushText()
                if headingLevel > 0 { headingBytes.append(UInt8(ascii: " ")) }
                if anchor != nil { anchorBytes.append(UInt8(ascii: " ")) }
            }
            if attributes["itemscope"] != nil || attributes["itemtype"] != nil { facts.hasMicrodata = true }
            if attributes["typeof"] != nil || attributes["vocab"] != nil { facts.hasRDFa = true }
            if let id = attributes["id"], id == "root" || id == "app" || id == "__next" || id == "__nuxt" { facts.hasAppRoot = true }

            switch name {
            case "title":
                // Only the document's own title counts, not one inside an inline SVG.
                if hidden == 0 {
                    facts.titleCount += 1
                    if facts.title == nil {
                        inTitle = true
                        titleBytes.removeAll()
                    }
                }
            case "html":
                if let lang = attributes["lang"], !lang.isEmpty { facts.lang = lang }
                if attributes["data-wf-site"] != nil { facts.isWebflow = true }
            case "body":
                inBody = true
                inHead = false
            case "base":
                if let href = attributes["href"], facts.base == nil { facts.base = href }
            case "meta":
                if attributes["charset"] != nil { facts.hasCharset = true }
                let equivalent = (attributes["http-equiv"] ?? "").lowercased()
                let content = clean(attributes["content"] ?? "")
                if equivalent == "content-type", content.lowercased().contains("charset") { facts.hasCharset = true }
                if equivalent == "refresh" { facts.metaRefresh = content }
                let key = (attributes["name"] ?? attributes["property"] ?? "").lowercased()
                switch key {
                case "description":
                    facts.descriptionCount += 1
                    if facts.description == nil { facts.description = content }
                case "robots", "googlebot":
                    for directive in content.lowercased().split(separator: ",") {
                        facts.robots.insert(directive.trimmingCharacters(in: .whitespaces))
                    }
                case "viewport":
                    facts.hasViewport = true
                    facts.viewport = content
                case "generator":
                    facts.generator = content
                    if content.lowercased().contains("webflow") { facts.isWebflow = true }
                default:
                    if key.hasPrefix("og:") || key.hasPrefix("twitter:") || key.hasPrefix("article:"),
                       facts.social[key] == nil, !content.isEmpty {
                        facts.social[key] = content
                    }
                }
            case "link":
                let rel = (attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init)
                let href = clean(attributes["href"] ?? "")
                if rel.contains("canonical") {
                    facts.canonicalCount += 1
                    if facts.canonical == nil { facts.canonical = href }
                }
                if rel.contains("icon") || rel.contains("apple-touch-icon") { facts.hasFavicon = true }
                if rel.contains("stylesheet") {
                    facts.stylesheetCount += 1
                    if !href.isEmpty { facts.stylesheets.append(href) }
                    if isInsecure(href) { facts.insecureResources.append(href) }
                }
                if rel.contains("alternate"), let language = attributes["hreflang"], !language.isEmpty {
                    facts.alternates.append(Alternate(hreflang: language, href: href))
                }
                if rel.contains("next") || rel.contains("prev") { facts.hasPrevNext = true }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if hidden == 0 {
                    // An unclosed heading ends where the next one starts.
                    if headingLevel > 0 {
                        facts.headings.append(Heading(level: headingLevel, text: clean(String(decoding: headingBytes, as: UTF8.self))))
                    }
                    headingLevel = Int(name.dropFirst()) ?? 1
                    headingBytes.removeAll(keepingCapacity: true)
                }
            case "a":
                if let unfinished = anchor { facts.anchors.append(unfinished) }
                anchor = nil
                anchorBytes.removeAll(keepingCapacity: true)
                if let href = attributes["href"] {
                    let rel = Set((attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
                    let label = clean(attributes["aria-label"] ?? attributes["title"] ?? "")
                    anchor = LinkFact(href: clean(href), text: label, rel: rel, opensNewTab: attributes["target"]?.lowercased() == "_blank")
                }
            case "img":
                let source = clean(attributes["src"] ?? attributes["data-src"] ?? "")
                let decorative = attributes["role"] == "presentation" || attributes["aria-hidden"] == "true"
                let alt = attributes["alt"].map(clean)
                let written = attributes["src"] ?? ""
                let deferred = (written.isEmpty || written.hasPrefix("data:")) && (attributes["data-src"] != nil || attributes["data-srcset"] != nil || attributes["data-lazy-src"] != nil)
                facts.images.append(ImageFact(source: source, alt: alt,
                                              hasDimensions: attributes["width"] != nil && attributes["height"] != nil,
                                              lazy: attributes["loading"]?.lowercased() == "lazy", decorative: decorative, deferred: deferred))
                if isInsecure(source) { facts.insecureResources.append(source) }
                if anchor != nil, let alt, !alt.isEmpty, anchor?.text.isEmpty == true { anchor?.text = alt }
            case "script":
                facts.scriptCount += 1
                let kind = (attributes["type"] ?? "").lowercased()
                if let source = attributes["src"] {
                    if !source.isEmpty { facts.scripts.append(clean(source)) }
                    if isInsecure(source) { facts.insecureResources.append(source) }
                    if inHead, attributes["async"] == nil, attributes["defer"] == nil, attributes["nomodule"] == nil, kind != "module" {
                        facts.blockingScripts.append(source)
                    }
                }
                // Its contents are code, not markup: skip to the closing tag.
                let close = findClosing(bytes, tag: name, from: i)
                if kind == "application/ld+json" {
                    let bodyEnd = close.flatMap { lastIndex(of: UInt8(ascii: "<"), in: bytes, before: $0) } ?? count
                    if bodyEnd > i { facts.jsonLD.append(String(decoding: bytes[i..<bodyEnd], as: UTF8.self)) }
                }
                i = close ?? count
            case "style":
                i = findClosing(bytes, tag: name, from: i) ?? count
            case "svg", "noscript", "template":
                hidden += 1
            case "time":
                facts.hasTime = true
            case "iframe":
                facts.iframeCount += 1
                if let source = attributes["src"], isInsecure(source) { facts.insecureResources.append(source) }
            case "source", "video", "audio", "embed":
                if let source = attributes["src"], isInsecure(source) { facts.insecureResources.append(source) }
            default:
                break
            }
        }
        flushText()
        if headingLevel > 0 {
            facts.headings.append(Heading(level: headingLevel, text: clean(String(decoding: headingBytes, as: UTF8.self))))
        }
        if let unfinished = anchor { facts.anchors.append(unfinished) }
        facts.textFingerprint = fingerprint
        return facts
    }

    // MARK: Pieces

    private static func isInline(_ name: String) -> Bool {
        switch name {
        case "a", "span", "b", "i", "em", "strong", "u", "small", "sup", "sub", "code", "mark", "abbr", "font", "img": return true
        default: return false
        }
    }

    private static func isInsecure(_ url: String) -> Bool {
        url.lowercased().hasPrefix("http://")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
    }

    private static func starts(_ bytes: [UInt8], at index: Int, with text: String) -> Bool {
        let needle = Array(text.utf8)
        guard index + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count where bytes[index + k] != needle[k] { return false }
        return true
    }

    private static func startsIgnoringCase(_ bytes: [UInt8], at index: Int, with text: String) -> Bool {
        let needle = Array(text.utf8)
        guard index + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count {
            let a = bytes[index + k], b = needle[k]
            if a != b, !(isLetter(a) && (a | 0x20) == b) { return false }
        }
        return true
    }

    private static func lastIndex(of byte: UInt8, in bytes: [UInt8], before end: Int) -> Int? {
        var i = min(end, bytes.count) - 1
        while i >= 0 {
            if bytes[i] == byte { return i }
            i -= 1
        }
        return nil
    }

    private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, start <= bytes.count - needle.count else { return nil }
        var i = start
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == needle[0] {
                var match = true
                for k in 1..<needle.count where bytes[i + k] != needle[k] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// The index just past `</tag ...>`, matched without regard to case.
    private static func findClosing(_ bytes: [UInt8], tag: String, from start: Int) -> Int? {
        let needle = Array(tag.utf8)
        var i = start
        while let open = find(bytes, "</", from: i) {
            let nameStart = open + 2
            if nameStart + needle.count <= bytes.count {
                var match = true
                for k in 0..<needle.count where (bytes[nameStart + k] | 0x20) != needle[k] {
                    match = false
                    break
                }
                if match { return find(bytes, ">", from: nameStart).map { $0 + 1 } ?? bytes.count }
            }
            i = open + 2
        }
        return nil
    }

    /// Reads attributes up to and including the closing ">". Returns them with lowercased names.
    private static func parseAttributes(_ bytes: [UInt8], from start: Int) -> ([String: String], Int) {
        var attributes: [String: String] = [:]
        var i = start
        let count = bytes.count
        while i < count {
            while i < count, isSpace(bytes[i]) || bytes[i] == UInt8(ascii: "/") { i += 1 }
            guard i < count else { break }
            if bytes[i] == UInt8(ascii: ">") { return (attributes, i + 1) }

            let nameStart = i
            while i < count, !isSpace(bytes[i]), bytes[i] != UInt8(ascii: "="), bytes[i] != UInt8(ascii: ">") { i += 1 }
            let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
            while i < count, isSpace(bytes[i]) { i += 1 }

            var value = ""
            if i < count, bytes[i] == UInt8(ascii: "=") {
                i += 1
                while i < count, isSpace(bytes[i]) { i += 1 }
                if i < count, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") {
                    let quote = bytes[i]
                    let valueStart = i + 1
                    i = valueStart
                    while i < count, bytes[i] != quote { i += 1 }
                    value = String(decoding: bytes[valueStart..<i], as: UTF8.self)
                    i = min(i + 1, count)
                } else {
                    let valueStart = i
                    while i < count, !isSpace(bytes[i]), bytes[i] != UInt8(ascii: ">") { i += 1 }
                    value = String(decoding: bytes[valueStart..<i], as: UTF8.self)
                }
            }
            if !name.isEmpty, attributes[name] == nil { attributes[name] = value }
        }
        return (attributes, count)
    }

    /// Collapses whitespace and decodes the handful of entities that turn up in titles and descriptions.
    static func clean(_ text: String) -> String {
        var result = text
        if result.contains("&") {
            let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                         "&ndash;": "–", "&mdash;": "—", "&rsquo;": "’", "&lsquo;": "‘", "&hellip;": "…", "&#x27;": "'"]
            for (entity, character) in named { result = result.replacingOccurrences(of: entity, with: character) }
            // Numeric entities such as &#8211; or &#x2014;
            var output = ""
            var rest = Substring(result)
            while let start = rest.range(of: "&#") {
                output += rest[..<start.lowerBound]
                let after = rest[start.upperBound...]
                if let semicolon = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semicolon) <= 7 {
                    let body = after[..<semicolon]
                    let code = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                    if let code, let scalar = Unicode.Scalar(code) {
                        output.unicodeScalars.append(scalar)
                        rest = after[after.index(after: semicolon)...]
                        continue
                    }
                }
                output += "&#"
                rest = after
            }
            result = output + rest
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
