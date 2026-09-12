import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Scope

/// Which slice of history a Wrapped is about. Year scopes only include plays we
/// have exact timestamps for, so an Apple Music library scan (one lifetime
/// "last played" date per track) shows up under All time only — see Track.isExact.
enum WrappedScope: Hashable, Identifiable {
    case allTime
    case year(Int)

    var id: String { label }
    var label: String {
        switch self {
        case .allTime: return "All time"
        case .year(let y): return "\(y)"
        }
    }
    var range: TimeRange {
        switch self {
        case .allTime: return .allTime
        case .year(let y):
            let cal = Calendar.current
            let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? Date()
            let end   = cal.date(from: DateComponents(year: y, month: 12, day: 31)) ?? Date()
            return .custom(start, end)
        }
    }

    /// All-time plus one entry per year we actually have plays for, newest first.
    @MainActor static func available(_ store: LibraryStore) -> [WrappedScope] {
        [.allTime] + store.playYears.map { .year($0) }
    }
}

// MARK: - Wrapped stats

/// Everything the Wrapped view shows, computed once from the store.
struct WrappedData {
    var scope: WrappedScope = .allTime
    var totalMs = 0
    var totalPlays = 0
    var uniqueArtists = 0
    var uniqueSongs = 0
    var topArtists: [Bucket] = []
    var topSongs: [Bucket] = []
    var topGenres: [(name: String, ms: Int)] = []
    var sources: [(Source, Int)] = []      // (source, ms), busiest first
    var firstPlay: Date? = nil
    var lastPlay: Date? = nil
    var personalityTitle = ""
    var personalityBlurb = ""

    // In-depth (exact-timestamp plays only)
    var byHour = Array(repeating: 0, count: 24)
    var byWeekday = Array(repeating: 0, count: 7)   // 0 = Sunday
    var byMonth: [(label: String, plays: Int)] = []
    var dayCounts: [Date: Int] = [:]                // listening-day -> plays
    var peakHour = 0
    var peakWeekday = 0
    var busiestDay: (date: Date, plays: Int)? = nil
    var distinctDays = 0
    var avgActiveDayMs = 0
    var topArtistShare = 0.0
    var oneShotArtists = 0
    var exactPlays = 0
    var currentStreak = 0
    var longestStreak = 0

    // Deeper stats
    var prevMs: Int? = nil                 // same-length previous period
    var prevLabel = ""
    var recentWindowMs: Int? = nil         // all-time scope: the last 30 days
    var discoveries: [LibraryStore.ArtistSpan] = []   // first heard in this period
    var discoveryCount = 0
    var dusty: [LibraryStore.ArtistSpan] = []         // loved once, long untouched
    var longestSession: (plays: Int, ms: Int, start: Date)? = nil
    var skipRate: Double = 0
    var topSkipped: [(name: String, count: Int)] = []
    var totalSkips = 0

    /// For a year scope this compares whole years; for all time it compares the
    /// last 30 days with the 30 before that (a lifetime total has nothing to be
    /// compared against).
    var deltaPercent: Int? {
        guard let p = prevMs, p > 0 else { return nil }
        let current = recentWindowMs ?? totalMs
        return Int(((Double(current) - Double(p)) / Double(p) * 100).rounded())
    }

    var isEmpty: Bool { totalPlays == 0 && exactPlays == 0 }

