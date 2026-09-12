import Foundation
import UserNotifications

/// Opt-in notifications: what's playing when the window is closed, and the
/// occasional milestone worth looking up for. Everything here no-ops unless the
/// user turned it on in Settings AND macOS granted permission, so Tempo never
/// nags on its own.
@MainActor
enum Notify {
    static let nowPlayingKey = "notify.nowPlaying"
    static let milestonesKey = "notify.milestones"

    private static var authorized = false
    private static var asked = false

    static var nowPlayingEnabled: Bool { UserDefaults.standard.bool(forKey: nowPlayingKey) }
    static var milestonesEnabled: Bool { UserDefaults.standard.bool(forKey: milestonesKey) }

    /// Ask once, lazily — only when a notification is actually wanted.
    static func ensureAuthorized() async -> Bool {
        if authorized { return true }
        if asked { return authorized }
        asked = true
        let center = UNUserNotificationCenter.current()
        authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return authorized
    }

    static func nowPlaying(title: String, artist: String) {
        guard nowPlayingEnabled else { return }
        post(title: title, body: artist.isEmpty ? "Now playing" : artist, sound: false)
    }

    static func milestone(_ headline: String, _ detail: String) {
        guard milestonesEnabled else { return }
        post(title: headline, body: detail, sound: true)
    }

    private static func post(title: String, body: String, sound: Bool) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }
}

/// A temporary "don't count this" window — for when someone else is using your
/// speakers and you don't want it in your stats.
@MainActor
/// How long a track has to play before the live scrobbler counts it.
///
/// Read straight from `UserDefaults` at the moment a track finishes rather than
/// cached: scrobbling may be happening in the background agent while you change
/// the setting in the app, and both processes share this domain, so a live read
/// is what makes the change take effect without restarting anything.
enum ScrobbleRule {
    static let modeKey    = "scrobble.rule"       // standard | time | share
    static let secondsKey = "scrobble.seconds"    // for .time
    static let shareKey   = "scrobble.share"      // for .share, 0…1

    enum Mode: String, CaseIterable, Identifiable {
        case standard, time, share
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return "Half the track, or 4 minutes"
            case .time:     return "After a set amount of time"
            case .share:    return "After a share of the track"
            }
        }
    }

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .standard
    }
    /// Defaults chosen to match the standard rule's spirit if a mode is picked
    /// before its own value ever is.
    static var seconds: Int {
        let v = UserDefaults.standard.integer(forKey: secondsKey)
        return v > 0 ? v : 120
    }
    static var share: Double {
        let v = UserDefaults.standard.double(forKey: shareKey)
        return v > 0 ? v : 0.5
    }

    /// Milliseconds of playback needed for a track of this length to count.
    /// `durationMs` is 0 when the player didn't tell us how long the track is.
    static func requiredMs(durationMs: Int) -> Double {
        let d = Double(durationMs)
        switch mode {
        case .standard:
            // Last.fm's rule: at least 30s and at least half the track, and
            // never more than 4 minutes. Unknown length falls back to 4 minutes.
            return durationMs > 0 ? max(30_000, min(d / 2, 240_000)) : 240_000
        case .time:
            let want = Double(seconds) * 1000
            // Never ask for more than the track can give: a 3-minute threshold
            // on a 2-minute song would mean it could never count at all. The
            // last sliver is forgiven because players move to the next track a
            // moment early.
            return durationMs > 0 ? min(want, d * 0.95) : want
        case .share:
            // With no duration to take a share of, apply it to a typical song
            // rather than silently falling back to a rule you didn't choose.
            let base = durationMs > 0 ? d : Double(LastFM.estimatedMs)
            // Same forgiveness as above, so a 100% share is "the whole song"
            // rather than a threshold the player never quite reaches.
            return min(base * share, base * 0.95)
        }
    }

    /// Plain-English summary of the rule as configured, for the settings screen.
    static var summary: String {
        func clock(_ ms: Double) -> String {
            let t = Int((ms / 1000).rounded())
            return t < 60 ? "\(t)s" : String(format: "%d:%02d", t / 60, t % 60)
        }
        let example = 210_000   // a 3:30 song
        switch mode {
        case .standard:
            return "A 3:30 song counts after \(clock(requiredMs(durationMs: example))). Songs over 8 minutes count after 4:00."
        case .time:
            return "Every song counts after \(clock(Double(seconds) * 1000)) — or at 95% for anything shorter than that."
        case .share:
            return "A 3:30 song counts after \(clock(requiredMs(durationMs: example))). Tracks whose length is unknown use 3:30 as a stand-in."
        }
    }
}

enum ScrobblePause {
    private static let key = "scrobble.pausedUntil"

    static var pausedUntil: Date? {
        let t = UserDefaults.standard.double(forKey: key)
        guard t > 0 else { return nil }
        let d = Date(timeIntervalSince1970: t)
        return d > Date() ? d : nil
    }

    static var isPaused: Bool { pausedUntil != nil }

    static func pause(hours: Double) {
        let until = Date().addingTimeInterval(hours * 3600)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: key)
        DistributedNotificationCenter.default().postNotificationName(
            .init(AgentIPC.prefs), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func resume() {
        UserDefaults.standard.removeObject(forKey: key)
        DistributedNotificationCenter.default().postNotificationName(
            .init(AgentIPC.prefs), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// "paused until 4:15 PM" for the menu.
    static var label: String {
        guard let d = pausedUntil else { return "" }
        return "paused until \(d.formatted(date: .omitted, time: .shortened))"
    }
}
