import SwiftUI
import ServiceManagement

/// The first thing you ever see. Four short steps: what Tempo is, how it should
/// look, where your listening comes from, and how it should behave in the
/// background. Everything here is also in Settings — this just means nobody has
/// to go hunting on day one.
struct WelcomeView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var theme = ThemeManager.shared
    var onFinish: () -> Void

    @State private var step = 0
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: intro
                case 1: appearance
                case 2: sources
                default: background
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 54).padding(.top, 46)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
    }

    // MARK: 1 — what this is

    private var intro: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text("WELCOME TO").font(Type.mono(10, .medium)).tracking(3).foregroundColor(C.green)
                Text("Tempo").font(Type.display(60, .medium)).foregroundColor(C.text)
                Text("Your listening, actually measured.")
                    .font(Type.display(19)).foregroundColor(C.muted)
            }
            VStack(alignment: .leading, spacing: 14) {
                bullet("clock", "Real listening time",
                       "Not just play counts — Tempo totals the hours behind every artist, album and song.")
                bullet("waveform", "It records as you listen",
                       "Anything you play in Spotify or Apple Music on this Mac is captured automatically, with exact timestamps.")
                bullet("chart.bar.fill", "Wrapped, whenever you want it",
                       "Your top artists, genres, streaks and listening habits — not once a year.")
            }
        }
    }

    // MARK: 2 — appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader("Make it yours", "Pick a look. You can change this any time in Settings → Appearance.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                ForEach(Themes.all) { p in
                    ThemeSwatch(palette: p, selected: theme.current.id == p.id)
                        .onTapGesture { theme.select(p) }
                }
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 14) {
                Text("Text size").font(Type.mono(12)).foregroundColor(C.muted)
                Button("–") { theme.setZoom(theme.zoom - 0.1) }
                Text("\(Int((theme.zoom * 100).rounded()))%")
                    .font(Type.mono(12, .semibold)).foregroundColor(C.text).frame(width: 52)
                Button("+") { theme.setZoom(theme.zoom + 0.1) }
                Button("Reset") { theme.setZoom(1.0) }
                Spacer()
            }
        }
    }

    // MARK: 3 — sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader("Where your music comes from",
                       "Tempo reads your Mac's library on its own. Connecting a service adds exact per-play history — including listening on your phone.")
            VStack(alignment: .leading, spacing: 12) {
                sourceRow("Apple Music & local files", accessory: libraryStatus, done: !store.tracks.isEmpty)
                sourceRow("Last.fm", accessory: "Every scrobble, with timestamps — the richest history.", done: hasLastFM)
                sourceRow("Spotify", accessory: "Your recently played, pulled straight from your account.", done: SpotifyAuth.shared.connected)
            }
            SettingsLink {
                Text("Open Settings → Sources")
                    .font(Type.mono(12, .semibold)).foregroundColor(C.bg)
                    .padding(.vertical, 9).padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 8).fill(C.green))
            }.buttonStyle(.plain)
            Text("You can skip this and connect later — Tempo already works with just your Mac's library.")
                .font(Type.mono(10)).foregroundColor(C.muted2)
        }
    }

    private var hasLastFM: Bool {
        !(UserDefaults.standard.string(forKey: "lastfm.user") ?? "").isEmpty
    }
    private var libraryStatus: String {
        if case .loaded(let n) = store.status { return "\(TimeFmt.commas(n)) tracks found." }
        if case .denied = store.status { return "Needs permission — macOS will ask." }
        return "Reading your library…"
    }

    // MARK: 4 — background behaviour

    private var background: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader("Always listening (if you want)",
                       "Tempo can keep a tiny helper running so plays are still recorded after you close the window.")
            VStack(alignment: .leading, spacing: 12) {
                toggleCard(
                    title: "Keep scrobbling in the background",
                    body: "Runs an invisible helper — no Dock icon, no ⌘-Tab entry. Turning it on asks for Touch ID.",
                    isOn: Binding(get: { bgOn }, set: { setBackground($0) })
                )
                toggleCard(
                    title: "Show a menu bar player",
                    body: "Now playing in your menu bar, with playback and volume controls. Scroll it to change volume.",
                    isOn: $menuBar
                )
                toggleCard(
                    title: "Launch at login",
                    body: "Start Tempo automatically so nothing is ever missed.",
                    isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })
                )
            }
            if let n = note { Text(n).font(Type.mono(10)).foregroundColor(.orange) }
        }
    }

    @AppStorage(AgentIPC.showMenuBarKey) private var menuBar = true
    @State private var bgOn = BackgroundAgent.isActive
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var note: String? = nil

    private func setBackground(_ on: Bool) {
        guard on != BackgroundAgent.isActive else { return }
        note = nil
        Task {
            do { try await BackgroundAgent.setEnabled(on) }
            catch { note = "Couldn't change that: \(error.localizedDescription)" }
            bgOn = BackgroundAgent.isActive
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { note = "macOS refused that: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: chrome

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(C.line).frame(height: 1)
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? C.green : C.line)
                            .frame(width: i == step ? 18 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: step)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(.plain).font(Type.mono(12)).foregroundColor(C.muted)
                }
                Button {
                    if step == steps - 1 { onFinish() } else { withAnimation { step += 1 } }
                } label: {
                    Text(step == steps - 1 ? "Start listening" : "Continue")
                        .font(Type.mono(12, .semibold)).foregroundColor(C.bg)
                        .padding(.vertical, 9).padding(.horizontal, 22)
                        .background(RoundedRectangle(cornerRadius: 8).fill(C.green))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 54).padding(.vertical, 18)
        }
    }

    private func stepHeader(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Type.display(34, .medium)).foregroundColor(C.text)
            Text(body).font(Type.mono(11)).foregroundColor(C.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(C.green)
                .frame(width: 26, height: 26)
                .background(Circle().fill(C.green.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Type.display(16, .medium)).foregroundColor(C.text)
                Text(body).font(Type.mono(10)).foregroundColor(C.muted2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func sourceRow(_ title: String, accessory: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? C.green : C.muted2).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Type.display(15, .medium)).foregroundColor(C.text)
                Text(accessory).font(Type.mono(10)).foregroundColor(C.muted2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(C.panel))
    }

    private func toggleCard(title: String, body: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Type.display(15, .medium)).foregroundColor(C.text)
                Text(body).font(Type.mono(10)).foregroundColor(C.muted2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(C.panel))
    }
}
