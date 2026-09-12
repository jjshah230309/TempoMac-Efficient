import AppKit
import SwiftUI
import CoreGraphics
import ServiceManagement
import LocalAuthentication
import Combine

/// Cross-process signals between the full app and the background agent, sent
/// over `DistributedNotificationCenter` (same channel the scrobbler already
/// listens on).
enum AgentIPC {
    static let uiDown = "com.tempo.ui.down"   // the full app has quit
    static let prefs  = "com.tempo.agent.prefs"   // menu-bar preference changed
    /// Asks the running app to toggle its mini player. Both processes can host
    /// one; whoever the user can see should own it, so the agent hands the job
    /// over rather than opening a second window.
    static let toggleMini = "com.tempo.mini.toggle"
    /// UserDefaults key for the "show menu bar while in background" option.
    static let showMenuBarKey = "agent.menuBar"

    /// UserDefaults key for scroll-over-the-menu-bar-item-to-change-volume.
    static let scrollVolumeKey = "mb.scrollVolume"
    /// Defaults to on: it's how the app has always behaved and what the welcome
    /// screen still promises. Read live rather than cached — the menu bar item
    /// usually lives in the agent process while the switch is flipped in the
    /// app, and a live read is what makes it take effect straight away.
    static var scrollVolume: Bool {
        UserDefaults.standard.object(forKey: scrollVolumeKey) as? Bool ?? true
    }
}

/// Process entry point. Tempo ships as ONE binary that runs in two modes:
///
///  • Normal:  the full SwiftUI menu-bar app (`TempoApp`).
///  • `--agent`: a headless background scrobbler with no window, no Dock icon —
///    launched and kept alive by launchd (see `BackgroundAgent`). This is what
///    lets live plays keep recording even after you Quit Tempo.
@main
enum TempoMain {
    static func main() {
        if CommandLine.arguments.contains("--agent") {
            AgentRunner.run()
        } else {
            // Kick the background menu-bar helper awake alongside the heavy
            // SwiftUI/iTunesLibrary launch, so it appears near-instantly instead
            // of waiting for the whole app. On its own thread: this asks
            // launchctl whether the helper is alive, and waiting for that answer
            // in front of the UI held the first window back by seconds.
            Thread.detachNewThread { BackgroundAgent.ensureRunningIfEnabled() }
            TempoApp.main()
        }
    }
}

/// The headless mode. Runs a minimal NSApplication whose only job is to keep the
/// scrobbler alive and writing history to disk. No windows are ever created.
enum AgentRunner {
    static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)   // background: no Dock icon, no menu bar
            let delegate = AgentDelegate()
            app.delegate = delegate               // kept alive: app.run() blocks below
            app.run()
        }
    }
}

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let store = LibraryStore()
    private let menuBar = AgentMenuBar()
    func applicationDidFinishLaunching(_ note: Notification) {
        store.startScrobbleOnly()
        menuBar.start(store: store)
        MiniPlayerController.shared.restoreIfEnabled()
    }

    /// The agent shares the app's bundle, so when you reopen Tempo (Dock,
    /// Spotlight, Finder) LaunchServices routes the request to this windowless
    /// background process instead of opening a window. Intercept it and bring up
    /// the real UI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar.handleReopen()
        return false
    }

    /// Opening a UIElement app (e.g. `open -a Tempo`, or macOS routing a reopen
    /// here) promotes it to a foreground app — which would put the agent in the
    /// Dock and Cmd-Tab. Demote back to accessory so the background agent stays
    /// invisible, like Raycast. Guarded so activating just to show the panel
    /// (already accessory) doesn't churn the activation policy.
    func applicationDidBecomeActive(_ note: Notification) {
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Launch a fresh full-UI instance of Tempo. `open -n` forces a new process
/// (the default `open` would just re-activate this windowless agent).
@MainActor
func launchTempoUI() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-n", Bundle.main.bundleURL.path]
    try? p.run()
}

/// Controls the music playing on this Mac from the menu-bar panel: play/pause,
/// next, previous (sent to Spotify or Apple Music via AppleScript), plus system
/// output volume. It targets whichever app the scrobbler is currently watching,
/// falling back to whichever of the two is running. Requires a one-time
/// "control Spotify/Music" automation grant (see NSAppleEventsUsageDescription).
@MainActor
enum MediaControl {
    static func playPause() { tellApp("playpause") }
    static func next()      { tellApp("next track") }
    static func previous()  { tellApp("previous track") }
    // Explicit rather than toggled: lifting the mini player's tonearm has to
    // stop the music whatever state it thinks playback is in, and dropping the
    // needle back on has to start it.
    static func pause()     { tellApp("pause") }
    static func play()      { tellApp("play") }

