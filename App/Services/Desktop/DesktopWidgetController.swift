import AppKit
import Foundation

/// Puts the desktop widgets on the displays and keeps their words current.
///
/// One window per widget and display, sized to what it shows, stacked in the store's order: a widget
/// listed first is in front of the ones after it where they overlap. Without widgets it keeps no window and
/// no timer and only listens for the store's change. With widgets it redraws when what they show
/// changes (each second for a clock with seconds, each minute for another clock, at a greeting's
/// hour, at sunrise and sunset, at midnight for dates, countdowns and the month), and only while one
/// of its windows can be seen: covered by other windows, on a sleeping display or behind the lock
/// screen it schedules nothing, and the window's occlusion change brings it back. Text never needs
/// a timer, and a battery widget listens to the battery's own notification, which it keeps only
/// while one is placed. A change of the clock, the time zone, the region format, the day, the
/// sunrise and sunset location or a wake redraws at once; a screen change moves the windows and
/// touches only the ones whose frame changed.
@MainActor
final class DesktopWidgetController {
    /// A display as the widgets see it.
    struct Screen: Equatable, Sendable {
        var displayID: UInt32
        /// Core Graphics' UUID for the display, stable across reboots; nil when it has none.
        var uuid: String?
        var name: String
        var frame: NSRect
        /// Whether it is the display with the menu bar.
        var isMain: Bool
    }

    /// The time, the calendar and the language the words are written in.
    struct Clock {
        var now: () -> Date
        var calendar: () -> Calendar
        var locale: () -> Locale

        static let system = Clock(
            now: Date.init, calendar: { Calendar.autoupdatingCurrent }, locale: { Locale.autoupdatingCurrent })
    }

    /// A widget on a display, as last drawn.
    struct Shown: Equatable {
        var widgetID: String
        var displayID: UInt32
        var frame: NSRect
        var text: String
    }

    private struct Key: Hashable {
        var widgetID: String
        var displayID: UInt32
    }

    private final class MediaListenerKey {}

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let screens: @MainActor () -> [Screen]
    private let makeSurface: @MainActor () -> any DesktopWidgetSurface
    private let clock: Clock
    private let schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> () -> Void
    private let makeBattery: @MainActor () -> any BatteryLevelSource
    private let spaceTopology: @MainActor () -> [String: WallpaperDisplaySpaces]?
    private let makeSpaceMover: @MainActor () -> (any WallpaperSpaceWindowMoving)?
    private let imageStore: DesktopWidgetImageStore
    private let formatters = DesktopWidgetRendering.Formatters()
    private let mediaToken = MediaListenerKey()
    private var mediaKey: ObjectIdentifier { ObjectIdentifier(mediaToken) }

    private var isStarted = false
    private var widgets: [DesktopWidget] = []
    private var surfaces: [Key: any DesktopWidgetSurface] = [:]
    private var drawn: [Key: Shown] = [:]
    /// The windows in the order they were last stacked, back first.
    private var stacked: [Key] = []
    private var cancelTimer: (() -> Void)?
    private(set) var nextChange: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The battery's notification, kept only while a battery widget is placed.
    private var battery: (any BatteryLevelSource)?
    private var batteryReading: BatteryReading?
    private var solar: WallpaperSolarSettings?
    /// Active wallpaper ID per display, used for `.wallpapers` widget scope filtering.
    private var activeWallpapers: [UInt32: String] = [:]
    /// Lazily resolved private Space mover, created only if a `.spaces` widget is placed.
    private var spaceMover: (any WallpaperSpaceWindowMoving)?
    private var resolvedSpaceMover = false
    /// Shared Now Playing session, consumed only while at least one `.nowPlaying` widget is on screen.
    private var mediaSession: DesktopMediaSession?
    private var isConsumingMedia = false
    private var mediaSnapshot = DesktopWidgetRendering.MediaSnapshot()
    private var lastMediaThumbnail: SystemMediaThumbnail?
    private var mediaArtworkToken: UInt64 = 0

