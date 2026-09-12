import Foundation

/// Parses a Spotify data export into exact per-play `Track` records (one play
/// each, `plays = 1`, `lengthMs` = milliseconds actually streamed, `lastPlayed`
/// = the real timestamp). Because each record is a real play with a real time,
/// date-range filtering over these is exact.
///
/// Handles both export shapes:
///   • Account data        → StreamingHistory*.json
///       { endTime, artistName, trackName, msPlayed }
///   • Extended history     → Streaming_History_Audio*.json / endsong*.json
///       { ts, ms_played, master_metadata_track_name,
///         master_metadata_album_artist_name, master_metadata_album_album_name }
enum HistoryImporter {

    static func parseSpotify(_ data: Data) -> [Track] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }

        let iso = ISO8601DateFormatter()
        let simple = DateFormatter()
        simple.dateFormat = "yyyy-MM-dd HH:mm"
        simple.timeZone = TimeZone(identifier: "UTC")

        var out: [Track] = []
        out.reserveCapacity(arr.count)
        for r in arr {
            guard let title = (r["trackName"] ?? r["master_metadata_track_name"]) as? String,
                  let artist = (r["artistName"] ?? r["master_metadata_album_artist_name"]) as? String,
                  !title.isEmpty, !artist.isEmpty else { continue }

            let album = (r["albumName"] ?? r["master_metadata_album_album_name"]) as? String ?? ""
            let ms = ((r["msPlayed"] ?? r["ms_played"]) as? NSNumber)?.intValue ?? 0

            var date: Date?
            if let ts = r["ts"] as? String { date = iso.date(from: ts) }
            else if let e = r["endTime"] as? String { date = simple.date(from: e) }

            out.append(Track(
                title: title,
                artist: artist,
                album: album,
                albumKey: "\(album)::\(artist)",
                source: .spotify,
                lengthMs: ms,      // exact ms streamed for this single play
                plays: 1,
                lastPlayed: date
            ))
        }
        return out
    }
}