    /// Current position and track length in seconds, or nil when no supported
    /// player is running. Never sends AppleScript to an app that isn't already
    /// running — `tell application "X"` would launch it.
    static func progress() -> (position: Double, duration: Double)? {
        guard let app = runningTarget() else { return nil }
        guard let raw = run("""
            tell application "\(app)" to return (player position as string) & "|" & ((duration of current track) as string)
            """) else { return nil }
        let parts = raw.split(separator: "|")
        guard parts.count == 2,
              let pos = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let rawDur = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        // Spotify reports track duration in milliseconds; Music in seconds.
        let dur = app == "Spotify" ? rawDur / 1000 : rawDur
        guard dur > 0 else { return nil }
        return (pos, dur)
    }

    /// Where to get the cover for what is playing *right now*. Taken from the
    /// player itself rather than Tempo's library cache: the two disagree more
    /// often than you'd think (singles vs album pressings, remasters, regional
    /// releases), and in a mini player the wrong cover is glaring.
    enum ArtSource {
        case url(String)     // Spotify hands us a URL
        case data(Data)      // Music hands us raw image bytes
        case none
    }

    static func artworkSource() -> ArtSource {
        guard let app = runningTarget() else { return .none }
        if app == "Spotify" {
            guard let u = run("tell application \"Spotify\" to return artwork url of current track"),
                  u.hasPrefix("http") else { return .none }
            return .url(u)
        }
        var err: NSDictionary?
        let src = "tell application \"Music\" to return raw data of artwork 1 of current track"
        guard let desc = NSAppleScript(source: src)?.executeAndReturnError(&err), err == nil else { return .none }
        let bytes = desc.data
        return bytes.isEmpty ? .none : .data(bytes)
    }

    /// Ask the player what's on right now. Tempo otherwise only learns about a
    /// track when the player *changes* one, so anything already playing when
    /// Tempo starts stayed invisible until the next song.
    static func nowPlaying() -> (state: String, title: String, artist: String, album: String, duration: Double)? {
        guard let app = runningTarget() else { return nil }
        // NB: `st` and `t` collide with AppleScript terms inside a tell block
        // and fail to compile — hence the longer variable names.
        let script = """
        tell application "\(app)"
            set ps to (player state as string)
            if ps is "stopped" then return "stopped|||||"
            set tr to current track
            return ps & "|" & (name of tr) & "|" & (artist of tr) & "|" & (album of tr) & "|" & ((duration of tr) as string)
        end tell
        """
        guard let raw = run(script) else { return nil }
        let f = raw.components(separatedBy: "|")
        guard f.count >= 5 else { return nil }
        // AppleScript reports lowercase states; the notification payloads we
        // normally parse are capitalised, so match those.
        let state = f[0].lowercased() == "playing" ? "Playing"
                  : (f[0].lowercased() == "paused" ? "Paused" : "Stopped")
        return (state, f[1], f[2], f[3], Double(f[4]) ?? 0)
    }

    static func seek(to seconds: Double) {
        guard let app = runningTarget() else { return }
        run("tell application \"\(app)\" to set player position to \(max(0, seconds))")
    }

    private static func tellApp(_ command: String) {
        guard let app = runningTarget() else { return }
        run("tell application \"\(app)\" to \(command)")
    }

    /// Which player we're currently talking to, if any.
    static var currentApp: String? { runningTarget() }

    /// Which players are running — cached, because enumerating
    /// NSWorkspace.runningApplications on every call meant every keystroke,
    /// scroll and progress tick paid for a scan of all running apps. Kept true
    /// by launch/quit observations (rare) instead of per-call queries.
    private static var spotifyUp = false
    private static var musicUp = false
    private static var observingLaunches = false

