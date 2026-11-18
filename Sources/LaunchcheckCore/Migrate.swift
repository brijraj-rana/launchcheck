import Foundation

// When a site is rebuilt, every old address that is not redirected loses its search ranking.
// This compares the old site with the new one and writes the redirect list.

/// What becomes of one old address.
public struct MigrationRow: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        /// The same address exists on the new site.
        case same
        /// It already redirects to a page that loads.
        case redirected
        /// It redirects, but to a missing page or through a chain.
        case broken
        /// Missing, with a match that can be trusted.
        case confident
        /// Missing, with a match that needs a look.
        case possible
        /// Missing, and nothing on the new site looks like it.
        case unmatched
    }

    /// How much attention a row needs. This is what the screen groups and marks rows by.
    public enum Standing: String, CaseIterable, Sendable {
        /// No destination: a person has to decide.
        case stranded
        /// A destination was suggested, but it should be checked.
        case uncertain
        /// The redirect is written and can be exported as it is.
        case ready
        /// Nothing to do.
        case fine
    }

    /// The old address in full.
    public var old: String
    /// The old path, as it goes on the left of a redirect rule.
    public var path: String
    public var outcome: Outcome
    /// The path on the new site this address should lead to.
    public var destination: String?
    /// False while the destination is a guess that needs checking.
    public var sure: Bool
    /// Why: "Same page under /posts", "Redirects to /x, which returns 404".
    public var note: String?
    /// The old page's title, when the old site still answered.
    public var title: String?
    /// Other pages on the new site it could be, best first.
    public var alternatives: [String]
    /// True once a person has chosen the destination.
    public var edited: Bool

    public var id: String { path }

    public init(old: String, path: String, outcome: Outcome, destination: String? = nil, sure: Bool = true, note: String? = nil,
                title: String? = nil, alternatives: [String] = [], edited: Bool = false) {
        self.old = old
        self.path = path
        self.outcome = outcome
        self.destination = destination
        self.sure = sure
        self.note = note
        self.title = title
        self.alternatives = alternatives
        self.edited = edited
    }

    public var standing: Standing {
        switch outcome {
        case .same, .redirected: return .fine
        case .confident, .possible, .broken, .unmatched:
            guard destination != nil else { return .stranded }
            return sure ? .ready : .uncertain
        }
    }

    /// True when a redirect has to be added or repaired for this address.
    public var needsRedirect: Bool { standing != .fine }
}

public struct MigrationMap: Codable, Equatable, Sendable {
    public struct NewPage: Codable, Equatable, Identifiable, Sendable {
        public var path: String
        public var title: String?
        public var id: String { path }

        public init(path: String, title: String? = nil) {
            self.path = path
            self.title = title
        }
    }

    public var oldSite: String
    public var newSite: String
    public var date: Date
    public var rows: [MigrationRow]
    /// Every page that loaded on the new site.
    public var newPages: [NewPage]
    /// Old addresses turned up; larger than `rows.count` when the page limit cut the run short.
    public var oldPagesFound: Int

    public init(oldSite: String, newSite: String, date: Date = Date(), rows: [MigrationRow], newPages: [NewPage], oldPagesFound: Int? = nil) {
        self.oldSite = oldSite
        self.newSite = newSite
        self.date = date
        self.rows = rows
        self.newPages = newPages
        self.oldPagesFound = oldPagesFound ?? rows.count
    }

    public var oldHost: String { URL(string: oldSite)?.host ?? oldSite }
    public var newHost: String { URL(string: newSite)?.host ?? newSite }

    public func count(_ standing: MigrationRow.Standing) -> Int {
        rows.filter { $0.standing == standing }.count
    }

    public func count(_ outcome: MigrationRow.Outcome) -> Int {
        rows.filter { $0.outcome == outcome }.count
    }

    /// Old addresses left with nowhere to go.
    public var stranded: Int { count(.stranded) }

