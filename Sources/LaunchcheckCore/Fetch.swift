import Foundation

public struct FetchResult: Sendable {
    /// The address that was asked for.
    public var url: URL
    /// Where the request ended up after following redirects.
    public var finalURL: URL
    /// The last HTTP status, or 0 when nothing answered.
    public var status: Int
    /// Response headers, with lowercased names.
    public var headers: [String: String]
    public var body: Data
    /// Each address the request was redirected to, in order.
    public var redirects: [URL]
    /// The status of each redirect, alongside `redirects` (301, 302, 307, 308).
    public var redirectStatuses: [Int]
    public var error: String?
    /// How long the server took to start answering the final request.
    public var milliseconds: Int

    public init(url: URL, finalURL: URL? = nil, status: Int, headers: [String: String] = [:], body: Data = Data(),
                redirects: [URL] = [], redirectStatuses: [Int] = [], error: String? = nil, milliseconds: Int = 0) {
        self.url = url
        self.finalURL = finalURL ?? url
        self.status = status
        self.headers = headers
        self.body = body
        self.redirects = redirects
        self.redirectStatuses = redirectStatuses
        self.error = error
        self.milliseconds = milliseconds
    }

    public var ok: Bool { status >= 200 && status < 300 }
    public var redirected: Bool { !redirects.isEmpty }
    public var isHTML: Bool { (headers["content-type"] ?? "").lowercased().contains("html") }
}

public protocol Fetcher: Sendable {
    /// Loads an address, following redirects. With `bodyWanted` false only the status and headers matter.
    func fetch(_ url: URL, bodyWanted: Bool) async -> FetchResult
}

/// The real network.
public final class URLSessionFetcher: NSObject, Fetcher, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let bodyLimit: Int

    public init(timeout: TimeInterval = 15, bodyLimit: Int = 3_000_000) {
        self.bodyLimit = bodyLimit
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (compatible; Launchcheck/0.1)",
            // What a browser sends. The image types matter: an image service that can answer with AVIF or WebP
            // only does so when asked, and weighing the PNG it falls back to would overstate every image.
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        ]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // Redirects are followed by hand so each hop can be recorded.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func fetch(_ url: URL, bodyWanted: Bool) async -> FetchResult {
        var current = url
        var redirects: [URL] = []
        var statuses: [Int] = []

        for _ in 0..<8 {
            if Task.isCancelled { return FetchResult(url: url, finalURL: current, status: 0, redirects: redirects, error: "Cancelled") }
            var hop = await once(current, method: bodyWanted ? "GET" : "HEAD", bodyWanted: bodyWanted)
            // Plenty of servers refuse HEAD; ask again properly before calling a link broken.
            if !bodyWanted, [400, 403, 404, 405, 501].contains(hop.status) || hop.status == 0 {
                hop = await once(current, method: "GET", bodyWanted: false)
            }

            if (300..<400).contains(hop.status), let location = hop.headers["location"],
               let target = URL(string: location, relativeTo: current)?.absoluteURL {
                redirects.append(target)
                statuses.append(hop.status)
                current = target
                continue
            }
            hop.url = url
            hop.finalURL = current
            hop.redirects = redirects
            hop.redirectStatuses = statuses
            return hop
        }
        return FetchResult(url: url, finalURL: current, status: 0, redirects: redirects, error: "Too many redirects")
    }

    private func once(_ url: URL, method: String, bodyWanted: Bool) async -> FetchResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return FetchResult(url: url, status: 0, error: "Not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }

            var body = Data()
            let type = (headers["content-type"] ?? "").lowercased()
            let readable = type.contains("html") || type.contains("xml") || type.contains("text") || type.isEmpty
            if bodyWanted, method == "GET", readable, (200..<300).contains(http.statusCode) {
                body.reserveCapacity(64_000)
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= bodyLimit { break }
                }
            }
            // Anything left (an image, a video, the rest of a huge page) is not needed.
            bytes.task.cancel()
            return FetchResult(url: url, status: http.statusCode, headers: headers, body: body, milliseconds: waited)
        } catch {
            return FetchResult(url: url, status: 0, error: Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .cannotFindHost, .dnsLookupFailed: return "The address does not exist"
        case .timedOut: return "It took too long to answer"
        case .cannotConnectToHost: return "The server refused the connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Its security certificate is not valid"
        case .notConnectedToInternet, .networkConnectionLost: return "No internet connection"
        default: return error.localizedDescription
        }
    }
}

