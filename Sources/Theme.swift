import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// A colour theme. Brand colours (Spotify green, Last.fm red, source dots) stay
/// fixed; everything else is driven by the active palette.
struct Palette: Identifiable, Equatable {
    let id: String          // also the persisted name
    let bg: Color
    let panel: Color
    let panel2: Color
    let panel3: Color
    let accent: Color
    let text: Color
    let muted: Color
    let muted2: Color
    let gradTop: Color
    let isLight: Bool

    init(_ id: String, bg: String, panel: String, panel2: String, panel3: String,
         accent: String, text: String, muted: String, muted2: String, gradTop: String,
         isLight: Bool = false) {
        self.id = id
        self.bg = Color(hex: bg); self.panel = Color(hex: panel)
        self.panel2 = Color(hex: panel2); self.panel3 = Color(hex: panel3)
        self.accent = Color(hex: accent); self.text = Color(hex: text)
        self.muted = Color(hex: muted); self.muted2 = Color(hex: muted2)
        self.gradTop = Color(hex: gradTop); self.isLight = isLight
    }
}

enum Themes {
    static let all: [Palette] = [
        Palette("Spotify Dark", bg: "#0a0a0a", panel: "#121212", panel2: "#181818", panel3: "#1f1f1f",
                accent: "#1DB954", text: "#ffffff", muted: "#a7a7a7", muted2: "#6f6f6f", gradTop: "#1c1c22"),
        Palette("Midnight", bg: "#0a0e17", panel: "#111726", panel2: "#161d30", panel3: "#1d2740",
                accent: "#5b8cff", text: "#eef2ff", muted: "#9fb0d0", muted2: "#5d6b86", gradTop: "#1a2238"),
        Palette("Sunset", bg: "#150d10", panel: "#1d1216", panel2: "#251820", panel3: "#2f1f28",
                accent: "#ff7a59", text: "#fff1ec", muted: "#caa9a3", muted2: "#7d5f5a", gradTop: "#2a1620"),
        Palette("Forest", bg: "#0a120c", panel: "#101a12", panel2: "#15211a", panel3: "#1d2c22",
                accent: "#3ddc84", text: "#eafff0", muted: "#9cc3a9", muted2: "#5d7a67", gradTop: "#13241a"),
        Palette("Grape", bg: "#0f0a17", panel: "#160f22", panel2: "#1d1530", panel3: "#271c40",
                accent: "#b388ff", text: "#f3edff", muted: "#b3a6cf", muted2: "#6f6286", gradTop: "#1f1633"),
        Palette("Daylight", bg: "#f4f4f2", panel: "#ffffff", panel2: "#f0f0ec", panel3: "#e6e6e1",
                accent: "#1DB954", text: "#141414", muted: "#5c5c5c", muted2: "#9a9a9a", gradTop: "#eef0ee",
                isLight: true),
        // Warm, light palettes.
        Palette("Paper", bg: "#f6f1e7", panel: "#fcf8f0", panel2: "#f0eadd", panel3: "#e6decd",
                accent: "#c2683d", text: "#2a241c", muted: "#6b6155", muted2: "#9a8f7e", gradTop: "#efe8da",
                isLight: true),
        Palette("Linen", bg: "#f5f3ee", panel: "#ffffff", panel2: "#edeae2", panel3: "#e2ded4",
                accent: "#b0805a", text: "#33302a", muted: "#6e6a62", muted2: "#a19c91", gradTop: "#edeae2",
                isLight: true),
        Palette("Sunrise", bg: "#fbf0e8", panel: "#fff7f1", panel2: "#f6e6da", panel3: "#eed6c6",
                accent: "#e07856", text: "#3b2a22", muted: "#7a5e50", muted2: "#b08e7c", gradTop: "#f5e4d7",
                isLight: true),
        Palette("Sage", bg: "#f1f2ea", panel: "#fafbf4", panel2: "#e8ead4", panel3: "#daddcb",
                accent: "#6e7b4f", text: "#2c2e24", muted: "#63665a", muted2: "#969a88", gradTop: "#e9ebdf",
                isLight: true),
    ]

    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? all[0] }
}

