import Foundation
import iTunesLibrary
import AppKit
import ImageIO
import Network

/// Reads the real Music library via Apple's iTunesLibrary framework and exposes
/// it to the UI. No demo data, no developer token — these are your own play
/// counts and durations as tracked by the Music app.
@MainActor
final class LibraryStore: ObservableObject {
    /// Tracks read fresh from the Music app each launch (Apple Music / local).
    @Published var libraryTracks: [Track] = [] { didSet { dataVersion &+= 1 } }
    /// Exact per-play history from Spotify imports and Last.fm — PERSISTED to
    /// disk so you import/sync once and it survives restarts.
    @Published var importedTracks: [Track] = [] { didSet { dataVersion &+= 1 } }

    /// Bumped whenever the underlying tracks change. Aggregation results are
    /// cached against it, because SwiftUI re-evaluates `body` constantly (hover,
    /// timers, keystrokes) and re-bucketing thousands of tracks each time is
    /// what makes a list feel sticky.
    private var dataVersion: UInt64 = 0
    private var bucketCache: [String: [Bucket]] = [:]
    private var spanCache: (version: UInt64, spans: [String: ArtistSpan])? = nil
    private var wrappedCache: [String: WrappedData] = [:]

    /// Wrapped's full stat set, memoised — it's built inside a SwiftUI `body`,
    /// so without this every hover and animation frame would recompute several
    /// passes over the whole library.
    func wrapped(scope: WrappedScope, splitCollabs: Bool) -> WrappedData {
        let key = "\(dataVersion)|\(scope.id)|\(splitCollabs)|\(skips.count)"
        if let hit = wrappedCache[key] { return hit }
        let result = WrappedData.compute(self, splitCollabs: splitCollabs, scope: scope)
        if wrappedCache.count > 8 { wrappedCache.removeAll() }
        wrappedCache[key] = result
        return result
    }
    @Published var status: Status = .loading
    /// One downscaled cover per album, keyed by `Track.albumKey`.
    @Published var artwork: [String: NSImage] = [:] { didSet { artVersion &+= 1 } }
    /// The same covers as cached PNG bytes, so a rescan can skip re-decoding
    /// artwork out of the Music library (the slowest part of a scan by far).
    private var artworkData: [String: Data] = [:]
    /// Resolved artist profile-picture URLs, keyed by lowercased artist name.
    @Published var artistURLs: [String: String] = [:]
    /// Genre tags per artist (from Last.fm), keyed by lowercased artist name.
    /// Empty array = looked up, nothing usable came back.
    @Published var artistGenres: [String: [String]] = [:]
    /// When the last successful source sync finished — shown in the UI.
    @Published var lastSynced: Date? = nil
    @Published var lastfmStatus: String? = nil
    @Published var spotifyStatus: String? = nil
    /// Last sync attempt for this source errored — surfaced in the UI so a bad
    /// API key or expired token doesn't fail silently.
    @Published var lastfmFailed = false
    @Published var spotifyFailed = false
    var syncFailed: Bool { lastfmFailed || spotifyFailed }

    private var artistResolved = Set<String>()   // names already looked up (hit or miss)

    /// Everything the UI works on. Concatenating copies every element, so with a
    /// large imported history this is expensive enough that it must not be done
    /// inside a SwiftUI `body` — use `trackCount`/`hasTracks` to ask about size,
    /// and `forEachTrack` to walk them without building the joined array.
    var tracks: [Track] { libraryTracks + importedTracks }

    var trackCount: Int { libraryTracks.count + importedTracks.count }

    /// Every cached aggregate keys off `dataVersion`, so a setting that changes
    /// what the numbers mean — rather than what the data is — has to bump it too.
    func invalidateDerived() { dataVersion &+= 1 }

    /// How many stored plays fall under the current "too short to count"
    /// threshold. Shown in Settings so the switch says what it will actually do.
    private var shortPlayCache: (version: UInt64, seconds: Int, count: Int)? = nil
    var shortPlayCount: Int {
        let secs = PlayCounting.seconds
        if let c = shortPlayCache, c.version == dataVersion, c.seconds == secs { return c.count }
        let floor = secs * 1000
        var n = 0
        for t in importedTracks where t.lengthMs > 0 && t.lengthMs < floor { n += t.plays }
        shortPlayCache = (dataVersion, secs, n)
        return n
    }

    /// Dated plays we hold at all — the denominator for the figure above.
    var datedPlayCount: Int { importedTracks.reduce(0) { $0 + $1.plays } }
    var hasTracks: Bool { !libraryTracks.isEmpty || !importedTracks.isEmpty }

    /// Played tracks with no per-play timestamp — the count the "hidden in this
    /// range" note reports. Cached because that note is drawn on every pass and
    /// used to filter the whole library each time.
    private var approxCountCache: (version: UInt64, count: Int)? = nil
    var approximateTrackCount: Int {
        if let c = approxCountCache, c.version == dataVersion { return c.count }
        var n = 0
        forEachTrack { if !$0.isExact && $0.plays > 0 { n += 1 } }
        approxCountCache = (dataVersion, n)
        return n
    }

    /// Walks both halves in place. Saves materialising ~80,000 `Track` values
    /// (each with several strings) just to iterate them once.
    func forEachTrack(_ body: (Track) -> Void) {
        for t in libraryTracks { body(t) }
        for t in importedTracks { body(t) }
    }

    /// Individual plays we know the exact time of (live scrobbles, plus Last.fm
    /// and Spotify history) — newest first. Powers the History view.
    /// Cached against `dataVersion`. This filters and *sorts* the whole history,
    /// and it's read from inside several `body` getters — Wrapped's scope picker
    /// alone asked for it on every pass. Re-sorting 75,000 plays for each redraw
    /// is most of what made a large library feel slow.
    private var recentPlaysCache: (version: UInt64, plays: [Track])? = nil

