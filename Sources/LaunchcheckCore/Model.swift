import Foundation

public enum Severity: Int, Codable, Comparable, CaseIterable, Sendable {
    case error      // fix before launch
    case warning    // should fix
    case notice     // worth a look

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .error: return "Fix before launch"
        case .warning: return "Should fix"
        case .notice: return "Worth a look"
        }
    }

    /// Points a failed check of this severity takes off its area's score when it affects the whole site.
    var deduction: Double {
        switch self {
        case .error: return 35
        case .warning: return 12
        case .notice: return 4
        }
    }
}

/// The areas a report is divided into. `weight` is the area's share of the overall score.
public enum Category: String, Codable, CaseIterable, Sendable {
    case indexing, sitemap, links, content, sharing, structured, ai, images, performance, security, international

    public var title: String {
        switch self {
        case .indexing: return "Indexing"
        case .sitemap: return "Sitemap"
        case .links: return "Links"
        case .content: return "Content"
        case .sharing: return "Sharing"
        case .structured: return "Structured data"
        case .ai: return "AI search"
        case .images: return "Images"
        case .performance: return "Performance"
        case .security: return "Security"
        case .international: return "International"
        }
    }

    public var blurb: String {
        switch self {
        case .indexing: return "Whether search engines can reach and keep each page"
        case .sitemap: return "What the sitemap lists, and whether it is true"
        case .links: return "Links, redirects and how pages connect"
        case .content: return "Titles, descriptions, headings and text"
        case .sharing: return "How links look when shared"
        case .structured: return "Schema.org markup for rich results"
        case .ai: return "Access for AI search engines and assistants"
        case .images: return "Alt text, weight and layout stability"
        case .performance: return "What can be told about speed from the server's answer"
        case .security: return "HTTPS and the headers that protect visitors"
        case .international: return "Language and region targeting"
        }
    }

    /// The name to type on the command line: "structured", "ai", "sitemap".
    public var key: String { rawValue }

    /// Reads an area from what someone typed: its key, or its title with or without spaces ("structured-data", "AI search").
    public static func named(_ text: String) -> Category? {
        let wanted = text.lowercased().filter { $0.isLetter }
        return allCases.first { $0.rawValue == wanted || $0.title.lowercased().filter(\.isLetter) == wanted }
    }

    public var weight: Double {
        switch self {
        case .indexing: return 14
        case .sitemap: return 6
        case .links: return 10
        case .content: return 22
        case .sharing: return 6
        case .structured: return 10
        case .ai: return 8
        case .images: return 6
        case .performance: return 8
        case .security: return 6
        case .international: return 4
        }
    }
}

/// One thing the audit looks for. `title` is how it reads when it fails, `passed` when it does not.
public struct Check: Equatable, Sendable {
    public let id: String
    public let severity: Severity
    public let category: Category
    public let title: String
    public let passed: String
    public let why: String
    /// How to fix it, in a sentence or two. The words live in Fixes.swift, keyed by `id`.
    public let fix: String?
    /// Where the fix is made on a site built with Webflow, when Webflow has a specific place for it.
    public let webflow: String?

    /// Every check, most serious first, in the order a report lists them.
    public static let all: [Check] = errors + warnings + notices