/// Holds the active palette and persists the choice. Observed by the views so a
/// theme change re-renders the whole UI.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @Published private(set) var current: Palette
    /// Drives real font-size scaling (see `Type`) rather than a post-render
    /// `.scaleEffect`, which rasterizes text at the pre-scale size and just
    /// stretches the bitmap — that's what made zoomed text blurry.
    @Published private(set) var zoom: CGFloat
    /// Largest unit listening totals may be shown in. Lives here so every view
    /// that already re-renders on a theme or zoom change re-renders on this too.
    @Published private(set) var timeUnits: TimeUnits
    /// How empty units are handled in those totals.
    @Published private(set) var timeZeros: TimeZeros

    private init() {
        let saved = UserDefaults.standard.string(forKey: "ui.theme") ?? Themes.all[0].id
        current = Themes.named(saved)
        let savedZoom = UserDefaults.standard.double(forKey: "ui.zoom")
        zoom = (savedZoom.isFinite && savedZoom != 0) ? savedZoom.clamped(to: 0.6...1.6) : 1.0
        timeUnits = TimeUnits(rawValue: UserDefaults.standard.string(forKey: "ui.timeUnits") ?? "")
            ?? .hoursMinutes
        timeZeros = TimeZeros(rawValue: UserDefaults.standard.string(forKey: "ui.timeZeros") ?? "")
            ?? .leadSkipMonths
    }

    func setTimeZeros(_ z: TimeZeros) {
        timeZeros = z
        UserDefaults.standard.set(z.rawValue, forKey: "ui.timeZeros")
    }

    func setTimeUnits(_ u: TimeUnits) {
        timeUnits = u
        UserDefaults.standard.set(u.rawValue, forKey: "ui.timeUnits")
    }

    /// Step to the next unit format. Clicking any total in the main window runs
    /// this, so the setting is reachable without opening Settings at all.
    func cycleTimeUnits() {
        let all = TimeUnits.allCases
        let i = all.firstIndex(of: timeUnits) ?? 0
        setTimeUnits(all[(i + 1) % all.count])
    }

    func select(_ p: Palette) {
        current = p
        UserDefaults.standard.set(p.id, forKey: "ui.theme")
    }

    func setZoom(_ z: CGFloat) {
        zoom = z.isFinite ? z.clamped(to: 0.6...1.6) : 1.0
        UserDefaults.standard.set(zoom, forKey: "ui.zoom")
    }
}

/// Global colour accessors used throughout the UI. They read the active palette,
/// so swapping the theme recolours everything. (`green` kept as the name for the
/// accent to avoid touching every call site.)
enum C {
    static var bg: Color { ThemeManager.shared.current.bg }
    static var panel: Color { ThemeManager.shared.current.panel }
    static var panel2: Color { ThemeManager.shared.current.panel2 }
    static var panel3: Color { ThemeManager.shared.current.panel3 }
    static var green: Color { ThemeManager.shared.current.accent }
    static var text: Color { ThemeManager.shared.current.text }
    static var muted: Color { ThemeManager.shared.current.muted }
    static var muted2: Color { ThemeManager.shared.current.muted2 }
    static var gradTop: Color { ThemeManager.shared.current.gradTop }
    /// Hairline separators — the backbone of the editorial layout.
    static var line: Color { ThemeManager.shared.current.text.opacity(0.09) }
    static var accentSoft: Color { ThemeManager.shared.current.accent.opacity(0.14) }
}