    /// `makeSurface` makes and shows a widget's window, `schedule` runs its action once at a date
    /// and returns what cancels it, and `makeBattery` makes the battery's source; tests pass ones
    /// that keep everything off screen and the clock and the battery in their hands.
    init(
        defaults: UserDefaults = ClientPreferences.defaults, center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screens: @escaping @MainActor () -> [Screen] = DesktopWidgetController.systemScreens,
        makeSurface: @escaping @MainActor () -> any DesktopWidgetSurface = DesktopWidgetWindow.present,
        clock: Clock = .system,
        schedule: @escaping @MainActor (Date, @escaping @MainActor () -> Void) -> () -> Void =
            DesktopWidgetController.scheduleTimer,
        makeBattery: @escaping @MainActor () -> any BatteryLevelSource = { SystemBatteryLevel() },
        mediaSession: DesktopMediaSession? = nil,
        spaceTopology: @escaping @MainActor () -> [String: WallpaperDisplaySpaces]? =
            DesktopWidgetController.systemSpaceTopology,
        makeSpaceMover: @escaping @MainActor () -> (any WallpaperSpaceWindowMoving)? = { SystemSpaceWindowMover() },
        imageStore: DesktopWidgetImageStore = .shared
    ) {
        self.defaults = defaults
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.screens = screens
        self.makeSurface = makeSurface
        self.clock = clock
        self.schedule = schedule
        self.makeBattery = makeBattery
        self.mediaSession = mediaSession
        self.spaceTopology = spaceTopology
        self.makeSpaceMover = makeSpaceMover
        self.imageStore = imageStore
    }

    /// What each widget window shows now, by widget then display.
    var shown: [Shown] {
        drawn.values.sorted { ($0.widgetID, $0.displayID) < ($1.widgetID, $1.displayID) }
    }

    /// The widget of each window, back to front, as the windows were last stacked.
    var stacking: [String] { stacked.map(\.widgetID) }

    /// Whether the controller is currently consuming Now Playing updates from `DesktopMediaSession`.
    var isConsumingMediaSession: Bool { isConsumingMedia }

    /// Attaches (or detaches) the shared process-wide `DesktopMediaSession`. Safe to call after
    /// `start()` once library services bring up the media session.
    func attachMediaSession(_ session: DesktopMediaSession?) {
        guard session !== mediaSession else { return }
        detachCurrentMediaSession()
        mediaSession = session
        if isStarted, let session {
            session.relay.addListener(mediaKey) { [weak self] event in
                self?.handleMediaEvent(event)
            }
            reconcileMediaDemand()
            render()
        }
    }

    /// Updates the active wallpaper ID shown on each connected display, reconciling wallpaper-scoped
    /// widgets and lazy Now Playing consumption. Cheap and idempotent when unchanged.
    func updateActiveWallpapers(_ wallpapers: [UInt32: String]) {
        guard wallpapers != activeWallpapers else { return }
        activeWallpapers = wallpapers
        if isStarted { place() }
    }

    /// Convenience overload reading display wallpaper assignments from a `BridgeMonitorInfoRow` snapshot.
    func updateActiveWallpapers(from rows: [BridgeMonitorInfoRow]) {
        updateActiveWallpapers(Self.activeWallpapers(from: rows))
    }