    /// Recompute the cached running-player flags. Called once at first use and
    /// again only when an app launches or quits.
    private static func refreshRunningState() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        spotifyUp = running.contains("com.spotify.client")
        musicUp   = running.contains("com.apple.Music")
    }

    /// One-time: observe launches/quits so the cached flags stay current.
    /// Register before seeding, so an app that appears in between is caught by
    /// the queued observer callback rather than lost to the gap.
    private static func observeLaunchesIfNeeded() {
        guard !observingLaunches else { return }
        observingLaunches = true
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshRunningState() }
        }
        wc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshRunningState() }
        }
        refreshRunningState()
    }

    /// The player we should talk to — preferring whatever the scrobbler is
    /// watching — but only if it's actually running.
    private static func runningTarget() -> String? {
        observeLaunchesIfNeeded()
        if let s = Scrobbler.shared.npSource {
            let preferred = s == .appleMusic ? "Music" : "Spotify"
            if preferred == "Music", musicUp { return "Music" }
            if preferred == "Spotify", spotifyUp { return "Spotify" }
        }
        if spotifyUp { return "Spotify" }
        if musicUp   { return "Music" }
        return nil
    }

    /// System output volume, 0–100.
    static func volume() -> Int {
        Int(run("output volume of (get volume settings)") ?? "") ?? 50
    }
    static func setVolume(_ v: Int) {
        run("set volume output volume \(max(0, min(100, v)))")
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err { NSLog("Tempo MediaControl error: \(err)"); return nil }
        return result?.stringValue
    }
}

/// The background agent's own menu-bar item — the live now-playing display, the
/// app's only persistent, always-visible presence (like Raycast's). It's shown
/// whenever the "keep menu bar" option is on; the agent itself is `.accessory`,
/// so it never appears in the Dock, Cmd-Tab, or Force Quit.
@MainActor
final class AgentMenuBar: NSObject {
    private var item: NSStatusItem?
    private weak var store: LibraryStore?
    private var bag = Set<AnyCancellable>()
    private var panelWindow: NSPanel?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var scrollMonitor: Any?
    /// 5s refresh tick, armed ONLY while something is playing — it exists to
    /// move the icon's progress hairline. Nil while idle, so an idle Mac never
    /// wakes for the menu bar.
    private var tickTimer: Timer?
    /// One-shot firing just past the next midnight while idle — the only work
    /// an idle item ever has: roll the "today" total into the new day.
    private var midnightTimer: Timer?
    /// When the full app last told us it was quitting. macOS sends this leftover
    /// agent a spurious "reopen" the instant the app's primary instance quits;
    /// we suppress that so quitting doesn't bounce a new window back up.
    private var lastUIDown = Date.distantPast

    private var optionOn: Bool {
        UserDefaults.standard.object(forKey: AgentIPC.showMenuBarKey) as? Bool ?? true
    }

    func start(store: LibraryStore) {
        self.store = store
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(onUIDown), name: .init(AgentIPC.uiDown), object: nil)
        dnc.addObserver(self, selector: #selector(onPrefs),  name: .init(AgentIPC.prefs),  object: nil)
        dnc.addObserver(self, selector: #selector(miniRequest(_:)), name: .init(AgentIPC.toggleMini), object: nil)
        refresh()   // show the item immediately if the option is on

        // Refresh the now-playing display whenever the scrobbler changes.
        Scrobbler.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &bag)

        // Also refresh when the play history changes (a source sync landed new
        // plays), so the "today" total updates.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &bag)
        // No always-on timer (this used to tick every 5s around the clock —
        // ~17k wakeups a day to redraw a static item). updateContent arms the
        // 5s tick only while something is playing, for the progress hairline,
        // and otherwise schedules ONE midnight shot to roll the "today" total
        // into the new day. Every idle↔playing transition re-runs
        // updateContent via the subscriptions above, so the timers swap
        // themselves with no permanently-scheduled wakeup.
    }

    @objc private func onUIDown() { lastUIDown = Date() }