    private static let errors: [Check] = [
        Check("robots.blocks-all", .error, .indexing, "robots.txt blocks every crawler", "robots.txt lets crawlers in",
              "A leftover “Disallow: /” keeps the whole site out of search. Remove it from robots.txt."),
        Check("robots.error", .error, .indexing, "robots.txt answers with a server error", "robots.txt answers properly",
              "Crawlers treat a server error on robots.txt as “stay out of everything”. It must answer with the file or a plain 404."),
        Check("page.noindex", .error, .indexing, "Pages are set to noindex", "No page is hidden from search engines",
              "A noindex tag or header tells search engines to drop the page. It is often left on from staging."),
        Check("sitemap.broken", .error, .sitemap, "Sitemap lists pages that do not load", "Every sitemap page loads",
              "Search engines are being sent to pages that return an error. Remove them from the sitemap or restore the pages."),
        Check("sitemap.offsite", .error, .sitemap, "Sitemap lists pages on another domain", "Sitemap stays on this domain",
              "A sitemap should only list this site's own pages. Other domains here usually mean it was generated on staging."),
        Check("sitemap.too-big", .error, .sitemap, "A sitemap file lists more than 50,000 pages", "Sitemap files are within the size limit",
              "Search engines stop reading a sitemap file at 50,000 addresses. Split it and list the parts in a sitemap index."),
        Check("staging.leftovers", .error, .indexing, "Pages still point at a staging domain", "No links to staging domains",
              "Links, canonicals or share images that point at a staging address will send visitors and search engines to the wrong site."),
        Check("canonical.offsite", .error, .indexing, "Canonical tags point to another domain", "Canonical tags stay on this domain",
              "A canonical on another domain tells search engines the real page lives there, and this one gets dropped."),
        Check("title.missing", .error, .content, "Pages have no title", "Every page has a title",
              "The title is the headline of a search result. Without one, search engines make something up."),
        Check("links.internal", .error, .links, "Broken links between pages", "No broken links between pages",
              "These links go to pages on this site that do not load."),
        Check("images.broken", .error, .images, "Images do not load", "Every image loads",
              "These image addresses return an error, so visitors see a gap or a broken icon."),
        Check("social.image.broken", .error, .sharing, "Share images do not load", "Share images load",
              "The og:image address returns an error, so shared links will show no picture."),
    ]

