import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// The main window app is an ordinary windowed app: it fully quits when you
/// close its window or choose Quit — no Dock icon or Cmd-Tab entry left behind.
/// The always-on background presence (menu bar + scrobbling after quit) lives
/// entirely in the separate, invisible launchd agent (see `AgentDelegate`), so
/// quitting here leaves nothing but that agent's menu-bar item.
extension Notification.Name {
    /// Posted by the ⌘F menu command; the center panel's search field listens.
    static let tempoFocusSearch = Notification.Name("com.tempo.focusSearch")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Fully quit when the window is closed — otherwise the app lingers as a
    /// windowless process, and reopening it just "activates" that ghost so no
    /// window ever appears.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ note: Notification) {
        BackgroundAgent.cleanupLegacy()   // remove the old SMAppService agent, if any
        // The menu-bar helper hands mini-player duty to us while we're running.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(miniRequest(_:)), name: .init(AgentIPC.toggleMini), object: nil)
        dnc.addObserver(self, selector: #selector(miniPrefs), name: .init(AgentIPC.prefs), object: nil)
        MiniPlayerController.shared.restoreIfEnabled()
    }

    /// While the app is running it is the preferred host for the mini player.
    @objc private func miniRequest(_ note: Notification) {
        let show = (note.userInfo?["show"] as? String).map { $0 == "1" }
        Task { @MainActor in
            MiniPlayerController.shared.handleRequest(show: show, preferredHost: true)
        }
    }
    @objc private func miniPrefs() {
        Task { @MainActor in MiniPlayerController.shared.handlePrefsChanged() }
    }
    func applicationWillTerminate(_ note: Notification) {
        // Let the background agent know we're gone, so it (re)shows its menu-bar
        // item and ignores the spurious reopen macOS fires the instant we quit.
        DistributedNotificationCenter.default().postNotificationName(
            .init(AgentIPC.uiDown), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

struct TempoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("view.showSidebar") private var showSidebar = true
    @AppStorage("view.showDetail") private var showDetail = true
    // Mirrors of the view-mode state so the menu bar can drive ⌘1–⌘5.
    @AppStorage("view.groupBy") private var groupByRaw = GroupBy.artist.rawValue
    @AppStorage("view.showHistory") private var showHistory = false
    @AppStorage("view.showWrapped") private var showWrapped = false

    private func show(_ g: GroupBy) { groupByRaw = g.rawValue; showHistory = false; showWrapped = false }

    var body: some Scene {
        WindowGroup("Tempo", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    store.bootstrap()
                    NSApp.setActivationPolicy(.regular)   // window open → normal Dock app
                    NSApp.activate(ignoringOtherApps: true)
                }
                .preferredColorScheme(theme.current.isLight ? .light : .dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { theme.setZoom(theme.zoom + 0.1) }.keyboardShortcut("+", modifiers: .command)
                // Cmd+= (zoom-in without Shift) maps to the same action, hidden from the menu.
                Button("") { theme.setZoom(theme.zoom + 0.1) }.keyboardShortcut("=", modifiers: .command).hidden()
                Button("Zoom Out") { theme.setZoom(theme.zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { theme.setZoom(1.0) }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button(showSidebar ? "Hide Sidebar Column" : "Show Sidebar Column") { showSidebar.toggle() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button(showDetail ? "Hide Detail Column" : "Show Detail Column") { showDetail.toggle() }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button("Artists")  { show(.artist) }.keyboardShortcut("1", modifiers: .command)
                Button("Sources")  { show(.app) }.keyboardShortcut("2", modifiers: .command)
                Button("Songs")    { show(.song) }.keyboardShortcut("3", modifiers: .command)
                Button("Albums")   { show(.album) }.keyboardShortcut("4", modifiers: .command)
                Button("History")  { showHistory = true; showWrapped = false }.keyboardShortcut("5", modifiers: .command)
                Button("Wrapped")  { showWrapped = true; showHistory = false }.keyboardShortcut("6", modifiers: .command)
                Divider()
                Button("Mini Player") { MiniPlayerController.requestToggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
            }
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .tempoFocusSearch, object: nil)
                }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Sync Sources Now") { store.syncNow() }.keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(store)
                .preferredColorScheme(theme.current.isLight ? .light : .dark)
        }
        // No MenuBarExtra here on purpose: a MenuBarExtra scene would keep this
        // windowed app alive (and in the menu bar) after its window closes,
        // which is exactly the lingering second process we want to avoid. The
        // menu bar is provided solely by the background agent when enabled.
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

struct ContentView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @EnvironmentObject var store: LibraryStore
    // Enums are stored as their raw String — the RawRepresentable @AppStorage
    // overload silently fails to persist here, but plain String always works.
    @AppStorage("view.groupBy") private var groupByRaw = GroupBy.artist.rawValue
    @AppStorage("view.sortBy") private var sortByRaw = SortBy.time.rawValue
    @State private var sourceFilter: Source? = nil
    @State private var search = ""
    @State private var selected: String? = nil
    @AppStorage("view.split") private var splitCollabs = false
    @State private var range: TimeRange = .allTime
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var customTo = Date()

    private var groupBy: Binding<GroupBy> {
        Binding(get: { GroupBy(rawValue: groupByRaw) ?? .artist }, set: { groupByRaw = $0.rawValue })
    }
    private var sortBy: Binding<SortBy> {
        Binding(get: { SortBy(rawValue: sortByRaw) ?? .time }, set: { sortByRaw = $0.rawValue })
    }

    @AppStorage("view.showSidebar") private var showSidebar = true
    @AppStorage("view.showDetail") private var showDetail = true
    @AppStorage("view.showHistory") private var showHistory = false
    @AppStorage("view.showWrapped") private var showWrapped = false

    // Zoom scales real font sizes (see `Type` in Theme.swift), driven by
    // ThemeManager.zoom — not a `.scaleEffect` transform. Transform-based
    // zoom rasterizes text at the pre-scale size and stretches the bitmap,
    // which is what made zoomed text blurry. Scaling the actual point sizes
    // means every zoom level renders at native resolution. The split panels'
    // minWidths below are left untouched by zoom on purpose: dynamically
    // resizing an NSSplitView subview's Auto Layout constraints in the same
    // transaction as resizing the split view's own frame previously sent
    // AppKit into a reentrant constraint crash — since zoom no longer
    // resizes any outer frame, that failure mode no longer applies.
    /// Shown once, ever. Stored rather than inferred from "is there data yet?" so
    /// it never reappears on a quiet week.
    @AppStorage("app.hasOnboarded") private var hasOnboarded = false

    var body: some View {
        if hasOnboarded {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                NowPlayingBar()
            }
            .background(C.bg.ignoresSafeArea())
        } else {
            WelcomeView { hasOnboarded = true }
        }
    }

    private var content: some View {
        // Flat panes on one surface, divided by the split view's hairline —
        // still resizable, but no floating cards.
        HSplitView {
            if showSidebar {
                Sidebar(groupBy: groupBy, showHistory: $showHistory, showWrapped: $showWrapped)
                    .frame(minWidth: 190, idealWidth: 210, maxWidth: 300)
            }
            CenterPanel(groupBy: groupBy, sortBy: sortBy, sourceFilter: $sourceFilter,
                        search: $search, selected: $selected, splitCollabs: $splitCollabs,
                        range: $range, customFrom: $customFrom, customTo: $customTo,
                        showHistory: $showHistory, showWrapped: $showWrapped)
                .frame(minWidth: 460, maxWidth: .infinity)
                .layoutPriority(1)
            if showDetail {
                DetailPanel(groupBy: groupBy.wrappedValue, sourceFilter: sourceFilter, search: search,
                            selected: selected, splitCollabs: splitCollabs, range: range, sortBy: sortBy.wrappedValue)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
            }
        }
        .background(C.bg.ignoresSafeArea())
    }
}

// MARK: - Sidebar
struct Sidebar: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var theme = ThemeManager.shared   // re-render on theme change
    @Binding var groupBy: GroupBy
    @Binding var showHistory: Bool
    @Binding var showWrapped: Bool
    @State private var taps = 0
    @State private var secret = false

    private var inList: Bool { !showHistory && !showWrapped }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Serif wordmark, cleared below the traffic lights.
            Text(secret ? "Tempo ♪" : "Tempo")
                .font(Type.display(26, .medium))
                .foregroundColor(secret ? C.green : C.text)
                .padding(.top, 30).padding(.bottom, 34).padding(.leading, 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    taps += 1
                    if taps >= 7 { secret = true }
                }
                .help(secret ? "Made for the love of listening." : "")

            Text("VIEW").font(Type.mono(10, .medium)).tracking(2)
                .foregroundColor(C.muted2).padding(.leading, 22).padding(.bottom, 10)

            ForEach(GroupBy.allCases) { g in
                navItem(g.title, active: inList && groupBy == g) {
                    groupBy = g; showHistory = false; showWrapped = false
                }
            }
            navItem("History", active: showHistory) { showHistory = true; showWrapped = false }
            navItem("Wrapped", active: showWrapped) { showWrapped = true; showHistory = false }

            Spacer()
            footer.padding(.leading, 22).padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func navItem(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle()   // active marker
                    .fill(active ? C.green : .clear)
                    .frame(width: 2)
                Text(title)
                    .font(Type.display(19, active ? .medium : .regular))
                    .foregroundColor(active ? C.text : C.muted)
                    .padding(.leading, 20)
                Spacer()
            }
            .frame(height: 34 * theme.zoom)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 7) {
            if secret {
                Text("♪ made for the love of listening")
                    .font(Type.mono(10)).foregroundColor(C.green)
            } else if (1...4).contains(Calendar.current.component(.hour, from: Date())) {
                // Small hours: a little company.
                Text("🦉 you're still up").font(Type.mono(10)).foregroundColor(C.muted2)
            } else if case .loaded(let n) = store.status {
                Circle().fill(C.green).frame(width: 5, height: 5)
                Text("\(TimeFmt.commas(n)) tracks").font(Type.mono(10)).foregroundColor(C.muted2)
            } else if case .denied = store.status {
                Image(systemName: "lock.fill").foregroundColor(.orange).font(.system(size: 9 * ThemeManager.shared.zoom))
                Text("Music access needed").font(Type.mono(10)).foregroundColor(C.muted2)
            } else {
                Text("reading library…").font(Type.mono(10)).foregroundColor(C.muted2)
            }
        }
    }
}