    /// A settings change from the app process. UserDefaults changes can take a
    /// beat to propagate across processes, so re-read now and again shortly after.
    @objc private func onPrefs() {
        UserDefaults.standard.synchronize()
        MiniPlayerController.shared.handlePrefsChanged()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            UserDefaults.standard.synchronize()
            self?.refresh()
        }
    }

    @objc private func refresh() {
        if optionOn { show() } else { hide() }
    }

    /// A reopen request routed to the agent. Ignore the spurious one macOS fires
    /// right after the app quits; honor a genuine reopen (user clicked later).
    func handleReopen() {
        if Date().timeIntervalSince(lastUIDown) < 2.5 { return }
        openFullUI()
    }

    private func show() {
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            installGestures()
        }
        updateContent()
    }

    /// Scroll over the menu-bar item to change volume — the fastest possible
    /// control, no clicking required. Middle-click toggles play/pause.
    private func installGestures() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] e in
            guard let self, let button = self.item?.button, e.window === button.window else { return e }
            switch e.type {
            case .scrollWheel:
                guard AgentIPC.scrollVolume else { return e }
                // Only what your fingers are actually doing. macOS keeps sending
                // scroll events for a second or two after a flick, and acting on
                // those meant one swipe carried on turning the volume down by
                // itself — the volume appearing to drop with nobody touching it.
                guard e.momentumPhase.isEmpty else { return nil }
                // Trackpads report fine-grained deltas; mice report whole lines.
                let step = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 4 : e.scrollingDeltaY * 3
                guard abs(step) >= 0.5 else { return nil }
                let next = Int((Double(MediaControl.volume()) + step).rounded())
                MediaControl.setVolume(next)
                return nil
            case .otherMouseDown:
                MediaControl.playPause()
                return nil
            default: return e
            }
        }
    }

    private func hide() {
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
        // Nothing displayed means nothing to refresh — no timers either.
        tickTimer?.invalidate(); tickTimer = nil
        midnightTimer?.invalidate(); midnightTimer = nil
    }

    private func updateContent() {
        guard let button = item?.button else { return }
        let s = Scrobbler.shared
        let d = UserDefaults.standard
        let showCover = d.object(forKey: "mb.showCover") as? Bool ?? true
        let showTitle = d.object(forKey: "mb.showTitle") as? Bool ?? true
        let showArtist = d.object(forKey: "mb.showArtist") as? Bool ?? true
        let showTodayIdle = d.object(forKey: "mb.showTodayIdle") as? Bool ?? true
        let maxChars = Int(d.object(forKey: "mb.maxChars") as? Double ?? 36)

        let playing = s.nowPlaying != nil
        var icon = (playing && showCover ? s.nowPlayingArt : nil)
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Tempo")
        if playing, showCover, s.nowPlayingArt != nil,
           d.object(forKey: "mb.showProgress") as? Bool ?? true,
           let p = MediaControl.progress(), p.duration > 0, let base = icon {
            icon = iconWithProgress(base, fraction: p.position / p.duration)
        }
        button.image = icon
        button.imagePosition = .imageLeading

        if playing {
            var parts: [String] = []
            if showTitle, !s.npTitle.isEmpty { parts.append(s.npTitle) }
            if showArtist, !s.npArtist.isEmpty { parts.append(s.npArtist) }
            let joined = parts.joined(separator: " — ")
            button.title = joined.count > maxChars
                ? String(joined.prefix(max(1, maxChars - 1))).trimmingCharacters(in: .whitespaces) + "…"
                : joined
        } else if showTodayIdle, let ms = store?.todayMs, ms >= 60_000 {
            button.title = TimeFmt.short(ms)
        } else {
            button.title = ""
        }

        // Style: "panel" → click opens a rich now-playing popover; "menu" → a
        // plain dropdown. When a menu is attached the button's own action never
        // fires, so we clear the menu for the panel style.
        if (d.string(forKey: "mb.style") ?? "panel") == "menu" {
            button.target = nil
            button.action = nil
            item?.menu = buildMenu()
        } else {
            item?.menu = nil
            button.target = self
            button.action = #selector(statusClicked)
        }

        // Timer discipline (see start(store:)): a 5s tick only while playing,
        // otherwise a single midnight shot. Idempotent, so any call path —
        // subscriptions, panel opens, the ticks themselves — can run it.
        if playing {
            if tickTimer == nil {
                tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateContent() }
                }
            }
            if midnightTimer != nil { midnightTimer?.invalidate(); midnightTimer = nil }
        } else {
            if tickTimer != nil { tickTimer?.invalidate(); tickTimer = nil }
            if midnightTimer == nil || midnightTimer?.isValid == false {
                midnightTimer?.invalidate()
                if let secs = untilMidnight() {
                    midnightTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateContent() }   // rolls the day over, re-arms
                    }
                }
            }
        }
    }

    /// Seconds until just past the next midnight — where the idle one-shot
    /// fires to roll the "today" total into a new day.
    private func untilMidnight() -> TimeInterval? {
        var comps = DateComponents()
        comps.hour = 0
        comps.minute = 0
        comps.second = 2   // just inside the new day, clear of 00:00:00 rounding
        guard let midnight = Calendar.current.nextDate(
            after: Date(), matching: comps, matchingPolicy: .nextTime
        ) else { return nil }
        return max(1, midnight.timeIntervalSinceNow)
    }

    /// Plain click opens the panel; ⌘-click jumps straight to Wrapped.
    @objc private func statusClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            UserDefaults.standard.set(true, forKey: "view.showWrapped")
            UserDefaults.standard.set(false, forKey: "view.showHistory")
            closePanel()
            openFullUI()
        } else {
            togglePanel()
        }
    }

    /// The cover in the menu bar doubles as a progress indicator: a hairline
    /// under the artwork fills as the track plays. Cheap, and it keeps the item
    /// itself informative without stealing menu-bar width.
    private func iconWithProgress(_ base: NSImage, fraction: Double) -> NSImage {
        guard fraction > 0, fraction <= 1 else { return base }
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        let barW = base.size.width - 7          // the icon's trailing padding
        let y: CGFloat = 0
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: y, width: barW, height: 1.5)).fill()
        NSColor.labelColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: y, width: barW * fraction, height: 1.5)).fill()
        out.unlockFocus()
        return out
    }

    private func buildMenu() -> NSMenu {
        let s = Scrobbler.shared
        let m = NSMenu()
        let np = NSMenuItem(title: s.nowPlaying ?? "Not playing", action: nil, keyEquivalent: "")
        np.isEnabled = false
        m.addItem(np)
        let today = NSMenuItem(title: "\(s.scrobbledToday) scrobbled today", action: nil, keyEquivalent: "")
        today.isEnabled = false
        m.addItem(today)
        m.addItem(.separator())
        // Read the shared flag, not our own window: the app may be the one
        // showing it, and a menu that says "Mini Player" while one is on screen
        // is just wrong.
        let miniShown = UserDefaults.standard.bool(forKey: Mini.enabledKey)
        let mini = NSMenuItem(title: miniShown ? "Hide Mini Player" : "Mini Player",
                              action: #selector(toggleMini), keyEquivalent: "")
        mini.target = self
        m.addItem(mini)
        let pause = NSMenuItem(title: ScrobblePause.isPaused ? "Resume scrobbling (\(ScrobblePause.label))" : "Pause scrobbling for 1 hour",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        m.addItem(pause)
        let open = NSMenuItem(title: "Open Tempo", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        m.addItem(open)
        m.addItem(.separator())
        // ⌘Q quits everything while the menu is open, matching the panel.
        let quit = NSMenuItem(title: "Quit Tempo", action: #selector(quitAll), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        m.addItem(quit)
        return m
    }

    @objc private func openApp() { openFullUI() }

    /// Let the app own the mini player when it's running, so the two processes
    /// can't each put one on screen.
    @objc private func toggleMini() {
        MiniPlayerController.requestToggle()
        updateContent()
    }

    /// Only host the window ourselves when the app isn't around to do it.
    @objc private func miniRequest(_ note: Notification) {
        let show = (note.userInfo?["show"] as? String).map { $0 == "1" }
        let bid = Bundle.main.bundleIdentifier ?? "com.tempo.listening"
        let me = ProcessInfo.processInfo.processIdentifier
        let appRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .contains { $0.processIdentifier != me }
        MiniPlayerController.shared.handleRequest(show: show, preferredHost: !appRunning)
        updateContent()
    }

    @objc private func togglePause() {
        if ScrobblePause.isPaused { ScrobblePause.resume() } else { ScrobblePause.pause(hours: 1) }
        updateContent()
    }

    // MARK: Panel (rich dropdown under the menu bar)

    @objc private func togglePanel() {
        if panelWindow != nil { closePanel() } else { showPanel() }
    }

    /// Show the rich panel as a borderless window placed *exactly* under the
    /// status item. We position it by hand from the status item's window frame
    /// rather than relying on NSPopover, whose auto-positioning with a SwiftUI
    /// host landed the panel well below the menu bar.
    private func showPanel() {
        guard let button = item?.button, let statusWin = button.window, let store else { return }
        closePanel()

        // Fixed size. AgentPanel renders to exactly this. The hosting view goes
        // inside a plain container so it can't resize/reposition the window
        // (NSHostingView drives its window's size by default, which was moving
        // the panel out from under the menu bar).
        let size = NSSize(width: 272, height: 310)
        let host = NSHostingView(rootView: AgentPanel(
            store: store,
            onOpen: { [weak self] in self?.closePanel(); self?.openFullUI() },
            onQuit: { [weak self] in self?.quitAll() },
            onToggleMini: { [weak self] in self?.toggleMini() }))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(host)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = container

        // Anchor the panel's TOP-LEFT to the menu bar's bottom edge, right edge
        // aligned to the status item, clamped on-screen.
        let sf = statusWin.frame                    // (x, screenTop-30, w, 30)
        let screen = statusWin.screen ?? NSScreen.main!
        var x = sf.maxX - size.width
        x = min(max(x, screen.frame.minX + 6), screen.frame.maxX - size.width - 6)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: sf.minY))   // sf.minY = menu bar bottom
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)      // make it key for ⌘Q
        panelWindow = panel

        // ⌘Q while the panel is open quits everything.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" {
                self?.quitAll(); return nil
            }
            return e
        }
        // Click anywhere outside the panel dismisses it.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panelWindow?.orderOut(nil)
        panelWindow = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    /// Quit the ENTIRE app: close the panel, terminate the UI if open, and stop
    /// this agent without letting launchd respawn it. Reopening Tempo brings it
    /// all back (see `BackgroundAgent.ensureRunningIfEnabled`).
    @objc private func quitAll() {
        closePanel()
        BackgroundAgent.quitEverything()
    }

    /// Bring up the full UI. Only "activate an existing app" when there's an
    /// actual on-screen window to raise; otherwise a windowless ghost instance
    /// would swallow the request and nothing would appear — so spawn fresh.
    func openFullUI() {
        if hasVisibleMainWindow() {
            let bid = Bundle.main.bundleIdentifier ?? "com.tempo.listening"
            let me = ProcessInfo.processInfo.processIdentifier
            NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != me }
                .forEach { $0.activate(options: [.activateAllWindows]) }
        } else {
            launchTempoUI()
        }
    }

    /// Is a real Tempo main window on screen (not this agent's status/menu-bar
    /// windows)? Checked via the window server so a windowless process can't fool us.
    private func hasVisibleMainWindow() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let wl = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for w in wl {
            guard (w[kCGWindowOwnerName as String] as? String)?.contains("Tempo") == true,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != Int(me) else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            if (b["Height"] as? Double ?? 0) > 200 { return true }   // a real window, not a strip
        }
        return false
    }
}