    /// New pages no old address leads to. Not a problem, only worth knowing: they start with no history.
    public var unclaimed: [String] {
        let claimed = Set(rows.compactMap(\.destination).map(Migrator.tidy))
        return newPages.map(\.path).filter { $0 != "/" && !claimed.contains(Migrator.tidy($0)) }
    }

    public var verdict: String {
        if rows.isEmpty { return "No old pages were found" }
        let needing = rows.filter(\.needsRedirect).count
        if needing == 0 { return "Every old page has somewhere to go" }
        return needing == 1 ? "1 old page needs a redirect" : "\(needing) old pages need a redirect"
    }

    /// "9 are written, 3 need a look, 2 have no match".
    public var breakdown: String {
        var parts: [String] = []
        let ready = count(.ready), uncertain = count(.uncertain), stranded = count(.stranded)
        if ready > 0 { parts.append(ready == 1 ? "1 is written" : "\(ready) are written") }
        if uncertain > 0 { parts.append(uncertain == 1 ? "1 needs a look" : "\(uncertain) need a look") }
        if stranded > 0 { parts.append(stranded == 1 ? "1 has no match" : "\(stranded) have no match") }
        return parts.joined(separator: ", ")
    }

    /// Sets where an old address should go, by hand. An empty destination leaves it with none.
    public mutating func setDestination(_ destination: String, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let path = Migrator.entered(destination)
        rows[index].edited = true
        rows[index].sure = true
        if let path {
            rows[index].destination = path
            if rows[index].outcome == .possible || rows[index].outcome == .unmatched { rows[index].outcome = .confident }
            rows[index].note = "Chosen by hand"
        } else {
            rows[index].destination = nil
            rows[index].outcome = .unmatched
            rows[index].note = "Left without a redirect"
        }
    }

    /// The rows that become redirect rules: the sure ones first, then the ones that need a look.
    public func redirects(confidentOnly: Bool = false) -> [MigrationRow] {
        let wanted = rows.filter { $0.needsRedirect && $0.destination != nil }
        return wanted.filter(\.sure) + (confidentOnly ? [] : wanted.filter { !$0.sure })
    }
}

public enum MigrationError: Error, LocalizedError, Equatable {
    case emptyList(String)

    public var errorDescription: String? {
        switch self {
        case .emptyList(let host): return "The list has no addresses on \(host). It should be a sitemap, or one address or path per line."
        }
    }
}

/// Reads both sites and decides what becomes of every old address.
public final class Migrator: @unchecked Sendable {
    // MARK: Thresholds

    /// The numbers the matcher decides by. A score is 1 for identical text and 0 for nothing in common.
    public enum Threshold {
        /// Last parts of two addresses this alike are taken to be the same page: "rocket-skates" and "rocket-skate".
        /// High, because a wrong redirect that looks right is worse than one a person is asked to check.
        public static let confidentSlug = 0.85
        /// Below this the last parts of two addresses have too little in common to suggest: "about" and "about-us"
        /// score 0.63 and are offered as a possible match; "team" and "careers" score 0.29 and are not.
        public static let possibleSlug = 0.6
        /// Titles or main headings this alike are taken to be the same page. Higher than for addresses, since
        /// templates make titles alike across a site ("Rocket skates" and "Rocket skis" already score 0.77).
        public static let confidentTitle = 0.9
        /// Below this two titles are not offered as a match.
        public static let possibleTitle = 0.65
        /// How far the best candidate must be ahead of the second best to be trusted. When two new pages fit
        /// almost equally, the choice between them is a person's.
        public static let lead = 0.08
        /// Candidates scoring at least this are kept as alternatives for the menu, best first.
        public static let alternative = 0.4
        /// Last parts shorter than this ("p", "en", "2") say too little to match on.
        public static let minimumSlug = 3
        /// Titles shorter than this ("Home", "Blog") are shared by too many pages to match on.
        public static let minimumTitle = 8
    }

