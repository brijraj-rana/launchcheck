import Foundation

/// International: what a page's hreflang tags say, beyond whether the codes exist and the links are returned
/// (those checks are older and live with the audit itself). After the seo-hreflang checklist.
enum InternationalChecks {
    struct Page {
        var url: URL
        /// One identity for the page, as `Auditor.key` gives it.
        var key: String
        /// The canonical, when the page has one that is not itself.
        var canonicalElsewhere: String?
        /// Each hreflang tag, in the order written: the code and where it points.
        var entries: [(code: String, target: URL)]
    }

    static func findings(for pages: [Page], state: (String) -> TargetState?) -> [Finding] {
        var findings: [Finding] = []
        for page in pages where !page.entries.isEmpty {
            // On a page that is not its own canonical, the tags are not read at all.
            if let canonical = page.canonicalElsewhere {
                findings.append(Finding("hreflang.noncanonical", url: page.url, detail: "canonical is \(canonical)"))
            }

            // One language, two different pages.
            var byCode: [String: [String]] = [:]
            var order: [String] = []
            for entry in page.entries {
                let code = entry.code.lowercased()
                if byCode[code] == nil { order.append(code) }
                let key = Auditor.key(entry.target)
                if byCode[code]?.contains(key) != true { byCode[code, default: []].append(key) }
            }
            let doubled = order.filter { (byCode[$0]?.count ?? 0) > 1 }
            if let detail = summarized(doubled.map { "\($0) is given \(byCode[$0]?.count ?? 2) different addresses" }) {
                findings.append(Finding("hreflang.duplicate", url: page.url, detail: detail))
            }

            // A stray http address in a set that is otherwise https.
            if page.url.scheme == "https" {
                let plain = page.entries.filter { $0.target.scheme == "http" }.map { "\($0.code) points at \($0.target.absoluteString)" }
                if let detail = summarized(plain) { findings.append(Finding("hreflang.protocol", url: page.url, detail: detail)) }
            }

            // Versions that are not there to be shown.
            var seen = Set<String>()
            var dead: [String] = []
            for entry in page.entries {
                let key = Auditor.key(entry.target)
                guard key != page.key, entry.target.scheme == page.url.scheme, seen.insert(key).inserted,
                      let problem = state(key)?.problem else { continue }
                dead.append("the \(entry.code) version at \(entry.target.absoluteString) \(problem)")
            }
            if let detail = summarized(dead) { findings.append(Finding("hreflang.target", url: page.url, detail: detail)) }
        }
        return findings
    }
}
