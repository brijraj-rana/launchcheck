import XCTest
@testable import LaunchcheckCore

final class ContentTests: XCTestCase {
    func testTheSameWordsHaveTheSameFingerprint() {
        let words = Array(repeating: "Rockets and anvils for everyone.", count: 30).joined(separator: " ")
        let one = HTMLScanner.scan("<html><body><h1>Acme</h1><p>\(words)</p></body></html>")
        let same = HTMLScanner.scan("<html><head><title>Other title</title></head><body><div><h2>ACME</h2>\n<p>\(words.uppercased())</p></div></body></html>")
        let other = HTMLScanner.scan("<html><body><h1>Acme</h1><p>\(words) And one more.</p></body></html>")
        XCTAssertEqual(one.textFingerprint, same.textFingerprint, "markup, case and the head do not count")
        XCTAssertNotEqual(one.textFingerprint, other.textFingerprint)

        func entry(_ path: String, _ facts: PageFacts) -> ContentChecks.Page { ContentChecks.Page(url: URL(string: "https://acme.com" + path)!, fingerprint: facts.textFingerprint, words: facts.wordCount) }
        XCTAssertEqual(ContentChecks.duplicates(among: [entry("/a", one), entry("/b", other), entry("/c", same)]).map { $0.map(\.path) }, [["/a", "/c"]])
        // Two near-empty pages share a menu, not their content.
        let empty = HTMLScanner.scan("<html><body><a href=\"/\">Home</a></body></html>")
        XCTAssertEqual(ContentChecks.duplicates(among: [entry("/x", empty), entry("/y", empty)]), [])
    }

    func testKnowsAnArticleWithNoDate() {
        let post = URL(string: "https://acme.com/blog/launch-day")!
        func facts(_ extra: String) -> PageFacts { HTMLScanner.scan("<html><head><meta property=\"og:type\" content=\"article\">\(extra)</head><body><p>Words</p></body></html>") }
        XCTAssertTrue(ContentChecks.isUndatedArticle(facts(""), url: post, schemaTypes: []))
        XCTAssertFalse(ContentChecks.isUndatedArticle(facts("<meta property=\"article:published_time\" content=\"2026-01-01\">"), url: post, schemaTypes: []))
        XCTAssertFalse(ContentChecks.isUndatedArticle(HTMLScanner.scan("<html><head><meta property=\"og:type\" content=\"article\"></head><body><time datetime=\"2026-01-01\">1 Jan</time></body></html>"), url: post, schemaTypes: []))
        XCTAssertFalse(ContentChecks.isUndatedArticle(facts(""), url: post, schemaTypes: ["BlogPosting"]), "the structured data check speaks for an Article")
        XCTAssertFalse(ContentChecks.isUndatedArticle(facts("<script type=\"application/ld+json\">{\"@type\":\"WebPage\",\"datePublished\":\"2026-01-01\"}</script>"), url: post, schemaTypes: ["WebPage"]))
        XCTAssertFalse(ContentChecks.isUndatedArticle(HTMLScanner.scan("<html><head><meta property=\"og:type\" content=\"website\"></head><body></body></html>"), url: post, schemaTypes: []))
        // og:type alone is not enough: a project page, or the blog's own front page, is not a dated article.
        XCTAssertFalse(ContentChecks.isUndatedArticle(facts(""), url: URL(string: "https://acme.com/work/rocket")!, schemaTypes: []))
        XCTAssertFalse(ContentChecks.isUndatedArticle(facts(""), url: URL(string: "https://acme.com/blog")!, schemaTypes: []))
    }

    func testLooksForAWayToThePeople() {
        func home(_ links: String) -> PageFacts { HTMLScanner.scan("<html><body>\(links)</body></html>") }
        XCTAssertFalse(ContentChecks.linksToPeople(home("<a href=\"/pricing\">Pricing</a><a href=\"/blog\">Blog</a>")))
        XCTAssertTrue(ContentChecks.linksToPeople(home("<a href=\"/contact-us\">Say hello</a>")))
        XCTAssertTrue(ContentChecks.linksToPeople(home("<a href=\"/x\">About us</a>")))
        XCTAssertTrue(ContentChecks.linksToPeople(home("<a href=\"mailto:someone@acme.test\">Write</a>")))
        XCTAssertTrue(ContentChecks.linksToPeople(home("<a href=\"/kontakt\">Schreiben</a>")))
        XCTAssertTrue(ContentChecks.linksToPeople(home("<a href=\"/x\">Impressum</a>")))
    }

    func testAnAuditFindsPagesThatRepeatEachOther() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        let article = "<meta property=\"og:type\" content=\"article\">"
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", body: "<h1>Acme</h1><a href=\"/blog/a\">A</a><a href=\"/b\">B</a><a href=\"/contact\">Contact</a>")),
            "\(root)/blog/a": .init(body: page(title: "The first copy of a page", description: "The first of two pages that carry exactly the same words as each other.", canonical: "\(root)/blog/a", head: article, body: "<h1>Twin</h1>")),
            "\(root)/b": .init(body: page(title: "The second copy of a page", description: "The second of two pages that carry exactly the same words as each other.", canonical: "\(root)/b", body: "<h1>Twin</h1>")),
            "\(root)/contact": .init(body: page(title: "Contact Acme Rockets today", description: "How to reach the people at Acme Rockets, by post, by telephone or by carrier pigeon.", canonical: "\(root)/contact", body: "<h1>Contact us</h1>")),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        XCTAssertEqual(report.findings.filter { $0.check == "content.duplicate" }.compactMap(\.detail), ["the same text on 2 pages: /blog/a, /b"])
        XCTAssertEqual(report.findings.filter { $0.check == "content.undated" }.map(\.url), ["\(root)/blog/a"])
        XCTAssertTrue(report.passed.contains("trust.contact"))
    }
}
