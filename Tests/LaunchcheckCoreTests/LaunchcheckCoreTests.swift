import XCTest
@testable import LaunchcheckCore

/// A pretend web: addresses mapped to canned answers, so audits run without the network.
final class StubFetcher: Fetcher, @unchecked Sendable {
    struct Answer {
        var status = 200
        var type = "text/html; charset=utf-8"
        var body = ""
        var redirect: String?
        var headers: [String: String] = [:]
    }

    var answers: [String: Answer] = [:]
    /// Sent with every answer; a well-configured server by default.
    var defaultHeaders: [String: String] = [
        "content-encoding": "br", "strict-transport-security": "max-age=63072000", "x-content-type-options": "nosniff",
        "x-frame-options": "DENY", "content-security-policy": "default-src 'self'", "referrer-policy": "strict-origin-when-cross-origin",
    ]
    /// What an address nobody defined answers with.
    var fallbackStatus = 404
    /// Hosts that do not exist at all.
    var deadHosts: Set<String> = []

    func fetch(_ url: URL, bodyWanted: Bool) async -> FetchResult {
        var current = url
        var redirects: [URL] = []
        for _ in 0..<8 {
            if deadHosts.contains(current.host ?? "") {
                return FetchResult(url: url, finalURL: current, status: 0, redirects: redirects, error: "The address does not exist")
            }
            guard let answer = answers[current.absoluteString] else {
                return FetchResult(url: url, finalURL: current, status: fallbackStatus, headers: ["content-type": "text/html"], redirects: redirects)
            }
            if let target = answer.redirect, let next = URL(string: target, relativeTo: current)?.absoluteURL {
                redirects.append(next)
                current = next
                continue
            }
            var headers = defaultHeaders.merging(answer.headers) { _, own in own }
            headers["content-type"] = answer.type
            return FetchResult(url: url, finalURL: current, status: answer.status, headers: headers,
                               body: bodyWanted ? Data(answer.body.utf8) : Data(), redirects: redirects)
        }
        return FetchResult(url: url, finalURL: current, status: 0, redirects: redirects, error: "Too many redirects")
    }
}

let filler = "<p>" + Array(repeating: "Plain words that say something useful about the subject at hand.", count: 24).joined(separator: " ") + "</p>"

func page(title: String?, description: String? = "A perfectly reasonable description of what this page is about, for search results.",
          canonical: String?, head: String = "", body: String = "<h1>Heading</h1>", lang: Bool = true, complete: Bool = true) -> String {
    var html = lang ? "<!doctype html><html lang=\"en\"><head>" : "<html><head>"
    if let title { html += "<title>\(title)</title>" }
    if let description { html += "<meta name=\"description\" content=\"\(description)\">" }
    if let canonical { html += "<link rel=\"canonical\" href=\"\(canonical)\">" }
    if complete {
        html += "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
        html += "<meta property=\"og:title\" content=\"T\"><meta property=\"og:description\" content=\"D\">"
        html += "<meta property=\"og:image\" content=\"/share.png\"><meta name=\"twitter:card\" content=\"summary_large_image\">"
    }
    return html + head + "</head><body>" + body + (complete ? filler : "") + "</body></html>"
}

final class LaunchcheckCoreTests: XCTestCase {
    // MARK: HTML

    func testScansAPage() {
        let html = """
        <!DOCTYPE html>
        <!-- <title>Not this</title> -->
        <html lang="en-GB" data-wf-site="abc">
        <head>
          <TITLE>  Rockets &amp; anvils &#8211; Acme  </TITLE>
          <meta name="description" content="Fast &quot;rockets&quot;.">
          <meta name=robots content="NOINDEX, follow">
          <meta property="og:image" content="https://acme.com/og.png">
          <meta name="twitter:card" content="summary_large_image">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <link rel="shortcut icon" href="/favicon.png">
          <link rel='canonical' href='https://acme.com/'>
          <script>var s = "<h1>not a heading</h1><a href='/nope'>x</a>";</script>
          <style>h1 { content: "<img src=x>" }</style>
        </head>
        <body>
          <svg><title>Icon</title></svg>
          <h1>One</h1><H1 class="x">Two</H1>
          <a href="/about">About</a> <a href='mailto:hi@acme.com'>Mail</a> <a>No href</a>
          <img src="/a.png" alt="A"> <img src="/b.png" alt=""> <img src="http://cdn.acme.com/c.png">
          <img src="/d.png" aria-hidden="true">
          <p>Lorem <b>ipsum</b> dolor sit amet. 2 < 3</p>
        </body></html>
        """
        let facts = HTMLScanner.scan(html)

        XCTAssertEqual(facts.title, "Rockets & anvils – Acme")
        XCTAssertEqual(facts.description, "Fast \"rockets\".")
        XCTAssertEqual(facts.robots, ["noindex", "follow"])
        XCTAssertEqual(facts.canonical, "https://acme.com/")
        XCTAssertEqual(facts.lang, "en-GB")
        XCTAssertEqual(facts.h1Count, 2)
        XCTAssertTrue(facts.hasViewport)
        XCTAssertTrue(facts.hasFavicon)
        XCTAssertTrue(facts.isWebflow)
        XCTAssertEqual(facts.social["og:image"], "https://acme.com/og.png")
        XCTAssertEqual(facts.social["twitter:card"], "summary_large_image")
        XCTAssertEqual(facts.links, ["/about", "mailto:hi@acme.com"])
        XCTAssertEqual(facts.imageCount, 4)
        XCTAssertEqual(facts.imagesMissingAlt, ["http://cdn.acme.com/c.png"])
        XCTAssertEqual(facts.insecureResources, ["http://cdn.acme.com/c.png"])
        XCTAssertTrue(facts.hasPlaceholderText)
    }