    private static let warnings: [Check] = [
        Check("sitemap.missing", .warning, .sitemap, "No sitemap found", "Sitemap found",
              "A sitemap tells search engines which pages exist. Publish one at /sitemap.xml and name it in robots.txt."),
        Check("sitemap.redirects", .warning, .sitemap, "Sitemap lists pages that redirect", "No redirects in the sitemap",
              "List the final address of each page, not one that redirects to it."),
        Check("sitemap.blocked", .warning, .sitemap, "Sitemap lists pages that robots.txt blocks", "robots.txt blocks nothing in the sitemap",
              "The sitemap invites crawlers to pages robots.txt turns them away from. Decide which one is right."),
        Check("sitemap.noncanonical", .warning, .sitemap, "Sitemap lists pages whose canonical is another page", "Every sitemap page is its own canonical",
              "A sitemap should list the canonical address of each page. These pages say the real one is elsewhere."),
        Check("page.orphan", .warning, .links, "Pages that nothing links to", "Every page is linked from another page",
              "These pages are in the sitemap, but no page that was read links to them. Visitors cannot reach them and search engines give them little weight."),
        Check("content.js-shell", .warning, .indexing, "Pages are empty until JavaScript runs", "Pages carry their content in the HTML",
              "The HTML the server sends has almost no text, only a mount point for a script. Crawlers and AI assistants that do not run JavaScript see a blank page."),
        Check("head.duplicates", .warning, .content, "Pages repeat a tag that should appear once", "No repeated title, description or canonical tags",
              "With two titles, descriptions or canonicals in one page, it is a toss-up which one a search engine reads."),
        Check("title.duplicate", .warning, .content, "Pages share the same title", "Every title is unique",
              "Pages with the same title compete with each other and look identical in search results."),
        Check("description.missing", .warning, .content, "Pages have no meta description", "Every page has a meta description",
              "The description is the text under the title in a search result. Without one, search engines pick a snippet themselves."),
        Check("description.duplicate", .warning, .content, "Pages share the same meta description", "Every meta description is unique",
              "A description copied across pages says nothing about any one of them."),
        Check("canonical.missing", .warning, .indexing, "Pages have no canonical tag", "Every page has a canonical tag",
              "A canonical tag names the one true address of a page, so tracking parameters and duplicates do not split its ranking."),
        Check("h1.missing", .warning, .content, "Pages have no H1", "Every page has an H1",
              "The H1 is the page's main heading, for readers and search engines alike."),
        Check("charset.missing", .warning, .content, "Pages do not declare a character set", "Every page declares a character set",
              "Without a charset, browsers guess, and accented letters and symbols can turn into gibberish."),
        Check("page.nofollow", .warning, .indexing, "Pages tell crawlers not to follow their links", "No page is set to nofollow",
              "A page-level nofollow stops search engines passing through to the pages it links to."),
        Check("meta.refresh", .warning, .links, "Pages redirect with a meta refresh", "No meta refresh redirects",
              "A meta refresh is a slow, unreliable redirect. Use a server-side 301 instead."),
        Check("redirect.chain", .warning, .links, "Redirects that pass through more than one hop", "No redirect chains",
              "Each extra hop slows the visitor down and wastes crawl budget. Point the first address straight at the last."),
        Check("links.empty", .warning, .links, "Links have no text", "Every link says where it goes",
              "A link with no words and no image description tells neither a screen reader nor a search engine where it leads."),
        Check("social.image.missing", .warning, .sharing, "Pages have no share image", "Every page has a share image",
              "Without an og:image, links shared on social apps and in chats show a blank card."),
        Check("images.alt", .warning, .images, "Images have no alt text", "Every image has an alt attribute",
              "Alt text is what screen readers speak and what search engines read. Decorative images should have an empty alt, not a missing one."),
        Check("images.heavy", .warning, .images, "Images over 500 KB", "No image is over 500 KB",
              "Images this large slow the page noticeably, most of all on phones. Resize or recompress them."),
        Check("viewport.missing", .warning, .content, "Pages have no viewport tag", "Every page has a viewport tag",
              "Without a viewport tag the page renders zoomed out on phones, and Google indexes the mobile version."),
        Check("links.external", .warning, .links, "Broken links to other sites", "No broken links to other sites",
              "These links go to pages on other sites that no longer exist."),
        Check("mixed.content", .warning, .security, "Pages load files over plain http", "Nothing loads over plain http",
              "Browsers block or flag http files on an https page."),
        Check("placeholder.text", .warning, .content, "Placeholder text left in", "No placeholder text",
              "“Lorem ipsum” is still on the page."),
        Check("https.redirect", .warning, .security, "http:// does not redirect to https://", "http:// redirects to https://",
              "Visitors and links using the old http address should land on the secure one."),
        Check("security.hsts", .warning, .security, "No Strict-Transport-Security header", "Strict-Transport-Security is set",
              "This header tells browsers to always use https for the site, closing the gap where a first visit can be intercepted."),
        Check("host.duplicate", .warning, .indexing, "The site answers on both www and non-www", "www and non-www resolve to one address",
              "Two addresses serving the same pages split links and ranking between them. Redirect one to the other."),
        Check("notfound.soft", .warning, .indexing, "Missing pages do not return a 404", "Missing pages return a 404",
              "An address that does not exist should say so with a 404 status, or search engines index error pages as real content."),
        Check("page.too-large", .warning, .performance, "Pages over 2 MB of HTML", "No page is over 2 MB of HTML",
              "Googlebot reads only the first 2 MB of a page's HTML. Anything after that, including structured data, is not indexed."),
        Check("perf.uncompressed", .warning, .performance, "Pages are sent uncompressed", "Pages are sent compressed",
              "Turning on gzip or Brotli on the server typically cuts HTML to a quarter of its size."),
        Check("schema.invalid", .warning, .structured, "Structured data that cannot be read", "Structured data parses",
              "A JSON-LD block with a syntax error is ignored entirely, along with any rich result it would have earned."),
        Check("schema.incomplete", .warning, .structured, "Structured data is missing required properties", "Structured data has its required properties",
              "Without these properties the markup does not qualify for the rich result it describes."),
        Check("schema.placeholder", .warning, .structured, "Structured data still has template placeholders", "No placeholders in structured data",
              "Values like “[Business Name]” were never filled in."),
        Check("ai.search-blocked", .warning, .ai, "robots.txt blocks AI search crawlers", "AI search crawlers are allowed",
              "These crawlers fetch pages to answer questions in ChatGPT, Claude and Perplexity and to cite sources. Blocking them keeps the site out of those answers. Crawlers that only gather training data are a separate choice and are not flagged."),
        Check("ai.llms-invalid", .warning, .ai, "llms.txt is not in the expected format", "llms.txt is well formed",
              "An llms.txt should open with a “# Title” line and list pages as Markdown links."),
        Check("hreflang.invalid", .warning, .international, "Hreflang tags use codes that do not exist", "Hreflang codes are valid",
              "The language must be a two-letter ISO 639-1 code and the region a two-letter ISO 3166-1 code, as in en-GB. Invalid tags are ignored."),
        Check("hreflang.self", .warning, .international, "Hreflang sets do not include the page itself", "Every hreflang set includes the page itself",
              "Each page must list itself among its language versions, or the whole set can be disregarded."),
        Check("sitemap.unreadable", .warning, .sitemap, "A sitemap that is named does not load", "Every named sitemap loads",
              "robots.txt or a sitemap index points at a sitemap file that answers with an error or is not a sitemap. Pages listed only there go unannounced."),
        Check("robots.blocks-assets", .warning, .indexing, "robots.txt blocks stylesheets or scripts", "robots.txt lets crawlers load stylesheets and scripts",
              "Google draws a page before judging it. With the files that style and build it blocked, what it sees is a broken page."),
        Check("canonical.broken", .warning, .indexing, "Canonical tags point at pages that redirect or do not load", "Canonical tags point at pages that load",
              "A canonical names the address to index. One that redirects, errors or is set to noindex leaves search engines to guess."),
        Check("content.duplicate", .warning, .content, "Pages with exactly the same text", "No two pages have the same text",
              "Two addresses carrying the same words compete with each other, and search engines keep only one of them."),
        Check("ai.llms-links", .warning, .ai, "llms.txt links to pages that do not load", "Every link in llms.txt loads",
              "The file exists to point assistants at the pages that matter. A dead link there points them at nothing."),
        Check("hreflang.noncanonical", .warning, .international, "Hreflang tags sit on pages whose canonical is another page", "Hreflang tags are only on canonical pages",
              "Search engines read hreflang from the canonical page only. On a page that names another as its canonical, the tags are ignored."),
        Check("hreflang.target", .warning, .international, "Hreflang links point at pages that redirect, do not load or are noindex", "Hreflang links point at pages that load",
              "Each language version has to be a page that loads and may be indexed, or that language drops out of the set."),
        Check("hreflang.duplicate", .warning, .international, "Hreflang sets name a language twice", "Each language appears once in a hreflang set",
              "Two different pages claiming the same language and region leave search engines to pick one, or neither."),
        Check("hreflang.return", .warning, .international, "Hreflang links are not returned", "Hreflang links point both ways",
              "If page A names B as its translation, B must name A back. One-way links are ignored."),
    ]

