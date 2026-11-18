import XCTest
@testable import LaunchcheckCore

final class AISearchTests: XCTestCase {
    func testTellsFetchersFromCrawlers() {
        let robots = Robots("User-agent: *\nAllow: /\n\nUser-agent: ChatGPT-User\nUser-agent: GPTBot\nDisallow: /\n\nUser-agent: Claude-User\nDisallow: /private")
        XCTAssertEqual(AISearchChecks.blockedUserAgents(robots), ["ChatGPT-User"])
        XCTAssertEqual(AISearchChecks.blockedUserAgents(Robots("User-agent: GPTBot\nDisallow: /")), [], "a training crawler is a separate choice")
    }

    func testReadsTheLinksOfAnLlmsFile() {
        let text = "# Acme\n\n> Rockets.\n\n- [About](/about): who\n- [Docs](https://docs.acme.com/start)\n- [About again](/about)\n- [Mail](mailto:x@acme.test)\n"
        XCTAssertEqual(AISearchChecks.links(in: text, base: URL(string: "https://acme.com/llms.txt")!).map(\.absoluteString),
                       ["https://acme.com/about", "https://docs.acme.com/start"])
    }

    func testAnAuditFollowsLlmsLinksOnThisSiteOnly() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", body: "<h1>Acme</h1><a href=\"mailto:hello@acme.test\">Write</a>")),
            "\(root)/robots.txt": .init(type: "text/plain", body: "User-agent: *\nAllow: /\n\nUser-agent: Perplexity-User\nDisallow: /"),
            "\(root)/llms.txt": .init(type: "text/plain", body: "# Acme\n\n> Rockets and anvils.\n\n- [Home](\(root)/)\n- [Gone](\(root)/gone)\n- [Elsewhere](https://other.test/missing)\n"),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        XCTAssertEqual(report.findings.filter { $0.check == "ai.llms-links" }.compactMap(\.detail), ["\(root)/gone returned 404"])
        XCTAssertEqual(report.findings.filter { $0.check == "ai.fetch-blocked" }.compactMap(\.detail), ["Perplexity-User is disallowed"])
        XCTAssertTrue(report.passed.contains("ai.search-blocked"))
    }
}

final class ImageChecksTests: XCTestCase {
    func testKnowsAnOlderFormatAndAPageWithNoLazyLoading() {
        XCTAssertEqual(ImageChecks.olderFormat(["content-type": "image/jpeg"]), "JPEG")
        XCTAssertEqual(ImageChecks.olderFormat(["content-type": "image/png; charset=binary"]), "PNG")
        XCTAssertNil(ImageChecks.olderFormat(["content-type": "image/webp"]))
        XCTAssertNil(ImageChecks.olderFormat(["content-type": "image/svg+xml"]))

        func gallery(_ count: Int, _ extra: String = "") -> [ImageFact] {
            HTMLScanner.scan("<html><body>" + String(repeating: "<img src=\"/a.jpg\" alt=\"\">", count: count) + extra + "</body></html>").images
        }
        XCTAssertTrue(ImageChecks.loadsEverythingAtOnce(gallery(10)))
        XCTAssertFalse(ImageChecks.loadsEverythingAtOnce(gallery(9)))
        XCTAssertFalse(ImageChecks.loadsEverythingAtOnce(gallery(10, "<img src=\"/b.jpg\" loading=\"lazy\" alt=\"\">")))
        XCTAssertFalse(ImageChecks.loadsEverythingAtOnce(gallery(10, "<img data-src=\"/b.jpg\" alt=\"\">")), "an image a script loads later counts as lazy")

        XCTAssertTrue(ImageChecks.isRelative("/og.png"))
        XCTAssertTrue(ImageChecks.isRelative("//cdn.acme.com/og.png"))
        XCTAssertFalse(ImageChecks.isRelative("https://acme.com/og.png"))
    }

    func testAnAuditNamesEachImageOnce() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        let images = "<img src=\"/mid.jpg\" alt=\"A\" width=\"1\" height=\"1\"><img src=\"/big.jpg\" alt=\"B\" width=\"1\" height=\"1\"><img src=\"/small.png\" alt=\"C\" width=\"1\" height=\"1\"><img src=\"/mid.webp\" alt=\"D\" width=\"1\" height=\"1\">"
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", body: "<h1>Acme</h1><a href=\"mailto:hello@acme.test\">Write</a>" + images, image: "\(root)/share.png")),
            "\(root)/mid.jpg": .init(type: "image/jpeg", headers: ["content-length": "150000"]),
            "\(root)/big.jpg": .init(type: "image/jpeg", headers: ["content-length": "350000"]),
            "\(root)/small.png": .init(type: "image/png", headers: ["content-length": "40000"]),
            "\(root)/mid.webp": .init(type: "image/webp", headers: ["content-length": "150000"]),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        XCTAssertEqual(report.findings.filter { $0.check == "images.format" }.compactMap(\.detail), ["JPEG, 150 KB: \(root)/mid.jpg"])
        XCTAssertEqual(report.findings.filter { $0.check == "images.large" }.compactMap(\.detail), ["350 KB: \(root)/big.jpg"])
        XCTAssertFalse(report.findings.contains { $0.check == "social.image.relative" })
    }
}
