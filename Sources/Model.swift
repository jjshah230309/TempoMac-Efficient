import Foundation

/// Where a listen came from. Apple Music's library distinguishes cloud
/// (streaming / matched) items from local files on disk.
enum Source: String, CaseIterable, Codable {
    case appleMusic = "Apple Music"
    case local = "Local Files"
    case spotify = "Spotify"
    case lastfm = "Last.fm"

    var hex: String {
        switch self {
        case .appleMusic: return "#FA2D48"
        case .local:      return "#8A5CF6"
        case .spotify:    return "#1DB954"
        case .lastfm:     return "#D51007"
        }
    }

    /// The source as shown to the user. Last.fm scrobbles are just the user's
    /// Spotify listening routed through Last.fm, so everywhere the UI labels,
    /// colours, groups or filters by source, Last.fm is presented and merged
    /// as Spotify. Storage keeps the two distinct (see LibraryStore) so the
    /// Last.fm full-resync's scoped `replace` never wipes real Spotify imports.
    var display: Source { self == .lastfm ? .spotify : self }
}

/// One aggregated track from the Music library. `totalMs` is the REAL listening
/// time = track length × play count, straight from the Music app's own counters.
struct Track: Identifiable, Codable {
    var id = UUID()
    let title: String
    let artist: String      // the tag exactly as Music stores it ("Drake and Lil Baby" stays one)
    let album: String
    let albumKey: String    // identifies the album cover (album + album artist)
    let source: Source
    let lengthMs: Int
    let plays: Int
    let lastPlayed: Date?
    var artURL: String? = nil   // remote cover (e.g. from Last.fm), when not local
    /// Release year, when the source tells us. The only thing that separates two
    /// albums sharing a title and an artist — e.g. the 2009 and 2020 films both
    /// called "Love Aaj Kal", both scored by Pritam.
    var year: Int? = nil
    /// True when `lastPlayed` is an exact single-play timestamp — an import, a
    /// synced play, or a play witnessed live by the scrobbler — rather than a
    /// blunt "last played ever" snapshot carrying a cumulative play count (the
    /// local Apple Music library scan). Only exact entries are attributed to a
    /// specific date range; approximate ones only ever count in "All time"
    /// (see LibraryStore.visible) since we genuinely don't know when they happened.
    var isExact: Bool = true
    /// Worked out from a rise in Apple Music's lifetime play count rather than
    /// witnessed as it happened. We know it fell between two library scans, so
    /// it can be dated well enough to count in a week or a month — but not to
    /// the minute, and it's flagged so nothing presents it as a real scrobble.
    var inferred: Bool = false

    var totalMs: Int { lengthMs * plays }

    /// Whether this record should be counted as a *play*, as opposed to time
    /// listened. It always contributes its time — you did hear those seconds.
    ///
    /// A Spotify data export records one row per stream with the milliseconds
    /// actually streamed, and no minimum: skipping four seconds into a track
    /// files a "play" indistinguishable from one you sat through. Live scrobbles
    /// and Last.fm entries carry the *track's* length instead, and only exist at
    /// all because they already passed a scrobble rule — so a stored length far
    /// too short to be a song is the signature of an abandoned stream, and the
    /// only records it can catch are the ones that shouldn't have counted.
    /// Only ever applied to a single dated play. A library record is an
    /// aggregate — a real track length and a lifetime count — so a genuinely
    /// short song there is a short song, not an abandoned stream.
    var countsAsPlay: Bool {
        guard PlayCounting.enabled, isExact, lengthMs > 0 else { return true }
        return lengthMs >= PlayCounting.minMs
    }

    /// `plays`, or zero for a stream too short to call a play.
    var countedPlays: Int { countsAsPlay ? plays : 0 }

    func withPlays(_ n: Int) -> Track {
        Track(id: id, title: title, artist: artist, album: album, albumKey: albumKey,
              source: source, lengthMs: lengthMs, plays: n, lastPlayed: lastPlayed,
              artURL: artURL, isExact: isExact, year: year, inferred: inferred)
    }

    /// The same play with a length filled in. Last.fm scrobbles arrive without
    /// one, so they settle for an estimate until a source that knows the real
    /// duration turns up.
    func withLength(_ ms: Int) -> Track {
        Track(id: id, title: title, artist: artist, album: album, albumKey: albumKey,
              source: source, lengthMs: ms, plays: plays, lastPlayed: lastPlayed,
              artURL: artURL, isExact: isExact, year: year, inferred: inferred)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumKey, source, lengthMs, plays, lastPlayed, artURL, isExact, year, inferred
    }

