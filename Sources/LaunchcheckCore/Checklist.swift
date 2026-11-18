import Foundation

/// The issues of one site that its owner has dealt with, or decided to live with. Ticking one does not change the
/// score: the check still fails until the site is fixed. It only keeps the list honest about what is left to do.
public struct Checklist: Codable, Equatable, Sendable {
    /// Check IDs, each with the moment it was ticked.
    public var handled: [String: Date]

    public init(handled: [String: Date] = [:]) {
        self.handled = handled
    }

    public var isEmpty: Bool { handled.isEmpty }

    public func isHandled(_ check: String) -> Bool {
        handled[check] != nil
    }

    public mutating func set(_ check: String, handled done: Bool, at date: Date = Date()) {
        handled[check] = done ? (handled[check] ?? date) : nil
    }

    public mutating func toggle(_ check: String, at date: Date = Date()) {
        set(check, handled: !isHandled(check), at: date)
    }

    /// The checklist to carry past a new check of the site. A tick is dropped once the check shows the issue gone,
    /// so if the problem ever comes back it comes back unticked. A tick on a check that did not run this time is kept.
    public func carried(past report: Report) -> Checklist {
        let failing = Set(report.findings.map(\.check))
        let passed = Set(report.passed)
        return Checklist(handled: handled.filter { id, _ in
            failing.contains(id) || (!passed.contains(id) && Check.named(id) != nil)
        })
    }

    /// The issues of a report that are ticked.
    public func handled(in report: Report) -> Set<String> {
        Set(report.groups.map(\.id).filter(isHandled))
    }

    /// "3 of 9": how many of a report's issues are ticked.
    public func progress(in report: Report) -> (handled: Int, total: Int) {
        (handled(in: report).count, report.groups.count)
    }

    /// A report's issues split in two, each half in the report's own order: still to do, then handled.
    public func split(_ groups: [Report.Group]) -> (open: [Report.Group], handled: [Report.Group]) {
        (groups.filter { !isHandled($0.id) }, groups.filter { isHandled($0.id) })
    }
}

extension History {
    /// Kept beside the site's reports, under a name the report reader does not pick up.
    private func checklistFile(for host: String) -> URL {
        folder(for: host).appendingPathComponent("handled.checklist")
    }

    /// What has been ticked for a site. Empty for a site kept before there was a checklist, or one never ticked.
    public func checklist(for host: String) -> Checklist {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: checklistFile(for: host)),
              let kept = try? decoder.decode(Checklist.self, from: data) else { return Checklist() }
        return kept
    }

    public func save(_ checklist: Checklist, for host: String) {
        let file = checklistFile(for: host)
        guard !checklist.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // Only ever beside reports: a checklist for a site with nothing kept would leave a folder with no report in it.
        guard FileManager.default.fileExists(atPath: folder(for: host).path) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(checklist) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