/// Typographic system: a serif for display (New York), mono for figures
/// (SF Mono), sans for body/labels. This is what gives Tempo its own voice.
enum Type {
    static func display(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size * ThemeManager.shared.zoom, weight: w, design: .serif)
    }
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size * ThemeManager.shared.zoom, weight: w, design: .monospaced)
    }
    static func label(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font {
        .system(size: size * ThemeManager.shared.zoom, weight: w)
    }
}

extension View {
    /// Marks a view as a listening total: clicking it steps to the next unit
    /// format, the same list the Appearance tab offers.
    ///
    /// Only ever applied inside the main window. The menu-bar panel and the mini
    /// player are click-to-act surfaces — a stray click there quietly rewriting a
    /// display setting for the whole app would be a genuinely nasty surprise —
    /// so their totals are left alone.
    func cyclesTimeUnits() -> some View {
        contentShape(Rectangle())
            .onTapGesture { ThemeManager.shared.cycleTimeUnits() }
            .help("Click to switch between hours, days and years")
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SourcesSettings()
                .tabItem { Label("Sources", systemImage: "dot.radiowaves.left.and.right") }
            MenuBarSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            MiniPlayerSettings()
                .tabItem { Label("Mini Player", systemImage: "play.rectangle") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 500, height: 520)
        .background(C.bg)
    }
}

struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var bgScrobbler = BackgroundAgent.isActive
    @State private var bgBusy = false
    @State private var bgNote: String? = nil
    @AppStorage(AgentIPC.showMenuBarKey) private var agentMenuBar = true
    @AppStorage("wrapped.splitCollabs") private var splitWrapped = true
    @AppStorage("day.startHour") private var dayStartHour = 0
    @AppStorage(ScrobbleRule.modeKey) private var scrobbleRule = ScrobbleRule.Mode.standard.rawValue
    @AppStorage(ScrobbleRule.secondsKey) private var scrobbleSeconds = 120
    @AppStorage(ScrobbleRule.shareKey) private var scrobbleShare = 0.5
    @AppStorage(PlayCounting.enabledKey) private var skipShortPlays = true
    @AppStorage(PlayCounting.secondsKey) private var minPlaySeconds = 30
    @State private var dataNote: String? = nil
    @EnvironmentObject private var store: LibraryStore

    /// Reading the three @AppStorage values here (rather than only inside
    /// `ScrobbleRule`) is what makes the summary refresh as you drag the slider:
    /// SwiftUI only re-renders for values the view actually observes.
    /// Says what the switch is worth on the history actually stored.
    private var shortPlaySummary: String {
        let short = store.shortPlayCount, total = store.datedPlayCount
        guard total > 0 else { return "Nothing imported yet." }
        let pct = Int((Double(short) / Double(total) * 100).rounded())
        return skipShortPlays
            ? "Not counting \(TimeFmt.commas(short)) plays under \(minPlaySeconds)s — \(pct)% of your \(TimeFmt.commas(total)) dated plays. Their listening time still counts."
            : "\(TimeFmt.commas(short)) of your \(TimeFmt.commas(total)) dated plays are under \(minPlaySeconds)s and are being counted."
    }

    private var ruleSummary: String {
        _ = (scrobbleRule, scrobbleSeconds, scrobbleShare, skipShortPlays, minPlaySeconds)
        return ScrobbleRule.summary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch Tempo at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            // Revert the toggle if macOS refused the change.
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Brings the menu-bar scrobbler back automatically after a quit or restart, so live plays are always captured.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 6)

                Toggle("Keep scrobbling in the background", isOn: $bgScrobbler)
                    .disabled(bgBusy)
                    .onChange(of: bgScrobbler) { _, on in
                        // Ignore the echo when we revert the toggle ourselves.
                        guard on != BackgroundAgent.isActive else { return }
                        setBackground(on)
                    }
                Text("Runs a tiny background helper so your live plays keep recording even after you Quit Tempo. Turning it on asks for Touch ID or your login password.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                Toggle("Keep the menu bar display on in the background", isOn: $agentMenuBar)
                    .disabled(!bgScrobbler)
                    .padding(.top, 2)
                    .onChange(of: agentMenuBar) { _, _ in
                        // Nudge the running agent to show/hide its item immediately.
                        DistributedNotificationCenter.default().postNotificationName(
                            .init(AgentIPC.prefs), object: nil, userInfo: nil, deliverImmediately: true)
                    }
                Text("Shows Tempo's now-playing item in the menu bar even while the app is closed. When the app is open, its own menu bar item is used instead.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                if let note = bgNote {
                    Text(note).font(.system(size: 11)).foregroundColor(.orange)
                }

                Divider().padding(.vertical, 6)

                Toggle("Split collaborations in Wrapped", isOn: $splitWrapped)
                Text("Counts each artist on a collaboration separately in your Wrapped stats — so a feature credits both artists, not the combined tag.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                HStack(spacing: 10) {
                    Text("A new day starts at").font(.system(size: 13))
                    Picker("", selection: $dayStartHour) {
                        Text("Midnight").tag(0)
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { h in Text("\(h)am").tag(h) }
                    }.labelsHidden().frame(width: 120)
                }.padding(.top, 6)
                Text("Music played after midnight still counts toward the previous day — handy if you listen late.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 6)

                Text("What counts as a play").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                Picker("", selection: $scrobbleRule) {
                    ForEach(ScrobbleRule.Mode.allCases) { m in Text(m.label).tag(m.rawValue) }
                }
                .pickerStyle(.radioGroup).labelsHidden()

                if ScrobbleRule.Mode(rawValue: scrobbleRule) == .time {
                    HStack(spacing: 10) {
                        Text("Count it after").font(.system(size: 13))
                        Picker("", selection: $scrobbleSeconds) {
                            ForEach([15, 30, 60, 90, 120, 180, 240, 300], id: \.self) { s in
                                // Only whole minutes are worded as minutes — 90 through
                            // integer division read as "1 minutes".
                            Text(s % 60 == 0 ? "\(s / 60) minute\(s == 60 ? "" : "s")" : "\(s) seconds").tag(s)
                            }
                        }.labelsHidden().frame(width: 140)
                    }.padding(.top, 2)
                }
                if ScrobbleRule.Mode(rawValue: scrobbleRule) == .share {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Count it after \(Int((scrobbleShare * 100).rounded()))% of the track")
                            .font(.system(size: 13))
                        Slider(value: $scrobbleShare, in: 0.1...1.0, step: 0.05)
                    }.padding(.top, 2)
                }

                // Recomputed from the live values, so the wording always describes
                // what the scrobbler will actually do.
                Text(ruleSummary)
                    .font(.system(size: 12)).foregroundColor(C.muted2)
                Text("Applies to Tempo's own live scrobbler, including when it runs in the background. Plays pulled from Last.fm or Spotify arrive already counted by them, so this doesn't change those.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 6)

                Text("Imported plays").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                Toggle(isOn: $skipShortPlays) {
                    Text("Don't count very short plays").font(.system(size: 13))
                }
                .onChange(of: skipShortPlays) { _, _ in store.invalidateDerived() }
                if skipShortPlays {
                    HStack(spacing: 10) {
                        Text("Shorter than").font(.system(size: 13))
                        Picker("", selection: $minPlaySeconds) {
                            ForEach(PlayCounting.choices, id: \.self) { Text("\($0) seconds").tag($0) }
                        }.labelsHidden().frame(width: 140)
                    }
                    .onChange(of: minPlaySeconds) { _, _ in store.invalidateDerived() }
                }
                Text(shortPlaySummary)
                    .font(.system(size: 12)).foregroundColor(C.muted2)
                Text("A Spotify export logs one row per stream with no minimum, so skipping a few seconds into a track files a play just like hearing it through. Those streams keep their listening time either way — this only decides whether they count as plays.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 6)

                HStack(spacing: 10) {
                    Button("Back Up History…") { backup() }
                    Button("Restore…") { restore() }
                    Button("Export CSV…") { exportCSV() }
                    if let n = dataNote {
                        Text(n).font(.system(size: 11)).foregroundColor(C.muted2)
                    }
                }
                Text("Your live scrobbles can't be re-downloaded from anywhere — keep a copy of history.json somewhere safe.")
                    .font(.system(size: 12)).foregroundColor(C.muted2)

                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            bgScrobbler = BackgroundAgent.isActive
        }
    }

    /// Copy history.json somewhere the user chooses.
    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tempo history \(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).json"
        panel.canCreateDirectories = true
        panel.title = "Back up listening history"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: Persistence.historyURL, to: dest)
            dataNote = "Backed up."
        } catch {
            dataNote = "Backup failed: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Tempo history.csv"
        panel.title = "Export listening history"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.historyCSV().write(to: url, atomically: true, encoding: .utf8)
            dataNote = "Exported."
        } catch { dataNote = "Export failed: \(error.localizedDescription)" }
    }

    /// Merge a backup back in. Merging (rather than overwriting) means restoring
    /// an old file can only ever add plays back, never delete newer ones.
    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Restore listening history"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        guard let data = try? Data(contentsOf: src),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else {
            dataNote = "That doesn't look like a Tempo history file."
            return
        }
        let added = store.restoreHistory(tracks)
        dataNote = added > 0 ? "Restored \(TimeFmt.commas(added)) plays." : "Nothing new to restore."
    }

    private func setBackground(_ on: Bool) {
        bgBusy = true; bgNote = nil
        Task {
            do {
                try await BackgroundAgent.setEnabled(on)
                // Give launchd a moment, then confirm it actually spawned.
                if on {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !BackgroundAgent.isRunning {
                        bgNote = "Enabled, but the helper didn't start. Check Console for “\(BackgroundAgent.label)”."
                    }
                }
            } catch {
                bgNote = on
                    ? "Couldn't turn it on: \(error.localizedDescription)"
                    : "Couldn't turn it off: \(error.localizedDescription)"
            }
            bgScrobbler = BackgroundAgent.isActive   // reflect the real state
            bgBusy = false
        }
    }
}

