import XCTest
@testable import LaunchcheckCore

/// Previews, the HTML report, the checklist and the structured data rules for a marketing site.
final class ShareTests: XCTestCase {
    private func summary(_ path: String = "/", title: String? = "Acme Rockets", description: String? = "Rockets and anvils.",
                         tags: [String: String]? = [:], indexable: Bool = true) -> PageSummary {
        PageSummary(url: "https://www.acme.com" + path, status: 200, title: title, description: description, indexable: indexable, shareTags: tags)
    }

    // MARK: Previews

    func testCutsTextTheWayASearchResultDoes() {
        let short = PagePreview.clip("Acme Rockets: anvils and rockets", to: PagePreview.titleWidth)
        XCTAssertFalse(short.isCut)
        XCTAssertEqual(short.shown, "Acme Rockets: anvils and rockets")

        let long = PagePreview.clip("Pricing for rockets, anvils and giant magnets from Acme Rockets of Arizona", to: PagePreview.titleWidth)
        XCTAssertTrue(long.isCut)
        XCTAssertTrue(long.shown.hasSuffix(" ..."))
        let kept = String(long.shown.dropLast(4))
        XCTAssertTrue(long.full.hasPrefix(kept))
        XCTAssertTrue(long.full.dropFirst(kept.count).hasPrefix(" ") || long.full.dropFirst(kept.count).hasPrefix(","), "cut at the end of a word: \(long.shown)")
        XCTAssertLessThanOrEqual(PagePreview.width(of: long.shown), PagePreview.titleWidth)
        XCTAssertTrue((50...64).contains(kept.count), "an ordinary title is cut at about 60 characters, not \(kept.count)")

        // By width, not by count: the same number of wide letters is cut sooner.
        let wide = PagePreview.clip(String(repeating: "W", count: 45), to: PagePreview.titleWidth)
        let narrow = PagePreview.clip(String(repeating: "i", count: 45), to: PagePreview.titleWidth)
        XCTAssertTrue(wide.isCut)
        XCTAssertFalse(narrow.isCut)
        XCTAssertLessThan(wide.shown.count, 40, "one long word is cut where it runs out of room")

        let sentence = "Rockets, anvils and everything a determined coyote could need, delivered to your canyon by next-day air. "
        let description = PagePreview.clip(sentence + sentence, to: PagePreview.descriptionWidth)
        XCTAssertTrue(description.isCut)
        XCTAssertTrue((140...170).contains(description.shown.count), "a description is cut at about 155 characters, not \(description.shown.count)")
        XCTAssertFalse(PagePreview.clip(String(sentence.dropLast()), to: PagePreview.descriptionWidth).isCut)
        XCTAssertEqual(PagePreview.clip("  two   spaces\n and a line break ", to: 30).shown, "two spaces and a line break")
    }

    func testDrawsASearchResult() {
        let page = summary("/blog/launch%20day/", title: "Launch day", description: "What we shipped.", tags: ["og:site_name": "Acme"])
        let snippet = PagePreview.search(for: page, host: "www.acme.com")
        XCTAssertEqual(snippet.breadcrumb, "https://www.acme.com › blog › launch day")
        XCTAssertEqual(snippet.siteName, "Acme")
        XCTAssertEqual(snippet.title?.shown, "Launch day")
        XCTAssertEqual(snippet.notes, [])
        XCTAssertEqual(PagePreview.search(for: summary(), host: "www.acme.com").siteName, "acme.com")
        XCTAssertEqual(PagePreview.breadcrumb(for: "https://acme.com/"), "https://acme.com")

        let bare = PagePreview.search(for: summary(title: " ", description: nil, indexable: false), host: "acme.com")
        XCTAssertNil(bare.title)
        XCTAssertNil(bare.description)
        XCTAssertEqual(bare.notes.map(\.label), ["No title", "No description", "Noindex"])
        XCTAssertEqual(bare.notes.map(\.tag), ["title", "description", nil])

        let long = PagePreview.search(for: summary(title: String(repeating: "Rockets and anvils ", count: 6)), host: "acme.com")
        XCTAssertEqual(long.notes.map(\.kind), [.cut])
        XCTAssertTrue(long.notes[0].text.contains("\(long.title?.full.count ?? 0) characters"))
    }

