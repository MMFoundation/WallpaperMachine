import AppKit
import XCTest
@testable import WallpaperMachine

/// The desktop widgets' windows: one per widget and display it belongs on, kept current only while
/// one of them can be seen, moved with the displays, and never mistaken for a wallpaper window.
@MainActor
final class DesktopWidgetControllerTests: XCTestCase {
    typealias Screen = DesktopWidgetController.Screen

    private let laptop = Screen(
        displayID: 1, uuid: "AAAA-1", name: "Built-in Display",
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
    private let external = Screen(
        displayID: 2, uuid: "BBBB-2", name: "Studio Display",
        frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440), isMain: false)

    /// A widget window that records what it was asked to show and is never put on screen.
    private final class FakeSurface: DesktopWidgetSurface {
        var frame: NSRect = .zero
        var text = ""
        var drawing: DesktopWidgetRendering.Drawing = .empty
        var showCount = 0
        var pinnedSpaces: [UInt64]? = nil
        var usedSpaceMover = false
        var isOnScreen = true
        var removed = false
        var raises = 0

        func raise() { raises += 1 }

        func show(
            _ drawing: DesktopWidgetRendering.Drawing, look: DesktopWidgetRendering.Look, padding: CGFloat,
            frame: NSRect
        ) {
            self.frame = frame
            if self.drawing != drawing { showCount += 1 }
            self.drawing = drawing
            switch drawing {
            case .text(let text):
                self.text = text.string
            case .nowPlaying(let card):
                self.text = [card.title.string, card.subtitle?.string]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            case .empty, .analog, .image:
                self.text = ""
            }
        }

        func applySpacePinning(_ managedSpaceIDs: [UInt64]?, using mover: (any WallpaperSpaceWindowMoving)?) {
            pinnedSpaces = managedSpaceIDs
            usedSpaceMover = mover != nil
        }

        func remove() { removed = true }
    }

    private final class FakeMediaProvider: SystemMediaProvider {
        var availability: SystemMediaAvailability = .available
        var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
        var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
        var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
        var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?
        private(set) var consumers = 0
        var currentProperties = SystemMediaProperties()
        var currentThumbnail: SystemMediaThumbnail?
        var currentPlayback = SystemMediaPlaybackState.stopped

        func addConsumer() { consumers += 1 }
        func removeConsumer() { consumers = max(consumers - 1, 0) }
        func replayCurrentState() {
            onPropertiesChanged?(currentProperties)
            if let currentThumbnail { onThumbnailChanged?(currentThumbnail) }
            onPlaybackChanged?(currentPlayback)
        }
    }

    private final class FakeSpaceMover: WallpaperSpaceWindowMoving {
        var canPlace = true
        var windowSpaces: [Int: [UInt64]] = [:]
        private(set) var placeCalls: [(window: Int, spaces: [UInt64])] = []

        func spaces(ofWindow number: Int) -> [UInt64]? { windowSpaces[number] }
        func move(windows: [Int], toSpace space: UInt64) {
            for id in windows { windowSpaces[id] = [space] }
        }
        func place(window number: Int, onSpaces spaces: [UInt64]) -> Bool {
            placeCalls.append((number, spaces))
            guard canPlace else { return false }
            windowSpaces[number] = spaces
            return true
        }
    }

    /// A battery whose reading the test sets, and which says whether anything listens to it.
    private final class FakeBattery: BatteryLevelSource {
        var reading: BatteryReading?
        private(set) var onChange: (@MainActor () -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0

        func start(onChange: @escaping @MainActor () -> Void) {
            starts += 1
            self.onChange = onChange
        }

        func stop() {
            stops += 1
            onChange = nil
        }
    }

