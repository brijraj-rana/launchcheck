import Foundation

/// Crawls a site and runs every check against it.
public final class Auditor: @unchecked Sendable {
    private let fetcher: Fetcher
    private let options: Options

    public init(fetcher: Fetcher = URLSessionFetcher(), options: Options = Options()) {
        self.fetcher = fetcher
        self.options = options
    }

    struct Page: Sendable {
        let url: URL                 // as listed or linked
        let result: FetchResult
        let facts: PageFacts?        // nil unless it loaded as HTML
        let inSitemap: Bool
    }

    /// Crawlers that fetch pages to answer a question and cite the source. Training crawlers are a separate decision.
    static let searchAgents = ["OAI-SearchBot", "Claude-SearchBot", "PerplexityBot"]

    static let genericLinkText: Set<String> = ["click here", "read more", "learn more", "here", "more", "link", "this page", "details",
                                               "view", "website", "continue", "go"]

    static let genericAltText: Set<String> = ["image", "photo", "picture", "img", "graphic", "icon", "untitled", "click here", "banner"]

    // MARK: Run

    public func run(_ input: String, progress: @escaping @Sendable (AuditProgress) -> Void = { _ in }) async throws -> Report {
        let started = Date()
        guard let entered = Self.siteURL(from: input) else { throw AuditError.invalidAddress(input) }
        let enteredHost = entered.host ?? input

        progress(AuditProgress(phase: "Loading \(enteredHost)"))
        let home = await fetcher.fetch(entered, bodyWanted: true)
        guard home.status != 0 else { throw AuditError.unreachable(enteredHost, home.error ?? "No answer") }
        guard home.ok else { throw AuditError.unreachable(enteredHost, "The home page answered with status \(home.status)") }

        // The site lives wherever the address ends up (example.com may forward to www.example.com).
        guard let host = home.finalURL.host, let root = URL(string: "\(home.finalURL.scheme ?? "https")://\(host)\(home.finalURL.port.map { ":\($0)" } ?? "")/") else {
            throw AuditError.invalidAddress(input)
        }
        var findings: [Finding] = []
        var skipped: Set<String> = []
        let homePage = Page(url: root, result: home, facts: home.isHTML || !home.body.isEmpty ? HTMLScanner.scan(home.body) : nil, inSitemap: false)

        // robots.txt
        progress(AuditProgress(phase: "Reading robots.txt"))
        let robotsURL = root.appendingPathComponent("robots.txt")
        let robotsResult = await fetcher.fetch(robotsURL, bodyWanted: true)
        var robots: Robots?
        if robotsResult.status >= 500 {
            findings.append(Finding("robots.error", url: robotsURL, detail: "answers with \(robotsResult.status)"))
            skipped.formUnion(["robots.blocks-all", "robots.missing", "ai.search-blocked", "sitemap.undeclared", "sitemap.blocked"])
        } else if robotsResult.ok, !robotsResult.isHTML {
            robots = Robots(String(decoding: robotsResult.body, as: UTF8.self))
        } else {
            findings.append(Finding("robots.missing", url: robotsURL))
            skipped.formUnion(["robots.blocks-all", "sitemap.undeclared"])
        }
        if let robots {
            if robots.blocksEverything {
                findings.append(Finding("robots.blocks-all", url: robotsResult.finalURL, detail: "Disallow: /"))
                skipped.insert("ai.search-blocked")       // already covered, and louder
            } else {
                for agent in Self.searchAgents where robots.blocks("/", agent: agent) {
                    findings.append(Finding("ai.search-blocked", url: robotsResult.finalURL, detail: "\(agent) is disallowed"))
                }
            }
        }

        // Sitemaps
        progress(AuditProgress(phase: "Reading the sitemap"))
        var sitemapPages: [URL] = []
        var listed = Set<String>()
        var offsite: [String] = []
        var dates: [String] = []
        var queue = robots?.sitemaps.compactMap { URL(string: $0) } ?? []
        if queue.isEmpty { queue = [root.appendingPathComponent("sitemap.xml")] }
        var read = Set<String>()
        while let next = queue.first, read.count < 25 {
            queue.removeFirst()
            guard read.insert(next.absoluteString).inserted else { continue }
            let result = await fetcher.fetch(next, bodyWanted: true)
            guard result.ok, !result.body.isEmpty else { continue }
            let contents = SitemapParser.parse(result.body)
            if contents.pages.count > 50_000 {
                findings.append(Finding("sitemap.too-big", url: next, detail: "\(contents.pages.count) addresses in one file"))
            }
            dates.append(contentsOf: contents.dates)
            queue.append(contentsOf: contents.sitemaps.compactMap { URL(string: $0) })
            for location in contents.pages {
                guard let url = URL(string: location), let pageHost = url.host else { continue }
                if Self.sameSite(pageHost, host) {
                    if listed.insert(Self.key(url)).inserted { sitemapPages.append(url) }
                } else {
                    offsite.append(location)
                }
            }
        }
        let hasSitemap = !sitemapPages.isEmpty || !offsite.isEmpty
        if !hasSitemap {
            findings.append(Finding("sitemap.missing", url: root.appendingPathComponent("sitemap.xml")))
            skipped.formUnion(["sitemap.broken", "sitemap.offsite", "sitemap.redirects", "sitemap.blocked", "sitemap.too-big",
                               "sitemap.noncanonical", "sitemap.undeclared", "sitemap.lastmod", "sitemap.noindex",
                               "sitemap.incomplete", "page.orphan"])
        } else {
            if let robots, robots.sitemaps.isEmpty { findings.append(Finding("sitemap.undeclared", url: robotsURL)) }
            if dates.count >= 10, Set(dates).count == 1 {
                findings.append(Finding("sitemap.lastmod", url: root.appendingPathComponent("sitemap.xml"), detail: "all \(dates.count) entries say \(dates[0])"))
            }
        }
        for location in offsite.prefix(20) { findings.append(Finding("sitemap.offsite", detail: location)) }
        if offsite.count > 20 { findings.append(Finding("sitemap.offsite", detail: "and \(offsite.count - 20) more")) }

        // llms.txt
        let llmsURL = root.appendingPathComponent("llms.txt")
        let llms = await fetcher.fetch(llmsURL, bodyWanted: true)
        if llms.ok, !llms.isHTML, !llms.body.isEmpty {
            let text = String(decoding: llms.body, as: UTF8.self)
            var problems: [String] = []
            if !text.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }) {
                problems.append("no “# Title” line")
            }
            if text.range(of: #"\[[^\]]+\]\([^)\s]+\)"#, options: .regularExpression) == nil { problems.append("no Markdown links") }
            if text.count < 50 { problems.append("under 50 characters") }
            if !problems.isEmpty { findings.append(Finding("ai.llms-invalid", url: llmsURL, detail: problems.joined(separator: ", "))) }
        } else {
            findings.append(Finding("ai.llms-missing", url: llmsURL))
            skipped.insert("ai.llms-invalid")
        }

