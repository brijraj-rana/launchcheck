import AppKit
import LaunchcheckCore
import SwiftUI

/// Development aid: renders the window to PNGs with a made-up site, so README images never show a real client's.
@MainActor
enum Snapshot {
    static func render(to directory: String, scale: CGFloat) {
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("launchcheck-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (before, after) = sample()
        let shots: [(String, AuditModel.Tab?)] = [("overview", .overview), ("issues", .issues), ("pages", .pages), ("previews", .previews), ("schema", .schema), ("focused", .schema), ("changes", .changes), ("welcome", nil),
                                                  ("migrate", nil)]

        for dark in [false, true] {
            for (name, tab) in shots {
                let model = AuditModel(history: History(directory: scratch), loadSites: false)
                model.sites = [after] + others()
                model.address = "acme-rockets.com"
                if name == "focused" {
                    // One link, one job: the structured data of a single product page.
                    model.address = "acme-rockets.com/products/rocket-skates"
                    model.job = AuditModel.Job.focused[0]
                    model.present(onePage(of: after, "/products/rocket-skates"), comparedWith: nil, landing: .schema)
                } else if let tab {
                    model.present(after, comparedWith: before)
                    model.tab = tab
                } else {
                    model.address = ""
                }
                model.selectedIssue = "page.noindex"
                model.trail = [58, 61, 60, 66, 69, after.score]
                model.checks = [after, before]
                model.selectedPage = "https://www.acme-rockets.com/pricing"
                if tab != nil {
                    // A few issues already dealt with, as they would be halfway through a launch list.
                    model.checklist = Checklist(handled: ["links.internal": Date().addingTimeInterval(-3 * 3600), "title.duplicate": Date().addingTimeInterval(-26 * 3600),
                                                          "security.hsts": Date().addingTimeInterval(-26 * 3600), "images.heavy": Date().addingTimeInterval(-26 * 3600), "images.dimensions": Date().addingTimeInterval(-50 * 3600)])
                    model.selectedIssue = "page.noindex"
                    if name == "issues" {
                        // One level, so the handled ones at the foot of the list are in the picture.
                        model.scope = .warning
                        model.selectedIssue = "images.alt"
                    }
                    model.previewPage = "https://www.acme-rockets.com/pricing"
                    model.schemaPage = "https://www.acme-rockets.com/products/rocket-skates"
                }
                if name.hasPrefix("migrate") {
                    model.mode = .migrate
                    if name == "migrate" {
                        model.migration.old = "acme-rockets.com"
                        model.migration.new = "acme-rockets.webflow.io"
                        model.migration.present(move())
                        model.migration.select("/our-people")
                    }
                }

                let window = ContentView(model: model)
                    .frame(width: 1060, height: 720)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 8) {
                            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                                Circle().fill($0).frame(width: 12, height: 12)
                            }
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                    // The shadow belongs to a shape behind the window, so it cannot bleed through the contents.
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black).shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 24, y: 12))
                    .padding(40)
                    .environment(\.isSnapshot, true)
                    .environment(\.colorScheme, dark ? .dark : .light)

