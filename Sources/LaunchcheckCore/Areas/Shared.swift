import Foundation

/// What became of an address that a tag points at: a canonical, a hreflang link.
struct TargetState: Equatable, Sendable {
    /// The status it answered with, 0 for no answer.
    var status: Int
    /// Where it ended up, when that is somewhere else.
    var redirectedTo: String?
    /// False when the page was read and is set to noindex. nil when the page was not read.
    var indexable: Bool?

    var broken: Bool { status == 0 || status >= 400 }

    /// What is wrong with it as the target of a tag, or nil when nothing is.
    var problem: String? {
        if broken { return status == 0 ? "did not load" : "returned \(status)" }
        if let redirectedTo { return "redirects to \(redirectedTo)" }
        if indexable == false { return "is set to noindex" }
        return nil
    }
}

/// "first" or "first, and 2 more": one line for a list of things found on a page.
func summarized(_ details: [String]) -> String? {
    guard let first = details.first else { return nil }
    return details.count > 1 ? "\(first), and \(details.count - 1) more" : first
}