        // Pages: the sitemap when there is one, otherwise whatever the home page links lead to.
        var pages: [Page] = []
        var statuses: [String: FetchResult] = [Self.key(root): home]
        statuses[Self.key(home.url)] = home
        var pagesFound: Int
        let limit = max(1, options.maxPages)

        if !sitemapPages.isEmpty {
            var targets = sitemapPages.filter { Self.key($0) != Self.key(root) }
            let homeListed = targets.count != sitemapPages.count
            pagesFound = targets.count + 1
            targets = Array(targets.prefix(limit - 1))
            pages.append(Page(url: root, result: home, facts: homePage.facts, inSitemap: homeListed))
            let counter = Counter()
            let total = targets.count + 1
            progress(AuditProgress(phase: "Reading pages", done: 1, total: total))
            let fetched = await concurrentMap(targets, limit: options.concurrency) { url -> Page in
                let page = await self.load(url, inSitemap: true)
                progress(AuditProgress(phase: "Reading pages", done: counter.next() + 1, total: total))
                return page
            }
            pages.append(contentsOf: fetched)
        } else {
            pages.append(homePage)
            var seen: Set<String> = [Self.key(root)]
            var frontier = internalLinks(of: homePage, host: host).filter { seen.insert(Self.key($0)).inserted }
            while !frontier.isEmpty, pages.count < limit {
                try Task.checkCancellation()
                let batch = Array(frontier.prefix(limit - pages.count))
                let done = pages.count
                let known = min(limit, seen.count)
                let counter = Counter()
                let fetched = await concurrentMap(batch, limit: options.concurrency) { url -> Page in
                    let page = await self.load(url, inSitemap: false)
                    progress(AuditProgress(phase: "Following links", done: done + counter.next(), total: known))
                    return page
                }
                var discovered: [URL] = Array(frontier.dropFirst(batch.count))
                for page in fetched {
                    statuses[Self.key(page.url)] = page.result
                    guard page.facts != nil else { continue }       // a broken link, reported with the links
                    pages.append(page)
                    for link in internalLinks(of: page, host: host) where seen.insert(Self.key(link)).inserted {
                        discovered.append(link)
                    }
                }
                frontier = discovered
            }
            pagesFound = seen.count
        }
        try Task.checkCancellation()
        for page in pages { statuses[Self.key(page.url)] = page.result }
        let truncated = pagesFound > limit

        // Sitemap entries that do not lead straight to a page
        for page in pages where page.inSitemap {
            if page.result.status == 0 || page.result.status >= 400 {
                findings.append(Finding("sitemap.broken", url: page.url, detail: Self.describe(page.result)))
            } else if Self.key(page.result.finalURL) != Self.key(page.url) {
                findings.append(Finding("sitemap.redirects", url: page.url, detail: "redirects to \(page.result.finalURL.absoluteString)"))
            }
            if let robots, robots.blocks(page.url.path) {
                findings.append(Finding("sitemap.blocked", url: page.url))
            }
        }