    @MainActor static func compute(_ store: LibraryStore, splitCollabs: Bool, scope: WrappedScope) -> WrappedData {
        var w = WrappedData()
        w.scope = scope
        let range = scope.range
        // Splitting attributes a collab's full time to EACH artist, so the sum
        // over artist buckets double-counts — take the real totals from songs
        // (each song counted once) and use the artist buckets only for the
        // artist-specific stats.
        let artists = store.buckets(groupBy: .artist, sortBy: .time, range: range, source: nil, search: "", split: splitCollabs)
        let songs   = store.buckets(groupBy: .song,   sortBy: .time, range: range, source: nil, search: "")
        let apps    = store.buckets(groupBy: .app,    sortBy: .time, range: range, source: nil, search: "")

        w.totalMs        = songs.reduce(0) { $0 + $1.totalMs }
        w.totalPlays     = songs.reduce(0) { $0 + $1.plays }
        w.uniqueArtists  = artists.count
        w.uniqueSongs    = songs.count
        w.topArtists     = Array(artists.prefix(5))
        // Songs rank by play count — that's the number we show next to them, and
        // ranking by time while displaying plays reads as an ordering bug.
        w.topSongs       = Array(songs.sorted { $0.plays > $1.plays }.prefix(5))
        w.oneShotArtists = artists.filter { $0.plays == 1 }.count
        // Clamped: with collaborations split, an artist is credited the full
        // length of a shared track, so a raw ratio against the (once-counted)
        // song total can exceed 100%.
        w.topArtistShare = w.totalMs > 0
            ? min(1, Double(artists.first?.totalMs ?? 0) / Double(w.totalMs)) : 0
        w.sources = apps.compactMap { b in
            guard let s = Source.allCases.first(where: { $0.display.rawValue == b.label }) else { return nil }
            return (s.display, b.totalMs)
        }

        // Genres: fold each artist's listening time into their Last.fm tags.
        var genreMs: [String: Int] = [:]
        for b in artists {
            for tag in store.artistGenres[b.label.lowercased()] ?? [] {
                genreMs[tag, default: 0] += b.totalMs
            }
        }
        w.topGenres = genreMs.sorted { $0.value > $1.value }.prefix(6).map { (name: $0.key, ms: $0.value) }

        let cal = Calendar.current
        let plays = store.recentPlays.filter { range.contains($0.lastPlayed) }   // newest first
        w.exactPlays = plays.count
        w.firstPlay = plays.last?.lastPlayed
        w.lastPlay  = plays.first?.lastPlayed
        var monthCounts: [Date: Int] = [:]
        var exactMs = 0
        for t in plays {
            guard let d = t.lastPlayed else { continue }
            w.byHour[cal.component(.hour, from: d)] += 1
            w.byWeekday[cal.component(.weekday, from: d) - 1] += 1
            w.dayCounts[LibraryStore.listeningDay(d), default: 0] += 1
            if let m = cal.date(from: cal.dateComponents([.year, .month], from: d)) {
                monthCounts[m, default: 0] += 1
            }
            exactMs += t.totalMs
        }
        w.distinctDays   = w.dayCounts.count
        w.avgActiveDayMs = w.distinctDays > 0 ? exactMs / w.distinctDays : 0
        w.peakHour       = w.byHour.indices.max(by: { w.byHour[$0] < w.byHour[$1] }) ?? 0
        w.peakWeekday    = w.byWeekday.indices.max(by: { w.byWeekday[$0] < w.byWeekday[$1] }) ?? 0
        if let best = w.dayCounts.max(by: { $0.value < $1.value }) { w.busiestDay = (best.key, best.value) }
        let mf = DateFormatter(); mf.dateFormat = "MMM"
        w.byMonth = monthCounts.sorted { $0.key < $1.key }.suffix(12).map { (mf.string(from: $0.key), $0.value) }
        (w.currentStreak, w.longestStreak) = streaks(w.dayCounts)
        w.longestSession = longestSession(plays)

        // Previous comparable period: the year before, or the preceding 30 days.
        // Only shown when history actually COVERS that earlier window — comparing
        // against a window that predates your data just reports when you started
        // using Tempo (a wildly inflated "+700%"), not a real change in habits.
        let historyStart = store.importedTracks.compactMap { $0.lastPlayed }.min()
        switch scope {
        case .year(let y):
            let prevStart = cal.date(from: DateComponents(year: y - 1, month: 1, day: 1)) ?? Date()
            let covered = (historyStart ?? Date()) <= cal.date(byAdding: .day, value: 30, to: prevStart)!
            let prev = WrappedScope.year(y - 1).range
            let ms = store.visible(range: prev, source: nil, search: "").reduce(0) { $0 + $1.totalMs }
            if ms > 0, covered { w.prevMs = ms; w.prevLabel = "\(y - 1)" }
        case .allTime:
            let now = Date()
            let d30 = cal.date(byAdding: .day, value: -30, to: now) ?? now
            let d60 = cal.date(byAdding: .day, value: -60, to: now) ?? now
            let recent = store.recentPlays.filter { ($0.lastPlayed ?? .distantPast) > d30 }
                .reduce(0) { $0 + $1.totalMs }
            let prior = store.recentPlays.filter {
                let d = $0.lastPlayed ?? .distantPast
                return d > d60 && d <= d30
            }.reduce(0) { $0 + $1.totalMs }
            if prior > 0, let h = historyStart, h <= d60 {
                w.prevMs = prior; w.prevLabel = "the 30 days before"
                // For all-time the headline is lifetime, so compare the windows.
                w.recentWindowMs = recent
            }
        }

        // Discoveries + gathering dust, using each artist's full history.
        let spans = store.artistSpans()
        let scopeStart: Date? = { if case .year(let y) = scope {
            return cal.date(from: DateComponents(year: y, month: 1, day: 1)) } else { return nil } }()
        // "Discovered" only means something once there's history BEFORE the
        // period. In your first tracked year every artist looks new, which is an
        // artifact of when you started using Tempo, not a real discovery.
        let discoveriesMeaningful: Bool = {
            guard let start = scopeStart, let h = historyStart,
                  let cutoff = cal.date(byAdding: .day, value: 30, to: h) else { return false }
            return start > cutoff
        }()
        let discovered = discoveriesMeaningful ? spans.values.filter { s in
            guard let start = scopeStart else { return false }
            return s.first >= start && range.contains(s.first)
        } : []
        w.discoveryCount = discovered.count
        w.discoveries = discovered.sorted { $0.ms > $1.ms }.prefix(5).map { $0 }

        let sixMonthsAgo = cal.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        w.dusty = spans.values
            .filter { $0.last < sixMonthsAgo && $0.plays >= 8 }
            .sorted { $0.ms > $1.ms }.prefix(5).map { $0 }

        // Skips (live scrobbler only, so they're always all-time).
        w.totalSkips = store.totalSkips
        let scrobbled = store.importedTracks.count
        if w.totalSkips > 0 {
            w.skipRate = Double(w.totalSkips) / Double(w.totalSkips + max(scrobbled, 1))
            w.topSkipped = store.skips.sorted { $0.value > $1.value }.prefix(5).map {
                (name: $0.key.replacingOccurrences(of: "::", with: " — "), count: $0.value)
            }
        }

        let variety = w.totalPlays > 0 ? Double(w.uniqueArtists) / Double(w.totalPlays) : 0
        if w.uniqueArtists == 0 {
            w.personalityTitle = "The Newcomer";  w.personalityBlurb = "Your story's just getting started."
        } else if w.uniqueArtists < 15 {
            w.personalityTitle = "The Specialist"; w.personalityBlurb = "A tight rotation — you know exactly what you like."
        } else if w.topArtistShare > 0.25 {
            w.personalityTitle = "The Devotee";    w.personalityBlurb = "One artist quietly runs your whole library."
        } else if variety > 0.5 {
            w.personalityTitle = "The Explorer";   w.personalityBlurb = "Always a track ahead — you rarely repeat yourself."
        } else {
            w.personalityTitle = "The Regular";    w.personalityBlurb = "A steady mix of old favorites and fresh finds."
        }
        return w
    }

