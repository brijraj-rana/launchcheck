import Foundation

extension ReportFormat {
    /// The whole report as one HTML file, for sending to a client. Nothing in it is fetched from anywhere: no fonts,
    /// no images, no scripts. It reads in light and dark and prints cleanly. Every word that came from the site is escaped.
    /// - Parameter handled: IDs of the issues ticked as handled, which are marked and counted.
    public static func html(_ report: Report, handled: Set<String> = []) -> String {
        let groups = report.groups
        let done = groups.filter { handled.contains($0.id) }.count
        let blocked = report.count(.error) > 0
        let tone = blocked ? "bad" : (report.score >= 90 ? "good" : (report.score >= 60 ? "warn" : "bad"))
        var out: [String] = []

        out.append("""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <meta name="color-scheme" content="light dark">
        <title>Launch check: \(escape(report.host))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main>
        """)

        // Verdict, then score
        let circumference = 2 * Double.pi * 34
        let arc = circumference * Double(max(1, min(100, report.score))) / 100
        out.append("""
        <header>
        <div class="lead">
        <p class="eyebrow">Launch check · \(link(report.site, text: report.host))</p>
        <h1>\(escape(report.verdict))</h1>
        <p class="meta">\(escape(summary(report))) · \(escape(stamp(report.date)))\(report.isWebflow ? " · Built with Webflow" : "")</p>
        \(report.pagesFound > report.pagesChecked ? "<p class=\"meta\">The first \(report.pagesChecked) of \(report.pagesFound) pages were read.</p>" : "")
        \(report.scopeNote.map { "<p class=\"scope\">\(escape($0))</p>" } ?? "")
        \(report.page.map { "<p class=\"meta\">Page: \(link($0, text: $0))</p>" } ?? "")
        </div>
        <div class="score \(tone)" role="img" aria-label="Score \(report.score) of 100, \(escape(report.grade))">
        <svg viewBox="0 0 80 80" width="88" height="88" aria-hidden="true">
        <circle cx="40" cy="40" r="34" class="track"/>
        <circle cx="40" cy="40" r="34" class="arc" stroke-dasharray="\(String(format: "%.1f", arc)) \(String(format: "%.1f", circumference))" transform="rotate(-90 40 40)"/>
        <text x="40" y="49" text-anchor="middle">\(report.score)</text>
        </svg>
        <p class="grade">\(escape(report.grade))</p>
        </div>
        </header>
        """)

        // Counts
        let counts: [(String, Int, String)] = [
            ("error", report.count(.error), "to fix before launch"),
            ("warning", report.count(.warning), "should fix"),
            ("notice", report.count(.notice), "worth a look"),
            ("passed", report.passed.count, "passed"),
        ]
        out.append("<section class=\"tally\" aria-label=\"Counts\"><ul>")
        for (kind, count, label) in counts {
            out.append("<li\(count == 0 ? " class=\"none\"" : "")><i class=\"mark \(kind)\"></i><b>\(count)</b> \(label)</li>")
        }
        if done > 0 { out.append("<li class=\"handled-count\">\(done) of \(groups.count) handled</li>") }
        out.append("</ul></section>")

        // Areas
        let areas = report.categoryScores.filter { $0.score != nil }
        if !areas.isEmpty {
            out.append("<section><h2>By area</h2><table class=\"areas\"><tbody>")
            for entry in areas {
                let score = entry.score ?? 0
                let level = score >= 90 ? "good" : (score >= 60 ? "warn" : "bad")
                out.append("<tr><th scope=\"row\">\(escape(entry.category.title))</th><td class=\"bar\"><span class=\"\(level)\" style=\"width:\(max(1, score))%\"></span></td><td class=\"num\">\(score)</td></tr>")
            }
            out.append("</tbody></table></section>")
        }