struct SourcesSettings: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var spotify = SpotifyAuth.shared
    @State private var showImporter = false
    @AppStorage("lastfm.user") private var lfUser = ""
    @AppStorage("lastfm.key") private var lfKey = ""
    @AppStorage("spotify.clientid") private var spClient = ""
    @AppStorage("sync.interval") private var syncInterval = 0

    private let intervals: [(String, Int)] = [
        ("Off", 0), ("30 seconds", 30), ("1 minute", 60),
        ("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Apple Music / local library
                section("Music library") {
                    HStack(spacing: 8) {
                        if case .loaded(let n) = store.status {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(C.green)
                            Text("\(TimeFmt.commas(n)) tracks loaded").font(.system(size: 12))
                        } else {
                            Text("Reading library…").font(.system(size: 12)).foregroundColor(C.muted)
                        }
                        Spacer()
                        Button("Refresh") { store.load() }
                    }
                    Text("Read live from the Music app (real play counts & durations).")
                        .font(.system(size: 11)).foregroundColor(C.muted2)
                }

                // Auto refresh
                section("Auto-refresh sources") {
                    Picker("Every", selection: $syncInterval) {
                        ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.menu).frame(width: 200)
                    .onChange(of: syncInterval) { _, _ in store.applyAutoRefresh() }
                    Text("How often to pull new plays from Spotify & Last.fm in the background. Live scrobbling always runs regardless.")
                        .font(.system(size: 11)).foregroundColor(C.muted2)
                }

                // Spotify
                section("Spotify") {
                    if spotify.connected {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundColor(Color(hex: "#1DB954"))
                            if store.spotifyPlays > 0 { Text("· \(TimeFmt.commas(store.spotifyPlays)) plays").foregroundColor(C.muted) }
                            Spacer()
                            Button("Sync now") { store.syncSpotify() }
                            Button("Disconnect") { spotify.disconnect() }
                        }.font(.system(size: 12))
                    } else {
                        TextField("Client ID", text: $spClient).textFieldStyle(.roundedBorder)
                        Text("Redirect URI to add in your Spotify app: \(SpotifyAuth.redirectURI)")
                            .font(.system(size: 10)).foregroundColor(C.muted2).textSelection(.enabled)
                        Button("Connect Spotify") {
                            Task { await spotify.connect(); if spotify.connected { store.syncSpotify() } }
                        }.disabled(spClient.isEmpty)
                    }
                    Button("Import old export (one-time)…") { showImporter = true }
                        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { r in
                            if case .success(let urls) = r { store.importSpotify(urls: urls) }
                        }
                    if let s = store.spotifyStatus ?? spotify.status {
                        Text(s).font(.system(size: 11)).foregroundColor(C.muted)
                    }
                }

                // Last.fm
                section("Last.fm") {
                    TextField("username", text: $lfUser).textFieldStyle(.roundedBorder)
                    SecureField("API key", text: $lfKey).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Free key at last.fm/api/account/create").font(.system(size: 10)).foregroundColor(C.muted2)
                        Spacer()
                        Button("Sync Last.fm") { store.syncLastFM(user: lfUser, apiKey: lfKey) }
                        // Normal syncs only fetch what's new. A full re-pull is
                        // the way to pick up scrobbles you edited or deleted on
                        // Last.fm itself.
                        Button("Full Resync") { store.syncLastFM(user: lfUser, apiKey: lfKey, fullResync: true) }
                            .help("Re-download your entire scrobble history")
                            .disabled(lfUser.isEmpty || lfKey.isEmpty)
                    }
                    if let s = store.lastfmStatus { Text(s).font(.system(size: 11)).foregroundColor(C.muted) }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1).foregroundColor(C.muted2)
            content()
        }
    }
}

