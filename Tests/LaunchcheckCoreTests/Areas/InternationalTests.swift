import XCTest
@testable import LaunchcheckCore

final class InternationalTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    private func languagePage(_ path: String, canonicalElsewhere: String? = nil, _ entries: [(String, String)]) -> InternationalChecks.Page {
        let address = url("https://acme.com" + path)
        return InternationalChecks.Page(url: address, key: Auditor.key(address), canonicalElsewhere: canonicalElsewhere,
                                        entries: entries.map { (code: $0.0, target: url($0.1)) })
    }

    func testAHealthySetSaysNothing() {
        let pages = [languagePage("/", [("en", "https://acme.com/"), ("fr", "https://acme.com/fr"), ("x-default", "https://acme.com/")]),
                     languagePage("/fr", [("en", "https://acme.com/"), ("fr", "https://acme.com/fr/"), ("x-default", "https://acme.com/")])]
        let fine = TargetState(status: 200, redirectedTo: nil, indexable: true)
        XCTAssertEqual(InternationalChecks.findings(for: pages) { _ in fine }, [])
        // A target that was never fetched is not judged.
        XCTAssertEqual(InternationalChecks.findings(for: pages) { _ in nil }, [])
    }

    func testFindsWhatBreaksASet() {
        let page = languagePage("/", canonicalElsewhere: "https://acme.com/home", [
            ("en", "https://acme.com/"), ("fr", "https://acme.com/fr"), ("FR", "https://acme.com/french"), ("de", "http://acme.com/de"),
            ("es", "https://acme.com/es"), ("it", "https://acme.com/it"),
        ])
        let states: [String: TargetState] = [
            "https://acme.com/fr": TargetState(status: 200, redirectedTo: "https://acme.com/fr-fr", indexable: true),
            "https://acme.com/french": TargetState(status: 200, redirectedTo: nil, indexable: true),
            "https://acme.com/es": TargetState(status: 404, redirectedTo: nil, indexable: nil),
            "https://acme.com/it": TargetState(status: 200, redirectedTo: nil, indexable: false),
        ]
        let found = InternationalChecks.findings(for: [page]) { states[$0] }
        XCTAssertEqual(found.map(\.check), ["hreflang.noncanonical", "hreflang.duplicate", "hreflang.protocol", "hreflang.target"])
        XCTAssertEqual(found[0].detail, "canonical is https://acme.com/home")
        XCTAssertEqual(found[1].detail, "fr is given 2 different addresses")
        XCTAssertEqual(found[2].detail, "de points at http://acme.com/de")
        XCTAssertEqual(found[3].detail, "the fr version at https://acme.com/fr redirects to https://acme.com/fr-fr, and 2 more")
        for check in found.map(\.check) { XCTAssertEqual(Check.named(check)?.category, .international) }
    }

    func testTheSameLanguageTwiceAtOneAddressIsNotADuplicate() {
        let page = languagePage("/", [("en", "https://acme.com/"), ("en", "https://acme.com"), ("en-GB", "https://acme.com/uk")])
        XCTAssertEqual(InternationalChecks.findings(for: [page]) { _ in nil }, [])
    }

    func testAnAuditFollowsHreflangLinks() async throws {
        let web = StubFetcher()
        let root = "https://www.acme.com"
        func tags(_ own: String) -> String {
            "<link rel=\"alternate\" hreflang=\"en\" href=\"\(root)/\"><link rel=\"alternate\" hreflang=\"de\" href=\"\(root)/de\">"
                + "<link rel=\"alternate\" hreflang=\"fr\" href=\"\(root)/fr\"><link rel=\"alternate\" hreflang=\"x-default\" href=\"\(root)/\">"
        }
        web.answers = [
            "\(root)/": .init(body: page(title: "Acme Rockets and anvils", canonical: "\(root)/", head: tags("/"), body: "<h1>Acme</h1><a href=\"/de\">Deutsch</a><a href=\"/contact\">Contact</a>")),
            "\(root)/de": .init(body: page(title: "Acme Raketen und Ambosse", description: "Raketen und Ambosse fuer alle, die es eilig haben, und noch viel mehr dazu.",
                                           canonical: "\(root)/de", head: tags("/de"), body: "<h1>Acme DE</h1><a href=\"/\">English</a>")),
            "\(root)/fr": .init(status: 404),
            "\(root)/contact": .init(body: page(title: "Contact Acme Rockets today", description: "How to reach the people at Acme Rockets, by post, by telephone or by carrier pigeon.", canonical: "\(root)/contact")),
            "\(root)/share.png": .init(type: "image/png"),
        ]
        let report = try await Auditor(fetcher: web).run("www.acme.com")
        let found = report.findings.filter { $0.check.hasPrefix("hreflang.") }
        XCTAssertEqual(Set(found.map(\.check)), ["hreflang.target"])
        XCTAssertEqual(found.first?.detail, "the fr version at \(root)/fr returned 404")
        XCTAssertTrue(report.passed.contains("hreflang.duplicate"))
        XCTAssertTrue(report.passed.contains("hreflang.return"))
    }
}
