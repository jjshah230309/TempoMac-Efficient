import SwiftUI
import AppKit
import Combine

// MARK: - Settings keys

enum Mini {
    static let enabledKey  = "mini.enabled"    // is the mini player showing
    static let styleKey    = "mini.style"      // classic | vinyl | cassette
    static let animateKey  = "mini.animate"    // spin the record / turn the reels
    static let controlsKey = "mini.controls"   // always | hover
    static let layoutKey   = "mini.layout"     // centred | filled


    enum Style: String, CaseIterable, Identifiable {
        case classic, vinyl, cassette
        var id: String { rawValue }
        var label: String {
            switch self {
            case .classic:  return "Cover"
            case .vinyl:    return "Vinyl"
            case .cassette: return "Cassette"
            }
        }
        var blurb: String {
            switch self {
            case .classic:  return "Just the artwork, edge to edge."
            case .vinyl:    return "A spinning record with the cover as its label."
            case .cassette: return "A tape deck whose reels turn as it plays."
            }
        }
    }

    /// When the play/pause strip is on screen.
    enum Controls: String, CaseIterable, Identifiable {
        case hover, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hover:  return "Only when the pointer is over the player"
            case .always: return "Always visible"
            }
        }
    }

    /// How the record and the title share a window that's taller than the
    /// record needs. Only the vinyl style has the two stacked, so it's the only
    /// one this changes.
    enum Layout: String, CaseIterable, Identifiable {
        case centred, filled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .centred: return "Keep the record and title together"
            case .filled:  return "Spread them to fill the window"
            }
        }
    }
}

// MARK: - Live artwork

/// Fetches the cover for whatever is playing, straight from the player, and
/// caches it per track so we don't re-fetch every second.
@MainActor
final class NowPlayingArt: ObservableObject {
    static let shared = NowPlayingArt()
    @Published private(set) var image: NSImage? { didSet { palette = Self.colors(from: image) } }
    /// Two colours sampled from the cover, used for the player's backdrop so it
    /// takes on the mood of whatever is playing.
    @Published private(set) var palette: (top: Color, bottom: Color) = (C.panel2, C.panel3)
    private var loadedFor = ""

    /// Average the top and bottom halves of the cover, then lift the saturation
    /// so a muted sleeve still gives a backdrop with some life in it.
    private static func colors(from img: NSImage?) -> (top: Color, bottom: Color) {
        guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (C.panel2, C.panel3)
        }
        var px = [UInt8](repeating: 0, count: 1 * 2 * 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (C.panel2, C.panel3)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 2))
        func make(_ i: Int) -> Color {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(red: r, green: g, blue: b, alpha: 1).usingColorSpace(.deviceRGB)?
                .getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            return Color(hue: Double(h), saturation: Double(min(s * 1.5 + 0.12, 0.75)),
                         brightness: Double(min(max(v, 0.28), 0.72)))
        }
        return (make(1), make(0))   // row 1 is the top of the image
    }

    func refresh(trackKey: String) {
        guard trackKey != loadedFor else { return }
        loadedFor = trackKey
        guard !trackKey.isEmpty else { image = nil; return }
        switch MediaControl.artworkSource() {
        case .data(let d):
            image = NSImage(data: d)
        case .url(let u):
            Task { [weak self] in
                guard let url = URL(string: u),
                      let (d, _) = try? await URLSession.shared.data(from: url) else { return }
                guard let self, self.loadedFor == trackKey else { return }   // track moved on
                self.image = NSImage(data: d)
            }
        case .none:
            // Fall back to whatever the scrobbler already resolved.
            image = Scrobbler.shared.nowPlayingArtFull
        }
    }
}

// MARK: - Window