    /// The longest unbroken listening run: consecutive plays with less than 20
    /// minutes between them. `plays` is newest-first, so we walk it backwards.
    private static func longestSession(_ plays: [Track]) -> (plays: Int, ms: Int, start: Date)? {
        let stamps = plays.compactMap { $0.lastPlayed }.sorted()
        guard stamps.count > 1 else { return nil }
        let gapLimit: TimeInterval = 20 * 60
        var bestCount = 1, bestStart = stamps[0], bestEnd = stamps[0]
        var runCount = 1, runStart = stamps[0]
        for i in 1..<stamps.count {
            if stamps[i].timeIntervalSince(stamps[i - 1]) <= gapLimit {
                runCount += 1
            } else {
                runCount = 1; runStart = stamps[i]
            }
            if runCount > bestCount {
                bestCount = runCount; bestStart = runStart; bestEnd = stamps[i]
            }
        }
        guard bestCount > 2 else { return nil }
        return (bestCount, Int(bestEnd.timeIntervalSince(bestStart) * 1000), bestStart)
    }

    /// (current, longest) run of consecutive listening days. The current streak
    /// counts back from today — or yesterday, so a day still in progress doesn't
    /// look like a broken streak.
    private static func streaks(_ days: [Date: Int]) -> (Int, Int) {
        guard !days.isEmpty else { return (0, 0) }
        let cal = Calendar.current
        let sorted = days.keys.sorted()
        var longest = 1, run = 1
        for i in 1..<max(sorted.count, 1) {
            let gap = cal.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day ?? 0
            if gap == 1 { run += 1; longest = max(longest, run) } else { run = 1 }
        }
        let today = LibraryStore.listeningDay(Date())
        let set = Set(sorted)
        var cursor = today
        if !set.contains(cursor) {                      // nothing yet today — allow yesterday
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            if !set.contains(cursor) { return (0, longest) }
        }
        var current = 0
        while set.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return (current, max(longest, current))
    }
}

// MARK: - Wrapped view