// Old sidebar-embedded source controls now live in Settings → Sources.
// MARK: - Center
struct CenterPanel: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var theme = ThemeManager.shared   // re-render on theme change
    @Binding var groupBy: GroupBy
    @Binding var sortBy: SortBy
    @Binding var sourceFilter: Source?
    @Binding var search: String
    @Binding var selected: String?
    @Binding var splitCollabs: Bool
    @Binding var range: TimeRange
    @Binding var customFrom: Date
    @Binding var customTo: Date
    @Binding var showHistory: Bool
    @Binding var showWrapped: Bool
    @State private var showCustom = false
    @State private var arrowMonitor: Any? = nil
    @State private var arrowRows: [String] = []
    @State private var historyLimit = 300
    @FocusState private var searchFocused: Bool
    @AppStorage("view.showSidebar") private var showSidebar = true
    @AppStorage("view.showDetail") private var showDetail = true

    /// Nothing to show and nothing configured — a brand new install.
    private var needsOnboarding: Bool {
        let d = UserDefaults.standard
        let hasLastFM = !(d.string(forKey: "lastfm.user") ?? "").isEmpty
        return !store.hasTracks && !hasLastFM && !SpotifyAuth.shared.connected
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                topBar
                if needsOnboarding { welcome }
                else if showWrapped { WrappedPanel() }
                else if showHistory { historyList }
                else { statsList }
            }
            .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 40)
            .background(ScrollPositionKeeper(key: viewKey).frame(width: 0, height: 0))
        }
        .background(C.bg)
    }

    /// Identifies the current view for scroll-position memory.
    private var viewKey: String {
        showWrapped ? "wrapped" : (showHistory ? "history" : "list.\(groupBy.rawValue)")
    }

    /// First run: say what Tempo is and give one button per way to start,
    /// instead of an empty window and a Settings hunt.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("WELCOME").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.green)
                Text("Let's find your listening").font(Type.display(38, .medium)).foregroundColor(C.text)
                Text("Tempo totals up how long you've actually listened — by artist, by song, by source.")
                    .font(Type.mono(12)).foregroundColor(C.muted).lineSpacing(3)
            }
            VStack(alignment: .leading, spacing: 12) {
                onboardStep("1", "Your Mac's music library",
                            "Apple Music and local files are read automatically — grant access if macOS asks.",
                            !store.hasTracks ? nil : "Found \(TimeFmt.commas(store.trackCount)) tracks")
                onboardStep("2", "Connect Last.fm",
                            "Brings in every scrobble with an exact timestamp — including listening on your phone.", nil)
                onboardStep("3", "Connect Spotify",
                            "Pulls your recently played straight from your account.", nil)
            }
            SettingsLink {
                Text("Open Settings → Sources")
                    .font(Type.mono(12, .semibold)).foregroundColor(C.bg)
                    .padding(.vertical, 10).padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 9).fill(C.green))
            }.buttonStyle(.plain)
            Text("Tempo also records what you play on this Mac from now on, all on its own.")
                .font(Type.mono(10)).foregroundColor(C.muted2)
        }
        .padding(.top, 10)
    }

    private func onboardStep(_ n: String, _ title: String, _ body: String, _ done: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n).font(Type.mono(11, .medium)).foregroundColor(C.muted2)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(C.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Type.display(16, .medium)).foregroundColor(C.text)
                Text(body).font(Type.mono(10)).foregroundColor(C.muted2).lineSpacing(2)
                if let d = done { Text("✓ \(d)").font(Type.mono(10)).foregroundColor(C.green) }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(C.panel))
    }

    // The existing grouped view (Artists / Apps / Songs).
    @ViewBuilder private var statsList: some View {
        let bk = buckets
        let maxMs = bk.first?.totalMs ?? 1
        keyboardNav(bk)
        header
        VStack(alignment: .leading, spacing: 16) {
            timescale
            chips
        }
        controls
        approximateNote
        Rectangle().fill(C.line).frame(height: 1)   // hairline above list
        LazyVStack(alignment: .leading, spacing: 0) {
            listHeader(count: bk.count)
            ForEach(Array(bk.enumerated()), id: \.element.id) { i, b in
                Row(index: i + 1, bucket: b, groupBy: groupBy, maxMs: maxMs,
                    selected: selected == b.id) { selected = b.id; showDetail = true }
            }
            if bk.isEmpty { emptyState }
        }
    }

    // Reverse-chronological list of individual plays.
    @ViewBuilder private var historyList: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = store.witnessedPlays.filter { t in
            q.isEmpty || "\(t.title) \(store.displayTitle(for: t)) \(t.artist) \(store.displayArtist(for: t)) \(t.album)"
                .lowercased().contains(q)
        }
        let plays = Array(matching.prefix(historyLimit))
        VStack(alignment: .leading, spacing: 8) {
            Text("HISTORY").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2)
            Text("Recently played").font(Type.display(40, .medium)).foregroundColor(C.text)
            Text("\(TimeFmt.commas(matching.count)) play\(matching.count == 1 ? "" : "s") with an exact timestamp, newest first.")
                .font(Type.mono(11)).foregroundColor(C.muted)
        }
        onThisDay
        Rectangle().fill(C.line).frame(height: 1)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(plays) { t in HistoryRow(track: t) }
            if matching.count > plays.count {
                Button {
                    historyLimit += 500
                } label: {
                    Text("Show \(TimeFmt.commas(min(500, matching.count - plays.count))) more")
                        .font(Type.mono(11, .semibold)).foregroundColor(C.green)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if plays.isEmpty {
                VStack(spacing: 8) {
                    Text("No plays recorded yet.")
                        .font(Type.display(15)).foregroundColor(C.muted2)
                    Text("Live scrobbles and Last.fm / Spotify history will appear here.")
                        .font(Type.mono(11)).foregroundColor(C.muted2)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            }
        }
    }

    /// ↑/↓ walk the list and open each row in the detail panel; ⎋ clears the
    /// selection. Typing in the search field is left alone.
    @ViewBuilder private func keyboardNav(_ bk: [Bucket]) -> some View {
        Color.clear.frame(height: 0)
            .onAppear { installArrowKeys(bk) }
            .onChange(of: bk.map(\.id)) { _, _ in installArrowKeys(bk) }
            .onDisappear {
                // Local monitors outlive the view unless removed, and a second
                // one would move the selection twice per keypress.
                if let m = arrowMonitor { NSEvent.removeMonitor(m); arrowMonitor = nil }
            }
    }

    private func installArrowKeys(_ bk: [Bucket]) {
        arrowRows = bk.map(\.id)
        guard arrowMonitor == nil else { return }
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Don't steal keys from a text field.
            if NSApp.keyWindow?.firstResponder is NSTextView { return e }
            let ids = arrowRows
            guard !ids.isEmpty else { return e }
            switch e.keyCode {
            case 125, 126:                                    // down, up
                let step = e.keyCode == 125 ? 1 : -1
                let cur = selected.flatMap { ids.firstIndex(of: $0) } ?? -1
                let next = max(0, min(ids.count - 1, cur + step))
                selected = ids[next]
                showDetail = true
                return nil
            case 53:                                           // esc
                if selected != nil { selected = nil; return nil }
                return e
            default: return e
            }
        }
    }

    /// Nostalgia hook: the same calendar day in previous years.
    @ViewBuilder private var onThisDay: some View {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day], from: Date())
        let thisYear = cal.component(.year, from: Date())
        let past = store.witnessedPlays.filter { t in
            guard let d = t.lastPlayed else { return false }
            let c = cal.dateComponents([.month, .day, .year], from: d)
            return c.month == today.month && c.day == today.day && (c.year ?? thisYear) < thisYear
        }
        if !past.isEmpty {
            let years = Set(past.compactMap { $0.lastPlayed.map { cal.component(.year, from: $0) } }).sorted(by: >)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("ON THIS DAY").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.green)
                    Text(years.map(String.init).joined(separator: " · "))
                        .font(Type.mono(10)).foregroundColor(C.muted2)
                }
                ForEach(past.prefix(3)) { t in
                    HStack(spacing: 10) {
                        Text(store.displayTitle(for: t)).font(Type.display(15, .medium)).foregroundColor(C.text).lineLimit(1)
                        Text(store.displayArtist(for: t)).font(Type.mono(10)).foregroundColor(C.muted2).lineLimit(1)
                        Spacer()
                        if let d = t.lastPlayed {
                            Text(d.formatted(.dateTime.year())).font(Type.mono(10)).foregroundColor(C.muted)
                        }
                    }
                    .contextMenu { TrackActions.menu(title: store.displayTitle(for: t), artist: store.displayArtist(for: t), groupBy: .song) }
                }
                if past.count > 3 {
                    Text("+ \(past.count - 3) more that day").font(Type.mono(9)).foregroundColor(C.muted2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(C.green.opacity(0.08)))
        }
    }

    // Always-visible top strip: column toggles + settings gear.
    private var topBar: some View {
        HStack(spacing: 14) {
            Button { showSidebar.toggle() } label: {
                Image(systemName: "sidebar.left").foregroundColor(showSidebar ? C.muted : C.muted2)
            }.buttonStyle(.plain).help("Show/hide sidebar (⌘⌥[)")
            Button { showDetail.toggle() } label: {
                Image(systemName: "sidebar.right").foregroundColor(showDetail ? C.muted : C.muted2)
            }.buttonStyle(.plain).help("Show/hide detail panel (⌘⌥])")

            if !showWrapped { searchField }

            Spacer(minLength: 12)

            if store.syncFailed {
                SettingsLink {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                        Text("Sync issue").font(Type.mono(10))
                    }.foregroundColor(.orange)
                }.buttonStyle(.plain).help(store.lastfmStatus ?? store.spotifyStatus ?? "A source failed to sync")
            }

            Text(syncLabel).font(Type.mono(10)).foregroundColor(C.muted2)
            Button { store.syncNow() } label: {
                Image(systemName: "arrow.clockwise").foregroundColor(C.muted2)
            }.buttonStyle(.plain).help("Sync sources now (⌘R)")

            SettingsLink {
                Image(systemName: "gearshape").foregroundColor(C.muted2)
            }.buttonStyle(.plain).help("Settings")
        }
        .font(.system(size: 14 * ThemeManager.shared.zoom))
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(C.muted2)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(Type.mono(11))
                .foregroundColor(C.text)
                .focused($searchFocused)
                .frame(width: 150)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(C.muted2)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(C.panel))
        .onReceive(NotificationCenter.default.publisher(for: .tempoFocusSearch)) { _ in
            searchFocused = true
        }
    }

    private var syncLabel: String {
        guard let d = store.lastSynced else { return "" }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "synced just now" }
        if secs < 3600 { return "synced \(secs / 60)m ago" }
        return "synced \(secs / 3600)h ago"
    }

    private var buckets: [Bucket] {
        store.buckets(groupBy: groupBy, sortBy: sortBy, range: range, source: sourceFilter,
                      search: search, split: splitCollabs && groupBy == .artist)
    }

    // MARK: timescale
    private var timescale: some View {
        HStack(spacing: 20) {
            ForEach(TimeRange.presets, id: \.self) { p in
                chip(p.label, active: range == p) { range = p }
            }
            chip(customLabel, active: range.isCustom) {
                range = .custom(customFrom, customTo); showCustom = true
            }
            .popover(isPresented: $showCustom, arrowEdge: .bottom) { customPicker }
            Spacer()
            Image(systemName: "info.circle").foregroundColor(C.muted2).font(.system(size: 12 * ThemeManager.shared.zoom))
                .help("Ranges use each track's last-played date. Apple's library doesn't store individual play timestamps, so a track played in this period contributes its full play count.")
        }
    }

    private var customLabel: String {
        guard range.isCustom else { return "Custom" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: customFrom)) – \(f.string(from: customTo))"
    }

    private var customPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom range").font(.system(size: 14 * ThemeManager.shared.zoom, weight: .bold))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("From").font(.system(size: 12 * ThemeManager.shared.zoom)).foregroundColor(C.muted)
                    DatePicker("", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().frame(width: 260)
                }
                VStack(alignment: .leading) {
                    Text("To").font(.system(size: 12 * ThemeManager.shared.zoom)).foregroundColor(C.muted)
                    DatePicker("", selection: $customTo, in: customFrom...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().frame(width: 260)
                }
            }
            Button("Done") { showCustom = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .onChange(of: customFrom) { _, _ in range = .custom(customFrom, customTo) }
        .onChange(of: customTo) { _, _ in range = .custom(customFrom, customTo) }
    }

    private var header: some View {
        // One pass over the visible tracks for all three header figures.
        let vis = store.visible(range: range, source: sourceFilter, search: search)
        let total = vis.reduce(0) { $0 + $1.totalMs }
        let plays = vis.reduce(0) { $0 + $1.countedPlays }
        var m: [Source: Int] = [:]
        for t in vis { m[t.source.display, default: 0] += t.totalMs }
        let byApp = m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return VStack(alignment: .leading, spacing: 18) {
            Text("LISTENING TIME · \(customLabel == "Custom" ? range.label.uppercased() : customLabel.uppercased())")
                .font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2)

            // The hero — huge serif figure.
            Text(TimeFmt.short(total)).cyclesTimeUnits()
                .font(Type.display(72, .medium))
                .foregroundColor(C.text)
                .padding(.top, -2)

            Text("\(TimeFmt.minutes(total)) · \(TimeFmt.commas(plays)) plays")
                .font(Type.mono(12)).foregroundColor(C.muted)

            // Thin split bar + inline mono legend.
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(byApp, id: \.0) { src, ms in
                            Rectangle().fill(Color(hex: src.hex))
                                .frame(width: max(0, geo.size.width * CGFloat(total == 0 ? 0 : Double(ms) / Double(total)) - 2))
                        }
                    }
                }.frame(height: 4)
                HStack(spacing: 22) {
                    ForEach(byApp, id: \.0) { src, ms in
                        HStack(spacing: 7) {
                            Circle().fill(Color(hex: src.hex)).frame(width: 6, height: 6)
                            Text(src.rawValue).font(Type.mono(11)).foregroundColor(C.muted)
                            Text(TimeFmt.short(ms)).font(Type.mono(11, .semibold)).foregroundColor(C.text)
                                .cyclesTimeUnits()
                        }
                    }
                    Spacer()
                }
            }.padding(.top, 4)
        }
    }

    private var chips: some View {
        HStack(spacing: 20) {
            chip("All", active: sourceFilter == nil) { sourceFilter = nil }
            ForEach(store.sources, id: \.self) { s in
                chip(s.rawValue, active: sourceFilter == s) { sourceFilter = s }
            }
            Spacer()
        }
    }

    // Grouping lives in the sidebar; this row is just split + sort.
    private var controls: some View {
        HStack(spacing: 16) {
            if groupBy == .artist {
                Toggle(isOn: $splitCollabs) {
                    Text("Split collaborations").font(Type.mono(11)).foregroundColor(C.muted)
                }
                .toggleStyle(.checkbox)
                .help("Break collaboration tags into individual artists — but keep real band names (Earth, Wind & Fire) whole.")
            }
            Spacer(minLength: 16)
            Text("SORT").font(Type.mono(10, .medium)).tracking(1.5).foregroundColor(C.muted2).fixedSize()
            Picker("", selection: $sortBy) {
                ForEach(SortBy.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 150)
        }
    }

    private func listHeader(count: Int) -> some View {
        HStack {
            Text(groupBy.title.uppercased()).font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2)
            Text("\(count)").font(Type.mono(10)).foregroundColor(C.muted2)
            Spacer()
        }.padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(!store.hasTracks ? "No played tracks found yet." : "Nothing matches your filters.")
                .font(Type.display(16, .medium)).foregroundColor(C.text)
            // Every empty state gets the button that actually fixes it.
            if !store.hasTracks {
                Text("Connect a source, or play something and Tempo will start recording.")
                    .font(Type.mono(11)).foregroundColor(C.muted2)
                SettingsLink {
                    Text("Connect a source").font(Type.mono(11, .semibold)).foregroundColor(C.bg)
                        .padding(.vertical, 8).padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 8).fill(C.green))
                }.buttonStyle(.plain)
            } else if !search.isEmpty {
                Text("No match for “\(search)”.").font(Type.mono(11)).foregroundColor(C.muted2)
                Button("Clear search") { search = "" }
                    .buttonStyle(.plain)
                    .font(Type.mono(11, .semibold)).foregroundColor(C.green)
            } else if !range.isAllTime {
                Text("Nothing in this period. Apple Music library tracks only carry one lifetime date, so they only appear under All time.")
                    .font(Type.mono(11)).foregroundColor(C.muted2)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Show all time") { range = .allTime }
                    .buttonStyle(.plain)
                    .font(Type.mono(11, .semibold)).foregroundColor(C.green)
            } else if sourceFilter != nil {
                Button("Clear source filter") { sourceFilter = nil }
                    .buttonStyle(.plain)
                    .font(Type.mono(11, .semibold)).foregroundColor(C.green)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    /// Explain the one genuinely confusing behaviour in the app: the Music
    /// library only stores a single lifetime "last played" date per track, so
    /// those tracks can't honestly be placed in a narrower window.
    @ViewBuilder private var approximateNote: some View {
        if !range.isAllTime {
            let hidden = store.approximateTrackCount
            if hidden > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundColor(C.muted2)
                    Text("\(TimeFmt.commas(hidden)) library tracks are hidden in this range — Apple Music only records one lifetime date each, so they only count under All time.")
                        .font(Type.mono(9)).foregroundColor(C.muted2)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Row
struct Row: View {
    @EnvironmentObject var store: LibraryStore
    let index: Int
    let bucket: Bucket
    let groupBy: GroupBy
    let maxMs: Int
    let selected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 18) {
                Text("\(index)")
                    .font(Type.mono(13)).foregroundColor(C.muted2)
                    .frame(width: 30, alignment: .trailing)
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(bucket.label).font(Type.display(17, .medium)).foregroundColor(C.text).lineLimit(1)
                        if groupBy == .artist && isCollab {
                            Text("collab").font(Type.mono(9)).foregroundColor(C.muted2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Capsule().stroke(C.line, lineWidth: 1))
                        }
                    }
                    Text(bucket.sublabel).font(Type.mono(10)).foregroundColor(C.muted2).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(TimeFmt.short(bucket.totalMs)).font(Type.mono(14, .medium)).foregroundColor(C.text)
                        .cyclesTimeUnits()
                    Text("\(TimeFmt.commas(bucket.plays)) plays").font(Type.mono(10)).foregroundColor(C.muted2)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(selected ? C.accentSoft : (hovering ? C.line.opacity(0.6) : .clear))
            .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { TrackActions.menu(title: bucket.label, artist: bucket.sublabel, groupBy: groupBy) }
    }

    private var isCollab: Bool {
        // A real collaboration tag the Music app keeps as one artist — flag but
        // never split. Protected band names ("Earth, Wind & Fire") aren't flagged.
        ArtistSplitter.isCollaboration(bucket.label)
    }

    @ViewBuilder private var artwork: some View {
        // Artists get a round profile photo (resolved via Deezer); everything
        // else uses the album cover. Falls back to the album/letter tile.
        // Drawn from the store's thumbnail cache, never fetched here: a row's
        // body runs on every scroll pass, and AsyncImage turned that into a
        // download and a full-size decode each time.
        if groupBy == .artist, let img = store.artistImage(for: bucket.label) {
            Image(nsImage: img)
                .resizable().interpolation(.high).scaledToFill()
                .frame(width: 40, height: 40).clipShape(Circle())
        } else {
            albumOrLetter
        }
    }

    @ViewBuilder private var albumOrLetter: some View {
        let shape = groupBy == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4))
        if groupBy != .app, let key = bucket.artKey, let img = store.cover(albumKey: key) {
            Image(nsImage: img)
                .resizable().interpolation(.high).scaledToFill()
                .frame(width: 40, height: 40).clipShape(shape)
        } else {
            let letter = bucket.label.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "♪"
            shape.fill(color(bucket.label))
                .frame(width: 40, height: 40)
                .overlay(Text(letter).font(Type.display(17, .medium)).foregroundColor(.white.opacity(0.9)))
        }
    }

    private func color(_ s: String) -> Color {
        var h = 0
        for ch in s.unicodeScalars { h = (h * 31 + Int(ch.value)) % 360 }
        return Color(hue: Double(h) / 360, saturation: 0.30, brightness: 0.30)
    }
}

