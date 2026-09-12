import Foundation
import AppKit

/// Tempo's own scrobbler. Spotify's Mac app and Apple Music both broadcast
/// "now playing" distributed notifications; we listen and record real plays
/// with exact timestamps — no Last.fm, no API limits.
///
/// A play counts (Last.fm-style) once you've listened ≥ 30s AND at least half
/// the track (capped at 4 min). Pauses accumulate; skips don't count.
///
/// Every play we witness live gets recorded with an exact timestamp — including
/// Apple Music library tracks, which the Music app itself only ever gives us a
/// lifetime play count for. Double-count safety against that lifetime count is
/// handled on the read side (LibraryStore.load subtracts what we've already
/// scrobbled from the library's own count for the same track).
@MainActor
final class Scrobbler: ObservableObject {
    static let shared = Scrobbler()

    @Published var nowPlaying: String? = nil     // "Title — Artist", nil when idle
    @Published var npTitle = ""
    @Published var npArtist = ""
    @Published var nowPlayingArt: NSImage? = nil       // 16pt padded icon for the menu bar
    @Published var nowPlayingArtFull: NSImage? = nil   // larger cover for the dropdown panel
    @Published var scrobbledToday = 0
    @Published var isPlaying = false                   // drives the panel's play/pause icon
    @Published var npSource: Source? = nil             // which app to target for controls

    private weak var store: LibraryStore?
    private var started = false
    /// When false, we still track "now playing" for display but never write a
    /// scrobble — used by the main app while the background agent owns recording,
    /// so a live play is only ever counted once.
    private var recording = true

    private struct Session {
        let title: String, artist: String, album: String
        let durationMs: Int
        let source: Source
        let startedAt = Date()
        var accumulatedMs: Double = 0
        var resumedAt: Date?
        var recorded = false
    }
    private var session: Session?

    /// Hand recording to, or take it back from, the background agent while
    /// Tempo is running. `start` only ever runs once, so without this the
    /// decision made at launch outlived the setting that drives it: turning the
    /// agent off left nobody recording at all until the next relaunch.
    func setRecording(_ on: Bool) { recording = on }

