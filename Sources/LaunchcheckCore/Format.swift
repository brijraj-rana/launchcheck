import Foundation

public enum ReportFormat {
    /// Plain text for a terminal.
    public static func text(_ report: Report) -> String {
        var lines: [String] = []
        lines.append(report.site)
        lines.append(report.verdict)
        lines.append("Score \(report.score) of 100 (\(report.grade)) · \(summary(report))")
        if let note = report.scopeNote { lines.append(note) }
        if let page = report.page { lines.append("Page: \(page)") }
        lines.append("")
        for entry in report.categoryScores {
            guard let score = entry.score else { continue }
            let bar = String(repeating: "█", count: score / 5) + String(repeating: "░", count: 20 - score / 5)
            lines.append("  \(entry.category.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(bar) \(score)")
        }

        for severity in Severity.allCases {
            let groups = report.groups.filter { $0.check.severity == severity }
            guard !groups.isEmpty else { continue }
            lines.append("")
            lines.append(severity.label.uppercased())
            for group in groups {
                lines.append("")
                lines.append("  \(mark(severity)) \(group.check.title) (\(group.findings.count))")
                lines.append("    \(group.check.why)")
                for finding in group.findings.prefix(12) { lines.append("    - \(line(finding, site: report.site))") }
                if group.findings.count > 12 { lines.append("    - and \(group.findings.count - 12) more") }
            }
        }

        let schema = structuredData(report)
        if !schema.isEmpty {
            lines.append("")
            lines.append("STRUCTURED DATA")
            lines += schema.map { "  \($0)" }
        }

        let passed = report.passedChecks
        if !passed.isEmpty {
            lines.append("")
            lines.append("PASSED")
            for check in passed { lines.append("  ✓ \(check.passed)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Markdown, for pasting into a ticket or sending to a client.
    public static func markdown(_ report: Report) -> String {
        var lines: [String] = []
        lines.append("# Launch check: \(report.site)")
        lines.append("")
        lines.append("**\(report.verdict).** Score \(report.score) of 100 (\(report.grade)). \(summary(report))")
        if let note = report.scopeNote { lines += ["", "_\(note)_"] }
        if let page = report.page { lines += ["", "Page: \(page)"] }
        lines.append("")
        lines.append("| Area | Score |")
        lines.append("|---|---|")
        for entry in report.categoryScores {
            if let score = entry.score { lines.append("| \(entry.category.title) | \(score) |") }
        }

        for severity in Severity.allCases {
            let groups = report.groups.filter { $0.check.severity == severity }
            guard !groups.isEmpty else { continue }
            lines.append("")
            lines.append("## \(severity.label)")
            for group in groups {
                lines.append("")
                lines.append("### \(group.check.title) (\(group.findings.count))")
                lines.append("")
                lines.append(group.check.why)
                lines.append("")
                let fix = fixLines(for: group.check, webflow: report.isWebflow)
                if !fix.isEmpty { lines += fix + [""] }
                for finding in group.findings.prefix(50) { lines.append("- \(line(finding, site: report.site))") }
                if group.findings.count > 50 { lines.append("- and \(group.findings.count - 50) more") }
            }
        }

        let schema = structuredData(report)
        if !schema.isEmpty {
            lines.append("")
            lines.append("## Structured data")
            lines.append("")
            lines += schema.map { "- \($0)" }
        }

        let passed = report.passedChecks
        if !passed.isEmpty {
            lines.append("")
            lines.append("## Passed")
            lines.append("")
            for check in passed { lines.append("- \(check.passed)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(_ report: Report) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The structured data found, a line per type, when that area was checked and there is any. For one page, each
    /// item is listed with what it is missing; for a site, each type with the number of pages it is on.
    public static func structuredData(_ report: Report) -> [String] {
        guard report.covers(.structured) else { return [] }
        var lines: [String] = []
        if report.page != nil, let page = report.pages.first, let blocks = page.schema {
            for block in blocks {
                if let error = block.error { lines.append("Block \(block.index): \(error)") }
                for item in block.items {
                    var line = "Block \(block.index): \(item.name), \(item.fields.count) \(item.fields.count == 1 ? "property" : "properties")"
                    let inside = nested(in: item)
                    if !inside.isEmpty { line += ", with \(inside.joined(separator: ", ")) inside" }
                    if let result = item.richResult { line += ". Can earn: \(result)" }
                    lines.append(line)
                    for missing in item.required { lines.append("  required: \(missing)") }
                    for missing in item.recommended { lines.append("  recommended: \(missing)") }
                    for note in item.notes { lines.append("  note: \(note)") }
                }
            }
            if let markup = page.markup, !markup.isEmpty { lines.append("Also found, not checked: \(markup.joined(separator: " and "))") }
        } else {
            for entry in report.schemaTypesInUse {
                lines.append("\(entry.type): \(entry.pages == 1 ? "1 page" : "\(entry.pages) pages")")
            }
            let unreadable = report.pagesWithUnreadableSchema.count
            if unreadable > 0 { lines.append("\(unreadable == 1 ? "1 page has" : "\(unreadable) pages have") a block that cannot be read") }
        }
        return lines
    }

    /// The types nested inside an item, each once, in the order met.
    static func nested(in item: SchemaItem) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        func visit(_ node: SchemaItem) {
            for child in node.children {
                if seen.insert(child.name).inserted { names.append(child.name) }
                visit(child)
            }
        }
        visit(item)
        return names
    }

    /// How to fix a check, as lines for a ticket. The Webflow line is only for sites built with Webflow.
    public static func fixLines(for check: Check, webflow: Bool) -> [String] {
        var lines: [String] = []
        if let fix = check.fix { lines.append("How to fix: \(fix)") }
        if webflow, let place = check.webflow { lines.append("In Webflow: \(place)") }
        return lines
    }

    public static func summary(_ report: Report) -> String {
        let pages = report.pagesFound > report.pagesChecked
            ? "\(report.pagesChecked) of \(report.pagesFound) pages"
            : (report.pagesChecked == 1 ? "1 page" : "\(report.pagesChecked) pages")
        let links = report.linksChecked == 1 ? "1 link" : "\(report.linksChecked) links"
        return "\(pages) and \(links) checked in \(String(format: "%.1f", report.seconds))s"
    }

    /// A finding as one line: the page (shortened to its path on this site), then the detail.
    public static func line(_ finding: Finding, site: String) -> String {
        let place = finding.url.map { short($0, site: site) }
        switch (place, finding.detail) {
        case let (place?, detail?): return "\(place)  \(detail)"
        case let (place?, nil): return place
        case let (nil, detail?): return detail
        default: return ""
        }
    }

    public static func short(_ url: String, site: String) -> String {
        let root = site.hasSuffix("/") ? String(site.dropLast()) : site
        guard url.hasPrefix(root) else { return url }
        let path = String(url.dropFirst(root.count))
        return path.isEmpty ? "/" : path
    }

    private static func mark(_ severity: Severity) -> String {
        switch severity {
        case .error: return "✗"
        case .warning: return "!"
        case .notice: return "·"
        }
    }
}