/// The rich now-playing popover for the "panel" menu-bar style — the app's own
/// UI in the menu bar, like the previous version. Observes the live scrobbler so
/// it updates while open.
struct AgentPanel: View {
    @ObservedObject private var scrobbler = Scrobbler.shared
    @ObservedObject var store: LibraryStore
    var onOpen: () -> Void
    var onQuit: () -> Void
    var onToggleMini: () -> Void

    @State private var volume: Double = 50
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var vinyl = false
    @State private var spin: Double = 0
    @State private var paused = ScrobblePause.isPaused
    @AppStorage(Mini.enabledKey) private var miniOpen = false

    /// The artist line — with a couple of jokes hiding in it.
    private var caption: String {
        // 4′33″ — John Cage's silent piece. Exactly 273 seconds.
        if Int(duration.rounded()) == 273 { return "John Cage would be proud" }
        let t = scrobbler.npTitle.lowercased()
        if t.contains("never gonna give you up") { return "you know the rules, and so do I" }
        return scrobbler.npArtist
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let art = scrobbler.nowPlayingArtFull {
                        // Vinyl mode: the cover turns like a record while playing.
                        Image(nsImage: art).resizable().interpolation(.high)
                            .frame(width: 46, height: 46)
                            .clipShape(vinyl ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
                            .overlay {
                                if vinyl {
                                    Circle().fill(C.panel).frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(C.line, lineWidth: 1))
                                }
                            }
                            .rotationEffect(.degrees(vinyl ? spin : 0))
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(C.panel3)
                            .frame(width: 46, height: 46)
                            .overlay(Image(systemName: "music.note").foregroundColor(C.muted2))
                    }
                }
                .onTapGesture(count: 2) { vinyl.toggle() }
                .help("Double-click for vinyl mode")