    func start(store: LibraryStore, recording: Bool = true) {
        guard !started else { return }   // bootstrap may run again on window reopen
        started = true
        self.recording = recording
        self.store = store
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyNote(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(musicNote(_:)),
                        name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        // Older macOS / iTunes name, harmless if never posted.
        dnc.addObserver(self, selector: #selector(musicNote(_:)),
                        name: NSNotification.Name("com.apple.iTunes.playerInfo"), object: nil)
        seedFromPlayer()
    }

    /// Pick up whatever is already playing. Without this, starting Tempo mid-song
    /// leaves the menu bar and mini player reading "Not playing" until the track
    /// changes — and that play goes unrecorded.
    private func seedFromPlayer() {
        guard let np = MediaControl.nowPlaying(), !np.title.isEmpty else { return }
        let source: Source = MediaControl.currentApp == "Music" ? .appleMusic : .spotify
        handle(state: np.state, title: np.title, artist: np.artist, album: np.album,
               rawDuration: np.duration, source: source)
    }

    @objc private func spotifyNote(_ n: Notification) {
        guard let info = n.userInfo else { return }
        handle(state: info["Player State"] as? String ?? "",
               title: info["Name"] as? String ?? "",
               artist: info["Artist"] as? String ?? "",
               album: info["Album"] as? String ?? "",
               rawDuration: (info["Duration"] as? NSNumber)?.doubleValue ?? 0,
               source: .spotify)
    }

    @objc private func musicNote(_ n: Notification) {
        guard let info = n.userInfo else { return }
        handle(state: info["Player State"] as? String ?? "",
               title: info["Name"] as? String ?? "",
               artist: info["Artist"] as? String ?? "",
               album: info["Album"] as? String ?? "",
               rawDuration: (info["Total Time"] as? NSNumber)?.doubleValue ?? 0,
               source: .appleMusic)
    }

    private func handle(state: String, title: String, artist: String, album: String,
                        rawDuration: Double, source: Source) {
        // Players report duration in ms (Apple) or sometimes seconds (Spotify
        // builds vary). Anything under 1200 is treated as seconds.
        let durMs = rawDuration > 0 && rawDuration < 1200 ? rawDuration * 1000 : rawDuration
        let now = Date()

        npSource = source   // remember the app to target for the panel's controls

        // Settle the current session on track change or stop.
        if var s = session {
            let same = s.title == title && s.artist == artist && s.source == source
            if same && state != "Stopped" {
                if state == "Playing" {
                    if s.resumedAt == nil { s.resumedAt = now }
                    setNP(s.title, s.artist)
                    isPlaying = true
                } else { // paused: bank the played time
                    if let r = s.resumedAt {
                        s.accumulatedMs += now.timeIntervalSince(r) * 1000
                        s.resumedAt = nil
                    }
                    setNP(s.title, s.artist, suffix: " (paused)")
                    isPlaying = false
                }
                session = s
                return
            }
            finalize(&s)
            session = nil
        }

        if state == "Playing" && !title.isEmpty {
            var s = Session(title: title, artist: artist, album: album,
                            durationMs: Int(durMs), source: source)
            s.resumedAt = now
            session = s
            setNP(title, artist)
            isPlaying = true
            // Only the recording process announces, so you never get two banners.
            if recording { Notify.nowPlaying(title: title, artist: artist) }
            resolveArt(title: title, artist: artist, album: album)
        } else {
            clearNP()
            isPlaying = false
            nowPlayingArt = nil; nowPlayingArtFull = nil
        }
    }

    private func setNP(_ title: String, _ artist: String, suffix: String = "") {
        npTitle = title; npArtist = artist
        nowPlaying = title.isEmpty ? nil : "\(title) — \(artist)\(suffix)"
    }
    private func clearNP() { npTitle = ""; npArtist = ""; nowPlaying = nil }

    /// Cover for the menu bar: reuse the app's art cache when the album is
    /// known, otherwise look the track up on Deezer (public, no auth).
    private func resolveArt(title: String, artist: String, album: String) {
        let key = "\(album)::\(artist)"
        if let cached = store?.artwork[key] { nowPlayingArtFull = cached; nowPlayingArt = menuBarIcon(cached); return }
        nowPlayingArt = nil; nowPlayingArtFull = nil
        Task { [weak self] in
            var comps = URLComponents(string: "https://api.deezer.com/search/track")!
            comps.queryItems = [.init(name: "q", value: "\(artist) \(title)"), .init(name: "limit", value: "1")]
            guard let url = comps.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (j["data"] as? [[String: Any]])?.first,
                  let albumObj = first["album"] as? [String: Any],
                  let cover = (albumObj["cover_medium"] ?? albumObj["cover_small"]) as? String,
                  let coverURL = URL(string: cover),
                  let (img, _) = try? await URLSession.shared.data(from: coverURL),
                  let thumb = LibraryStore.thumbnail(img, maxPixel: 64) else { return }
            guard let self, self.session?.title == title else { return }  // still the same track
            self.nowPlayingArtFull = thumb
            self.nowPlayingArt = self.menuBarIcon(thumb)
            self.store?.artwork[key] = thumb   // full-size version for the main lists
        }
    }

    /// A menu-bar-sized icon: a 16×16 rounded cover with transparent trailing
    /// padding baked in, so there's a real gap before the track name that the
    /// menu bar can't compress. Intrinsic size is fixed so it isn't stretched.
    private func menuBarIcon(_ source: NSImage) -> NSImage {
        let side: CGFloat = 16, trailingPad: CGFloat = 7
        let out = NSImage(size: NSSize(width: side + trailingPad, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: side, height: side)   // cover on the left
        NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).addClip()
        source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func finalize(_ s: inout Session) {
        var playedMs = s.accumulatedMs
        if let r = s.resumedAt { playedMs += Date().timeIntervalSince(r) * 1000 }
        // Whatever rule is set in General settings — the Last.fm one by default.
        let needed = ScrobbleRule.requiredMs(durationMs: s.durationMs)
        guard !s.recorded else { return }
        guard playedMs >= needed else {
            // Didn't reach the scrobble threshold — that's a skip. Ignore the
            // near-instant track changes (under 5s) that are really just
            // scrubbing through a queue rather than rejecting a song.
            if recording, playedMs >= 5_000, !s.title.isEmpty {
                store?.recordSkip(title: s.title, artist: s.artist)
            }
            return
        }
        s.recorded = true
        // Display-only mode (agent owns recording): count nothing here.
        guard recording else { return }
        // Explicitly paused by the user — listen, don't record.
        guard !ScrobblePause.isPaused else { return }

        let ms = s.durationMs > 0 ? s.durationMs : Int(playedMs)
        let track = Track(title: s.title, artist: s.artist, album: s.album,
                          albumKey: "\(s.album)::\(s.artist)", source: s.source,
                          lengthMs: ms, plays: 1, lastPlayed: s.startedAt)
        store?.recordScrobble(track)
        scrobbledToday += 1
    }
}
