import XCTest
@testable import LaunchcheckCore

final class TechnicalTests: XCTestCase {
    func testFindsAssetsThatRobotsBlocks() {
        let robots = Robots("User-agent: *\nDisallow: /assets/\nAllow: /assets/public/\n\nUser-agent: Googlebot\nDisallow: /js/")
        let files = ["https://acme.com/assets/site.css", "https://acme.com/js/app.js?v=2", "https://acme.com/js/app.js?v=2", "https://acme.com/css/site.css"].map { URL(string: $0)! }
        // Google obeys the group written for it, and only that one.
        XCTAssertEqual(TechnicalChecks.blockedAssets(stylesheets: [files[0], files[3]], scripts: [files[1], files[2]], robots: robots), ["/js/app.js?v=2"])
        let everyone = Robots("User-agent: *\nDisallow: /assets/\nAllow: /assets/public/")
        XCTAssertEqual(TechnicalChecks.blockedAssets(stylesheets: [files[0], URL(string: "https://acme.com/assets/public/a.css")!], scripts: [], robots: everyone), ["/assets/site.css"])
    }

    func testReadsRobotsAndViewportDirectives() {
        XCTAssertTrue(TechnicalChecks.forbidsSnippet("index, NoSnippet"))
        XCTAssertTrue(TechnicalChecks.forbidsSnippet("max-snippet: 0, max-image-preview:large"))
        XCTAssertFalse(TechnicalChecks.forbidsSnippet("max-snippet:-1, max-image-preview:large, index, follow"))
        XCTAssertFalse(TechnicalChecks.forbidsSnippet("max-snippet:50"))
        XCTAssertFalse(TechnicalChecks.forbidsSnippet(""))

        XCTAssertNil(TechnicalChecks.zoomBlock(in: "width=device-width, initial-scale=1"))
        XCTAssertNil(TechnicalChecks.zoomBlock(in: "width=device-width, initial-scale=1, maximum-scale=5"))
        XCTAssertEqual(TechnicalChecks.zoomBlock(in: "width=device-width, initial-scale=1, user-scalable=no"), "user-scalable=no")
        XCTAssertEqual(TechnicalChecks.zoomBlock(in: "width=device-width, initial-scale=1.0, maximum-scale=1.0"), "maximum-scale=1.0")
        XCTAssertNil(TechnicalChecks.zoomBlock(in: ""))
    }

    func testAnAuditFollowsCanonicalsAndReadsTheRest() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        let head = "<link rel=\"stylesheet\" href=\"/private/site.css\"><meta name=\"robots\" content=\"nosnippet\">"
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", head: head,
                                         body: "<h1>Acme</h1><a href=\"/old\">Old</a><a href=\"/contact\">Contact</a><img src=\"/a.png\" alt=\"A\" width=\"1\" height=\"1\">")),
            "\(root)/old": .init(body: page(title: "The old page about anvils", description: "An older page that says its real address is somewhere that has since been moved.",
                                            canonical: "\(root)/moved", head: "<meta name=\"viewport\" content=\"width=device-width, user-scalable=no\">", complete: false)),
            "\(root)/moved": .init(redirect: "\(root)/"),
            "\(root)/contact": .init(body: page(title: "Contact Acme Rockets today", description: "How to reach the people at Acme Rockets, by post, by telephone or by carrier pigeon.", canonical: "\(root)/contact")),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nDisallow: /private/"),
            "\(root)/a.png": .init(type: "image/png", headers: ["content-length": "900", "cache-control": "no-cache"]),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        func details(_ check: String) -> [String] { report.findings.filter { $0.check == check }.map { ReportFormat.line($0, site: report.site) } }
        XCTAssertEqual(details("canonical.broken"), ["/old  \(root)/moved redirects to \(root)/"])
        XCTAssertEqual(details("robots.blocks-assets"), ["/robots.txt  /private/site.css"])
        XCTAssertEqual(details("page.nosnippet"), ["/  nosnippet"])
        XCTAssertEqual(details("viewport.zoom"), ["/old  user-scalable=no"])
    }
}
