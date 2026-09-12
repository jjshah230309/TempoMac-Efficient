import Foundation

/// Last.fm scrobble sync via the public API (`user.getrecenttracks`).
///
/// Scrobbles give an EXACT timestamp per play, so date-range membership and
/// play counts are precise. They do NOT include track duration, so listening
/// time uses a caller-supplied duration lookup (matched against your Apple /
/// Spotify tracks) and falls back to an estimate for anything unmatched.
enum LastFM {

    static let estimatedMs = 210_000 // 3.5 min fallback for unknown durations

    enum SyncError: LocalizedError {
        case missingCredentials
        case api(String)
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .missingCredentials: return "Enter your Last.fm username and API key."
            case .api(let m): return "Last.fm: \(m)"
            case .http(let c): return "Last.fm request failed (HTTP \(c))."
            }
        }
    }

    /// Fetch the user's full scrobble history (paged). `durationFor(title,artist)`
    /// returns the best-known length in ms. `progress(page,totalPages)` reports
    /// sync progress on whatever thread; hop to main inside it if updating UI.
    /// `from` limits the pull to scrobbles after that moment — the difference
    /// between fetching a handful of new plays and re-downloading a lifetime of
    /// history on every sync.
    nonisolated static func fetchRecent(
        user: String,
        apiKey: String,
        from: Date? = nil,
        durationFor: @Sendable (String, String) -> Int,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> [Track] {
        let user = user.trimmingCharacters(in: .whitespaces)
        let apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !apiKey.isEmpty else { throw SyncError.missingCredentials }

        var page = 1
        var totalPages = 1
        var out: [Track] = []
        let maxPages = 200 // safety cap (~40k scrobbles)

        repeat {
            var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
            comps.queryItems = [
                .init(name: "method", value: "user.getrecenttracks"),
                .init(name: "user", value: user),
                .init(name: "api_key", value: apiKey),
                .init(name: "format", value: "json"),
                .init(name: "limit", value: "200"),
                .init(name: "page", value: "\(page)"),
            ]
            if let from {
                comps.queryItems?.append(.init(name: "from", value: "\(Int(from.timeIntervalSince1970))"))
            }
            let (data, resp) = try await URLSession.shared.data(from: comps.url!)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                // Last.fm returns JSON error bodies even on non-200 sometimes.
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let m = j["message"] as? String { throw SyncError.api(m) }
                throw SyncError.http(http.statusCode)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            if let m = json["message"] as? String { throw SyncError.api(m) }
            guard let rt = json["recenttracks"] as? [String: Any] else { break }
            if let attr = rt["@attr"] as? [String: Any], let tp = attr["totalPages"] as? String {
                totalPages = Int(tp) ?? 1
            }

            // `track` is an array, or a single object when there's only one.
            let rawTracks: [[String: Any]]
            if let arr = rt["track"] as? [[String: Any]] { rawTracks = arr }
            else if let one = rt["track"] as? [String: Any] { rawTracks = [one] }
            else { rawTracks = [] }

            for t in rawTracks {
                // Skip the "now playing" entry (it has no scrobble timestamp).
                if let a = t["@attr"] as? [String: Any], (a["nowplaying"] as? String) == "true" { continue }
                guard let name = t["name"] as? String, !name.isEmpty,
                      let dateObj = t["date"] as? [String: Any],
                      let uts = dateObj["uts"] as? String, let secs = TimeInterval(uts) else { continue }
                let artist = (t["artist"] as? [String: Any])?["#text"] as? String ?? ""
                let album = (t["album"] as? [String: Any])?["#text"] as? String ?? ""
                let ms = durationFor(name, artist)
                out.append(Track(
                    title: name,
                    artist: artist,
                    album: album,
                    albumKey: "\(album)::\(artist)",
                    source: .lastfm,
                    lengthMs: ms,
                    plays: 1,
                    lastPlayed: Date(timeIntervalSince1970: secs),
                    artURL: bestImageURL(t["image"])
                ))
            }

            progress(page, totalPages)
            page += 1
        } while page <= totalPages && page <= maxPages

        return out
    }

    /// Top user-applied tags for an artist — Tempo's stand-in for genres, since
    /// neither Apple Music nor Spotify hands us a genre per play. Returns a few
    /// cleaned-up tag names, most-applied first, or [] if the artist is unknown.
    /// Track length in ms from `track.getInfo`, for scrobbles no local source
    /// knows the duration of.
    ///
    /// Three outcomes, and they are not the same thing: a length, `0` for "Last
    /// .fm has this track but no duration for it" (very common — the field is
    /// frequently absent or literally "0"), and `nil` for a request that failed.
    /// Only `nil` is worth retrying; caching the `0` is what stops us asking
    /// again on every launch for a track nobody will ever have a length for.
    nonisolated static func trackDuration(title: String, artist: String, apiKey: String) async -> Int? {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !title.isEmpty, !artist.isEmpty else { return nil }
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comps.queryItems = [
            .init(name: "method", value: "track.getInfo"),
            .init(name: "track", value: title),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: key),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if j["error"] != nil { return 0 }          // no such track — settled, don't re-ask
        guard let t = j["track"] as? [String: Any] else { return nil }
        // `duration` comes back as a string of ms, sometimes as a number.
        let ms: Int
        if let s = t["duration"] as? String { ms = Int(s) ?? 0 }
        else if let n = t["duration"] as? Int { ms = n }
        else if let n = t["duration"] as? Double { ms = Int(n) }
        else { ms = 0 }
        // Last.fm occasionally reports nonsense (a few seconds, or many hours).
        // Treat anything outside a plausible song length as "not known".
        return (ms >= 20_000 && ms <= 3_600_000) ? ms : 0
    }

    nonisolated static func topTags(artist: String, apiKey: String) async -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !artist.isEmpty else { return [] }
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comps.queryItems = [
            .init(name: "method", value: "artist.gettoptags"),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: key),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tt = j["toptags"] as? [String: Any] else { return [] }
        let raw: [[String: Any]]
        if let arr = tt["tag"] as? [[String: Any]] { raw = arr }
        else if let one = tt["tag"] as? [String: Any] { raw = [one] }
        else { raw = [] }

        // Drop noise tags ("seen live", "favourites", years, single letters) and
        // keep only tags a decent share of listeners agreed on.
        let noise: Set<String> = ["seen live", "favorites", "favourites", "spotify", "albums i own",
                                  "under 2000 listeners", "male vocalists", "female vocalists",
                                  "beautiful", "love", "favorite", "awesome", "cool", "good"]
        var out: [String] = []
        for t in raw {
            guard let name = (t["name"] as? String)?.trimmingCharacters(in: .whitespaces), name.count > 2,
                  let count = t["count"] as? Int, count >= 15 else { continue }
            let lower = name.lowercased()
            if noise.contains(lower) { continue }
            if Int(lower) != nil { continue }              // bare years like "2013"
            out.append(lower)
            if out.count == 3 { break }
        }
        return out
    }

    /// Largest non-placeholder cover URL from a Last.fm `image` array.
    /// `2a96cbd8…` is Last.fm's grey "no cover" star — skip it.
    private static func bestImageURL(_ raw: Any?) -> String? {
        guard let images = raw as? [[String: Any]] else { return nil }
        for size in ["extralarge", "large", "medium", "small"] {
            if let m = images.first(where: { ($0["size"] as? String) == size }),
               let u = m["#text"] as? String, !u.isEmpty,
               !u.contains("2a96cbd8b46e442fc41c2b86b821562f") {
                return u
            }
        }
        return nil
    }
}