    var recentPlays: [Track] {
        if let c = recentPlaysCache, c.version == dataVersion { return c.plays }
        let plays = importedTracks
            .filter { $0.isExact && $0.lastPlayed != nil }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }
        recentPlaysCache = (dataVersion, plays)
        return plays
    }

    /// The plays History lists: ones we actually watched happen. An inferred
    /// play is a count with a date attached, not a moment we witnessed — it
    /// belongs in the totals it was built for, not in a reverse-chronological
    /// log next to real scrobbles, where a night's phone sync would bury the
    /// listening you actually did at this machine.
    /// Years with at least one dated play, newest first — the Wrapped scope
    /// picker's options. Cached because working it out means a calendar
    /// conversion per play, and the picker is rebuilt on every redraw.
    private var playYearsCache: (version: UInt64, years: [Int])? = nil

    var playYears: [Int] {
        if let c = playYearsCache, c.version == dataVersion { return c.years }
        let cal = Calendar.current
        var set = Set<Int>()
        for t in recentPlays {
            if let d = t.lastPlayed { set.insert(cal.component(.year, from: d)) }
        }
        let years = set.sorted(by: >)
        playYearsCache = (dataVersion, years)
        return years
    }

    private var witnessedPlaysCache: (version: UInt64, plays: [Track])? = nil

    var witnessedPlays: [Track] {
        if let c = witnessedPlaysCache, c.version == dataVersion { return c.plays }
        let plays = recentPlays.filter { !$0.inferred }
        witnessedPlaysCache = (dataVersion, plays)
        return plays
    }

    var spotifyPlays: Int { importedTracks.lazy.filter { $0.source == .spotify }.count }
    var lastfmPlays: Int { importedTracks.lazy.filter { $0.source == .lastfm }.count }

    /// Sources actually present in the data (for the filter chips), collapsed
    /// to their display identity so Last.fm folds into a single Spotify chip.
    var sources: [Source] {
        let present = Set(tracks.map { $0.source.display })
        return Source.allCases.filter { present.contains($0) }
    }

    // MARK: - Bootstrap (called once on launch)

    private var booted = false
    func bootstrap() {
        guard !booted else { return }              // window may reopen; only set up once
        booted = true
        importedTracks = Persistence.load()        // restore saved history immediately
        artistURLs = Persistence.loadArtistURLs()  // restore resolved artist photos
        artistImageData = Persistence.loadArtistArt()
        artistImages = artistImageData.compactMapValues { NSImage(data: $0) }
        artistGenres = Persistence.loadGenres()    // restore cached genre tags
        fetchedDurations = Persistence.loadDurations()  // ...and track lengths looked up before
        skips = Persistence.loadSkips()
        artistResolved = Set(artistURLs.keys)

        // Warm start: paint last launch's library snapshot immediately, then
        // rescan in the background and swap in anything that changed. Scanning
        // the Music library takes a couple of seconds, and staring at an empty
        // window while it runs is the whole of the "slow launch" feeling.
        let cachedLibrary = Persistence.loadLibrary()
        if !cachedLibrary.isEmpty {
            libraryTracks = cachedLibrary
            artworkData = Persistence.loadArtwork()
            artwork = artworkData.compactMapValues { NSImage(data: $0) }
            status = .loaded(count: cachedLibrary.count)
        }
        load()                                     // refresh from the Music library
        syncNow()                                  // refresh connected live sources once
        startConnectivityWatch()                   // retry on network/wake
        startLibraryRescanTimer()                  // and keep noticing synced play counts
        // Start listening straight away, but don't RECORD until we know whether
        // the agent is doing it — asking costs a subprocess, and asking on the
        // main thread is what made launch feel hung. Deferring is the safe way
        // round: two recorders would double-count, one recorder starting a
        // moment late loses nothing, because the agent is already recording in
        // exactly the case where we're waiting to find out.
        Scrobbler.shared.start(store: self, recording: false)
        Task { await resolveRecordingOwnership() }
        NotificationCenter.default.addObserver(
            forName: BackgroundAgent.ownershipChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // launchd needs a moment to spawn (or reap) the helper, so settle
            // before asking whether it's running.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await self?.resolveRecordingOwnership()
            }
        }
    }

    private var observingAgent = false

    /// Work out who is recording live plays right now, and set the app up to
    /// match. If the background agent is running it is the single writer of
    /// scrobbles AND the periodic source-syncer — the app then only *listens*
    /// (for now-playing display) and reloads history from disk when it changes,
    /// so plays are never counted twice and writes don't race.
    ///
    /// Re-checked whenever the setting is toggled, not just at launch. It used
    /// to be decided once: turning the agent off mid-session left the app still
    /// deferring to a helper that no longer existed, so nothing recorded a
    /// single play until Tempo was relaunched — and turning it on had both
    /// processes recording the same plays.
    /// Asks off the main thread, then applies the answer on it.
    func resolveRecordingOwnership() async {
        let agentOwns = await BackgroundAgent.isRunningAsync()
        applyRecordingOwnership(agentOwns: agentOwns)
    }

    func applyRecordingOwnership(agentOwns: Bool) {
        Scrobbler.shared.setRecording(!agentOwns)
        if agentOwns {
            refreshTimer?.invalidate(); refreshTimer = nil   // the agent syncs instead
            if !observingAgent { observeAgentScrobbles(); observingAgent = true }
        } else {
            applyAutoRefresh()                               // we own the periodic sync
        }
    }

    /// Headless (`--agent`) startup: no Music library read — but DOES keep the
    /// connected sources (Last.fm / Spotify) synced, so the menu bar's "today"
    /// total stays current even while the app is closed and even for plays that
    /// only reach us through Last.fm (e.g. Spotify on your phone).
    func startScrobbleOnly() {
        guard !booted else { return }
        booted = true
        isAgentWriter = true
        importedTracks = Persistence.load()
        skips = Persistence.loadSkips()
        Scrobbler.shared.start(store: self, recording: true)
        syncNow()                    // pull now so the menu bar is current at once
        startAgentSyncTimer()        // and keep pulling in the background
        startConnectivityWatch()     // ...and the moment the network shows up
    }

    /// True while the displays are asleep (agent process only): nobody can see
    /// the menu-bar total then, so the periodic sync below pauses until wake.
    private var displayAsleep = false
    private var observingScreens = false

    /// One-time (agent path): pause the 300s sync timer while the display
    /// sleeps — those wakeups burn battery refreshing a total nobody is
    /// looking at. On wake the timer restarts; the sync itself is already
    /// covered by the didWake handler in startConnectivityWatch, so nothing is
    /// missed. (If the agent is spawned while the display is already asleep we
    /// can't know — screen sleep is transition-only — so it ticks until the
    /// next wake; vanishingly rare next to the nightly pause this buys.)
    private func observeScreensIfNeeded() {
        guard !observingScreens else { return }
        observingScreens = true
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.displayAsleep = true
                self.refreshTimer?.invalidate(); self.refreshTimer = nil
            }
        }
        wc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.displayAsleep = false
                self.startAgentSyncTimer()
            }
        }
    }

    /// Periodic source sync run by the background agent, independent of the app's
    /// "sync.interval" setting, purely to keep the menu-bar total live. Paused
    /// while the display sleeps.
    private func startAgentSyncTimer() {
        observeScreensIfNeeded()
        guard !displayAsleep else { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }

    /// True in the background-agent process. Marks the work that belongs to the
    /// app alone — Last.fm duration lookups, which shouldn't be run twice.
    /// (Merging onto the latest file on disk is no longer conditional on this:
    /// both processes do it, because both clobber the other otherwise.)
    private var isAgentWriter = false

    /// Pick up scrobbles the agent wrote while the app was in the background —
    /// both when the window comes forward AND live, the moment the agent records
    /// one (so Tempo's own scrobbles show up in History right away).
    private func observeAgentScrobbles() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.importedTracks = Persistence.load()
                self?.rescanLibraryIfStale()   // catch play counts synced since
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.tempo.historyChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.importedTracks = Persistence.load() }
        }
    }

    // MARK: - Live scrobbles

    // MARK: - Skips

    /// Tracks the live scrobbler saw you abandon before the scrobble threshold,
    /// keyed "title::artist". Forward-looking only — there's no way to recover
    /// skips that happened before Tempo started watching.
    @Published var skips: [String: Int] = [:]

    func recordSkip(title: String, artist: String) {
        // Same single-writer discipline as history: re-read first, in either
        // process, so this merges onto whatever the other one last wrote.
        var current = Persistence.loadSkips()
        current["\(title)::\(artist)", default: 0] += 1
        skips = current
        Persistence.saveSkips(current)
    }

    var totalSkips: Int { skips.values.reduce(0, +) }

    /// Delete a single recorded play — for when a scrobble is plain wrong
    /// (mis-tagged track, something a guest played). Identity is the track's
    /// UUID, so only that one entry goes.
    func deletePlay(_ track: Track) {
        // Re-read first, like every other whole-file write: deleting one play
        // from a copy loaded before the agent's last scrobble would take that
        // scrobble with it.
        var current = Persistence.loadIfChangedExternally() ?? importedTracks
        current.removeAll { $0.id == track.id }
        importedTracks = current
        Persistence.save(current)
    }

    /// Every timestamped play as CSV — your data, in a form anything can read.
    func historyCSV() -> String {
        let f = ISO8601DateFormatter()
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        // Estimated plays stay in the export — they're real listening — but with
        // a column saying so, since their time is worked out from a play-count
        // rise rather than watched.
        var out = "played_at,title,artist,album,source,length_ms,plays,estimated\n"
        for t in recentPlays {
            let when = t.lastPlayed.map { f.string(from: $0) } ?? ""
            out += "\(when),\(esc(t.title)),\(esc(t.artist)),\(esc(t.album)),\(t.source.rawValue),\(t.lengthMs),\(t.plays),\(t.inferred)\n"
        }
        return out
    }

    /// Merge a backup file's plays back in, de-duped like any other import.
    /// Returns how many were actually new.
    @discardableResult
    func restoreHistory(_ tracks: [Track]) -> Int {
        let before = importedTracks.count
        for source in Set(tracks.map(\.source)) {
            mergeImported(tracks.filter { $0.source == source }, source: source, replace: false)
        }
        return importedTracks.count - before
    }

    /// Record one play captured live by the scrobbler (persisted like imports).
    /// For an Apple Music track already in the local library, the library
    /// snapshot's lifetime count won't subtract this one until the next
    /// `load()` (launch or manual refresh) — a same-session, self-correcting
    /// off-by-one, not a persistent double-count.
    func recordScrobble(_ t: Track) {
        mergeImported([t], source: t.source, replace: false)
        announceMilestones(for: t)
    }

    /// Round-number moments worth surfacing — the 100th/500th/1000th play of an
    /// artist, and your first anniversary with Tempo. Fired at most once each
    /// (we only notify on the exact crossing).
    private func announceMilestones(for t: Track) {
        guard Notify.milestonesEnabled else { return }
        let key = Self.artistKey(t.artist)
        let plays = importedTracks.reduce(0) { sum, x in
            sum + (Self.artistKey(x.artist) == key ? x.countedPlays : 0)
        }
        for mark in [100, 500, 1000, 2500, 5000] where plays == mark {
            Notify.milestone("\(TimeFmt.commas(mark)) plays with \(t.artist)",
                             "That's a milestone worth noticing.")
        }
    }

    /// The "listening day" a moment belongs to, honouring the configurable day
    /// boundary ("day.startHour", 0–6). With a 4am boundary, music played at 2am
    /// still counts toward the previous day — which is how night listening
    /// actually feels.
    nonisolated static func listeningDay(_ d: Date) -> Date {
        let cal = Calendar.current
        let h = UserDefaults.standard.integer(forKey: "day.startHour")
        guard h > 0 else { return cal.startOfDay(for: d) }
        return cal.startOfDay(for: cal.date(byAdding: .hour, value: -h, to: d) ?? d)
    }

    /// Exact-history listening that happened today (live scrobbles + synced plays).
    var todayMs: Int {
        let today = Self.listeningDay(Date())
        return importedTracks
            .filter { $0.lastPlayed.map { Self.listeningDay($0) == today } == true }
            .reduce(0) { $0 + $1.totalMs }
    }

    /// First/last time we saw each artist, over ALL timestamped history — the
    /// basis for "discovered this year" and "gathering dust". Keyed by the
    /// normalised alias key; `name` keeps the most-played spelling.
    struct ArtistSpan {
        var name: String
        var first: Date
        var last: Date
        var plays: Int = 0
        var ms: Int = 0
    }

    func artistSpans() -> [String: ArtistSpan] {
        if let c = spanCache, c.version == dataVersion { return c.spans }
        let spans = computeArtistSpans()
        spanCache = (dataVersion, spans)
        return spans
    }

    private func computeArtistSpans() -> [String: ArtistSpan] {
        var out: [String: ArtistSpan] = [:]
        var votes: [String: [String: Int]] = [:]
        for t in importedTracks {
            guard t.isExact, let d = t.lastPlayed else { continue }
            for name in ArtistSplitter.split(t.artist) {
                let key = Self.artistKey(name)
                guard !key.isEmpty else { continue }
                votes[key, default: [:]][name, default: 0] += t.countedPlays
                if var s = out[key] {
                    s.first = min(s.first, d); s.last = max(s.last, d)
                    s.plays += t.countedPlays; s.ms += t.totalMs
                    out[key] = s
                } else {
                    out[key] = ArtistSpan(name: name, first: d, last: d, plays: t.countedPlays, ms: t.totalMs)
                }
            }
        }
        for (key, v) in votes {
            if let best = v.max(by: { $0.value < $1.value })?.key { out[key]?.name = best }
        }
        return out
    }

    // MARK: - Genres (Last.fm tags)

    private var genreResolving = false

    /// Look up genre tags for the busiest artists we don't have yet. Cheap and
    /// idempotent: cached to disk, throttled, and capped per call so we never
    /// hammer Last.fm. Called by the Wrapped view when it appears.
    func resolveGenres(limit: Int = 60) {
        let d = UserDefaults.standard
        let key = (d.string(forKey: "lastfm.key") ?? "").trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !genreResolving else { return }

        let top = buckets(groupBy: .artist, sortBy: .time, range: .allTime, source: nil, search: "")
        let missing = top.map(\.label)
            .filter { artistGenres[$0.lowercased()] == nil }
            .prefix(limit)
        guard !missing.isEmpty else { return }

        genreResolving = true
        Task { [weak self] in
            for name in missing {
                let tags = await LastFM.topTags(artist: name, apiKey: key)
                guard let self else { return }
                self.artistGenres[name.lowercased()] = tags
                try? await Task.sleep(nanoseconds: 250_000_000)   // ~4 req/sec
            }
            guard let self else { return }
            Persistence.saveGenres(self.artistGenres)
            self.genreResolving = false
        }
    }

    /// Returns a cached artist photo URL, kicking off a one-time Deezer lookup
    /// the first time an artist is seen. Safe to call from a view body.
    func artistURL(for name: String) -> String? {
        let key = name.lowercased()
        if let u = artistURLs[key] { return u }
        if artistResolved.contains(key) { return nil }
        artistResolved.insert(key)                 // not @Published — no view-update churn
        Task { [weak self] in
            if let url = await ArtistArt.imageURL(for: name) {
                self?.artistURLs[key] = url
                Persistence.saveArtistURLs(self?.artistURLs ?? [:])
            }
        }
        return nil
    }

    /// Artist photos ready to draw: 160-pixel thumbnails, keyed by lowercased
    /// artist name, so a row renders one straight from memory.
    @Published private(set) var artistImages: [String: NSImage] = [:]
    private var artistImageData: [String: Data] = [:]
    private var artistImageLoading = Set<String>()

    /// The photo for an artist row, or nil to fall back to the letter tile.
    ///
    /// Safe to call from a view body, and cheap on every call after the first:
    /// a dictionary lookup. Rows used to hand the raw URL to `AsyncImage`, which
    /// re-requested and re-decoded Deezer's 1000×1000 original every time a row
    /// scrolled back into view — to fill a 40-point circle. That was the whole
    /// of the scrolling stutter.
    func artistImage(for name: String) -> NSImage? {
        let key = name.lowercased()
        if let img = artistImages[key] { return img }
        guard let urlStr = artistURL(for: name), let url = URL(string: urlStr) else { return nil }
        guard !artistImageLoading.contains(key) else { return nil }
        artistImageLoading.insert(key)          // not @Published — no redraw churn
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let jpeg = Self.thumbnailData(data, maxPixel: 160),
                  let img = NSImage(data: jpeg) else { return }
            self?.stageArtistImage(key: key, image: img, data: jpeg)
        }
        return nil
    }

    private var pendingArtistImages: [String: (NSImage, Data)] = [:]
    private var artistImageFlush: Timer?

    /// Photos arrive one request at a time, and every one of them publishing on
    /// its own re-renders every visible row — scrolling a list of a few hundred
    /// artists for the first time would otherwise fight several hundred separate
    /// view invalidations. Collect them and publish in batches instead.
    private func stageArtistImage(key: String, image: NSImage, data: Data) {
        pendingArtistImages[key] = (image, data)
        guard artistImageFlush == nil else { return }
        artistImageFlush = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushArtistImages() }
        }
    }

    private func flushArtistImages() {
        artistImageFlush = nil
        guard !pendingArtistImages.isEmpty else { return }
        var images = artistImages
        for (k, v) in pendingArtistImages {
            images[k] = v.0
            artistImageData[k] = v.1
        }
        pendingArtistImages.removeAll()
        artistImages = images                  // one publish for the whole batch
        Persistence.saveArtistArt(artistImageData)
    }

    /// Re-sync every configured live source (Last.fm and/or Spotify OAuth).
    func syncNow() {
        let d = UserDefaults.standard
        let user = d.string(forKey: "lastfm.user") ?? ""
        let key = d.string(forKey: "lastfm.key") ?? ""
        if !user.isEmpty && !key.isEmpty { syncLastFM(user: user, apiKey: key) }
        if SpotifyAuth.shared.connected { syncSpotify() }   // auto-refresh recent plays
        // NB: `lastSynced` is set when a source actually succeeds, not here —
        // otherwise a failed sync would still claim "synced just now".
    }

    // MARK: - Staying current across boots, sleeps and dropouts

    private var netMonitor: NWPathMonitor?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 15

    /// Sync as soon as the machine is genuinely able to. At login — especially
    /// after a cold boot — launchd starts us before Wi-Fi is up, so the first
    /// sync fails and (previously) nothing tried again for five minutes, leaving
    /// the menu bar showing no listening time for today. Now we retry on
    /// failure, sync the moment the network appears, and sync on wake.
    func startConnectivityWatch() {
        guard netMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.syncIfStale() }
        }
        monitor.start(queue: DispatchQueue(label: "com.tempo.network"))
        netMonitor = monitor

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncIfStale()
                // Waking is when a night's listening is most likely to be
                // sitting in the Music library unread — a phone plugged in
                // overnight syncs its play counts across while the Mac sleeps.
                self?.rescanLibraryIfStale()
            }
        }
    }

    /// Re-read the Music library on the app's own schedule, so play counts that
    /// arrive after launch — a phone sync, or Music flushing its counter — get
    /// picked up without quitting and reopening. Scanning only ever happened at
    /// launch before, so leaving Tempo open for days meant it never noticed.
    private func startLibraryRescanTimer() {
        libraryTimer?.invalidate()
        libraryTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanLibraryIfStale() }
        }
    }

    /// Rescan unless one just ran. Wake and became-active fire together, and a
    /// scan reads every item's artwork — worth doing on a timer, not in bursts.
    func rescanLibraryIfStale(minInterval: TimeInterval = 300) {
        // App only. Two processes scanning would both read the same play-count
        // snapshot, both see the same rise, and both turn it into plays.
        guard !isAgentWriter else { return }
        if let last = lastLibraryScan, Date().timeIntervalSince(last) < minInterval { return }
        load()
    }

    /// Sync unless we just did — so a flurry of network/wake events doesn't
    /// trigger a burst of requests.
    func syncIfStale(minInterval: TimeInterval = 45) {
        if let last = lastSynced, Date().timeIntervalSince(last) < minInterval { return }
        syncNow()
    }

    /// Called when a source fails. Backs off 15s → 30s → … up to 5 minutes.
    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.syncNow() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 300)
    }

    /// A source succeeded — stamp the time and reset the backoff.
    private func syncSucceeded() {
        lastSynced = Date()
        retryDelay = 15
        retryWork?.cancel(); retryWork = nil
    }

    // MARK: - Auto refresh

    private var refreshTimer: Timer?

    /// (Re)start the background auto-sync timer from the saved interval
    /// ("sync.interval" seconds; 0 = off). Call after changing the setting.
    func applyAutoRefresh() {
        refreshTimer?.invalidate(); refreshTimer = nil
        let secs = UserDefaults.standard.integer(forKey: "sync.interval")
        guard secs > 0 else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }

    /// Pull recent plays straight from a connected Spotify account and merge
    /// them in (exact timestamps + album art). Accumulates over time, so leaving
    /// it connected builds full forward history with no exports.
    func syncSpotify() {
        spotifyStatus = "Syncing…"
        Task {
            guard let token = await SpotifyAuth.shared.validToken() else {
                spotifyStatus = "Connect Spotify first."; spotifyFailed = true; return
            }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]

            var collected: [Track] = []
            // Ask only for plays after the newest one we already hold. Spotify
            // caps recently-played at the last 50 anyway, so re-walking five
            // pages every sync just re-fetched the same rows.
            let newest = self.importedTracks.lazy.filter { $0.source == .spotify }
                .compactMap { $0.lastPlayed }.max()
            var first = "https://api.spotify.com/v1/me/player/recently-played?limit=50"
            if let n = newest {
                first += "&after=\(Int(n.timeIntervalSince1970 * 1000))"
            }
            var next: URL? = URL(string: first)
            var pages = 0
            while let u = next, pages < 5 {
                var req = URLRequest(url: u)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                let items = (j["items"] as? [[String: Any]]) ?? []
                if items.isEmpty { break }
                for it in items {
                    guard let t = it["track"] as? [String: Any],
                          let name = t["name"] as? String,
                          let playedAt = it["played_at"] as? String else { continue }
                    let artist = ((t["artists"] as? [[String: Any]]) ?? [])
                        .compactMap { $0["name"] as? String }.joined(separator: ", ")
                    let album = t["album"] as? [String: Any]
                    let albumName = album?["name"] as? String ?? ""
                    let artURL = (album?["images"] as? [[String: Any]])?.first?["url"] as? String
                    let ms = (t["duration_ms"] as? Int) ?? 0
                    let date = iso.date(from: playedAt) ?? isoPlain.date(from: playedAt)
                    collected.append(Track(
                        title: name, artist: artist, album: albumName,
                        albumKey: "\(albumName)::\(artist)", source: .spotify,
                        lengthMs: ms, plays: 1, lastPlayed: date, artURL: artURL,
                        year: (album?["release_date"] as? String)
                            .flatMap { Int($0.prefix(4)) }))
                }
                if let cursors = j["cursors"] as? [String: Any], let before = cursors["before"] as? String {
                    next = URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50&before=\(before)")
                } else { next = nil }
                pages += 1
            }
            let new = collected
            mergeImported(new, source: .spotify, replace: false)   // accumulate + de-dupe
            spotifyStatus = "\(TimeFmt.commas(spotifyPlays)) plays"
            spotifyFailed = false
            syncSucceeded()
            fetchRemoteArt(for: new)
        }
    }

    // MARK: - Imports

    /// Import one or more Spotify export JSON files as exact per-play history.
    /// De-duplicates against existing history so re-importing is harmless.
    func importSpotify(urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            var added: [Track] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                added.append(contentsOf: HistoryImporter.parseSpotify(data))
            }
            let new = added
            await MainActor.run {
                self.mergeImported(new, source: .spotify, replace: false)
            }
        }
    }

    /// How close two records of the same song have to be to be one play seen
    /// twice (our live scrobbler plus a Last.fm sync of the same Spotify play)
    /// rather than the song played again.
    ///
    /// Measured against Last.fm's own timestamps rather than guessed: both mark
    /// when a track STARTED, and they agree to within a second — median 0.7s,
    /// 4s at the 95th percentile. The flat four minutes this used to allow was
    /// sixty times wider than any real disagreement, and it quietly ate repeat
    /// listening: a 108-second song on repeat scrobbles every 109 seconds, so
    /// two of every three plays were discarded as duplicates of the first.
    ///
    /// Never wider than half a track, so a song can always be played twice in
    /// a row no matter how short it is.
    nonisolated static func duplicateWindow(_ t: Track) -> TimeInterval {
        let seconds = Double(t.lengthMs) / 1000
        guard seconds > 0 else { return 60 }        // unknown length: the plain window
        return min(60, max(10, seconds / 2))
    }

    /// Merge exact-history tracks in, de-duping by play signature, then persist.
    /// Also suppresses cross-source near-duplicates — see `duplicateWindow`.
    private func mergeImported(_ incoming: [Track], source: Source, replace: Bool) {
        // Always merge onto what's on disk, in both processes. The app and the
        // agent write the same file, and this saves the whole history rather
        // than a delta — so merging onto an in-memory copy taken before the
        // other process's write silently reverts it. The agent records live
        // plays while the app is open, which is exactly when the app holds a
        // stale copy, so those are the plays that go missing.
        //
        // Only actually re-read when the other process has written since we
        // last did. Decoding the file unconditionally is fine at a thousand
        // plays and not at seventy-five thousand, where it would stall the main
        // thread every time a track changed.
        // Nothing offered and nothing to replace — the usual outcome of a sync
        // that found no new plays. Indexing and rewriting the whole history to
        // add nothing is pure cost, and at this size it's seconds of it.
        guard !incoming.isEmpty || replace else { return }

        let reread = Persistence.loadIfChangedExternally()
        let base = reread ?? importedTracks
        var kept = replace ? base.filter { $0.source != source } : base
        var seen = Set(kept.map { Self.sig($0) })
        var timeIndex: [String: [TimeInterval]] = [:]
        for t in kept {
            if let d = t.lastPlayed {
                timeIndex[Self.dedupKey(t), default: []].append(d.timeIntervalSince1970)
            }
        }
        let before = kept.count
        for t in incoming {
            guard seen.insert(Self.sig(t)).inserted else { continue }
            if let d = t.lastPlayed {
                let k = Self.dedupKey(t)
                let ts = d.timeIntervalSince1970
                let window = Self.duplicateWindow(t)
                if timeIndex[k]?.contains(where: { abs($0 - ts) < window }) == true { continue }
                timeIndex[k, default: []].append(ts)
            }
            kept.append(t)
        }
        // Everything offered was already known: leave the file alone. Writing an
        // identical 20MB back costs as much as a real merge and invalidates
        // every cached view for nothing.
        guard kept.count != before || replace else {
            // Still adopt the other process's writes if that's why we re-read.
            if reread != nil { importedTracks = kept }
            return
        }
        importedTracks = kept
        Persistence.save(kept)
        // Notify other Tempo processes (agent ↔ app) that history changed, so the
        // menu bar total and the History view refresh — covers live scrobbles AND
        // source syncs. Reaching here already means something changed.
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.tempo.historyChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Re-runs the duration match over scrobbles already stored. A scrobble
    /// keeps whatever length it was given at import, so one that arrived before
    /// the library had been scanned — or before the matching was any good — sits
    /// on the flat estimate for good, and every "time listened" total it feeds
    /// stays wrong. Run whenever the set of known durations grows.
    ///
    /// Only entries still on the estimate are touched; a real length is never
    /// overwritten, and nothing is written to disk unless something changed.
    @discardableResult
    func backfillScrobbleDurations() -> Int {
        var known: [String: Int] = [:]
        forEachTrack { t in
            guard t.lengthMs > 0, t.source != .lastfm else { return }
            let k = Self.songMatchKey(title: t.title, artist: t.artist)
            known[k] = max(known[k] ?? 0, t.lengthMs)
        }
        guard !known.isEmpty || !fetchedDurations.isEmpty else { return 0 }
        // Same care as mergeImported, and for the same reason: this rewrites the
        // whole history, so it has to start from what's on disk in either
        // process or it reverts the other one's last write — and for the same
        // reason it only re-reads when someone else actually wrote.
        let base = Persistence.loadIfChangedExternally() ?? importedTracks
        var fixed = 0
        let updated = base.map { t -> Track in
            guard t.source == .lastfm, t.lengthMs == LastFM.estimatedMs else { return t }
            let k = Self.songMatchKey(title: t.title, artist: t.artist)
            // A local source is preferred over Last.fm's own figure: it's the
            // recording you actually played. A cached 0 means Last.fm was asked
            // and had nothing, so it must not be read as a length.
            guard let ms = known[k] ?? fetchedDurations[k].flatMap({ $0 > 0 ? $0 : nil }),
                  ms > 0, ms != t.lengthMs else { return t }
            fixed += 1
            return t.withLength(ms)
        }
        guard fixed > 0 else { return 0 }
        importedTracks = updated
        Persistence.save(updated)
        return fixed
    }

    /// Lengths Last.fm gave us for songs no local source knows. Keyed by
    /// `songMatchKey`; a `0` records a track Last.fm has no duration for.
    private var fetchedDurations: [String: Int] = [:]
    private var durationResolving = false

    /// Ask Last.fm directly for the lengths of scrobbles nothing local can date.
    ///
    /// One request per unique *song*, not per play — 563 plays here are only 197
    /// songs — and every answer is cached to disk, misses included, so a song is
    /// only ever asked about once however many times it's been played. Throttled
    /// to roughly four requests a second and capped per call, so this can never
    /// turn into a flood. Runs only in the app: the agent syncs too, and both
    /// writing the same cache would just clobber each other.
    func resolveScrobbleDurations(limit: Int = 250) {
        let key = (UserDefaults.standard.string(forKey: "lastfm.key") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !durationResolving, !isAgentWriter else { return }

        var wanted: [String: (title: String, artist: String)] = [:]
        for t in importedTracks where t.source == .lastfm && t.lengthMs == LastFM.estimatedMs {
            let k = Self.songMatchKey(title: t.title, artist: t.artist)
            guard fetchedDurations[k] == nil, wanted[k] == nil else { continue }
            wanted[k] = (t.title, t.artist)
        }
        guard !wanted.isEmpty else { return }
        let batch = Array(wanted.prefix(limit))

        durationResolving = true
        Task { [weak self] in
            for (k, song) in batch {
                let ms = await LastFM.trackDuration(title: song.title, artist: song.artist, apiKey: key)
                guard let self else { return }
                // nil is a failed request, not an answer — leave it uncached so
                // the next run tries again.
                if let ms { self.fetchedDurations[k] = ms }
                try? await Task.sleep(nanoseconds: 250_000_000)   // ~4 req/sec
            }
            guard let self else { return }
            Persistence.saveDurations(self.fetchedDurations)
            self.backfillScrobbleDurations()
            self.durationResolving = false
        }
    }

    /// Both sources the Music app's own library lands under: streamed tracks
    /// are `.appleMusic`, files on disk are `.local`. Anything reconciling our
    /// history against Music's lifetime play counts has to count both, or the
    /// plays we already hold get counted a second time — an inferred play of a
    /// local file carries `.local`, so an Apple-Music-only filter walks past it
    /// on every later scan and the all-time total drifts up.
    nonisolated static func fromMusicApp(_ t: Track) -> Bool {
        t.source == .appleMusic || t.source == .local
    }

    /// Turns a rise in Apple Music's lifetime play counts into dated plays.
    ///
    /// The Music app keeps a running total per track and one "last played" date
    /// — never the individual plays. So a song on 5 plays at yesterday's scan and
    /// 8 at today's tells us three listens happened. That's not exact, but it's
    /// enough to place them in a week or a month, which is all the ranged views
    /// need; without it those plays only ever showed up under "All time".
    ///
    /// The count answers *how many*; only the last-played stamp answers *when*,
    /// and the two arrive at different times. A count can sit unflushed on disk
    /// for a day, or arrive in a batch when a phone syncs a week of listening at
    /// once — so the gap between two scans says nothing about when the listening
    /// happened, and everything the placement does hangs off the stamp instead.
    ///
    /// Care taken in three places:
    ///  * Plays the live scrobbler already caught are subtracted, or every Apple
    ///    Music listen would be counted twice.
    ///  * The first scan only records a baseline. A lifetime count with nothing
    ///    to compare it against says nothing about *when*.
    ///  * A track Music has never dated is left alone entirely: a count with no
    ///    stamp behind it is a number, not a listen we can place.
    nonisolated static func inferPlays(counts: [String: Int],
                                       meta: [String: (Track, Int)],
                                       previous: Persistence.PlayCounts?,
                                       alreadyLive: [String: Int],
                                       now: Date) -> [Track] {
        guard let previous, previous.taken < now else { return [] }
        var out: [Track] = []
        for (key, count) in counts {
            // A song absent from the last snapshot is one we've never seen
            // before: its whole count predates our first sighting of it.
            guard let before = previous.counts[key], count > before else { continue }
            let n = (count - before) - (alreadyLive[key] ?? 0)
            guard n > 0, let (template, _) = meta[key] else { continue }

            // The rise says HOW MANY plays we missed. Music's own last-played
            // stamp is the only thing that says WHEN — so trust the stamp, not
            // the moment we noticed, because counts arrive long after the
            // listening. Music flushes them to its database lazily, and a phone
            // that syncs overnight lands days of plays in a single scan. Dating
            // either to the scan would invent a session that never happened and
            // stack every track that synced onto the same instant.
            //
            // Anchoring here also cancels a play we already witnessed live but
            // whose count only reached disk later: it lands within seconds of
            // the record we hold, where `mergeImported`'s duplicate guard
            // absorbs it. Dated "now" it would have slipped past as a second
            // play of the same listen.
            guard let last = template.lastPlayed, last <= now else { continue }

            // Only the most recent of these plays has a real time; the rest
            // happened at some unknown point before it. Lay them back-to-back
            // behind it, spaced by the track's own length so a repeat reads as
            // a repeat — and always clear of the duplicate window, which would
            // otherwise merge them away and lose the count.
            let step = max(Double(template.lengthMs) / 1000, Self.duplicateWindow(template) + 1)
            for i in 0..<n {
                let at = last.addingTimeInterval(-step * Double(i))
                out.append(Track(title: template.title, artist: template.artist,
                                 album: template.album, albumKey: template.albumKey,
                                 source: template.source, lengthMs: template.lengthMs,
                                 plays: 1, lastPlayed: at, isExact: true,
                                 year: template.year, inferred: true))
            }
        }
        return out
    }

    /// Normalised identity for a title and artist: same song, however the source
    /// spelled it. Sources credit differently — Last.fm files a track under
    /// "Pritam" where Apple Music lists "Pritam, Arijit Singh, Antara Mitra" —
    /// so anything matching one record against another has to go through here
    /// rather than compare the raw strings.
    nonisolated static func songMatchKey(title: String, artist: String) -> String {
        "\(normalizedTitle(title))|\(primaryArtist(artist))"
    }

    /// Key for the "same play seen by two recorders" check, so a play both
    /// Spotify and Last.fm reported is one play rather than two.
    private static func dedupKey(_ t: Track) -> String {
        songMatchKey(title: t.title, artist: t.artist)
    }

    /// A struct rather than an interpolated string: a merge builds one of these
    /// for every play already stored, and allocating 75,000 strings to do it was
    /// a visible part of the cost. Hashing the fields directly allocates nothing.
    private struct PlaySig: Hashable {
        let source: Source, title: String, artist: String, at: TimeInterval
    }

    private static func sig(_ t: Track) -> PlaySig {
        PlaySig(source: t.source, title: t.title, artist: t.artist,
                at: t.lastPlayed?.timeIntervalSince1970 ?? -1)
    }

    /// Sync Last.fm scrobbles. Durations are matched against tracks already
    /// loaded (Apple/Spotify) and estimated otherwise.
    func syncLastFM(user: String, apiKey: String, fullResync: Bool = false) {
        // Duration lookup from tracks whose length we already know. Keyed on the
        // normalised song identity, not the raw "title::artist": Last.fm credits
        // only the lead artist, so an exact-string match missed almost every
        // track that Apple Music or Spotify credits in full, and the scrobble
        // fell back to the flat estimate despite its real length being right
        // there in the library.
        var build: [String: Int] = [:]
        forEachTrack { t in
            guard t.lengthMs > 0, t.source != .lastfm else { return }
            let k = Self.songMatchKey(title: t.title, artist: t.artist)
            build[k] = max(build[k] ?? 0, t.lengthMs)
        }
        let durs = build   // immutable copy for safe concurrent capture

        // Incremental by default: ask only for scrobbles newer than the last one
        // we already have (minus an hour of overlap, in case a scrobble landed
        // out of order). Re-pulling a lifetime of history every five minutes is
        // slow, wasteful, and a good way to get rate-limited.
        let newest = importedTracks.lazy.filter { $0.source == .lastfm }
            .compactMap { $0.lastPlayed }.max()
        let from = fullResync ? nil : newest?.addingTimeInterval(-3600)
        let replace = from == nil       // only a full pull may replace what's stored

        lastfmStatus = from == nil ? "Syncing all scrobbles…" : "Checking for new scrobbles…"
        Task {
            do {
                let new = try await LastFM.fetchRecent(
                    user: user, apiKey: apiKey, from: from,
                    durationFor: { title, artist in
                        durs[LibraryStore.songMatchKey(title: title, artist: artist)] ?? LastFM.estimatedMs
                    },
                    progress: { page, total in
                        guard total > 1 else { return }
                        Task { @MainActor in self.lastfmStatus = "Syncing… page \(page)/\(total)" }
                    }
                )
                await MainActor.run {
                    let before = self.importedTracks.count
                    self.mergeImported(new, source: .lastfm, replace: replace)
                    let added = self.importedTracks.count - before
                    self.lastfmStatus = replace
                        ? "\(TimeFmt.commas(new.count)) scrobbles synced"
                        : (added > 0 ? "\(TimeFmt.commas(added)) new scrobble\(added == 1 ? "" : "s")"
                                     : "Up to date")
                    self.lastfmFailed = false
                    // New scrobbles can be the first time a song is seen at all,
                    // and a Spotify play of it may already be waiting with a real
                    // length — so match again now the set has grown.
                    self.backfillScrobbleDurations()
                    self.resolveScrobbleDurations()
                    self.syncSucceeded()
                    self.fetchRemoteArt(for: new)
                }
            } catch {
                await MainActor.run {
                    self.lastfmStatus = error.localizedDescription
                    self.lastfmFailed = true
                    self.scheduleRetry()   // network probably isn't up yet
                }
            }
        }
    }

    enum Status: Equatable {
        case loading
        case loaded(count: Int)
        case denied
        case error(String)
    }

    private var scanning = false
    private var libraryTimer: Timer?
    private var lastLibraryScan: Date?

    func load() {
        // One scan at a time. Two overlapping scans both read the play-count
        // snapshot from before either finished, so both saw the same rise and
        // both turned it into plays — the same listening counted twice.
        guard !scanning else { return }
        scanning = true
        lastLibraryScan = Date()
        // Only show "loading" when there's nothing on screen yet — a background
        // refresh shouldn't blank out a warm-started list.
        if libraryTracks.isEmpty { status = .loading }
        // Snapshot how many plays we've already witnessed live (exact timestamp,
        // recorded by the Scrobbler) for each track, so the library's own lifetime
        // playCount can be reduced to just the plays we DIDN'T witness — the ones
        // with no exact date, which stay approximate (see Track.isExact).
        var scrobbledCounts: [String: Int] = [:]
        for t in importedTracks where Self.fromMusicApp(t) {
            scrobbledCounts[Self.dedupKey(t), default: 0] += 1
        }
        // Play counts as of the last scan, and the live plays we already
        // recorded since then. A rise in Music's lifetime counter that we didn't
        // witness ourselves is listening that happened while Tempo wasn't
        // watching — see `inferPlays`.
        let previousCounts = Persistence.loadPlayCounts()
        var liveSince: [String: Int] = [:]
        if let since = previousCounts?.taken {
            for t in importedTracks
            where Self.fromMusicApp(t) && !t.inferred && (t.lastPlayed ?? .distantPast) > since {
                liveSince[Self.dedupKey(t), default: 0] += 1
            }
        }
        let alreadyLive = liveSince
        // Reuse the cached cover thumbnails — decoding artwork out of the Music
        // library dominates a scan (seconds), while reading back a downscaled
        // PNG is trivial. Only genuinely new albums get decoded.
        let cachedArt = artworkData
        Task.detached(priority: .userInitiated) {
            do {
                let lib = try ITLibrary(apiVersion: "1.0")
                var out: [Track] = []
                out.reserveCapacity(lib.allMediaItems.count)
                var coverData: [String: Data] = [:]
                // Lifetime counts summed per song identity — two library items
                // can be the same song — plus enough of the tagging to build a
                // play record from, taken from the best-played copy.
                var counts: [String: Int] = [:]
                var meta: [String: (Track, Int)] = [:]

                for item in lib.allMediaItems {
                    guard item.mediaKind.rawValue == 2 else { continue } // 2 == song

                    // Artist tag exactly as Music stores it. Falls back to the
                    // album artist, then "Unknown Artist".
                    let artist = item.artist?.name
                        ?? item.album.albumArtist
                        ?? "Unknown Artist"
                    let album = item.album.title ?? ""
                    let albumKey = "\(album)::\(item.album.albumArtist ?? artist)"
                    let source: Source = item.isCloud ? .appleMusic : .local
                    // Normalised, so differing artist credits between the Music
                    // library and our own scrobbles still cancel out instead of
                    // counting the same play twice.
                    let alreadyScrobbled = scrobbledCounts[
                        "\(Self.normalizedTitle(item.title))|\(Self.primaryArtist(artist))"] ?? 0
                    let residualPlays = max(0, Int(item.playCount) - alreadyScrobbled)

                    let songKey = "\(Self.normalizedTitle(item.title))|\(Self.primaryArtist(artist))"
                    counts[songKey, default: 0] += Int(item.playCount)
                    if Int(item.playCount) >= (meta[songKey]?.1 ?? -1) {
                        meta[songKey] = (Track(title: item.title, artist: artist, album: album,
                                               albumKey: albumKey, source: source,
                                               lengthMs: Int(item.totalTime), plays: 1,
                                               lastPlayed: item.lastPlayedDate,
                                               year: item.year > 0 ? Int(item.year) : nil,
                                               inferred: true),
                                         Int(item.playCount))
                    }

                    out.append(Track(
                        title: item.title,
                        artist: artist,
                        album: album,
                        albumKey: albumKey,
                        source: source,
                        lengthMs: Int(item.totalTime),
                        plays: residualPlays,
                        lastPlayed: item.lastPlayedDate,
                        isExact: false,
                        year: item.year > 0 ? Int(item.year) : nil
                    ))

                    // Load each album's cover once, downscaled, off the main thread.
                    if Int(item.playCount) > 0, coverData[albumKey] == nil {
                        if let hit = cachedArt[albumKey] {
                            coverData[albumKey] = hit          // cache hit: no decode
                        } else if item.hasArtworkAvailable, let data = item.artwork?.imageData,
                                  let jpeg = Self.thumbnailData(data, maxPixel: 96) {
                            coverData[albumKey] = jpeg
                        }
                    }
                }

                let now = Date()
                let snapshot = counts          // immutable copy for the main-actor hop
                let inferred = Self.inferPlays(counts: snapshot, meta: meta,
                                               previous: previousCounts, alreadyLive: alreadyLive, now: now)
                // Those plays now live in the exact history, so take them back
                // out of the library's undated residual or they'd be counted twice.
                var owed: [String: Int] = [:]
                for t in inferred { owed[Self.songMatchKey(title: t.title, artist: t.artist), default: 0] += 1 }
                let loaded = out.map { t -> Track in
                    let k = Self.songMatchKey(title: t.title, artist: t.artist)
                    guard let n = owed[k], n > 0, t.plays > 0 else { return t }
                    let take = min(n, t.plays)
                    owed[k] = n - take
                    return t.withPlays(t.plays - take)
                }
                let art = coverData
                let images = art.compactMapValues { NSImage(data: $0) }
                await MainActor.run {
                    self.libraryTracks = loaded
                    Persistence.savePlayCounts(.init(taken: now, counts: snapshot))
                    if !inferred.isEmpty { self.mergeImported(inferred, source: .appleMusic, replace: false) }
                    self.artworkData = art
                    // Keep any remote covers already resolved for imported tracks.
                    self.artwork.merge(images) { _, new in new }
                    self.status = .loaded(count: loaded.count)
                    self.scanning = false
                    // The library is where most real durations come from, so this
                    // is the moment scrobbles that settled for the estimate can be
                    // given their true length. Whatever it still can't place,
                    // ask Last.fm about.
                    self.backfillScrobbleDurations()
                    self.resolveScrobbleDurations()
                }
                Persistence.saveLibrary(loaded)
                Persistence.saveArtwork(art)
            } catch {
                let ns = error as NSError
                // ITLibrary returns a permission error when Music access is denied.
                let denied = ns.domain == "com.apple.iTunesLibrary.ITLibrary"
                    || ns.localizedDescription.localizedCaseInsensitiveContains("permission")
                    || ns.localizedDescription.localizedCaseInsensitiveContains("denied")
                await MainActor.run {
                    self.status = denied ? .denied : .error(ns.localizedDescription)
                    self.scanning = false   // a failed scan must not lock out the next one
                }
            }
        }
    }

    /// Download covers for albums we don't already have art for (e.g. Last.fm
    /// scrobbles whose albums aren't in the local Music library). One request
    /// per album, downscaled, merged into `artwork` keyed by `albumKey`.
    func fetchRemoteArt(for tracks: [Track]) {
        var need: [String: URL] = [:]
        for t in tracks {
            guard artwork[t.albumKey] == nil, need[t.albumKey] == nil,
                  let s = t.artURL, let u = URL(string: s) else { continue }
            need[t.albumKey] = u
        }
        guard !need.isEmpty else { return }
        let snapshot = need
        Task.detached(priority: .utility) {
            let loaded = await withTaskGroup(of: (String, NSImage?).self) { group -> [String: NSImage] in
                for (key, url) in snapshot {
                    group.addTask {
                        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return (key, nil) }
                        return (key, Self.thumbnail(data, maxPixel: 96))
                    }
                }
                var out: [String: NSImage] = [:]
                for await (key, img) in group { if let img { out[key] = img } }
                return out
            }
            await MainActor.run { for (k, v) in loaded { self.artwork[k] = v } }
        }
    }

    /// Decode + downscale artwork using ImageIO (thread-safe, fast, low memory).
    nonisolated static func thumbnail(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let cg = thumbnailCG(data, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func thumbnailCG(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Downscale to JPEG bytes — the form we cache on disk. JPEG rather than PNG
    /// because covers are opaque photos: same visible quality at roughly a fifth
    /// of the size, which keeps the cache quick to read back at launch.
    nonisolated static func thumbnailData(_ data: Data, maxPixel: Int) -> Data? {
        guard let cg = thumbnailCG(data, maxPixel: maxPixel) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Aggregation

    /// Tracks that actually have listening time (played at least once), filtered
    /// by the active time range, app filter, and search query.
    /// Memoised like `buckets`, and for the same reason: the header, the empty
    /// state and the detail panel each ask for this inside a SwiftUI `body`, so
    /// it runs on every hover and every timer tick. Over a large history that
    /// filter is milliseconds a pass, which is the difference between a list
    /// that scrolls and one that doesn't.
    private var visibleCache: [String: [Track]] = [:]

    func visible(range: TimeRange, source: Source?, search: String) -> [Track] {
        let key = "\(dataVersion)|\(range)|\(source?.rawValue ?? "-")|\(search)"
        if let hit = visibleCache[key] { return hit }
        let result = computeVisible(range: range, source: source, search: search)
        if visibleCache.count > 16 { visibleCache.removeAll() }
        visibleCache[key] = result
        return result
    }

    private func computeVisible(range: TimeRange, source: Source?, search: String) -> [Track] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Track] = []
        forEachTrack { t in
            if keep(t, range: range, source: source, q: q) { out.append(t) }
        }
        return out
    }

    private func keep(_ t: Track, range: TimeRange, source: Source?, q: String) -> Bool {
        if t.plays <= 0 { return false }          // only real listening time
        if t.isExact {
            if !range.contains(t.lastPlayed) { return false }
        } else if !range.isAllTime {
            // No per-play timestamps for this one (see Track.isExact) — we
            // can't honestly place it in a window narrower than all time.
            return false
        }
        if let s = source, t.source.display != s.display { return false }
        if !q.isEmpty {
            let hay = "\(t.title) \(t.artist) \(t.album) \(t.source.display.rawValue)".lowercased()
            if !hay.contains(q) { return false }
        }
        return true
    }

    /// Grouping key for an artist name. Folds away the differences that are
    /// spelling noise rather than a different artist — case, stray whitespace,
    /// and surrounding punctuation — so "drake" and "Drake " are one row.
    /// Deliberately conservative: it does NOT strip articles like "The", which
    /// would merge genuinely distinct names.
    // MARK: - Song identity across sources

    /// A song's title with the decorations sources disagree about removed:
    /// bracketed suffixes ("(From …)", "[Deluxe Edition]", "(feat. X)") and the
    /// familiar " - Remastered" style tails. Version markers that mean a genuinely
    /// different recording — Remix, Male/Female, Acoustic — are deliberately kept.
    /// Words that mark a genuinely different recording. A bracketed phrase
    /// containing one of these is kept, so "Kangna (Acoustic Mix)" stays distinct
    /// from "Kangna" — everything else ("(From …)", "[Deluxe Edition]",
    /// "(feat. X)") is source noise and gets dropped.
    nonisolated private static let versionMarkers = [
        "remix", "mix", "acoustic", "instrumental", "reprise", "unplugged", "live",
        "demo", "karaoke", "mashup", "cover", "slowed", "reverb", "sped", "lofi",
        "male", "female", "duet", "extended",
    ]

    /// Compiled once, at first use. Building an `NSRegularExpression` costs far
    /// more than running it, and these were being rebuilt on every call: two
    /// per title, three counting the tail below. Indexing a 75,000-play history
    /// meant a quarter of a million regex compilations — enough to stop the app
    /// responding after a large Spotify import.
    nonisolated private static let bracketExprs: [NSRegularExpression] =
        ["\\(([^)]*)\\)", "\\[([^\\]]*)\\]"].compactMap { try? NSRegularExpression(pattern: $0) }

    nonisolated private static let pressingTailExpr = try? NSRegularExpression(
        pattern: "\\s-\\s(remaster(ed)?|mono|stereo|single version|album version|radio edit|bonus track|deluxe)\\b.*$",
        options: [.caseInsensitive])

    /// Results, keyed by the raw title. A big history is mostly the same songs
    /// over and over — 75,000 plays of 4,400 distinct tracks here — so nearly
    /// every call after the first is a lookup. Shared across threads (the
    /// library scan runs off the main actor), hence the lock.
    nonisolated(unsafe) private static var titleCache: [String: String] = [:]
    nonisolated private static let titleCacheLock = NSLock()

    nonisolated static func normalizedTitle(_ s: String) -> String {
        titleCacheLock.lock()
        let hit = titleCache[s]
        titleCacheLock.unlock()
        if let hit { return hit }

        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for re in bracketExprs {
            // Keep bracketed groups that name a version; drop the rest.
            var result = ""
            var last = t.startIndex
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let whole = Range(m.range, in: t), let inner = Range(m.range(at: 1), in: t) else { continue }
                result += t[last..<whole.lowerBound]
                let body = t[inner].lowercased()
                if versionMarkers.contains(where: { body.contains($0) }) { result += " " + t[inner] + " " }
                last = whole.upperBound
            }
            result += t[last...]
            t = result
        }
        // " - Remastered 2011" style tails: same recording, different pressing.
        if let re = pressingTailExpr {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        let out = t.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")

        titleCacheLock.lock()
        if titleCache.count > 50_000 { titleCache.removeAll(keepingCapacity: true) }
        titleCache[s] = out
        titleCacheLock.unlock()
        return out
    }

    /// The lead credit only. One source lists a track as "Pritam", another as
    /// "Pritam, Arijit Singh, Ash King…" — the first name is what they agree on.
    /// Memoised: this runs nine case-insensitive substring searches, and the
    /// song index calls it once per play. Over a large history that made it the
    /// single most expensive thing the app did.
    nonisolated(unsafe) private static var primaryArtistCache: [String: String] = [:]
    nonisolated private static let primaryArtistCacheLock = NSLock()

    nonisolated static func primaryArtist(_ s: String) -> String {
        primaryArtistCacheLock.lock()
        let hit = primaryArtistCache[s]
        primaryArtistCacheLock.unlock()
        if let hit { return hit }

        var a = s.components(separatedBy: CharacterSet(charactersIn: ",&/;")).first ?? s
        for sep in [" feat.", " feat ", " ft.", " ft ", " featuring ", " with ", " vs.", " vs ", " x "] {
            if let r = a.range(of: sep, options: [.caseInsensitive]) { a = String(a[..<r.lowerBound]) }
        }
        let out = artistKey(a)

        primaryArtistCacheLock.lock()
        if primaryArtistCache.count > 50_000 { primaryArtistCache.removeAll(keepingCapacity: true) }
        primaryArtistCache[s] = out
        primaryArtistCacheLock.unlock()
        return out
    }

    /// Resolves the several ways sources spell one song into a single identity.
    /// Two entries are the same song when the normalised titles match AND either
    /// the lead artist or the normalised album matches — so differing credits
    /// don't split a track, but two unrelated songs sharing a title don't merge.
    final class SongIndex {
        private var byArtist: [String: String] = [:]
        private var byAlbum: [String: String] = [:]

        /// A track's identity as far as this index is concerned. Hashing three
        /// existing strings costs nothing; interpolating them into new ones, for
        /// every play in the history, is most of what a rebuild used to spend
        /// its time on.
        private struct Ident: Hashable { let title: String, artist: String, album: String }

        /// Answers already worked out. Safe to reuse: once `byArtist` records a
        /// canonical id for a title+artist it is only ever re-read, never
        /// changed, so the same track always resolves the same way. A history of
        /// 75,000 plays is only a few thousand distinct songs, so nearly every
        /// call lands here.
        private var resolved: [Ident: String] = [:]

        func key(for t: Track) -> String {
            let ident = Ident(title: t.title, artist: t.artist, album: t.album)
            if let hit = resolved[ident] { return hit }

            let title = LibraryStore.normalizedTitle(t.title)
            let artistK = "\(title)|a|\(LibraryStore.primaryArtist(t.artist))"
            let album = LibraryStore.normalizedTitle(t.album)
            let albumK = album.isEmpty ? "" : "\(title)|b|\(album)"

            let canonical = byArtist[artistK] ?? (albumK.isEmpty ? nil : byAlbum[albumK]) ?? artistK
            byArtist[artistK] = canonical
            if !albumK.isEmpty { byAlbum[albumK] = canonical }
            resolved[ident] = canonical
            return canonical
        }
    }

    /// The same problem one level up: the Music library stamps an album with its
    /// *album artist* while imports use the track artist, so one album arrives
    /// under several ids — splitting it in the Albums view and breaking cover
    /// lookups. Identity is the normalised album title plus its lead artist;
    /// a generic credit ("Various Artists") adopts whatever real album shares
    /// the title, so compilations don't fragment.
    /// Two records only count as the same album when they share at least one
    /// song. Matching on title and artist alone is not enough: *Love Aaj Kal*
    /// (2009) and its 2020 namesake are both Pritam soundtracks with completely
    /// different track lists, and merging them is worse than leaving one album
    /// split. Overlap is the evidence that settles it — the same album seen by
    /// two sources always has songs in common; two different albums never do.
    final class AlbumIndex {
        private static let generics: Set<String> = ["", "various artists", "various", "unknown artist", "unknown"]
        /// "title|year" → the canonical id chosen by a real (non-generic) credit,
        /// so a "Various Artists" copy joins the named one instead of splitting.
        private var byTitleYear: [String: String] = [:]
        /// Song id → album id, learned from tracks that carry a year. Sources
        /// that report no year (Last.fm) attach through a song they share.
        private var songToGroup: [String: String] = [:]

        init(tracks: [Track], songs: SongIndex) {
            for t in tracks {
                guard let year = t.year, !Self.normTitle(t).isEmpty else { continue }
                let artist = Self.artist(t)
                guard !Self.generics.contains(artist) else { continue }
                let title = Self.normTitle(t)
                byTitleYear["\(title)|\(year)"] = byTitleYear["\(title)|\(year)"] ?? "\(title)|\(artist)|\(year)"
            }
            for t in tracks where t.year != nil {
                let k = key(for: t)
                guard !k.isEmpty else { continue }
                let sk = songs.key(for: t)
                if songToGroup[sk] == nil { songToGroup[sk] = k }
            }
            self.songs = songs
        }
        private var songs: SongIndex?

        private static func normTitle(_ t: Track) -> String { LibraryStore.normalizedTitle(t.album) }
        private static func artist(_ t: Track) -> String {
            LibraryStore.primaryArtist(LibraryStore.albumArtist(of: t))
        }

        func key(for t: Track) -> String {
            let title = Self.normTitle(t)
            guard !title.isEmpty else { return "" }
            let artist = Self.artist(t)
            if let year = t.year {
                if Self.generics.contains(artist), let named = byTitleYear["\(title)|\(year)"] { return named }
                return "\(title)|\(artist)|\(year)"
            }
            // No year from this source: follow a song we've already placed.
            if let songs, let g = songToGroup[songs.key(for: t)] { return g }
            return "\(title)|\(artist)|?"
        }
    }

    private var albumIndexCache: (version: UInt64, index: AlbumIndex)? = nil
    private var coverIndexCache: (version: UInt64, map: [String: NSImage])? = nil
    private var artVersion: UInt64 = 0

    func albumIndex() -> AlbumIndex {
        if let c = albumIndexCache, c.version == dataVersion { return c.index }
        let idx = AlbumIndex(tracks: tracks, songs: songIndex())
        albumIndexCache = (dataVersion, idx)
        return idx
    }

    /// The credit an album is filed under. `albumKey` is "album::albumArtist"
    /// for library tracks and "album::artist" for imports — either way the tail
    /// is the album's own credit.
    nonisolated static func albumArtist(of t: Track) -> String {
        let parts = t.albumKey.components(separatedBy: "::")
        guard parts.count > 1 else { return t.artist }
        let tail = parts[1...].joined(separator: "::")
        return tail.isEmpty ? t.artist : tail
    }

    func albumKey(for t: Track) -> String { albumIndex().key(for: t) }

    /// Cover for an album id, falling back to the canonical album identity — so
    /// a track imported from Spotify still finds the artwork the Music library
    /// scan stored under its own differently-spelled key.
    func cover(albumKey raw: String) -> NSImage? {
        if let img = artwork[raw] { return img }
        return coverIndex()[Self.coverKey(raw)]
    }

    /// Looser than album identity on purpose: covers are matched on title and
    /// artist alone. Two same-titled albums borrowing each other's artwork is a
    /// cosmetic slip; merging their statistics would not be.
    private static func coverKey(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "::")
        let album = parts.first ?? ""
        let artist = parts.count > 1 ? parts[1...].joined(separator: "::") : ""
        return "\(normalizedTitle(album))|\(primaryArtist(artist))"
    }

    private func coverIndex() -> [String: NSImage] {
        if let c = coverIndexCache, c.version == artVersion { return c.map }
        var map: [String: NSImage] = [:]
        for (raw, img) in artwork { map[Self.coverKey(raw)] = img }
        coverIndexCache = (artVersion, map)
        return map
    }

    private var songIndexCache: (version: UInt64, index: SongIndex)? = nil

    /// Built once over every known track so the mapping is stable, then reused.
    func songIndex() -> SongIndex {
        if let c = songIndexCache, c.version == dataVersion { return c.index }
        let idx = SongIndex()
        forEachTrack { _ = idx.key(for: $0) }
        songIndexCache = (dataVersion, idx)
        return idx
    }

    func songKey(for t: Track) -> String { songIndex().key(for: t) }

    private var songLabelCache: (version: UInt64, titles: [String: String], artists: [String: String])? = nil

    /// One title and one artist credit per song, so the same track never reads
    /// two ways. Sources describe a song differently in every direction —
    /// capitalisation ("O MAAHI" / "O Maahi"), a soundtrack suffix on some
    /// entries and not others (`Naal Nachna (From "Dhurandhar")` / `Naal
    /// Nachna`), and credits that list only the lead artist where another names
    /// everyone (`Shashwat Sachdev` / `Afsana Khan`). Grouped views already
    /// settle on one spelling; these give the same answer to anywhere a single
    /// play is shown, so History and Songs agree.
    func displayTitle(for t: Track) -> String { songLabels().titles[songKey(for: t)] ?? t.title }
    func displayArtist(for t: Track) -> String { songLabels().artists[songKey(for: t)] ?? t.artist }

    /// Every letter upper case, and more than one of them — enough to rule out
    /// a lone initial while still catching a fully capitalised title.
    nonisolated static func isShouty(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count > 1 && !letters.contains(where: \.isLowercase)
    }

    private func songLabels() -> (titles: [String: String], artists: [String: String]) {
        if let c = songLabelCache, c.version == dataVersion { return (c.titles, c.artists) }
        let idx = songIndex()
        var titleVotes: [String: [String: Int]] = [:]
        var bestArtist: [String: (plays: Int, artist: String)] = [:]
        for t in tracks {
            let k = idx.key(for: t)
            titleVotes[k, default: [:]][t.title, default: 0] += max(t.plays, 1)
            // Same rule the Songs list uses for its sub-label: the credit from
            // the most-played variant, which is usually the fullest tagging.
            if t.plays > (bestArtist[k]?.plays ?? -1) { bestArtist[k] = (t.plays, t.artist) }
        }
        let titles = titleVotes.compactMapValues { Self.settleTitle($0) }
        songLabelCache = (dataVersion, titles, bestArtist.mapValues(\.artist))
        return (titles, bestArtist.mapValues(\.artist))
    }

    /// Choose one spelling out of everything a song has been filed under.
    ///
    /// Two passes, because the two kinds of disagreement need opposite rules.
    /// Variants that differ only in case are folded together first, and there
    /// the calmer one wins outright — a shouty variant can easily be the more
    /// played, as "O MAAHI" is, so a vote would keep the shouting. Only then do
    /// genuinely different wordings compete, and there plays decide.
    private static func settleTitle(_ variants: [String: Int]) -> String? {
        var wordings: [String: (title: String, plays: Int)] = [:]
        for (title, plays) in variants {
            let k = title.lowercased()
            guard var g = wordings[k] else { wordings[k] = (title, plays); continue }
            g.plays += plays
            if betterCasing(title, than: g.title, in: variants) { g.title = title }
            wordings[k] = g
        }
        return wordings.values.max { a, b in
            a.plays != b.plays ? a.plays < b.plays : a.title > b.title
        }?.title
    }

    /// Within one wording: not shouting beats shouting, then more plays, then
    /// the string itself so the choice never wobbles on dictionary ordering.
    private static func betterCasing(_ a: String, than b: String, in variants: [String: Int]) -> Bool {
        if isShouty(a) != isShouty(b) { return !isShouty(a) }
        let pa = variants[a] ?? 0, pb = variants[b] ?? 0
        return pa != pb ? pa > pb : a < b
    }

    /// Memoised for the same reason as `normalizedTitle`: cheap on its own, but
    /// run over every play of a large history on every re-index.
    nonisolated(unsafe) private static var artistKeyCache: [String: String] = [:]
    nonisolated private static let artistKeyCacheLock = NSLock()

    nonisolated static func artistKey(_ s: String) -> String {
        artistKeyCacheLock.lock()
        let hit = artistKeyCache[s]
        artistKeyCacheLock.unlock()
        if let hit { return hit }

        let out = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,'\"’`-–—&+"))

        artistKeyCacheLock.lock()
        if artistKeyCache.count > 50_000 { artistKeyCache.removeAll(keepingCapacity: true) }
        artistKeyCache[s] = out
        artistKeyCacheLock.unlock()
        return out
    }

    func buckets(groupBy: GroupBy, sortBy: SortBy, range: TimeRange, source: Source?,
                 search: String, split: Bool = false) -> [Bucket] {
        let cacheKey = "\(dataVersion)|\(groupBy.rawValue)|\(sortBy.rawValue)|\(range)|\(source?.rawValue ?? "-")|\(search)|\(split)"
        if let hit = bucketCache[cacheKey] { return hit }
        let result = computeBuckets(groupBy: groupBy, sortBy: sortBy, range: range,
                                    source: source, search: search, split: split)
        if bucketCache.count > 24 { bucketCache.removeAll() }   // keep it bounded
        bucketCache[cacheKey] = result
        return result
    }

    private func computeBuckets(groupBy: GroupBy, sortBy: SortBy, range: TimeRange, source: Source?,
                                search: String, split: Bool) -> [Bucket] {
        var map: [String: Bucket] = [:]
        // For artists the map key is the normalised alias key, but each bucket
        // keeps the spelling of its most-played variant as the display label.
        var labelVotes: [String: [String: Int]] = [:]
        let songs = songIndex()
        let albums = albumIndex()
        func add(_ key: String, _ label: String, _ t: Track) {
            if groupBy == .artist || groupBy == .song {
                labelVotes[key, default: [:]][label, default: 0] += t.countedPlays
            }
            var b = map[key] ?? Bucket(id: key, label: label)
            b.totalMs += t.totalMs
            b.plays += t.countedPlays
            b.songKeys.insert(songs.key(for: t))
            b.sources.insert(t.source.display)
            if t.isExact, let d = t.lastPlayed, d > (b.lastPlayed ?? .distantPast) { b.lastPlayed = d }
            // Take artwork and the artist credit from the most-played variant —
            // usually the fullest tagging, rather than whichever source was last.
            if t.countedPlays > b.bestPlays {
                b.bestPlays = t.countedPlays
                b.artKey = t.albumKey
                if groupBy == .song  { b.sublabel = t.artist }
                if groupBy == .album { b.sublabel = Self.albumArtist(of: t) }
            }
            map[key] = b
        }
        for t in visible(range: range, source: source, search: search) {
            switch groupBy {
            case .artist:
                if split {
                    // Full attribution per contributor (protected names stay whole).
                    for part in ArtistSplitter.split(t.artist) { add(Self.artistKey(part), part, t) }
                } else {
                    add(Self.artistKey(t.artist), t.artist, t)
                }
            case .app:  add(t.source.display.rawValue, t.source.display.rawValue, t)
            case .song: add(songs.key(for: t), t.title, t)
            case .album:
                // Skip singles/loose tracks with no album tag — an "Unknown
                // Album" bucket holding hundreds of unrelated songs is noise.
                guard !t.album.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let key = albums.key(for: t)
                guard !key.isEmpty else { continue }
                labelVotes[key, default: [:]][t.album, default: 0] += t.countedPlays
                add(key, t.album, t)
            }
        }

        var arr = Array(map.values)
        for i in arr.indices {
            switch groupBy {
            case .artist:
                // Adopt the most-played spelling, and make that the row's id so
                // selection and the detail panel work in display terms.
                let best = labelVotes[arr[i].id]?.max(by: { $0.value < $1.value })?.key ?? arr[i].label
                let apps = arr[i].sources.map(\.rawValue).sorted().joined(separator: " · ")
                let n = arr[i].songKeys.count
                arr[i].label = best
                arr[i].id = best
                arr[i].sublabel = "\(n) song\(n == 1 ? "" : "s") · \(apps)"
            case .app:
                arr[i].sublabel = "\(arr[i].songKeys.count) songs · \(TimeFmt.commas(arr[i].plays)) plays"
            case .song:
                // Show the title spelling of the most-played variant.
                if let best = labelVotes[arr[i].id]?.max(by: { $0.value < $1.value })?.key {
                    arr[i].label = best
                }
            case .album:
                // Show the fullest album title we saw, credited to its artist.
                if let best = labelVotes[arr[i].id]?.max(by: { $0.value < $1.value })?.key {
                    arr[i].label = best
                }
                let artist = arr[i].sublabel     // set from the most-played track
                let n = arr[i].songKeys.count
                arr[i].sublabel = artist.isEmpty ? "\(n) track\(n == 1 ? "" : "s")"
                                                 : "\(artist) · \(n) track\(n == 1 ? "" : "s")"
            }
        }

        arr.sort { a, b in
            switch sortBy {
            case .time:  return a.totalMs > b.totalMs
            case .plays: return a.plays > b.plays
            case .name:  return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            case .recent:
                // Rows with no timestamped play sink to the bottom rather than
                // jumbling in at an arbitrary position.
                return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            }
        }
        return arr
    }
}
