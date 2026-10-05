import Foundation

/// Rules for matching window titles and browser tab URLs to zone targets.
public enum TargetMatching {
    /// Case-insensitive "title contains" match. Window titles change (e.g. a
    /// document's name, unread counts), so containment is more forgiving than
    /// equality. An empty pattern matches nothing.
    public static func title(_ title: String, matches pattern: String) -> Bool {
        let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Lowercases and strips the scheme, `www.`, and a trailing slash so
    /// `https://www.GitHub.com/` and `github.com` compare equal.
    public static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// True if `url` starts with `pattern` at a boundary, so `github.com`
    /// matches `github.com/foo` but not `github.community`.
    public static func url(_ url: String, matches pattern: String) -> Bool {
        let p = normalize(pattern), u = normalize(url)
        guard !p.isEmpty, u.hasPrefix(p) else { return false }
        guard let next = u.dropFirst(p.count).first else { return true }
        return p.last.map { "/?#&=:".contains($0) } == true || "/?#:".contains(next)
    }

    /// A short, durable pattern for a tab's URL: host + path, without the
    /// query or fragment (so `youtube.com/watch` covers any video).
    public static func suggestedPattern(for url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return normalize(url) }
        return normalize(host + components.path)
    }

    /// A URL that can be opened for a pattern typed by the user.
    public static func openableURL(for pattern: String) -> URL? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }
}
