import XCTest
@testable import LaunchcheckCore

private func doc(_ title: String, h1: String? = nil, links: [String] = []) -> StubFetcher.Answer {
    let anchors = links.map { "<a href=\"\($0)\">\($0)</a>" }.joined()
    return .init(body: "<!doctype html><html lang=\"en\"><head><title>\(title)</title></head><body><h1>\(h1 ?? title)</h1>\(anchors)</body></html>")
}

private func sitemap(_ root: String, _ paths: [String]) -> StubFetcher.Answer {
    .init(type: "application/xml", body: "<urlset>" + paths.map { "<url><loc>\(root)\($0)</loc></url>" }.joined() + "</urlset>")
}

final class MigrateTests: XCTestCase {
    private let old = "https://www.acme.com"
    private let new = "https://acme.webflow.io"

    /// The rebuilt site: eight pages, three redirects already set up (one good, one a chain, one to nowhere).
    private func newSite(into web: StubFetcher) {
        let paths = ["/", "/about", "/pricing", "/posts/why-anvils-fall", "/products", "/products/rocket-skates", "/crew", "/fresh"]
        web.answers["\(new)/sitemap.xml"] = sitemap(new, paths)
        web.answers["\(new)/"] = doc("Acme Rockets")
        web.answers["\(new)/about"] = doc("About Acme Rockets")
        web.answers["\(new)/pricing"] = doc("Pricing | Acme Rockets", h1: "Pricing")
        web.answers["\(new)/posts/why-anvils-fall"] = doc("Why anvils fall | Acme Rockets", h1: "Why anvils fall")
        web.answers["\(new)/products"] = doc("Everything Acme makes")
        web.answers["\(new)/products/rocket-skates"] = doc("Rocket skates | Acme Rockets", h1: "Rocket skates")
        web.answers["\(new)/crew"] = doc("Meet the people behind Acme Rockets")
        web.answers["\(new)/fresh"] = doc("A page the old site never had")
        web.answers["\(new)/old-shop"] = .init(redirect: "\(new)/products")
        web.answers["\(new)/chain"] = .init(redirect: "\(new)/chain-2")
        web.answers["\(new)/chain-2"] = .init(redirect: "\(new)/products")
        web.answers["\(new)/dead-end"] = .init(redirect: "\(new)/nowhere")
    }

    private let oldPaths = ["/", "/about/", "/pricing.html", "/blog/2021/03/why-anvils-fall", "/old-shop", "/chain", "/dead-end",
                            "/services/rocket-skate", "/about-the-team", "/gone-forever"]

    private func bothSites() -> StubFetcher {
        let web = StubFetcher()
        newSite(into: web)
        web.answers["\(old)/sitemap.xml"] = sitemap(old, oldPaths)
        web.answers["\(old)/"] = doc("Acme")
        web.answers["\(old)/about/"] = doc("About")
        web.answers["\(old)/pricing.html"] = doc("Prices")
        web.answers["\(old)/blog/2021/03/why-anvils-fall"] = doc("Why anvils fall")
        web.answers["\(old)/old-shop"] = doc("Shop")
        web.answers["\(old)/chain"] = doc("Chain")
        web.answers["\(old)/dead-end"] = doc("Dead end")
        web.answers["\(old)/services/rocket-skate"] = doc("Skates")
        web.answers["\(old)/about-the-team"] = doc("Meet the people behind Acme")
        web.answers["\(old)/gone-forever"] = doc("Clearance")
        return web
    }

    // MARK: The six outcomes