    /// First segments that mean the same thing on different platforms. /blog/x on the old site and /posts/x on
    /// the new one are taken to be the same page. Kept to pairs that are safe to treat as one.
    static let prefixes: [[String]] = [
        ["blog", "posts", "post", "news", "articles", "article", "journal", "insights", "stories", "updates"],
        ["products", "product", "shop", "store", "catalog", "catalogue"],
        ["services", "service"],
        ["work", "portfolio", "projects", "project", "case-studies", "case-study", "our-work"],
        ["team", "people", "our-team"],
        ["careers", "jobs"],
        ["about", "about-us"],
        ["contact", "contact-us"],
        ["faq", "faqs"],
    ]

    /// Endings that name a file where the new site has a plain path.
    static let endings = [".html", ".htm", ".php", ".aspx", ".asp", ".jsp", ".cfm"]

    private static let alias: [String: String] = {
        var map: [String: String] = [:]
        for group in prefixes { for name in group { map[name] = group[0] } }
        return map
    }()

    private let fetcher: Fetcher
    private let options: Options

    public init(fetcher: Fetcher = URLSessionFetcher(), options: Options = Options()) {
        self.fetcher = fetcher
        self.options = options
    }

    // MARK: Run

    /// - Parameters:
    ///   - old: The old site's address. Its sitemap is read, or failing that its links are followed.
    ///   - new: The new site's address. It can be a staging address; redirects are written as paths.
    ///   - oldList: The old site's addresses as text, for when it is already offline: a sitemap file, or one
    ///     address or path per line.
    public func run(old: String, new: String, oldList: String? = nil,
                    progress: @escaping @Sendable (AuditProgress) -> Void = { _ in }) async throws -> MigrationMap {
        guard let oldEntered = Auditor.siteURL(from: old) else { throw AuditError.invalidAddress(old) }
        guard let newEntered = Auditor.siteURL(from: new) else { throw AuditError.invalidAddress(new) }
        let auditor = Auditor(fetcher: fetcher, options: options)
        let limit = max(1, options.maxPages)

        // The new site: every page that loads, with its title and main heading.
        let fresh = try await auditor.discover(newEntered, phase: "Reading new pages", progress: progress)
        try Task.checkCancellation()
        var candidates: [Candidate] = []
        var known = Set<String>()
        for page in fresh.pages {
            guard page.result.ok, let facts = page.facts, Auditor.sameSite(page.result.finalURL.host ?? "", fresh.host) else { continue }
            let path = Self.path(of: page.result.finalURL)
            guard known.insert(path).inserted else { continue }
            candidates.append(Candidate(path: path, title: facts.title, h1: facts.h1))
        }

        // The old addresses: a list when one was given, otherwise whatever the old site says it has.
        var oldPages: [Auditor.Page]
        var oldFound: Int
        var oldRoot: URL
        if let oldList {
            guard let host = oldEntered.host, let root = URL(string: "\(oldEntered.scheme ?? "https")://\(host)/") else { throw AuditError.invalidAddress(old) }
            oldRoot = root
            let listed = Self.addresses(in: oldList, base: root).filter { Auditor.sameSite($0.host ?? "", host) }
            guard !listed.isEmpty else { throw MigrationError.emptyList(host) }
            oldFound = listed.count
            let targets = Array(listed.prefix(limit))
            let counter = Counter()
            progress(AuditProgress(phase: "Reading old pages", done: 0, total: targets.count))
            oldPages = await concurrentMap(targets, limit: options.concurrency) { url -> Auditor.Page in
                let page = await auditor.load(url, inSitemap: true)
                progress(AuditProgress(phase: "Reading old pages", done: counter.next(), total: targets.count))
                return page
            }
        } else if Auditor.sameSite(oldEntered.host ?? "", fresh.host) {
            // One address for both: the site has already moved, and what is there now is all that can be read.
            (oldPages, oldFound, oldRoot) = (fresh.pages, fresh.found, fresh.root)
        } else {
            let stale = try await auditor.discover(oldEntered, phase: "Reading old pages", progress: progress)
            (oldPages, oldFound, oldRoot) = (stale.pages, stale.found, stale.root)
        }
        try Task.checkCancellation()

        // A server that answers 200 to anything cannot be asked whether an address exists.
        let madeUp = fresh.root.appendingPathComponent("launchcheck-\(UUID().uuidString.prefix(8).lowercased())")
        let answersAnything = await fetcher.fetch(madeUp, bodyWanted: false).ok

        var seen = Set<String>()
        let unique = oldPages.filter { seen.insert(Self.pathAndQuery(of: $0.url)).inserted }
        let oneSite = Auditor.sameSite(oldRoot.host ?? "", fresh.host)
        let pool = candidates
        let knownPaths = known
        let newRoot = fresh.root
        let counter = Counter()
        progress(AuditProgress(phase: "Looking up old addresses", done: 0, total: unique.count))
        let rows = await concurrentMap(unique, limit: options.concurrency) { page -> MigrationRow in
            let row = await self.decide(page, oneSite: oneSite, newRoot: newRoot, known: knownPaths, candidates: pool, answersAnything: answersAnything)
            progress(AuditProgress(phase: "Looking up old addresses", done: counter.next(), total: unique.count))
            return row
        }
        try Task.checkCancellation()

        return MigrationMap(oldSite: oldRoot.absoluteString, newSite: fresh.root.absoluteString, rows: rows,
                            newPages: candidates.map { MigrationMap.NewPage(path: $0.path, title: $0.title) },
                            oldPagesFound: max(oldFound, rows.count))
    }

