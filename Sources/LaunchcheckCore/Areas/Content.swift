import Foundation

/// The content checks added from the seo-content checklist: pages that repeat each other word for word, articles
/// with no date, and a home page with no way to the people behind it.
enum ContentChecks {
    struct Page {
        var url: URL
        var fingerprint: UInt64
        var words: Int
    }

    /// Groups of pages whose visible text is the same, word for word. Short pages are left out: two near-empty
    /// pages share their navigation and footer, not their content.
    static func duplicates(among pages: [Page]) -> [[URL]] {
        var groups: [UInt64: [URL]] = [:]
        var order: [UInt64] = []
        for page in pages where page.words >= 100 {
            if groups[page.fingerprint] == nil { order.append(page.fingerprint) }
            groups[page.fingerprint, default: []].append(page.url)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    /// True for a page that calls itself an article and gives no date anywhere a machine would look.
    /// Sections of a site where pages are dated writing. og:type alone is not enough to go on: plenty of sites set
    /// "article" on every page that is not the home page.
    static let datedSections = ["blog", "news", "post", "posts", "article", "articles", "journal", "stories", "insights", "press", "updates", "changelog"]

    static func isUndatedArticle(_ facts: PageFacts, url: URL, schemaTypes: [String]) -> Bool {
        guard facts.social["og:type"]?.lowercased() == "article" else { return false }
        let parts = url.path.lowercased().split(separator: "/").map(String.init)
        // The section's own front page lists articles; it is not one.
        guard parts.count > 1, parts.dropLast().contains(where: datedSections.contains) else { return false }
        // An Article in the JSON-LD has its date checked with the structured data.
        if schemaTypes.contains(where: SchemaInspector.articleTypes.contains) { return false }
        if facts.hasTime || facts.social["article:published_time"] != nil || facts.social["article:modified_time"] != nil { return false }
        return !facts.jsonLD.contains { $0.contains("datePublished") || $0.contains("dateModified") }
    }

    /// Words that name a contact or about page, in the languages a marketing site is most often written in.
    static let contactWords = ["contact", "kontakt", "contacto", "contato", "contatti", "about", "ueber", "uber-uns", "über", "a-propos", "à propos",
                               "sobre", "chi-siamo", "chi siamo", "impressum", "team", "company", "support", "help", "get in touch", "over-ons", "om-oss",
                               "お問い合わせ", "联系", "聯絡", "연락", "связ", "iletişim", "iletisim", "kapcsolat", "yhteys", "o-nas", "o nas"]

    /// True when the home page links to somewhere a visitor could reach or read about the people behind the site.
    static func linksToPeople(_ facts: PageFacts) -> Bool {
        facts.anchors.contains { link in
            let href = link.href.lowercased(), text = link.text.lowercased()
            if href.hasPrefix("mailto:") || href.hasPrefix("tel:") { return true }
            return contactWords.contains { href.contains($0) || text.contains($0) }
        }
    }
}