    private static let notices: [Check] = [
        Check("robots.missing", .notice, .indexing, "No robots.txt", "robots.txt found",
              "Not required, but it is where crawlers look first and where the sitemap is announced."),
        Check("sitemap.undeclared", .notice, .sitemap, "robots.txt does not name the sitemap", "robots.txt names the sitemap",
              "A “Sitemap:” line in robots.txt lets every crawler find it without being told."),
        Check("sitemap.lastmod", .notice, .sitemap, "Every sitemap entry has the same last-modified date", "Sitemap dates vary by page",
              "Identical dates mean the sitemap stamps the build time on everything, so search engines learn to ignore them."),
        Check("sitemap.noindex", .notice, .sitemap, "Sitemap lists pages set to noindex", "No noindex pages in the sitemap",
              "A sitemap asks for pages to be indexed; noindex asks for the opposite. Remove one or the other."),
        Check("sitemap.incomplete", .notice, .sitemap, "Linked pages are missing from the sitemap", "Linked pages are all in the sitemap",
              "These pages are linked from the site and load fine, but the sitemap does not mention them."),
        Check("page.deep", .notice, .links, "Pages more than three clicks from the home page", "Every page is within three clicks of home",
              "The further a page is from the home page, the less often it is crawled and the less weight it carries."),
        Check("links.redirect", .notice, .links, "Links between pages go through a redirect", "Links between pages go straight there",
              "Link to the final address. It saves visitors a round trip and keeps the link's full value."),
        Check("redirect.temporary", .notice, .links, "Redirects marked as temporary", "Redirects are permanent",
              "A 302 or 307 says the move is temporary, so search engines keep the old address. Use a 301 for a move that is meant to last."),
        Check("links.generic", .notice, .links, "Links that just say “click here”", "Link text describes its destination",
              "Words like “click here” or “read more” waste the one place a link can say what it leads to."),
        Check("links.insecure", .notice, .security, "Links to http:// addresses", "No links to http:// addresses",
              "These links leave a secure page for an insecure address. Most destinations have an https version."),
        Check("url.hygiene", .notice, .indexing, "Addresses that are long or untidy", "Addresses are short and tidy",
              "Capital letters, underscores, doubled slashes and very long addresses are harder to share and easier to mistype."),
        Check("title.length", .notice, .content, "Titles are very short or very long", "Titles are a sensible length",
              "Search results show roughly 60 characters. Longer titles get cut off; very short ones waste the space."),
        Check("description.length", .notice, .content, "Meta descriptions are very short or very long", "Meta descriptions are a sensible length",
              "Search results show roughly 160 characters. Aim for 50 to 160."),
        Check("canonical.mismatch", .notice, .indexing, "Canonical tags point to a different page", "Canonical tags match their pages",
              "This can be deliberate. If it is not, the page is telling search engines to index a different one instead."),
        Check("h1.multiple", .notice, .content, "Pages have more than one H1", "No page has more than one H1",
              "One main heading per page keeps the outline clear."),
        Check("heading.skip", .notice, .content, "Headings skip a level", "Headings step down one level at a time",
              "An H2 followed by an H4 leaves a hole in the outline that screen readers and AI summaries rely on."),
        Check("content.thin", .notice, .content, "Pages with under 200 words", "Every page has at least 200 words",
              "There is little here for a search engine to rank. Fine for a contact page, a problem for a page meant to be found."),
        Check("doctype.missing", .notice, .content, "Pages have no doctype", "Every page has a doctype",
              "Without <!doctype html> browsers fall back to a legacy rendering mode."),
        Check("social.text.missing", .notice, .sharing, "Pages are missing share titles or descriptions", "Every page has a share title and description",
              "og:title and og:description control the text on a shared link."),
        Check("social.twitter.missing", .notice, .sharing, "Pages have no Twitter card tag", "Every page has a Twitter card tag",
              "A twitter:card tag chooses between a small thumbnail and a large image when the link is posted on X."),
        Check("social.url.mismatch", .notice, .sharing, "og:url differs from the canonical", "og:url matches the canonical",
              "Shares and likes are counted against og:url. If it differs from the canonical they are credited to a different address."),
        Check("images.large", .notice, .images, "Images over 200 KB", "No image is over 200 KB",
              "Worth a second look: most content images can be well under 200 KB in a modern format."),
        Check("images.dimensions", .notice, .images, "Images have no width and height", "Every image has a width and height",
              "Without both attributes the browser cannot reserve space, so the page jumps as images arrive."),
        Check("images.alt-quality", .notice, .images, "Alt text that says nothing", "Alt text is descriptive",
              "A filename, a single generic word or a paragraph is not a description. Aim for a short phrase saying what the image shows."),
        Check("images.first-lazy", .notice, .images, "The first image on the page is lazy-loaded", "The first image loads eagerly",
              "Lazy-loading the first image usually delays the largest thing on screen. Keep lazy loading for images further down."),
        Check("perf.slow", .notice, .performance, "Pages are slow to start answering", "Pages start answering within a second",
              "The server took over a second to begin its reply, measured from this Mac. Everything else on the page waits on that."),
        Check("perf.blocking-scripts", .notice, .performance, "Scripts in the head hold up the page", "No render-blocking scripts in the head",
              "A script in the head without async or defer stops the page drawing until it has downloaded and run."),
        Check("security.headers", .notice, .security, "Recommended security headers are missing", "Recommended security headers are set",
              "Not a ranking factor, but each of these closes off a common attack on visitors."),
        Check("schema.missing", .notice, .structured, "No structured data on the site", "The site has structured data",
              "Schema.org markup tells search engines what a page is (an organisation, an article, a product) and unlocks rich results."),
        Check("schema.recommended", .notice, .structured, "Structured data is missing recommended properties", "Structured data has its recommended properties",
              "The markup is read without these, but they are what puts a logo, a date or an author beside the result. Each one missing is a chance left open."),
        Check("schema.deprecated", .notice, .structured, "Structured data types that no longer earn a rich result", "No retired structured data types",
              "Search engines have stopped showing rich results for these types. They do no harm, but they no longer do any good."),
        Check("ai.llms-missing", .notice, .ai, "No llms.txt", "llms.txt found",
              "An optional Markdown file at /llms.txt that points AI assistants at the pages that matter. Search engines ignore it."),
        Check("hreflang.x-default", .notice, .international, "Hreflang sets have no x-default", "Hreflang sets have an x-default",
              "x-default names the page for visitors whose language is not listed."),
        Check("sitemap.lastmod-invalid", .notice, .sitemap, "Sitemap dates are in the future or are not dates", "Sitemap dates are real dates",
              "A last-modified date has to be a day that has happened, written as 2026-02-07. Search engines stop trusting a sitemap whose dates cannot be true."),
        Check("page.nosnippet", .notice, .indexing, "Pages forbid search snippets", "No page forbids search snippets",
              "nosnippet or max-snippet:0 shows the page in search with no description, and keeps it out of AI answers. Sometimes deliberate, rarely wanted on a marketing page."),
        Check("viewport.zoom", .notice, .content, "Pages stop visitors zooming", "Every page can be zoomed",
              "user-scalable=no or a maximum-scale of 1 stops people enlarging text they cannot read."),
        Check("content.undated", .notice, .content, "Articles show no date", "Articles carry a date",
              "These pages say they are articles but give no publication date in the markup. Readers, search engines and AI assistants all weigh how fresh an article is."),
        Check("trust.contact", .notice, .content, "No contact or about page linked from the home page", "The home page links to a contact or about page",
              "A way to reach the people behind a site is one of the first things a visitor looks for, and one of the first signs of a site that can be trusted."),
        Check("ai.fetch-blocked", .notice, .ai, "robots.txt blocks assistants fetching pages for their users", "Assistants may fetch pages for their users",
              "When someone pastes a link into ChatGPT, Claude or Perplexity, these agents fetch the page. Blocked, the assistant can say nothing about it."),
        Check("images.format", .notice, .images, "Images are not offered in a modern format", "Images are offered in a modern format",
              "These are sent as JPEG or PNG even to a browser that asks for WebP or AVIF, which are typically a third smaller."),
        Check("images.no-lazy", .notice, .images, "Pages load every image at once", "Long pages lazy-load their images",
              "With ten or more images and none marked lazy, the browser fetches them all before the visitor has scrolled."),
        Check("social.image.relative", .notice, .sharing, "Share images are not given as full addresses", "Share images are given as full addresses",
              "og:image should start with https://. Some apps do not resolve a relative address, and show no picture."),
        Check("schema.values", .notice, .structured, "Structured data has values in the wrong form", "Structured data values are well formed",
              "Dates should be written as 2026-02-07 and addresses in full. A value in another form is skipped, and the property counts as missing."),
        Check("hreflang.protocol", .notice, .international, "Hreflang sets mix http and https", "Hreflang sets use one protocol",
              "Every address in a set should use https. A stray http address redirects, and the pair it belongs to stops matching."),
        Check("lang.missing", .notice, .content, "Pages do not declare a language", "Every page declares a language",
              "The lang attribute on <html> helps screen readers and translation tools."),
        Check("favicon.missing", .notice, .content, "No favicon", "Favicon found",
              "The small icon in browser tabs and some search results."),
    ]