    @MainActor
    private final class Fixture {
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let defaults: UserDefaults
        let imageStore: DesktopWidgetImageStore
        var screens: [Screen]
        var now = Date(timeIntervalSince1970: 1_794_171_907)  // 21:05:07 UTC
        var surfacesOnScreen = true
        let battery = FakeBattery()
        let mediaProvider = FakeMediaProvider()
        lazy var mediaSession = DesktopMediaSession(provider: mediaProvider)
        var spaceTopology: [String: WallpaperDisplaySpaces]? = nil
        var spaceMover: FakeSpaceMover? = FakeSpaceMover()
        private(set) var made: [FakeSurface] = []
        private(set) var scheduled: [Date] = []
        private(set) var cancelled = 0
        private var pending: (@MainActor () -> Void)?
        lazy var store = DesktopWidgetStore(defaults: defaults, center: center)
        lazy var controller = DesktopWidgetController(
            defaults: defaults, center: center, workspaceCenter: workspace,
            screens: { [unowned self] in screens },
            makeSurface: { [unowned self] in
                let surface = FakeSurface()
                surface.isOnScreen = surfacesOnScreen
                made.append(surface)
                return surface
            },
            clock: .init(
                now: { [unowned self] in now },
                calendar: {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "UTC")!
                    return calendar
                },
                locale: { Locale(identifier: "en_GB") }),
            schedule: { [unowned self] date, action in
                scheduled.append(date)
                pending = action
                return { [unowned self] in cancelled += 1 }
            },
            makeBattery: { [unowned self] in battery },
            mediaSession: mediaSession,
            spaceTopology: { [unowned self] in spaceTopology },
            makeSpaceMover: { [unowned self] in spaceMover },
            imageStore: imageStore)

        init(defaults: UserDefaults, imageStore: DesktopWidgetImageStore, screens: [Screen]) {
            self.defaults = defaults
            self.imageStore = imageStore
            self.screens = screens
        }

        var live: [FakeSurface] { made.filter { !$0.removed } }

        /// Runs the scheduled redraw as its timer would.
        func fire() {
            let action = pending
            pending = nil
            action?()
        }

        func screensChanged() {
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
    }

    private func makeFixture(screens: [Screen]) throws -> Fixture {
        let assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-widget-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        let imageStore = DesktopWidgetImageStore(managed: ManagedUserAssetStore(root: assetRoot))
        let fixture = Fixture(
            defaults: try TemporaryDefaults.make(for: self).defaults,
            imageStore: imageStore,
            screens: screens)
        addTeardownBlock { @MainActor in
            fixture.controller.stop()
            try? FileManager.default.removeItem(at: assetRoot)
        }
        return fixture
    }

    func testWithoutWidgetsThereIsNoWindowAndNoTimer() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        fixture.screensChanged()
        XCTAssertTrue(fixture.made.isEmpty)
        XCTAssertTrue(fixture.scheduled.isEmpty)
    }