        // Each page that loaded, once
        var checkedKeys = Set<String>()
        let loaded = pages.filter { page in
            page.facts != nil && page.result.ok && Self.sameSite(page.result.finalURL.host ?? "", host)
                && checkedKeys.insert(Self.key(page.result.finalURL)).inserted
        }
        let hostIsStaging = Self.isStaging(host)
        var titles: [String: [URL]] = [:]
        var descriptions: [String: [URL]] = [:]
        var shareImages: [String: (url: URL, pages: [URL])] = [:]
        var pageImages: [String: (url: URL, pages: [URL])] = [:]
        var linkTargets: [String: (url: URL, sources: [URL])] = [:]
        var outgoing: [String: Set<String>] = [:]
        var alternates: [String: (url: URL, targets: [String: String])] = [:]     // page → [target key: hreflang]
        var summaries: [PageSummary] = []
        var anyStructuredData = false

        for page in loaded {
            guard let facts = page.facts else { continue }
            let url = page.result.finalURL
            let pageKey = Self.key(url)
            let base = facts.base.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url

            // Indexing
            let header = (page.result.headers["x-robots-tag"] ?? "").lowercased()
            let hidden = facts.robots.contains("noindex") || facts.robots.contains("none")
            if hidden {
                findings.append(Finding("page.noindex", url: url, detail: "robots meta tag"))
            } else if header.contains("noindex") || header.contains("none") {
                findings.append(Finding("page.noindex", url: url, detail: "X-Robots-Tag header"))
            }
            let indexable = !hidden && !header.contains("noindex") && !header.contains("none")
            if page.inSitemap, !indexable { findings.append(Finding("sitemap.noindex", url: url)) }
            if facts.robots.contains("nofollow") || header.contains("nofollow") { findings.append(Finding("page.nofollow", url: url)) }
            if let refresh = facts.metaRefresh, refresh.lowercased().contains("url") {
                findings.append(Finding("meta.refresh", url: url, detail: refresh))
            }

            var untidy: [String] = []
            if url.path != url.path.lowercased() { untidy.append("capital letters") }
            if url.path.contains("_") { untidy.append("underscores") }
            if url.path.contains("//") { untidy.append("a doubled slash") }
            if url.absoluteString.count > 100 { untidy.append("\(url.absoluteString.count) characters long") }
            if !untidy.isEmpty { findings.append(Finding("url.hygiene", url: url, detail: untidy.joined(separator: ", "))) }

            // Canonical
            var canonicalIsSelf = true
            var canonicalURL: URL?
            if let raw = facts.canonical, !raw.isEmpty, let canonical = URL(string: raw, relativeTo: base)?.absoluteURL {
                canonicalURL = canonical
                if !Self.sameSite(canonical.host ?? "", host) {
                    canonicalIsSelf = false
                    if !hostIsStaging, Self.isStaging(canonical.host ?? "") {
                        findings.append(Finding("staging.leftovers", url: url, detail: "canonical → \(canonical.absoluteString)"))
                    } else {
                        findings.append(Finding("canonical.offsite", url: url, detail: "→ \(canonical.absoluteString)"))
                    }
                } else if Self.key(canonical) != pageKey {
                    canonicalIsSelf = false
                    findings.append(Finding("canonical.mismatch", url: url, detail: "→ \(canonical.absoluteString)"))
                    if page.inSitemap { findings.append(Finding("sitemap.noncanonical", url: url, detail: "canonical is \(canonical.absoluteString)")) }
                }
            } else {
                findings.append(Finding("canonical.missing", url: url))
            }

            // Head
            var repeated: [String] = []
            if facts.titleCount > 1 { repeated.append("\(facts.titleCount) title tags") }
            if facts.descriptionCount > 1 { repeated.append("\(facts.descriptionCount) meta descriptions") }
            if facts.canonicalCount > 1 { repeated.append("\(facts.canonicalCount) canonical tags") }
            if !repeated.isEmpty { findings.append(Finding("head.duplicates", url: url, detail: repeated.joined(separator: ", "))) }
            if !facts.hasDoctype { findings.append(Finding("doctype.missing", url: url)) }
            if !facts.hasCharset, !(page.result.headers["content-type"] ?? "").lowercased().contains("charset") {
                findings.append(Finding("charset.missing", url: url))
            }

            let title = facts.title ?? ""
            if title.isEmpty {
                findings.append(Finding("title.missing", url: url))
            } else {
                if title.count < 10 || title.count > 65 {
                    findings.append(Finding("title.length", url: url, detail: "\(title.count) characters: “\(title)”"))
                }
                if indexable, canonicalIsSelf { titles[title.lowercased(), default: []].append(url) }
            }
            let description = facts.description ?? ""
            if description.isEmpty {
                findings.append(Finding("description.missing", url: url))
            } else {
                if description.count < 50 || description.count > 165 {
                    findings.append(Finding("description.length", url: url, detail: "\(description.count) characters"))
                }
                if indexable, canonicalIsSelf { descriptions[description.lowercased(), default: []].append(url) }
            }

            // Structure and text
            if facts.h1Count == 0 { findings.append(Finding("h1.missing", url: url)) }
            if facts.h1Count > 1 { findings.append(Finding("h1.multiple", url: url, detail: "\(facts.h1Count) H1s")) }
            var previous = 0
            for heading in facts.headings {
                if previous > 0, heading.level > previous + 1 {
                    findings.append(Finding("heading.skip", url: url, detail: "H\(previous) is followed by H\(heading.level): “\(heading.text.prefix(60))”"))
                    break
                }
                previous = heading.level
            }
            if facts.lang == nil { findings.append(Finding("lang.missing", url: url)) }
            if !facts.hasViewport { findings.append(Finding("viewport.missing", url: url)) }
            if facts.hasPlaceholderText { findings.append(Finding("placeholder.text", url: url, detail: "“Lorem ipsum”")) }
            let shell = facts.wordCount < 50 && facts.hasAppRoot
            if shell {
                findings.append(Finding("content.js-shell", url: url, detail: "\(facts.wordCount) words in the HTML"))
            } else if indexable, facts.wordCount < 200 {
                findings.append(Finding("content.thin", url: url, detail: "\(facts.wordCount) words"))
            }
            if page.result.body.count >= 2_000_000 {
                findings.append(Finding("page.too-large", url: url, detail: Self.size(page.result.body.count)))
            }
            if page.result.milliseconds > 1000 {
                findings.append(Finding("perf.slow", url: url, detail: String(format: "%.1f seconds", Double(page.result.milliseconds) / 1000)))
            }
            if let first = facts.blockingScripts.first {
                let n = facts.blockingScripts.count
                findings.append(Finding("perf.blocking-scripts", url: url, detail: n > 1 ? "\(n) scripts, starting with \(first)" : first))
            }

            // Images
            if !facts.imagesMissingAlt.isEmpty {
                let n = facts.imagesMissingAlt.count
                findings.append(Finding("images.alt", url: url, detail: "\(n) of \(facts.imageCount) \(facts.imageCount == 1 ? "image" : "images")"))
            }
            let unsized = facts.images.filter { !$0.hasDimensions && !$0.source.lowercased().hasSuffix(".svg") }.count
            if unsized > 0 {
                findings.append(Finding("images.dimensions", url: url, detail: "\(unsized) of \(facts.imageCount) \(facts.imageCount == 1 ? "image" : "images")"))
            }
            let weakAlt = facts.images.compactMap { image -> String? in
                guard let alt = image.alt, !alt.isEmpty else { return nil }
                let lower = alt.lowercased()
                if lower.range(of: #"\.(jpe?g|png|gif|webp|avif|svg)$"#, options: .regularExpression) != nil { return alt }
                if Self.genericAltText.contains(lower) { return alt }
                return alt.count > 250 ? "\(alt.prefix(40))… (\(alt.count) characters)" : nil
            }
            if let example = weakAlt.first {
                findings.append(Finding("images.alt-quality", url: url, detail: weakAlt.count > 1 ? "“\(example)” and \(weakAlt.count - 1) more" : "“\(example)”"))
            }
            if facts.images.first?.lazy == true { findings.append(Finding("images.first-lazy", url: url)) }
            if url.scheme == "https", let first = facts.insecureResources.first {
                let more = facts.insecureResources.count - 1
                findings.append(Finding("mixed.content", url: url, detail: more > 0 ? "\(first) and \(more) more" : first))
            }
            for image in facts.images {
                guard !image.source.isEmpty, let imageURL = Self.resolve(image.source, base: base) else { continue }
                pageImages[imageURL.absoluteString, default: (imageURL, [])].pages.append(url)
            }

            // Sharing
            let image = facts.social["og:image"] ?? facts.social["twitter:image"]
            var shareImage: String?
            if let image, let imageURL = URL(string: image, relativeTo: base)?.absoluteURL {
                shareImage = imageURL.absoluteString
                if !hostIsStaging, Self.isStaging(imageURL.host ?? "") {
                    findings.append(Finding("staging.leftovers", url: url, detail: "share image → \(imageURL.absoluteString)"))
                }
                shareImages[imageURL.absoluteString, default: (imageURL, [])].pages.append(url)
            } else {
                findings.append(Finding("social.image.missing", url: url))
            }
            let missingText = ["og:title", "og:description"].filter { facts.social[$0] == nil }
            if !missingText.isEmpty {
                findings.append(Finding("social.text.missing", url: url, detail: "no " + missingText.joined(separator: " or ")))
            }
            if facts.social["twitter:card"] == nil { findings.append(Finding("social.twitter.missing", url: url)) }
            if let shared = facts.social["og:url"], let sharedURL = URL(string: shared, relativeTo: base)?.absoluteURL {
                if !hostIsStaging, Self.isStaging(sharedURL.host ?? "") {
                    findings.append(Finding("staging.leftovers", url: url, detail: "og:url → \(shared)"))
                } else if let canonicalURL, Self.key(sharedURL) != Self.key(canonicalURL) {
                    findings.append(Finding("social.url.mismatch", url: url, detail: "og:url is \(shared)"))
                }
            }

            // Structured data
            let schema = SchemaInspector.inspect(facts.jsonLD)
            if !facts.jsonLD.isEmpty || facts.hasMicrodata { anyStructuredData = true }
            for issue in schema.issues { findings.append(Finding(issue.check, url: url, detail: issue.detail)) }

            // Hreflang
            if !facts.alternates.isEmpty {
                var targets: [String: String] = [:]
                var invalid: [String] = []
                for alternate in facts.alternates {
                    if let problem = Hreflang.problem(with: alternate.hreflang) { invalid.append(problem) }
                    if let target = URL(string: alternate.href, relativeTo: base)?.absoluteURL { targets[Self.key(target)] = alternate.hreflang.lowercased() }
                }
                if let first = invalid.first {
                    findings.append(Finding("hreflang.invalid", url: url, detail: invalid.count > 1 ? "\(first), and \(invalid.count - 1) more" : first))
                }
                alternates[pageKey] = (url, targets)
            }

            // Links
            var stagingLinks: [String] = []
            var internalKeys = Set<String>()
            var emptyLinks = 0
            var generic: [String] = []
            var insecure: [String] = []
            for link in facts.anchors {
                guard let target = Self.resolve(link.href, base: base) else { continue }
                if link.text.isEmpty { emptyLinks += 1 }
                if Self.genericLinkText.contains(link.text.lowercased()) { generic.append(link.text) }
                if url.scheme == "https", target.scheme == "http" { insecure.append(target.absoluteString) }
                if !hostIsStaging, Self.isLeftoverLink(target.host ?? "", onWebflow: facts.isWebflow) {
                    stagingLinks.append(target.absoluteString)
                    continue
                }
                if Self.sameSite(target.host ?? "", host) { internalKeys.insert(Self.key(target)) }
                linkTargets[Self.key(target), default: (target, [])].sources.append(url)
            }
            outgoing[pageKey] = internalKeys
            if let first = stagingLinks.first {
                let more = Set(stagingLinks).count - 1
                findings.append(Finding("staging.leftovers", url: url, detail: more > 0 ? "link → \(first) and \(more) more" : "link → \(first)"))
            }
            if emptyLinks > 0 { findings.append(Finding("links.empty", url: url, detail: emptyLinks == 1 ? "1 link" : "\(emptyLinks) links")) }
            if let first = generic.first {
                findings.append(Finding("links.generic", url: url, detail: generic.count > 1 ? "“\(first)” and \(generic.count - 1) more" : "“\(first)”"))
            }
            if let first = insecure.first {
                let more = Set(insecure).count - 1
                findings.append(Finding("links.insecure", url: url, detail: more > 0 ? "\(first) and \(more) more" : first))
            }

            summaries.append(PageSummary(
                url: url.absoluteString, status: page.result.status, title: facts.title, description: facts.description,
                canonical: canonicalURL?.absoluteString, robots: facts.robots.isEmpty ? nil : facts.robots.sorted().joined(separator: ", "),
                h1: facts.headings.filter { $0.level == 1 }.map(\.text), h2: facts.headings.filter { $0.level == 2 }.map(\.text),
                words: facts.wordCount, images: facts.imageCount, milliseconds: page.result.milliseconds, bytes: page.result.body.count,
                indexable: indexable, schemaTypes: schema.types, shareTitle: facts.social["og:title"],
                shareDescription: facts.social["og:description"], shareImage: shareImage,
                hasShareTags: facts.social.keys.contains { $0.hasPrefix("og:") }))
        }

        for (title, urls) in titles.sorted(by: { $0.key < $1.key }) where urls.count > 1 {
            findings.append(Finding("title.duplicate", url: urls[0], detail: "“\(loaded.first { $0.result.finalURL == urls[0] }?.facts?.title ?? title)” on \(urls.count) pages: \(Self.paths(urls))"))
        }
        for (_, urls) in descriptions.sorted(by: { $0.key < $1.key }) where urls.count > 1 {
            findings.append(Finding("description.duplicate", url: urls[0], detail: "same description on \(urls.count) pages: \(Self.paths(urls))"))
        }
        if !anyStructuredData {
            findings.append(Finding("schema.missing", url: root))
            skipped.formUnion(["schema.invalid", "schema.incomplete", "schema.placeholder", "schema.deprecated"])
        }

        // Hreflang sets, now that every page's tags are known
        if alternates.isEmpty {
            skipped.formUnion(["hreflang.invalid", "hreflang.self", "hreflang.return", "hreflang.x-default"])
        } else {
            for (pageKey, entry) in alternates.sorted(by: { $0.key < $1.key }) {
                if entry.targets[pageKey] == nil { findings.append(Finding("hreflang.self", url: entry.url)) }
                if !entry.targets.values.contains("x-default") { findings.append(Finding("hreflang.x-default", url: entry.url)) }
                for (target, language) in entry.targets.sorted(by: { $0.key < $1.key }) where target != pageKey {
                    // Only pages that were read can be checked for the link back.
                    guard checkedKeys.contains(target), alternates[target]?.targets[pageKey] == nil else { continue }
                    findings.append(Finding("hreflang.return", url: entry.url, detail: "the \(language) version at \(target) does not link back"))
                }
            }
        }

        // Links, share images and page images that have not been loaded yet
        try Task.checkCancellation()
        var pending: [(key: String, url: URL)] = []
        let sortedTargets = linkTargets.sorted { $0.key < $1.key }
        for (key, target) in sortedTargets where statuses[key] == nil && Self.sameSite(target.url.host ?? "", host) {
            pending.append((key, target.url))
        }
        if options.checkExternalLinks {
            for (key, target) in sortedTargets where statuses[key] == nil && !Self.sameSite(target.url.host ?? "", host) {
                pending.append((key, target.url))
            }
        } else {
            skipped.insert("links.external")
        }
        for (_, image) in shareImages.sorted(by: { $0.key < $1.key }) where statuses[Self.key(image.url)] == nil {
            pending.append((key: Self.key(image.url), url: image.url))
        }
        var seenPending = Set<String>()
        pending = Array(pending.filter { seenPending.insert($0.key).inserted }.prefix(options.maxLinkChecks))

        let sortedImages = pageImages.sorted { $0.key < $1.key }
        var imagePending: [(key: String, url: URL)] = []
        if options.checkImages {
            for (_, image) in sortedImages where statuses[Self.key(image.url)] == nil && !seenPending.contains(Self.key(image.url)) {
                imagePending.append((Self.key(image.url), image.url))
            }
            imagePending = Array(imagePending.prefix(options.maxImageChecks))
        } else {
            skipped.formUnion(["images.broken", "images.heavy", "images.large"])
        }

        for (phase, batch) in [("Checking links", pending), ("Weighing images", imagePending)] where !batch.isEmpty {
            let counter = Counter()
            let total = batch.count
            progress(AuditProgress(phase: phase, done: 0, total: total))
            let checked = await concurrentMap(batch, limit: options.concurrency * 2) { item -> (String, FetchResult) in
                let result = await self.fetcher.fetch(item.url, bodyWanted: false)
                progress(AuditProgress(phase: phase, done: counter.next(), total: total))
                return (item.key, result)
            }
            for (key, result) in checked { statuses[key] = result }
            try Task.checkCancellation()
        }

        func broken(_ result: FetchResult) -> Bool {
            result.status == 0 || (result.status >= 400 && ![401, 403, 429].contains(result.status))
        }

        var missingFromSitemap = 0
        for (key, target) in sortedTargets {
            guard let result = statuses[key] else { continue }
            let sourceCount = Set(target.sources).count
            let pagesNote = sourceCount > 1 ? ", linked from \(sourceCount) pages" : ""
            if Self.sameSite(target.url.host ?? "", host) {
                if broken(result) {
                    findings.append(Finding("links.internal", url: target.sources[0],
                                            detail: "\(target.url.absoluteString) \(Self.describe(result))\(pagesNote)"))
                } else {
                    let finalKey = Self.key(result.finalURL)
                    if result.redirected, finalKey != key {
                        findings.append(Finding("links.redirect", url: target.sources[0],
                                                detail: "\(target.url.absoluteString) → \(result.finalURL.absoluteString)\(pagesNote)"))
                    }
                    if hasSitemap, !truncated, result.ok, result.isHTML, Self.sameSite(result.finalURL.host ?? "", host),
                       !listed.contains(key), !listed.contains(finalKey), finalKey != Self.key(root), !Self.isFile(target.url) {
                        missingFromSitemap += 1
                        if missingFromSitemap <= 25 { findings.append(Finding("sitemap.incomplete", url: target.url)) }
                    }
                }
            } else if options.checkExternalLinks {
                // Other sites often turn robots away; only call a link broken when the page is plainly gone.
                if result.status == 404 || result.status == 410 || result.error == "The address does not exist" {
                    findings.append(Finding("links.external", url: target.sources[0],
                                            detail: "\(target.url.absoluteString) \(Self.describe(result))\(pagesNote)"))
                }
            }
        }
        if missingFromSitemap > 25 { findings.append(Finding("sitemap.incomplete", detail: "and \(missingFromSitemap - 25) more")) }

        // Redirects on this site: long ones and temporary ones
        var seenRedirects = Set<String>()
        for (_, result) in statuses.sorted(by: { $0.key < $1.key }) where result.redirected && Self.sameSite(result.url.host ?? "", host) {
            guard seenRedirects.insert(Self.key(result.url)).inserted else { continue }
            if result.redirects.count > 1 {
                let path = ([result.url] + result.redirects).map(\.absoluteString).joined(separator: " → ")
                findings.append(Finding("redirect.chain", url: result.url, detail: "\(result.redirects.count) hops: \(path)"))
            }
            if let temporary = result.redirectStatuses.first(where: { $0 == 302 || $0 == 307 }) {
                findings.append(Finding("redirect.temporary", url: result.url, detail: "answers with \(temporary), then goes to \(result.finalURL.absoluteString)"))
            }
        }

        for (_, image) in shareImages.sorted(by: { $0.key < $1.key }) {
            guard let result = statuses[Self.key(image.url)], broken(result) else { continue }
            let note = image.pages.count > 1 ? ", used on \(image.pages.count) pages" : ""
            findings.append(Finding("social.image.broken", url: image.pages[0], detail: "\(image.url.absoluteString) \(Self.describe(result))\(note)"))
        }
        if options.checkImages {
            for (_, image) in sortedImages {
                guard let result = statuses[Self.key(image.url)] else { continue }
                let used = Set(image.pages).count
                let note = used > 1 ? ", on \(used) pages" : ""
                if broken(result) {
                    findings.append(Finding("images.broken", url: image.pages[0], detail: "\(image.url.absoluteString) \(Self.describe(result))\(note)"))
                } else if let bytes = Int(result.headers["content-length"] ?? ""), bytes > 200_000 {
                    findings.append(Finding(bytes > 500_000 ? "images.heavy" : "images.large", url: image.pages[0],
                                            detail: "\(Self.size(bytes)): \(image.url.absoluteString)\(note)"))
                }
            }
        }

        // How pages connect: who links to whom, and how far each is from the home page
        let homeKey = Self.key(home.finalURL)
        func destination(_ key: String) -> String {
            statuses[key].map { Self.key($0.finalURL) } ?? key
        }
        var inbound: [String: Int] = [:]
        for (source, targets) in outgoing {
            for target in Set(targets.map(destination)) where target != source { inbound[target, default: 0] += 1 }
        }
        var depth: [String: Int] = [homeKey: 0]
        var frontier = [homeKey]
        while !frontier.isEmpty {
            var next: [String] = []
            for key in frontier {
                for target in (outgoing[key] ?? []).map(destination) where depth[target] == nil && checkedKeys.contains(target) {
                    depth[target] = (depth[key] ?? 0) + 1
                    next.append(target)
                }
            }
            frontier = next
        }
        for index in summaries.indices {
            let key = URL(string: summaries[index].url).map(Self.key) ?? ""
            summaries[index].depth = depth[key]
            summaries[index].inboundLinks = inbound[key] ?? 0
        }
        if truncated {
            // With only part of the site read, "nothing links here" and "far from home" cannot be told.
            skipped.formUnion(["page.orphan", "page.deep", "sitemap.incomplete"])
        } else {
            for page in loaded {
                let key = Self.key(page.result.finalURL)
                guard key != homeKey else { continue }
                if hasSitemap, page.inSitemap, inbound[key] == nil {
                    findings.append(Finding("page.orphan", url: page.result.finalURL))
                } else if let clicks = depth[key], clicks > 3 {
                    findings.append(Finding("page.deep", url: page.result.finalURL, detail: "\(clicks) clicks from the home page"))
                }
            }
        }

        // The site as a whole
        progress(AuditProgress(phase: "Checking the domain"))
        if root.scheme == "https", let plain = URL(string: "http://\(host)/") {
            let result = await fetcher.fetch(plain, bodyWanted: false)
            if result.ok, result.finalURL.scheme == "http" {
                findings.append(Finding("https.redirect", url: plain, detail: "answers with \(result.status) and no redirect"))
            }

            let hsts = (home.headers["strict-transport-security"] ?? "").lowercased()
            if hsts.isEmpty {
                findings.append(Finding("security.hsts", url: root))
            } else if let age = hsts.range(of: #"max-age=\s*(\d+)"#, options: .regularExpression).map({ hsts[$0] }),
                      Int(age.filter(\.isNumber)) == 0 {
                findings.append(Finding("security.hsts", url: root, detail: "max-age is 0, which switches it off"))
            }
            let policy = (home.headers["content-security-policy"] ?? "").lowercased()
            var missing: [String] = []
            if (home.headers["x-content-type-options"] ?? "").lowercased() != "nosniff" { missing.append("X-Content-Type-Options: nosniff") }
            if home.headers["x-frame-options"] == nil, !policy.contains("frame-ancestors") { missing.append("X-Frame-Options, or frame-ancestors in a Content-Security-Policy") }
            if policy.isEmpty { missing.append("Content-Security-Policy") }
            if home.headers["referrer-policy"] == nil { missing.append("Referrer-Policy") }
            for header in missing { findings.append(Finding("security.headers", url: root, detail: header)) }
        } else {
            skipped.formUnion(["https.redirect", "security.hsts", "security.headers"])
        }
        if home.headers["content-encoding"] == nil, home.body.count > 2_000 {
            findings.append(Finding("perf.uncompressed", url: root, detail: "\(Self.size(home.body.count)) of HTML sent as is"))
        }

        let twin: String? = host.hasPrefix("www.") ? String(host.dropFirst(4)) : (host.split(separator: ".").count == 2 ? "www.\(host)" : nil)
        if let twin, let twinURL = URL(string: "\(root.scheme ?? "https")://\(twin)/") {
            let result = await fetcher.fetch(twinURL, bodyWanted: true)
            if result.ok, result.finalURL.host?.lowercased() == twin.lowercased() {
                // A canonical pointing at the main address is an acceptable way to merge the two.
                let canonicalHost = HTMLScanner.scan(result.body).canonical.flatMap { URL(string: $0)?.host?.lowercased() }
                if canonicalHost != host.lowercased() {
                    findings.append(Finding("host.duplicate", url: twinURL, detail: "\(twin) and \(host) both serve the site"))
                }
            }
        } else {
            skipped.insert("host.duplicate")
        }

        let missing = root.appendingPathComponent("launchcheck-\(UUID().uuidString.prefix(8).lowercased())")
        let missingResult = await fetcher.fetch(missing, bodyWanted: false)
        if missingResult.ok {
            findings.append(Finding("notfound.soft", url: missing, detail: "a made-up address answers with \(missingResult.status)"))
        }

        if homePage.facts?.hasFavicon != true {
            let icon = await fetcher.fetch(root.appendingPathComponent("favicon.ico"), bodyWanted: false)
            if !icon.ok { findings.append(Finding("favicon.missing", url: root)) }
        }

        let failed = Set(findings.map(\.check))
        let order = Dictionary(uniqueKeysWithValues: Check.all.enumerated().map { ($1.id, $0) })
        let sorted = findings.enumerated().sorted { a, b in
            let x = order[a.element.check] ?? .max, y = order[b.element.check] ?? .max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)

        return Report(site: root.absoluteString,
                      date: started,
                      pagesChecked: loaded.count,
                      pagesFound: max(pagesFound, loaded.count),
                      linksChecked: linkTargets.count,
                      seconds: Date().timeIntervalSince(started),
                      findings: sorted,
                      passed: Check.all.map(\.id).filter { !failed.contains($0) && !skipped.contains($0) },
                      pages: summaries)
    }

    // MARK: Pieces

    private func load(_ url: URL, inSitemap: Bool) async -> Page {
        let result = await fetcher.fetch(url, bodyWanted: true)
        let facts = result.ok && result.isHTML ? HTMLScanner.scan(result.body) : nil
        return Page(url: url, result: result, facts: facts, inSitemap: inSitemap)
    }

    private func internalLinks(of page: Page, host: String) -> [URL] {
        guard let facts = page.facts else { return [] }
        let base = facts.base.flatMap { URL(string: $0, relativeTo: page.result.finalURL)?.absoluteURL } ?? page.result.finalURL
        return facts.links.compactMap { href in
            guard let url = Self.resolve(href, base: base), Self.sameSite(url.host ?? "", host), !Self.isFile(url) else { return nil }
            return url
        }
    }

    /// Turns what someone typed ("example.com", "https://example.com/about") into the address to start from.
    public static func siteURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, host.contains(".") || host == "localhost" else { return nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }

    /// Resolves a link the way a browser would, or nil for anything that is not a web page (mailto:, tel:, #top).
    static func resolve(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil
        return parts.url ?? url
    }

    /// One identity per page: no fragment, no trailing slash, lowercased host.
    static func key(_ url: URL) -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        let query = url.query.map { "?\($0)" } ?? ""
        return "\(url.scheme?.lowercased() ?? "https")://\(url.host?.lowercased() ?? "")\(url.port.map { ":\($0)" } ?? "")\(path)\(query)"
    }

