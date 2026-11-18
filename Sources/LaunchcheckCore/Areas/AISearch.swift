import Foundation

/// The AI search checks added from the seo-geo checklist: the agents that fetch a page when a user asks about it,
/// and whether the links in llms.txt lead anywhere.
enum AISearchChecks {
    /// Agents that fetch one page because a person asked an assistant about it. Not crawlers: they gather nothing.
    static let userAgents = ["ChatGPT-User", "Claude-User", "Perplexity-User"]

    static func blockedUserAgents(_ robots: Robots) -> [String] {
        userAgents.filter { robots.blocks("/", agent: $0) }
    }

    /// The addresses an llms.txt links to, in order, each once.
    static func links(in text: String, base: URL) -> [URL] {
        var seen = Set<String>()
        var found: [URL] = []
        var rest = Substring(text)
        while let open = rest.range(of: "](") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(where: { $0 == ")" || $0.isWhitespace }) else { break }
            let address = String(after[..<close])
            rest = after[close...]
            guard let url = Auditor.resolve(address, base: base), seen.insert(url.absoluteString).inserted else { continue }
            found.append(url)
        }
        return found
    }
}