struct MenuBarSettings: View {
    @AppStorage("mb.showTitle") private var showTitle = true
    @AppStorage("mb.showArtist") private var showArtist = true
    @AppStorage("mb.showCover") private var showCover = true
    @AppStorage("mb.showTodayIdle") private var showTodayIdle = true
    @AppStorage("mb.maxChars") private var maxChars = 36.0
    @AppStorage("mb.style") private var style = "panel"
    @AppStorage("mb.showProgress") private var showProgress = true
    @AppStorage(AgentIPC.scrollVolumeKey) private var scrollVolume = true
    @AppStorage(Notify.nowPlayingKey) private var notifyNowPlaying = false
    @AppStorage(Notify.milestonesKey) private var notifyMilestones = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("When you click the menu bar icon, show:")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(C.muted)
                Picker("", selection: $style) {
                    Text("Now-playing panel").tag("panel")
                    Text("Simple menu").tag("menu")
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .onChange(of: style) { _, _ in notifyAgent() }
                Text("The panel shows a large cover and controls, like the old menu; the simple menu is a compact dropdown.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 4)

                Text("What the menu bar shows while music is playing:")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(C.muted)
                Toggle("Album cover", isOn: $showCover).onChange(of: showCover) { _, _ in notifyAgent() }
                Toggle("Song title", isOn: $showTitle).onChange(of: showTitle) { _, _ in notifyAgent() }
                Toggle("Artist name", isOn: $showArtist).onChange(of: showArtist) { _, _ in notifyAgent() }

                Divider().padding(.vertical, 4)

                Toggle("Show today's total when nothing is playing", isOn: $showTodayIdle)
                    .onChange(of: showTodayIdle) { _, _ in notifyAgent() }

                Toggle("Show playback progress on the icon", isOn: $showProgress)
                    .onChange(of: showProgress) { _, _ in notifyAgent() }
                Text("Draws a thin progress line under the album cover. Middle-click the item to play/pause, ⌘-click to jump to Wrapped.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Toggle("Scroll over the menu bar item to change volume", isOn: $scrollVolume)
                    .onChange(of: scrollVolume) { _, _ in notifyAgent() }
                Text("Handy, but the item sits at the top of the screen — so a scroll that drifts over it changes your volume with no click and no warning, and downwards is the direction that turns it down. Turn this off if your volume keeps moving on its own.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 4)

                Text("The mini player has its own settings tab.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 4)

                Toggle("Notify me when the track changes", isOn: $notifyNowPlaying)
                Toggle("Notify me about milestones", isOn: $notifyMilestones)
                Text("Milestones are round numbers worth noticing — your 100th, 500th or 1,000th play of an artist. macOS will ask permission the first time.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Maximum text length: \(Int(maxChars)) characters")
                        .font(.system(size: 12)).foregroundColor(C.muted)
                    Slider(value: $maxChars, in: 16...80, step: 2)
                        .onChange(of: maxChars) { _, _ in notifyAgent() }
                }.padding(.top, 4)

                Text("Longer titles are shortened with an ellipsis so the menu bar stays tidy. Live scrobbling keeps running whenever Tempo is open, regardless of these display options.")
                    .font(.system(size: 11)).foregroundColor(C.muted2).padding(.top, 4)
                Spacer()
            }
            .toggleStyle(.switch)
            .padding(20)
        }
    }

    /// Tell the running background agent to re-render its menu bar item now.
    private func notifyAgent() {
        DistributedNotificationCenter.default().postNotificationName(
            .init(AgentIPC.prefs), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// Everything about the floating mini player, gathered in one place rather than
/// tacked onto the end of the menu-bar options — it's a window of its own, not
/// a menu-bar display setting.
struct MiniPlayerSettings: View {
    @AppStorage(Mini.enabledKey) private var miniOn = false
    @AppStorage(Mini.styleKey) private var style = Mini.Style.vinyl.rawValue
    @AppStorage(Mini.animateKey) private var animate = true
    @AppStorage(Mini.controlsKey) private var controls = Mini.Controls.hover.rawValue
    @AppStorage(Mini.layoutKey) private var layout = Mini.Layout.centred.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Show the mini player", isOn: $miniOn)
                    .onChange(of: miniOn) { _, on in MiniPlayerController.requestShow(on) }
                Text("A small window that floats above everything else. Drag it anywhere, resize it to any size. ⇧⌘M toggles it.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 4)

                Text("Style").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                Picker("", selection: $style) {
                    ForEach(Mini.Style.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .onChange(of: style) { _, _ in apply() }
                Text(Mini.Style(rawValue: style)?.blurb ?? "")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Toggle("Animate it while music plays", isOn: $animate)
                Text("The record spins and the tape reels turn in time with playback. Turn this off if you'd rather it sat still.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 4)

                Text("Control strip").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                Picker("", selection: $controls) {
                    ForEach(Mini.Controls.allCases) { c in Text(c.label).tag(c.rawValue) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .onChange(of: controls) { _, _ in apply() }
                Text("The back / play / skip buttons that sit over the artwork. Hidden by default so the player is just the cover until you reach for it; pin them on to keep them in view.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                if Mini.Style(rawValue: style) == .vinyl {
                    Divider().padding(.vertical, 4)

                    Text("Tall windows").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                    Picker("", selection: $layout) {
                        ForEach(Mini.Layout.allCases) { l in Text(l.label).tag(l.rawValue) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    .onChange(of: layout) { _, _ in apply() }
                    Text("The record is square, so a window taller than it is wide has height to spare. Keep them together and the pair sits centred; spread them and the title drops to the bottom edge.")
                        .font(.system(size: 11)).foregroundColor(C.muted2)

                    Divider().padding(.vertical, 4)
                    Text("Working the deck").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                    Text("Turn the record to scrub — clockwise winds the song forward, anticlockwise back. Drag the tonearm to move through the track, or lift it off the record to pause; it stays where you leave it until you drop it back on.")
                        .font(.system(size: 11)).foregroundColor(C.muted2)
                }
                Spacer()
            }
            .toggleStyle(.switch)
            .padding(20)
        }
    }

    /// The window may be hosted by the background helper, so the change has to
    /// travel to the other process as well as being applied here.
    private func apply() {
        DistributedNotificationCenter.default().postNotificationName(
            .init(AgentIPC.prefs), object: nil, userInfo: nil, deliverImmediately: true)
        MiniPlayerController.shared.handlePrefsChanged()
    }
}

struct AppearanceSettings: View {
    @ObservedObject private var theme = ThemeManager.shared

    private let cols = [GridItem(.adaptive(minimum: 130), spacing: 12)]
    /// 42 minutes, 4½ hours, 42 days and a year and ten days — chosen so every
    /// option visibly differs from the others in the preview row.
    private static let samples = [2_520_000, 16_200_000, 3_628_800_000, 32_400_000_000]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(Themes.all) { p in
                        ThemeSwatch(palette: p, selected: theme.current.id == p.id)
                            .onTapGesture { theme.select(p) }
                    }
                }

                Divider().padding(.vertical, 6)

                Text("Zoom").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                HStack(spacing: 14) {
                    Button("–") { theme.setZoom(theme.zoom - 0.1) }
                    Text("\(Int((theme.zoom * 100).rounded()))%").font(.system(size: 14, weight: .semibold)).frame(width: 56)
                    Button("+") { theme.setZoom(theme.zoom + 0.1) }
                    Button("Reset") { theme.setZoom(1.0) }
                    Spacer()
                }
                Text("Also: ⌘+ to zoom in, ⌘– to zoom out, ⌘0 to reset.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)

                Divider().padding(.vertical, 6)

                Text("Listening time").font(.system(size: 13, weight: .bold)).foregroundColor(C.muted)
                Picker("", selection: Binding(get: { theme.timeUnits },
                                              set: { theme.setTimeUnits($0) })) {
                    ForEach(TimeUnits.allCases) { u in Text(u.label).tag(u) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if theme.timeUnits != .hoursMinutes {
                    Text("Empty units").font(.system(size: 12, weight: .semibold)).foregroundColor(C.muted)
                        .padding(.top, 2)
                    Picker("", selection: Binding(get: { theme.timeZeros.resolved(for: theme.timeUnits) },
                                                  set: { theme.setTimeZeros($0) })) {
                        ForEach(TimeZeros.options(for: theme.timeUnits)) { z in Text(z.label).tag(z) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                HStack(spacing: 8) {
                    ForEach(Self.samples, id: \.self) { ms in
                        Text(TimeFmt.short(ms, units: theme.timeUnits, zeros: theme.timeZeros))
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(C.panel2))
                    }
                }
                Text("Applies everywhere a total is shown — songs, artists, albums, Wrapped and the menu bar. Totals under a day are unaffected. A month counts as 30 days and a year as 365. Some choices only appear under years and months, where there's a larger unit for them to act on.")
                    .font(.system(size: 11)).foregroundColor(C.muted2)
            }
            .padding(20)
        }
    }
}

struct ThemeSwatch: View {
    let palette: Palette
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8).fill(palette.bg)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(palette.panel2).frame(width: 34, height: 22)
                    Circle().fill(palette.accent).frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 2).fill(palette.text).frame(width: 20, height: 5)
                }.padding(8)
            }
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? palette.accent : Color.gray.opacity(0.3), lineWidth: selected ? 2.5 : 1))

            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(palette.accent).font(.system(size: 11)) }
                Text(palette.id).font(.system(size: 12, weight: selected ? .bold : .regular))
            }
        }
    }
}