    static func sameSite(_ a: String, _ b: String) -> Bool {
        func bare(_ host: String) -> String {
            let lower = host.lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        return !a.isEmpty && bare(a) == bare(b)
    }

    /// A link that should not have survived to the live site: one to a local machine, or, on a Webflow site,
    /// one to a webflow.io address (elsewhere that is more likely a deliberate link to someone's showcase).
    static func isLeftoverLink(_ host: String, onWebflow: Bool) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "127.0.0.1" || lower.hasSuffix(".local") || lower.hasSuffix(".test") { return true }
        return onWebflow && lower.hasSuffix(".webflow.io")
    }

    /// Preview and staging hosts. Fine to link to, wrong as a canonical or share image.
    static func isStaging(_ host: String) -> Bool {
        let lower = host.lowercased()
        let suffixes = [".webflow.io", ".vercel.app", ".netlify.app", ".pages.dev", ".framer.app", ".framer.website", ".wpengine.com",
                        ".wpenginepowered.com", ".kinsta.cloud", ".herokuapp.com", ".ngrok.io", ".ngrok-free.app", ".local", ".test"]
        return lower == "localhost" || lower == "127.0.0.1" || lower.hasPrefix("staging.") || suffixes.contains { lower.hasSuffix($0) }
    }

    private static func isFile(_ url: URL) -> Bool {
        let extensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "ico", "zip", "mp4", "mov", "webm",
                                       "mp3", "wav", "css", "js", "json", "xml", "txt", "csv", "doc", "docx", "xls", "xlsx", "ppt",
                                       "pptx", "dmg", "woff", "woff2"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    private static func describe(_ result: FetchResult) -> String {
        result.status == 0 ? "did not load (\(result.error ?? "no answer"))" : "returned \(result.status)"
    }

    private static func paths(_ urls: [URL]) -> String {
        let shown = urls.prefix(4).map { $0.path.isEmpty ? "/" : $0.path }.joined(separator: ", ")
        return urls.count > 4 ? "\(shown) and \(urls.count - 4) more" : shown
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(Int((Double(bytes) / 1000).rounded())) KB"
    }
}

// MARK: Concurrency helpers

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Runs `body` over every item with at most `limit` in flight, keeping the results in order.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    guard !items.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(max(1, limit), items.count) {
            let index = next
            next += 1
            group.addTask { (index, await body(items[index])) }
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if next < items.count {
                let following = next
                next += 1
                group.addTask { (following, await body(items[following])) }
            }
        }
        return results.compactMap { $0 }
    }
}