                VStack(alignment: .leading, spacing: 2) {
                    if scrobbler.nowPlaying != nil {
                        Text(scrobbler.npTitle).font(.system(size: 13, weight: .bold))
                            .foregroundColor(C.text).lineLimit(1)
                        Text(caption).font(.system(size: 12))
                            .foregroundColor(C.muted).lineLimit(1)
                    } else {
                        Text(ScrobblePause.isPaused ? "Scrobbling paused" : "Not playing")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(C.text)
                        Text(ScrobblePause.isPaused ? ScrobblePause.label : "Live scrobbler is listening")
                            .font(.system(size: 11)).foregroundColor(C.muted2)
                    }
                }
                Spacer()
            }.padding(.bottom, 10)

            // Scrubber — drag to seek in the running player.
            VStack(spacing: 3) {
                Slider(value: $position, in: 0...max(duration, 1)) { editing in
                    scrubbing = editing
                    if !editing { MediaControl.seek(to: position) }
                }
                .controlSize(.mini)
                .disabled(duration <= 0)
                HStack {
                    Text(clock(position)).font(.system(size: 9, design: .monospaced)).foregroundColor(C.muted2)
                    Spacer()
                    Text(duration > 0 ? clock(duration) : "--:--")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(C.muted2)
                }
            }.padding(.bottom, 8)

            // Transport controls
            HStack(spacing: 26) {
                ctlButton("backward.fill", size: 15) { MediaControl.previous() }
                Button { MediaControl.playPause() } label: {
                    Image(systemName: scrobbler.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(C.bg)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(C.green))
                }.buttonStyle(.plain)
                ctlButton("forward.fill", size: 15) { MediaControl.next() }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)

            // Volume
            HStack(spacing: 9) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundColor(C.muted2)
                Slider(value: $volume, in: 0...100)
                    .controlSize(.small)
                    .onChange(of: volume) { _, v in MediaControl.setVolume(Int(v)) }
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundColor(C.muted2)
            }

            Divider().padding(.vertical, 9)

            Text("Today: \(TimeFmt.short(store.todayMs)) · \(scrobbler.scrobbledToday) scrobbled live")
                .font(.system(size: 11)).foregroundColor(C.muted2).padding(.bottom, 6)

            panelButton(miniOpen ? "Hide mini player" : "Mini player", "rectangle.inset.filled") {
                onToggleMini()   // the shared flag updates the label for us
            }
            panelButton(ScrobblePause.isPaused ? "Resume scrobbling" : "Pause scrobbling for 1 hour",
                        ScrobblePause.isPaused ? "play.circle" : "pause.circle") {
                if ScrobblePause.isPaused { ScrobblePause.resume() } else { ScrobblePause.pause(hours: 1) }
                paused = ScrobblePause.isPaused
            }
            panelButton("Open Tempo", "macwindow", action: onOpen)
            panelButton("Quit Tempo", "power", action: onQuit)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(C.panel)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(C.line, lineWidth: 1))
        )
        .padding(6)                       // room for the window shadow
        .frame(width: 272, height: 310)   // exact panel size (matches showPanel)
        .onAppear {
            volume = Double(MediaControl.volume())
            paused = ScrobblePause.isPaused
            refreshProgress()
        }
        .onReceive(tick) { _ in
            refreshProgress()
            if vinyl, scrobbler.isPlaying {
                withAnimation(.linear(duration: 1)) { spin += 24 }   // ~40rpm
            }
        }
    }

    /// Poll the player, unless the user is mid-drag on the scrubber.
    private func refreshProgress() {
        guard !scrubbing else { return }
        if let p = MediaControl.progress() {
            position = min(p.position, p.duration)
            duration = p.duration
        } else {
            position = 0; duration = 0
        }
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func ctlButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .medium)).foregroundColor(C.text)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func panelButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13)).foregroundColor(C.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Manages the launchd LaunchAgent that runs `Tempo --agent` in the background.
///
/// We install it the classic way — writing a plist to `~/Library/LaunchAgents`
/// and loading it with `launchctl bootstrap` — rather than `SMAppService.agent`.
/// SMAppService makes launchd validate the helper against a code requirement
/// (LWCR), which a self-signed / no-Team-ID build (like Tempo's local signing)
/// can't satisfy: launchd refuses to spawn it (`spawn failed`, `EX_CONFIG`).
/// A user LaunchAgent loaded manually has no such requirement, so it runs with
/// any signature. It's a *user* agent (not a root daemon), so it lives in your
/// login session — exactly where Spotify/Music broadcast "now playing".
enum BackgroundAgent {
    static let label = "com.tempo.bgscrobbler"

    private static var plistURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    private static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Tempo.app/Contents/MacOS/Tempo"
    }

    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "\(domainTarget)/\(label)" }

    /// Installed: the plist is on disk, so the agent is enabled to run.
    static var isActive: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Actually spawned with a live PID right now — the main app defers recording
    /// to the agent only in this state.
    ///
    /// This spawns `launchctl` and waits for it, which is far too slow to sit on
    /// the main thread: launch alone asked three times over, and each answer cost
    /// seconds. Answers are held briefly so a burst of callers costs one process,
    /// and `setEnabled` clears them so a toggle is never answered from a stale
    /// reading. Call `isRunningAsync` from anywhere that can wait.
    nonisolated(unsafe) private static var runningCache: (at: Date, value: Bool)? = nil
    nonisolated private static let runningCacheLock = NSLock()

    static func invalidateRunningCache() {
        runningCacheLock.lock(); runningCache = nil; runningCacheLock.unlock()
    }

    static var isRunning: Bool {
        runningCacheLock.lock()
        let hit = runningCache
        runningCacheLock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < 5 { return hit.value }

        let r = launchctl(["print", serviceTarget])
        let value = r.status == 0 && r.output.contains("pid = ")
        runningCacheLock.lock(); runningCache = (Date(), value); runningCacheLock.unlock()
        return value
    }

    /// The same answer, worked out off the main thread.
    static func isRunningAsync() async -> Bool {
        await Task.detached(priority: .userInitiated) { isRunning }.value
    }

    static var needsApproval: Bool { false }   // no System-Settings approval step

    /// Posted after the agent is installed or removed, so the running app can
    /// work out again who is recording live plays. Every route to that change
    /// goes through `setEnabled`, so announcing it here means no caller has to
    /// remember to.
    static let ownershipChanged = Notification.Name("com.tempo.agentOwnershipChanged")

    /// Verify the user with Touch ID / password, then install or remove the agent.
    static func setEnabled(_ on: Bool) async throws {
        try await authenticate(reason: on
            ? "turn on Tempo's always-on background scrobbler"
            : "turn off Tempo's background scrobbler")
        if on { try install() } else { uninstall() }
        invalidateRunningCache()
        NotificationCenter.default.post(name: ownershipChanged, object: nil)
    }

    private static func install() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--agent"],
            "RunAtLoad": true,           // start immediately on load AND at login
            "KeepAlive": true,           // relaunch if it exits — "always running"
            // Background, not Interactive: this helper is woken by playback
            // notifications, never by anything latency-sensitive, so full
            // scheduling priority 24/7 buys nothing — Background lets the
            // scheduler defer and coalesce its wakeups, exactly right for a
            // headless battery-conscious agent. (The menu-bar item appearing a
            // beat slower after login is a fair trade.) The default 10s
            // crash-respawn throttle is fine here too, so ThrottleInterval is
            // left at launchd's default.
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // Reload cleanly: drop any previous instance, then load and start.
        _ = launchctl(["bootout", serviceTarget])
        let r = launchctl(["bootstrap", domainTarget, plistURL.path])
        if r.status != 0 {
            _ = launchctl(["load", "-w", plistURL.path])   // fallback for older syntax
        }
        _ = launchctl(["enable", serviceTarget])
        // `kickstart` (no -k) starts it if RunAtLoad hasn't already; avoid -k so
        // we don't kill+respawn and trip launchd's ~10s respawn throttle.
        _ = launchctl(["kickstart", serviceTarget])
    }

    private static func uninstall() {
        _ = launchctl(["bootout", serviceTarget])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Full quit from the menu bar: close the UI, then stop this agent and keep
    /// launchd from respawning it — WITHOUT removing the plist (the option stays
    /// on). Opening Tempo again re-loads it via `ensureRunningIfEnabled`.
    @MainActor
    static func quitEverything() {
        let bid = Bundle.main.bundleIdentifier ?? "com.tempo.listening"
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            where app.processIdentifier != me {
            app.terminate()
        }
        _ = launchctl(["bootout", serviceTarget])   // stop us; no KeepAlive respawn
        NSApp.terminate(nil)
    }

    /// If the option is on (plist present) but the agent isn't running — e.g. it
    /// was stopped by a menu-bar Quit, or launchd has it throttled — bring it back
    /// immediately. `install()` does a full bootout+bootstrap, which resets any
    /// throttle so the menu bar appears at once. Called when the app opens.
    static func ensureRunningIfEnabled() {
        guard isActive, !isRunning else { return }
        try? install()
        // We just changed who is recording. Say so, or the app — which asks in
        // parallel with this and may well have asked first — keeps the answer it
        // got before the helper existed, and records everything twice.
        invalidateRunningCache()
        NotificationCenter.default.post(name: ownershipChanged, object: nil)
    }

    /// Best-effort removal of the old `SMAppService`-registered agent from
    /// earlier builds, so it stops failing to spawn in the background.
    static func cleanupLegacy() {
        let legacy = SMAppService.agent(plistName: "com.tempo.scrobbler.plist")
        if legacy.status == .enabled || legacy.status == .requiresApproval {
            Task { try? await legacy.unregister() }
        }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        // Drain BEFORE waiting. `launchctl print` writes several kilobytes; once
        // it fills the pipe buffer the child blocks on write while we block in
        // waitUntilExit, and neither side can move.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Touch ID with automatic password fallback.
    static func authenticate(reason: String) async throws {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw err ?? NSError(domain: "Tempo", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "This Mac can't verify your identity."])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, e in
                if ok { cont.resume() }
                else { cont.resume(throwing: e ?? NSError(domain: "Tempo", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Authentication was cancelled."])) }
            }
        }
    }
}