    func testLinkCardsFallBackInOrder() {
        // Everything written out: Open Graph for chat apps, the twitter: tags on X.
        let full = summary(tags: ["og:title": "OG title", "og:description": "OG words", "og:image": "https://www.acme.com/og.png", "og:site_name": "Acme",
                                  "twitter:card": "summary_large_image", "twitter:title": "X title", "twitter:image": "https://www.acme.com/x.png"])
        let chat = PagePreview.card(for: full, host: "www.acme.com", on: .chat)
        XCTAssertEqual([chat.title, chat.description, chat.image, chat.siteName], ["OG title", "OG words", "https://www.acme.com/og.png", "Acme"])
        XCTAssertEqual(chat.layout, .large)
        XCTAssertEqual(chat.notes, [])
        let x = PagePreview.card(for: full, host: "www.acme.com", on: .x)
        XCTAssertEqual([x.title, x.description, x.image], ["X title", "OG words", "https://www.acme.com/x.png"])
        XCTAssertEqual(x.layout, .large)
        XCTAssertEqual(x.notes.map(\.label), ["Differs on X"])
        XCTAssertTrue(x.notes[0].text.contains("title and picture"))

        // Nothing but a title and a description: Open Graph borrows them, X borrows from Open Graph, and both say what to add.
        let plain = summary(tags: [:])
        let borrowed = PagePreview.card(for: plain, host: "www.acme.com", on: .chat)
        XCTAssertEqual([borrowed.title, borrowed.description, borrowed.image, borrowed.siteName], ["Acme Rockets", "Rockets and anvils.", nil, "acme.com"])
        XCTAssertEqual(borrowed.notes.map(\.kind), [.fallback, .fallback, .missing])
        XCTAssertEqual(borrowed.notes.map(\.tag), ["og:title", "og:description", "og:image"])
        let small = PagePreview.card(for: plain, host: "www.acme.com", on: .x)
        XCTAssertEqual([small.title, small.description, small.image], ["Acme Rockets", "Rockets and anvils.", nil])
        XCTAssertEqual(small.layout, .thumbnail)
        XCTAssertEqual(small.notes.map(\.tag), ["twitter:card", "og:image"])

        // twitter:card decides the shape; twitter:image alone gives X a picture that chat apps do not get.
        let summaryCard = summary(tags: ["og:title": "T", "og:description": "D", "twitter:card": "summary", "twitter:image": "https://www.acme.com/x.png"])
        XCTAssertEqual(PagePreview.card(for: summaryCard, host: "acme.com", on: .x).layout, .thumbnail)
        XCTAssertEqual(PagePreview.card(for: summaryCard, host: "acme.com", on: .x).image, "https://www.acme.com/x.png")
        XCTAssertNil(PagePreview.card(for: summaryCard, host: "acme.com", on: .chat).image)

        // Nothing at all.
        let empty = PagePreview.card(for: summary(title: nil, description: nil), host: "acme.com", on: .chat)
        XCTAssertNil(empty.title)
        XCTAssertEqual(empty.notes.map(\.kind), [.missing, .missing, .missing])

        // One list per page, most pressing first, each thing said once.
        XCTAssertEqual(PagePreview.notes(for: plain, host: "acme.com").map(\.label), ["No image", "Title borrowed", "Description borrowed", "No twitter:card"])
        XCTAssertEqual(PagePreview.notes(for: full, host: "acme.com").map(\.label), ["Differs on X"])
    }

    func testJudgesASharePictureByItsSize() {
        XCTAssertNil(PagePreview.imageNote(width: 1200, height: 630, layout: .large))
        XCTAssertNil(PagePreview.imageNote(width: 2400, height: 1260, layout: .large))
        XCTAssertEqual(PagePreview.imageNote(width: 400, height: 210, layout: .large)?.label, "Small picture")
        XCTAssertEqual(PagePreview.imageNote(width: 1200, height: 1200, layout: .large)?.label, "Picture cropped")
        XCTAssertNil(PagePreview.imageNote(width: 1200, height: 1200, layout: .thumbnail))
        XCTAssertEqual(PagePreview.imageNote(width: 100, height: 100, layout: .thumbnail)?.label, "Small picture")
        XCTAssertNil(PagePreview.imageNote(width: 0, height: 0, layout: .large))
    }