    public static func named(_ id: String) -> Check? { all.first { $0.id == id } }

    init(_ id: String, _ severity: Severity, _ category: Category, _ title: String, _ passed: String, _ why: String) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.passed = passed
        self.why = why
        let guidance = Fixes.table[id]
        fix = guidance?.fix
        webflow = guidance?.webflow
    }
}

/// One place a check failed.
public struct Finding: Codable, Equatable, Identifiable, Sendable {
    public let check: String
    /// The page it was found on, when there is one.
    public let url: String?
    public let detail: String?

    public var id: String { "\(check)|\(url ?? "")|\(detail ?? "")" }

    public init(_ check: String, url: URL? = nil, detail: String? = nil) {
        self.check = check
        self.url = url?.absoluteString
        self.detail = detail
    }
}

/// What was read from one page, kept so a report can show the page and so two reports can be compared.
public struct PageSummary: Codable, Equatable, Identifiable, Sendable {
    public var url: String
    public var status: Int
    public var title: String?
    public var description: String?
    public var canonical: String?
    public var robots: String?
    public var h1: [String]
    public var h2: [String]
    public var words: Int
    public var images: Int
    public var milliseconds: Int
    public var bytes: Int
    public var indexable: Bool
    /// Clicks from the home page, when it could be worked out.
    public var depth: Int?
    public var inboundLinks: Int
    public var schemaTypes: [String]
    public var shareTitle: String?
    public var shareDescription: String?
    public var shareImage: String?
    public var hasShareTags: Bool
    /// The Open Graph and Twitter tags as written ("og:title", "twitter:card"), with image addresses made absolute.
    /// Absent from reports kept before this was recorded; `shareTitle`, `shareDescription` and `shareImage` stand in.
    public var shareTags: [String: String]?
    /// Every JSON-LD block on the page, taken apart: its items, their fields and what each is missing.
    /// Absent from reports kept before this was recorded.
    public var schema: [SchemaBlock]?
    /// Other structured data written into the markup, noted but not validated: "Microdata", "RDFa".
    public var markup: [String]?

