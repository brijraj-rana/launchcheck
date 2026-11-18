import XCTest
@testable import LaunchcheckCore

/// One area alone, one page alone, and the structured data inspector.
final class FocusedCheckTests: XCTestCase {
    private let root = "https://www.acme.com"

    private func site(listsThePost: Bool = true) -> StubFetcher {
        let web = StubFetcher()
        let schema = """
        <script type="application/ld+json">{"@context":"https://schema.org","@graph":[
          {"@type":"Organization","@id":"\(root)/#org","name":"Acme","url":"\(root)/"},
          {"@type":"BlogPosting","headline":"Launch day","datePublished":"March 3, 2026","image":"/a.png",
           "author":{"@type":"Person","name":"Wile","url":"\(root)/wile"},"publisher":{"@id":"\(root)/#org"}}]}</script>
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"Anvil",}</script>
        """
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", body: "<h1>Acme</h1><a href=\"/post\">Post</a>")),
            "\(root)/post": .init(body: page(title: "Launch day at Acme Rockets", description: "What happened on the day the rockets went up, and what came down again.",
                                             canonical: "\(root)/post", head: schema, body: "<h1>Launch day</h1><div itemscope itemtype=\"https://schema.org/Thing\"></div><img src=\"/missing.png\">")),
            "\(root)/sitemap.xml": .init(type: "application/xml", body: "<urlset><url><loc>\(root)/</loc></url>\(listsThePost ? "<url><loc>\(root)/post</loc></url>" : "")</urlset>"),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nAllow: /\nSitemap: \(root)/sitemap.xml"),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        return web
    }

    func testOneAreaAloneReportsOnlyThatArea() async throws {
        var options = Options()
        options.areas = [.structured]
        let report = try await Auditor(fetcher: site(), options: options).run("www.acme.com")
        XCTAssertEqual(report.areas, ["structured"])
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(Set(report.findings.compactMap { Check.named($0.check)?.category }), [.structured])
        XCTAssertEqual(Set(report.findings.map(\.check)), ["schema.invalid", "schema.recommended", "schema.values"])
        XCTAssertTrue(report.passed.allSatisfy { Check.named($0)?.category == .structured })
        XCTAssertEqual(report.categoryScores.filter { $0.score != nil }.map(\.category), [.structured])
        XCTAssertEqual(report.verdict, "Structured data only: 1 thing to tidy")
        XCTAssertEqual(report.scopeNote, "Only Structured data was checked. The score covers that and nothing else.")

        // The same site in full has more to say, and says it is the whole site.
        let full = try await Auditor(fetcher: site()).run("www.acme.com")
        XCTAssertNil(full.areas)
        XCTAssertFalse(full.isPartial)
        XCTAssertNil(full.scopeNote)
        XCTAssertTrue(full.findings.count > report.findings.count)

        // A full report cut down to the same area compares fairly with the partial one.
        let cut = full.restricted(to: [.structured])
        XCTAssertEqual(cut.findings, report.findings)
        XCTAssertEqual(Set(cut.passed), Set(report.passed))
        XCTAssertEqual(cut.score, report.score)
    }

    func testOnePageAloneReadsNothingElse() async throws {
        var options = Options()
        options.singlePage = true
        options.areas = [.structured, .indexing, .sitemap, .images]
        let report = try await Auditor(fetcher: site(listsThePost: false), options: options).run("www.acme.com/post")
        XCTAssertEqual(report.page, "\(root)/post")
        XCTAssertEqual(report.pages.map(\.url), ["\(root)/post"])
        XCTAssertEqual(report.pagesChecked, 1)
        XCTAssertEqual(report.site, "\(root)/")
        XCTAssertEqual(report.verdict, "4 areas, one page only: 1 thing to fix before launch")
        func details(_ check: String) -> [String] { report.findings.filter { $0.check == check }.compactMap(\.detail) }
        XCTAssertEqual(details("sitemap.incomplete"), ["this page is not in the sitemap"])
        XCTAssertEqual(details("images.broken").count, 1)
        XCTAssertEqual(details("schema.invalid"), ["a JSON-LD block has a comma before a closing bracket, on line 1"])
        XCTAssertEqual(Set(details("schema.recommended")), ["Organization has no logo"])
        XCTAssertEqual(Set(details("schema.values")), ["datePublished is “March 3, 2026”, not a date written like 2026-02-07", "image is “/a.png”, not a full address"])
        XCTAssertFalse(report.passed.contains("page.orphan"), "what only the whole site can answer is left unsaid")
        XCTAssertFalse(report.passed.contains("title.duplicate"))

        // Without the flag the same address checks the site, from its front door.
        let whole = try await Auditor(fetcher: site()).run("www.acme.com/post")
        XCTAssertNil(whole.page)
        XCTAssertEqual(whole.pages.first?.url, "\(root)/")
    }

    func testTakesStructuredDataApart() async throws {
        var options = Options()
        options.singlePage = true
        let report = try await Auditor(fetcher: site(), options: options).run("www.acme.com/post")
        let page = try XCTUnwrap(report.pages.first)
        XCTAssertEqual(page.markup, ["Microdata"])
        let blocks = try XCTUnwrap(page.schema)
        XCTAssertEqual(blocks.map(\.index), [1, 2])

        // The first block: a graph of two items, one with two more inside it.
        XCTAssertTrue(blocks[0].parses)
        XCTAssertEqual(blocks[0].raw?.hasPrefix("{\"@context\""), true)
        XCTAssertEqual(blocks[0].items.map(\.name), ["Organization", "BlogPosting"])
        let org = blocks[0].items[0], post = blocks[0].items[1]
        XCTAssertEqual(org.fields.map(\.name), ["@id", "name", "url"])
        XCTAssertEqual(org.recommended, ["Organization has no logo"])
        XCTAssertEqual(org.richResult, "Organization logo and knowledge panel")
        XCTAssertEqual(post.richResult, "Article")
        XCTAssertEqual(post.fields.first { $0.name == "author" }?.value, "Person")
        XCTAssertEqual(post.fields.first { $0.name == "publisher" }?.value, "→ \(root)/#org")
        XCTAssertEqual(post.children.map(\.name), ["Person"])
        XCTAssertEqual(post.children[0].role, "author")
        XCTAssertNil(post.children[0].richResult)
        XCTAssertEqual(post.children[0].id, "1.1.author")
        XCTAssertEqual(post.children[0].required + post.children[0].recommended, [], "a nested author is not held to a list")
        XCTAssertEqual(post.required, [])
        XCTAssertEqual(post.notes.count, 2)

        // The second does not parse, and says where.
        XCTAssertFalse(blocks[1].parses)
        XCTAssertEqual(blocks[1].error, "A JSON-LD block has a comma before a closing bracket, on line 1.")
        XCTAssertEqual(blocks[1].items, [])

        // What the inspector lists is what the checks report, no more and no less.
        let listed = Set(blocks.flatMap(\.items).flatMap { $0.required + $0.recommended + $0.notes })
        let reported = Set(report.findings.filter { ["schema.incomplete", "schema.recommended", "schema.values"].contains($0.check) }.compactMap(\.detail))
        XCTAssertEqual(listed, reported)

        // It survives being kept and read back, and a report kept before it existed still loads.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Report.self, from: Data(ReportFormat.json(report).utf8)).pages, report.pages)
        let old = "{\"site\":\"https://acme.com/\",\"date\":\"2025-11-01T10:00:00Z\",\"pagesChecked\":1,\"pagesFound\":1,\"linksChecked\":0,\"seconds\":1,\"findings\":[],\"passed\":[],\"pages\":[]}"
        let kept = try decoder.decode(Report.self, from: Data(old.utf8))
        XCTAssertNil(kept.areas)
        XCTAssertFalse(kept.isPartial)
        XCTAssertEqual(kept.verdict, "Ready to launch")
    }

    func testShortensValuesAndKnowsTheRules() {
        XCTAssertEqual(SchemaInspector.short(String(repeating: "word ", count: 40)).count, 89)
        XCTAssertEqual(SchemaInspector.short(["a", "b"]), "a, b")
        XCTAssertEqual(SchemaInspector.short([["@type": "ListItem"], ["@type": "ListItem"]]), "2 × ListItem")
        XCTAssertEqual(SchemaInspector.short(["x": 1, "y": 2]), "2 properties")
        XCTAssertEqual(SchemaInspector.short(NSNumber(value: true)), "true")
        XCTAssertEqual(SchemaInspector.short(NSNumber(value: 4.5)), "4.5")

        XCTAssertEqual(SchemaInspector.rules["Product"]?.required, ["name", "image", "offers"])
        XCTAssertEqual(SchemaInspector.rules["Product"]?.everywhere, true)
        XCTAssertEqual(SchemaInspector.rules["NewsArticle"]?.recommended, ["headline", "image", "datePublished", "author"])
        XCTAssertEqual(SchemaInspector.rules["Dentist"]?.richResult, "Local business")
        XCTAssertNil(SchemaInspector.rules["Person"])
        XCTAssertTrue(SchemaInspector.isDate("2026-02-07T10:00:00.000Z"))
        XCTAssertTrue(SchemaInspector.isDate("2026-02-07T10:00:00+0530"))
        XCTAssertFalse(SchemaInspector.isDate("7 February 2026"))
    }

    func testExportsSayWhatAPartialCheckCovered() async throws {
        var options = Options()
        options.singlePage = true
        options.areas = [.structured]
        let report = try await Auditor(fetcher: site(), options: options).run("www.acme.com/post")
        let text = ReportFormat.text(report)
        XCTAssertTrue(text.contains("Structured data, one page only: 1 thing to tidy"))
        XCTAssertTrue(text.contains("Only Structured data was checked, on this one page."))
        XCTAssertTrue(text.contains("Page: \(root)/post"))
        XCTAssertTrue(text.contains("STRUCTURED DATA"))
        XCTAssertTrue(text.contains("Block 1: BlogPosting, 5 properties, with Person inside. Can earn: Article"))
        XCTAssertTrue(text.contains("  recommended: Organization has no logo"))
        XCTAssertTrue(text.contains("Block 2: A JSON-LD block has a comma before a closing bracket, on line 1."))
        XCTAssertTrue(text.contains("Also found, not checked: Microdata"))

        let markdown = ReportFormat.markdown(report)
        XCTAssertTrue(markdown.contains("_Only Structured data was checked, on this one page. The score covers that and nothing else._"))
        XCTAssertTrue(markdown.contains("## Structured data"))

        let html = ReportFormat.html(report)
        XCTAssertTrue(html.contains("<p class=\"scope\">Only Structured data was checked, on this one page."))
        XCTAssertTrue(html.contains("<h2>Structured data</h2>"))
        XCTAssertTrue(html.contains("<b>BlogPosting</b>"))
        XCTAssertTrue(html.contains("<span class=\"quiet\">as author</span>"))
        XCTAssertTrue(html.contains("<span class=\"tag\">Article</span>"))

        // A check of other areas leaves structured data out of the export altogether.
        options.areas = [.images]
        let images = try await Auditor(fetcher: site(), options: options).run("www.acme.com/post")
        XCTAssertFalse(ReportFormat.text(images).contains("STRUCTURED DATA"))
        XCTAssertFalse(ReportFormat.html(images).contains("<h2>Structured data</h2>"))
        // And a full site check lists the types and how many pages each is on.
        let full = try await Auditor(fetcher: site()).run("www.acme.com")
        XCTAssertEqual(full.schemaTypesInUse.first?.pages, 1)
        XCTAssertTrue(ReportFormat.text(full).contains("  BlogPosting: 1 page"))
    }

    func testAreasHaveNamesAndWeights() {
        XCTAssertEqual(Category.named("structured-data"), .structured)
        XCTAssertEqual(Category.named("AI search"), .ai)
        XCTAssertEqual(Category.named("sitemap"), .sitemap)
        XCTAssertNil(Category.named("nonsense"))
        XCTAssertEqual(Category.allCases.map(\.weight).reduce(0, +), 100)
        XCTAssertEqual(Check.all.count, 104)
        for area in Category.allCases { XCTAssertGreaterThanOrEqual(Check.all.filter { $0.category == area }.count, 3, area.title) }
    }
}
