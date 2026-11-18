import Foundation

public enum ReportFormat {
    /// Plain text for a terminal.
    public static func text(_ report: Report) -> String {
        var lines: [String] = []
        lines.append(report.site)
        lines.append(report.verdict)
        lines.append("Score \(report.score) of 100 (\(report.grade)) · \(summary(report))")
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
