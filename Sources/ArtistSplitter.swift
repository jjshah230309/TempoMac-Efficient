import Foundation

/// Smart artist resolution.
///
/// Default behaviour: an artist tag is ONE artist, exactly as the Music app
/// stores it — "Drake and Lil Baby" / "Pritam, Arijit Singh, Shilpa Rao" stay
/// whole. The optional "Split collaborations" view breaks real collaborations
/// into individual contributors, while protecting band names that legitimately
/// contain "and", "&" or commas.
enum ArtistSplitter {

    /// Single-artist names that contain separator tokens. Matched whole,
    /// case-insensitively, and never split.
    static let protectedNames: Set<String> = [
        "florence and the machine", "earth, wind & fire", "tyler, the creator",
        "simon and garfunkel", "hall and oates", "belle and sebastian",
        "mumford and sons", "nick cave and the bad seeds", "sly and the family stone",
        "kool and the gang", "iron and wine", "edward sharpe and the magnetic zeros",
        "now, now", "crosby, stills and nash", "crosby, stills, nash and young",
        "blood, sweat and tears", "derek and the dominos", "huey lewis and the news",
        "me first and the gimme gimmes",
    ]

    /// Separators (regex) that indicate multiple contributors, applied in order.
    /// Compiled ONCE — recompiling these per call was the source of the lag.
    private static let separators: [NSRegularExpression] = [
        #"\s*\bfeat(?:uring|\.)?\b\s*"#,
        #"\s*\bft\.?\b\s*"#,
        #"\s*\bwith\b\s*"#,
        #"\s+&\s+"#,
        #"\s+x\s+"#,
        #"\s*\band\b\s*"#,
        #"\s*,\s*"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    /// Memoize results — the same artist tag recurs across many tracks and across
    /// every re-render, so we compute each tag's split at most once.
    private static var cache: [String: [String]] = [:]

    static func clean(_ s: String) -> String {
        let ns = s as NSString
        let collapsed = whitespace.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    static func isProtected(_ tag: String) -> Bool {
        protectedNames.contains(tag.lowercased())
    }

    /// Break a tag into individual contributors, respecting protected names.
    /// Returns `[tag]` for solo artists and protected band names. Memoized.
    static func split(_ rawArtist: String) -> [String] {
        if let cached = cache[rawArtist] { return cached }
        let result = computeSplit(rawArtist)
        cache[rawArtist] = result
        return result
    }

    private static func computeSplit(_ rawArtist: String) -> [String] {
        let tag = clean(rawArtist)
        if isProtected(tag) { return [tag] }

        // Fast path: no separator characters at all -> solo artist.
        if !tag.contains(where: { $0 == "," || $0 == "&" }) &&
            tag.range(of: #"\b(feat|ft|with|and|x)\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return [tag]
        }

        var parts = [tag]
        for re in separators {
            var next: [String] = []
            for p in parts {
                if isProtected(p) { next.append(p); continue }
                next.append(contentsOf: splitRegex(p, re))
            }
            parts = next
        }

        var seen = Set<String>()
        var result: [String] = []
        for p in parts.map(clean) where !p.isEmpty {
            if seen.insert(p.lowercased()).inserted { result.append(p) }
        }
        return result.isEmpty ? [tag] : result
    }

    /// True if the tag is a real multi-artist collaboration (protected => false).
    static func isCollaboration(_ rawArtist: String) -> Bool {
        split(rawArtist).count > 1
    }

    private static func splitRegex(_ s: String, _ re: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
}