// MARK: robots.txt

public struct Robots: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        public var allow: Bool
        public var path: String
    }

    public struct Group: Equatable, Sendable {
        public var agents: [String]
        public var rules: [Rule]
    }

    public var sitemaps: [String] = []
    public var groups: [Group] = []

    public init(_ text: String) {
        var current: Group?
        var lastWasAgent = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "sitemap":
                if !value.isEmpty { sitemaps.append(value) }
                continue
            case "user-agent":
                // Consecutive user-agent lines share the group that follows them.
                if lastWasAgent, current != nil {
                    current?.agents.append(value.lowercased())
                } else {
                    if let finished = current { groups.append(finished) }
                    current = Group(agents: [value.lowercased()], rules: [])
                }
                lastWasAgent = true
                continue
            case "disallow":
                if !value.isEmpty { current?.rules.append(Rule(allow: false, path: value)) }
            case "allow":
                if !value.isEmpty { current?.rules.append(Rule(allow: true, path: value)) }
            default:
                break
            }
            lastWasAgent = false
        }
        if let finished = current { groups.append(finished) }
    }

    /// The rules a crawler obeys: those of the groups naming it, or failing that, the groups for everyone.
    public func rules(for agent: String) -> [Rule] {
        let name = agent.lowercased()
        let named = groups.filter { $0.agents.contains(name) }
        let chosen = named.isEmpty || name == "*" ? groups.filter { $0.agents.contains("*") } : named
        return chosen.flatMap(\.rules)
    }

    /// True when the file has a group written for this crawler by name.
    public func names(_ agent: String) -> Bool {
        groups.contains { $0.agents.contains(agent.lowercased()) }
    }

    /// The longest matching rule wins, as crawlers apply it.
    public func blocks(_ path: String, agent: String = "*") -> Bool {
        let path = path.isEmpty ? "/" : path
        var best: (length: Int, allow: Bool)?
        for rule in rules(for: agent) where Self.matches(rule.path, path) {
            let length = rule.path.count
            if best == nil || length > best!.length || (length == best!.length && rule.allow) {
                best = (length, rule.allow)
            }
        }
        return best.map { !$0.allow } ?? false
    }

    /// robots.txt patterns: a prefix match, where "*" stands for anything and a trailing "$" pins the end.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        let anchored = pattern.hasSuffix("$")
        let pieces = (anchored ? String(pattern.dropLast()) : pattern).split(separator: "*", omittingEmptySubsequences: false)
        var rest = Substring(path)
        for (index, piece) in pieces.enumerated() {
            if index == 0 {
                guard rest.hasPrefix(piece) else { return false }
                rest = rest.dropFirst(piece.count)
            } else if index == pieces.count - 1, anchored {
                return rest.hasSuffix(piece)
            } else if piece.isEmpty {
                continue
            } else {
                guard let found = rest.range(of: piece) else { return false }
                rest = rest[found.upperBound...]
            }
        }
        return !anchored || rest.isEmpty
    }

    public var blocksEverything: Bool { blocks("/") }
}

// MARK: Sitemaps

public struct SitemapContents: Equatable, Sendable {
    public var pages: [String] = []
    /// The <lastmod> of each page that has one.
    public var dates: [String] = []
    /// Further sitemaps, when this one is an index.
    public var sitemaps: [String] = []
}

public final class SitemapParser: NSObject, XMLParserDelegate {
    private var contents = SitemapContents()
    private var stack: [String] = []
    private var text = ""

    public static func parse(_ data: Data) -> SitemapContents {
        let handler = SitemapParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.contents
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        stack.append(name.lowercased())
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if !stack.isEmpty { stack.removeLast() } }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased() == "lastmod", stack.count >= 2, stack[stack.count - 2] == "url", !value.isEmpty {
            contents.dates.append(value)
        }
        guard name.lowercased() == "loc", stack.count >= 2, !value.isEmpty else { return }
        switch stack[stack.count - 2] {
        case "url": contents.pages.append(value)
        case "sitemap": contents.sitemaps.append(value)
        default: break
        }
    }
}