// MARK: - History row
struct HistoryRow: View {
    @EnvironmentObject var store: LibraryStore
    let track: Track
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    var body: some View {
        HStack(spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(for: track)).font(Type.display(16, .medium)).foregroundColor(C.text).lineLimit(1)
                Text(store.displayArtist(for: track)).font(Type.mono(10)).foregroundColor(C.muted2).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if let d = track.lastPlayed {
                    Text(Self.relative.localizedString(for: d, relativeTo: Date()))
                        .font(Type.mono(11)).foregroundColor(C.muted)
                        .help(d.formatted(date: .abbreviated, time: .shortened))
                }
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: track.source.hex)).frame(width: 5, height: 5)
                    Text(track.source.display.rawValue).font(Type.mono(9)).foregroundColor(C.muted2)
                    // No "estimated" badge to draw here: this list is fed from
                    // `witnessedPlays`, so every row is a play we saw happen.
                }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(hovering ? C.line.opacity(0.6) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            TrackActions.menu(title: store.displayTitle(for: track), artist: store.displayArtist(for: track), groupBy: .song)
            Divider()
            Button("Remove This Play") { store.deletePlay(track) }
        }
    }

    @ViewBuilder private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        if let img = store.cover(albumKey: track.albumKey) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                .frame(width: 38, height: 38).clipShape(shape)
        } else {
            let name = store.displayTitle(for: track)
            let letter = name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "♪"
            shape.fill(tileColor(name))
                .frame(width: 38, height: 38)
                .overlay(Text(letter).font(Type.display(16, .medium)).foregroundColor(.white.opacity(0.9)))
        }
    }

    private func tileColor(_ s: String) -> Color {
        var h = 0
        for ch in s.unicodeScalars { h = (h * 31 + Int(ch.value)) % 360 }
        return Color(hue: Double(h) / 360, saturation: 0.30, brightness: 0.30)
    }
}