    init(id: UUID = UUID(), title: String, artist: String, album: String, albumKey: String,
         source: Source, lengthMs: Int, plays: Int, lastPlayed: Date?, artURL: String? = nil,
         isExact: Bool = true, year: Int? = nil, inferred: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.source = source
        self.lengthMs = lengthMs
        self.plays = plays
        self.lastPlayed = lastPlayed
        self.artURL = artURL
        self.isExact = isExact
        self.year = year
        self.inferred = inferred
    }

    // Custom decode so history.json saved before `isExact` existed still loads
    // (missing key defaults to true — everything persisted so far was exact).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        albumKey = try c.decode(String.self, forKey: .albumKey)
        source = try c.decode(Source.self, forKey: .source)
        lengthMs = try c.decode(Int.self, forKey: .lengthMs)
        plays = try c.decode(Int.self, forKey: .plays)
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        artURL = try c.decodeIfPresent(String.self, forKey: .artURL)
        isExact = try c.decodeIfPresent(Bool.self, forKey: .isExact) ?? true
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        inferred = try c.decodeIfPresent(Bool.self, forKey: .inferred) ?? false
    }
}

/// A time window for filtering listening. Because Apple's library only records
/// each track's *last-played* date (not individual plays), a range includes a
/// track if it was last played inside the window.
enum TimeRange: Hashable {
    case last7, last30, last3mo, last6mo, allTime
    case custom(Date, Date)

    static let presets: [TimeRange] = [.last7, .last30, .last3mo, .last6mo, .allTime]

    var label: String {
        switch self {
        case .last7:   return "7 days"
        case .last30:  return "30 days"
        case .last3mo: return "3 months"
        case .last6mo: return "6 months"
        case .allTime: return "All time"
        case .custom:  return "Custom"
        }
    }

    var isCustom: Bool { if case .custom = self { return true }; return false }
    var isAllTime: Bool { if case .allTime = self { return true }; return false }

    func contains(_ date: Date?) -> Bool {
        if case .allTime = self { return true }
        guard let date = date else { return false }
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .last7:   return date >= cal.date(byAdding: .day, value: -7, to: now)!
        case .last30:  return date >= cal.date(byAdding: .day, value: -30, to: now)!
        case .last3mo: return date >= cal.date(byAdding: .month, value: -3, to: now)!
        case .last6mo: return date >= cal.date(byAdding: .month, value: -6, to: now)!
        case .allTime: return true
        case .custom(let a, let b):
            let lo = cal.startOfDay(for: min(a, b))
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(a, b)))!
            return date >= lo && date < hi   // inclusive of the end day
        }
    }
}

enum GroupBy: String, CaseIterable, Identifiable {
    case artist = "Artists"
    case app = "Apps"
    case song = "Songs"
    case album = "Albums"
    var id: String { rawValue }

    /// What the user sees. "Apps" was misleading once Last.fm folded into
    /// Spotify — these are really the sources a play came from. The raw value
    /// stays put so saved preferences keep working.
    var title: String { self == .app ? "Sources" : rawValue }
}

enum SortBy: String, CaseIterable, Identifiable {
    case time = "Time listened"
    case plays = "Play count"
    case name = "Name (A–Z)"
    case recent = "Recently played"
    var id: String { rawValue }
}

/// An aggregated row (an artist, an app, or a song).
struct Bucket: Identifiable {
    var id: String
    var label: String
    var sublabel: String = ""
    var totalMs: Int = 0
    var plays: Int = 0
    var songKeys: Set<String> = []
    var sources: Set<Source> = []
    var artKey: String? = nil   // album cover of the most-played track in this bucket
    var bestPlays: Int = -1
    /// Most recent exact play in this bucket — powers the "Recently played" sort.
    var lastPlayed: Date? = nil
}

/// How large a unit a listening total is allowed to reach. Hours are fine for a
/// day or an artist; a lifetime of plays in hours is a number nobody can picture.
enum TimeUnits: String, CaseIterable, Identifiable {
    case hoursMinutes, days, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hoursMinutes: return "Hours and minutes"
        case .days:         return "Days as well"
        case .full:         return "Days, months and years"
        }
    }
}

/// What to do with units that come out at zero — whether "0y 42d" reads better
/// than "1mo 12d" is a matter of taste, so it's a setting rather than a rule.
enum TimeZeros: String, CaseIterable, Identifiable {
    case leadSkipMonths, leadKeepMonths, allUnits, adjacent, trim
    var id: String { rawValue }
    var label: String {
        // Worded for the largest unit rather than for years, because "Days as
        // well" has no years to start at.
        switch self {
        case .leadSkipMonths: return "Always show the largest unit, and skip months"
        case .leadKeepMonths: return "Always show the largest unit"
        case .allUnits:       return "Show every unit"
        case .adjacent:       return "Keep the next unit down"
        case .trim:           return "Skip empty units"
        }
    }