    public var id: String { url }

    public init(url: String, status: Int, title: String? = nil, description: String? = nil, canonical: String? = nil, robots: String? = nil,
                h1: [String] = [], h2: [String] = [], words: Int = 0, images: Int = 0, milliseconds: Int = 0, bytes: Int = 0,
                indexable: Bool = true, depth: Int? = nil, inboundLinks: Int = 0, schemaTypes: [String] = [],
                shareTitle: String? = nil, shareDescription: String? = nil, shareImage: String? = nil, hasShareTags: Bool = false,
                shareTags: [String: String]? = nil, schema: [SchemaBlock]? = nil, markup: [String]? = nil) {
        self.url = url
        self.status = status
        self.title = title
        self.description = description
        self.canonical = canonical
        self.robots = robots
        self.h1 = h1
        self.h2 = h2
        self.words = words
        self.images = images
        self.milliseconds = milliseconds
        self.bytes = bytes
        self.indexable = indexable
        self.depth = depth
        self.inboundLinks = inboundLinks
        self.schemaTypes = schemaTypes
        self.shareTitle = shareTitle
        self.shareDescription = shareDescription
        self.shareImage = shareImage
        self.hasShareTags = hasShareTags
        self.shareTags = shareTags
        self.schema = schema
        self.markup = markup
    }
}