    /// Decides one old address: asks the new site what it does with it today, and looks for a match if the answer is nothing.
    private func decide(_ page: Auditor.Page, oneSite: Bool, newRoot: URL, known: Set<String>, candidates: [Candidate],
                        answersAnything: Bool) async -> MigrationRow {
        let path = Self.pathAndQuery(of: page.url)
        let plain = Self.path(of: page.url)
        var row = MigrationRow(old: page.url.absoluteString, path: path, outcome: .unmatched, title: page.facts?.title)

        // What the new site answers for this address. When both sites share a domain, the page was already asked.
        var answer: FetchResult?
        if oneSite {
            answer = page.result
        } else if page.result.redirected, Auditor.sameSite(page.result.finalURL.host ?? "", newRoot.host ?? "") {
            answer = page.result                  // the old domain already forwards to the new one
        } else if page.url.query == nil, known.contains(plain) {
            row.outcome = .same
            row.destination = plain
            return row
        } else if !answersAnything, let probe = URL(string: path, relativeTo: newRoot)?.absoluteURL {
            answer = await fetcher.fetch(probe, bodyWanted: false)
        }

        var lostTo: String?
        if let answer, answer.status != 0 {
            // A hop that only adds a slash, https or www is not a redirect anyone has to care about.
            var stops = [plain]
            for hop in answer.redirects where Self.path(of: hop) != stops.last { stops.append(Self.path(of: hop)) }
            let end = Self.path(of: answer.finalURL)
            let landed = Auditor.sameSite(answer.finalURL.host ?? "", newRoot.host ?? "") ? end : answer.finalURL.absoluteString
            if answer.ok, stops.count == 1 {
                row.outcome = .same
                row.destination = plain
                return row
            }
            if answer.ok, stops.count == 2 {
                row.outcome = .redirected
                row.destination = landed
                row.note = "Already redirects to \(landed)"
                return row
            }
            if answer.ok {
                row.outcome = .broken
                row.destination = landed
                row.note = "Gets there in \(stops.count - 1) hops: \(stops.joined(separator: " → ")). Point it straight at the last one."
                return row
            }
            if stops.count > 1 { lostTo = "Redirects to \(landed), which returns \(answer.status)" }
        }

        // Nothing lives at this address on the new site. Look for the page it became.
        let match = Self.match(path: plain, title: page.facts?.title, h1: page.facts?.h1, among: candidates)
        row.destination = match.destination
        row.sure = match.sure
        row.alternatives = match.alternatives
        if let lostTo {
            row.outcome = .broken
            row.note = match.note.map { "\(lostTo). \($0)" } ?? lostTo
        } else {
            row.outcome = match.destination == nil ? .unmatched : (match.sure ? .confident : .possible)
            row.note = match.note ?? "Nothing on the new site has a similar address or title"
        }
        return row
    }

