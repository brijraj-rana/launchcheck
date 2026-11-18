import Foundation
import LaunchcheckCore

let usage = """
Usage: launchcheck <site> [options]
       launchcheck migrate <old site> <new site> [options]

Check a site:
  --max-pages <n>   Stop after this many pages (default 200)
  --no-external     Skip links to other sites
  --baseline <file> Compare with an earlier report saved with --json, and say what changed
  --markdown        Print the report as Markdown
  --json            Print the report as JSON
  --checks          List every check as JSON, with how to fix it, and exit
  -h, --help        Show this help

Exits with 1 when something must be fixed before launch, 2 when the site could not be checked.

Move a site: compare the old site with the new one and write the redirects.
  --old-list <file> Read the old addresses from a file: a sitemap, or one address or path per line.
                    For when the old site is already offline.
  --format <name>   webflow    CSV for Webflow's 301 redirect import
                    text       old -> new, one per line (the default)
                    redirects  a _redirects file for Netlify or Cloudflare Pages
                    json       everything, including what needs no redirect
  --confident-only  Leave out the matches that need checking
  --max-pages <n>   Read at most this many pages of each site (default 200)

The redirects go to standard output and the summary to standard error, so the output can be saved as a file.
Exits with 1 when an old page is left with nowhere to go, 2 when a site could not be read.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

let showProgress = isatty(STDERR_FILENO) != 0
/// Writes the step in hand over the last one, on a terminal only.
func reporter(_ show: Bool) -> @Sendable (AuditProgress) -> Void {
    { progress in
        guard show else { return }
        let count = progress.total > 0 ? " \(progress.done)/\(progress.total)" : ""
        FileHandle.standardError.write(Data("\r\u{1B}[K\(progress.phase)\(count)".utf8))
    }
}
func clearProgress() {
    if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var options = Options()

// MARK: migrate

if arguments.first == "migrate" {
    arguments.removeFirst()
    var sites: [String] = []
    var format = MigrationFormat.text
    var confidentOnly = false
    var list: String?

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--max-pages":
            guard let value = arguments.first.flatMap(Int.init), value > 0 else { fail("--max-pages needs a number") }
            arguments.removeFirst()
            options.maxPages = value
        case "--old-list":
            guard let path = arguments.first, let data = FileManager.default.contents(atPath: path) else { fail("--old-list needs a file that can be read") }
            arguments.removeFirst()
            list = String(decoding: data, as: UTF8.self)
        case "--format":
            guard let name = arguments.first, let chosen = MigrationFormat(rawValue: name) else {
                fail("--format needs one of: \(MigrationFormat.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            arguments.removeFirst()
            format = chosen
        case "--confident-only":
            confidentOnly = true
        default:
            if argument.hasPrefix("-") || sites.count == 2 { fail("Unexpected argument: \(argument)\n\n\(usage)") }
            sites.append(argument)
        }
    }
    guard sites.count == 2 else { fail("migrate needs two addresses: the old site, then the new one.\n\n\(usage)") }

    do {
        let map = try await Migrator(options: options).run(old: sites[0], new: sites[1], oldList: list, progress: reporter(showProgress))
        clearProgress()
        print(format.render(map, confidentOnly: confidentOnly), terminator: "")

        var summary = ["\(map.oldHost) to \(map.newHost)", map.verdict]
        if !map.breakdown.isEmpty { summary.append(map.breakdown.prefix(1).uppercased() + map.breakdown.dropFirst() + ".") }
        let fine = map.count(.fine)
        if fine > 0, fine < map.rows.count { summary.append("Nothing to do for \(fine) of \(map.rows.count) old pages: the address is the same or already redirects.") }
        if map.oldPagesFound > map.rows.count { summary.append("Only the first \(map.rows.count) of \(map.oldPagesFound) old pages were read. Raise --max-pages to read them all.") }
        let unsure = map.count(.uncertain)
        if unsure > 0, !confidentOnly, format != .json {
            summary.append("The \(unsure) to check \(format == .webflow ? "are the last rows of the file" : "are marked"). Use --confident-only to leave them out.")
        }
        for row in map.rows where row.standing == .stranded { summary.append("  no match: \(row.path)") }
        if !map.unclaimed.isEmpty { summary.append("\(map.unclaimed.count) new \(map.unclaimed.count == 1 ? "page has" : "pages have") no old address leading to \(map.unclaimed.count == 1 ? "it" : "them").") }
        FileHandle.standardError.write(Data((summary.joined(separator: "\n") + "\n").utf8))
        exit(map.stranded > 0 ? 1 : 0)
    } catch {
        clearProgress()
        fail(error.localizedDescription)
    }
}

// MARK: check

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
        guard let value = arguments.first.flatMap(Int.init), value > 0 else { fail("--max-pages needs a number") }
        arguments.removeFirst()
        options.maxPages = value
    case "--baseline":
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let path = arguments.first, let data = FileManager.default.contents(atPath: path),
              let earlier = try? decoder.decode(Report.self, from: data) else {
            fail("--baseline needs a report saved with --json")
        }
        arguments.removeFirst()
        baseline = earlier
    case "--checks":
        let list = Check.all.map { check -> [String: String] in
            var entry = ["id": check.id, "severity": "\(check.severity)", "area": check.category.title, "title": check.title, "passed": check.passed, "why": check.why]
            entry["fix"] = check.fix
            entry["webflow"] = check.webflow
            return entry
        }
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
        if argument.hasPrefix("-") || site != nil { fail("Unexpected argument: \(argument)\n\n\(usage)") }
        site = argument
    }
}

guard let site else {
    print(usage)
    exit(2)
}

let code: Int32
do {
    let result = try await Auditor(options: options).run(site, progress: reporter(showProgress))
    clearProgress()
    switch format {
    case "markdown": print(ReportFormat.markdown(result), terminator: "")
    case "json": print(ReportFormat.json(result))
    default: print(ReportFormat.text(result), terminator: "")
    }
    if let baseline, format != "json" {
        let comparison = Drift.compare(baseline, result)
        var lines = ["", "SINCE THE BASELINE", "  Score \(comparison.scoreBefore) → \(comparison.scoreAfter)"]
        for check in comparison.introduced { lines.append("  ✗ New: \(check.title)") }
        for check in comparison.fixed { lines.append("  ✓ Fixed: \(check.passed)") }
        for change in comparison.changes {
            lines.append("  · \(change.summary): \(ReportFormat.short(change.url, site: result.site))\(change.detail.map { "  \($0)" } ?? "")")
        }
        if comparison.isEmpty { lines.append("  Nothing changed.") }
        print(lines.joined(separator: "\n"))
    }
    code = result.count(.error) > 0 ? 1 : 0
} catch {
    clearProgress()
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    code = 2
}
exit(code)