    /// Only the choices that actually change something in this mode.
    ///
    /// The two "largest unit" styles exist to pad a leading zero, and "skip
    /// months" exists to keep days counting past thirty — neither has anything
    /// to do once days *are* the largest unit. Offering all five under "Days as
    /// well" gave four radio buttons that did nothing.
    static func options(for units: TimeUnits) -> [TimeZeros] {
        units == .full ? allCases : [.trim, .adjacent, .allUnits]
    }

    /// The behaviour this style collapses to when the mode can't express it, so
    /// a picker never sits with nothing selected.
    func resolved(for units: TimeUnits) -> TimeZeros {
        Self.options(for: units).contains(self) ? self : .trim
    }
}

enum TimeFmt {
    static func short(_ ms: Int) -> String {
        short(ms, units: ThemeManager.shared.timeUnits, zeros: ThemeManager.shared.timeZeros)
    }

    /// A duration in the chosen units. Anything under a day always reads exactly
    /// as it did before any of this was an option, whatever else is set — the
    /// larger units only ever change the totals that were unreadable in hours.
    ///
    /// A month here is a flat 30 days and a year 365: listening time is a span,
    /// not a stretch of calendar, so there's no month to be the length of.
    static func short(_ ms: Int, units: TimeUnits, zeros: TimeZeros) -> String {
        let total = max(0, Int((Double(ms) / 60000).rounded()))
        func hoursAndMinutes() -> String {
            let h = total / 60, m = total % 60
            return h >= 1 ? "\(h)h \(m)m" : "\(m)m"
        }
        guard units != .hoursMinutes, total >= 24 * 60 else { return hoursAndMinutes() }

        // Months are left out of the ladder entirely for `leadSkipMonths`, which
        // is what lets days keep climbing past thirty and gives "0y 42d".
        var ladder: [(suffix: String, minutes: Int)] = units == .full
            ? (zeros == .leadSkipMonths
                ? [("y", 365 * 24 * 60), ("d", 24 * 60)]
                : [("y", 365 * 24 * 60), ("mo", 30 * 24 * 60), ("d", 24 * 60)])
            : [("d", 24 * 60)]
        ladder += [("h", 60), ("m", 1)]

        var rem = total
        var vals: [(suffix: String, value: Int)] = []
        for (suffix, size) in ladder { vals.append((suffix, rem / size)); rem %= size }
        func text(_ v: (suffix: String, value: Int)) -> String { "\(v.value)\(v.suffix)" }

        switch zeros {
        case .leadSkipMonths, .leadKeepMonths:
            // The biggest unit is always spoken, even at zero; it's paired with
            // the next one that actually carries something.
            var parts = [text(vals[0])]
            if let next = vals.dropFirst().first(where: { $0.value > 0 }) { parts.append(text(next)) }
            return parts.joined(separator: " ")
        case .allUnits:
            // Literally every unit of the ladder, minutes included. Stopping
            // short made this the least detailed option rather than the most.
            return vals.map(text).joined(separator: " ")
        case .adjacent:
            guard let i = vals.firstIndex(where: { $0.value > 0 }) else { return hoursAndMinutes() }
            var parts = [text(vals[i])]
            if i + 1 < vals.count { parts.append(text(vals[i + 1])) }
            return parts.joined(separator: " ")
        case .trim:
            let carried = vals.filter { $0.value > 0 }.prefix(2)
            guard !carried.isEmpty else { return hoursAndMinutes() }
            return carried.map(text).joined(separator: " ")
        }
    }
    static func minutes(_ ms: Int) -> String {
        let totalMin = Int((Double(ms) / 60000).rounded())
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: totalMin)) ?? "\(totalMin)") + " min"
    }
    static func commas(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// How short a stream has to be before Tempo stops calling it a play.
///
/// Only ever changes what is *counted*, never what is stored: turn it off and
/// every play is back. Listening time is unaffected either way.
enum PlayCounting {
    static let enabledKey = "count.skipShortPlays"
    static let secondsKey = "count.minPlaySeconds"

    /// On by default. An imported history is mostly skips otherwise — 44% of a
    /// 73,000-row Spotify export here was under thirty seconds — and every
    /// ranking by play count reads as how often something was skipped past.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    static var seconds: Int {
        let v = UserDefaults.standard.integer(forKey: secondsKey)
        return v > 0 ? v : 30          // Last.fm's own floor
    }
    static var minMs: Int { seconds * 1000 }

    static let choices = [10, 20, 30, 45, 60]
}