    /// Resolves live `displayID -> activeWallpaperID` from bridge monitor rows, preferring
    /// standalone rows and falling back to a mirrored display's target wallpaper.
    static func activeWallpapers(from rows: [BridgeMonitorInfoRow]) -> [UInt32: String] {
        let byMonitorID = Dictionary(
            rows.compactMap { row -> (String, String)? in
                guard !row.wallpaperId.isEmpty else { return nil }
                return (row.displayId, row.wallpaperId)
            },
            uniquingKeysWith: { first, _ in first })
        var result: [UInt32: String] = [:]
        for row in rows where row.mirrorTargetDisplayId == nil {
            guard !row.wallpaperId.isEmpty,
                  let liveID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
            else { continue }
            result[liveID] = row.wallpaperId
        }
        for row in rows where row.mirrorTargetDisplayId != nil {
            guard let liveID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title),
                  result[liveID] == nil
            else { continue }
            let wallpaper = !row.wallpaperId.isEmpty
                ? row.wallpaperId
                : row.mirrorTargetDisplayId.flatMap { byMonitorID[$0] }
            if let wallpaper, !wallpaper.isEmpty { result[liveID] = wallpaper }
        }
        return result
    }

    /// Reclaims sticker image files no saved widget references. Call once at app startup before
    /// any panel Undo/Redo history exists — never inside `start()`, which Presentation Mode and
    /// Toggle Desktop Widgets re-run during a session.
    func pruneUnusedImagesOnLaunch() {
        let saved = DesktopWidgetStore.load(from: defaults)
        imageStore.pruneUnused(keeping: Set(saved.compactMap { $0.imageAsset?.assetID }))
    }

    // MARK: Running

    func start() {
        guard observers.isEmpty else { return }
        isStarted = true
        if let mediaSession {
            mediaSession.relay.addListener(mediaKey) { [weak self] event in
                self?.handleMediaEvent(event)
            }
        }
        observe(center, DesktopWidgetStore.didChangeNotification) { $0.reload() }
        // An XDR display posts a screen change for every frame of an EDR headroom ramp; a change that
        // moves no widget touches no window.
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.place() }
        observe(center, WallpaperSpaceMonitor.didChangeNotification) { controller in
            guard controller.widgets.contains(where: { $0.pinnedSpaceIDs != nil }) else { return }
            controller.place()
        }
        for name in [
            Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
            NSLocale.currentLocaleDidChangeNotification,
        ] {
            observe(center, name) { $0.render() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspaceCenter, name) { controller in
                controller.batteryReading = controller.battery?.reading
                controller.reconcileMediaDemand()
                controller.render()
            }
        }
        observe(center, WallpaperAutomationStore.didChangeNotification) { controller in
            controller.solar = Self.savedSolar(in: controller.defaults)
            controller.render()
        }
        observe(center, NSWindow.didChangeOcclusionStateNotification) { controller, notification in
            guard let window = notification.object as AnyObject?,
                  controller.surfaces.values.contains(where: { $0 === window }) else { return }
            controller.reconcileMediaDemand()
            controller.render()
        }
        reload()
    }

    func stop() {
        isStarted = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        cancelTimer?()
        cancelTimer = nil
        nextChange = nil
        battery?.stop()
        battery = nil
        batteryReading = nil
        detachCurrentMediaSession()
        for surface in surfaces.values { surface.remove() }
        surfaces.removeAll()
        drawn.removeAll()
        stacked.removeAll()
    }

    /// The words are due to change: draws them, which schedules the next change.
    func tick() {
        cancelTimer = nil
        render()
    }

    // MARK: Drawing

    private func reload() {
        widgets = DesktopWidgetStore.load(from: defaults).filter(\.isShown)
        solar = Self.savedSolar(in: defaults)
        place()
    }

    /// Makes a window for each widget on each display it belongs on, removes the rest, applies
    /// Space pinning, reconciles battery/media demand, and draws.
    private func place() {
        let screens = screens()
        let needsSpaces = widgets.contains { $0.pinnedSpaceIDs != nil }
        let topology = needsSpaces ? spaceTopology() : nil
        let mover: (any WallpaperSpaceWindowMoving)? = needsSpaces ? resolveSpaceMover() : nil

        var wanted = Set<Key>()
        var spaceAssignments: [Key: [UInt64]?] = [:]
        for widget in widgets {
            for screen in screens
            where widget.isPlaced(onDisplayUUID: screen.uuid, isMain: screen.isMain)
                && widget.matchesWallpaper(activeWallpapers[screen.displayID])
            {
                let key = Key(widgetID: widget.id, displayID: screen.displayID)
                if let pinnedUUIDs = widget.pinnedSpaceIDs {
                    if let topology, mover != nil, let displaySpaces = topology[String(screen.displayID)] {
                        let matched = displaySpaces.spaces.filter { pinnedUUIDs.contains($0.id) }
                        guard !matched.isEmpty else { continue }
                        let managed = matched.compactMap(\.managedID).sorted()
                        wanted.insert(key)
                        spaceAssignments[key] = managed.isEmpty ? nil : managed
                    } else {
                        // Private Space topology or window-moving API unavailable: fall back to all Spaces.
                        wanted.insert(key)
                        spaceAssignments[key] = nil
                    }
                } else {
                    wanted.insert(key)
                    spaceAssignments[key] = nil
                }
            }
        }
        for (key, surface) in surfaces where !wanted.contains(key) {
            surface.remove()
            surfaces[key] = nil
            drawn[key] = nil
        }
        for key in wanted where surfaces[key] == nil {
            surfaces[key] = makeSurface()
        }
        for key in wanted {
            let assignment = spaceAssignments[key] ?? nil
            surfaces[key]?.applySpacePinning(assignment, using: assignment == nil ? nil : mover)
        }
        stack()
        let placed = Set(wanted.map(\.widgetID))
        observeBattery(widgets.contains { $0.kind == .battery && placed.contains($0.id) })
        reconcileMediaDemand()
        render(screens: screens)
    }

    private func resolveSpaceMover() -> (any WallpaperSpaceWindowMoving)? {
        if !resolvedSpaceMover {
            resolvedSpaceMover = true
            spaceMover = makeSpaceMover()
        }
        return spaceMover
    }

    /// Puts the windows in the layers' order, the last widget at the back. A new window comes up in
    /// front of the others, so one being added or a new order restacks them; anything else leaves
    /// the windows as they are.
    private func stack() {
        let order = widgets.reversed().flatMap { widget in
            surfaces.keys.filter { $0.widgetID == widget.id }.sorted { $0.displayID < $1.displayID }
        }
        guard order != stacked else { return }
        let isOnlyRemoval = order.count < stacked.count && stacked.filter { order.contains($0) } == order
        stacked = order
        guard !isOnlyRemoval else { return }
        for key in order { surfaces[key]?.raise() }
    }

    private func render() { render(screens: screens()) }

    private func render(screens: [Screen]) {
        let store = imageStore
        let inputs = DesktopWidgetRendering.Inputs(
            date: clock.now(), calendar: clock.calendar(), locale: clock.locale(), battery: batteryReading,
            solar: solar, media: isConsumingMedia ? mediaSnapshot : nil, isPreview: false,
            resolveImage: { store.loadImage(for: $0) })
        let frames = Dictionary(screens.map { ($0.displayID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for widget in widgets {
            let content = DesktopWidgetRendering.content(for: widget, inputs: inputs, formatters: formatters)
            for (key, surface) in surfaces where key.widgetID == widget.id {
                guard let display = frames[key.displayID] else { continue }
                let frame = DesktopWidgetRendering.frame(for: content, widget: widget, display: display)
                let shown = Shown(widgetID: widget.id, displayID: key.displayID, frame: frame, text: content.text)
                surface.show(content.drawing, look: content.look, padding: content.padding, frame: frame)
                drawn[key] = shown
            }
        }
        scheduleNextChange(after: inputs)
    }

    // MARK: Now Playing (lazy, event-driven)

    /// Consumes `DesktopMediaSession.relay` ONLY while at least one enabled `.nowPlaying` widget
    /// is placed on a matching display/Space AND visible on an uncovered screen (`isOnScreen`).
    private func reconcileMediaDemand() {
        let wantsMedia = isStarted && mediaSession != nil && widgets.contains { widget in
            widget.kind == .nowPlaying
                && surfaces.contains { $0.key.widgetID == widget.id && $0.value.isOnScreen }
        }
        guard wantsMedia != isConsumingMedia else { return }
        guard let session = mediaSession else {
            isConsumingMedia = false
            resetMediaState()
            return
        }
        if wantsMedia {
            isConsumingMedia = true
            session.relay.setConsuming(true, for: mediaKey)
            for event in session.relay.currentEvents(userEnabled: true) {
                _ = applyMediaEvent(event)
            }
        } else {
            isConsumingMedia = false
            session.relay.setConsuming(false, for: mediaKey)
            resetMediaState()
        }
    }

    private func detachCurrentMediaSession() {
        guard let session = mediaSession else { return }
        if isConsumingMedia {
            isConsumingMedia = false
            session.relay.setConsuming(false, for: mediaKey)
        }
        session.relay.removeListener(mediaKey)
        resetMediaState()
    }

    private func resetMediaState() {
        mediaSnapshot = DesktopWidgetRendering.MediaSnapshot()
        lastMediaThumbnail = nil
    }

    private func handleMediaEvent(_ event: WebWallpaperMediaRelay.Event) {
        // Drop events whenever no `.nowPlaying` widget is actively visible on screen.
        guard isConsumingMedia else { return }
        guard applyMediaEvent(event) else { return }
        render()
    }

    /// Applies discrete track/artwork/playback updates to `mediaSnapshot`. Timeline ticks are
    /// deliberately ignored so the widget never redraws at 1 Hz or animates a progress bar.
    private func applyMediaEvent(_ event: WebWallpaperMediaRelay.Event) -> Bool {
        switch event {
        case .status, .timeline:
            return false
        case .properties(let properties):
            var next = mediaSnapshot
            next.title = properties.title
            next.artist = properties.artist
            next.album = properties.albumTitle
            guard next != mediaSnapshot else { return false }
            mediaSnapshot = next
            return true
        case .playback(let state):
            guard mediaSnapshot.playback != state else { return false }
            mediaSnapshot.playback = state
            return true
        case .thumbnail(let thumbnail):
            guard thumbnail != lastMediaThumbnail else { return false }
            lastMediaThumbnail = thumbnail
            if thumbnail.isEmpty {
                mediaSnapshot.artwork = nil
                mediaSnapshot.primaryColor = nil
                mediaSnapshot.textColor = nil
            } else {
                mediaArtworkToken &+= 1
                mediaSnapshot.artwork = DesktopWidgetRendering.MediaSnapshot.artwork(
                    from: thumbnail, token: mediaArtworkToken)
                mediaSnapshot.primaryColor = thumbnail.primaryColor
                mediaSnapshot.textColor = thumbnail.textColor
            }
            return true
        }
    }

    /// Schedules the next redraw, or none while no widget window can be seen.
    private func scheduleNextChange(after inputs: DesktopWidgetRendering.Inputs) {
        cancelTimer?()
        cancelTimer = nil
        nextChange = nil
        guard surfaces.values.contains(where: \.isOnScreen) else { return }
        let placed = Set(surfaces.keys.map(\.widgetID))
        guard let next = DesktopWidgetRendering.nextChange(
            after: inputs, widgets: widgets.filter { placed.contains($0.id) }) else { return }
        nextChange = next
        cancelTimer = schedule(next) { [weak self] in self?.tick() }
    }

    /// Starts listening to the battery when a battery widget is placed, and stops when none is.
    private func observeBattery(_ wanted: Bool) {
        if wanted, battery == nil {
            let source = makeBattery()
            battery = source
            batteryReading = source.reading
            source.start { [weak self, weak source] in
                guard let self, let source else { return }
                batteryReading = source.reading
                render()
            }
        } else if !wanted, let source = battery {
            source.stop()
            battery = nil
            batteryReading = nil
        }
    }

    /// The sunrise and sunset settings the automatic wallpapers saved, read as their store reads
    /// them; nil when none are saved or they cannot be read.
    nonisolated static func savedSolar(in defaults: UserDefaults) -> WallpaperSolarSettings? {
        if let data = defaults.data(forKey: WallpaperAutomationStore.solarKey),
           let settings = try? JSONDecoder().decode(WallpaperSolarSettings.self, from: data), settings.isValid {
            return settings
        }
        guard let data = defaults.data(forKey: WallpaperAutomationStore.locationKey),
              let location = try? JSONDecoder().decode(WallpaperSolarLocation.self, from: data),
              location.isValid else { return nil }
        return WallpaperSolarSettings(source: .coordinates, location: location)
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (DesktopWidgetController, Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self, notification)
            }
        }
        observers.append((center, token))
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (DesktopWidgetController) -> Void
    ) {
        observe(center, name) { controller, _ in action(controller) }
    }

    // MARK: The system

    /// The connected displays as AppKit reports them now.
    static func systemScreens() -> [Screen] {
        let main = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let displayID = SystemDisplays.id(of: screen) else { return nil }
            return Screen(
                displayID: displayID, uuid: displayUUID(displayID), name: screen.localizedName,
                frame: screen.frame, isMain: displayID == main)
        }
    }

    /// The live macOS desktop Space topology when available; nil when Space calls cannot be read.
    static func systemSpaceTopology() -> [String: WallpaperDisplaySpaces]? {
        let monitor = WallpaperSpaceMonitor.shared
        return monitor.available ? monitor.displays : nil
    }

    nonisolated static func displayUUID(_ displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// A one-shot timer on the main run loop, a few milliseconds after `date` so the words read
    /// the new second or minute.
    static func scheduleTimer(at date: Date, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(fire: date.addingTimeInterval(0.005), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