struct WrappedPanel: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showDeep = false
    @State private var scope: WrappedScope = .allTime
    @State private var sharing = false
    @State private var shareNote: String? = nil
    /// Counts down while the jackpot animation runs; each tick re-renders the
    /// hero with a fresh random number, so it reads like a slot machine.
    @State private var spinTicks = 0
    @State private var konami: [UInt16] = []
    @State private var konamiMonitor: Any? = nil
    private var spinning: Bool { spinTicks > 0 }
    @AppStorage("wrapped.splitCollabs") private var splitCollabs = true

    /// ↑↑↓↓←→←→BA — the hero number pays out like a slot machine.
    private static let konamiCode: [UInt16] = [126, 126, 125, 125, 123, 124, 123, 124, 11, 0]

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        let d = store.wrapped(scope: scope, splitCollabs: splitCollabs)
        VStack(alignment: .leading, spacing: 36) {
            header(d)
            scopePicker
            if d.isEmpty {
                emptyState
            } else {
                if let years = anniversary(d) { anniversaryBanner(years) }
                hero(d)
                tiles(d)
                if d.deltaPercent != nil { comparison(d) }
                if d.currentStreak > 0 || d.longestStreak > 1 { streakBar(d) }
                topArtistFeature(d)
                if d.topArtists.count > 1 { rankedArtists(d) }
                rankedSongs(d)
                if !d.topGenres.isEmpty { genres(d) }
                if !d.discoveries.isEmpty { discoveries(d) }
                if !d.dusty.isEmpty { dusty(d) }
                personality(d)
                deepToggle
                if showDeep { deepSection(d) }
            }
        }
        .onAppear {
            store.resolveGenres()
            installKonami()
        }
        .onDisappear {
            if let m = konamiMonitor { NSEvent.removeMonitor(m); konamiMonitor = nil }
        }
    }

    private func installKonami() {
        guard konamiMonitor == nil else { return }
        konamiMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            konami.append(e.keyCode)
            if konami.count > Self.konamiCode.count { konami.removeFirst() }
            if konami == Self.konamiCode {
                konami.removeAll()
                jackpot()
                return nil
            }
            return e
        }
    }

    /// Spin the hero number for a moment, then settle back to the truth.
    private func jackpot() {
        spinTicks = 18
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            MainActor.assumeIsolated {
                if spinTicks > 0 { spinTicks -= 1 } else { t.invalidate() }
            }
        }
    }

    // MARK: headline

    private func header(_ d: WrappedData) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("WRAPPED").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.green)
                Text(scope == .allTime ? "Your listening, wrapped" : "Your \(scope.label), wrapped")
                    .font(Type.display(40, .medium)).foregroundColor(C.text)
                Text(spanLabel(d)).font(Type.mono(11)).foregroundColor(C.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button { share(d) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11 * theme.zoom))
                        Text(sharing ? "Saving…" : "Share").font(Type.mono(11, .semibold))
                    }
                    .foregroundColor(C.text)
                    .padding(.vertical, 7).padding(.horizontal, 13)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(C.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(sharing || d.isEmpty)
                .help("Save your Wrapped as an image")
                if let n = shareNote {
                    Text(n).font(Type.mono(9)).foregroundColor(C.muted2)
                }
            }
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 20) {
            ForEach(WrappedScope.available(store)) { s in
                chip(s.label, active: scope == s) { scope = s }
            }
            Spacer()
        }
    }

    /// Whole years since your very first tracked play, but only in the week
    /// around the date itself — otherwise it's just a number, not an occasion.
    private func anniversary(_ d: WrappedData) -> Int? {
        guard let first = store.importedTracks.compactMap({ $0.lastPlayed }).min() else { return nil }
        let cal = Calendar.current
        let years = cal.dateComponents([.year], from: first, to: Date()).year ?? 0
        guard years >= 1,
              let mark = cal.date(byAdding: .year, value: years, to: first) else { return nil }
        let days = abs(cal.dateComponents([.day], from: mark, to: Date()).day ?? 99)
        return days <= 3 ? years : nil
    }

    private func anniversaryBanner(_ years: Int) -> some View {
        HStack(spacing: 12) {
            Text("🎂").font(.system(size: 20))
            Text(years == 1 ? "One year with Tempo" : "\(years) years with Tempo")
                .font(Type.display(18, .medium)).foregroundColor(C.text)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(C.green.opacity(0.12)))
    }

    private func spanLabel(_ d: WrappedData) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        if let a = d.firstPlay, let b = d.lastPlay {
            let sa = f.string(from: a), sb = f.string(from: b)
            return sa == sb ? "\(scope.label) · \(sa)" : "\(scope.label) · \(sa) – \(sb)"
        }
        return scope.label
    }

    private func hero(_ d: WrappedData) -> some View {
        let minutes = Int((Double(d.totalMs) / 60000).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            Text(TimeFmt.commas(spinning ? Int.random(in: 1...999_999) : minutes))
                .font(Type.display(84, .medium)).foregroundColor(spinning ? C.green : C.text)
                .minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText())
            Text("MINUTES LISTENED").font(Type.mono(11, .medium)).tracking(2).foregroundColor(C.muted)
            Text("that's \(TimeFmt.short(d.totalMs)) of music").font(Type.mono(11)).foregroundColor(C.muted2).padding(.top, 2)
                .cyclesTimeUnits()
                .help(funUnits(d.totalMs))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(C.green.opacity(0.10)))
    }

    /// Easter egg: hovering the hero tells you the total in sillier units.
    private func funUnits(_ ms: Int) -> String {
        let days = Double(ms) / 86_400_000
        if days >= 7 { return String(format: "≈ %.1f days straight · %.1f full work weeks", days, days * 24 / 40) }
        if days >= 1 { return String(format: "≈ %.1f days straight", days) }
        return String(format: "≈ %.1f hours straight", Double(ms) / 3_600_000)
    }

    private func tiles(_ d: WrappedData) -> some View {
        HStack(spacing: 12) {
            statTile(TimeFmt.commas(d.totalPlays), "PLAYS")
            statTile(TimeFmt.commas(d.uniqueArtists), "ARTISTS")
            statTile(TimeFmt.commas(d.uniqueSongs), "SONGS")
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Type.display(28, .medium)).foregroundColor(C.text).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(Type.mono(9, .medium)).tracking(1.2).foregroundColor(C.muted2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
    }

    private func streakBar(_ d: WrappedData) -> some View {
        HStack(spacing: 14) {
            Text("🔥").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(d.currentStreak > 0 ? "\(d.currentStreak)-day streak" : "No streak right now")
                    .font(Type.display(18, .medium)).foregroundColor(C.text)
                Text("longest: \(d.longestStreak) day\(d.longestStreak == 1 ? "" : "s") · \(TimeFmt.commas(d.distinctDays)) days with music")
                    .font(Type.mono(10)).foregroundColor(C.muted2)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
    }

    @ViewBuilder private func comparison(_ d: WrappedData) -> some View {
        if let pct = d.deltaPercent, let prev = d.prevMs {
            let up = pct >= 0
            HStack(spacing: 14) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(up ? C.green : C.muted)
                VStack(alignment: .leading, spacing: 3) {
                    // On the all-time scope the headline is a lifetime total, so
                    // say plainly that this compares recent windows instead.
                    Text(d.recentWindowMs != nil
                         ? "Last 30 days: \(abs(pct))% \(up ? "more" : "less") than the 30 before"
                         : "\(abs(pct))% \(up ? "more" : "less") than \(d.prevLabel)")
                        .font(Type.display(18, .medium)).foregroundColor(C.text)
                    Text(d.recentWindowMs != nil
                         ? "last 30 days: \(TimeFmt.short(d.recentWindowMs ?? 0)) vs \(TimeFmt.short(prev))"
                         : "\(d.prevLabel): \(TimeFmt.short(prev))")
                        .font(Type.mono(10)).foregroundColor(C.muted2)
                        .cyclesTimeUnits()
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
        }
    }

    private func discoveries(_ d: WrappedData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("DISCOVERED IN \(scope.label.uppercased())")
            Text("\(TimeFmt.commas(d.discoveryCount)) new artist\(d.discoveryCount == 1 ? "" : "s")")
                .font(Type.display(22, .medium)).foregroundColor(C.text)
            ForEach(Array(d.discoveries.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 12) {
                    artistArt(s.name, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(Type.display(15, .medium)).foregroundColor(C.text).lineLimit(1)
                        Text("first heard \(s.first.formatted(date: .abbreviated, time: .omitted))")
                            .font(Type.mono(9)).foregroundColor(C.muted2)
                    }
                    Spacer()
                    Text(TimeFmt.short(s.ms)).font(Type.mono(11)).foregroundColor(C.muted).cyclesTimeUnits()
                }
            }
        }
    }

    private func dusty(_ d: WrappedData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("GATHERING DUST")
            Text("You loved these once — nothing in 6+ months.")
                .font(Type.mono(11)).foregroundColor(C.muted)
            ForEach(Array(d.dusty.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 12) {
                    artistArt(s.name, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(Type.display(15, .medium)).foregroundColor(C.text).lineLimit(1)
                        Text("last played \(s.last.formatted(date: .abbreviated, time: .omitted)) · \(TimeFmt.commas(s.plays)) plays")
                            .font(Type.mono(9)).foregroundColor(C.muted2)
                    }
                    Spacer()
                    Text(TimeFmt.short(s.ms)).font(Type.mono(11)).foregroundColor(C.muted).cyclesTimeUnits()
                }
                .contextMenu { TrackActions.menu(title: s.name, artist: "", groupBy: .artist) }
            }
        }
    }

    @ViewBuilder private func topArtistFeature(_ d: WrappedData) -> some View {
        if let top = d.topArtists.first {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("YOUR TOP ARTIST")
                HStack(spacing: 18) {
                    artistArt(top.label, size: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(top.label).font(Type.display(34, .medium)).foregroundColor(C.text).lineLimit(2)
                        Text("\(TimeFmt.short(top.totalMs)) · \(TimeFmt.commas(top.plays)) plays")
                            .cyclesTimeUnits()
                            .font(Type.mono(11)).foregroundColor(C.muted)
                        if d.topArtistShare > 0 {
                            Text("\(Int((d.topArtistShare * 100).rounded()))% of your listening")
                                .font(Type.mono(10)).foregroundColor(C.green)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func artistArt(_ name: String, size: CGFloat) -> some View {
        Group {
            if let img = store.artistImage(for: name) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
            } else { letterTile(name) }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }

    private func letterTile(_ s: String) -> some View {
        let letter = s.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "♪"
        var h = 0; for ch in s.unicodeScalars { h = (h * 31 + Int(ch.value)) % 360 }
        return Circle().fill(Color(hue: Double(h) / 360, saturation: 0.30, brightness: 0.32))
            .overlay(Text(letter).font(Type.display(30, .medium)).foregroundColor(.white.opacity(0.9)))
    }

    private func rankedArtists(_ d: WrappedData) -> some View {
        let maxMs = d.topArtists.first?.totalMs ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("MORE OF YOUR TOP ARTISTS")
            ForEach(Array(d.topArtists.enumerated()).dropFirst(), id: \.element.id) { i, b in
                wrapRow(rank: i + 1, title: b.label, sub: "\(TimeFmt.commas(b.plays)) plays",
                        value: TimeFmt.short(b.totalMs), frac: Double(b.totalMs) / Double(max(maxMs, 1)))
                    .cyclesTimeUnits()
            }
        }
    }

    private func rankedSongs(_ d: WrappedData) -> some View {
        let maxPlays = d.topSongs.first?.plays ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("YOUR TOP SONGS")
            ForEach(Array(d.topSongs.enumerated()), id: \.element.id) { i, b in
                wrapRow(rank: i + 1, title: b.label, sub: b.sublabel,
                        value: "\(TimeFmt.commas(b.plays)) plays", frac: Double(b.plays) / Double(max(maxPlays, 1)))
            }
        }
    }

    private func wrapRow(rank: Int, title: String, sub: String, value: String, frac: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("\(rank)").font(Type.mono(13)).foregroundColor(C.muted2).frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Type.display(16, .medium)).foregroundColor(C.text).lineLimit(1)
                    if !sub.isEmpty { Text(sub).font(Type.mono(10)).foregroundColor(C.muted2).lineLimit(1) }
                }
                Spacer(minLength: 12)
                Text(value).font(Type.mono(12, .medium)).foregroundColor(C.text)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(C.line)
                    Capsule().fill(C.green).frame(width: max(2, g.size.width * frac))
                }
            }.frame(height: 3).padding(.leading, 36)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
    }

    private func genres(_ d: WrappedData) -> some View {
        let maxMs = d.topGenres.first?.ms ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("YOUR TOP GENRES")
            ForEach(Array(d.topGenres.enumerated()), id: \.offset) { _, g in
                HStack(spacing: 12) {
                    Text(g.name).font(Type.display(15, .medium)).foregroundColor(C.text)
                        .frame(width: 130, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(C.line)
                            Capsule().fill(C.green.opacity(0.75))
                                .frame(width: max(2, geo.size.width * Double(g.ms) / Double(max(maxMs, 1))))
                        }
                    }.frame(height: 5)
                    Text(TimeFmt.short(g.ms)).font(Type.mono(10)).foregroundColor(C.muted).cyclesTimeUnits()
                        .frame(width: 58, alignment: .trailing)
                }
            }
            Text("Genres come from Last.fm community tags for your artists.")
                .font(Type.mono(9)).foregroundColor(C.muted2).padding(.top, 2)
        }
    }

    private func personality(_ d: WrappedData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("YOUR LISTENING TYPE")
            Text(d.personalityTitle).font(Type.display(30, .medium)).foregroundColor(C.green)
            Text(d.personalityBlurb).font(Type.mono(12)).foregroundColor(C.muted).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 14).fill(C.panel))
    }

    private var deepToggle: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { showDeep.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: showDeep ? "chevron.down" : "chevron.right").font(.system(size: 11 * theme.zoom))
                Text(showDeep ? "Hide in-depth stats" : "Show in-depth stats").font(Type.mono(12, .semibold))
            }
            .foregroundColor(C.text)
            .padding(.vertical, 12).padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).stroke(C.line, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: in-depth

    private func deepSection(_ d: WrappedData) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            calendarSection(d)
            clockSection(d)
            weekdaySection(d)
            if d.byMonth.count > 1 { monthSection(d) }
            deepTiles(d)
            if let s = d.longestSession { longestSessionSection(s) }
            if !d.topSkipped.isEmpty { skipsSection(d) }
            if !d.sources.isEmpty { sourcesSection(d) }
        }
        .padding(.top, 6)
    }

    private func longestSessionSection(_ s: (plays: Int, ms: Int, start: Date)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("LONGEST SESSION")
            Text("\(s.plays) songs back to back")
                .font(Type.display(22, .medium)).foregroundColor(C.text)
            Text("\(TimeFmt.short(s.ms)) starting \(s.start.formatted(date: .abbreviated, time: .shortened))")
                .cyclesTimeUnits()
                .font(Type.mono(11)).foregroundColor(C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
    }

    private func skipsSection(_ d: WrappedData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("MOST SKIPPED")
            Text("\(Int((d.skipRate * 100).rounded()))% skip rate · \(TimeFmt.commas(d.totalSkips)) skipped")
                .font(Type.mono(11)).foregroundColor(C.muted)
            ForEach(Array(d.topSkipped.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 12) {
                    Text(s.name).font(Type.display(15, .medium)).foregroundColor(C.text).lineLimit(1)
                    Spacer()
                    Text("\(s.count)×").font(Type.mono(11)).foregroundColor(C.muted)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
            }
            Text("Counted from plays Tempo's live scrobbler saw you abandon early — so it only covers listening on this Mac, from now on.")
                .font(Type.mono(9)).foregroundColor(C.muted2).padding(.top, 2)
        }
    }

    /// GitHub-style contribution grid of listening days.
    private func calendarSection(_ d: WrappedData) -> some View {
        let cal = Calendar.current
        let end: Date
        let start: Date
        switch d.scope {
        case .year(let y):
            start = cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? Date()
            end   = min(cal.date(from: DateComponents(year: y, month: 12, day: 31)) ?? Date(), Date())
        case .allTime:
            end   = LibraryStore.listeningDay(Date())
            start = cal.date(byAdding: .day, value: -364, to: end) ?? end
        }
        // Align the first column to the Sunday on//before the start date.
        let startWeekday = cal.component(.weekday, from: start) - 1
        let gridStart = cal.date(byAdding: .day, value: -startWeekday, to: cal.startOfDay(for: start)) ?? start
        let totalDays = (cal.dateComponents([.day], from: gridStart, to: cal.startOfDay(for: end)).day ?? 0) + 1
        let weeks = max(1, Int(ceil(Double(totalDays) / 7.0)))
        let maxCount = d.dayCounts.values.max() ?? 1

        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("LISTENING CALENDAR")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(0..<weeks, id: \.self) { wk in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { dow in
                                let day = cal.date(byAdding: .day, value: wk * 7 + dow, to: gridStart)!
                                let inRange = day >= cal.startOfDay(for: start) && day <= cal.startOfDay(for: end)
                                let n = d.dayCounts[cal.startOfDay(for: day)] ?? 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(cellColor(n, max: maxCount, inRange: inRange))
                                    .frame(width: 11, height: 11)
                                    .help(inRange ? "\(day.formatted(date: .abbreviated, time: .omitted)): \(n) play\(n == 1 ? "" : "s")" : "")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("less").font(Type.mono(9)).foregroundColor(C.muted2)
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 0 ? C.line.opacity(0.55) : C.green.opacity(0.25 + 0.19 * Double(i)))
                        .frame(width: 11, height: 11)
                }
                Text("more").font(Type.mono(9)).foregroundColor(C.muted2)
            }
        }
    }

    private func cellColor(_ n: Int, max: Int, inRange: Bool) -> Color {
        guard inRange else { return .clear }
        guard n > 0 else { return C.line.opacity(0.55) }
        let frac = Double(n) / Double(Swift.max(max, 1))
        if frac > 0.66 { return C.green.opacity(0.95) }
        if frac > 0.33 { return C.green.opacity(0.70) }
        if frac > 0.12 { return C.green.opacity(0.48) }
        return C.green.opacity(0.28)
    }

    private func clockSection(_ d: WrappedData) -> some View {
        let maxH = d.byHour.max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("WHEN YOU LISTEN")
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { h in
                    Capsule()
                        .fill(h == d.peakHour ? C.green : C.line)
                        .frame(height: max(3, 70 * (maxH > 0 ? Double(d.byHour[h]) / Double(maxH) : 0)))
                        .frame(maxWidth: .infinity)
                        .help("\(hourLabel(h)): \(d.byHour[h]) plays")
                }
            }.frame(height: 70, alignment: .bottom)
            HStack {
                Text("12a").font(Type.mono(9)).foregroundColor(C.muted2); Spacer()
                Text("6a").font(Type.mono(9)).foregroundColor(C.muted2); Spacer()
                Text("12p").font(Type.mono(9)).foregroundColor(C.muted2); Spacer()
                Text("6p").font(Type.mono(9)).foregroundColor(C.muted2); Spacer()
                Text("11p").font(Type.mono(9)).foregroundColor(C.muted2)
            }
            Text(nightOwlLine(d)).font(Type.mono(11)).foregroundColor(C.muted)
        }
    }

    /// Easter egg: the small-hours listeners get called out.
    private func nightOwlLine(_ d: WrappedData) -> String {
        let base = "Peak hour: \(hourLabel(d.peakHour)) · busiest day \(Self.weekdayNames[d.peakWeekday])"
        if (1...4).contains(d.peakHour) { return base + " 🦉 you're a certified night owl" }
        if (5...7).contains(d.peakHour) { return base + " ☀️ an actual morning person" }
        return base
    }

    private func weekdaySection(_ d: WrappedData) -> some View {
        let maxW = d.byWeekday.max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("BY DAY OF WEEK")
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == d.peakWeekday ? C.green : C.line)
                            .frame(height: max(4, 80 * (maxW > 0 ? Double(d.byWeekday[i]) / Double(maxW) : 0)))
                        Text(Self.weekdayNames[i]).font(Type.mono(9)).foregroundColor(C.muted2)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 100, alignment: .bottom)
        }
    }

    private func monthSection(_ d: WrappedData) -> some View {
        let maxM = d.byMonth.map(\.plays).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("BY MONTH")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(d.byMonth.enumerated()), id: \.offset) { _, m in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(C.green.opacity(0.55))
                            .frame(height: max(4, 80 * (maxM > 0 ? Double(m.plays) / Double(maxM) : 0)))
                        Text(m.label).font(Type.mono(8)).foregroundColor(C.muted2).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 100, alignment: .bottom)
        }
    }

    private func deepTiles(_ d: WrappedData) -> some View {
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                statTile(TimeFmt.commas(d.distinctDays), "DAYS WITH MUSIC")
                statTile(TimeFmt.short(d.avgActiveDayMs), "AVG / ACTIVE DAY").cyclesTimeUnits()
            }
            HStack(spacing: 12) {
                if let bd = d.busiestDay {
                    statTile("\(bd.plays)", "PLAYS · \(df.string(from: bd.date).uppercased())")
                }
                statTile("\(d.longestStreak)", "LONGEST STREAK")
            }
            HStack(spacing: 12) {
                statTile("\(d.oneShotArtists)", "ONE-PLAY ARTISTS")
                statTile(TimeFmt.commas(d.exactPlays), "TIMESTAMPED PLAYS")
            }
        }
    }

    private func sourcesSection(_ d: WrappedData) -> some View {
        let maxS = d.sources.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("WHERE YOU LISTEN")
            ForEach(Array(d.sources.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: item.0.hex)).frame(width: 7, height: 7)
                    Text(item.0.rawValue).font(Type.mono(11)).foregroundColor(C.text).frame(width: 90, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(C.line)
                            Capsule().fill(Color(hex: item.0.hex))
                                .frame(width: max(2, g.size.width * (maxS > 0 ? Double(item.1) / Double(maxS) : 0)))
                        }
                    }.frame(height: 5)
                    Text(TimeFmt.short(item.1)).font(Type.mono(11)).foregroundColor(C.muted).frame(width: 60, alignment: .trailing)
                        .cyclesTimeUnits()
                }
            }
        }
    }

    // MARK: share

    private func share(_ d: WrappedData) {
        sharing = true; shareNote = nil
        Task {
            // Pull the top artist's photo first so the card isn't missing it.
            var artistImage: NSImage? = nil
            if let name = d.topArtists.first?.label,
               let s = store.artistURL(for: name), let url = URL(string: s),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                artistImage = NSImage(data: data)
            }
            let card = WrappedCard(data: d, artistImage: artistImage, palette: theme.current)
            if let img = WrappedCardRenderer.render(card) {
                shareNote = WrappedCardRenderer.save(img, scope: d.scope.label)
            } else {
                shareNote = "Couldn't render the card."
            }
            sharing = false
        }
    }

    // MARK: helpers

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2).padding(.bottom, 8)
    }

    private func hourLabel(_ h: Int) -> String {
        let am = h < 12; let hr = h % 12 == 0 ? 12 : h % 12
        return "\(hr)\(am ? "am" : "pm")"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not enough listening yet").font(Type.display(30, .medium)).foregroundColor(C.text)
            Text(scope == .allTime
                 ? "Play some music (or sync Last.fm / Spotify) and your wrapped will build itself."
                 : "No timestamped plays in \(scope.label) yet.")
                .font(Type.mono(11)).foregroundColor(C.muted2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 40)
    }
}