    func testScannerSurvivesBrokenMarkup() {
        XCTAssertEqual(HTMLScanner.scan("").title, nil)
        XCTAssertEqual(HTMLScanner.scan("<title>Unclosed").title, nil)
        XCTAssertEqual(HTMLScanner.scan("<a href=\"/x").links, ["/x"])
        XCTAssertEqual(HTMLScanner.scan("<script>never closed <h1>").h1Count, 0)
        XCTAssertEqual(HTMLScanner.scan("< <<h1>ok</h1> <!-- open").h1Count, 1)
        // Addresses in attributes are entity-encoded and must be decoded before they are requested.
        XCTAssertEqual(HTMLScanner.scan("<img src=\"/i?url=a.png&amp;w=96\" alt=\"\">").images.first?.source, "/i?url=a.png&w=96")
        XCTAssertEqual(HTMLScanner.scan("<head><script src=\"/a.js\" nomodule></script><script src=\"/b.js\"></script></head>").blockingScripts, ["/b.js"])
        XCTAssertFalse(HTMLScanner.scan("<p>All fine here</p>").hasPlaceholderText)
    }

    // MARK: robots.txt and sitemaps

    func testReadsRobots() {
        let robots = Robots("""
        # hello
        User-agent: Googlebot
        Disallow: /private

        User-agent: *
        Disallow: /admin
        Allow: /admin/help
        Disallow: /*.pdf$
        Sitemap: https://acme.com/sitemap.xml
        """)
        XCTAssertEqual(robots.sitemaps, ["https://acme.com/sitemap.xml"])
        XCTAssertTrue(robots.blocks("/admin/users"))
        XCTAssertFalse(robots.blocks("/admin/help/faq"))
        XCTAssertFalse(robots.blocks("/private"))
        XCTAssertFalse(robots.blocks("/"))
        XCTAssertTrue(robots.blocks("/files/menu.pdf"))
        XCTAssertFalse(robots.blocks("/files/menu.pdf?download"))
        XCTAssertFalse(robots.blocksEverything)

        XCTAssertTrue(Robots("User-agent: *\nDisallow: /").blocksEverything)
        XCTAssertFalse(Robots("User-agent: *\nDisallow:").blocksEverything)
        XCTAssertFalse(Robots("User-agent: BadBot\nDisallow: /").blocksEverything)
        XCTAssertTrue(Robots("User-agent: a\nUser-agent: *\nDisallow: /").blocksEverything)
    }

    func testReadsSitemaps() {
        let pages = SitemapParser.parse(Data("""
        <?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc> https://acme.com/ </loc><lastmod>2026-01-01</lastmod></url>
        <url><loc>https://acme.com/a?x=1&amp;y=2</loc></url></urlset>
        """.utf8))
        XCTAssertEqual(pages.pages, ["https://acme.com/", "https://acme.com/a?x=1&y=2"])
        XCTAssertTrue(pages.sitemaps.isEmpty)

        let index = SitemapParser.parse(Data("<sitemapindex><sitemap><loc>https://acme.com/s1.xml</loc></sitemap></sitemapindex>".utf8))
        XCTAssertEqual(index.sitemaps, ["https://acme.com/s1.xml"])
        XCTAssertEqual(SitemapParser.parse(Data("<html>not a sitemap</html>".utf8)), SitemapContents())
    }

    // MARK: Addresses

