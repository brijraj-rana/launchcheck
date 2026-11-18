import XCTest
@testable import LaunchcheckCore

final class SitemapTests: XCTestCase {
    private func answer(_ address: String, status: Int = 200, type: String = "application/xml", body: String = "") -> FetchResult {
        FetchResult(url: URL(string: address)!, status: status, headers: ["content-type": type], body: Data(body.utf8))
    }

    func testTellsASitemapFromSomethingElse() {
        let address = "https://acme.com/sitemap.xml"
        let good = "<urlset><url><loc>https://acme.com/</loc></url></urlset>"
        XCTAssertNil(SitemapChecks.unreadable(answer(address, body: good), parsed: SitemapParser.parse(Data(good.utf8)), namedBy: "robots.txt"))
        XCTAssertEqual(SitemapChecks.unreadable(answer(address, status: 404), parsed: SitemapContents(), namedBy: "robots.txt"),
                       "robots.txt names \(address), which returned 404")
        XCTAssertEqual(SitemapChecks.unreadable(answer(address, status: 0), parsed: SitemapContents(), namedBy: "A sitemap index"),
                       "A sitemap index names \(address), which did not load")
        XCTAssertEqual(SitemapChecks.unreadable(answer(address, type: "text/html", body: "<html><body>Not found</body></html>"), parsed: SitemapContents(), namedBy: "robots.txt"),
                       "robots.txt names \(address), which is not a sitemap")
        XCTAssertNil(SitemapChecks.unreadable(answer(address, status: 403), parsed: SitemapContents(), namedBy: "robots.txt"), "being turned away is not a missing file")
        // Forms a crawler accepts, or that cannot be opened here, are left alone.
        XCTAssertNil(SitemapChecks.unreadable(answer(address, body: "<urlset></urlset>"), parsed: SitemapContents(), namedBy: "robots.txt"), "an empty sitemap is still one")
        XCTAssertNil(SitemapChecks.unreadable(answer(address, type: "text/plain", body: "https://acme.com/\nhttps://acme.com/a\n"), parsed: SitemapContents(), namedBy: "robots.txt"))
        XCTAssertNil(SitemapChecks.unreadable(answer("https://acme.com/sitemap.xml.gz", type: "application/octet-stream", body: "xx"), parsed: SitemapContents(), namedBy: "robots.txt"))
    }

    func testJudgesLastModifiedDates() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)          // 2 February 2026
        XCTAssertEqual(SitemapChecks.lastmodProblems(["2026-02-01", "2025-12-31T10:00:00+05:30", "2026-02-03", "2024", "2025-06"], now: now), [])
        XCTAssertEqual(SitemapChecks.lastmodProblems(["2031-01-01", "2026-02-10T00:00:00Z", "2026-01-01"], now: now),
                       ["2 entries are dated in the future, such as 2031-01-01"])
        XCTAssertEqual(SitemapChecks.lastmodProblems(["07/02/2026", "2026-01-01"], now: now), ["1 date is not a date: “07/02/2026”"])
    }

    func testAnAuditReportsANamedSitemapThatIsMissing() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", body: "<h1>Acme</h1><a href=\"/contact\">Contact</a>")),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nAllow: /\nSitemap: \(root)/sitemap.xml\nSitemap: \(root)/news.xml"),
            "\(root)/sitemap.xml": .init(type: "application/xml", body: "<sitemapindex><sitemap><loc>\(root)/pages.xml</loc></sitemap><sitemap><loc>\(root)/gone.xml</loc></sitemap></sitemapindex>"),
            "\(root)/pages.xml": .init(type: "application/xml", body: "<urlset><url><loc>\(root)/</loc><lastmod>2099-01-01</lastmod></url></urlset>"),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        let lines = report.findings.filter { $0.check == "sitemap.unreadable" }.compactMap(\.detail)
        XCTAssertEqual(Set(lines), ["robots.txt names \(root)/news.xml, which returned 404", "A sitemap index names \(root)/gone.xml, which returned 404"])
        XCTAssertEqual(report.findings.filter { $0.check == "sitemap.lastmod-invalid" }.compactMap(\.detail), ["1 entry is dated in the future: 2099-01-01"])
        XCTAssertEqual(Check.named("sitemap.unreadable")?.category, .sitemap)
        XCTAssertFalse(report.findings.contains { $0.check == "sitemap.missing" })
        XCTAssertNotNil(report.categoryScores.first { $0.category == .sitemap }?.score)
        XCTAssertEqual(Check.all.filter { $0.category == .sitemap }.count, 13)
    }
}
