import AppKit
import Darwin

/// What the pinning needs to know about one display that follows desktop Spaces.
struct WallpaperSpacePin: Equatable {
    enum Content: Equatable {
        /// The current desktop's own wallpaper is on screen, or nothing is to change.
        case ready
        /// The current desktop's wallpaper is being applied.
        case loading
        /// The current desktop's wallpaper waits until playback can run it.
        case waiting
    }

    /// The window server's number for the display's current desktop; nil on a full-screen app's
    /// Space, where the windows stay on the desktop they were on.
    var space: UInt64?
    var content: Content
}

/// One wallpaper window, as the pinning sees it.
@MainActor
protocol WallpaperPinnableWindow {
    var number: Int { get }
    var displayID: UInt32? { get }
    var joinsAllSpaces: Bool { get nonmutating set }
    /// Hides the window at once, on screen before it returns, or shows it again over `fade`
    /// seconds.
    func setConcealed(_ concealed: Bool, fade: TimeInterval)
}

/// The window server's Space calls for this app's own windows.
@MainActor
protocol WallpaperSpaceWindowMoving {
    func spaces(ofWindow number: Int) -> [UInt64]?
    func move(windows: [Int], toSpace space: UInt64)
}

/// Keeps the wallpaper windows of a display that follows desktop Spaces on that display's current
/// desktop only.
///
/// Wallpaper windows normally join every Space, so the live wallpaper is the picture of every
/// desktop: Mission Control and the Spaces bar show it on each one, and a swipe carries the old
/// wallpaper onto the next desktop until its own has loaded. A pinned window stays on its desktop
/// instead, so every other desktop shows the macOS picture of its own, the poster of its
/// wallpaper. When the current desktop changes, the windows move to it hidden while the desktop's
/// own wallpaper loads, with that desktop's poster showing through, and fade in once it is ready.
///
/// A hidden window is still on screen to the window server and AppKit (fully transparent), so
/// occlusion does not suspend the display and the renderer keeps presenting its first frame.
/// Displays that do not follow Spaces keep windows on every Space, as does every display when the
/// window server's calls are not available.
@MainActor
final class WallpaperSpacePinning {
    struct Configuration {
        /// The longest a window stays hidden for a wallpaper that is being applied.
        var loadingCeiling: Duration = .seconds(30)
        /// The fade-in, in seconds; none under Reduce Motion.
        var fade: TimeInterval = 0.2
    }

    private let windows: @MainActor () -> [any WallpaperPinnableWindow]
    private let pins: @MainActor () -> [UInt32: WallpaperSpacePin]
    private let holding: @MainActor (UInt32) -> Bool
    private let mover: (any WallpaperSpaceWindowMoving)?
    private let reduceMotion: @MainActor () -> Bool
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let center: NotificationCenter
    private let configuration: Configuration
    private var observer: NSObjectProtocol?
    /// Windows taken off every Space by this pinning.
    private var pinnedWindows = Set<Int>()
    private var concealedWindows = Set<Int>()
    private var concealedSince: [UInt32: ContinuousClock.Instant] = [:]
    /// Displays that reached the ceiling, shown until their wallpaper is ready.
    private var gaveUp = Set<UInt32>()
    private var ceiling: Task<Void, Never>?

    /// `pins` lists the displays that follow Spaces now; `holding` says whether the switch hold
    /// still covers a display, which for a web page or a clip is how its readiness shows.
    init(windows: @escaping @MainActor () -> [any WallpaperPinnableWindow] = SystemPinnableWindow.all,
         pins: @escaping @MainActor () -> [UInt32: WallpaperSpacePin],
         holding: @escaping @MainActor (UInt32) -> Bool,
         mover: (any WallpaperSpaceWindowMoving)?,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         center: NotificationCenter = .default,
         configuration: Configuration = Configuration()) {
        self.windows = windows
        self.pins = pins
        self.holding = holding
        self.mover = mover
        self.reduceMotion = reduceMotion
        self.now = now
        self.sleep = sleep
        self.center = center
        self.configuration = configuration
    }