    func testDecidesEveryOldPage() async throws {
        let map = try await Migrator(fetcher: bothSites()).run(old: "www.acme.com", new: "acme.webflow.io")
        let rows = Dictionary(uniqueKeysWithValues: map.rows.map { ($0.path, $0) })
        XCTAssertEqual(map.rows.map(\.path), ["/", "/about", "/pricing.html", "/blog/2021/03/why-anvils-fall", "/old-shop", "/chain", "/dead-end",
                                              "/services/rocket-skate", "/about-the-team", "/gone-forever"])
        XCTAssertEqual(map.oldSite, "https://www.acme.com/")
        XCTAssertEqual(map.newSite, "https://acme.webflow.io/")

        // The same address exists on the new site.
        XCTAssertEqual(rows["/"]?.outcome, .same)
        XCTAssertEqual(rows["/about"]?.outcome, .same)
        XCTAssertEqual(rows["/about"]?.standing, .fine)

        // Already redirects to a live page, and says where.
        XCTAssertEqual(rows["/old-shop"]?.outcome, .redirected)
        XCTAssertEqual(rows["/old-shop"]?.destination, "/products")
        XCTAssertEqual(rows["/old-shop"]?.note, "Already redirects to /products")
        XCTAssertFalse(rows["/old-shop"]?.needsRedirect ?? true)

        // Redirects through a chain: the fix is known, so it is ready.
        XCTAssertEqual(rows["/chain"]?.outcome, .broken)
        XCTAssertEqual(rows["/chain"]?.destination, "/products")
        XCTAssertEqual(rows["/chain"]?.standing, .ready)
        XCTAssertTrue(rows["/chain"]?.note?.hasPrefix("Gets there in 2 hops: /chain → /chain-2 → /products") ?? false)

        // Redirects to a missing page, and nothing else fits.
        XCTAssertEqual(rows["/dead-end"]?.outcome, .broken)
        XCTAssertNil(rows["/dead-end"]?.destination)
        XCTAssertEqual(rows["/dead-end"]?.standing, .stranded)
        XCTAssertEqual(rows["/dead-end"]?.note, "Redirects to /nowhere, which returns 404")

        // Missing with a confident match: a file ending, another name for the section, a near-identical last part.
        XCTAssertEqual(rows["/pricing.html"]?.outcome, .confident)
        XCTAssertEqual(rows["/pricing.html"]?.destination, "/pricing")
        XCTAssertEqual(rows["/pricing.html"]?.note, "Same address once tidied")
        XCTAssertEqual(rows["/blog/2021/03/why-anvils-fall"]?.outcome, .confident)
        XCTAssertEqual(rows["/blog/2021/03/why-anvils-fall"]?.destination, "/posts/why-anvils-fall")
        XCTAssertEqual(rows["/blog/2021/03/why-anvils-fall"]?.note, "Same page under /posts")
        XCTAssertEqual(rows["/services/rocket-skate"]?.outcome, .confident)
        XCTAssertEqual(rows["/services/rocket-skate"]?.destination, "/products/rocket-skates")
        XCTAssertEqual(rows["/services/rocket-skate"]?.note, "Similar address, 92% alike")

        // Missing with a possible match, found by its title.
        XCTAssertEqual(rows["/about-the-team"]?.outcome, .possible)
        XCTAssertEqual(rows["/about-the-team"]?.destination, "/crew")
        XCTAssertEqual(rows["/about-the-team"]?.standing, .uncertain)
        XCTAssertEqual(rows["/about-the-team"]?.note, "Similar title, 77% alike")
        XCTAssertEqual(rows["/about-the-team"]?.title, "Meet the people behind Acme")

        // Missing with no match.
        XCTAssertEqual(rows["/gone-forever"]?.outcome, .unmatched)
        XCTAssertNil(rows["/gone-forever"]?.destination)

        XCTAssertEqual(map.verdict, "7 old pages need a redirect")
        XCTAssertEqual(map.breakdown, "4 are written, 1 needs a look, 2 have no match")
        XCTAssertEqual(map.stranded, 2)
        XCTAssertEqual(map.count(.fine), 3)
        // New pages nothing old points to.
        XCTAssertEqual(map.unclaimed, ["/fresh"])
        XCTAssertEqual(map.newPages.count, 8)
    }