        // Issues
        for severity in Severity.allCases {
            let matching = groups.filter { $0.check.severity == severity }
            guard !matching.isEmpty else { continue }
            out.append("<section><h2>\(escape(severity.label)) <span class=\"count\">\(matching.count)</span></h2>")
            for group in matching {
                let check = group.check
                let ticked = handled.contains(check.id)
                out.append("<article class=\"issue\(ticked ? " handled" : "")\" id=\"\(escape(check.id))\">")
                out.append("<h3><i class=\"mark \(kind(severity))\"></i>\(escape(check.title)) <span class=\"count\">\(group.findings.count)</span>\(ticked ? " <span class=\"tag\">Handled</span>" : "")</h3>")
                out.append("<p class=\"why\">\(escape(check.why))</p>")
                out.append("<dl>")
                out.append("<dt>Done when</dt><dd>\(escape(check.passed))</dd>")
                if let fix = check.fix { out.append("<dt>How to fix</dt><dd>\(escape(fix))</dd>") }
                if report.isWebflow, let place = check.webflow { out.append("<dt>In Webflow</dt><dd>\(escape(place))</dd>") }
                out.append("</dl>")
                out.append("<ul class=\"found\">")
                for finding in group.findings {
                    let place = finding.url.map { link($0, text: short($0, site: report.site)) } ?? ""
                    let detail = finding.detail.map { "<span class=\"detail\">\(escape($0))</span>" } ?? ""
                    out.append("<li>\(place.isEmpty ? "" : "<span class=\"path\">\(place)</span>")\(detail)</li>")
                }
                out.append("</ul></article>")
            }
            out.append("</section>")
        }
        if groups.isEmpty {
            out.append("<section><h2>Nothing to fix</h2><p class=\"why\">Every check that ran passed.</p></section>")
        }

        // Structured data, when it was looked at
        if report.covers(.structured), report.pages.contains(where: { !$0.schemaTypes.isEmpty || !($0.schema ?? []).isEmpty }) {
            out.append("<section><h2>Structured data</h2>")
            let types = report.schemaTypesInUse
            if !types.isEmpty {
                out.append("<table class=\"areas types\"><tbody>")
                for entry in types {
                    out.append("<tr><th scope=\"row\">\(escape(entry.type))</th><td class=\"num\">\(entry.pages == 1 ? "1 page" : "\(entry.pages) pages")</td></tr>")
                }
                out.append("</tbody></table>")
            }
            // One page, or a handful: every block taken apart. A whole site gets the summary above.
            let detailed = report.pages.filter { !($0.schema ?? []).isEmpty }
            if detailed.count <= 12 {
                for page in detailed {
                    out.append("<h3 class=\"path sub\">\(link(page.url, text: short(page.url, site: report.site)))</h3>")
                    for block in page.schema ?? [] {
                        if let error = block.error { out.append("<p class=\"why\"><i class=\"mark warning\"></i>Block \(block.index): \(escape(error))</p>") }
                        for item in block.items { out.append(render(item, block: block.index)) }
                    }
                    if let markup = page.markup, !markup.isEmpty {
                        out.append("<p class=\"meta\">Also found, not checked: \(escape(markup.joined(separator: " and ")))</p>")
                    }
                }
            }
            out.append("</section>")
        }

        // Passed
        let passed = report.passedChecks
        if !passed.isEmpty {
            out.append("<section class=\"passed\"><h2>Passed <span class=\"count\">\(passed.count)</span></h2><ul>")
            for check in passed { out.append("<li><i class=\"mark passed\"></i>\(escape(check.passed))</li>") }
            out.append("</ul></section>")
        }

        // Pages
        if !report.pages.isEmpty {
            let perPage = Dictionary(report.findings.compactMap(\.url).map { ($0, 1) }, uniquingKeysWith: +)
            out.append("<section><h2>Pages <span class=\"count\">\(report.pages.count)</span></h2>")
            out.append("<table class=\"pages\"><thead><tr><th scope=\"col\">Page</th><th scope=\"col\">Title</th><th scope=\"col\" class=\"num\">Status</th><th scope=\"col\" class=\"num\">Words</th><th scope=\"col\" class=\"num\">To fix</th></tr></thead><tbody>")
            for page in report.pages {
                let title = (page.title ?? "").isEmpty ? "<span class=\"bad-text\">No title</span>" : escape(page.title ?? "")
                let status = "\(page.status)" + (page.indexable ? "" : " <span class=\"bad-text\">noindex</span>")
                let found = perPage[page.url] ?? 0
                out.append("<tr><td class=\"path\">\(link(page.url, text: short(page.url, site: report.site)))</td><td>\(title)</td><td class=\"num\">\(status)</td><td class=\"num\">\(page.words)</td><td class=\"num\">\(found == 0 ? "<span class=\"quiet\">0</span>" : "\(found)")</td></tr>")
            }
            out.append("</tbody></table></section>")
        }

