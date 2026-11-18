import Foundation

/// The technical checks added from the seo-technical checklist: what robots.txt keeps crawlers from loading, where
/// canonicals lead, and what the robots and viewport tags forbid.
enum TechnicalChecks {
    /// Stylesheets and scripts on the site's own host that robots.txt keeps Google from loading.
    static func blockedAssets(stylesheets: [URL], scripts: [URL], robots: Robots) -> [String] {
        var seen = Set<String>()
        var blocked: [String] = []
        for file in stylesheets + scripts {
            let path = file.path + (file.query.map { "?\($0)" } ?? "")
            guard seen.insert(path).inserted, robots.blocks(path, agent: "Googlebot") else { continue }
            blocked.append(path)
        }
        return blocked
    }

    /// True when a robots directive keeps the page's text out of search results.
    static func forbidsSnippet(_ directives: String) -> Bool {
        let tidy = directives.lowercased().replacingOccurrences(of: " ", with: "")
        return tidy.split(whereSeparator: { $0 == "," || $0 == ";" }).contains { $0 == "nosnippet" || $0 == "max-snippet:0" }
    }

    /// What a viewport tag does to stop zooming, or nil when it does nothing of the kind.
    static func zoomBlock(in viewport: String) -> String? {
        let tidy = viewport.lowercased().replacingOccurrences(of: " ", with: "")
        for part in tidy.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "user-scalable", pair[1] == "no" || pair[1] == "0" { return "user-scalable=\(pair[1])" }
            if pair[0] == "maximum-scale", let scale = Double(pair[1]), scale <= 1 { return "maximum-scale=\(pair[1])" }
        }
        return nil
    }
}