/// A floating, freely resizable panel that sits above every other window.
@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate {
    static let shared = MiniPlayerController()
    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : open() }

    /// Which process currently shows the mini player. The app and the menu-bar
    /// helper can both host one, so ownership is recorded to stop two appearing.
    private static let ownerKey = "mini.ownerPID"
    private var ownedByAnotherProcess: Bool {
        let pid = UserDefaults.standard.integer(forKey: Self.ownerKey)
        guard pid != 0, pid != Int(ProcessInfo.processInfo.processIdentifier) else { return false }
        return NSRunningApplication(processIdentifier: pid_t(pid)) != nil
    }

    // MARK: Requests
    //
    // The window may be hosted by either process, so "show/hide the mini player"
    // is broadcast rather than acted on locally: whoever owns the window closes
    // it, and only the preferred host opens one. Acting locally meant the app
    // could be asked to hide a window the menu-bar helper owned — and silently
    // do nothing, which is exactly what "the option doesn't hide it" looked like.

    static func requestToggle() { post(nil) }
    static func requestShow(_ show: Bool) { post(show) }

    private static func post(_ show: Bool?) {
        var info: [String: String]? = nil
        if let show { info = ["show": show ? "1" : "0"] }
        DistributedNotificationCenter.default().postNotificationName(
            .init(AgentIPC.toggleMini), object: nil, userInfo: info, deliverImmediately: true)
    }

    /// `preferredHost` is the process that should create the window when nobody
    /// has one: the app whenever it's running, otherwise the menu-bar helper.
    func handleRequest(show: Bool?, preferredHost: Bool) {
        let wantsVisible = show ?? !(isOpen || ownedByAnotherProcess)
        if wantsVisible {
            guard !isOpen, !ownedByAnotherProcess, preferredHost else { return }
            open()
        } else if isOpen {
            close()
        }
    }

    /// The close/minimise/zoom buttons fade in with the transport and sit over
    /// the artwork rather than in a strip of their own — otherwise a mini player
    /// carries a chunk of empty title bar wherever it goes.
    func setChromeVisible(_ visible: Bool) {
        guard let p = panel else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Nudge the real window buttons in off the very top edge so they read as
    /// part of the player's own surface, the way Spotify's mini player does.
    private func layoutTrafficLights(in p: NSPanel) {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, kind) in kinds.enumerated() {
            guard let b = p.standardWindowButton(kind), let bar = b.superview else { continue }
            let size = b.frame.size
            let x = 13 + CGFloat(i) * (size.width + 8)
            let y = max(0, bar.bounds.height - size.height - 9)
            b.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let p = panel else { return }
        layoutTrafficLights(in: p)
    }

    /// The player's surface. Nothing masks it: the window is opaque, so macOS
    /// rounds all four corners itself at the frame's own radius.
    private func makeContentView() -> NSView {
        NSHostingView(rootView: MiniPlayerView())
    }

    /// Restyle in place when the setting changes in the other process.
    func handlePrefsChanged() {
        guard isOpen else { return }
        restyle()
    }

    /// Bring it back at launch if it was on when you last quit — otherwise the
    /// setting would read "on" with nothing on screen.
    func restoreIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Mini.enabledKey), !ownedByAnotherProcess else { return }
        open()
    }

    func open() {
        if let p = panel { p.makeKeyAndOrderFront(nil); return }
        guard !ownedByAnotherProcess else { return }
        UserDefaults.standard.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: Self.ownerKey)
        // Reopened at exactly the size it was left at. Nothing reshapes it: the
        // window resizes freely in both directions, so whatever proportion you
        // dragged it into is yours to keep.
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: savedSize),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true          // drag from anywhere
        p.level = .floating                            // above ordinary windows
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        // Opaque on purpose. A transparent window opts out of the system's
        // corner mask and shadow shaping — the app then owns its own shape, and
        // a corner masked away in the content isn't part of the window at all,
        // so it neither rounds against the frame nor takes a resize drag. That
        // is what left the bottom two corners square and unresizable. Opaque
        // hands both back to AppKit, which rounds all four at the same radius
        // and resizes from every corner, like any ordinary window. The player
        // paints edge to edge, so this colour is never actually seen.
        p.isOpaque = true
        p.backgroundColor = .black
        p.minSize = NSSize(width: 150, height: 150)
        p.contentView = makeContentView()
        // Hidden until the pointer is over the player.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(kind)?.alphaValue = 0
        }
        layoutTrafficLights(in: p)
        p.delegate = self
        if let origin = savedOrigin { p.setFrameOrigin(origin) } else { p.center() }
        p.makeKeyAndOrderFront(nil)
        panel = p
        UserDefaults.standard.set(true, forKey: Mini.enabledKey)
    }

    func close() {
        saveFrame()
        panel?.orderOut(nil)
        panel = nil
        releaseOwnership()
        UserDefaults.standard.set(false, forKey: Mini.enabledKey)
    }

    private func releaseOwnership() {
        let d = UserDefaults.standard
        if d.integer(forKey: Self.ownerKey) == Int(ProcessInfo.processInfo.processIdentifier) {
            d.removeObject(forKey: Self.ownerKey)
        }
    }

    /// Rebuild the view when the style changes underneath us.
    func restyle() {
        guard let p = panel else { return }
        p.contentView = makeContentView()
        // Deliberately leaves the frame alone: switching style keeps whatever
        // size and proportion you've dragged the window into.
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        panel = nil
        releaseOwnership()
        UserDefaults.standard.set(false, forKey: Mini.enabledKey)
    }

    // Remember where and how big it was.
    private func saveFrame() {
        guard let f = panel?.frame else { return }
        let d = UserDefaults.standard
        d.set(Double(f.width), forKey: "mini.w"); d.set(Double(f.height), forKey: "mini.h")
        d.set(Double(f.origin.x), forKey: "mini.x"); d.set(Double(f.origin.y), forKey: "mini.y")
    }
    private var savedSize: NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: "mini.w"), h = d.double(forKey: "mini.h")
        return NSSize(width: w > 100 ? w : 260, height: h > 100 ? h : 260)
    }
    private var savedOrigin: NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: "mini.x") != nil else { return nil }
        return NSPoint(x: d.double(forKey: "mini.x"), y: d.double(forKey: "mini.y"))
    }
}

