import AppKit
import LaunchcheckCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AuditModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case issues = "Issues"
        case pages = "Pages"
        case changes = "Changes"
    }

    @Published var address = ""
    @Published var phase: Phase = .idle
    @Published var progress = AuditProgress(phase: "Starting")
    /// Steps of the current run that have finished, in order.
    @Published var finishedSteps: [String] = []
    @Published var report: Report?
    @Published var comparison: Comparison?
    @Published var sites: [Report] = []

    @Published var tab: Tab = .overview
    enum Grouping: Hashable {
        case severity, area
    }

    @Published var grouping: Grouping = .severity
    @Published var search = ""
    @Published var pageSearch = ""
    @Published var selectedPage: String?
    @Published var selectedIssue: String?
    /// Which checks the issue list shows.
    enum Scope: Hashable {
        case all, error, warning, notice, passed
    }

    /// The order of the page list, and so the figure each row shows.
    enum PageSort: String, CaseIterable {
        case issues = "Most to fix"
        case slowest = "Slowest"
        case thinnest = "Fewest words"
        case deepest = "Most clicks from home"
        case path = "Address"
    }

    @Published var scope: Scope = .all
    @Published var pageSort: PageSort = .issues
    /// Scores of the checks kept for this site, oldest first, ending with the one on screen.
    @Published var trail: [Int] = []
    /// Briefly true after something was copied, so the button can say so.
    @Published var copied = false
    /// The checks kept for the site on screen, newest first.
    @Published var checks: [Report] = []
    /// True from the moment a fresh check lands until the overview has played its arrival.
    @Published var arrived = false
    /// Counts failed checks, so the address bar can shake once for each.
    @Published var failures = 0
    /// A deletion waiting for the user to confirm it.
    @Published var removal: Removal?

    enum Removal: Identifiable, Equatable {
        case site(String)
        case everything

        var id: String {
            switch self {
            case .site(let host): return host
            case .everything: return "*"
            }
        }
    }

    @Published var maxPages: Int {
        didSet { UserDefaults.standard.set(maxPages, forKey: "maxPages") }
    }
    @Published var checkExternalLinks: Bool {
        didSet { UserDefaults.standard.set(checkExternalLinks, forKey: "checkExternalLinks") }
    }
    @Published var checkImages: Bool {
        didSet { UserDefaults.standard.set(checkImages, forKey: "checkImages") }
    }

    let history: History
    private var task: Task<Void, Never>?
    private var run = 0

    init(history: History = History(), loadSites: Bool = true) {
        self.history = history
        let defaults = UserDefaults.standard
        maxPages = defaults.object(forKey: "maxPages") as? Int ?? 200
        checkExternalLinks = defaults.object(forKey: "checkExternalLinks") as? Bool ?? true
        checkImages = defaults.object(forKey: "checkImages") as? Bool ?? true
        if loadSites { sites = history.sites() }
    }

    var isRunning: Bool { phase == .running }

    // MARK: Running a check

    func start() {
        let site = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else { return }
        task?.cancel()
        run += 1
        let current = run
        var options = Options()
        options.maxPages = maxPages
        options.checkExternalLinks = checkExternalLinks
        options.checkImages = checkImages
        progress = AuditProgress(phase: "Starting")
        finishedSteps = []
        phase = .running

        let update: @Sendable (AuditProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                // A late update from a run that was stopped or replaced must not repaint the screen.
                guard let self, self.run == current, self.isRunning else { return }
                if progress.phase != self.progress.phase, self.progress.phase != "Starting" {
                    self.finishedSteps.append(Self.past(self.progress))
                }
                // Updates arrive from several requests at once; never let the bar run backwards.
                if progress.phase != self.progress.phase || progress.done >= self.progress.done { self.progress = progress }
            }
        }
        task = Task { [weak self] in
            do {
                let report = try await Auditor(options: options).run(site, progress: update)
                guard let self, self.run == current, !Task.isCancelled else { return }
                self.finish(report)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.run == current else { return }
                self.phase = .failed(error.localizedDescription)
                self.failures += 1
            }
        }
    }

    private static func past(_ step: AuditProgress) -> String {
        step.total > 0 ? "\(step.phase) (\(step.total))" : step.phase
    }

    private func finish(_ report: Report) {
        let previous = history.latest(for: report.host)
        history.save(report)
        sites = history.sites()
        arrived = true
        present(report, comparedWith: previous)
    }

    func stop() {
        task?.cancel()
        run += 1
        phase = report == nil ? .idle : .done
    }

    // MARK: Showing a report

    /// Opens an earlier report from the sidebar, compared with the one before it.
    func show(_ report: Report) {
        guard !isRunning else { return }
        let earlier = history.reports(for: report.host).first { $0.date < report.date }
        address = report.host
        present(report, comparedWith: earlier)
    }

    func present(_ report: Report, comparedWith previous: Report?, keepingTab: Bool = false) {
        let tabBefore = tab
        defer { if keepingTab { tab = tabBefore } }
        self.report = report
        comparison = previous.map { Drift.compare($0, report) }
        checks = history.reports(for: report.host)
        trail = Array(history.reports(for: report.host).filter { $0.date <= report.date }.sorted { $0.date < $1.date }.map(\.score).suffix(12))
        if trail.isEmpty { trail = (previous.map { [$0.score] } ?? []) + [report.score] }
        tab = .overview
        grouping = .severity
        search = ""
        pageSearch = ""
        scope = .all
        pageSort = .issues
        // The most serious problem is already open; the rest is one arrow key away.
        selectedIssue = report.groups.first?.id
        selectedPage = sortedPages(of: report).first?.url
        phase = .done
    }

    // MARK: Deleting

    /// Deletes every kept check of one site.
    func forget(_ host: String) {
        history.forget(host)
        sites = history.sites()
        if report?.host == host, !isRunning { clear() }
    }

    func forgetEverything() {
        history.forgetAll()
        sites = []
        if !isRunning { clear() }
    }

    /// Deletes one kept check. If it was the one on screen, the check before it takes its place.
    func delete(_ check: Report) {
        history.remove(check)
        sites = history.sites()
        guard let shown = report, shown.host == check.host, !isRunning else { return }
        let left = history.reports(for: check.host)
        if abs(shown.date.timeIntervalSince(check.date)) < 1 {
            if let next = left.first {
                present(next, comparedWith: left.dropFirst().first, keepingTab: true)
            } else {
                clear()
            }
        } else {
            present(shown, comparedWith: left.first { $0.date < shown.date }, keepingTab: true)
        }
    }

    func confirmRemoval() {
        switch removal {
        case .site(let host): forget(host)
        case .everything: forgetEverything()
        case nil: break
        }
        removal = nil
    }

    private func clear() {
        report = nil
        comparison = nil
        checks = []
        trail = []
        address = ""
        phase = .idle
    }

    func reveal(_ check: Check) {
        search = ""
        scope = .all
        selectedIssue = check.id
        tab = .issues
    }

    func filter(by category: LaunchcheckCore.Category) {
        search = ""
        scope = .all
        grouping = .area
        if let first = report?.groups.first(where: { $0.check.category == category }) { selectedIssue = first.id }
        tab = .issues
    }

    func showPage(_ address: String?) {
        guard let address, report?.pages.contains(where: { $0.url == address }) == true else { return }
        pageSearch = ""
        selectedPage = address
        tab = .pages
    }

    var visibleGroups: [Report.Group] {
        guard let report else { return [] }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let scoped = report.groups.filter { group in
            switch scope {
            case .all: return true
            case .error: return group.check.severity == .error
            case .warning: return group.check.severity == .warning
            case .notice: return group.check.severity == .notice
            case .passed: return false
            }
        }
        guard !needle.isEmpty else { return scoped }
        return scoped.filter { group in
            group.check.title.lowercased().contains(needle)
                || group.check.category.title.lowercased().contains(needle)
                || group.findings.contains { ($0.url ?? "").lowercased().contains(needle) || ($0.detail ?? "").lowercased().contains(needle) }
        }
    }

    /// The issues in the order the list shows them, so the arrow keys follow what is on screen.
    var orderedGroups: [Report.Group] {
        let groups = visibleGroups
        guard grouping == .area else { return groups }
        return LaunchcheckCore.Category.allCases.flatMap { category in groups.filter { $0.check.category == category } }
    }

    /// Moves the selection in whichever list is showing. Driven by the arrow keys.
    func move(by step: Int) {
        guard phase == .done || phase == .idle, report != nil else { return }
        switch tab {
        case .issues:
            let ids = orderedGroups.map(\.id)
            guard !ids.isEmpty else { return }
            let index = selectedIssue.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
            selectedIssue = ids[min(ids.count - 1, max(0, index + step))]
        case .pages:
            let urls = visiblePages.map(\.url)
            guard !urls.isEmpty else { return }
            let index = selectedPage.flatMap { urls.firstIndex(of: $0) } ?? (step > 0 ? -1 : urls.count)
            selectedPage = urls[min(urls.count - 1, max(0, index + step))]
        default:
            break
        }
    }

    /// Pages in the chosen order; by default, the ones with the most to fix first.
    func sortedPages(of report: Report) -> [PageSummary] {
        let counts = Dictionary(report.findings.compactMap(\.url).map { ($0, 1) }, uniquingKeysWith: +)
        func weight(_ page: PageSummary) -> Double {
            switch pageSort {
            case .issues: return Double(counts[page.url] ?? 0)
            case .slowest: return Double(page.milliseconds)
            case .thinnest: return -Double(page.words)
            case .deepest: return Double(page.depth ?? -1)
            case .path: return 0
            }
        }
        return report.pages.enumerated().sorted { a, b in
            if pageSort == .path { return a.element.url < b.element.url }
            let x = weight(a.element), y = weight(b.element)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// Where the selection sits in the list on screen, for "3 of 20".
    var position: (index: Int, count: Int)? {
        switch tab {
        case .issues:
            let ids = orderedGroups.map(\.id)
            guard let index = selectedIssue.flatMap({ ids.firstIndex(of: $0) }) else { return nil }
            return (index + 1, ids.count)
        case .pages:
            let urls = visiblePages.map(\.url)
            guard let index = selectedPage.flatMap({ urls.firstIndex(of: $0) }) else { return nil }
            return (index + 1, urls.count)
        default:
            return nil
        }
    }

    var visiblePages: [PageSummary] {
        guard let report else { return [] }
        let needle = pageSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let pages = sortedPages(of: report)
        guard !needle.isEmpty else { return pages }
        return pages.filter { $0.url.lowercased().contains(needle) || ($0.title ?? "").lowercased().contains(needle) }
    }

    // MARK: Getting it out

    func copyMarkdown() {
        guard let report else { return }
        copy(ReportFormat.markdown(report))
    }

    /// One issue as a to-do: what is wrong, why it matters, when it is done, and where.
    func copyTask(_ group: Report.Group) {
        guard let report else { return }
        var lines = ["## \(group.check.title)", "", group.check.why, "", "Done when: \(group.check.passed.prefix(1).lowercased() + group.check.passed.dropFirst())."]
        if !group.findings.isEmpty { lines.append("") }
        for finding in group.findings {
            let place = finding.url.map { ReportFormat.short($0, site: report.site) } ?? report.host
            lines.append("- [ ] \(place)\(finding.detail.map { ": \($0)" } ?? "")")
        }
        copy(lines.joined(separator: "\n"))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.copied = false
        }
    }

    func save(json: Bool) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "launch-check-\(report.host).\(json ? "json" : "md")"
        panel.allowedContentTypes = [json ? .json : (UTType(filenameExtension: "md") ?? .plainText)]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (json ? ReportFormat.json(report) : ReportFormat.markdown(report)).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(_ address: String?) {
        guard let address, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
