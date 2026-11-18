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
        case previews = "Previews"
        case schema = "Structured data"
        case changes = "Changes"
    }

    /// What a check is asked to do: everything, or one job that needs nothing but an address.
    struct Job: Hashable, Identifiable {
        let id: String
        let title: String
        /// One line saying what the job answers.
        let about: String
        /// The areas it checks. nil checks them all.
        let areas: Set<LaunchcheckCore.Category>?
        /// The tab that answers it, where its result opens.
        let landing: Tab

        static let full = Job(id: "full", title: "Full check", about: "Every page in the sitemap, against every check.", areas: nil, landing: .overview)

        /// The jobs offered first: each one a question people arrive with.
        static let focused: [Job] = [
            Job(id: "structured", title: "Structured data", about: "Every JSON-LD block, its types and fields, and what each is missing.", areas: [.structured], landing: .schema),
            Job(id: "sharing", title: "Sharing and previews", about: "How the link looks on Google, in a chat and on X.", areas: [.sharing], landing: .previews),
            Job(id: "indexing", title: "Indexing", about: "Can it be found: robots.txt, noindex, canonical, sitemap, redirects.", areas: [.indexing, .sitemap], landing: .issues),
            Job(id: "images", title: "Images", about: "Weight, format, alt text, size attributes and lazy loading.", areas: [.images], landing: .issues),
            Job(id: "international", title: "International", about: "Hreflang: codes, return links, where each version leads.", areas: [.international], landing: .issues),
            Job(id: "ai", title: "AI search", about: "Which assistants may read it, llms.txt, and what is there without JavaScript.", areas: [.ai], landing: .issues),
        ]

        /// The remaining areas, each on its own.
        static let others: [Job] = [LaunchcheckCore.Category.links, .content, .performance, .security].map {
            Job(id: $0.rawValue, title: $0.title, about: $0.blurb + ".", areas: [$0], landing: .issues)
        }

        static let all = [full] + focused + others
    }

    /// What the window is for at the moment: checking one site, or moving one to a new build.
    enum Mode: Hashable {
        case check, migrate
    }

    @Published var mode: Mode = .check
    let migration = MigrationModel()

    @Published var address = ""
    /// What the next check will do. Remembered for each site.
    @Published var job: Job = .full
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
    /// The page the Previews tab is showing: the home page until another is picked.
    @Published var previewPage: String?
    @Published var previewSearch = ""
    /// The page the Structured data tab is showing.
    @Published var schemaPage: String?
    @Published var schemaSearch = ""
    /// The issues of the site on screen that have been ticked as handled.
    @Published var checklist = Checklist()
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
        migration.pageLimit = { [weak self] in self?.maxPages ?? 200 }
    }

    var isRunning: Bool { phase == .running }

    // MARK: Running a check

    func start() {
        let site = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else { return }
        mode = .check
        task?.cancel()
        run += 1
        let current = run
        var options = Options()
        options.maxPages = maxPages
        options.checkExternalLinks = checkExternalLinks
        options.checkImages = checkImages
        options.areas = job.areas
        // One job, one link: the address of a page means that page; the address of a site means the site.
        options.singlePage = job.areas != nil && Self.isDeepLink(site)
        if let host = Auditor.siteURL(from: site)?.host { remember(job, for: host) }
        let landing = job.landing
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
                self.finish(report, landing: landing)
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

    private func finish(_ report: Report, landing: Tab = .overview) {
        let previous = history.latest(for: report.host)
        if report.isPartial {
            // A check of one area or one page is shown, not kept: the sidebar score, the trend and the next
            // comparison all stay with the last check of the whole site. It is compared with that check, cut down
            // to the same areas, so "fixed" and "new" mean what they say.
            let like = report.page == nil ? previous.map { $0.restricted(to: report.checkedAreas ?? LaunchcheckCore.Category.allCases) } : nil
            present(report, comparedWith: like, landing: landing)
            return
        }
        history.save(report)
        // A tick lasts until a check shows the issue gone.
        history.save(history.checklist(for: report.host).carried(past: report), for: report.host)
        sites = history.sites()
        arrived = true
        present(report, comparedWith: previous)
    }

    /// True for the address of a page inside a site, as opposed to the site itself.
    static func isDeepLink(_ text: String) -> Bool {
        guard let url = Auditor.siteURL(from: text) else { return false }
        return url.path.count > 1 || url.query != nil
    }

    // MARK: The job, remembered per site

    private static func bare(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    private func remember(_ job: Job, for host: String) {
        var kept = UserDefaults.standard.dictionary(forKey: "jobs") as? [String: String] ?? [:]
        kept[Self.bare(host)] = job.id == Job.full.id ? nil : job.id
        UserDefaults.standard.set(kept, forKey: "jobs")
    }

    private func remembered(for host: String) -> Job {
        let kept = UserDefaults.standard.dictionary(forKey: "jobs") as? [String: String] ?? [:]
        return Job.all.first { $0.id == kept[Self.bare(host)] } ?? .full
    }

    /// Runs the whole check of the site on screen, from a partial result.
    func checkEverything() {
        guard let report else { return }
        job = .full
        address = report.host
        start()
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
        mode = .check
        let earlier = history.reports(for: report.host).first { $0.date < report.date }
        address = report.host
        job = remembered(for: report.host)
        present(report, comparedWith: earlier)
    }

    func present(_ report: Report, comparedWith previous: Report?, keepingTab: Bool = false, landing: Tab = .overview) {
        let tabBefore = tab
        defer { tab = keepingTab ? tabBefore : landing }
        self.report = report
        comparison = previous.map { Drift.compare($0, report) }
        checks = history.reports(for: report.host)
        checklist = history.checklist(for: report.host)
        trail = Array(history.reports(for: report.host).filter { $0.date <= report.date }.sorted { $0.date < $1.date }.map(\.score).suffix(12))
        if trail.isEmpty { trail = (previous.map { [$0.score] } ?? []) + [report.score] }
        tab = .overview
        grouping = .severity
        search = ""
        pageSearch = ""
        previewSearch = ""
        scope = .all
        pageSort = .issues
        // The most serious problem still to do is already open; the rest is one arrow key away.
        selectedIssue = orderedGroups.first?.id
        selectedPage = sortedPages(of: report).first?.url
        previewPage = Self.homePage(of: report)?.url
        schemaSearch = ""
        // Open on a page that has something to show.
        schemaPage = (report.pages.first { !($0.schema ?? []).isEmpty } ?? Self.homePage(of: report))?.url
        phase = .done
    }

    /// Answers launchcheck://open?site=example.com: the latest kept report for that site, or a fresh check of it.
    func open(link: URL) {
        guard let site = DeepLink.site(from: link) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let kept = history.latest(matching: site) {
            if isRunning { stop() }
            show(kept)
        } else {
            address = site
            start()
        }
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
        checklist = Checklist()
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

    /// The page a visitor lands on: the site's own address when it was read, otherwise the first page.
    static func homePage(of report: Report) -> PageSummary? {
        func bare(_ address: String) -> String { address.hasSuffix("/") ? String(address.dropLast()) : address }
        return report.pages.first { bare($0.url) == bare(report.site) } ?? report.pages.first
    }

    func showPreview(_ address: String?) {
        guard let address, report?.pages.contains(where: { $0.url == address }) == true else { return }
        previewSearch = ""
        previewPage = address
        tab = .previews
    }

    func showSchema(_ address: String?) {
        guard let address, report?.pages.contains(where: { $0.url == address }) == true else { return }
        schemaSearch = ""
        schemaPage = address
        tab = .schema
    }

    /// Pages for the Structured data list: those matching the filter, by address, title or type.
    var schemaPages: [PageSummary] {
        guard let report else { return [] }
        let needle = schemaSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return report.pages }
        return report.pages.filter { page in
            page.url.lowercased().contains(needle) || page.schemaTypes.contains { $0.lowercased().contains(needle) }
        }
    }

    /// Pages for the Previews list, in the order they were read: the home page first.
    var previewPages: [PageSummary] {
        guard let report else { return [] }
        let needle = previewSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return report.pages }
        return report.pages.filter { $0.url.lowercased().contains(needle) || ($0.title ?? "").lowercased().contains(needle) }
    }

    // MARK: Checklist

    var handled: Set<String> {
        report.map { checklist.handled(in: $0) } ?? []
    }

    /// Ticks an issue as handled, or unticks it, and remembers that for the site.
    func toggleHandled(_ id: String) {
        guard let report else { return }
        let ticking = !checklist.isHandled(id)
        // Ticking the open issue moves on to the one that takes its place, so a list can be worked down without looking away.
        var following: String?
        if ticking, selectedIssue == id {
            let open = orderedGroups.map(\.id).filter { !checklist.isHandled($0) }
            if let index = open.firstIndex(of: id) {
                following = index + 1 < open.count ? open[index + 1] : (index > 0 ? open[index - 1] : nil)
            }
        }
        checklist.set(id, handled: ticking)
        history.save(checklist, for: report.host)
        if let following { selectedIssue = following }
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
        var groups = visibleGroups
        if grouping == .area {
            groups = LaunchcheckCore.Category.allCases.flatMap { category in groups.filter { $0.check.category == category } }
        }
        // Handled issues are collected at the bottom.
        let split = checklist.split(groups)
        return split.open + split.handled
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
        case .previews:
            let urls = previewPages.map(\.url)
            guard !urls.isEmpty else { return }
            let index = previewPage.flatMap { urls.firstIndex(of: $0) } ?? (step > 0 ? -1 : urls.count)
            previewPage = urls[min(urls.count - 1, max(0, index + step))]
        case .schema:
            let urls = schemaPages.map(\.url)
            guard !urls.isEmpty else { return }
            let index = schemaPage.flatMap { urls.firstIndex(of: $0) } ?? (step > 0 ? -1 : urls.count)
            schemaPage = urls[min(urls.count - 1, max(0, index + step))]
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
        case .previews:
            let urls = previewPages.map(\.url)
            guard let index = previewPage.flatMap({ urls.firstIndex(of: $0) }) else { return nil }
            return (index + 1, urls.count)
        case .schema:
            let urls = schemaPages.map(\.url)
            guard urls.count > 1, let index = schemaPage.flatMap({ urls.firstIndex(of: $0) }) else { return nil }
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
        let fix = ReportFormat.fixLines(for: group.check, webflow: report.isWebflow)
        if !fix.isEmpty { lines += [""] + fix }
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
        save(as: json ? .json : .markdown)
    }

    enum Export {
        case markdown, json, html
    }

    func save(as format: Export) {
        guard let report else { return }
        let panel = NSSavePanel()
        let type: (String, UTType)
        switch format {
        case .markdown: type = ("md", UTType(filenameExtension: "md") ?? .plainText)
        case .json: type = ("json", .json)
        case .html: type = ("html", .html)
        }
        panel.nameFieldStringValue = "launch-check-\(report.host).\(type.0)"
        panel.allowedContentTypes = [type.1]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        switch format {
        case .markdown: text = ReportFormat.markdown(report)
        case .json: text = ReportFormat.json(report)
        // The one made for sending on, so it says what has been handled.
        case .html: text = ReportFormat.html(report, handled: handled)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(_ address: String?) {
        guard let address, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