// MARK: - Detail
struct DetailPanel: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var theme = ThemeManager.shared   // re-render on theme change
    let groupBy: GroupBy
    let sourceFilter: Source?
    let search: String
    let selected: String?
    let splitCollabs: Bool
    let range: TimeRange
    let sortBy: SortBy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let sel = selected, !matching(sel).isEmpty {
                    detail(for: sel)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing selected").font(Type.display(18, .medium)).foregroundColor(C.muted)
                        Text("Pick an artist, app, or song to see how your listening splits across apps.")
                            .font(Type.mono(11)).foregroundColor(C.muted2).lineSpacing(3)
                    }.padding(.top, 60)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
    }

    private func matching(_ sel: String) -> [Track] {
        store.visible(range: range, source: sourceFilter, search: search).filter { t in
            switch groupBy {
            case .artist:
                // Compare on the normalised alias key so spelling variants of the
                // same artist all match the selected row (see LibraryStore.artistKey).
                let key = LibraryStore.artistKey(sel)
                return splitCollabs
                    ? ArtistSplitter.split(t.artist).contains { LibraryStore.artistKey($0) == key }
                    : LibraryStore.artistKey(t.artist) == key
            case .app:    return t.source.display.rawValue == sel
            case .song:   return store.songKey(for: t) == sel
            case .album:  return store.albumKey(for: t) == sel
            }
        }
    }

    @ViewBuilder private func detail(for sel: String) -> some View {
        let items = matching(sel)
        let total = items.reduce(0) { $0 + $1.totalMs }
        // Song and album ids are composite keys, so read the display name off a
        // matching track rather than showing "Title::Artist" to the user.
        let title: String = {
            switch groupBy {
            case .song:  return items.first?.title ?? sel
            case .album: return items.first?.album ?? sel
            default:     return sel
            }
        }()
        let artKey = items.max(by: { $0.countedPlays < $1.countedPlays })?.albumKey
        HStack(spacing: 14) {
            if groupBy == .artist, let img = store.artistImage(for: sel) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                    .frame(width: 72, height: 72).clipShape(Circle())
            } else if groupBy == .artist, let k = artKey, let img = store.cover(albumKey: k) {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if groupBy != .app, let k = artKey, let img = store.cover(albumKey: k) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Type.display(24, .medium)).lineLimit(2)
                Text("\(TimeFmt.short(total)) · \(TimeFmt.commas(items.reduce(0){$0+$1.countedPlays})) plays")
                    .cyclesTimeUnits()
                    .font(Type.mono(11)).foregroundColor(C.muted)
            }
        }
        .padding(.bottom, 8)

        timeline(items)

        Text("BY APP").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2).padding(.top, 10)
        ForEach(bySource(items), id: \.0) { src, ms in
            HStack(spacing: 10) {
                Circle().fill(Color(hex: src.hex)).frame(width: 6, height: 6)
                Text(src.rawValue).font(Type.mono(11)).foregroundColor(C.muted).frame(width: 84, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(C.line)
                        Rectangle().fill(Color(hex: src.hex))
                            .frame(width: g.size.width * CGFloat(total == 0 ? 0 : Double(ms)/Double(total)))
                    }
                }.frame(height: 3)
                Text(TimeFmt.short(ms)).font(Type.mono(11)).foregroundColor(C.text)
                    .cyclesTimeUnits()
            }
        }
        if groupBy != .song {
            Text("TOP TRACKS").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2).padding(.top, 16)
            ForEach(topTracks(items), id: \.id) { t in
                HStack {
                    Text(t.title).font(Type.display(14)).lineLimit(1)
                    Spacer()
                    Text(sortBy == .plays ? "\(TimeFmt.commas(t.countedPlays)) plays" : TimeFmt.short(t.totalMs))
                        .cyclesTimeUnits()
                        .font(Type.mono(11)).foregroundColor(C.muted)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
            }
        }
    }

    /// Your history with this artist/song: a 12-month sparkline plus the dates
    /// that give it context. Only timestamped plays can be placed in time, so an
    /// Apple Music library-only entry shows nothing here.
    private struct TimelineInfo {
        let series: [Int]      // plays per month, oldest → newest (12 buckets)
        let first: Date
        let last: Date
        let days: Int
    }

    /// Bucket a selection's timestamped plays into the last 12 months.
    private func timelineInfo(_ items: [Track]) -> TimelineInfo? {
        let cal = Calendar.current
        let dated = items.filter { $0.isExact && $0.lastPlayed != nil }
        guard let first = dated.compactMap({ $0.lastPlayed }).min(),
              let last = dated.compactMap({ $0.lastPlayed }).max() else { return nil }
        let months: [Date] = (0..<12).reversed().compactMap {
            cal.date(byAdding: .month, value: -$0, to: Date()).flatMap {
                cal.date(from: cal.dateComponents([.year, .month], from: $0))
            }
        }
        var counts: [Date: Int] = [:]
        for t in dated {
            guard let d = t.lastPlayed,
                  let m = cal.date(from: cal.dateComponents([.year, .month], from: d)) else { continue }
            counts[m, default: 0] += t.countedPlays
        }
        let days = Set(dated.compactMap { $0.lastPlayed.map { LibraryStore.listeningDay($0) } }).count
        return TimelineInfo(series: months.map { counts[$0] ?? 0 }, first: first, last: last, days: days)
    }

    @ViewBuilder private func timeline(_ items: [Track]) -> some View {
        if let info = timelineInfo(items) {
            let series = info.series
            let peak = series.max() ?? 1
            let first = info.first, last = info.last, days = info.days

            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR HISTORY").font(Type.mono(10, .medium)).tracking(2).foregroundColor(C.muted2)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, n in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(n > 0 ? C.green.opacity(0.75) : C.line)
                            .frame(height: max(2, 34 * (peak > 0 ? Double(n) / Double(peak) : 0)))
                            .frame(maxWidth: .infinity)
                    }
                }.frame(height: 34, alignment: .bottom)
                Text("first heard \(first.formatted(date: .abbreviated, time: .omitted))")
                    .font(Type.mono(10)).foregroundColor(C.muted)
                Text("last played \(last.formatted(date: .abbreviated, time: .omitted)) · across \(TimeFmt.commas(days)) day\(days == 1 ? "" : "s")")
                    .font(Type.mono(10)).foregroundColor(C.muted2)
            }
            .padding(.top, 10)
        }
    }

    private func bySource(_ items: [Track]) -> [(Source, Int)] {
        var m: [Source: Int] = [:]
        for t in items { m[t.source.display, default: 0] += t.totalMs }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    private func topTracks(_ items: [Track]) -> [Track] {
        var m: [String: Track] = [:]
        for t in items {
            // Canonical identity, so one song tagged differently by two sources
            // is a single row rather than two.
            let k = store.songKey(for: t)
            if let e = m[k] {
                // Keep the better-tagged variant's title/artwork: the one with
                // more plays is almost always the fuller record.
                let base = t.countedPlays > e.countedPlays ? t : e
                m[k] = Track(title: base.title, artist: base.artist, album: base.album,
                             albumKey: base.albumKey, source: base.source,
                             lengthMs: max(e.lengthMs, t.lengthMs), plays: e.countedPlays + t.countedPlays,
                             lastPlayed: [e.lastPlayed, t.lastPlayed].compactMap { $0 }.max())
            } else { m[k] = t }
        }
        return Array(m.values).sorted { a, b in
            switch sortBy {
            case .time:  return a.totalMs > b.totalMs
            case .plays: return a.plays > b.plays
            case .name:  return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .recent: return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            }
        }.prefix(8).map { $0 }
    }
}

