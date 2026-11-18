import Foundation
import LaunchcheckCore

let usage = """
Usage: launchcheck <site> [options]

  --max-pages <n>   Stop after this many pages (default 200)
  --no-external     Skip links to other sites
  --baseline <file> Compare with an earlier report saved with --json, and say what changed
  --markdown        Print the report as Markdown
  --json            Print the report as JSON
  --checks          List every check as JSON and exit
  -h, --help        Show this help

Exits with 1 when something must be fixed before launch, 2 when the site could not be checked.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var options = Options()
var format = "text"
var site: String?
var baseline: Report?

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--max-pages":
        guard let value = arguments.first.flatMap(Int.init), value > 0 else {
            FileHandle.standardError.write(Data("--max-pages needs a number\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        options.maxPages = value
    case "--baseline":
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let path = arguments.first, let data = FileManager.default.contents(atPath: path),
              let earlier = try? decoder.decode(Report.self, from: data) else {
            FileHandle.standardError.write(Data("--baseline needs a report saved with --json\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        baseline = earlier
    case "--checks":
        let list = Check.all.map { ["id": $0.id, "severity": "\($0.severity)", "area": $0.category.title, "title": $0.title, "passed": $0.passed, "why": $0.why] }
        let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    case "--no-external":
        options.checkExternalLinks = false
    case "--markdown":
        format = "markdown"
    case "--json":
        format = "json"
    default:
        if argument.hasPrefix("-") || site != nil {
            FileHandle.standardError.write(Data("Unexpected argument: \(argument)\n\n\(usage)\n".utf8))
            exit(2)
        }
        site = argument
    }
}

guard let site else {
    print(usage)
    exit(2)
}

let showProgress = isatty(STDERR_FILENO) != 0
let code: Int32
do {
    let report = try await Auditor(options: options).run(site) { progress in
        guard showProgress else { return }
        let count = progress.total > 0 ? " \(progress.done)/\(progress.total)" : ""
        FileHandle.standardError.write(Data("\r\u{1B}[K\(progress.phase)\(count)".utf8))
    }
    if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    switch format {
    case "markdown": print(ReportFormat.markdown(report), terminator: "")
    case "json": print(ReportFormat.json(report))
    default: print(ReportFormat.text(report), terminator: "")
    }
    if let baseline, format != "json" {
        let comparison = Drift.compare(baseline, report)
        var lines = ["", "SINCE THE BASELINE", "  Score \(comparison.scoreBefore) → \(comparison.scoreAfter)"]
        for check in comparison.introduced { lines.append("  ✗ New: \(check.title)") }
        for check in comparison.fixed { lines.append("  ✓ Fixed: \(check.passed)") }
        for change in comparison.changes {
            lines.append("  · \(change.summary): \(ReportFormat.short(change.url, site: report.site))\(change.detail.map { "  \($0)" } ?? "")")
        }
        if comparison.isEmpty { lines.append("  Nothing changed.") }
        print(lines.joined(separator: "\n"))
    }
    code = report.count(.error) > 0 ? 1 : 0
} catch {
    if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    code = 2
}
exit(code)