    func testAcceptsAListWhenTheOldSiteIsOffline() async throws {
        let web = StubFetcher()
        newSite(into: web)
        web.deadHosts = ["www.acme.com", "acme.com"]
        let list = """
        address,visits
        https://www.acme.com/about/,120
        /pricing.html
        /Blog/Why_Anvils_Fall.php\t9
        https://www.acme.com/about
        https://elsewhere.example/ignored
        /gone-forever
        """
        let map = try await Migrator(fetcher: web).run(old: "acme.com", new: new, oldList: list)
        XCTAssertEqual(map.rows.map(\.path), ["/about", "/pricing.html", "/Blog/Why_Anvils_Fall.php", "/gone-forever"])
        XCTAssertEqual(map.rows.map(\.outcome), [.same, .confident, .confident, .unmatched])
        XCTAssertEqual(map.rows[2].destination, "/posts/why-anvils-fall")
        XCTAssertNil(map.rows[1].title, "an offline site has no titles to read")

        // A sitemap pasted in works the same way.
        let pasted = "<urlset><url><loc>https://acme.com/old-shop</loc></url><url><loc>https://acme.com/chain</loc></url></urlset>"
        let second = try await Migrator(fetcher: web).run(old: "acme.com", new: new, oldList: pasted)
        XCTAssertEqual(second.rows.map(\.outcome), [.redirected, .broken])
        XCTAssertEqual(second.verdict, "1 old page needs a redirect")

        do {
            _ = try await Migrator(fetcher: web).run(old: "acme.com", new: new, oldList: "nothing useful here")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MigrationError, .emptyList("acme.com"))
        }
    }

    func testWorksWhenTheNewSiteAlreadyHasTheDomain() async throws {
        // After the switch: the old addresses come from a list and are asked of the one live site.
        let web = StubFetcher()
        let root = "https://acme.com"
        web.answers = [
            "\(root)/": doc("Acme Rockets", links: ["/pricing", "/team"]),
            "\(root)/pricing": doc("Pricing"),
            "\(root)/team": doc("The team"),
            "\(root)/pricing/": .init(redirect: "\(root)/pricing"),
            "\(root)/shop": .init(redirect: "\(root)/pricing"),
        ]
        let map = try await Migrator(fetcher: web).run(old: "acme.com", new: "acme.com", oldList: "/pricing/\n/shop\n/our-team\n/team")
        XCTAssertEqual(map.rows.map(\.outcome), [.same, .redirected, .confident, .same], "a hop that only drops a slash is not a redirect")
        XCTAssertEqual(map.rows[2].destination, "/team")
        XCTAssertEqual(map.rows[2].note, "Same page under /team")

        // With no list, the site is compared with itself and everything is fine.
        let same = try await Migrator(fetcher: web).run(old: "acme.com", new: "acme.com")
        XCTAssertEqual(same.verdict, "Every old page has somewhere to go")
        XCTAssertEqual(same.rows.count, 3)
    }

    func testDoesNotTrustAServerThatAnswersEverything() async throws {
        let web = StubFetcher()
        newSite(into: web)
        web.fallbackStatus = 200
        let map = try await Migrator(fetcher: web).run(old: "acme.com", new: new, oldList: "/gone-forever\n/about")
        XCTAssertEqual(map.rows.map(\.outcome), [.unmatched, .same])
    }

    func testReportsSitesItCannotRead() async {
        let web = StubFetcher()
        web.deadHosts = ["acme.webflow.io"]
        do {
            _ = try await Migrator(fetcher: web).run(old: "acme.com", new: "acme.webflow.io")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AuditError, .unreachable("acme.webflow.io", "The address does not exist"))
        }
        do {
            _ = try await Migrator(fetcher: web).run(old: "not a site", new: "acme.webflow.io")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AuditError, .invalidAddress("not a site"))
        }
    }

    // MARK: The matcher on its own

    func testTidiesAddresses() {
        XCTAssertEqual(Migrator.tidy("/About-Us/"), "/about-us")
        XCTAssertEqual(Migrator.tidy("/blog/My_Post.HTML"), "/blog/my-post")
        XCTAssertEqual(Migrator.tidy("/shop/index.php"), "/shop")
        XCTAssertEqual(Migrator.tidy("/index.html"), "/")
        XCTAssertEqual(Migrator.tidy("/caf%C3%A9?ref=1"), "/café")
        XCTAssertEqual(Migrator.core("/blog/2021/03/x"), "/blog/x")
        XCTAssertEqual(Migrator.core("/posts/x"), "/blog/x")
        XCTAssertEqual(Migrator.core("/2021/03/x"), "/x")
        XCTAssertEqual(Migrator.core("/products/42"), "/products/42", "a page named by a number keeps its name")
        XCTAssertEqual(Migrator.slug("/a/b/Rocket_Skates.html"), "rocket-skates")
        XCTAssertEqual(Migrator.overlap("why-anvils-fall", "why-our-anvils-fall-straighter"), 0.6, accuracy: 0.001)
        XCTAssertEqual(Migrator.headline("Pricing | Acme"), "pricing")
        XCTAssertEqual(Migrator.headline("  Acme · A short history of the anvil "), "a short history of the anvil")
        XCTAssertEqual(Migrator.entered(" pricing/ "), "/pricing")
        XCTAssertEqual(Migrator.entered("https://shop.acme.com/x"), "https://shop.acme.com/x")
        XCTAssertNil(Migrator.entered("  "))
    }

    func testMatchesByAddressThenTitle() {
        typealias C = Migrator.Candidate
        let pages = [C(path: "/"), C(path: "/about", title: "About Acme Rockets"), C(path: "/work/canyon-bridge", title: "Canyon bridge"),
                     C(path: "/journal/canyon-bridge", title: "How we built the canyon bridge"), C(path: "/contact"),
                     C(path: "/products/rocket-skates", title: "Rocket skates"), C(path: "/products/rocket-skis", title: "Rocket skis")]

        XCTAssertEqual(Migrator.match(path: "/Contact-Us.php", among: pages).destination, "/contact")
        XCTAssertEqual(Migrator.match(path: "/about-us", among: pages), Migrator.Match(destination: "/about", note: "Same page under /about"))

        // Two new pages share the last part: a suggestion, but not one to trust.
        let shared = Migrator.match(path: "/case/canyon-bridge", among: pages)
        XCTAssertEqual(shared.destination, "/work/canyon-bridge")
        XCTAssertFalse(shared.sure)
        XCTAssertEqual(shared.alternatives, ["/journal/canyon-bridge"])
        XCTAssertEqual(shared.note, "2 new pages end in “canyon-bridge”")

        // A near-identical last part is trusted when it is well ahead of the next best, which is kept as an alternative.
        let close = Migrator.match(path: "/shop/rocket-skate", among: pages)
        XCTAssertEqual(close.destination, "/products/rocket-skates")
        XCTAssertTrue(close.sure)
        XCTAssertEqual(close.alternatives, ["/products/rocket-skis"])

        // Equally close to two pages: the choice is a person's.
        let tied = Migrator.match(path: "/range/anvil-pro-3", among: [C(path: "/products/anvil-pro-1"), C(path: "/products/anvil-pro-2")])
        XCTAssertEqual(tied.destination, "/products/anvil-pro-1")
        XCTAssertFalse(tied.sure)
        XCTAssertEqual(tied.note, "Similar address, 91% alike, but another page is as close")

        // A title carries a page whose address changed entirely.
        let byTitle = Migrator.match(path: "/p/1432", title: "How we built the canyon bridge | Acme", among: pages)
        XCTAssertEqual(byTitle, Migrator.Match(destination: "/journal/canyon-bridge", note: "Same title", alternatives: ["/work/canyon-bridge"]))

        // Short titles and short last parts are not evidence.
        XCTAssertNil(Migrator.match(path: "/p/2", title: "About", h1: "About", among: pages).destination)
        XCTAssertNil(Migrator.match(path: "/warranty", title: "Warranty terms", among: pages).destination)
        XCTAssertNil(Migrator.match(path: "/anything", among: []).destination)

        XCTAssertGreaterThan(Migrator.Threshold.confidentSlug, Migrator.Threshold.possibleSlug)
        XCTAssertGreaterThan(Migrator.Threshold.confidentTitle, Migrator.Threshold.possibleTitle)
        XCTAssertGreaterThan(Migrator.Threshold.possibleSlug, Migrator.Threshold.alternative)
    }

    // MARK: Formats

    private func sampleMap() -> MigrationMap {
        MigrationMap(oldSite: "https://old.acme.com/", newSite: "https://acme.webflow.io/", date: Date(timeIntervalSince1970: 1_700_000_000), rows: [
            MigrationRow(old: "https://old.acme.com/", path: "/", outcome: .same, destination: "/"),
            MigrationRow(old: "https://old.acme.com/shop", path: "/shop", outcome: .redirected, destination: "/products"),
            MigrationRow(old: "https://old.acme.com/team", path: "/team", outcome: .possible, destination: "/crew", sure: false, note: "Similar title, 77% alike"),
            MigrationRow(old: "https://old.acme.com/pricing.html", path: "/pricing.html", outcome: .confident, destination: "/pricing"),
            MigrationRow(old: "https://old.acme.com/a,b", path: "/a,b", outcome: .broken, destination: "/say-\"hi\""),
            MigrationRow(old: "https://old.acme.com/gone", path: "/gone", outcome: .unmatched),
        ], newPages: [.init(path: "/"), .init(path: "/products"), .init(path: "/crew"), .init(path: "/pricing"), .init(path: "/fresh", title: "Fresh")])
    }

    func testWritesTheRedirectsInEachFormat() throws {
        let map = sampleMap()
        XCTAssertEqual(MigrationFormat.webflowHeader, ["source", "target"])
        XCTAssertEqual(MigrationFormat.webflow.render(map), """
        source,target
        /pricing.html,/pricing
        "/a,b","/say-""hi\"""
        /team,/crew

        """)
        XCTAssertEqual(MigrationFormat.webflow.render(map, confidentOnly: true), "source,target\n/pricing.html,/pricing\n\"/a,b\",\"/say-\"\"hi\"\"\"\n")

        XCTAssertEqual(MigrationFormat.text.render(map), """
        /pricing.html -> /pricing
        /a,b -> /say-"hi"
        /team -> /crew  (check)
        /gone -> ?

        """)
        XCTAssertFalse(MigrationFormat.text.render(map, confidentOnly: true).contains("/team"))

        XCTAssertEqual(MigrationFormat.redirects.render(map), """
        /pricing.html  /pricing  301
        /a,b           /say-"hi"  301

        # Check these before use: the match is a guess
        /team          /crew  301

        # No match on the new site
        # /gone

        """)
        XCTAssertFalse(MigrationFormat.redirects.render(map, confidentOnly: true).contains("/crew"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MigrationFormat.json.render(map).utf8)) as? [String: Any])
        let redirects = try XCTUnwrap(json["redirects"] as? [[String: Any]])
        XCTAssertEqual(redirects.map { $0["from"] as? String }, ["/pricing.html", "/a,b", "/team"])
        XCTAssertEqual(redirects.map { $0["uncertain"] as? Bool }, [false, false, true])
        XCTAssertEqual(redirects.last?["outcome"] as? String, "possible")
        XCTAssertEqual(json["noMatch"] as? [String], ["/gone"])
        XCTAssertEqual(json["newPagesWithNoOldAddress"] as? [String], ["/fresh"])
        XCTAssertEqual((json["fine"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(json["verdict"] as? String, "4 old pages need a redirect")
        let trimmed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MigrationFormat.json.render(map, confidentOnly: true).utf8)) as? [String: Any])
        XCTAssertEqual((trimmed["redirects"] as? [[String: Any]])?.count, 2)

        // Nothing to write is an empty file, apart from the CSV's heading.
        let none = MigrationMap(oldSite: "https://a.com/", newSite: "https://b.com/", rows: [map.rows[0]], newPages: [])
        XCTAssertEqual(MigrationFormat.text.render(none), "")
        XCTAssertEqual(MigrationFormat.redirects.render(none), "")
        XCTAssertEqual(MigrationFormat.webflow.render(none), "source,target\n")
        XCTAssertEqual(Set(MigrationFormat.allCases.map(\.rawValue)), ["webflow", "text", "redirects", "json"])
    }

    func testADestinationCanBeChosenByHand() throws {
        var map = sampleMap()
        map.setDestination("fresh/", for: "/gone")
        XCTAssertEqual(map.rows[5].destination, "/fresh")
        XCTAssertEqual(map.rows[5].outcome, .confident)
        XCTAssertTrue(map.rows[5].edited)
        XCTAssertEqual(map.stranded, 0)
        XCTAssertEqual(map.unclaimed, [])

        map.setDestination("/pricing", for: "/team")
        XCTAssertEqual(map.rows[2].standing, .ready)
        XCTAssertEqual(map.unclaimed, ["/crew"], "the page it was guessed to be is free again")

        map.setDestination("", for: "/pricing.html")
        XCTAssertEqual(map.rows[3].standing, .stranded)
        XCTAssertEqual(map.verdict, "4 old pages need a redirect")
        XCTAssertEqual(map.breakdown, "3 are written, 1 has no match")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(MigrationMap.self, from: encoder.encode(map)), map)
    }

    // MARK: Opening from another app

    func testReadsTheURLScheme() throws {
        func site(_ link: String) -> String? { URL(string: link).flatMap(DeepLink.site) }
        XCTAssertEqual(site("launchcheck://open?site=example.com"), "example.com")
        XCTAssertEqual(site("LAUNCHCHECK://open?site=https%3A%2F%2Fwww.example.com%2F"), "https://www.example.com/")
        XCTAssertEqual(site("launchcheck://open?ref=launchwatch&site=%20example.com%20"), "example.com")
        XCTAssertNil(site("launchcheck://open"))
        XCTAssertNil(site("launchcheck://open?site="))
        XCTAssertNil(site("launchcheck://open?site=not%20a%20site"))
        XCTAssertNil(site("launchcheck://check?site=example.com"))
        XCTAssertNil(site("https://open?site=example.com"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launchcheck-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = History(directory: directory)
        XCTAssertNil(history.latest(matching: "example.com"))
        history.save(Report(site: "https://www.example.com/", date: Date(timeIntervalSince1970: 1_700_000_000), pagesChecked: 7, pagesFound: 7,
                            linksChecked: 0, seconds: 1, findings: [], passed: []))
        XCTAssertEqual(history.latest(matching: "example.com")?.pagesChecked, 7, "kept under www, asked for without")
        XCTAssertEqual(history.latest(matching: "https://www.example.com/pricing")?.pagesChecked, 7)
        XCTAssertNil(history.latest(matching: "other.org"))
    }

    // MARK: How to fix it

    func testEveryCheckSaysHowToFixIt() {
        for check in Check.all {
            XCTAssertNotNil(check.fix, "\(check.id) has no fix")
            if check.webflow != nil { XCTAssertNotNil(check.fix, "\(check.id) names a place in Webflow but not how to fix it") }
            for text in [check.fix, check.webflow].compactMap({ $0 }) {
                XCTAssertFalse(text.contains("\u{2013}") || text.contains("\u{2014}") || text.replacingOccurrences(of: "<!doctype", with: "").contains("!"), "\(check.id): \(text)")
                XCTAssertFalse(text.isEmpty)
            }
        }
        XCTAssertEqual(Set(Fixes.table.keys).subtracting(Check.all.map(\.id)), [], "guidance written for a check that does not exist")
        XCTAssertEqual(Check.named("page.noindex")?.webflow?.hasPrefix("Page settings → SEO settings"), true)
        XCTAssertNil(Check.named("security.hsts")?.webflow, "Webflow has no setting for response headers")
    }

    func testReportsRememberWhatTheSiteWasBuiltWith() throws {
        // A report kept before the field existed still opens.
        let kept = """
        {"site":"https://acme.com/","date":"2025-11-01T10:00:00Z","pagesChecked":1,"pagesFound":1,"linksChecked":0,"seconds":1,
         "findings":[{"check":"page.noindex","url":"https://acme.com/a","detail":"robots meta tag"}],"passed":["title.missing"],"pages":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(Report.self, from: Data(kept.utf8))
        XCTAssertNil(report.builtWith)
        XCTAssertFalse(report.isWebflow)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertFalse(ReportFormat.json(report).contains("builtWith"), "nothing is written when nothing is known")

        var markdown = ReportFormat.markdown(report)
        XCTAssertTrue(markdown.contains("How to fix: Remove the noindex"))
        XCTAssertFalse(markdown.contains("In Webflow:"))

        report.builtWith = "Webflow"
        XCTAssertEqual(try decoder.decode(Report.self, from: Data(ReportFormat.json(report).utf8)), report)
        markdown = ReportFormat.markdown(report)
        XCTAssertTrue(markdown.contains("In Webflow: Page settings → SEO settings → turn Sitemap indexing on."))
        XCTAssertEqual(ReportFormat.fixLines(for: Check.named("sitemap.too-big")!, webflow: true).count, 1)
    }

    func testAuditsNoticeWebflow() async throws {
        let web = StubFetcher()
        web.answers["https://wf.example.com/"] = .init(body: "<!doctype html><html data-wf-site=\"1\"><head><title>Built in Webflow</title></head><body><h1>Hi</h1></body></html>")
        web.answers["https://plain.example.com/"] = .init(body: "<!doctype html><html><head><title>Written by hand</title></head><body><h1>Hi</h1></body></html>")
        let webflow = try await Auditor(fetcher: web).run("wf.example.com")
        XCTAssertEqual(webflow.builtWith, "Webflow")
        let plain = try await Auditor(fetcher: web).run("plain.example.com")
        XCTAssertNil(plain.builtWith)
    }
}