// MARK: - Now playing bar

/// A slim transport strip along the bottom of the window. The menu bar already
/// has one, but when the window is open this is where your eyes are — and it
/// means you can skip a track without leaving your stats.
struct NowPlayingBar: View {
    @ObservedObject private var scrobbler = Scrobbler.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if scrobbler.nowPlaying != nil {
            VStack(spacing: 0) {
                Rectangle().fill(C.line).frame(height: 1)
                HStack(spacing: 14) {
                    if let art = scrobbler.nowPlayingArtFull {
                        Image(nsImage: art).resizable().interpolation(.high)
                            .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(C.panel3).frame(width: 34, height: 34)
                            .overlay(Image(systemName: "music.note").font(.system(size: 12)).foregroundColor(C.muted2))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scrobbler.npTitle).font(Type.display(13, .medium))
                            .foregroundColor(C.text).lineLimit(1)
                        Text(scrobbler.npArtist).font(Type.mono(9)).foregroundColor(C.muted2).lineLimit(1)
                    }
                    .frame(width: 190, alignment: .leading)

                    HStack(spacing: 16) {
                        ctl("backward.fill") { MediaControl.previous() }
                        ctl(scrobbler.isPlaying ? "pause.fill" : "play.fill") { MediaControl.playPause() }
                        ctl("forward.fill") { MediaControl.next() }
                    }

                    Text(clock(position)).font(Type.mono(9)).foregroundColor(C.muted2)
                    Slider(value: $position, in: 0...max(duration, 1)) { editing in
                        scrubbing = editing
                        if !editing { MediaControl.seek(to: position) }
                    }
                    .controlSize(.mini).disabled(duration <= 0)
                    Text(duration > 0 ? clock(duration) : "--:--")
                        .font(Type.mono(9)).foregroundColor(C.muted2)

                    if ScrobblePause.isPaused {
                        Text("paused").font(Type.mono(9)).foregroundColor(.orange)
                            .help("Scrobbling is paused — \(ScrobblePause.label)")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 9)
            }
            .background(C.panel)
            .onAppear { refresh() }
            .onReceive(tick) { _ in refresh() }
        }
    }

    private func ctl(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12 * theme.zoom, weight: .medium))
                .foregroundColor(C.text).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func refresh() {
        // Each poll is an AppleScript round-trip; don't spend one every second
        // while the window is behind something else and nobody can see the bar.
        guard !scrubbing, NSApp.isActive else { return }
        if let p = MediaControl.progress() {
            position = min(p.position, p.duration); duration = p.duration
        } else { position = 0; duration = 0 }
    }

    private func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let n = Int(s.rounded())
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}