    func testReportsKeptBeforeShareTagsStillPreview() throws {
        let kept = """
        {"url":"https://acme.com/a","status":200,"title":"A","h1":[],"h2":[],"words":1,"images":0,"milliseconds":1,"bytes":1,"indexable":true,
         "inboundLinks":0,"schemaTypes":[],"shareTitle":"Old share title","shareImage":"https://acme.com/og.png","hasShareTags":true}
        """
        let page = try JSONDecoder().decode(PageSummary.self, from: Data(kept.utf8))
        XCTAssertNil(page.shareTags)
        let card = PagePreview.card(for: page, host: "acme.com", on: .chat)
        XCTAssertEqual(card.title, "Old share title")
        XCTAssertEqual(card.image, "https://acme.com/og.png")
        XCTAssertEqual(card.notes.map(\.label), ["No description"])
    }

    func testAuditsKeepTheShareTags() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        let head = "<meta property=\"og:site_name\" content=\"Acme\"><meta name=\"twitter:image\" content=\"/x.png\">"
        web.answers = ["\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", head: head))]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        let tags = try XCTUnwrap(report.pages.first?.shareTags)
        XCTAssertEqual(tags["og:image"], "\(root)/share.png", "image addresses are made absolute")
        XCTAssertEqual(tags["twitter:image"], "\(root)/x.png")
        XCTAssertEqual(tags["og:site_name"], "Acme")
        XCTAssertEqual(tags["twitter:card"], "summary_large_image")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Report.self, from: Data(ReportFormat.json(report).utf8)).pages, report.pages)
    }

    // MARK: HTML report

    func testWritesTheWholeReportAsOneHTMLFile() {
        let pages = [PageSummary(url: "https://acme.com/", status: 200, title: "Home <b>bold</b> & \"quoted\"", words: 640),
                     PageSummary(url: "https://acme.com/about", status: 200, title: nil, words: 90, indexable: false)]
        let report = Report(site: "https://acme.com/", date: Date(timeIntervalSince1970: 1_700_000_000), pagesChecked: 2, pagesFound: 2, linksChecked: 7, seconds: 1.26,
                            findings: [Finding("page.noindex", url: URL(string: "https://acme.com/about"), detail: "robots meta tag"),
                                       Finding("title.duplicate", url: URL(string: "https://acme.com/"), detail: "“<script>alert('x')</script>” on 2 pages"),
                                       Finding("lang.missing", url: URL(string: "https://acme.com/"))],
                            passed: ["title.missing", "h1.missing"], pages: pages, builtWith: "Webflow")
        let html = ReportFormat.html(report, handled: ["lang.missing"])

        // The verdict, the score, the counts.
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<h1>1 thing to fix before launch</h1>"))
        XCTAssertTrue(html.contains("Score \(report.score) of 100, Not ready"))
        XCTAssertTrue(html.contains("<b>1</b> to fix before launch"))
        XCTAssertTrue(html.contains("<b>1</b> should fix"))
        XCTAssertTrue(html.contains("<b>2</b> passed"))
        XCTAssertTrue(html.contains("2 pages and 7 links checked in 1.3s"))
        XCTAssertTrue(html.contains("1 of 3 handled"))

        // Every issue, with when it is done and how to fix it, and where in Webflow for a Webflow site.
        for group in report.groups {
            XCTAssertTrue(html.contains(ReportFormat.escape(group.check.title)), group.id)
            XCTAssertTrue(html.contains("<dt>Done when</dt><dd>\(ReportFormat.escape(group.check.passed))</dd>"), group.id)
            XCTAssertTrue(html.contains("<dt>How to fix</dt><dd>\(ReportFormat.escape(group.check.fix ?? ""))</dd>"), group.id)
        }
        XCTAssertTrue(html.contains("<dt>In Webflow</dt><dd>Page settings → SEO settings"))
        XCTAssertTrue(html.contains("<article class=\"issue handled\" id=\"lang.missing\">"))
        XCTAssertTrue(html.contains("robots meta tag"))
        XCTAssertTrue(html.contains("Every page has a title"))

        // The page list.
        XCTAssertTrue(html.contains("<a href=\"https://acme.com/about\">/about</a>"))
        XCTAssertTrue(html.contains("No title"))
        XCTAssertTrue(html.contains("noindex"))

        // Nothing from the site gets through as markup.
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<b>bold</b>"))
        XCTAssertTrue(html.contains("Home &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot;"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))

        // Nothing is fetched: no scripts, images, stylesheets or fonts, and the only links are to pages.
        for needle in ["<img", "<link", "<iframe", "@import", "url(", "src=", "@font-face"] {
            XCTAssertFalse(html.contains(needle), "the report must not load anything: \(needle)")
        }
        XCTAssertTrue(html.contains("prefers-color-scheme:dark"))
        XCTAssertTrue(html.contains("@media print"))

        // Without Webflow, no Webflow advice; without ticks, no count of them.
        var plain = report
        plain.builtWith = nil
        XCTAssertFalse(ReportFormat.html(plain).contains("In Webflow"))
        XCTAssertFalse(ReportFormat.html(plain).contains("of 3 handled"))
    }

    func testTheHTMLReportNeverLinksToAScript() {
        let report = Report(site: "https://acme.com/", pagesChecked: 1, pagesFound: 1, linksChecked: 0, seconds: 1,
                            findings: [Finding("sitemap.offsite", url: URL(string: "javascript:alert(1)"), detail: "\" onmouseover=\"alert(1)")],
                            passed: [], pages: [PageSummary(url: "javascript:alert(2)", status: 200, title: "T")])
        let html = ReportFormat.html(report)
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("\" onmouseover=\""))
        XCTAssertTrue(html.contains("&quot; onmouseover=&quot;alert(1)"))
        XCTAssertEqual(ReportFormat.escape("<a href='x'>&\"</a>"), "&lt;a href=&#39;x&#39;&gt;&amp;&quot;&lt;/a&gt;")
    }

    // MARK: Checklist

    private func report(failing: [String], passed: [String] = [], day: Double = 1) -> Report {
        Report(site: "https://acme.com/", date: Date(timeIntervalSince1970: day * 86_400), pagesChecked: 1, pagesFound: 1, linksChecked: 0, seconds: 1,
               findings: failing.map { Finding($0, url: URL(string: "https://acme.com/")) }, passed: passed)
    }

    func testTicksAreCountedSortedAndDroppedWhenTheIssueIsGone() {
        let first = report(failing: ["page.noindex", "images.alt", "lang.missing", "images.heavy"])
        var list = Checklist()
        XCTAssertEqual(list.progress(in: first).handled, 0)
        list.toggle("images.alt")
        list.toggle("lang.missing")
        list.toggle("images.heavy")
        list.toggle("title.missing")                    // not failing in this report
        XCTAssertTrue(list.isHandled("images.alt"))
        XCTAssertEqual(list.progress(in: first).handled, 3)
        XCTAssertEqual(list.progress(in: first).total, 4)
        XCTAssertEqual(list.handled(in: first), ["images.alt", "lang.missing", "images.heavy"])

        // Still to do first, handled after, each in the report's own order.
        let split = list.split(first.groups)
        XCTAssertEqual(split.open.map(\.id), ["page.noindex"])
        XCTAssertEqual(split.handled.map(\.id), ["images.alt", "images.heavy", "lang.missing"])

        // The next check: alt text is fixed, the language still fails, images were not weighed this time.
        let second = report(failing: ["page.noindex", "lang.missing"], passed: ["images.alt", "title.missing"], day: 2)
        let carried = list.carried(past: second)
        XCTAssertEqual(Set(carried.handled.keys), ["lang.missing", "images.heavy"], "a fixed issue loses its tick; one that did not run keeps it")
        XCTAssertEqual(carried.handled["lang.missing"], list.handled["lang.missing"], "the tick keeps its date")

        // If the problem comes back, it comes back unticked.
        let third = report(failing: ["images.alt"], day: 3)
        XCTAssertFalse(carried.carried(past: third).isHandled("images.alt"))
        XCTAssertFalse(Checklist(handled: ["no.such-check": Date()]).carried(past: third).isHandled("no.such-check"))

        list.toggle("images.alt")
        XCTAssertFalse(list.isHandled("images.alt"))
    }

    func testTheChecklistIsKeptBesideTheHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launchcheck-checklist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = History(directory: directory)

        // History written before there was a checklist: reports only. It loads, and its checklist is empty.
        for day in 1...13 { history.save(report(failing: ["lang.missing"], day: Double(day))) }
        XCTAssertEqual(history.reports(for: "acme.com").count, 12)
        XCTAssertEqual(history.checklist(for: "acme.com"), Checklist())

        var list = Checklist()
        list.set("lang.missing", handled: true, at: Date(timeIntervalSince1970: 500))
        history.save(list, for: "acme.com")
        XCTAssertEqual(History(directory: directory).checklist(for: "acme.com"), list, "remembered across launches")

        // The checklist file is not mistaken for a report, and does not take a report's place among the twelve kept.
        XCTAssertEqual(history.reports(for: "acme.com").count, 12)
        history.save(report(failing: ["lang.missing"], day: 20))
        XCTAssertEqual(history.reports(for: "acme.com").count, 12)
        XCTAssertEqual(history.latest(for: "acme.com")?.date, Date(timeIntervalSince1970: 20 * 86_400))
        XCTAssertEqual(history.sites().map(\.host), ["acme.com"])
        XCTAssertEqual(history.checklist(for: "acme.com"), list)

        // A file that cannot be read is an empty checklist, not a crash.
        try Data("not json".utf8).write(to: directory.appendingPathComponent("acme.com/handled.checklist"))
        XCTAssertEqual(history.checklist(for: "acme.com"), Checklist())

        // Unticking the last one removes the file; nothing is written for a site with no reports; deleting the site takes the ticks with it.
        history.save(list, for: "acme.com")
        history.save(Checklist(), for: "acme.com")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("acme.com/handled.checklist").path))
        history.save(list, for: "never-checked.com")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("never-checked.com").path))
        history.save(list, for: "acme.com")
        for kept in history.reports(for: "acme.com") { history.remove(kept) }
        XCTAssertEqual(history.checklist(for: "acme.com"), Checklist())
        XCTAssertTrue(history.sites().isEmpty)
    }

    // MARK: Structured data

    func testChecksTheTypesAMarketingSiteUses() {
        func issues(_ json: String) -> [String] {
            SchemaInspector.inspect([json]).issues.map { "\($0.check): \($0.detail)" }
        }
        let context = "\"@context\":\"https://schema.org\""

        // A healthy site: a graph with an organisation, a site, a page and a trail, and references between them.
        let healthy = """
        {\(context),"@graph":[
          {"@type":"Organization","@id":"#org","name":"Acme","url":"https://acme.com/","logo":{"@type":"ImageObject","url":"https://acme.com/logo.png"}},
          {"@type":"WebSite","@id":"#site","name":"Acme","url":"https://acme.com/","publisher":{"@id":"#org"}},
          {"@type":"BlogPosting","headline":"Launch day","image":"https://acme.com/a.png","datePublished":"2026-01-02",
           "author":{"@type":"Person","name":"Wile"},"publisher":{"@type":"Organization","name":"Acme"}},
          {"@type":"BreadcrumbList","itemListElement":[
            {"@type":"ListItem","position":1,"name":"Blog","item":"https://acme.com/blog"},
            {"@type":"ListItem","position":2,"name":"Launch day"}]},
          {"@type":"Product","name":"Anvil","image":"https://acme.com/anvil.png","description":"Heavy.",
           "offers":{"@type":"Offer","price":"10","priceCurrency":"USD"}},
          {"@id":"#org"}
        ]}
        """
        XCTAssertEqual(issues(healthy), [])
        // A person and a site, the shape of a portfolio: nothing to say.
        XCTAssertEqual(issues("{\(context),\"@type\":\"Person\",\"name\":\"B\",\"worksFor\":{\"@type\":\"Organization\",\"name\":\"Studio\"}}"), [])
        XCTAssertEqual(issues("[{\(context),\"@type\":\"WebSite\",\"url\":\"https://acme.com\",\"name\":\"Acme\"}]"), [])

        // Recommended properties are notices, and only for items that stand on their own.
        XCTAssertEqual(issues("{\(context),\"@type\":\"Organization\",\"name\":\"Acme\"}"),
                       ["schema.recommended: Organization has no url", "schema.recommended: Organization has no logo"])
        XCTAssertEqual(issues("{\(context),\"@type\":\"Article\",\"headline\":\"H\",\"author\":\"\"}"),
                       ["schema.recommended: Article has no image", "schema.recommended: Article has no datePublished", "schema.recommended: Article has no author"])
        XCTAssertEqual(issues("{\(context),\"@type\":[\"BlogPosting\"],\"headline\":\"H\",\"image\":\"i\",\"datePublished\":\"2026-01-02\",\"author\":{\"@id\":\"#me\"}}"), [])
        XCTAssertEqual(issues("{\(context),\"@type\":\"Product\",\"name\":\"N\",\"image\":\"i\",\"offers\":{\"@type\":\"Offer\",\"price\":1,\"priceCurrency\":\"USD\"}}"),
                       ["schema.recommended: Product has no description"])

        // Required ones are warnings.
        XCTAssertEqual(issues("{\(context),\"@type\":\"WebSite\"}"), ["schema.incomplete: WebSite has no url", "schema.recommended: WebSite has no name"])
        XCTAssertEqual(issues("{\(context),\"@type\":\"BreadcrumbList\",\"itemListElement\":[{\"position\":1,\"name\":\"Blog\"},{\"position\":2,\"name\":\"Post\"}]}"),
                       ["schema.incomplete: BreadcrumbList items before the last need an item address"])
        XCTAssertTrue(issues("{\(context),\"@type\":\"FAQPage\"}").contains("schema.incomplete: FAQPage has no mainEntity"))
        XCTAssertTrue(issues("{\(context),\"@type\":\"FAQPage\",\"mainEntity\":[{\"@type\":\"Question\",\"name\":\"Why?\",\"acceptedAnswer\":{\"@type\":\"Answer\"}}]}")
            .contains("schema.incomplete: FAQPage questions need a name and an acceptedAnswer with text"))
        let faq = issues("{\(context),\"@type\":\"FAQPage\",\"mainEntity\":{\"@type\":\"Question\",\"name\":\"Why?\",\"acceptedAnswer\":{\"@type\":\"Answer\",\"text\":\"Because.\"}}}")
        XCTAssertEqual(faq.filter { $0.hasPrefix("schema.incomplete") }, [])

        // A newspaper that says an article is part of a paid publication is not selling a product with no picture.
        XCTAssertEqual(issues("{\(context),\"@type\":\"NewsArticle\",\"headline\":\"H\",\"image\":\"https://acme.com/i.png\",\"datePublished\":\"2026-01-02\",\"author\":\"A\",\"isAccessibleForFree\":false,\"isPartOf\":{\"@type\":[\"CreativeWork\",\"Product\"],\"name\":\"The Paper\",\"productID\":\"paper.com:basic\"}}"), [])

        // Naming a type.
        XCTAssertEqual(issues("{\(context),\"@graph\":[{\"name\":\"Nameless\"}]}"), ["schema.incomplete: an item in @graph has no @type"])
        XCTAssertEqual(issues("{\(context),\"@type\":\" \",\"name\":\"x\"}"), ["schema.incomplete: a JSON-LD block has no @type"])

        // JSON that does not parse says where, when the parser knows; valid JSON that is not an object is no better.
        let broken = issues("{\(context),\n\"@type\":\"Organization\"\n\"name\":\"Acme\"}")
        XCTAssertEqual(broken.count, 1)
        XCTAssertTrue(broken[0].hasPrefix("schema.invalid: a JSON-LD block is not valid JSON"), broken[0])
        // A comma before a closing bracket is the usual slip, and some parsers wave it through. It is said plainly, with its line.
        XCTAssertEqual(issues("{\(context),\n\"@type\":\"Organization\",\n\"name\":\"Acme, Inc. [US],\",\n}"),
                       ["schema.invalid: a JSON-LD block has a comma before a closing bracket, on line 3"])
        XCTAssertNil(SchemaInspector.trailingComma(in: "{\"a\":[1, 2],\"b\":\",]\",\"c\":{}}"))
        XCTAssertEqual(issues("\"just a string\""), ["schema.invalid: a JSON-LD block holds no object"])

        XCTAssertEqual(Check.named("schema.invalid")?.severity, .warning)
        XCTAssertEqual(Check.named("schema.recommended")?.severity, .notice)
        XCTAssertEqual(Check.named("schema.recommended")?.category, .structured)
    }

    func testRecommendedPropertiesReachTheReportAsANotice() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        let script = "<script type=\"application/ld+json\">{\"@context\":\"https://schema.org\",\"@type\":\"Organization\",\"name\":\"Acme\",\"url\":\"\(root)/\"}</script>"
        web.answers = ["\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", head: script))]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        XCTAssertEqual(report.findings.filter { $0.check.hasPrefix("schema.") }, [Finding("schema.recommended", url: URL(string: "\(root)/"), detail: "Organization has no logo")])
        XCTAssertTrue(report.passed.contains("schema.incomplete"))
        XCTAssertFalse(report.passed.contains("schema.recommended"))

        // With no structured data at all, the one notice is that there is none.
        web.answers["\(root)/"] = .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/"))
        let bare = try await Auditor(fetcher: web).run("www.acme.com")
        XCTAssertEqual(bare.findings.filter { $0.check.hasPrefix("schema.") }.map(\.check), ["schema.missing"])
        XCTAssertFalse(bare.passed.contains("schema.recommended"))
    }
}