// MARK: - Record deck geometry
//
// Everything the vinyl style draws and hit-tests is derived from one place, so
// the picture on screen and the places you can grab it can't drift apart. All
// coordinates are inside a `side × side` box holding the disc, y pointing down
// as SwiftUI has it. Angles are degrees clockwise from straight down, matching
// `rotationEffect`, whose positive direction is clockwise.

struct Deck {
    let side: CGFloat

    var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }
    var discR: CGFloat  { side * 0.47 }    // the record's edge
    var labelR: CGFloat { side * 0.22 }    // the cover in the middle

    // The playable band lies outside the label and inside the edge, so the
    // stylus rides bare vinyl for the whole track and never sits on the artwork.
    // The run-out is set by where the *headshell* ends up, not the needle: the
    // stylus could track to 0.255 and still be on vinyl, but the shell around it
    // would be sitting over the artwork by then.
    var grooveOuter: CGFloat { side * 0.435 }   // where a track starts
    var grooveInner: CGFloat { side * 0.285 }   // where it ends

    // The arm's bearing sits off the disc at the back right, as on a real deck.
    var pivot: CGPoint   { CGPoint(x: side * 0.875, y: side * 0.10) }
    var armLen: CGFloat  { side * 0.50 }
    var pivotCap: CGFloat { side * 0.115 }
    /// Where the arm parks when there's nothing to play — just past the edge.
    var restRadius: CGFloat { side * 0.50 }
    /// How far out you're allowed to swing it, kept inside the window.
    var maxRadius: CGFloat { side * 0.53 }
    /// How close to the arm counts as grabbing it.
    var grabSlop: CGFloat { max(6, side * 0.06) }

    private var pivotDistance: CGFloat { hypot(pivot.x - center.x, pivot.y - center.y) }

    /// Rotation of the line from the bearing to the middle of the record.
    private var centreAngle: Double {
        let u = Double(center.x - pivot.x), v = Double(center.y - pivot.y)
        return atan2(-u, v) * 180 / .pi
    }

    /// The rotation that drops the stylus this far from the middle of the record.
    /// Straight triangle work: the bearing, the middle, and the stylus, with the
    /// arm and the bearing's offset as the two known sides.
    func armAngle(radius r: CGFloat) -> Double {
        let d = Double(pivotDistance), l = Double(armLen), rr = Double(r)
        guard d > 0, l > 0 else { return 0 }
        let cosA = (d * d + l * l - rr * rr) / (2 * d * l)
        return centreAngle - acos(min(max(cosA, -1), 1)) * 180 / .pi
    }

    /// The inverse — how far out the stylus sits at a given rotation.
    func radius(armAngle deg: Double) -> CGFloat {
        let a = (centreAngle - deg) * .pi / 180
        let d = Double(pivotDistance), l = Double(armLen)
        return CGFloat(sqrt(max(0, d * d + l * l - 2 * d * l * cos(a))))
    }

    /// Rotation for a point in the track, outer groove at the start to inner at
    /// the end, exactly as a record plays.
    func armAngle(fraction f: Double) -> Double {
        let t = CGFloat(min(max(f, 0), 1))
        return armAngle(radius: grooveOuter + (grooveInner - grooveOuter) * t)
    }

    /// …and back, for working out where a dragged arm has been dropped.
    func fraction(armAngle deg: Double) -> Double {
        let r = radius(armAngle: deg)
        return Double(min(max((grooveOuter - r) / (grooveOuter - grooveInner), 0), 1))
    }

    var restAngle: Double { armAngle(radius: restRadius) }

    /// Where the needle is for a given rotation.
    func stylus(armAngle deg: Double) -> CGPoint {
        let t = deg * .pi / 180
        return CGPoint(x: pivot.x - armLen * CGFloat(sin(t)),
                       y: pivot.y + armLen * CGFloat(cos(t)))
    }

    /// The rotation that points the arm at this spot, clamped to the range it
    /// can physically reach.
    func armAngle(pointingAt p: CGPoint) -> Double {
        let dx = Double(p.x - pivot.x), dy = Double(p.y - pivot.y)
        let raw = atan2(-dx, dy) * 180 / .pi
        return min(max(raw, armAngle(radius: maxRadius)), armAngle(radius: grooveInner))
    }

    func isOnArm(_ p: CGPoint, angle: Double) -> Bool {
        distance(p, from: pivot, to: stylus(armAngle: angle)) <= grabSlop
    }

    func isOnDisc(_ p: CGPoint) -> Bool {
        hypot(p.x - center.x, p.y - center.y) <= discR
    }

    /// Rotation of a point about the middle of the record — the reading the
    /// scrub gesture works from.
    func discAngle(_ p: CGPoint) -> Double {
        atan2(Double(-(p.x - center.x)), Double(p.y - center.y)) * 180 / .pi
    }

    private func distance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let wx = p.x - a.x, wy = p.y - a.y
        let len2 = vx * vx + vy * vy
        let t = len2 > 0 ? max(0, min(1, (wx * vx + wy * vy) / len2)) : 0
        return hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
    }
}

