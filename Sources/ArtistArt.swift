import Foundation

/// Resolves an artist name to a profile-picture URL using Deezer's public API
/// (no key/auth required). Works for any source — Spotify, Last.fm, Apple,
/// local — since it's name-based. Last.fm's own artist images are deprecated
/// (grey placeholder) and Spotify's export has none, so this fills the gap.
enum ArtistArt {

    static func imageURL(for name: String) async -> String? {
        if let hit = await search(name) { return hit }
        // Collaboration tag with no direct match → retry with the lead artist.
        let lead = ArtistSplitter.split(name).first ?? name
        if lead != name { return await search(lead) }
        return nil
    }

    private static func search(_ name: String) async -> String? {
        let q = norm(name)
        guard !q.isEmpty, q != "unknown artist" else { return nil }

        var comps = URLComponents(string: "https://api.deezer.com/search/artist")!
        comps.queryItems = [.init(name: "q", value: name), .init(name: "limit", value: "5")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return nil }

        // Take the first result whose name reasonably matches, so we don't grab
        // an unrelated face.
        for a in arr {
            let dz = norm(a["name"] as? String ?? "")
            guard !dz.isEmpty else { continue }
            if dz == q || q.hasPrefix(dz) || q.contains(dz) || dz.contains(q) {
                if let pic = (a["picture_xl"] ?? a["picture_big"] ?? a["picture_medium"]) as? String,
                   !pic.isEmpty { return pic }
            }
        }
        return nil
    }

    private static func norm(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
