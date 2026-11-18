import Foundation

/// Sitemap: whether the files that are named exist and whether their dates can be true. The older sitemap checks
/// (entries that redirect, error, are blocked or noindex) need the crawl and live with the audit itself.
/// After the seo-sitemap checklist.
enum SitemapChecks {
    /// A sitemap file that was asked for and could not be used.
    static func unreadable(_ result: FetchResult, parsed: SitemapContents, namedBy source: String) -> String? {
        let address = result.url.absoluteString
        // A server turning a robot away says nothing about the file.
        if [401, 403, 429].contains(result.status) { return nil }
        if result.status == 0 { return "\(source) names \(address), which did not load" }
        if !result.ok { return "\(source) names \(address), which returned \(result.status)" }
        // A compressed sitemap is not opened here, and a plain list of addresses is a valid sitemap.
        let type = (result.headers["content-type"] ?? "").lowercased()
        if result.url.pathExtension.lowercased() == "gz" || type.contains("gzip") { return nil }
        if parsed.pages.isEmpty, parsed.sitemaps.isEmpty {
            let text = String(decoding: result.body.prefix(4000), as: UTF8.self)
            if result.body.isEmpty { return nil }                               // nothing was read; say nothing
            if !result.isHTML, text.contains("http"), !text.contains("<") { return nil }
            if text.contains("<urlset") || text.contains("<sitemapindex") { return nil }     // a sitemap, with nothing in it yet
            return "\(source) names \(address), which is not a sitemap"
        }
        return nil
    }

    /// What is wrong with the last-modified dates of a sitemap, in a sentence each.
    static func lastmodProblems(_ dates: [String], now: Date = Date()) -> [String] {
        var formatter = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        // Two days of grace, so a date written in another time zone is never called the future.
        let limit = formatter.dateComponents([.year, .month, .day], from: now.addingTimeInterval(2 * 86_400))
        let ceiling = String(format: "%04d-%02d-%02d", limit.year ?? 0, limit.month ?? 0, limit.day ?? 0)

        var malformed: [String] = []
        var future: [String] = []
        for date in dates {
            guard SchemaInspector.isDate(date) else {
                malformed.append(date)
                continue
            }
            if date.count >= 10, String(date.prefix(10)) > ceiling { future.append(date) }
        }
        var problems: [String] = []
        if let first = future.first {
            problems.append(future.count == 1 ? "1 entry is dated in the future: \(first)" : "\(future.count) entries are dated in the future, such as \(first)")
        }
        if let first = malformed.first {
            problems.append(malformed.count == 1 ? "1 date is not a date: “\(first.prefix(40))”" : "\(malformed.count) dates are not dates, such as “\(first.prefix(40))”")
        }
        return problems
    }
}