    // MARK: Matching

    struct Candidate: Equatable, Sendable {
        var path: String
        var title: String?
        var h1: String?
    }

    struct Match: Equatable, Sendable {
        var destination: String?
        var sure = true
        var note: String?
        var alternatives: [String] = []
    }

    /// Finds the new page an old address became. In order: the same address once tidied, the same page under
    /// another name for its section, the same last part, then likeness of the last part and of the title or H1.
    static func match(path: String, title: String? = nil, h1: String? = nil, among candidates: [Candidate]) -> Match {
        let pool = candidates.filter { $0.path != path }
        guard !pool.isEmpty else { return Match() }
        func others(than chosen: String, from paths: [String]) -> [String] { Array(paths.filter { $0 != chosen }.prefix(3)) }

        // 1. Case, trailing slash, .html or .php, /index
        let tidied = tidy(path)
        let sameTidied = pool.filter { tidy($0.path) == tidied }
        if let first = sameTidied.first {
            return Match(destination: first.path, note: "Same address once tidied", alternatives: others(than: first.path, from: sameTidied.map(\.path)))
        }

        // 2. /blog/2021/03/x and /posts/x
        let wanted = core(path)
        let sameCore = pool.filter { core($0.path) == wanted }
        if let first = sameCore.first, wanted != "/" {
            let section = first.path.split(separator: "/").first.map { "/\($0)" } ?? first.path
            return Match(destination: first.path, sure: sameCore.count == 1,
                         note: sameCore.count == 1 ? "Same page under \(section)" : "\(sameCore.count) new pages fit this address",
                         alternatives: others(than: first.path, from: sameCore.map(\.path)))
        }

        // 3. The same last part anywhere on the new site
        let last = slug(path)
        let usable = last.count >= Threshold.minimumSlug && !last.allSatisfy(\.isNumber)
        if usable {
            let sameSlug = pool.filter { slug($0.path) == last }
            if let first = sameSlug.first {
                return Match(destination: first.path, sure: sameSlug.count == 1,
                             note: sameSlug.count == 1 ? "Same last part of the address" : "\(sameSlug.count) new pages end in “\(last)”",
                             alternatives: others(than: first.path, from: sameSlug.map(\.path)))
            }
        }

        // 4. Likeness of the address, then of the title and main heading
        let oldTitle = headline(title), oldHeading = headline(h1)
        var scored: [(candidate: Candidate, slug: Double, title: Double)] = []
        for candidate in pool {
            let theirs = slug(candidate.path)
            var bySlug = 0.0
            if usable, theirs.count >= Threshold.minimumSlug {
                bySlug = max(Drift.similarity(last, theirs), overlap(last, theirs))
            }
            var byTitle = 0.0
            if bySlug < Threshold.confidentSlug {
                for (mine, other) in [(oldTitle, headline(candidate.title)), (oldHeading, headline(candidate.h1))]
                where mine.count >= Threshold.minimumTitle && other.count >= Threshold.minimumTitle {
                    byTitle = max(byTitle, Drift.similarity(mine, other))
                }
            }
            if max(bySlug, byTitle) >= Threshold.alternative { scored.append((candidate, bySlug, byTitle)) }
        }
        scored.sort { max($0.slug, $0.title) > max($1.slug, $1.title) }
        guard let best = scored.first else { return Match() }
        let alternatives = Array(scored.dropFirst().prefix(3).map(\.candidate.path))
        let ahead = scored.count < 2 || max(best.slug, best.title) - max(scored[1].slug, scored[1].title) >= Threshold.lead

        let titleLed = best.title > best.slug
        let percent = Int((max(best.slug, best.title) * 100).rounded())
        let note = titleLed ? (best.title == 1 ? "Same title" : "Similar title, \(percent)% alike") : "Similar address, \(percent)% alike"
        if best.slug >= Threshold.confidentSlug || best.title >= Threshold.confidentTitle {
            return Match(destination: best.candidate.path, sure: ahead, note: ahead ? note : "\(note), but another page is as close",
                         alternatives: alternatives)
        }
        if best.slug >= Threshold.possibleSlug || best.title >= Threshold.possibleTitle {
            return Match(destination: best.candidate.path, sure: false, note: note, alternatives: alternatives)
        }
        return Match(alternatives: scored.prefix(3).map(\.candidate.path))
    }