    func testEachWidgetGoesOnTheDisplaysItIsPlacedOn() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        let clock = try fixture.store.add(.time)
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [1], "a new widget is on the main display")
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:05")

        try fixture.store.update(clock.id) { $0.placement = .all }
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [1, 2])
        XCTAssertEqual(fixture.made.count, 2, "the main display keeps its window")

        try fixture.store.update(clock.id) { $0.placement = .display(uuid: "bbbb-2", name: "Studio Display") }
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [2], "by the display's own UUID")
        XCTAssertEqual(fixture.live.count, 1)

        fixture.screens = [laptop]
        fixture.screensChanged()
        XCTAssertTrue(fixture.controller.shown.isEmpty, "a disconnected display takes its widget with it")
        fixture.screens = [laptop, external]
        fixture.screensChanged()
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [2], "and brings it back")

        try fixture.store.update(clock.id) { $0.isShown = false }
        XCTAssertTrue(fixture.live.isEmpty, "a hidden widget keeps no window")
        try fixture.store.update(clock.id) { $0.isShown = true }
        try fixture.store.remove(clock.id)
        XCTAssertTrue(fixture.live.isEmpty)
    }

    func testTheWordsChangeOnTimeAndOnlyAsOftenAsTheyNeed() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        let clock = try fixture.store.add(.time)
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_171_960), "21:06")

        fixture.now = Date(timeIntervalSince1970: 1_794_171_960)
        fixture.fire()
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:06")
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_172_020), "21:07")

        try fixture.store.update(clock.id) { $0.showsSeconds = true }
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:06:00")
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_171_961), "each second")

        try fixture.store.remove(clock.id)
        _ = try fixture.store.add(.date)
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_182_400), "dates alone wait for midnight")
    }

    func testNothingIsScheduledWhileNoWidgetCanBeSeenUntilOneCanAgain() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.surfacesOnScreen = false
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:05", "drawn, so it is right when it shows")
        XCTAssertTrue(fixture.scheduled.isEmpty, "covered, asleep or locked: no timer")
        XCTAssertNil(fixture.controller.nextChange)

        fixture.now = Date(timeIntervalSince1970: 1_794_172_200)
        let surface = try XCTUnwrap(fixture.live.first)
        surface.isOnScreen = true
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: NSObject())
        XCTAssertTrue(fixture.scheduled.isEmpty, "another window's occlusion changes nothing")
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:10", "brought up to date as it shows")
        XCTAssertEqual(fixture.scheduled.count, 1)

        surface.isOnScreen = false
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.cancelled, 1, "covered again, the timer goes")
        XCTAssertEqual(fixture.scheduled.count, 1)
    }

    func testAWakeOrAClockChangeRedrawsAtOnce() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        fixture.now = Date(timeIntervalSince1970: 1_794_200_000)
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(fixture.controller.shown.first?.text, "04:53")
        fixture.now = Date(timeIntervalSince1970: 1_794_171_907)
        fixture.center.post(name: .NSSystemClockDidChange, object: nil)
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:05")
    }

    func testAScreenChangeMovesTheWindowsAndOneThatMovesNothingTouchesNone() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        let before = try XCTUnwrap(fixture.controller.shown.first?.frame)
        for _ in 0..<30 { fixture.screensChanged() }
        XCTAssertEqual(fixture.made.count, 1)
        XCTAssertEqual(fixture.controller.shown.first?.frame, before)

        fixture.screens[0].frame.origin = NSPoint(x: -1512, y: 300)
        fixture.screensChanged()
        XCTAssertEqual(fixture.controller.shown.first?.frame, before.offsetBy(dx: -1512, dy: 300))
        XCTAssertEqual(fixture.made.count, 1, "the same window moves")
    }

    func testABatteryWidgetFollowsTheBatterysNotificationAndKeepsItOnlyWhilePlaced() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.battery.reading = BatteryReading(percent: 82, isDischarging: true)
        fixture.controller.start()
        XCTAssertEqual(fixture.battery.starts, 0, "nothing listens without a battery widget")

        let widget = try fixture.store.add(.battery)
        XCTAssertEqual(fixture.battery.starts, 1)
        let percent = (0.82).formatted(.percent.locale(Locale(identifier: "en_GB")))
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "Battery \(percent)"))
        XCTAssertTrue(fixture.scheduled.isEmpty, "the battery needs no timer")

        fixture.battery.reading = BatteryReading(percent: 83, isDischarging: false, isCharging: true)
        fixture.battery.onChange?()
        let charging = (0.83).formatted(.percent.locale(Locale(identifier: "en_GB")))
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "Charging \(charging)"))

        try fixture.store.update(widget.id) { $0.isShown = false }
        XCTAssertEqual(fixture.battery.stops, 1, "a hidden battery widget stops listening")
        try fixture.store.update(widget.id) { $0.isShown = true }
        XCTAssertEqual(fixture.battery.starts, 2)
        fixture.controller.stop()
        XCTAssertEqual(fixture.battery.stops, 2)
    }

    func testTheSunFollowsTheSunriseAndSunsetSettingsAndRedrawsWhenTheyChange() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.sun)
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "No location for sunrise and sunset"))
        XCTAssertTrue(fixture.scheduled.isEmpty, "nothing to wait for without a place")

        var solar = WallpaperSolarSettings()
        solar.source = .fixed
        solar.fixedSunriseMinute = 7 * 60 + 15
        fixture.defaults.set(try JSONEncoder().encode(solar), forKey: WallpaperAutomationStore.solarKey)
        fixture.center.post(name: WallpaperAutomationStore.didChangeNotification, object: nil)
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "Sunrise \("07:15")"), "tomorrow's")
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_182_400), "midnight comes first")
    }

    func testStoppingTakesEveryWidgetDownAndListensNoMore() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        fixture.controller.stop()
        XCTAssertTrue(fixture.live.isEmpty)
        XCTAssertTrue(fixture.controller.shown.isEmpty)
        _ = try fixture.store.add(.date)
        XCTAssertEqual(fixture.made.count, 1)
    }

    func testTheWindowsAreStackedInTheLayersOrder() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        let clock = try fixture.store.add(.time)
        let date = try fixture.store.add(.date)
        XCTAssertEqual(fixture.controller.stacking, [clock.id, date.id], "back to front: the newest in front")

        try fixture.store.move(clock.id, to: 0)
        XCTAssertEqual(fixture.controller.stacking, [date.id, clock.id])
        let raises = fixture.live.map(\.raises).reduce(0, +)
        try fixture.store.update(clock.id) { $0.size = 40 }
        XCTAssertEqual(fixture.live.map(\.raises).reduce(0, +), raises, "a change that keeps the order restacks nothing")

        try fixture.store.update(date.id) { $0.placement = .all }
        XCTAssertEqual(fixture.controller.stacking, [date.id, date.id, clock.id], "each display's window in its layer")
        try fixture.store.remove(clock.id)
        XCTAssertEqual(fixture.controller.stacking, [date.id, date.id])
    }

    // MARK: The window

    func testTheWindowSitsBetweenTheWallpaperAndTheDesktopIconsAndIsNoWallpaperWindow() {
        let window = DesktopWidgetWindow.make()
        defer { window.close() }
        XCTAssertGreaterThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)), "above the wallpaper")
        XCTAssertLessThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)), "below Finder's icons")
        XCTAssertTrue(window.ignoresMouseEvents, "a click there reaches the desktop")
        XCTAssertFalse(window.isOpaque, "only the text covers the wallpaper")
        XCTAssertFalse(window.canHide, "hiding the app hides only the panel")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(
            WallpaperPresentationPolicy.wallpaperWindows().contains(window),
            "occlusion tracking, the window audit and the posters look only at wallpaper windows")

        let widget = DesktopWidget(kind: .time)
        let text = DesktopWidgetRendering.attributedText("21:05", for: widget)
        window.show(.text(text), look: .init(), padding: 4, frame: NSRect(x: 10, y: 20, width: 300, height: 140))
        XCTAssertEqual(window.frame, NSRect(x: 10, y: 20, width: 300, height: 140))
        XCTAssertEqual(window.shownText, "21:05")

        // Space pinning removes `.canJoinAllSpaces` when mover places the window, and falls back when unavailable.
        let mover = FakeSpaceMover()
        window.applySpacePinning([42], using: mover)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(mover.placeCalls.last?.spaces, [42])
        mover.canPlace = false
        window.applySpacePinning([99], using: mover)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces), "falls back cleanly when place() fails")
        window.applySpacePinning(nil, using: nil)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testNowPlayingConsumesMediaLazilyOnlyWhileOnScreenAndIgnoresTimelineTicks() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.surfacesOnScreen = false
        fixture.controller.start()
        XCTAssertEqual(fixture.mediaProvider.consumers, 0, "no media consumer without a Now Playing widget")
        XCTAssertFalse(fixture.controller.isConsumingMediaSession)

        // Covered screen: widget window exists, but media session is NOT consumed.
        let np = try fixture.store.add(.nowPlaying)
        XCTAssertEqual(fixture.mediaProvider.consumers, 0, "covered display must consume zero media energy")
        XCTAssertTrue(fixture.scheduled.isEmpty, "Now Playing schedules zero timers")

        // Uncover screen -> media consumption starts lazily.
        let surface = try XCTUnwrap(fixture.live.first)
        surface.isOnScreen = true
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.mediaProvider.consumers, 1)
        XCTAssertTrue(fixture.controller.isConsumingMediaSession)
        XCTAssertEqual(surface.drawing, .empty, "idle collapses when hidesWhenIdle is on")

        // Discrete track + playback events update the static card.
        fixture.mediaProvider.currentProperties = SystemMediaProperties(title: "Time", artist: "Pink Floyd")
        fixture.mediaProvider.currentPlayback = .playing
        fixture.mediaProvider.onPropertiesChanged?(fixture.mediaProvider.currentProperties)
        fixture.mediaProvider.onPlaybackChanged?(.playing)
        XCTAssertEqual(surface.text, "Time — Pink Floyd")
        XCTAssertTrue(fixture.scheduled.isEmpty, "playing track schedules zero timers")

        // Timeline ticks NEVER trigger a redraw.
        let drawsBeforeTicks = surface.showCount
        for second in 1...10 {
            fixture.mediaProvider.onTimelineChanged?(SystemMediaTimeline(position: Double(second), duration: 240))
        }
        XCTAssertEqual(surface.showCount, drawsBeforeTicks, "timeline ticks never redraw a static widget")

        // Stopping playback collapses the card automatically.
        fixture.mediaProvider.onPlaybackChanged?(.stopped)
        XCTAssertEqual(surface.drawing, .empty)

        // Covering the screen releases the media session immediately.
        surface.isOnScreen = false
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.mediaProvider.consumers, 0)
        XCTAssertFalse(fixture.controller.isConsumingMediaSession)

        // Hiding the widget also drops consumption.
        surface.isOnScreen = true
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.mediaProvider.consumers, 1)
        try fixture.store.update(np.id) { $0.isShown = false }
        XCTAssertEqual(fixture.mediaProvider.consumers, 0)
    }

    func testWallpaperScopedWidgetFiltersByActiveDisplayWallpaperAndGatesMediaSession() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        let widget = try fixture.store.add(.nowPlaying)
        try fixture.store.update(widget.id) {
            $0.placement = .all
            $0.scope = .wallpapers(["aurora"])
        }
        XCTAssertTrue(fixture.live.isEmpty, "no display currently shows aurora")
        XCTAssertEqual(fixture.mediaProvider.consumers, 0)

        fixture.controller.updateActiveWallpapers([1: "rain", 2: "aurora"])
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [2], "only the display showing aurora")
        XCTAssertEqual(fixture.mediaProvider.consumers, 1, "active on screen 2 -> consumes media")

        fixture.controller.updateActiveWallpapers([1: "rain", 2: "night"])
        XCTAssertTrue(fixture.live.isEmpty)
        XCTAssertEqual(fixture.mediaProvider.consumers, 0, "matching wallpaper left -> stops consuming")

        // Bridge monitor row mapping resolves standalone and mirrored displays.
        let rows = [
            BridgeMonitorInfoRow(
                displayId: "1", title: "Built-in", wallpaperId: "aurora", wallpaperTitle: "Aurora",
                mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
                targetFps: "30", audioResponse: false),
            BridgeMonitorInfoRow(
                displayId: "2", title: "Mirror", wallpaperId: "", wallpaperTitle: "",
                mirrorTargetDisplayId: "1", mirrorTargetTitle: "Built-in", scalingMode: "fill",
                targetFps: "30", audioResponse: false),
        ]
        let mapped = DesktopWidgetController.activeWallpapers(from: rows)
        XCTAssertEqual(mapped[1], "aurora")
        XCTAssertEqual(mapped[2], "aurora")
    }

    func testSpaceScopedWidgetPinsWindowsAndFallsBackWhenPrivateSpaceAPIUnavailable() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.spaceTopology = [
            "1": WallpaperDisplaySpaces(
                displayUUID: "AAAA-1",
                spaces: [
                    WallpaperDesktopSpace(id: "default", number: 1, managedID: 10),
                    WallpaperDesktopSpace(id: "space-2", number: 2, managedID: 20),
                ],
                current: "default", currentManagedID: 10),
        ]
        fixture.controller.start()
        let clock = try fixture.store.add(.time)
        try fixture.store.update(clock.id) { $0.scope = .spaces(["space-2"]) }

        let surface = try XCTUnwrap(fixture.live.first)
        XCTAssertEqual(surface.pinnedSpaces, [20])
        XCTAssertTrue(surface.usedSpaceMover)

        // Pinning to a Space not present on this display removes the surface from this display.
        try fixture.store.update(clock.id) { $0.scope = .spaces(["other-display-space"]) }
        XCTAssertTrue(fixture.live.isEmpty)

        // When Space topology becomes unavailable, falls back gracefully to all Spaces.
        fixture.spaceTopology = nil
        fixture.center.post(name: WallpaperSpaceMonitor.didChangeNotification, object: nil)
        let fallbackSurface = try XCTUnwrap(fixture.live.first)
        XCTAssertNil(fallbackSurface.pinnedSpaces, "graceful fallback to .canJoinAllSpaces")
        XCTAssertFalse(fallbackSurface.usedSpaceMover)
    }

    func testStopAndStartPreservesUnreferencedStickerForUndoWhileLaunchPruneReclaimsIt() throws {
        let fixture = try makeFixture(screens: [laptop])
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-sticker-\(UUID().uuidString).png")
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try pngData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // Imported sticker not currently in saved widgets (as when a deleted widget is still on Undo).
        let asset = try fixture.imageStore.importImage(from: sourceURL)
        XCTAssertNotNil(fixture.imageStore.loadImage(for: asset))

        // Presentation Mode / Toggle Desktop Widgets cycles stop() + start() without pruning.
        fixture.controller.start()
        fixture.controller.stop()
        fixture.controller.start()
        XCTAssertNotNil(fixture.imageStore.loadImage(for: asset),
                        "restarting the controller mid-session must keep stickers reachable by Undo")

        // Launch-only cleanup reclaims orphaned stickers.
        fixture.controller.pruneUnusedImagesOnLaunch()
        XCTAssertNil(fixture.imageStore.loadImage(for: asset),
                     "launch cleanup removes stickers no saved widget references")
    }
}