// MARK: - Deck input

enum DeckPhase { case began, changed, ended, tapped }

/// Mouse handling for the record deck, done in AppKit rather than with SwiftUI
/// gestures because the panel is draggable by its background: a plain
/// `DragGesture` competes with the window move and which of them wins isn't
/// ours to decide. A view that answers hit-tests *only* over the disc and the
/// arm — and refuses to move the window — keeps both behaviours: scrub the
/// record and swing the arm on the deck, drag the window everywhere else.
@MainActor
final class DeckInputView: NSView {
    var deck = Deck(side: 1)
    /// Where the disc's box sits inside this view.
    var origin: CGPoint = .zero
    var armAngle: Double = 0
    var onArm:  ((DeckPhase, CGPoint) -> Void)?
    var onDisc: ((DeckPhase, CGPoint) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private enum Target { case arm, disc, none }
    private var target: Target = .none
    private var downAt: CGPoint = .zero
    private var moved = false

    private func local(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }

    /// The arm wins ties: it lies over the record, and grabbing the record when
    /// you meant the arm is the more annoying mistake of the two.
    private func hitTarget(_ p: CGPoint) -> Target {
        if deck.isOnArm(p, angle: armAngle) { return .arm }
        if deck.isOnDisc(p) { return .disc }
        return .none
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let p = convert(point, from: sv)
        // Never answer for the window's own resize band. The disc reaches to
        // within a few points of the top edge, and a deck that swallowed those
        // would leave that edge un-draggable.
        let band: CGFloat = 6
        guard p.x > band, p.y > band, p.x < bounds.width - band, p.y < bounds.height - band else { return nil }
        return hitTarget(local(p)) == .none ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let p = local(convert(event.locationInWindow, from: nil))
        target = hitTarget(p); downAt = p; moved = false
        switch target {
        case .arm:  onArm?(.began, p)
        case .disc: onDisc?(.began, p)
        case .none: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = local(convert(event.locationInWindow, from: nil))
        if hypot(p.x - downAt.x, p.y - downAt.y) > 2 { moved = true }
        switch target {
        case .arm:  onArm?(.changed, p)
        case .disc: onDisc?(.changed, p)
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = local(convert(event.locationInWindow, from: nil))
        let phase: DeckPhase = moved ? .ended : .tapped
        switch target {
        case .arm:  onArm?(phase, p)
        case .disc: onDisc?(phase, p)
        case .none: break
        }
        target = .none
    }
}

private struct DeckInputLayer: NSViewRepresentable {
    let deck: Deck
    let origin: CGPoint
    let armAngle: Double
    let onArm:  (DeckPhase, CGPoint) -> Void
    let onDisc: (DeckPhase, CGPoint) -> Void

    func makeNSView(context: Context) -> DeckInputView { DeckInputView() }

    func updateNSView(_ v: DeckInputView, context: Context) {
        v.deck = deck; v.origin = origin; v.armAngle = armAngle
        v.onArm = onArm; v.onDisc = onDisc
    }
}

// MARK: - View

struct MiniPlayerView: View {
    @ObservedObject private var scrobbler = Scrobbler.shared
    @ObservedObject private var art = NowPlayingArt.shared
    @AppStorage(Mini.styleKey) private var styleRaw = Mini.Style.vinyl.rawValue
    @AppStorage(Mini.animateKey) private var animate = true
    @AppStorage(Mini.controlsKey) private var controlsRaw = Mini.Controls.hover.rawValue
    @AppStorage(Mini.layoutKey) private var layoutRaw = Mini.Layout.centred.rawValue
    @State private var hovering = false

    // Playback, sampled every couple of seconds and interpolated in between so
    // nothing on screen has to wait for the next poll to move.
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var sampledAt = Date()

    // The spin is stated as "this much rotation by this moment, gaining this
    // fast" rather than as an animation, so the angle is a plain function of the
    // clock. A dropped frame then costs one frame, where a chain of one-second
    // animations used to stall until the next tick restarted it.
    @State private var spinPhase: Double = 0
    @State private var spinSince: Date? = nil

    // Tonearm: dragged position wins, then a spot the user parked it in,
    // otherwise it tracks the song.
    @State private var armDrag: Double? = nil
    @State private var armParked: Double? = nil

    // Scrubbing the record.
    @State private var scrubbing = false
    @State private var scrubFrom: Double = 0     // last angle the pointer was at
    @State private var scrubTurned: Double = 0   // degrees turned so far, clockwise +
    @State private var scrubBase: Double = 0     // where the song was when you grabbed it

    /// A whole turn of the record moves this far through the song. A real 33⅓
    /// disc would be 1.8 seconds a turn, which makes seeking across a track a
    /// two-minute job — this trades the physics for something you can actually
    /// aim with.
    private static let secondsPerTurn: Double = 30

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var style: Mini.Style { Mini.Style(rawValue: styleRaw) ?? .vinyl }
    private var controlsMode: Mini.Controls { Mini.Controls(rawValue: controlsRaw) ?? .hover }
    private var layout: Mini.Layout { Mini.Layout(rawValue: layoutRaw) ?? .centred }
    private var showControls: Bool { hovering || controlsMode == .always }
    private var spinning: Bool { spinSince != nil }
    /// Gentle enough to read as a turning record; a true 200°/s would strobe.
    private var degreesPerSecond: Double { style == .cassette ? 90 : 33 }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // Backdrop takes its colour from the cover, like the sleeve
                // bleeding onto the shelf behind it.
                LinearGradient(colors: [art.palette.top, art.palette.bottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                switch style {
                case .classic:  classic(side: side, size: geo.size)
                case .vinyl:    vinyl(size: geo.size)
                case .cassette: cassette(size: geo.size)
                }
                // Controls float over the artwork rather than claiming layout
                // space of their own — on hover, or pinned if you'd rather.
                // Vinyl is the exception: it hangs its own strip off the bottom
                // of the record, because the window's bottom edge there is the
                // track title, and the strip landed straight on top of it.
                if showControls, style != .vinyl {
                    VStack {
                        Spacer()
                        controls(ctlSize(side))
                            .padding(.bottom, side * 0.045)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Outside the reader, not inside it. The title bar puts a safe-area
        // inset on the content, so a reader laid out within it measures ~32pt
        // short; ignoring the inset on the *content* then shifted that short
        // slab up over the title bar and left the bottom 32pt of the window
        // unpainted. Ignoring it out here means the reader spans the whole
        // window, so the player genuinely reaches all four corners.
        .ignoresSafeArea()
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) { hovering = inside }
            MiniPlayerController.shared.setChromeVisible(inside)
        }
        .onAppear { refresh(); syncSpin() }
        .onReceive(tick) { _ in refresh() }
        .onChange(of: scrobbler.isPlaying) { _, playing in
            syncSpin()
            // Starting playback by any other route puts a parked arm back down.
            if playing { armParked = nil }
            refreshSoon()
        }
        .onChange(of: animate) { _, _ in syncSpin() }
        .onChange(of: scrobbler.npTitle) { _, _ in armParked = nil; refreshSoon() }
    }

    // MARK: playback sampling

    private func refresh() {
        art.refresh(trackKey: "\(scrobbler.npTitle)|\(scrobbler.npArtist)")
        if let p = MediaControl.progress() {
            position = min(p.position, p.duration); duration = p.duration
        } else {
            position = 0; duration = 0
        }
        sampledAt = Date()
    }

    /// After a transport command the player needs a moment to settle before it
    /// reports the new position.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { refresh() }
    }

    /// Where playback has got to right now, carried forward from the last poll.
    private func livePosition(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        let drift = scrobbler.isPlaying ? now.timeIntervalSince(sampledAt) : 0
        return min(duration, max(0, position + drift))
    }

    private var progressFraction: Double {
        duration > 0 ? min(1, max(0, livePosition(at: Date()) / duration)) : 0.5
    }

    // MARK: spin

    private func spinAngle(at now: Date) -> Double {
        guard let since = spinSince else { return spinPhase }
        return spinPhase + now.timeIntervalSince(since) * degreesPerSecond
    }

    private func startSpin() {
        guard spinSince == nil else { return }
        spinSince = Date()
    }

    private func stopSpin() {
        guard let since = spinSince else { return }
        spinPhase = (spinPhase + Date().timeIntervalSince(since) * degreesPerSecond)
            .truncatingRemainder(dividingBy: 360)
        spinSince = nil
    }

    private func syncSpin() {
        if animate, scrobbler.isPlaying, !scrubbing { startSpin() } else { stopSpin() }
    }

    // MARK: styles

    @ViewBuilder private func cover(_ size: CGFloat) -> some View {
        if let img = art.image {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size)
        } else {
            Rectangle().fill(C.panel3).frame(width: size, height: size)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: size * 0.25)).foregroundColor(C.muted2))
        }
    }

    private func classic(side: CGFloat, size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            cover(max(size.width, size.height)).frame(width: size.width, height: size.height).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 2) {
                Text(scrobbler.npTitle).font(.system(size: max(11, side * 0.075), weight: .bold))
                    .foregroundColor(.white).lineLimit(1)
                Text(scrobbler.npArtist).font(.system(size: max(9, side * 0.055)))
                    .foregroundColor(.white.opacity(0.75)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.bottom, showControls ? 44 : 12)
        }
    }

    /// A record deck: disc with the cover as its label, and a tonearm whose
    /// stylus rides the bare vinyl, tracking inwards as the song plays. Grab the
    /// arm to move it, or turn the record itself to scrub.
    private func vinyl(size: CGSize) -> some View {
        // Title takes a slice, the transport takes a band of its own beneath it,
        // and the disc gets what's left. The band is reserved whether or not the
        // strip is showing, so hovering never shuffles the layout — and sized
        // off the window rather than the disc, which would be circular.
        let ctl    = ctlSize(min(size.width, size.height))
        let stripH = ctl * 2.9 + min(size.width, size.height) * 0.03
        let textH  = min(max(size.height * 0.17, 26), 54)
        let avail = max(40, size.height - textH - stripH - size.height * 0.04)
        let side  = min(size.width * 0.88, avail)
        // The disc is square, so on a window taller than it is wide there's
        // height left over. Centred keeps that slack outside the pair — record
        // and title stay a block — where filled hands it to the disc's row and
        // leaves the title down at the bottom on its own.
        let discH = layout == .centred ? side : avail
        let deck  = Deck(side: side)
        let origin = CGPoint(x: (size.width - side) / 2, y: (discH - side) / 2)
        return VStack(spacing: 0) {
            ZStack {
                // Redrawn every frame off the clock while it turns, so the
                // rotation is continuous instead of restarting each second.
                TimelineView(.animation(paused: !spinning)) { ctx in
                    ZStack {
                        record(deck).rotationEffect(.degrees(spinAngle(at: ctx.date)))
                        tonearm(deck, angle: armAngle(deck, at: ctx.date))
                    }
                    .frame(width: side, height: side)
                }
            }
            .frame(width: size.width, height: discH)
            .overlay {
                DeckInputLayer(deck: deck, origin: origin,
                               // Hit-tested against the arm as last sampled: it
                               // creeps a few degrees a minute, so a two-second
                               // old angle is well inside the grab slop.
                               armAngle: armAngle(deck, at: sampledAt),
                               onArm: { phase, p in handleArm(phase, at: p, deck: deck) },
                               onDisc: { phase, p in handleDisc(phase, at: p, deck: deck) })
            }
            trackText(scale: side).frame(height: textH)
            // Its own band under the title: clear of the record above and the
            // text beside it, so nothing overlaps anything.
            ZStack {
                if showControls { controls(ctl).transition(.opacity) }
            }
            .frame(width: size.width, height: stripH)
        }
        .frame(width: size.width, height: size.height)
    }

    private func record(_ deck: Deck) -> some View {
        let side = deck.side
        return ZStack {
            Circle().fill(Color(white: 0.06)).frame(width: deck.discR * 2, height: deck.discR * 2)
                .shadow(color: .black.opacity(0.45), radius: side * 0.03, y: side * 0.01)
            ForEach(1..<7) { i in
                Circle().stroke(Color.white.opacity(0.055), lineWidth: max(0.5, side * 0.003))
                    .frame(width: side * (0.9 - Double(i) * 0.075))
            }
            cover(deck.labelR * 2).clipShape(Circle())
            Circle().stroke(Color.black.opacity(0.35), lineWidth: max(1, side * 0.006))
                .frame(width: deck.labelR * 2)
            Circle().fill(Color(white: 0.06)).frame(width: side * 0.045, height: side * 0.045)
        }
        .frame(width: side, height: side)
    }

    /// Which way the arm is pointing at this instant: your hand if you're moving
    /// it, else where you left it, else the groove for this point in the song.
    private func armAngle(_ deck: Deck, at now: Date) -> Double {
        if let a = armDrag { return a }
        if let a = armParked { return a }
        guard duration > 0, !scrobbler.npTitle.isEmpty else { return deck.restAngle }
        return deck.armAngle(fraction: livePosition(at: now) / duration)
    }

    /// Bearing at the back right, arm swinging in over the record. Rotated about
    /// the bearing itself, so the stylus traces the arc a real arm would.
    private func tonearm(_ deck: Deck, angle: Double) -> some View {
        let side = deck.side
        let cap  = deck.pivotCap
        let armW = max(2, side * 0.022)
        let headW = side * 0.06, headH = side * 0.055
        let h = cap / 2 + deck.armLen + headH / 2
        return ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.66)],
                                         startPoint: .top, endPoint: .bottom))
                .frame(width: cap, height: cap)
                .position(x: cap / 2, y: cap / 2)
            Circle().fill(Color(white: 0.25))
                .frame(width: cap * 0.42, height: cap * 0.42)
                .position(x: cap / 2, y: cap / 2)
            Capsule().fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.7)],
                                          startPoint: .leading, endPoint: .trailing))
                .frame(width: armW, height: deck.armLen)
                .position(x: cap / 2, y: cap / 2 + deck.armLen / 2)
            RoundedRectangle(cornerRadius: side * 0.012)
                .fill(Color(white: 0.82))
                .frame(width: headW, height: headH)
                .position(x: cap / 2, y: cap / 2 + deck.armLen - headH * 0.4)
        }
        .frame(width: cap, height: h)
        .shadow(color: .black.opacity(0.3), radius: side * 0.012, y: side * 0.006)
        .rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: (cap / 2) / h))
        // `.position` places the unrotated frame's centre; the bearing sits half
        // a cap down from its top edge.
        .position(x: deck.pivot.x, y: deck.pivot.y + h / 2 - cap / 2)
        .frame(width: side, height: side)
        .animation(armDrag == nil ? .easeInOut(duration: 0.45) : nil, value: armParked)
    }

    private func trackText(scale side: CGFloat) -> some View {
        VStack(spacing: side * 0.012) {
            Text(scrobbler.npTitle.isEmpty ? "Not playing" : scrobbler.npTitle)
                .font(.system(size: max(11, side * 0.085), weight: .bold))
                .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.55)
            Text(scrobbler.npArtist)
                .font(.system(size: max(9, side * 0.062)))
                .foregroundColor(.white.opacity(0.72)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.35), radius: 2)
        .padding(.top, side * 0.03)
    }

    // MARK: deck interaction

    /// Lifting the arm off the record stops the music and leaves the arm where
    /// you put it — the same bargain a real deck offers. Dropping it back on the
    /// vinyl seeks there and starts playing again.
    private func handleArm(_ phase: DeckPhase, at p: CGPoint, deck: Deck) {
        switch phase {
        case .began:
            armDrag = armAngle(deck, at: Date())
        case .changed:
            armDrag = deck.armAngle(pointingAt: p)
        case .tapped:
            armDrag = nil
            if armParked != nil {
                armParked = nil
                MediaControl.play()
            } else {
                armParked = deck.restAngle
                MediaControl.pause()
            }
            refreshSoon()
        case .ended:
            let final = armDrag ?? deck.restAngle
            armDrag = nil
            if deck.radius(armAngle: final) > deck.discR {
                armParked = final          // off the record: stop, and stay there
                MediaControl.pause()
            } else {
                armParked = nil
                if duration > 0 {
                    let t = deck.fraction(armAngle: final) * duration
                    MediaControl.seek(to: min(t, max(0, duration - 0.5)))
                    position = t; sampledAt = Date()
                }
                if !scrobbler.isPlaying { MediaControl.play() }
            }
            refreshSoon()
        }
    }

    /// Turning the record scrubs the song: clockwise winds it forward,
    /// anticlockwise back. The seek is sent once you let go — each one is an
    /// Apple Event round trip, far too slow to fire per frame.
    private func handleDisc(_ phase: DeckPhase, at p: CGPoint, deck: Deck) {
        switch phase {
        case .began:
            stopSpin()                       // hand it over to the pointer
            scrubbing = true
            scrubTurned = 0
            // Pinned at the grab, not read live: the song carries on playing
            // while you hold the record, and a target that crept forward under
            // a motionless hand would land somewhere you didn't aim for.
            scrubBase = livePosition(at: Date())
            scrubFrom = deck.discAngle(p)
        case .changed:
            guard scrubbing else { return }
            let now = deck.discAngle(p)
            var d = now - scrubFrom
            // Unwrap across the ±180 seam, so a drag past the bottom of the
            // record doesn't read as a near-full turn the other way.
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            scrubFrom = now
            scrubTurned += d
            spinPhase += d                   // the record follows your hand
        case .ended, .tapped:
            guard scrubbing else { return }
            scrubbing = false
            if duration > 0, scrubTurned != 0 {
                let target = min(max(scrubTarget, 0), max(0, duration - 0.5))
                MediaControl.seek(to: target)
                position = target; sampledAt = Date()
            }
            scrubTurned = 0
            syncSpin()
            refreshSoon()
        }
    }

    /// Where the current scrub would land.
    private var scrubTarget: Double {
        let delta = scrubTurned / 360 * Self.secondsPerTurn
        return min(max(scrubBase + delta, 0), max(duration, 0))
    }

    /// A cassette: cover art on the J-card, and reels that wind the tape across
    /// as the track plays.
    private func cassette(size: CGSize) -> some View {
        // The transport overlays the body on hover, so the cassette gets the
        // whole window rather than sharing it with a control strip.
        let bodyH = max(40, size.height * 0.94)
        let w = min(size.width * 0.94, bodyH * 1.6)
        let h = w / 1.6
        return VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.04).fill(Color(white: 0.14))
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.4), radius: w * 0.02, y: w * 0.008)
                VStack(spacing: h * 0.04) {
                    // J-card: artwork on the left, track written beside it.
                    HStack(spacing: w * 0.04) {
                        cover(h * 0.34).clipShape(RoundedRectangle(cornerRadius: w * 0.015))
                        VStack(alignment: .leading, spacing: h * 0.02) {
                            Text(scrobbler.npTitle.isEmpty ? "Not playing" : scrobbler.npTitle)
                                .font(.system(size: max(8, w * 0.05), weight: .bold))
                                .foregroundColor(C.text).lineLimit(1)
                            Text(scrobbler.npArtist)
                                .font(.system(size: max(7, w * 0.038)))
                                .foregroundColor(C.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, w * 0.05).padding(.top, h * 0.06)
                    // Window onto the reels
                    ZStack {
                        RoundedRectangle(cornerRadius: w * 0.02).fill(Color(white: 0.08))
                        TimelineView(.animation(paused: !spinning)) { ctx in
                            let a = spinAngle(at: ctx.date)
                            HStack(spacing: w * 0.14) {
                                reel(h * 0.3, fill: 1 - progressFraction, angle: a)
                                reel(h * 0.3, fill: progressFraction, angle: a)
                            }
                        }
                    }
                    .frame(width: w * 0.74, height: h * 0.36)
                    .padding(.bottom, h * 0.06)
                }
                .frame(width: w * 0.9, height: h * 0.86)
                .background(RoundedRectangle(cornerRadius: w * 0.025)
                    .fill(LinearGradient(colors: [C.panel, C.panel2], startPoint: .top, endPoint: .bottom)))
            }
            .frame(width: size.width, height: bodyH)
        }
        .frame(width: size.width, height: size.height)
    }

    private func reel(_ d: CGFloat, fill: Double, angle: Double) -> some View {
        ZStack {
            // Tape wound on the hub grows/shrinks as the track plays.
            Circle().fill(Color(white: 0.28))
                .frame(width: d * (0.55 + 0.45 * fill), height: d * (0.55 + 0.45 * fill))
            Circle().fill(art.image == nil ? C.panel3 : Color(white: 0.75)).frame(width: d * 0.42)
            ForEach(0..<6) { i in
                Capsule().fill(Color(white: 0.35))
                    .frame(width: d * 0.06, height: d * 0.2)
                    .offset(y: -d * 0.13)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
        }
        .frame(width: d, height: d)
        .rotationEffect(.degrees(angle))
    }

    // MARK: controls

    /// Icon size for the transport, scaled to the player but kept legible.
    private func ctlSize(_ side: CGFloat) -> CGFloat { min(max(11, side * 0.075), 17) }


    /// Transport, sized to the player. Shown on hover, or pinned on if you'd
    /// rather not chase it (Settings ▸ Mini Player).
    private func controls(_ size: CGFloat) -> some View {
        HStack(spacing: size * 1.5) {
            ctl("backward.end.fill", size) { MediaControl.previous(); refreshSoon() }
            ctl(scrobbler.isPlaying ? "pause.fill" : "play.fill", size * 1.15) {
                MediaControl.playPause(); armParked = nil; refreshSoon()
            }
            ctl("forward.end.fill", size) { MediaControl.next(); refreshSoon() }
        }
        .padding(.vertical, size * 0.45).padding(.horizontal, size * 1.1)
        .background(Capsule().fill(.black.opacity(style == .cassette ? 0.28 : 0.22)))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private func ctl(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size * 1.7, height: size * 1.7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 2)
    }
}