                let renderer = ImageRenderer(content: window)
                renderer.isOpaque = false
                renderer.scale = scale
                if let cg = renderer.cgImage,
                   let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? data.write(to: out.appendingPathComponent(dark ? "\(name)-dark.png" : "\(name).png"))
                }
            }
        }
        exit(0)
    }

    private static let root = "https://www.acme-rockets.com"

    /// The report a structured data check of one page would make: that page, that area, nothing else.
    private static func onePage(of report: Report, _ path: String) -> Report {
        let address = root + path
        let own = report.findings.filter { $0.url == address && Check.named($0.check)?.category == .structured }
        let failed = Set(own.map(\.check))
        return Report(site: report.site, date: Date().addingTimeInterval(-20), pagesChecked: 1, pagesFound: 1, linksChecked: 14, seconds: 0.8,
                      findings: own, passed: Check.all.filter { $0.category == .structured && !failed.contains($0.id) && $0.id != "schema.missing" }.map(\.id),
                      pages: report.pages.filter { $0.url == address }, builtWith: report.builtWith, areas: ["structured"], page: address)
    }

    // MARK: Structured data, as each kind of page would carry it

    private static let crumbs = { (trail: [(String, String?)]) -> String in
        let items = trail.enumerated().map { index, step in
            "{\"@type\":\"ListItem\",\"position\":\(index + 1),\"name\":\"\(step.0)\"\(step.1.map { ",\"item\":\"\(root)\($0)\"" } ?? "")}"
        }
        return "{\"@context\":\"https://schema.org\",\"@type\":\"BreadcrumbList\",\"itemListElement\":[\(items.joined(separator: ","))]}"
    }

    private static let organization = """
    {"@context":"https://schema.org","@graph":[
      {"@type":"Organization","@id":"\(root)/#organization","name":"Acme Rockets","url":"\(root)/","logo":{"@type":"ImageObject","url":"\(root)/img/logo.png","width":512,"height":512},
       "sameAs":["https://www.linkedin.com/company/acme-rockets","https://www.youtube.com/@acmerockets"]},
      {"@type":"WebSite","@id":"\(root)/#website","name":"Acme Rockets","url":"\(root)/","publisher":{"@id":"\(root)/#organization"},"inLanguage":"en"}]}
    """

    private static func product(_ slug: String, _ name: String, currency: Bool = true) -> [String] {
        ["""
        {"@context":"https://schema.org","@type":"Product","name":"\(name)","image":"\(root)/img/\(slug).jpg","description":"One of the Acme classics, back in stock and shipped by next-day air.",
         "sku":"ACME-\(slug.uppercased().prefix(6))","brand":{"@type":"Brand","name":"Acme"},
         "offers":{"@type":"Offer","price":"49.00",\(currency ? "\"priceCurrency\":\"USD\"," : "")"availability":"https://schema.org/InStock","url":"\(root)/products/\(slug)"},
         "aggregateRating":{"@type":"AggregateRating","ratingValue":4.6,"reviewCount":128}}
        """, crumbs([("Home", "/"), ("Products", "/products"), (name, nil)])]
    }

    private static func post(_ slug: String, _ title: String, author: Bool = true) -> [String] {
        ["""
        {"@context":"https://schema.org","@type":"BlogPosting","headline":"\(title)","image":"\(root)/img/blog/\(slug).jpg","datePublished":"2026-09-14","dateModified":"2026-10-02",
         \(author ? "\"author\":{\"@type\":\"Person\",\"name\":\"Wile E. Coyote\",\"url\":\"\(root)/team\"}," : "")"publisher":{"@id":"\(root)/#organization"},"mainEntityOfPage":"\(root)/blog/\(slug)"}
        """, crumbs([("Home", "/"), ("Blog", "/blog"), (title, nil)])]
    }

    private static func at(_ path: String) -> URL? { URL(string: root + path) }

    private static func passed(except failed: [Finding]) -> [String] {
        let ids = Set(failed.map(\.check))
        // A site in one language has no International score at all.
        let notApplicable = Set(Check.all.filter { $0.category == .international }.map(\.id))
        return Check.all.map(\.id).filter { !ids.contains($0) && !notApplicable.contains($0) }
    }

    /// Acme Rockets, rebuilt: a WordPress site on its way to Webflow.
    private static func move() -> MigrationMap {
        typealias Row = MigrationRow
        func row(_ path: String, _ outcome: Row.Outcome, _ destination: String? = nil, sure: Bool = true, note: String? = nil, title: String? = nil,
                 alternatives: [String] = []) -> Row {
            Row(old: "https://www.acme-rockets.com" + path, path: path, outcome: outcome, destination: destination, sure: sure, note: note,
                title: title, alternatives: alternatives)
        }
        let products = ["rocket-skates", "giant-magnet", "anvil-classic", "anvil-pro", "jet-boots", "dehydrated-boulders", "earthquake-pills", "tornado-kit",
                        "spring-shoes", "bird-seed", "tunnel-paint", "catapult"]
        let posts = ["why-anvils-fall", "canyon-shipping", "a-year-of-rockets", "meet-the-test-pilots", "desert-warehouse", "magnets-and-you", "safety-first"]
        let same = ["/", "/about", "/pricing", "/contact", "/blog", "/products", "/legal/privacy"]

        var rows: [Row] = [
            row("/clearance", .unmatched, note: "Nothing on the new site has a similar address or title", title: "Clearance: last year's rockets"),
            row("/dealers/arizona", .unmatched, note: "Nothing on the new site has a similar address or title", title: "Find a dealer in Arizona"),
            row("/our-people", .possible, "/team", sure: false, note: "Similar title, 81% alike", title: "The people behind Acme Rockets",
                alternatives: ["/careers/test-pilot", "/about"]),
            row("/blog/2023/11/skates-recalled", .possible, "/posts/skates-recall", sure: false, note: "Similar address, 79% alike", title: "Rocket skates recalled",
                alternatives: ["/products/rocket-skates"]),
            row("/shop/anvil", .possible, "/products/anvil-classic", sure: false, note: "2 new pages fit this address", title: "Anvils",
                alternatives: ["/products/anvil-pro"]),
            row("/jobs.php", .confident, "/careers", note: "Same page under /careers", title: "Jobs at Acme"),
            row("/Contact-Us.html", .confident, "/contact", note: "Same address once tidied", title: "Contact us"),
            row("/catalogue", .broken, "/products", note: "Gets there in 2 hops: /catalogue → /shop → /products. Point it straight at the last one.", title: "Catalogue"),
        ]
        rows += posts.enumerated().map { index, name in
            row("/blog/202\(index % 3 + 1)/\(String(format: "%02d", index + 3))/\(name)", .confident, "/posts/\(name)", note: "Same page under /posts",
                title: name.replacingOccurrences(of: "-", with: " ").capitalized)
        }
        rows += products.prefix(6).map { row("/shop/\($0)", .confident, "/products/\($0)", note: "Same page under /products", title: $0.replacingOccurrences(of: "-", with: " ").capitalized) }
        rows += [row("/faq", .redirected, "/help", note: "Already redirects to /help"), row("/press", .redirected, "/about", note: "Already redirects to /about")]
        rows += same.map { row($0, .same, $0) }
        rows += products.suffix(6).map { row("/products/\($0)", .same, "/products/\($0)") }

        var pages: [MigrationMap.NewPage] = same.map { .init(path: $0, title: $0 == "/" ? "Acme Rockets" : nil) }
        pages += [.init(path: "/team", title: "The team behind Acme Rockets"), .init(path: "/careers", title: "Careers at Acme Rockets"),
                  .init(path: "/careers/test-pilot", title: "Careers: test pilot"), .init(path: "/help", title: "Help"),
                  .init(path: "/posts/skates-recall", title: "Why we recalled the rocket skates"), .init(path: "/changelog", title: "Changelog"),
                  .init(path: "/posts/the-new-crate", title: "The new crate"), .init(path: "/compare", title: "Compare plans")]
        pages += products.map { .init(path: "/products/\($0)", title: $0.replacingOccurrences(of: "-", with: " ").capitalized) }
        pages += posts.map { .init(path: "/posts/\($0)", title: $0.replacingOccurrences(of: "-", with: " ").capitalized) }
        pages[1].title = "About Acme Rockets"
        return MigrationMap(oldSite: root + "/", newSite: "https://acme-rockets.webflow.io/", date: Date().addingTimeInterval(-40), rows: rows, newPages: pages)
    }

    /// Other sites for the sidebar, each with a believable score.
    private static func others() -> [Report] {
        let sites: [(String, [String], Double)] = [
            ("https://tidyhq.io/", [], 3),
            ("https://www.northwind-studio.com/", ["images.heavy", "content.thin", "security.headers", "links.redirect", "description.length"], 26),
            ("https://harbour-coffee.co/", ["title.missing", "links.internal", "sitemap.missing", "social.image.missing", "images.alt", "h1.missing"], 100),
        ]
        return sites.map { site, failed, hours in
            let findings = failed.map { Finding($0, url: URL(string: site)) }
            return Report(site: site, date: Date().addingTimeInterval(-hours * 3600), pagesChecked: 3, pagesFound: 3, linksChecked: 40, seconds: 4,
                          findings: findings, passed: passed(except: findings))
        }
    }

    private static func sample() -> (before: Report, after: Report) {
        func page(_ path: String, _ title: String, _ description: String?, words: Int, images: Int = 6, depth: Int = 1, inbound: Int = 12,
                  schema: [String] = ["Organization", "WebPage"], indexable: Bool = true, h1: String? = nil, share: Bool = true,
                  card: String? = "summary_large_image", ld: [String]? = nil) -> PageSummary {
            // Product and post pages carry their own markup; the rest carry the organisation's.
            let last = String(path.split(separator: "/").last ?? "")
            let blocks = ld ?? (schema.contains("Product") ? product(last, title) : (schema.contains("BlogPosting") ? post(last, title) : (schema.isEmpty ? [] : [organization])))
            var tags: [String: String] = [:]
            if share {
                tags = ["og:title": title, "og:image": root + "/og\(path == "/" ? "/home" : path).png", "og:site_name": "Acme Rockets", "og:type": "website"]
                tags["og:description"] = description
                tags["twitter:card"] = card
            }
            return PageSummary(url: root + path, status: 200, title: title, description: description, canonical: root + path,
                        robots: indexable ? nil : "noindex", h1: [h1 ?? title], h2: ["Why Acme", "How it works"], words: words, images: images,
                        milliseconds: 180 + words % 240, bytes: 38_000 + words * 30, indexable: indexable, depth: depth, inboundLinks: inbound,
                        schemaTypes: blocks.isEmpty ? schema : SchemaInspector.inspect(blocks).types, shareTitle: share ? title : nil,
                        shareDescription: share ? description : nil, shareImage: share ? root + "/og\(path == "/" ? "/home" : path).png" : nil,
                        hasShareTags: share, shareTags: tags, schema: SchemaInspector.outline(blocks),
                        markup: path == "/blog" ? ["Microdata"] : [])
        }
        let long = "Rockets, anvils and everything a determined coyote could need, delivered to your canyon by next-day air. Compare plans, see what is in each crate and order today, with free returns for thirty days."
        let main = [
            page("/", "Home", "Acme builds rockets and anvils for people in a hurry.", words: 640, depth: 0, inbound: 48),
            page("/pricing", "Pricing for rockets, anvils and giant magnets from Acme Rockets", long, words: 410, indexable: false, card: "summary"),
            page("/about", "About Acme Rockets", "Who we are, where we build and why our anvils fall straighter than anyone else's.", words: 520),
            page("/blog", "Blog", "Notes from the workshop.", words: 180, schema: ["Blog"]),
            page("/blog/launch-day", "Launch day: what we shipped and what blew up", "A look back at the week Acme Rockets went live.", words: 1240, depth: 2, inbound: 3, schema: ["BlogPosting"], indexable: false),
            page("/blog/anvils", "A short history of the anvil", nil, words: 980, depth: 2, inbound: 2, schema: ["BlogPosting"],
                 ld: post("anvils", "A short history of the anvil", author: false)),
            page("/team", "The team behind Acme Rockets", "Engineers, test pilots and one very patient insurance broker.", words: 310, images: 12),
            page("/contact", "Contact Acme Rockets", nil, words: 90, images: 1, schema: [], share: false),
            page("/products/rocket-skates", "Rocket skates", "Strap them on and go. Brakes sold separately.", words: 450, depth: 2, inbound: 4, schema: ["Product"],
                 ld: product("rocket-skates", "Rocket skates", currency: false)),
            page("/products/giant-magnet", "Giant magnet", "Attracts everything except customers who read the manual.", words: 430, depth: 2, inbound: 4, schema: ["Product"]),
            page("/careers/test-pilot", "Careers: test pilot", "Must be comfortable with heights and sudden stops.", words: 380, depth: 4, inbound: 1),
            page("/legal/privacy", "Privacy policy", "How Acme Rockets handles your data.", words: 2100, depth: 1, inbound: 48),
        ]

        let fillers = ["anvil-classic", "anvil-pro", "jet-boots", "dehydrated-boulders", "earthquake-pills", "tornado-kit", "spring-shoes",
                       "bird-seed", "tunnel-paint", "invisible-ink", "catapult", "roller-skis", "super-outfit", "iron-carrot", "smoke-screen",
                       "glue-v2", "lightning-rod", "instant-road"]
        let posts = ["why-anvils-fall", "canyon-shipping", "a-year-of-rockets", "meet-the-test-pilots", "desert-warehouse", "returns-policy-explained",
                     "magnets-and-you", "spring-catalogue", "safety-first", "the-new-crate", "skates-recall", "hiring-in-arizona",
                     "boulder-care", "paint-that-fools", "our-first-launch", "what-we-learned", "catalogue-archive", "press-kit"]
        let pages = main
            + fillers.map { page("/products/\($0)", $0.replacingOccurrences(of: "-", with: " ").capitalized, "One of the Acme classics, back in stock.", words: 420, depth: 2, inbound: 4, schema: ["Product"]) }
            + posts.map { page("/blog/\($0)", $0.replacingOccurrences(of: "-", with: " ").capitalized, "From the Acme workshop notebook.", words: 900, depth: 2, inbound: 2, schema: ["BlogPosting"]) }

        let now: [Finding] = [
            Finding("page.noindex", url: at("/pricing"), detail: "robots meta tag"),
            Finding("page.noindex", url: at("/blog/launch-day"), detail: "robots meta tag"),
            Finding("staging.leftovers", url: at("/about"), detail: "canonical → https://acme-rockets.webflow.io/about"),
            Finding("links.internal", url: at("/"), detail: "https://www.acme-rockets.com/careers returned 404, linked from 48 pages"),
            Finding("title.duplicate", url: at("/blog"), detail: "“Blog” on 3 pages: /blog, /blog/page/2, /blog/page/3"),
            Finding("description.missing", url: at("/contact")),
            Finding("description.missing", url: at("/blog/anvils")),
            Finding("social.image.missing", url: at("/contact")),
            Finding("images.alt", url: at("/"), detail: "4 of 19 images"),
            Finding("images.alt", url: at("/team"), detail: "11 of 12 images"),
            Finding("images.heavy", url: at("/"), detail: "1.8 MB: https://www.acme-rockets.com/img/hero-canyon.png"),
            Finding("schema.incomplete", url: at("/products/rocket-skates"), detail: "Product offer has a price but no priceCurrency"),
            Finding("ai.search-blocked", url: at("/robots.txt"), detail: "PerplexityBot is disallowed"),
            Finding("security.hsts", url: at("/")),
            Finding("title.length", url: at("/"), detail: "4 characters: “Home”"),
            Finding("title.length", url: at("/pricing"), detail: "62 characters"),
            Finding("description.length", url: at("/pricing"), detail: "\(long.count) characters"),
            Finding("h1.multiple", url: at("/pricing"), detail: "3 H1s"),
            Finding("content.thin", url: at("/contact"), detail: "90 words"),
            Finding("content.thin", url: at("/blog"), detail: "180 words"),
            Finding("page.deep", url: at("/careers/test-pilot"), detail: "4 clicks from the home page"),
            Finding("links.redirect", url: at("/"), detail: "https://www.acme-rockets.com/shop → https://www.acme-rockets.com/products, linked from 48 pages"),
            Finding("images.dimensions", url: at("/team"), detail: "12 of 12 images"),
            Finding("security.headers", url: at("/"), detail: "Content-Security-Policy"),
            Finding("security.headers", url: at("/"), detail: "Referrer-Policy"),
            Finding("ai.llms-missing", url: at("/llms.txt")),
            Finding("schema.recommended", url: at("/blog/anvils"), detail: "BlogPosting has no author"),
            // Some of what the wider checklists add.
            Finding("canonical.broken", url: at("/products/anvil-pro"), detail: "https://www.acme-rockets.com/shop/anvil-pro redirects to https://www.acme-rockets.com/products/anvil-pro"),
            Finding("images.format", url: at("/team"), detail: "PNG, 164 KB: https://www.acme-rockets.com/img/team-wide.png"),
            Finding("sitemap.lastmod-invalid", url: at("/sitemap.xml"), detail: "2 entries are dated in the future, such as 2027-03-01"),
            Finding("images.alt", url: at("/products/jet-boots"), detail: "2 of 6 images"),
            Finding("description.length", url: at("/blog/returns-policy-explained"), detail: "182 characters"),
            Finding("images.dimensions", url: at("/products/catapult"), detail: "3 of 6 images"),
            Finding("content.thin", url: at("/blog/press-kit"), detail: "140 words"),
            Finding("title.length", url: at("/products/glue-v2"), detail: "7 characters: “Glue V2”"),
        ]
        let after = Report(site: root + "/", date: Date().addingTimeInterval(-40), pagesChecked: 48, pagesFound: 48, linksChecked: 312, seconds: 9.4,
                           findings: now, passed: passed(except: now), pages: pages, builtWith: "Webflow")

        // A week earlier: a few things worse, a few not yet broken.
        var earlierPages = pages
        earlierPages[1].indexable = true
        earlierPages[1].title = "Pricing"
        earlierPages[2].canonical = root + "/about-us"
        earlierPages[5].h1 = ["Anvils: a history"]
        earlierPages[8].schemaTypes = []
        earlierPages.removeLast()
        let then: [Finding] = now.filter { !["page.noindex", "ai.search-blocked", "images.heavy"].contains($0.check) } + [
            Finding("sitemap.missing", url: at("/sitemap.xml")),
            Finding("title.missing", url: at("/team")),
            Finding("social.image.broken", url: at("/"), detail: "https://www.acme-rockets.com/og/home.png returned 404, used on 31 pages"),
            Finding("h1.missing", url: at("/team")),
            Finding("mixed.content", url: at("/about"), detail: "http://cdn.acme-rockets.com/map.js"),
            Finding("perf.uncompressed", url: at("/")),
            Finding("schema.invalid", url: at("/products/giant-magnet"), detail: "a JSON-LD block is not valid JSON"),
        ]
        let before = Report(site: root + "/", date: Date().addingTimeInterval(-6 * 86_400), pagesChecked: 47, pagesFound: 47, linksChecked: 305, seconds: 9.1,
                            findings: then, passed: passed(except: then), pages: earlierPages)
        return (before, after)
    }
}