public struct Options: Sendable {
    public var maxPages = 200
    public var checkExternalLinks = true
    public var checkImages = true
    public var concurrency = 6
    public var maxLinkChecks = 1500
    public var maxImageChecks = 300
    /// The areas to check. nil checks everything; anything else makes a partial report that says which areas it covers.
    public var areas: Set<Category>?
    /// Check the one address that was given and nothing else, where a site check would read the whole sitemap.
    public var singlePage = false

    public init() {}
}

public struct AuditProgress: Sendable {
    public var phase: String
    public var done: Int
    public var total: Int

    public init(phase: String, done: Int = 0, total: Int = 0) {
        self.phase = phase
        self.done = done
        self.total = total
    }
}

public struct Report: Codable, Equatable, Sendable {
    public var site: String
    public var date: Date
    public var pagesChecked: Int
    /// Pages the sitemap or crawl turned up; larger than `pagesChecked` when the page limit cut the run short.
    public var pagesFound: Int
    public var linksChecked: Int
    public var seconds: Double
    public var findings: [Finding]
    /// IDs of checks that ran and found nothing.
    public var passed: [String]
    public var pages: [PageSummary]
    /// What the site was built with, when it says so ("Webflow"). Absent from reports kept before this was recorded.
    public var builtWith: String?
    /// The areas that were checked, by key, when not all of them were. nil for a full check, and for every report kept before areas could be chosen.
    public var areas: [String]?
    /// The one address that was checked, when the check was of a single page and not the site.
    public var page: String?

    public init(site: String, date: Date = Date(), pagesChecked: Int, pagesFound: Int, linksChecked: Int, seconds: Double,
                findings: [Finding], passed: [String], pages: [PageSummary] = [], builtWith: String? = nil,
                areas: [String]? = nil, page: String? = nil) {
        self.site = site
        self.date = date
        self.pagesChecked = pagesChecked
        self.pagesFound = pagesFound
        self.linksChecked = linksChecked
        self.seconds = seconds
        self.findings = findings
        self.passed = passed
        self.pages = pages
        self.builtWith = builtWith
        self.areas = areas
        self.page = page
    }

    /// True when the pages carry Webflow's marks, so fixes can name the place in Webflow where they are made.
    public var isWebflow: Bool { builtWith == "Webflow" }

    public struct Group: Identifiable, Sendable {
        public let check: Check
        public let findings: [Finding]
        public var id: String { check.id }
    }

    /// Failed checks, most serious first, each with the places it failed.
    public var groups: [Group] {
        Check.all.compactMap { check in
            let hits = findings.filter { $0.check == check.id }
            return hits.isEmpty ? nil : Group(check: check, findings: hits)
        }
    }

    public func count(_ severity: Severity) -> Int {
        groups.filter { $0.check.severity == severity }.count
    }

