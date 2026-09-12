import Foundation

/// Saves imported/synced play history to disk so it survives restarts — you
/// import or sync once, not every launch. Stored as JSON in Application Support.
enum Persistence {
    private static var baseDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var fileURL: URL { baseDir.appendingPathComponent("history.json") }
    private static var artistURLFile: URL { baseDir.appendingPathComponent("artistURLs.json") }
    private static var genreFile: URL { baseDir.appendingPathComponent("genres.json") }
    private static var durationFile: URL { baseDir.appendingPathComponent("durations.json") }

    /// Where history lives — used by the backup/restore commands in Settings.
    static var historyURL: URL { fileURL }

    private static var libraryFile: URL { baseDir.appendingPathComponent("library.json") }
    private static var artworkFile: URL { baseDir.appendingPathComponent("artwork.cache") }

    /// Snapshot of the Music library from the last scan, so the UI can render
    /// instantly on launch while a fresh scan runs in the background.
    static func saveLibrary(_ tracks: [Track]) {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }
    static func loadLibrary() -> [Track] {
        guard let data = try? Data(contentsOf: libraryFile) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    /// Album cover thumbnails as PNG bytes, keyed by `Track.albumKey`. Decoding
    /// these from the Music library is by far the slowest part of a scan, so we
    /// keep the downscaled results.
    static func saveArtwork(_ map: [String: Data]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: artworkFile, options: .atomic)
        }
    }
    static func loadArtwork() -> [String: Data] {
        guard let data = try? Data(contentsOf: artworkFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private static var artistArtFile: URL { baseDir.appendingPathComponent("artistArt.cache") }

    /// Artist profile photos, downscaled, keyed by lowercased artist name. Kept
    /// for the same reason as album covers: the source images are 1000×1000, and
    /// re-fetching one to draw a 40-point circle is not something a scrolling
    /// list can afford to do per row.
    static func saveArtistArt(_ map: [String: Data]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: artistArtFile, options: .atomic)
        }
    }
    static func loadArtistArt() -> [String: Data] {
        guard let data = try? Data(contentsOf: artistArtFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private static var skipFile: URL { baseDir.appendingPathComponent("skips.json") }

    /// Skip counts keyed "title::artist". Only ever grows, and only from plays
    /// Tempo's live scrobbler actually witnessed.
    static func saveSkips(_ map: [String: Int]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: skipFile, options: .atomic)
        }
    }
    static func loadSkips() -> [String: Int] {
        guard let data = try? Data(contentsOf: skipFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    static func saveGenres(_ map: [String: [String]]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: genreFile, options: .atomic)
        }
    }
    static func loadGenres() -> [String: [String]] {
        guard let data = try? Data(contentsOf: genreFile) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    /// Apple Music's lifetime play counts as they stood at the last library
    /// scan. The next scan diffs against this to work out how many plays
    /// happened in between — the Music app records a running total and a single
    /// "last played" date, never the individual plays.
    struct PlayCounts: Codable {
        var taken: Date
        var counts: [String: Int]      // normalised song key → lifetime play count
    }

    private static var playCountFile: URL { baseDir.appendingPathComponent("playcounts.json") }

    static func savePlayCounts(_ snap: PlayCounts) {
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: playCountFile, options: .atomic)
        }
    }
    static func loadPlayCounts() -> PlayCounts? {
        guard let data = try? Data(contentsOf: playCountFile) else { return nil }
        return try? JSONDecoder().decode(PlayCounts.self, from: data)
    }

    /// Track lengths looked up from Last.fm, keyed by normalised song identity.
    /// A stored `0` means "asked, Last.fm doesn't know" — kept deliberately, so
    /// a track nobody has a duration for isn't re-requested on every launch.
    static func saveDurations(_ map: [String: Int]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: durationFile, options: .atomic)
        }
    }
    static func loadDurations() -> [String: Int] {
        guard let data = try? Data(contentsOf: durationFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    static func saveArtistURLs(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: artistURLFile, options: .atomic)
        }
    }
    static func loadArtistURLs() -> [String: String] {
        guard let data = try? Data(contentsOf: artistURLFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// True when the last `load()` found a history file it couldn't parse. The
    /// store refuses to overwrite history in that state — a corrupt read used to
    /// silently return [], and the next scrobble would then write that empty
    /// array back, destroying listening history that exists nowhere else.
    private(set) static var historyUnreadable = false

    /// Modification date of the history file as this process last left it.
    /// Lets a caller tell "nobody else has written since I did" from "the other
    /// process has changed it", without decoding the file to find out — which,
    /// at tens of thousands of plays, costs more than everything else a scrobble
    /// does put together.
    private static var lastWriteStamp: Date? = nil

    private static var fileStamp: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// The history on disk, but only if another process has touched it since our
    /// last write. `nil` means the caller's own copy is already current.
    static func loadIfChangedExternally() -> [Track]? {
        guard let stamp = fileStamp else { return load() }   // no file, or unreadable
        guard stamp != lastWriteStamp else { return nil }
        return load()
    }

    static func save(_ tracks: [Track]) {
        guard !historyUnreadable else {
            NSLog("Tempo: refusing to overwrite history — the existing file could not be read.")
            return
        }
        do {
            // A big shrink is almost always a bug, not an intent. Keep the old
            // file before replacing it so nothing is ever unrecoverable.
            if let existing = try? Data(contentsOf: fileURL),
               let old = try? JSONDecoder().decode([Track].self, from: existing),
               old.count > 50, tracks.count < old.count / 2 {
                try? existing.write(to: backupFile, options: .atomic)
                NSLog("Tempo: history shrank \(old.count) → \(tracks.count); previous copy kept at \(backupFile.lastPathComponent).")
            }
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: fileURL, options: .atomic)
            lastWriteStamp = fileStamp
        } catch {
            NSLog("Tempo: failed to save history: \(error.localizedDescription)")
        }
    }

    static func load() -> [Track] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            historyUnreadable = false      // no file yet is fine — a fresh start
            return []
        }
        if let tracks = try? JSONDecoder().decode([Track].self, from: data) {
            historyUnreadable = false
            return tracks
        }
        // Unparseable but non-empty: preserve it and refuse to write over it.
        // Quarantine only once per process — load() runs on several paths, and
        // we don't want a pile of identical copies.
        if !historyUnreadable {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = baseDir.appendingPathComponent("history.unreadable-\(stamp).json")
            try? data.write(to: quarantine, options: .atomic)
            NSLog("Tempo: history.json could not be parsed; a copy was kept at \(quarantine.lastPathComponent).")
        }
        historyUnreadable = true
        // Fall back to the last known-good backup if we have one.
        if let bak = try? Data(contentsOf: backupFile),
           let tracks = try? JSONDecoder().decode([Track].self, from: bak) {
            NSLog("Tempo: recovered \(tracks.count) plays from the backup copy.")
            historyUnreadable = false
            return tracks
        }
        return []
    }

    private static var backupFile: URL { baseDir.appendingPathComponent("history.backup.json") }
}