// MARK: - Scroll position memory

/// Remembers where you were in each view. SwiftUI tears the scroll view down
/// when the mode changes, so we reach the underlying `NSScrollView` and
/// save/restore its offset ourselves — keyed by mode, for the session.
@MainActor final class ScrollMemory {
    static let shared = ScrollMemory()
    private var offsets: [String: CGFloat] = [:]
    func save(_ y: CGFloat, for key: String) { offsets[key] = y }
    func offset(for key: String) -> CGFloat { offsets[key] ?? 0 }
}

struct ScrollPositionKeeper: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        // Restore after the scroll view has content to scroll through.
        DispatchQueue.main.async { context.coordinator.attach(to: v, key: key, restore: true) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        // Mode changed within the same hierarchy: re-key and restore.
        if context.coordinator.key != key {
            DispatchQueue.main.async { context.coordinator.attach(to: v, key: key, restore: true) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var key = ""
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        func attach(to view: NSView, key: String, restore: Bool) {
            self.key = key
            guard let sv = view.enclosingScrollView else { return }
            if scrollView !== sv {
                scrollView = sv
                sv.contentView.postsBoundsChangedNotifications = true
                if let o = observer { NotificationCenter.default.removeObserver(o) }
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: sv.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let sv = self.scrollView else { return }
                        ScrollMemory.shared.save(sv.contentView.bounds.origin.y, for: self.key)
                    }
                }
            }
            guard restore else { return }
            let target = ScrollMemory.shared.offset(for: key)
            guard target > 0 else { return }
            // Wait a beat for layout so the target offset is actually reachable.
            DispatchQueue.main.async {
                let maxY = max(0, sv.documentView.map { $0.bounds.height - sv.contentSize.height } ?? 0)
                sv.contentView.scroll(to: NSPoint(x: 0, y: min(target, maxY)))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }

        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }
}

