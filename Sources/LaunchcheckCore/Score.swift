import Foundation

public struct CategoryScore: Identifiable, Equatable, Sendable {
    public let category: Category
    /// 0 to 100, or nil when none of the category's checks applied to this site.
    public let score: Int?
    public let failed: Int
    public let passed: Int

    public var id: String { category.rawValue }
}

extension Report {
    /// Checks that describe the site as a whole, so they count in full however many pages there are.
    private static let siteWide: Set<String> = [
        "robots.blocks-all", "robots.error", "robots.missing", "sitemap.missing", "sitemap.too-big", "sitemap.undeclared", "sitemap.lastmod",
        "https.redirect", "security.hsts", "security.headers", "host.duplicate", "notfound.soft", "perf.uncompressed", "schema.missing",
        "ai.search-blocked", "ai.llms-invalid", "ai.llms-missing", "favicon.missing",
    ]

    /// A score per area: 100, less a deduction for each failed check. A failed check costs more the more pages it touches.
    public var categoryScores: [CategoryScore] {
        let failedGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.check.id, $0) })
        let passedIDs = Set(passed)

        return Category.allCases.map { category in
            var lost = 0.0
            var failed = 0
            var passedCount = 0
            for check in Check.all where check.category == category {
                if let group = failedGroups[check.id] {
                    lost += check.severity.deduction * spread(of: group)
                    failed += 1
                } else if passedIDs.contains(check.id) {
                    passedCount += 1
                }
            }
            let score = failed + passedCount > 0 ? max(0, Int((100 - lost).rounded())) : nil
            return CategoryScore(category: category, score: score, failed: failed, passed: passedCount)
        }
    }

    /// The overall score: each area weighted by how much it matters, leaving out areas that did not apply,
    /// then marked down again for anything that must be fixed before launch.
    public var score: Int {
        var weighted = 0.0
        var weights = 0.0
        for entry in categoryScores {
            guard let score = entry.score else { continue }
            weighted += Double(score) * entry.category.weight
            weights += entry.category.weight
        }
        guard weights > 0 else { return 100 }
        let blockers = groups.filter { $0.check.severity == .error }.reduce(0.0) { $0 + 6 * spread(of: $1) }
        return max(0, Int((weighted / weights - min(30, blockers)).rounded()))
    }

    public var grade: String {
        if count(.error) > 0 { return "Not ready" }
        switch score {
        case 90...: return "Excellent"
        case 75..<90: return "Good"
        case 55..<75: return "Needs work"
        default: return "Poor"
        }
    }

    /// A problem on one page in fifty costs less than the same problem everywhere; a site-wide problem costs in full.
    private func spread(of group: Group) -> Double {
        if Self.siteWide.contains(group.check.id) { return 1 }
        let pages = Set(group.findings.compactMap(\.url)).count
        guard pages > 0, pagesChecked > 1 else { return 1 }
        return 0.4 + 0.6 * min(1, Double(pages) / Double(pagesChecked))
    }
}