    public var passedChecks: [Check] {
        Check.all.filter { passed.contains($0.id) }
    }

    public func findings(on page: String) -> [Finding] {
        findings.filter { $0.url == page }
    }

    public var host: String {
        URL(string: site)?.host ?? site
    }

    public var verdict: String {
        let errors = count(.error)
        let warnings = count(.warning)
        // A check of part of a site, or of one page, cannot say the site is ready. It says what it looked at, then what it found.
        if let scope = scopeName {
            if errors > 0 { return "\(scope): \(errors == 1 ? "1 thing" : "\(errors) things") to fix before launch" }
            if warnings > 0 { return "\(scope): \(warnings == 1 ? "1 thing" : "\(warnings) things") to tidy" }
            return "\(scope): nothing to fix"
        }
        if errors > 0 { return errors == 1 ? "1 thing to fix before launch" : "\(errors) things to fix before launch" }
        if warnings > 0 { return warnings == 1 ? "Ready to launch, with 1 thing to tidy" : "Ready to launch, with \(warnings) things to tidy" }
        return "Ready to launch"
    }

    /// The areas this report covers, when it does not cover them all.
    public var checkedAreas: [Category]? {
        guard let areas else { return nil }
        let chosen = Category.allCases.filter { areas.contains($0.rawValue) }
        return chosen.count == Category.allCases.count ? nil : chosen
    }

    /// True when only some areas were checked, or only one page.
    public var isPartial: Bool { checkedAreas != nil || page != nil }

    /// "Structured data only", "Sitemap and Images only", "One page only": what a partial report covers, in a few words.
    public var scopeName: String? {
        guard isPartial else { return nil }
        var name: String
        if let chosen = checkedAreas {
            switch chosen.count {
            case 1: name = chosen[0].title
            case 2: name = "\(chosen[0].title) and \(chosen[1].title.prefix(1).lowercased() + chosen[1].title.dropFirst())"
            default: name = "\(chosen.count) areas"
            }
            if page != nil { name += ", one page" }
        } else {
            name = "One page"
        }
        return name + " only"
    }

    /// One sentence saying what a partial report did and did not look at. nil for a full check.
    public var scopeNote: String? {
        guard isPartial else { return nil }
        let what = checkedAreas.map { chosen in
            chosen.count == 1 ? "Only \(chosen[0].title) was checked" : "Only \(chosen.count) areas were checked (\(chosen.map(\.title).joined(separator: ", ")))"
        } ?? "Every area was checked"
        let whereabouts = page != nil ? ", on this one page" : ""
        return "\(what)\(whereabouts). The score covers that and nothing else."
    }

    /// Whether an area was looked at in this report.
    public func covers(_ area: Category) -> Bool {
        checkedAreas?.contains(area) ?? true
    }

    /// The structured data types in use, most common first, each with the number of pages it appears on. These are
    /// the items that stand on their own (an Article, a Product), not what is nested inside them (its author, its offer).
    public var schemaTypesInUse: [(type: String, pages: Int)] {
        var counts: [String: Int] = [:]
        for page in pages {
            // A report kept before blocks were recorded only knows every type it met.
            let own = page.schema.map { $0.flatMap(\.items).flatMap(\.types) } ?? page.schemaTypes
            for type in Set(own) { counts[type, default: 0] += 1 }
        }
        return counts.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }.map { ($0.key, $0.value) }
    }

    /// Pages carrying a JSON-LD block that could not be read.
    public var pagesWithUnreadableSchema: [PageSummary] {
        pages.filter { $0.schema?.contains { !$0.parses } ?? false }
    }

    /// The same report with everything outside some areas left out, so it can be compared fairly with a partial one.
    public func restricted(to areas: [Category]) -> Report {
        let keep = Set(areas)
        var copy = self
        copy.findings = findings.filter { Check.named($0.check).map { keep.contains($0.category) } ?? false }
        copy.passed = passed.filter { Check.named($0).map { keep.contains($0.category) } ?? false }
        copy.areas = areas.map(\.rawValue)
        return copy
    }
}

public enum AuditError: Error, LocalizedError, Equatable {
    case invalidAddress(String)
    case unreachable(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let input): return "“\(input)” is not a web address."
        case .unreachable(let site, let reason): return "Could not load \(site): \(reason)"
        }
    }
}