    /// An address with the differences that do not matter removed: case, a trailing slash, a file ending,
    /// /index, underscores for hyphens.
    static func tidy(_ path: String) -> String {
        var text = (path.removingPercentEncoding ?? path).lowercased()
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        text = text.replacingOccurrences(of: "_", with: "-")
        var parts = text.split(separator: "/").map(String.init)
        if var last = parts.popLast() {
            for ending in endings where last.hasSuffix(ending) {
                last = String(last.dropLast(ending.count))
                break
            }
            if !last.isEmpty, last != "index", last != "default" { parts.append(last) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The tidied address with dates dropped and its section called by one name: /blog/2021/03/x and /posts/x agree.
    static func core(_ path: String) -> String {
        var parts = tidy(path).split(separator: "/").map(String.init)
        if let first = parts.first, let name = alias[first] { parts[0] = name }
        // WordPress writes the year, month and day into the address; nobody else does.
        // The last part is the page's own name and stays, even when it is a number.
        if let last = parts.popLast() {
            parts = parts.filter { !($0.count <= 4 && $0.allSatisfy(\.isNumber)) } + [last]
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The last part of an address, tidied: "why-anvils-fall" for /blog/2021/Why_Anvils_Fall.html
    static func slug(_ path: String) -> String {
        tidy(path).split(separator: "/").last.map(String.init) ?? ""
    }

    /// The share of words two slugs have in common: 3 of 5 for "why-anvils-fall" and "why-our-anvils-fall-straighter".
    static func overlap(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: "-")), y = Set(b.split(separator: "-"))
        guard x.count > 1, y.count > 1 else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// A title without the site's name on the end: "Pricing" for "Pricing | Acme Rockets".
    static func headline(_ text: String?) -> String {
        let whole = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var pieces = [whole]
        for separator in [" | ", " · ", " - ", " : ", " \u{2013} ", " \u{2014} "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return (pieces.max { $0.count < $1.count } ?? whole).trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Addresses

    /// The path of an address as a redirect rule writes it: no trailing slash, "/" for the home page.
    static func path(of url: URL) -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    static func pathAndQuery(of url: URL) -> String {
        path(of: url) + (url.query.map { "?\($0)" } ?? "")
    }

    /// What someone typed as a destination, as a path: "pricing", "/pricing/" and a full address on the new site all work.
    /// Nil for nothing at all. A full address on another site is kept whole.
    public static func entered(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") { return trimmed }
        var path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Reads a list of old addresses: a sitemap file, or text with one address or path at the start of each line
    /// (so the first column of a CSV works too). Paths are taken to be on `base`.
    public static func addresses(in text: String, base: URL) -> [URL] {
        var found: [String] = []
        if text.range(of: "<loc", options: .caseInsensitive) != nil {
            found = SitemapParser.parse(Data(text.utf8)).pages
        } else {
            for line in text.split(whereSeparator: \.isNewline) {
                let first = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == " " || $0 == ";" }).first.map(String.init) ?? ""
                let entry = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                // Anything else at the start of a line is a heading or a comment.
                if entry.hasPrefix("/") || entry.lowercased().hasPrefix("http://") || entry.lowercased().hasPrefix("https://") { found.append(entry) }
            }
        }
        var seen = Set<String>()
        return found.compactMap { entry -> URL? in
            guard let url = URL(string: entry, relativeTo: base)?.absoluteURL, url.host != nil else { return nil }
            return seen.insert(Auditor.key(url)).inserted ? url : nil
        }
    }
}

// MARK: Finding a site's pages

struct Discovery: Sendable {
    /// The site's home address, wherever the typed one ended up.
    let root: URL
    let host: String
    /// The home page first, then every page listed or linked, loaded.
    let pages: [Auditor.Page]
    /// Pages turned up; more than `pages.count` when the limit cut the reading short.
    let found: Int
}

extension Auditor {
    /// Finds and loads a site's pages the way an audit does: the sitemap when there is one, otherwise the links
    /// from the home page onward.
    func discover(_ entered: URL, phase: String, progress: @escaping @Sendable (AuditProgress) -> Void) async throws -> Discovery {
        let enteredHost = entered.host ?? entered.absoluteString
        progress(AuditProgress(phase: "Loading \(enteredHost)"))
        let home = await fetcher.fetch(entered, bodyWanted: true)
        guard home.status != 0 else { throw AuditError.unreachable(enteredHost, home.error ?? "No answer") }
        guard home.ok else { throw AuditError.unreachable(enteredHost, "The home page answered with status \(home.status)") }
        guard let host = home.finalURL.host, let root = URL(string: "\(home.finalURL.scheme ?? "https")://\(host)\(home.finalURL.port.map { ":\($0)" } ?? "")/") else {
            throw AuditError.invalidAddress(entered.absoluteString)
        }
        let homePage = Page(url: root, result: home, facts: HTMLScanner.scan(home.body), inSitemap: false)
        let limit = max(1, options.maxPages)

        let robotsResult = await fetcher.fetch(root.appendingPathComponent("robots.txt"), bodyWanted: true)
        let robots = robotsResult.ok && !robotsResult.isHTML ? Robots(String(decoding: robotsResult.body, as: UTF8.self)) : nil
        var queue = robots?.sitemaps.compactMap { URL(string: $0) } ?? []
        if queue.isEmpty { queue = [root.appendingPathComponent("sitemap.xml")] }
        var listed: [URL] = []
        var seen: Set<String> = [Self.key(root)]
        var read = Set<String>()
        while let next = queue.first, read.count < 25 {
            queue.removeFirst()
            guard read.insert(next.absoluteString).inserted else { continue }
            let result = await fetcher.fetch(next, bodyWanted: true)
            guard result.ok, !result.body.isEmpty else { continue }
            let contents = SitemapParser.parse(result.body)
            queue.append(contentsOf: contents.sitemaps.compactMap { URL(string: $0) })
            for location in contents.pages {
                guard let url = URL(string: location), Self.sameSite(url.host ?? "", host), seen.insert(Self.key(url)).inserted else { continue }
                listed.append(url)
            }
        }

        var pages = [homePage]
        if !listed.isEmpty {
            let targets = Array(listed.prefix(limit - 1))
            let counter = Counter()
            let total = targets.count + 1
            progress(AuditProgress(phase: phase, done: 1, total: total))
            pages += await concurrentMap(targets, limit: options.concurrency) { url -> Page in
                let page = await self.load(url, inSitemap: true)
                progress(AuditProgress(phase: phase, done: counter.next() + 1, total: total))
                return page
            }
            return Discovery(root: root, host: host, pages: pages, found: listed.count + 1)
        }

        var frontier = internalLinks(of: homePage, host: host).filter { seen.insert(Self.key($0)).inserted }
        while !frontier.isEmpty, pages.count < limit {
            try Task.checkCancellation()
            let batch = Array(frontier.prefix(limit - pages.count))
            let done = pages.count
            let known = min(limit, seen.count)
            let counter = Counter()
            let fetched = await concurrentMap(batch, limit: options.concurrency) { url -> Page in
                let page = await self.load(url, inSitemap: false)
                progress(AuditProgress(phase: phase, done: done + counter.next(), total: known))
                return page
            }
            var discovered = Array(frontier.dropFirst(batch.count))
            for page in fetched where page.facts != nil {
                pages.append(page)
                for link in internalLinks(of: page, host: host) where seen.insert(Self.key(link)).inserted { discovered.append(link) }
            }
            frontier = discovered
        }
        return Discovery(root: root, host: host, pages: pages, found: seen.count)
    }
}

// MARK: Formats

public enum MigrationFormat: String, CaseIterable, Sendable {
    case webflow, text, redirects, json

    /// The column names on the first line of the Webflow file. Webflow's import (Site settings → Publishing →
    /// 301 redirects) reads the first column as the old path and the second as where it goes. These names are
    /// believed to match what its own export writes but were not checked against a live export: export once
    /// from Webflow to confirm, and change them here if they differ.
    public static let webflowHeader = ["source", "target"]

    public var title: String {
        switch self {
        case .webflow: return "Webflow redirects CSV"
        case .text: return "Plain list"
        case .redirects: return "_redirects file"
        case .json: return "JSON"
        }
    }

    public var fileName: String {
        switch self {
        case .webflow: return "redirects.csv"
        case .text: return "redirects.txt"
        case .redirects: return "_redirects"
        case .json: return "redirects.json"
        }
    }

    /// The redirect list in this format. Rows that need a look come last and are marked wherever the format has
    /// room for a mark; `confidentOnly` leaves them out.
    public func render(_ map: MigrationMap, confidentOnly: Bool = false) -> String {
        let rows = map.redirects(confidentOnly: confidentOnly)
        let lost = map.rows.filter { $0.standing == .stranded }
        switch self {
        case .webflow:
            // Two columns and nothing else, so the file imports as it is. A CSV has no place for a remark:
            // rows that need a look are simply last.
            let lines = [Self.webflowHeader] + rows.map { [$0.path, $0.destination ?? ""] }
            return lines.map { $0.map(Self.cell).joined(separator: ",") }.joined(separator: "\n") + "\n"
        case .text:
            var lines = rows.map { "\($0.path) -> \($0.destination ?? "")\($0.sure ? "" : "  (check)")" }
            lines += lost.map { "\($0.path) -> ?" }
            return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        case .redirects:
            // Netlify's _redirects, which Cloudflare Pages reads too: old path, new path, status.
            let width = (rows.map(\.path.count).max() ?? 0) + 2
            func line(_ row: MigrationRow) -> String { "\(row.path.padding(toLength: max(width, row.path.count + 2), withPad: " ", startingAt: 0))\(row.destination ?? "")  301" }
            var lines = rows.filter(\.sure).map(line)
            let unsure = rows.filter { !$0.sure }
            if !unsure.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("# Check these before use: the match is a guess")
                lines += unsure.map(line)
            }
            if !lost.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("# No match on the new site")
                lines += lost.map { "# \($0.path)" }
            }
            return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        case .json:
            let formatter = ISO8601DateFormatter()
            let object: [String: Any] = [
                "oldSite": map.oldSite,
                "newSite": map.newSite,
                "date": formatter.string(from: map.date),
                "verdict": map.verdict,
                "redirects": rows.map { row -> [String: Any] in
                    var entry: [String: Any] = ["from": row.path, "to": row.destination ?? "", "outcome": row.outcome.rawValue, "uncertain": !row.sure]
                    if let note = row.note { entry["note"] = note }
                    return entry
                },
                "noMatch": lost.map(\.path),
                "fine": map.rows.filter { !$0.needsRedirect }.map { row -> [String: Any] in
                    ["from": row.path, "to": row.destination ?? row.path, "outcome": row.outcome.rawValue]
                },
                "newPagesWithNoOldAddress": map.unclaimed,
            ]
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self) + "\n" } ?? "{}\n"
        }
    }

    private static func cell(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: Opening the app from elsewhere

/// launchcheck://open?site=example.com
public enum DeepLink {
    public static let scheme = "launchcheck"

    /// The site a link asks for, or nil when the link is not one of ours or names no usable address.
    public static func site(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "site" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              Auditor.siteURL(from: value)?.host != nil else { return nil }
        return value
    }
}

extension History {
    /// The latest kept report for a site however it was typed: with or without www, as a host or a full address.
    public func latest(matching site: String) -> Report? {
        guard let host = Auditor.siteURL(from: site)?.host?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return [host, bare, "www.\(bare)"].compactMap { latest(for: $0) }.max { $0.date < $1.date }
    }
}