    func testUnderstandsAddresses() {
        XCTAssertEqual(Auditor.siteURL(from: " acme.com ")?.absoluteString, "https://acme.com/")
        XCTAssertEqual(Auditor.siteURL(from: "http://acme.com/x")?.absoluteString, "http://acme.com/x")
        XCTAssertNil(Auditor.siteURL(from: "not a site"))
        XCTAssertNil(Auditor.siteURL(from: "acme"))
        XCTAssertNil(Auditor.siteURL(from: ""))

        let base = URL(string: "https://acme.com/blog/post")!
        XCTAssertEqual(Auditor.resolve("../about#team", base: base)?.absoluteString, "https://acme.com/about")
        XCTAssertEqual(Auditor.resolve("//cdn.acme.com/x", base: base)?.absoluteString, "https://cdn.acme.com/x")
        XCTAssertNil(Auditor.resolve("#top", base: base))
        XCTAssertNil(Auditor.resolve("mailto:a@b.co", base: base))
        XCTAssertNil(Auditor.resolve("tel:+123", base: base))
        XCTAssertNil(Auditor.resolve("javascript:void(0)", base: base))

        XCTAssertEqual(Auditor.key(URL(string: "https://ACME.com/about/")!), Auditor.key(URL(string: "https://acme.com/about#x")!))
        XCTAssertNotEqual(Auditor.key(URL(string: "https://acme.com/a?p=1")!), Auditor.key(URL(string: "https://acme.com/a")!))
        XCTAssertTrue(Auditor.sameSite("www.acme.com", "ACME.com"))
        XCTAssertFalse(Auditor.sameSite("shop.acme.com", "acme.com"))
        XCTAssertTrue(Auditor.isStaging("acme.webflow.io"))
        XCTAssertFalse(Auditor.isStaging("acme.com"))
        XCTAssertTrue(Auditor.isLeftoverLink("friend.webflow.io", onWebflow: true))
        XCTAssertFalse(Auditor.isLeftoverLink("friend.webflow.io", onWebflow: false))
        XCTAssertTrue(Auditor.isLeftoverLink("localhost", onWebflow: false))
    }

    // MARK: Whole audits