// MARK: - Row context menu

/// Right-click actions shared by the stats rows and the History rows. Turns a
/// read-only stat back into something you can act on — play it, look it up, or
/// copy it out.
enum TrackActions {
    @ViewBuilder
    static func menu(title: String, artist: String, groupBy: GroupBy) -> some View {
        // For artist/app rows the "sublabel" isn't an artist name, so search on
        // the row title alone.
        let query = (groupBy == .song && !artist.isEmpty) ? "\(title) \(artist)" : title

        Button("Play in Spotify") { open("spotify:search:\(esc(query))", fallback: "https://open.spotify.com/search/\(esc(query))") }
        Button("Search in Apple Music") { open("music://music.apple.com/search?term=\(esc(query))", fallback: "https://music.apple.com/search?term=\(esc(query))") }
        Divider()
        Button("Search on Last.fm") { open("https://www.last.fm/search?q=\(esc(query))") }
        Button("Search on YouTube") { open("https://www.youtube.com/results?search_query=\(esc(query))") }
        Divider()
        Button("Copy \(groupBy == .song && !artist.isEmpty ? "“\(title) — \(artist)”" : "“\(title)”")") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(groupBy == .song && !artist.isEmpty ? "\(title) — \(artist)" : title, forType: .string)
        }
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// Open a URL, falling back to the web equivalent when the app scheme isn't
    /// handled (e.g. Spotify isn't installed).
    private static func open(_ primary: String, fallback: String? = nil) {
        guard let url = URL(string: primary) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let f = fallback, let furl = URL(string: f) {
            NSWorkspace.shared.open(furl)
        }
    }
}

// MARK: - small helpers
@ViewBuilder func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) { content() }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(C.panel).cornerRadius(10)
}
@ViewBuilder func sectionTitle(_ t: String) -> some View {
    Text(t.uppercased()).font(.system(size: 12 * ThemeManager.shared.zoom, weight: .bold)).tracking(1).foregroundColor(C.muted2).padding(.bottom, 6)
}
// Editorial toggle: quiet mono text, an accent underline when active — no pills.
func chip(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 5) {
            Text(label)
                .font(Type.mono(12, active ? .semibold : .regular))
                .foregroundColor(active ? C.text : C.muted2)
            Rectangle().fill(active ? C.green : .clear).frame(height: 1.5)
        }
        .fixedSize()
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
}
