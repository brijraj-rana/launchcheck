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
        let shots: [(String, AuditModel.Tab)] = [("overview", .overview), ("issues", .issues), ("pages", .pages), ("changes", .changes)]

        for dark in [false, true] {
            for (name, tab) in shots {
                let model = AuditModel(history: History(directory: scratch), loadSites: false)
                model.sites = [after] + others()
                model.address = "acme-rockets.com"
                model.present(after, comparedWith: before)
                model.tab = tab
                model.expanded = ["page.noindex", "staging.leftovers"]
                model.selectedPage = "https://www.acme-rockets.com/pricing"

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
                    .background(dark ? Color(white: 0.118) : Color(white: 0.985))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 24, y: 12)
                    .padding(40)
                    .environment(\.isSnapshot, true)
                    .environment(\.colorScheme, dark ? .dark : .light)

                let renderer = ImageRenderer(content: window)
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

    private static func at(_ path: String) -> URL? { URL(string: root + path) }

    private static func passed(except failed: [Finding]) -> [String] {
        let ids = Set(failed.map(\.check))
        let notApplicable: Set<String> = ["hreflang.invalid", "hreflang.self", "hreflang.return", "hreflang.x-default"]
        return Check.all.map(\.id).filter { !ids.contains($0) && !notApplicable.contains($0) }
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
                  schema: [String] = ["Organization", "WebPage"], indexable: Bool = true, h1: String? = nil, share: Bool = true) -> PageSummary {
            PageSummary(url: root + path, status: 200, title: title, description: description, canonical: root + path,
                        robots: indexable ? nil : "noindex", h1: [h1 ?? title], h2: ["Why Acme", "How it works"], words: words, images: images,
                        milliseconds: 180 + words % 240, bytes: 38_000 + words * 30, indexable: indexable, depth: depth, inboundLinks: inbound,
                        schemaTypes: schema, shareTitle: share ? title : nil,
                        shareDescription: share ? description : nil, shareImage: share ? root + "/og\(path == "/" ? "/home" : path).png" : nil,
                        hasShareTags: share)
        }
        let long = "Rockets, anvils and everything a determined coyote could need, delivered to your canyon by next-day air. Compare plans, see what is in each crate and order today."
        let pages = [
            page("/", "Home", "Acme builds rockets and anvils for people in a hurry.", words: 640, depth: 0, inbound: 48),
            page("/pricing", "Pricing for rockets, anvils and giant magnets from Acme Rockets", long, words: 410, indexable: false),
            page("/about", "About Acme Rockets", "Who we are, where we build and why our anvils fall straighter than anyone else's.", words: 520),
            page("/blog", "Blog", "Notes from the workshop.", words: 180, schema: ["Blog"]),
            page("/blog/launch-day", "Launch day: what we shipped and what blew up", "A look back at the week Acme Rockets went live.", words: 1240, depth: 2, inbound: 3, schema: ["BlogPosting"], indexable: false),
            page("/blog/anvils", "A short history of the anvil", nil, words: 980, depth: 2, inbound: 2, schema: ["BlogPosting"]),
            page("/team", "The team behind Acme Rockets", "Engineers, test pilots and one very patient insurance broker.", words: 310, images: 12),
            page("/contact", "Contact Acme Rockets", nil, words: 90, images: 1, schema: [], share: false),
            page("/products/rocket-skates", "Rocket skates", "Strap them on and go. Brakes sold separately.", words: 450, depth: 2, inbound: 4, schema: ["Product"]),
            page("/products/giant-magnet", "Giant magnet", "Attracts everything except customers who read the manual.", words: 430, depth: 2, inbound: 4, schema: ["Product"]),
            page("/careers/test-pilot", "Careers: test pilot", "Must be comfortable with heights and sudden stops.", words: 380, depth: 4, inbound: 1),
            page("/legal/privacy", "Privacy policy", "How Acme Rockets handles your data.", words: 2100, depth: 1, inbound: 48),
        ]

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
            Finding("description.length", url: at("/pricing"), detail: "167 characters"),
            Finding("h1.multiple", url: at("/pricing"), detail: "3 H1s"),
            Finding("content.thin", url: at("/contact"), detail: "90 words"),
            Finding("content.thin", url: at("/blog"), detail: "180 words"),
            Finding("page.deep", url: at("/careers/test-pilot"), detail: "4 clicks from the home page"),
            Finding("links.redirect", url: at("/"), detail: "https://www.acme-rockets.com/shop → https://www.acme-rockets.com/products, linked from 48 pages"),
            Finding("images.dimensions", url: at("/team"), detail: "12 of 12 images"),
            Finding("security.headers", url: at("/"), detail: "Content-Security-Policy"),
            Finding("security.headers", url: at("/"), detail: "Referrer-Policy"),
            Finding("ai.llms-missing", url: at("/llms.txt")),
        ]
        let after = Report(site: root + "/", date: Date().addingTimeInterval(-40), pagesChecked: 48, pagesFound: 48, linksChecked: 312, seconds: 9.4,
                           findings: now, passed: passed(except: now), pages: pages)

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
