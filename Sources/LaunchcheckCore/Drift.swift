import Foundation

/// One difference between two checks of the same site.
public struct Change: Equatable, Identifiable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case critical, warning, info
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public let level: Level
    public let url: String
    public let summary: String
    public let detail: String?

    public var id: String { "\(url)|\(summary)" }
}

public struct Comparison: Equatable, Sendable {
    public var since: Date
    public var scoreBefore: Int
    public var scoreAfter: Int
    /// Checks that failed last time and pass now.
    public var fixed: [Check]
    /// Checks that passed (or did not fail) last time and fail now.
    public var introduced: [Check]
    public var changes: [Change]
    public var pagesAdded: [String]
    public var pagesRemoved: [String]

    public var isEmpty: Bool {
        fixed.isEmpty && introduced.isEmpty && changes.isEmpty && pagesAdded.isEmpty && pagesRemoved.isEmpty
    }
}

public enum Drift {
    /// What changed between an earlier report and a later one, page by page and check by check.
    public static func compare(_ old: Report, _ new: Report) -> Comparison {
        let failedBefore = Set(old.findings.map(\.check))
        let failedNow = Set(new.findings.map(\.check))
        let before = Dictionary(old.pages.map { (key($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.pages.map { (key($0.url), $0) }, uniquingKeysWith: { first, _ in first })

        var changes: [Change] = []
        for page in new.pages {
            guard let was = before[key(page.url)] else { continue }
            func add(_ level: Change.Level, _ summary: String, _ detail: String? = nil) {
                changes.append(Change(level: level, url: page.url, summary: summary, detail: detail))
            }

            if (200..<300).contains(was.status), page.status >= 400 || page.status == 0 {
                add(.critical, "Stopped loading", "was \(was.status), now \(page.status == 0 ? "no answer" : String(page.status))")
                continue
            }
            if was.indexable, !page.indexable { add(.critical, "Noindex added") }
            if !was.schemaTypes.isEmpty, page.schemaTypes.isEmpty { add(.critical, "Structured data removed", was.schemaTypes.joined(separator: ", ")) }
            if let old = was.canonical, !old.isEmpty {
                if (page.canonical ?? "").isEmpty {
                    add(.critical, "Canonical removed", "was \(old)")
                } else if let now = page.canonical, key(now) != key(old) {
                    add(.critical, "Canonical changed", "\(old) → \(now)")
                }
            }
            if !was.h1.isEmpty, page.h1.isEmpty {
                add(.critical, "H1 removed", "was “\(was.h1[0])”")
            } else if let old = was.h1.first, let now = page.h1.first, old != now {
                add(similarity(old, now) < 0.5 ? .critical : .info, "H1 changed", "“\(old)” → “\(now)”")
            }
            let oldTitle = normalized(was.title), newTitle = normalized(page.title)
            if !oldTitle.isEmpty, newTitle.isEmpty {
                add(.critical, "Title removed", "was “\(oldTitle)”")
            } else if oldTitle != newTitle {
                add(.warning, "Title changed", "“\(oldTitle)” → “\(newTitle)”")
            }
            if normalized(was.description) != normalized(page.description) { add(.warning, "Meta description changed") }
            if was.hasShareTags, !page.hasShareTags { add(.warning, "Share tags removed") }
            if !was.schemaTypes.isEmpty, !page.schemaTypes.isEmpty, was.schemaTypes != page.schemaTypes {
                add(.warning, "Structured data changed", "\(was.schemaTypes.joined(separator: ", ")) → \(page.schemaTypes.joined(separator: ", "))")
            }
            if was.schemaTypes.isEmpty, !page.schemaTypes.isEmpty { add(.info, "Structured data added", page.schemaTypes.joined(separator: ", ")) }
            if was.h2 != page.h2 { add(.info, "H2 headings changed", "\(was.h2.count) before, \(page.h2.count) now") }
        }

        // Stable order: most serious first, then by address.
        let sorted = changes.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level < b.element.level : a.offset < b.offset
        }.map(\.element)

        return Comparison(
            since: old.date,
            scoreBefore: old.score,
            scoreAfter: new.score,
            fixed: Check.all.filter { failedBefore.contains($0.id) && !failedNow.contains($0.id) && new.passed.contains($0.id) },
            introduced: Check.all.filter { failedNow.contains($0.id) && !failedBefore.contains($0.id) },
            changes: sorted,
            pagesAdded: new.pages.map(\.url).filter { before[key($0)] == nil },
            pagesRemoved: old.pages.map(\.url).filter { after[key($0)] == nil })
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func key(_ address: String) -> String {
        URL(string: address).map(Auditor.key) ?? address
    }

    /// 1 for identical strings, 0 for nothing in common (edit distance over the longer length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

/// Keeps the most recent reports for each site, so a new check can be compared with the last one.
public final class History: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default
    private let keep = 12

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Launchcheck/History", isDirectory: true)
    }

    public init(directory: URL = History.defaultDirectory) {
        self.directory = directory
    }

    func folder(for host: String) -> URL {
        let safe = host.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe), isDirectory: true)
    }

    /// Reports for a site, newest first.
    public func reports(for host: String) -> [Report] {
        let files = (try? fm.contentsOfDirectory(at: folder(for: host), includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Report.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    public func latest(for host: String) -> Report? {
        reports(for: host).first
    }

    /// Every site that has been checked, most recent first, with its latest report.
    public func sites() -> [Report] {
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { latest(for: $0.lastPathComponent) }.sorted { $0.date > $1.date }
    }

    public func save(_ report: Report) {
        let folder = folder(for: report.host)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        let name = String(Int(report.date.timeIntervalSince1970 * 1000))
        try? data.write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)

        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in files.dropFirst(keep) { try? fm.removeItem(at: stale) }
    }

    public func forget(_ host: String) {
        try? fm.removeItem(at: folder(for: host))
    }

    /// Removes one kept report, and the site's folder with it when that was the last one.
    public func remove(_ report: Report) {
        let folder = folder(for: report.host)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        var left = files.count
        for file in files {
            guard let kept = try? decoder.decode(Report.self, from: Data(contentsOf: file)),
                  abs(kept.date.timeIntervalSince(report.date)) < 1 else { continue }
            try? fm.removeItem(at: file)
            left -= 1
        }
        if left <= 0 { try? fm.removeItem(at: folder) }
    }

    /// Removes every kept report of every site.
    public func forgetAll() {
        for folder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: folder)
        }
    }
}