// MARK: - Shareable card

/// A poster-shaped summary rendered offscreen to a PNG. Deliberately separate
/// from `WrappedPanel`: fixed size, no scrolling, no async image loading (the
/// artist photo is passed in already fetched).
struct WrappedCard: View {
    let data: WrappedData
    let artistImage: NSImage?
    let palette: Palette

    static let size = CGSize(width: 900, height: 1400)

    var body: some View {
        let minutes = Int((Double(data.totalMs) / 60000).rounded())
        VStack(alignment: .leading, spacing: 0) {
            Text("TEMPO").font(.system(size: 20, weight: .medium, design: .monospaced))
                .tracking(6).foregroundColor(palette.accent)
            Text(data.scope == .allTime ? "Your listening, wrapped" : "Your \(data.scope.label), wrapped")
                .font(.system(size: 56, weight: .medium, design: .serif))
                .foregroundColor(palette.text).padding(.top, 14)

            Text(TimeFmt.commas(minutes))
                .font(.system(size: 150, weight: .medium, design: .serif))
                .foregroundColor(palette.text).minimumScaleFactor(0.4).lineLimit(1)
                .padding(.top, 40)
            Text("MINUTES LISTENED")
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .tracking(4).foregroundColor(palette.muted)

            HStack(spacing: 0) {
                cardStat(TimeFmt.commas(data.totalPlays), "PLAYS")
                cardStat(TimeFmt.commas(data.uniqueArtists), "ARTISTS")
                cardStat(TimeFmt.commas(data.uniqueSongs), "SONGS")
            }.padding(.top, 46)

            if let top = data.topArtists.first {
                Text("TOP ARTIST").font(.system(size: 17, weight: .medium, design: .monospaced))
                    .tracking(4).foregroundColor(palette.muted2).padding(.top, 52)
                HStack(spacing: 26) {
                    Group {
                        if let img = artistImage {
                            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                        } else {
                            Circle().fill(palette.accent.opacity(0.25))
                                .overlay(Text(String(top.label.prefix(1)).uppercased())
                                    .font(.system(size: 52, weight: .medium, design: .serif))
                                    .foregroundColor(palette.text))
                        }
                    }
                    .frame(width: 130, height: 130).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 8) {
                        Text(top.label).font(.system(size: 46, weight: .medium, design: .serif))
                            .foregroundColor(palette.text).lineLimit(2).minimumScaleFactor(0.6)
                        Text("\(TimeFmt.short(top.totalMs)) · \(TimeFmt.commas(top.plays)) plays")
                            .cyclesTimeUnits()
                            .font(.system(size: 20, design: .monospaced)).foregroundColor(palette.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(.top, 18)
            }

            if !data.topSongs.isEmpty {
                Text("TOP SONGS").font(.system(size: 17, weight: .medium, design: .monospaced))
                    .tracking(4).foregroundColor(palette.muted2).padding(.top, 46)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(data.topSongs.prefix(5).enumerated()), id: \.element.id) { i, b in
                        HStack(spacing: 18) {
                            Text("\(i + 1)").font(.system(size: 22, design: .monospaced))
                                .foregroundColor(palette.muted2).frame(width: 30, alignment: .trailing)
                            Text(b.label).font(.system(size: 26, weight: .medium, design: .serif))
                                .foregroundColor(palette.text).lineLimit(1)
                            Spacer(minLength: 10)
                            Text("\(TimeFmt.commas(b.plays))").font(.system(size: 20, design: .monospaced))
                                .foregroundColor(palette.muted)
                        }
                    }
                }.padding(.top, 16)
            }

            Spacer(minLength: 0)

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(data.personalityTitle)
                        .font(.system(size: 34, weight: .medium, design: .serif))
                        .foregroundColor(palette.accent)
                    Text(data.personalityBlurb)
                        .font(.system(size: 18, design: .monospaced)).foregroundColor(palette.muted)
                }
                Spacer()
                if data.longestStreak > 1 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("🔥 \(data.longestStreak)").font(.system(size: 34, weight: .medium, design: .serif))
                            .foregroundColor(palette.text)
                        Text("LONGEST STREAK").font(.system(size: 14, design: .monospaced))
                            .tracking(2).foregroundColor(palette.muted2)
                    }
                }
            }
            .padding(.top, 40)
        }
        .padding(64)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(palette.bg)
    }

    private func cardStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 48, weight: .medium, design: .serif))
                .foregroundColor(palette.text).minimumScaleFactor(0.5).lineLimit(1)
            Text(label).font(.system(size: 15, weight: .medium, design: .monospaced))
                .tracking(2).foregroundColor(palette.muted2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
enum WrappedCardRenderer {
    /// Pixels per point in the exported image. Snapshotting a view only ever
    /// captures at the backing scale of the screen it's on (1× on a non-Retina
    /// display), which made exports look soft — `ImageRenderer` lets us ask for
    /// a real 3× render regardless of the display.
    static let scale: CGFloat = 3

    /// Render the card offscreen at `scale`, as raw pixels.
    static func render(_ card: WrappedCard) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        // Keep the point size so the PNG reports a sensible physical size while
        // carrying the full pixel detail.
        rep.size = WrappedCard.size
        return rep
    }

    /// Ask where to save, write a PNG, and return a short status line.
    static func save(_ rep: NSBitmapImageRep, scope: String) -> String {
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return "Couldn't encode the image."
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Tempo Wrapped \(scope).png"
        panel.canCreateDirectories = true
        panel.title = "Save your Wrapped"
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        do {
            try png.write(to: url)
            return "Saved \(rep.pixelsWide)×\(rep.pixelsHigh) to \(url.lastPathComponent)"
        } catch { return "Save failed: \(error.localizedDescription)" }
    }
}