    private func messySite() -> StubFetcher {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        let wf = "<meta name=\"generator\" content=\"Webflow\">"
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme makes rockets and anvils", canonical: "\(root)/", head: wf,
                                         body: "<h1>Acme</h1><a href=\"/missing\">x</a><a href=\"https://acme.webflow.io/x\">s</a><a href=\"https://gone.example.org/page\">g</a><a href=\"https://nowhere.example.net/\">n</a><a href=\"/about\">a</a>")),
            "\(root)/about": .init(body: page(title: "About the Acme company", description: nil, canonical: nil,
                                              body: "<p>Lorem ipsum dolor</p><img src=\"http://www.acme.com/a.png\"><a href=\"/missing\">x</a>", lang: false, complete: false)
                .replacingOccurrences(of: "<head>", with: "<head><meta name=\"robots\" content=\"noindex\">")),
            "\(root)/pricing": .init(body: page(title: "Pricing for rockets and anvils", description: "What it costs to buy a rocket or an anvil from Acme, in plain numbers.",
                                                canonical: "https://acme.webflow.io/pricing")
                .replacingOccurrences(of: "/share.png", with: "/og-missing.png")),
            "\(root)/contact": .init(body: page(title: "Acme makes rockets and anvils", description: "How to reach the people at Acme who answer questions about rockets.",
                                                canonical: "\(root)/contact", body: "<h1>One</h1><h1>Two</h1>")),
            "\(root)/old": .init(redirect: "\(root)/pricing"),
            "\(root)/share.png": .init(type: "image/png"),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nDisallow: /about\nSitemap: \(root)/sitemap.xml"),
            "\(root)/sitemap.xml": .init(type: "application/xml", body: """
                <urlset><url><loc>\(root)/</loc></url><url><loc>\(root)/about</loc></url><url><loc>\(root)/pricing</loc></url>
                <url><loc>\(root)/contact</loc></url><url><loc>\(root)/old</loc></url><url><loc>\(root)/dead</loc></url>
                <url><loc>https://acme.webflow.io/x</loc></url></urlset>
                """),
            "http://www.acme.com/": .init(body: "<html></html>"),
            "https://acme.com/": .init(body: page(title: "Acme makes rockets and anvils", canonical: nil)),
            "https://nowhere.example.net/": .init(status: 403),
        ]
        web.deadHosts = ["dns-gone.example.org"]
        return web
    }

    func testNoticesAServerThatNeverSays404() async throws {
        // Answers 200 to anything, including the made-up address the audit asks for.
        final class Soft404: Fetcher, @unchecked Sendable {
            let inner: StubFetcher
            init(_ inner: StubFetcher) { self.inner = inner }
            func fetch(_ url: URL, bodyWanted: Bool) async -> FetchResult {
                url.path.hasPrefix("/launchcheck-") ? FetchResult(url: url, status: 200) : await inner.fetch(url, bodyWanted: bodyWanted)
            }
        }
        let report = try await Auditor(fetcher: Soft404(messySite())).run("https://www.acme.com")
        XCTAssertTrue(report.findings.contains { $0.check == "notfound.soft" })
        XCTAssertFalse(report.passed.contains("notfound.soft"))
    }

    func testFindsEverythingWrongWithAMessySite() async throws {
        let report = try await Auditor(fetcher: messySite()).run("https://www.acme.com")
        let failed = Set(report.findings.map(\.check))
        let expected: Set<String> = [
            "page.noindex", "sitemap.broken", "sitemap.offsite", "staging.leftovers", "links.internal", "social.image.broken",
            "sitemap.redirects", "sitemap.blocked", "title.duplicate", "description.missing", "canonical.missing", "h1.missing",
            "social.image.missing", "images.alt", "viewport.missing", "links.external", "mixed.content", "placeholder.text",
            "https.redirect", "host.duplicate", "h1.multiple", "social.text.missing", "lang.missing", "favicon.missing",
            // and what the wider set of checks adds for the same site
            "images.broken", "images.dimensions", "doctype.missing", "sitemap.noindex", "social.twitter.missing", "page.orphan",
            "schema.missing", "ai.llms-missing",
        ]
        XCTAssertEqual(failed, expected, "unexpected: \(failed.subtracting(expected).sorted()), missing: \(expected.subtracting(failed).sorted())")

        XCTAssertEqual(report.site, "https://www.acme.com/")
        XCTAssertEqual(report.pagesChecked, 4)
        XCTAssertEqual(report.pagesFound, 6)
        XCTAssertEqual(report.verdict, "7 things to fix before launch")
        XCTAssertTrue(report.passed.contains("robots.blocks-all"))
        XCTAssertTrue(report.passed.contains("notfound.soft"))
        XCTAssertFalse(report.passed.contains("page.noindex"))

        func details(_ check: String) -> [String] { report.findings.filter { $0.check == check }.map { ReportFormat.line($0, site: report.site) } }
        XCTAssertEqual(details("page.noindex"), ["/about  robots meta tag"])
        XCTAssertEqual(details("sitemap.broken"), ["/dead  returned 404"])
        XCTAssertEqual(details("sitemap.redirects"), ["/old  redirects to https://www.acme.com/pricing"])
        XCTAssertEqual(details("links.internal"), ["/  https://www.acme.com/missing returned 404, linked from 2 pages"])
        XCTAssertEqual(details("links.external"), ["/  https://gone.example.org/page returned 404"])
        XCTAssertEqual(details("staging.leftovers"), ["/  link → https://acme.webflow.io/x", "/pricing  canonical → https://acme.webflow.io/pricing"])
        XCTAssertEqual(details("title.duplicate"), ["/  “Acme makes rockets and anvils” on 2 pages: /, /contact"])
        XCTAssertEqual(details("images.alt"), ["/about  1 of 1 image"])
        XCTAssertEqual(details("social.image.broken"), ["/pricing  https://www.acme.com/og-missing.png returned 404"])
        XCTAssertEqual(details("host.duplicate"), ["https://acme.com/  acme.com and www.acme.com both serve the site"])

        // Findings come out most serious first.
        let severities = report.groups.map(\.check.severity)
        XCTAssertEqual(severities, severities.sorted())
    }

    func testPassesATidySite() async throws {
        let web = StubFetcher()
        let root = "https://www.tidy.com"
        let icon = "<link rel=\"icon\" href=\"/icon.png\"><script type=\"application/ld+json\">{\"@context\":\"https://schema.org\",\"@type\":\"Organization\",\"name\":\"Tidy\"}</script>"
        web.answers = [
            "\(root)/a.png": .init(type: "image/png", headers: ["content-length": "48000"]),
            "\(root)/llms.txt": .init(type: "text/plain", body: "# Tidy\n\n> Keeps things in order.\n\n## Pages\n\n- [About](https://www.tidy.com/about): who we are\n"),
            "\(root)/": .init(body: page(title: "Tidy keeps things in order", canonical: "\(root)/", head: icon, body: "<h1>Tidy</h1><a href=\"/about/\">About</a>")),
            "\(root)/about": .init(body: page(title: "About the people at Tidy", description: "Who we are, where we work and why we like things to be kept in good order.",
                                              canonical: "\(root)/about", head: icon, body: "<h1>About</h1><a href=\"/\">Home</a><img src=\"/a.png\" alt=\"\" width=\"40\" height=\"40\">")),
            "\(root)/share.png": .init(type: "image/png"),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nAllow: /\nSitemap: \(root)/sitemap.xml"),
            "\(root)/sitemap.xml": .init(type: "application/xml", body: "<urlset><url><loc>\(root)/</loc></url><url><loc>\(root)/about</loc></url></urlset>"),
            "http://www.tidy.com/": .init(redirect: "\(root)/"),
            "https://tidy.com/": .init(redirect: "\(root)/"),
        ]

        let report = try await Auditor(fetcher: web).run("tidy.com")
        XCTAssertEqual(report.findings, [])
        XCTAssertEqual(report.site, "https://www.tidy.com/")
        XCTAssertEqual(report.pagesChecked, 2)
        XCTAssertEqual(report.verdict, "Ready to launch")
        // Everything passes except the hreflang checks, which do not apply to a site in one language.
        XCTAssertEqual(Set(Check.all.map(\.id)).subtracting(report.passed), ["hreflang.invalid", "hreflang.self", "hreflang.return", "hreflang.x-default"])
        XCTAssertEqual(report.score, 100)
        XCTAssertNil(report.categoryScores.first { $0.category == .international }?.score)
        XCTAssertEqual(report.pages.map(\.url), ["https://www.tidy.com/", "https://www.tidy.com/about"])
        XCTAssertEqual(report.pages[1].depth, 1)
        XCTAssertEqual(report.pages[1].inboundLinks, 1)
        XCTAssertEqual(report.pages[0].schemaTypes, ["Organization"])
        XCTAssertGreaterThan(report.pages[0].words, 200)
    }

    func testFollowsLinksWhenThereIsNoSitemap() async throws {
        let web = StubFetcher()
        let root = "https://plain.org"
        func simple(_ title: String, _ path: String, _ body: String) -> StubFetcher.Answer {
            .init(body: page(title: title, description: "A description for \(title) that is comfortably long enough to pass.", canonical: root + path,
                             head: "<link rel=\"icon\" href=\"/i.png\">", body: "<h1>\(title)</h1>" + body))
        }
        web.answers = [
            "\(root)/": simple("The plain home page", "/", "<a href=\"/one\">1</a><a href=\"/file.pdf\">pdf</a>"),
            "\(root)/one": simple("The first plain page", "/one", "<a href=\"/two\">2</a><a href=\"/\">home</a>"),
            "\(root)/two": simple("The second plain page", "/two", "<a href=\"/three\">3</a><a href=\"/gone\">gone</a>"),
            "\(root)/three": simple("The third plain page", "/three", ""),
            "\(root)/file.pdf": .init(type: "application/pdf"),
            "\(root)/share.png": .init(type: "image/png"),
            "http://plain.org/": .init(redirect: "\(root)/"),
            "https://www.plain.org/": .init(redirect: "\(root)/"),
        ]

        let report = try await Auditor(fetcher: web).run("plain.org")
        XCTAssertEqual(report.pagesChecked, 4)
        XCTAssertEqual(Set(report.findings.map(\.check)), ["robots.missing", "sitemap.missing", "links.internal", "schema.missing", "ai.llms-missing"])
        XCTAssertFalse(report.passed.contains("sitemap.broken"), "sitemap checks cannot pass without a sitemap")

        var limited = Options()
        limited.maxPages = 2
        let short = try await Auditor(fetcher: web, options: limited).run("plain.org")
        XCTAssertEqual(short.pagesChecked, 2)
        XCTAssertGreaterThan(short.pagesFound, 2)
    }

    func testReportsSitesItCannotReach() async {
        let web = StubFetcher()
        web.deadHosts = ["nothing.example"]
        do {
            _ = try await Auditor(fetcher: web).run("nothing.example")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AuditError, .unreachable("nothing.example", "The address does not exist"))
        }
        do {
            _ = try await Auditor(fetcher: web).run("two words")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AuditError, .invalidAddress("two words"))
        }
    }

    func testFindsTheSubtlerProblems() async throws {
        let web = StubFetcher()
        web.defaultHeaders = [:]                  // a server with nothing configured
        let root = "https://shop.example.com"
        let schema = """
        <script type="application/ld+json">{"@context":"https://schema.org","@graph":[
          {"@type":"Product","name":"Anvil","offers":{"@type":"Offer","price":"10"}},
          {"@type":"HowTo","name":"[Business Name]"},
          {"@type":"BreadcrumbList","itemListElement":[{"@type":"ListItem","name":"Home"}]}]}</script>
        <script type="application/ld+json">{ not json </script>
        """
        let alternates = "<link rel=\"alternate\" hreflang=\"en-uk\" href=\"\(root)/\"><link rel=\"alternate\" hreflang=\"de\" href=\"\(root)/de\">"
        func simple(_ title: String, _ path: String, head: String = "", _ body: String) -> StubFetcher.Answer {
            .init(body: page(title: title, description: "A description for \(title) that is comfortably long enough to pass.", canonical: root + path,
                             head: "<link rel=\"icon\" href=\"/i.png\">" + head, body: "<h1>\(title)</h1>" + body))
        }
        web.answers = [
            "\(root)/": simple("The shop that sells anvils", "/", head: schema + alternates + "<script src=\"/app.js\"></script>",
                               "<h3>Skipped</h3><a href=\"/a\">click here</a><a href=\"/a\"><img src=\"/big.jpg\" width=\"1\" height=\"1\" loading=\"lazy\"></a>"
                               + "<a href=\"/moved\">Moved page</a><a href=\"/de\">Deutsch</a><a href=\"http://old.example.org/\">Old site</a><img src=\"/mid.jpg\" alt=\"IMG_2041.jpg\" width=\"1\" height=\"1\">"),
            "\(root)/de": simple("Der Laden mit den Ambossen", "/de", "<a href=\"/\">Start</a>"),
            "\(root)/a": simple("Page A leads to page B", "/a", "<a href=\"/b\">Page B</a>"),
            "\(root)/b": simple("Page B leads to page C", "/b", "<a href=\"/c\">Page C</a>"),
            "\(root)/c": simple("Page C leads to page D", "/c", "<a href=\"/Deep_Page\">Page D</a>"),
            "\(root)/Deep_Page": .init(body: "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>The deepest page of all</title></head><body><div id=\"root\"></div></body></html>"),
            "\(root)/moved": .init(redirect: "\(root)/moved-again"),
            "\(root)/moved-again": .init(redirect: "\(root)/a"),
            "\(root)/big.jpg": .init(type: "image/jpeg", headers: ["content-length": "900000"]),
            "\(root)/mid.jpg": .init(type: "image/jpeg", headers: ["content-length": "300000"]),
            "\(root)/share.png": .init(type: "image/png"),
            "\(root)/llms.txt": .init(type: "text/plain", body: "just some words"),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nAllow: /\n\nUser-agent: PerplexityBot\nDisallow: /\n\nUser-agent: GPTBot\nDisallow: /"),
            "http://old.example.org/": .init(body: "<html></html>"),
        ]

        let report = try await Auditor(fetcher: web).run(root)
        func details(_ check: String) -> [String] { report.findings.filter { $0.check == check }.map { ReportFormat.line($0, site: report.site) } }

        // AI search: the answer engine's crawler is flagged, the training crawler is not.
        XCTAssertEqual(details("ai.search-blocked"), ["/robots.txt  PerplexityBot is disallowed"])
        XCTAssertEqual(details("ai.llms-invalid"), ["/llms.txt  no “# Title” line, no Markdown links, under 50 characters"])

        XCTAssertEqual(details("schema.invalid"), ["/  a JSON-LD block is not valid JSON"])
        XCTAssertEqual(Set(details("schema.incomplete")), ["/  Product has no image", "/  Product offer has a price but no priceCurrency",
                                                           "/  BreadcrumbList items need a position and a name"])
        XCTAssertEqual(details("schema.deprecated"), ["/  HowTo: rich results removed in September 2023"])
        XCTAssertEqual(details("schema.placeholder"), ["/  “[Business Name]”"])

        XCTAssertEqual(details("hreflang.invalid"), ["/  “uk” is not a region code; Britain is GB"])
        XCTAssertEqual(details("hreflang.x-default").count, 1)
        XCTAssertEqual(details("hreflang.return"), ["/  the de version at https://shop.example.com/de does not link back"])
        XCTAssertTrue(report.passed.contains("hreflang.self"))

        XCTAssertEqual(details("heading.skip"), ["/  H1 is followed by H3: “Skipped”"])
        XCTAssertEqual(details("links.generic"), ["/  “click here”"])
        XCTAssertEqual(details("links.empty"), ["/  1 link"])
        XCTAssertEqual(details("links.insecure"), ["/  http://old.example.org/"])
        XCTAssertEqual(details("links.redirect"), ["/  https://shop.example.com/moved → https://shop.example.com/a"])
        XCTAssertEqual(details("redirect.chain"), ["/moved  2 hops: https://shop.example.com/moved → https://shop.example.com/moved-again → https://shop.example.com/a"])
        XCTAssertEqual(details("images.heavy"), ["/  900 KB: https://shop.example.com/big.jpg"])
        XCTAssertEqual(details("images.large"), ["/  300 KB: https://shop.example.com/mid.jpg"])
        XCTAssertEqual(details("images.alt-quality"), ["/  “IMG_2041.jpg”"])
        XCTAssertEqual(details("images.first-lazy"), ["/"])
        XCTAssertEqual(details("perf.blocking-scripts"), ["/  /app.js"])
        XCTAssertEqual(details("content.js-shell"), ["/Deep_Page  0 words in the HTML"])
        XCTAssertEqual(details("url.hygiene"), ["/Deep_Page  capital letters, underscores"])
        XCTAssertEqual(details("page.deep"), ["/Deep_Page  4 clicks from the home page"])
        XCTAssertEqual(details("security.hsts"), ["/"])
        XCTAssertEqual(details("security.headers").count, 4)
        XCTAssertEqual(details("perf.uncompressed").count, 1)
        XCTAssertTrue(report.passed.contains("content.thin"))

        XCTAssertLessThan(report.score, 90)
        let scores = Dictionary(uniqueKeysWithValues: report.categoryScores.map { ($0.category, $0.score) })
        XCTAssertNotNil(scores[.international] ?? nil)
        XCTAssertLessThan((scores[.security] ?? nil) ?? 100, 85)
        XCTAssertEqual(report.count(.error), 0)
        XCTAssertEqual(report.grade, "Good")
    }

    func testReadsRobotsPerCrawler() {
        let robots = Robots("User-agent: *\nDisallow: /private\n\nUser-agent: GPTBot\nUser-agent: CCBot\nDisallow: /\n\nUser-agent: Claude-SearchBot\nAllow: /")
        XCTAssertTrue(robots.blocks("/", agent: "gptbot"))
        XCTAssertTrue(robots.blocks("/", agent: "CCBot"))
        XCTAssertFalse(robots.blocks("/", agent: "OAI-SearchBot"))
        // A crawler with its own group ignores the rules for everyone else.
        XCTAssertFalse(robots.blocks("/private", agent: "Claude-SearchBot"))
        XCTAssertTrue(robots.blocks("/private", agent: "OAI-SearchBot"))
        XCTAssertTrue(robots.names("GPTBot"))
        XCTAssertFalse(robots.names("PerplexityBot"))
    }

    func testValidatesHreflangCodes() {
        for good in ["en", "en-GB", "EN-gb", "zh-Hant", "zh-Hans-US", "x-default", "pt-BR"] {
            XCTAssertNil(Hreflang.problem(with: good), good)
        }
        for bad in ["eng", "jp", "en-UK", "en-EU", "", "en_GB", "en-GB-x-y"] {
            XCTAssertNotNil(Hreflang.problem(with: bad), bad)
        }
    }

    func testInspectsStructuredData() {
        let fine = SchemaInspector.inspect(["""
        {"@context":"https://schema.org","@type":"LocalBusiness","name":"Acme","address":{"@type":"PostalAddress","streetAddress":"1 Road"},
         "aggregateRating":{"@type":"AggregateRating","ratingValue":4.8,"reviewCount":12}}
        """])
        XCTAssertEqual(fine.issues, [])
        XCTAssertEqual(fine.types, ["LocalBusiness", "PostalAddress", "AggregateRating"])

        let broken = SchemaInspector.inspect(["{\"@type\":\"Restaurant\",\"name\":\"\"}", "[1, 2"])
        XCTAssertEqual(Set(broken.issues.map(\.detail)), ["a JSON-LD block has no @context", "Restaurant has no name", "Restaurant has no address",
                                                         "a JSON-LD block is not valid JSON"])
        XCTAssertEqual(SchemaInspector.inspect([" "]), SchemaInspector.Result())
    }

    func testComparesTwoReports() {
        func report(_ pages: [PageSummary], findings: [Finding], passed: [String], day: Double) -> Report {
            Report(site: "https://acme.com/", date: Date(timeIntervalSince1970: day * 86_400), pagesChecked: pages.count, pagesFound: pages.count,
                   linksChecked: 0, seconds: 1, findings: findings, passed: passed, pages: pages)
        }
        let home = "https://acme.com/", about = "https://acme.com/about", gone = "https://acme.com/gone", fresh = "https://acme.com/new"
        let before = report([
            PageSummary(url: home, status: 200, title: "Acme rockets", description: "Old", canonical: home, h1: ["Rockets for everyone"], schemaTypes: ["Organization"], hasShareTags: true),
            PageSummary(url: about, status: 200, title: "About", canonical: about, h1: ["About us"], h2: ["Team"]),
            PageSummary(url: gone, status: 200, title: "Gone"),
        ], findings: [Finding("title.duplicate", url: URL(string: home))], passed: ["page.noindex"], day: 1)
        let after = report([
            PageSummary(url: home + "#top", status: 200, title: "Acme  rockets", description: "New", canonical: about, h1: ["Something else entirely"], indexable: false, schemaTypes: []),
            PageSummary(url: about, status: 500, title: "About", canonical: about, h1: ["About us"]),
            PageSummary(url: fresh, status: 200, title: "New"),
        ], findings: [Finding("page.noindex", url: URL(string: home))], passed: ["title.duplicate"], day: 2)

        let comparison = Drift.compare(before, after)
        XCTAssertEqual(comparison.fixed.map(\.id), ["title.duplicate"])
        XCTAssertEqual(comparison.introduced.map(\.id), ["page.noindex"])
        XCTAssertEqual(comparison.pagesAdded, [fresh])
        XCTAssertEqual(comparison.pagesRemoved, [gone])
        XCTAssertEqual(comparison.changes.filter { $0.level == .critical }.map(\.summary),
                       ["Noindex added", "Structured data removed", "Canonical changed", "H1 changed", "Stopped loading"])
        XCTAssertEqual(comparison.changes.filter { $0.level == .warning }.map(\.summary), ["Meta description changed", "Share tags removed"])
        XCTAssertTrue(Drift.compare(before, before).isEmpty)
        XCTAssertEqual(Drift.similarity("kitten", "sitting"), 1 - 3.0 / 7, accuracy: 0.001)
    }

    func testKeepsHistoryPerSite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launchcheck-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = History(directory: directory)
        XCTAssertNil(history.latest(for: "acme.com"))

        for day in 1...14 {
            history.save(Report(site: "https://acme.com/", date: Date(timeIntervalSince1970: Double(day) * 86_400), pagesChecked: day, pagesFound: day,
                                linksChecked: 0, seconds: 1, findings: [], passed: []))
        }
        history.save(Report(site: "https://other.org/", date: Date(timeIntervalSince1970: 99 * 86_400), pagesChecked: 1, pagesFound: 1,
                            linksChecked: 0, seconds: 1, findings: [Finding("lang.missing")], passed: []))

        XCTAssertEqual(history.latest(for: "acme.com")?.pagesChecked, 14)
        XCTAssertEqual(history.reports(for: "acme.com").count, 12, "only the most recent dozen are kept")
        XCTAssertEqual(history.sites().map(\.host), ["other.org", "acme.com"])
        XCTAssertEqual(history.latest(for: "other.org")?.findings, [Finding("lang.missing")])
        history.forget("acme.com")
        XCTAssertEqual(history.sites().map(\.host), ["other.org"])
    }

    func testScoresByAreaAndSpread() {
        func report(_ findings: [Finding], pages: Int = 10) -> Report {
            let failed = Set(findings.map(\.check))
            return Report(site: "https://acme.com/", pagesChecked: pages, pagesFound: pages, linksChecked: 0, seconds: 1, findings: findings,
                          passed: Check.all.map(\.id).filter { !failed.contains($0) })
        }
        XCTAssertEqual(report([]).score, 100)
        XCTAssertEqual(report([]).grade, "Excellent")

        let one = report([Finding("page.noindex", url: URL(string: "https://acme.com/a"))])
        let everywhere = report((0..<10).map { Finding("page.noindex", url: URL(string: "https://acme.com/\($0)")) })
        XCTAssertLessThan(everywhere.score, one.score, "the same problem on every page costs more than on one")
        XCTAssertLessThan(one.score, 100)

        let cosmetic = report([Finding("favicon.missing", url: URL(string: "https://acme.com/"))])
        XCTAssertGreaterThan(cosmetic.score, one.score, "a notice costs less than an error")
        XCTAssertEqual(one.grade, "Not ready", "no site with a launch blocker is called good")
        XCTAssertEqual(cosmetic.grade, "Excellent")
        XCTAssertEqual(Category.allCases.map(\.weight).reduce(0, +), 100)
        XCTAssertTrue(Check.all.map(\.severity) == Check.all.map(\.severity).sorted(), "the catalogue is ordered by severity")
    }

    // MARK: Formats

    func testFormatsAReport() {
        let report = Report(site: "https://acme.com/", date: Date(timeIntervalSince1970: 1_700_000_000), pagesChecked: 3, pagesFound: 10, linksChecked: 1, seconds: 1.26,
                            findings: [Finding("page.noindex", url: URL(string: "https://acme.com/about"), detail: "robots meta tag"),
                                       Finding("lang.missing", url: URL(string: "https://acme.com/"))],
                            passed: ["title.missing"])

        let text = ReportFormat.text(report)
        XCTAssertTrue(text.contains("1 thing to fix before launch"))
        XCTAssertTrue(text.contains("3 of 10 pages and 1 link checked in 1.3s"))
        XCTAssertTrue(text.contains("(Not ready)"))
        XCTAssertTrue(text.contains("✗ Pages are set to noindex (1)"))
        XCTAssertTrue(text.contains("- /about  robots meta tag"))
        XCTAssertTrue(text.contains("✓ Every page has a title"))

        let markdown = ReportFormat.markdown(report)
        XCTAssertTrue(markdown.hasPrefix("# Launch check: https://acme.com/"))
        XCTAssertTrue(markdown.contains("## Fix before launch"))
        XCTAssertTrue(markdown.contains("### Pages do not declare a language (1)"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(Report.self, from: Data(ReportFormat.json(report).utf8))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(Set(Check.all.map(\.id)).count, Check.all.count, "check IDs must be unique")
    }
}