        out.append("""
        <footer>Checked with <a href="https://github.com/brijraj-rana/launchcheck">Launchcheck</a>. Pages are read the way a crawler reads them, without running JavaScript.</footer>
        </main>
        </body>
        </html>
        """)
        return out.joined(separator: "\n") + "\n"
    }

    private static func render(_ item: SchemaItem, block: Int) -> String {
        var out = "<div class=\"item\"><p class=\"type\"><b>\(escape(item.name))</b>"
        if let role = item.role { out += " <span class=\"quiet\">as \(escape(role))</span>" } else { out += " <span class=\"quiet\">block \(block)</span>" }
        if let result = item.richResult { out += " <span class=\"tag\">\(escape(result))</span>" }
        out += "</p>"
        if !item.fields.isEmpty {
            out += "<dl class=\"fields\">"
            for field in item.fields { out += "<dt>\(escape(field.name))</dt><dd>\(escape(field.value))</dd>" }
            out += "</dl>"
        }
        if !(item.required + item.recommended + item.notes).isEmpty {
            out += "<ul class=\"found\">"
            for line in item.required { out += "<li><i class=\"mark warning\"></i>\(escape(line))</li>" }
            for line in item.recommended { out += "<li><i class=\"mark notice\"></i>\(escape(line))</li>" }
            for line in item.notes { out += "<li><i class=\"mark notice\"></i>\(escape(line))</li>" }
            out += "</ul>"
        }
        for child in item.children { out += render(child, block: block) }
        return out + "</div>"
    }

    /// Makes a text safe to put in HTML, as content or inside a quoted attribute.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// A link when the address is plainly a web address, and plain text otherwise: a report must never carry a
    /// javascript: link that a site slipped into its own markup.
    private static func link(_ address: String, text: String) -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return escape(text)
        }
        return "<a href=\"\(escape(address))\">\(escape(text))</a>"
    }

    private static func kind(_ severity: Severity) -> String {
        switch severity {
        case .error: return "error"
        case .warning: return "warning"
        case .notice: return "notice"
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    private static let css = """
    :root{--surface:#fdfcfb;--raised:#fff;--ink:#1a1714;--soft:#6f6a63;--faint:#a39e96;--line:rgba(26,23,20,.1);--wash:rgba(26,23,20,.045);--bad:#d6382e;--warn:#cc8209;--good:#1f9459;--dot:#8f8f8f}
    @media (prefers-color-scheme:dark){:root{--surface:#1b1b1a;--raised:#262524;--ink:#f2f0eb;--soft:#a5a19a;--faint:#74716b;--line:rgba(242,240,235,.12);--wash:rgba(242,240,235,.06);--bad:#fa6e61;--warn:#f5b342;--good:#59cc8a;--dot:#858585}}
    *{box-sizing:border-box}
    html{-webkit-text-size-adjust:100%}
    body{margin:0;background:var(--surface);color:var(--ink);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
    main{max-width:820px;margin:0 auto;padding:56px 28px 72px}
    a{color:inherit;text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:3px}
    a:hover{text-decoration-color:currentColor}
    header{display:flex;gap:28px;align-items:flex-start;justify-content:space-between}
    .lead{min-width:0}
    .eyebrow{margin:0 0 10px;font-size:12px;font-weight:600;color:var(--soft)}
    h1{margin:0;font-size:32px;line-height:1.15;letter-spacing:-.02em;font-weight:650}
    .meta{margin:10px 0 0;font-size:12.5px;color:var(--soft);font-variant-numeric:tabular-nums}
    .score{flex:none;text-align:center}
    .score svg{display:block}
    .score circle{fill:none;stroke-width:6}
    .score .track{stroke:var(--line)}
    .score .arc{stroke-linecap:round}
    .score text{font-size:27px;font-weight:650;fill:var(--ink);font-variant-numeric:tabular-nums}
    .score.good .arc{stroke:var(--good)}.score.warn .arc{stroke:var(--warn)}.score.bad .arc{stroke:var(--bad)}
    .grade{margin:6px 0 0;font-size:12.5px;font-weight:600}
    .score.good .grade{color:var(--good)}.score.warn .grade{color:var(--warn)}.score.bad .grade{color:var(--bad)}
    section{margin-top:44px}
    h2{margin:0 0 6px;font-size:12px;font-weight:600;color:var(--soft)}
    .count{font-weight:500;color:var(--faint);font-variant-numeric:tabular-nums;margin-left:2px}
    .tally{margin-top:32px;padding:14px 0;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
    .tally ul{display:flex;flex-wrap:wrap;gap:8px 24px;margin:0;padding:0;list-style:none;font-size:13px;color:var(--soft)}
    .tally b{color:var(--ink);font-weight:650;font-variant-numeric:tabular-nums}
    .tally .none{opacity:.5}
    .tally .handled-count{margin-left:auto}
    .mark{display:inline-block;width:8px;height:8px;margin-right:8px;border-radius:50%;vertical-align:1px;flex:none}
    .mark.error{background:var(--bad)}
    .mark.warning{background:var(--warn);border-radius:1.5px;width:7px;height:7px;transform:rotate(45deg)}
    .mark.notice{background:var(--dot);width:5px;height:5px;margin-left:1.5px;margin-right:9.5px;vertical-align:2px}
    .mark.passed{background:none;border-radius:0;width:9px;height:5px;border-left:2px solid var(--good);border-bottom:2px solid var(--good);transform:rotate(-45deg);vertical-align:3px}
    table{width:100%;border-collapse:collapse;font-size:13px}
    th,td{text-align:left;padding:7px 12px 7px 0;border-top:1px solid var(--line);font-weight:400;vertical-align:top}
    thead th{border-top:0;font-size:11.5px;color:var(--soft);font-weight:500}
    .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;padding-right:0;padding-left:12px}
    .areas{max-width:460px}.areas th{width:150px}.areas .num{width:44px}.areas tr:first-child th,.areas tr:first-child td{border-top:0}
    .areas .bar{vertical-align:middle}
    .bar span{display:block;height:3px;border-radius:2px}
    .bar{position:relative}
    .bar::before{content:"";position:absolute;left:0;right:12px;top:50%;height:3px;margin-top:-1.5px;border-radius:2px;background:var(--line)}
    .bar span{position:relative}
    .bar .good{background:var(--good)}.bar .warn{background:var(--warn)}.bar .bad{background:var(--bad)}
    .issue{padding:10px 0 26px}
    h3{margin:0;font-size:17px;line-height:1.3;letter-spacing:-.01em;font-weight:650}
    h3 .mark{vertical-align:2px}
    h3 .count{font-size:13px}
    .tag{display:inline-block;margin-left:6px;padding:1px 8px;border:1px solid var(--line);border-radius:999px;font-size:11px;font-weight:500;color:var(--soft);vertical-align:2px;letter-spacing:0}
    .handled h3,.handled .why,.handled dl,.handled .found{opacity:.55}
    .handled h3 .tag{opacity:1}
    .why{margin:8px 0 0;max-width:64ch;color:var(--ink)}
    dl{display:grid;grid-template-columns:96px 1fr;gap:6px 16px;margin:14px 0 0;font-size:13px}
    dt{color:var(--soft)}dd{margin:0;max-width:62ch}
    .found{margin:14px 0 0;padding:0;list-style:none;font-size:12.5px}
    .found li{display:flex;flex-wrap:wrap;gap:2px 14px;padding:6px 0;border-top:1px solid var(--line)}
    .path,.path a{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;overflow-wrap:anywhere}
    .detail{color:var(--soft);overflow-wrap:anywhere}
    .passed ul{margin:6px 0 0;padding:0;list-style:none;columns:2;column-gap:32px;font-size:13px}
    .passed li{padding:4px 0;break-inside:avoid}
    .pages td{overflow-wrap:anywhere}
    .bad-text{color:var(--bad)}.quiet{color:var(--faint)}
    .scope{margin:12px 0 0;padding:8px 12px;border:1px solid var(--line);border-radius:8px;font-size:12.5px;color:var(--soft);display:inline-block}
    .types{max-width:360px}.types .num{width:auto}
    h3.sub{margin:26px 0 4px;font-size:13px;font-weight:600;letter-spacing:0}
    .item{margin:10px 0 0;padding:10px 0 0;border-top:1px solid var(--line)}
    .item .item{margin-left:20px}
    .type{margin:0;font-size:13.5px}
    .fields{grid-template-columns:150px 1fr;margin-top:8px;font-size:12.5px;gap:3px 16px}
    .fields dt{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11.5px}
    .fields dd{overflow-wrap:anywhere;max-width:none}
    .item .found{margin-top:8px}.item .found li{display:block;border-top:0;padding:2px 0}
    footer{margin-top:56px;padding-top:16px;border-top:1px solid var(--line);font-size:12px;color:var(--soft)}
    @media (max-width:600px){main{padding:32px 18px 48px}header{flex-direction:column-reverse;gap:18px}h1{font-size:26px}dl{grid-template-columns:1fr;gap:2px}dd{margin-bottom:8px}.passed ul{columns:1}.pages th:nth-child(4),.pages td:nth-child(4){display:none}}
    @media print{:root{--surface:#fff;--raised:#fff;--ink:#000;--soft:#444;--faint:#777;--line:rgba(0,0,0,.18);--wash:rgba(0,0,0,.04);--bad:#c22a20;--warn:#a86a00;--good:#157a47;--dot:#777}body{font-size:11pt}main{max-width:none;padding:0}section{margin-top:28pt}h1{font-size:22pt}h2,h3,.issue .why{break-after:avoid}.issue h3,.issue .why,.issue dl{break-inside:avoid}tr,.found li{break-inside:avoid}a{text-decoration:none}*{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
    """
}