    func start() {
        guard observer == nil else { return }
        if mover == nil {
            AppLog.warn("space pinning: the window server's Space calls are unavailable; "
                + "wallpaper windows stay on every desktop")
        }
        observer = center.addObserver(forName: WallpaperSpaceMonitor.didChangeNotification, object: nil,
                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Puts every window back on every Space, shown.
    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
        ceiling?.cancel()
        ceiling = nil
        for window in windows() {
            if pinnedWindows.contains(window.number) { window.joinsAllSpaces = true }
            if concealedWindows.contains(window.number) { window.setConcealed(false, fade: 0) }
        }
        pinnedWindows.removeAll()
        concealedWindows.removeAll()
        concealedSince.removeAll()
        gaveUp.removeAll()
    }

    /// Whether the display's wallpaper windows are hidden while its desktop's wallpaper loads.
    func isConcealed(_ display: UInt32) -> Bool { concealedSince[display] != nil }

    /// Brings every wallpaper window in line with the displays that follow Spaces. Cheap and
    /// idempotent: call it whenever the desktop, the choices, a switch or the windows changed.
    func update() {
        let pins = mover == nil || observer == nil ? [:] : self.pins()
        let concealed = displaysToConceal(pins)
        for window in windows() {
            let number = window.number
            guard let display = window.displayID, let pin = pins[display], let mover else {
                if pinnedWindows.remove(number) != nil { window.joinsAllSpaces = true }
                if concealedWindows.remove(number) != nil { window.setConcealed(false, fade: 0) }
                continue
            }
            let hide = concealed.contains(display)
            // Hidden before it moves, so the old picture never reaches the new desktop.
            if hide, concealedWindows.insert(number).inserted { window.setConcealed(true, fade: 0) }
            if window.joinsAllSpaces { window.joinsAllSpaces = false }
            pinnedWindows.insert(number)
            if let space = pin.space, mover.spaces(ofWindow: number) != [space] {
                mover.move(windows: [number], toSpace: space)
            }
            if !hide, concealedWindows.remove(number) != nil {
                window.setConcealed(false, fade: reduceMotion() ? 0 : configuration.fade)
            }
        }
        let live = Set(windows().map(\.number))
        pinnedWindows.formIntersection(live)
        concealedWindows.formIntersection(live)
    }

    private func displaysToConceal(_ pins: [UInt32: WallpaperSpacePin]) -> Set<UInt32> {
        let instant = now()
        var result = Set<UInt32>()
        for (display, pin) in pins {
            let wasConcealed = concealedSince[display] != nil
            let held = wasConcealed && holding(display)
            guard pin.content != .ready || held else {
                gaveUp.remove(display)
                continue
            }
            guard !gaveUp.contains(display) else { continue }
            let since = concealedSince[display] ?? instant
            if pin.content != .waiting, since.duration(to: instant) >= configuration.loadingCeiling {
                AppLog.warn("space pinning: display \(display) wallpaper not ready after "
                    + "\(configuration.loadingCeiling.wholeMilliseconds / 1_000) s; showing it")
                gaveUp.insert(display)
                continue
            }
            if !wasConcealed { AppLog.info("space pinning: display \(display) hidden while its desktop's wallpaper loads") }
            concealedSince[display] = since
            result.insert(display)
        }
        for (display, since) in concealedSince where !result.contains(display) {
            concealedSince[display] = nil
            let seconds = Double(since.duration(to: instant).wholeMilliseconds) / 1_000
            AppLog.info("space pinning: display \(display) shown after \(String(format: "%.1f", seconds)) s")
        }
        armCeiling()
        return result
    }

    /// Wakes the pinning when the oldest hidden display reaches the ceiling.
    private func armCeiling() {
        ceiling?.cancel()
        ceiling = nil
        guard let oldest = concealedSince.values.min() else { return }
        let wait = max(.zero, now().duration(to: oldest + configuration.loadingCeiling))
        let sleep = self.sleep
        ceiling = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            self?.update()
        }
    }
}

/// A wallpaper window of any of the four kinds.
struct SystemPinnableWindow: WallpaperPinnableWindow {
    let window: NSWindow

    static func all() -> [any WallpaperPinnableWindow] {
        WallpaperPresentationPolicy.wallpaperWindows().map(SystemPinnableWindow.init)
    }

    var number: Int { window.windowNumber }

    var displayID: UInt32? {
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var joinsAllSpaces: Bool {
        get { window.collectionBehavior.contains(.canJoinAllSpaces) }
        nonmutating set {
            if newValue { window.collectionBehavior.insert(.canJoinAllSpaces) }
            else { window.collectionBehavior.remove(.canJoinAllSpaces) }
        }
    }

    func setConcealed(_ concealed: Bool, fade: TimeInterval) {
        guard !concealed, fade > 0 else {
            window.alphaValue = concealed ? 0 : 1
            // A window's alpha reaches the screen with the next Core Animation commit, at the end
            // of this run loop turn, while a Space move takes effect at once: without the flush
            // the window would arrive on the new desktop opaque and show the old wallpaper.
            if concealed { CATransaction.flush() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            window.animator().alphaValue = 1
        }
    }
}

/// Optional private CoreGraphics entry points that place this app's own windows on a Space.
/// Public AppKit has no call that moves a window to the current Space: a window ordered in again,
/// or one that joins every Space and leaves again, returns to the Space it came from.
@MainActor
final class SystemSpaceWindowMover: WallpaperSpaceWindowMoving {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Move = @convention(c) (Int32, CFArray, UInt64) -> Void
    /// Current, other and user Spaces: every Space the window is on.
    private static let allSpacesMask: Int32 = 0x7
    private let connection: Connection
    private let copySpaces: CopySpaces
    private let moveWindows: Move

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let copySpaces = dlsym(handle, "CGSCopySpacesForWindows"),
              let moveWindows = dlsym(handle, "CGSMoveWindowsToManagedSpace") else { return nil }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        self.copySpaces = unsafeBitCast(copySpaces, to: CopySpaces.self)
        self.moveWindows = unsafeBitCast(moveWindows, to: Move.self)
    }

    func spaces(ofWindow number: Int) -> [UInt64]? {
        guard let spaces = copySpaces(connection(), Self.allSpacesMask, [number] as CFArray)?
            .takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.map(\.uint64Value).sorted()
    }

    func move(windows: [Int], toSpace space: UInt64) {
        moveWindows(connection(), windows as CFArray, space)
    }
}
