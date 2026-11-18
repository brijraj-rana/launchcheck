import Foundation

/// The image checks added from the seo-images checklist: the format a file is sent in, and pages that fetch every
/// image before the visitor has scrolled.
enum ImageChecks {
    /// "JPEG" or "PNG" when the server answered a request that accepts WebP and AVIF with an older format.
    static func olderFormat(_ headers: [String: String]) -> String? {
        let type = (headers["content-type"] ?? "").lowercased()
        if type.hasPrefix("image/jpeg") || type.hasPrefix("image/jpg") { return "JPEG" }
        if type.hasPrefix("image/png") { return "PNG" }
        return nil
    }

    /// Ten images or more, and not one of them left for later.
    static func loadsEverythingAtOnce(_ images: [ImageFact]) -> Bool {
        images.count >= 10 && !images.contains { $0.lazy || $0.deferred }
    }

    /// True when a share image is written as a path, which some apps will not resolve.
    static func isRelative(_ address: String) -> Bool {
        let lower = address.trimmingCharacters(in: .whitespaces).lowercased()
        return !lower.isEmpty && !lower.hasPrefix("http://") && !lower.hasPrefix("https://")
    }
}
