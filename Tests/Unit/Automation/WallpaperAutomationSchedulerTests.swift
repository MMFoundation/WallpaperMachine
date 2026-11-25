import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperAutomationSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var rules: WallpaperAutomationStore!
    private var focus: FocusFilterState!
    private var states: [String: WallpaperAutomationDisplayState] = [:]
    private var changes: [(String, WallpaperAutomationTarget)] = []
    private var restores = 0
    private var running = true
    private var dark = false
    private var presentationPaused = false
    private var onBattery = false
    private var appSwitches: [String: AppWallpaperSwitch] = [:]
    private var targetDisplay = "primary"
    private var clock = Date()
    private let queue = UserCommandQueue()
    private var failures = Set<String>()
    private var spaceVisits: [String: WallpaperSpaceVisit] = [:]
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        rules = WallpaperAutomationStore(defaults: defaults)
        focus = FocusFilterState(defaults: defaults)
        var playlist = DisplayPlaylist()
        playlist.mode = .rotate; playlist.source = .list; playlist.wallpaperIDs = ["original", "other"]
        states = ["primary": .init(playlist: playlist, wallpaperID: "original"), "secondary": .init(playlist: .init(), wallpaperID: "second")]
        changes = []; restores = 0; running = true; dark = false; presentationPaused = false; onBattery = false
        appSwitches = [:]; failures = []; targetDisplay = "primary"
        spaceVisits = [:]
        clock = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10))!
    }
    private func settle() async { for _ in 0..<70 { await Task.yield() } }
    private func target(_ id: String, _ kind: WallpaperAutomationTarget.Kind = .wallpaper) -> WallpaperAutomationTarget { .init(kind: kind, id: id) }
    private func scheduler(appearanceCenter: NotificationCenter = NotificationCenter(),
                           center: NotificationCenter = .default,
                           spaceMonitor: WallpaperSpaceMonitor? = nil) -> WallpaperAutomationScheduler {
        WallpaperAutomationScheduler(store: rules, focus: focus, displays: { Array(self.states.keys) }, targetDisplay: { self.targetDisplay },
            canRun: { _ in self.running }, capture: { self.states[$0]! }, queue: { display, action in
                try await self.queue.runReporting(slot: BridgeStore.activationSlot(displayId: display), origin: .automation, action)
            }, apply: { target, display in
                self.changes.append((display, target))
                if self.failures.contains(target.id) { throw AutomationError(message: "Fixture unavailable") }
                if target.kind == .wallpaper {
                    self.states[display]?.wallpaperID = target.id
                    self.states[display]?.playlist.mode = .off
                    self.states[display]?.playlist.planID = nil
                } else {
                    self.states[display]?.playlist.mode = .rotate
                    self.states[display]?.playlist.planID = target.id
                }
            }, restore: { original, display, preserve in
                self.restores += 1
                self.states[display]?.playlist = original.playlist
                if !preserve { self.states[display]?.wallpaperID = original.wallpaperID }
            }, dark: { self.dark }, now: { self.clock }, calendar: calendar,
            center: center, appearanceCenter: appearanceCenter,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            spaceMonitor: spaceMonitor, spaceVisit: { self.spaceVisits[$0] },
            isPresentationPaused: { self.presentationPaused },
            onBattery: { self.onBattery },
            appWallpaperSwitch: { self.appSwitches[$0] })
    }

    func testAppearanceAndSpaceInputsReportDistinctNotificationsWithoutChangingSelection() {
        let appearanceCenter = NotificationCenter()
        let spaceMonitor = WallpaperSpaceMonitor()
        let scheduler = scheduler(appearanceCenter: appearanceCenter, spaceMonitor: spaceMonitor)
        var received: [Notification.Name] = []
        scheduler.onInputsChanged = { received.append($0) }
        scheduler.start()
        defer { scheduler.stop() }

        let appearanceChanged = Notification.Name("AppleInterfaceThemeChangedNotification")
        appearanceCenter.post(name: appearanceChanged, object: nil)
        NotificationCenter.default.post(name: WallpaperSpaceMonitor.didChangeNotification, object: spaceMonitor)

        XCTAssertEqual(received, [appearanceChanged, WallpaperSpaceMonitor.didChangeNotification])
        XCTAssertEqual(states["primary"]?.wallpaperID, "original")
        XCTAssertTrue(changes.isEmpty)
    }

    func testTimeRulesCatchUpOnceWaitWhenPausedAndRespectManualChoice() async throws {
        try rules.update("primary") {
            $0.mode = .schedule
            $0.rules = [.init(minute: 8 * 60, target: target("morning")), .init(minute: 12 * 60, target: target("noon")), .init(minute: 14 * 60, target: target("afternoon"))]
        }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "morning")
        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        running = false; clock.addTimeInterval(5 * 3600)
        scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["morning"])
        running = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["morning", "afternoon"])
        scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.count, 2)
    }

    func testSpaceChoicesRespectManualSelectionUntilAnotherDesktopVisit() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        states["primary"]?.wallpaperID = "manual"; scheduler.noteManualChoice("primary")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        spaceVisits["primary"] = .init(spaceID: "unmapped", token: "visit2")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit3")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit4")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "forest")
    }

    func testADesktopWithoutAChoiceShowsDesktop1sAsANewDesktopDoes() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit1", firstSpaceID: "a")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest")

        spaceVisits["primary"] = .init(spaceID: "new", token: "visit2", firstSpaceID: "a")
        XCTAssertEqual(scheduler.pendingTarget(on: "primary"), target("ocean"), "the new desktop waits for Desktop 1's")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        XCTAssertNil(rules.configuration(for: "primary").spaces["new"], "following Desktop 1 saves nothing for the desktop")

        try rules.update("primary") { $0.spaces["a"] = nil }
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit3", firstSpaceID: "a"); scheduler.evaluate(); await settle()
        spaceVisits["primary"] = .init(spaceID: "new", token: "visit4", firstSpaceID: "a"); scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest", "with no choice on Desktop 1 either, the display keeps what it shows")
    }

    func testADesktopFollowingDesktop1FollowsTheNewDesktop1WhenTheDesktopsAreReordered() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "new", token: "visit1", firstSpaceID: "a")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")

        // Desktop b is moved to the front while the person stays on the same desktop.
        spaceVisits["primary"] = .init(spaceID: "new", token: "visit1", firstSpaceID: "b")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest", "the desktop shows the new Desktop 1's wallpaper")
    }

    func testAWallpaperChosenByHandBecomesTheCurrentDesktopsOwn() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")

        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary", wallpaperID: "manual")
        await settle()
        XCTAssertEqual(rules.configuration(for: "primary").spaces["a"], target("manual"))
        XCTAssertEqual(changes.map { $0.1.id }, ["ocean"], "what was chosen is on screen already")

        spaceVisits["primary"] = .init(spaceID: "b", token: "visit2")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest")
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit3")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual", "coming back keeps the desktop's own wallpaper")

        spaceVisits["primary"] = .init(spaceID: "new", token: "visit4")
        scheduler.evaluate(); await settle()
        states["primary"]?.wallpaperID = "picked"
        scheduler.noteManualChoice("primary", wallpaperID: "picked")
        XCTAssertEqual(rules.configuration(for: "primary").spaces["new"], target("picked"),
                       "a desktop without a choice gets one")
    }

    func testAManualChoiceOutsideTheSpaceModeChangesNoDesktop() async throws {
        try rules.update("primary") { $0.mode = .schedule; $0.spaces = [:] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()

        scheduler.noteManualChoice("primary", wallpaperID: "manual")

        XCTAssertTrue(rules.configuration(for: "primary").spaces.isEmpty)
    }

    func testSpaceChoiceWaitsWhilePausedAndBlocksPosterPublicationUntilSettled() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces["a"] = target("ocean") }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1"); running = false
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(scheduler.selectionIsSettled(on: "primary"))
        XCTAssertEqual(scheduler.pendingTarget(on: "primary"), target("ocean"), "the desktop's choice waits")
        XCTAssertFalse(scheduler.isApplying(on: "primary"), "it is not running while paused")
        running = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        XCTAssertTrue(scheduler.selectionIsSettled(on: "primary"))
        XCTAssertNil(scheduler.pendingTarget(on: "primary"))
    }

    func testFocusEndsOnlyAfterSpaceInformationRecoversAndUsesTheNewDesktopChoice() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary")); await settle()
        spaceVisits["primary"] = nil; focus.set(nil); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        XCTAssertNotNil(rules.focusRestore["primary"])
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit2")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest")
        XCTAssertNil(rules.focusRestore["primary"])
    }

    func testAppearanceChangesOnceAndAStoredHandledEventSurvivesRestart() async throws {
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("light"); $0.dark = target("dark") }
        var scheduler = scheduler(); scheduler.start(); await settle(); scheduler.stop()
        states["primary"]?.wallpaperID = "manual"
        rules = WallpaperAutomationStore(defaults: defaults)
        scheduler = self.scheduler(); scheduler.start(); defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        dark = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "dark")
        XCTAssertEqual(changes.map { $0.1.id }, ["light", "dark"])
    }

    func testFocusOverridesThenRestoresWallpaperAndPlaylist() async throws {
        let original = states["primary"]
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        XCTAssertNotNil(WallpaperAutomationStore(defaults: defaults).focusRestore["primary"])
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertTrue(rules.focusRestore.isEmpty)
        XCTAssertEqual(restores, 1)
    }

    func testManualWallpaperDuringFocusSurvivesExitButTheOldPlaylistReturns() async throws {
        let original = states["primary"]!.playlist
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary")
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        XCTAssertEqual(states["primary"]?.playlist, original)
    }

    func testEditingThePlaylistDuringFocusWinsOverRestoration() async throws {
        focus.set(nil, selection: .init(target: target("focus-plan", .playlist), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        states["primary"]?.playlist.interval = 120
        let edited = states["primary"]
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], edited)
        XCTAssertEqual(restores, 0)
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    func testDeletingTheFocusSavedPlanKeepsItsCopiedPlaylistAndStillRestores() async throws {
        let original = states["primary"]
        focus.set(nil, selection: .init(target: target("temporary", .playlist), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        states["primary"]?.playlist.planID = nil
        try rules.forgetPlan("temporary")
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertEqual(restores, 1)
    }

    func testChangingFocusKeepsTheOriginalBaselineAndPinsAnImplicitDisplay() async throws {
        let original = states["primary"]
        focus.set(nil, selection: .init(target: target("first"), displayID: nil))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        targetDisplay = "secondary"
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["secondary"]?.wallpaperID, "second")
        focus.set(nil, selection: .init(target: target("next"), displayID: "primary")); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "next")
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
    }

    func testFocusExitUsesTheLatestScheduleInsteadOfReplayingMissedChanges() async throws {
        try rules.update("primary") { $0.mode = .schedule; $0.rules = [.init(minute: 480, target: target("morning")), .init(minute: 720, target: target("noon"))] }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary")); await settle()
        clock.addTimeInterval(3 * 3600); scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        focus.set(nil); await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["morning", "focus", "noon"])
        XCTAssertEqual(restores, 0)
    }

    func testInterruptedFocusPublicationCanRestoreAfterRelaunch() async throws {
        let original = states["primary"]!
        try rules.rememberFocus(.init(key: "focus:interrupted", before: original, expectedPlaylist: original.playlist, pending: true), on: "primary")
        states["primary"]?.playlist.mode = .off
        states["primary"]?.wallpaperID = "partial"
        rules = WallpaperAutomationStore(defaults: defaults)
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    func testFailureIsReportedOnceAndExplicitRetryCanRecover() async throws {
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("missing") }
        failures = ["missing"]
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.count, 1)
        XCTAssertNotNil(rules.errors["primary"])
        failures = []; rules.retry("primary"); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "missing")
        XCTAssertNil(rules.errors["primary"])
    }

    func testAQueuedRuleCannotReplaceANewerManualCommand() async throws {
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("automatic") }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        let manual = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
                states["primary"]?.wallpaperID = "manual"
                scheduler.noteManualChoice("primary")
            }
        }
        await settle()
        try XCTUnwrap(release).resume()
        await blocker.value; await manual.value; await settle()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
    }

    /// An update reloading the display's files while a Focus wallpaper waits its turn takes the
    /// Focus change's place in the line. Nothing the user chose replaced it, so it is applied
    /// once the queue is free, and leaving Focus then restores what was there before.
    func testAFocusChangeReplacedByAReloadWhileWaitingIsStillApplied() async throws {
        let original = states["primary"]
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertTrue(changes.isEmpty, "the Focus change waits behind the running command")

        let reload = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary"), origin: .updateReload) {}
        }
        await settle()
        try XCTUnwrap(release).resume()
        await blocker.value; _ = await reload.value; await settle()

        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        XCTAssertNotNil(rules.focusRestore["primary"])
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertEqual(restores, 1)
    }

    func testARuleThatFindsAManualCommandWaitingGivesWayAndDoesNotRetry() async throws {
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        let manual = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary")) { states["primary"]?.wallpaperID = "manual" }
        }
        await settle()
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("automatic") }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        try XCTUnwrap(release).resume()
        await blocker.value; await manual.value; await settle()

        scheduler.evaluate(); await settle()
        XCTAssertTrue(changes.isEmpty, "The rule's event is spent, not queued again behind the user's choice")
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        XCTAssertNil(rules.errors["primary"], "Giving way is not a failure to report")
    }

    func testARuleThatFindsAManualCommandRunningGivesWayAndDoesNotReplaceIt() async throws {
        var release: CheckedContinuation<Void, Never>?
        let manual = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
                await withCheckedContinuation { release = $0 }
                states["primary"]?.wallpaperID = "manual"
            }
        }
        await settle()
        XCTAssertTrue(queue.isBusy)
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("automatic") }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertTrue(queue.waiting.isEmpty, "The rule does not queue up behind the user's command")
        try XCTUnwrap(release).resume()
        await manual.value; await settle()

        scheduler.evaluate(); await settle()
        XCTAssertTrue(changes.isEmpty, "The rule's event is spent, not applied over the user's choice")
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        XCTAssertNil(rules.errors["primary"], "Giving way is not a failure to report")
    }

    func testRapidSpaceChangesDiscardQueuedChoicesForDesktopsAlreadyLeft() async throws {
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest"), "c": target("mountain")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit2"); scheduler.evaluate()
        spaceVisits["primary"] = .init(spaceID: "c", token: "visit3"); scheduler.evaluate()
        try XCTUnwrap(release).resume(); await blocker.value; await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["mountain"])
    }

    // MARK: Precedence & nested transactional restore

    func testBatteryOverrideAppliesPerDisplayOverGlobalAndTransactionallyRestoresOnAC() async throws {
        let originalPrimary = states["primary"]
        let originalSecondary = states["secondary"]
        try rules.setGlobalBatteryTarget(target("global-battery"))
        try rules.update("primary") { $0.batteryTarget = target("primary-battery") }

        let center = NotificationCenter()
        let scheduler = scheduler(center: center); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"], originalPrimary, "on AC power, battery targets do not apply")
        XCTAssertEqual(states["secondary"], originalSecondary)

        onBattery = true
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "primary-battery", "per-display battery target wins over global")
        XCTAssertEqual(states["secondary"]?.wallpaperID, "global-battery", "global battery target covers other displays")
        XCTAssertEqual(rules.activeOverrides["primary"], .battery)
        XCTAssertEqual(rules.activeOverrides["secondary"], .battery)

        onBattery = false
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"], originalPrimary, "AC restores original wallpaper and playlist")
        XCTAssertEqual(states["secondary"], originalSecondary)
        XCTAssertTrue(rules.focusRestore.isEmpty)
        XCTAssertNil(rules.activeOverrides["primary"])
        XCTAssertNil(rules.activeOverrides["secondary"])
        XCTAssertEqual(restores, 2)

        // Unplugging a second time re-applies cleanly after restore.
        onBattery = true
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "primary-battery")
        XCTAssertEqual(states["secondary"]?.wallpaperID, "global-battery")
    }

    func testFullPrecedenceCascadeAndTransactionalFallThroughAcrossFocusAppBatteryAndBase() async throws {
        let original = states["primary"]
        try rules.update("primary") { $0.batteryTarget = target("battery") }
        let appRule = AppWallpaperSwitch(
            ruleID: UUID(), bundleIdentifier: "com.apple.dt.Xcode", condition: .frontmost,
            target: target("xcode"), displayID: "primary")

        let center = NotificationCenter()
        let scheduler = scheduler(center: center); scheduler.start(); defer { scheduler.stop() }; await settle()

        // 1. Battery turns on.
        onBattery = true
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "battery")
        XCTAssertEqual(rules.activeOverrides["primary"], .battery)

        // 2. App-driven switch overrides Battery.
        appSwitches["primary"] = appRule
        center.post(name: AppRuleMonitor.wallpaperSwitchDidChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "xcode")
        XCTAssertEqual(rules.activeOverrides["primary"], .app)

        // 3. Focus overrides App-driven switch.
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        center.post(name: FocusFilterState.didChangeNotification, object: focus)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        XCTAssertEqual(rules.activeOverrides["primary"], .focus)

        // 4. Focus ends while App and Battery are still active -> falls through to App.
        focus.set(nil)
        center.post(name: FocusFilterState.didChangeNotification, object: focus)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "xcode")
        XCTAssertEqual(rules.activeOverrides["primary"], .app)
        XCTAssertEqual(restores, 0, "pre-override baseline stays preserved while lower override is active")

        // 5. Returning to AC while App is active keeps the App wallpaper with no reload.
        let changesBeforeAC = changes.count
        onBattery = false
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "xcode")
        XCTAssertEqual(changes.count, changesBeforeAC, "AC transition under higher-priority App switch is a no-op")
        XCTAssertEqual(rules.activeOverrides["primary"], .app)

        // 6. Unplug again, then App exits -> falls through to Battery wallpaper!
        onBattery = true
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        appSwitches["primary"] = nil
        center.post(name: AppRuleMonitor.wallpaperSwitchDidChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "battery")
        XCTAssertEqual(rules.activeOverrides["primary"], .battery)

        // 7. Return to AC with no remaining overrides -> transactionally restores original wallpaper + playlist.
        onBattery = false
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertNil(rules.activeOverrides["primary"])
        XCTAssertTrue(rules.focusRestore.isEmpty)
        XCTAssertEqual(restores, 1)
    }

    func testFocusEndingWhileOnBatteryRestoresBatteryWallpaperThenACRestoresBaseSchedule() async throws {
        try rules.update("primary") {
            $0.mode = .schedule
            $0.rules = [.init(minute: 8 * 60, target: target("morning")), .init(minute: 12 * 60, target: target("noon"))]
            $0.batteryTarget = target("battery")
        }
        let center = NotificationCenter()
        let scheduler = scheduler(center: center); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "morning")

        onBattery = true
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        center.post(name: FocusFilterState.didChangeNotification, object: focus)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")

        // Advance past noon while Focus is active, then end Focus while still on Battery.
        clock.addTimeInterval(3 * 3600)
        focus.set(nil)
        center.post(name: FocusFilterState.didChangeNotification, object: focus)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "battery", "Focus exit on battery falls through to Battery")

        // Plug in AC -> catches up to noon schedule instead of replaying morning.
        onBattery = false
        center.post(name: PowerSourceMonitor.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "noon")
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    func testPresentationModeAndManualPauseOutrankFocusAppBatteryAndRestore() async throws {
        let original = states["primary"]
        try rules.update("primary") { $0.batteryTarget = target("battery") }
        let appRule = AppWallpaperSwitch(
            ruleID: UUID(), bundleIdentifier: "com.example.IDE", condition: .running,
            target: target("ide"), displayID: "primary")

        let center = NotificationCenter()
        presentationPaused = true
        let scheduler = scheduler(center: center); scheduler.start(); defer { scheduler.stop() }

        // While Presentation Mode / Manual Pause is active, Focus, App, and Battery must not mutate wallpapers.
        onBattery = true
        appSwitches["primary"] = appRule
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"], original, "Presentation / Manual Pause outranks Focus, App and Battery")
        XCTAssertTrue(changes.isEmpty)

        // Exiting Presentation Mode catches up immediately to the highest active tier (Focus).
        presentationPaused = false
        center.post(name: PresentationModeController.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")

        // Entering Presentation Mode again blocks restoration when Focus/App/Battery clear.
        presentationPaused = true
        focus.set(nil); appSwitches["primary"] = nil; onBattery = false
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus", "restoration waits while Presentation / Manual Pause is active")

        // Exiting Presentation Mode completes transactional restore.
        presentationPaused = false
        center.post(name: PresentationModeController.didChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    func testBatteryAndAppOverridesRecoverAfterRelaunchWhenConditionHasEnded() async throws {
        let original = states["primary"]
        try rules.update("primary") { $0.batteryTarget = target("battery") }
        onBattery = true
        var scheduler = self.scheduler(); scheduler.start(); await settle(); scheduler.stop()
        XCTAssertEqual(states["primary"]?.wallpaperID, "battery")
        XCTAssertNotNil(WallpaperAutomationStore(defaults: defaults).focusRestore["primary"])

        // Simulated relaunch after plugging into AC while the app was closed.
        onBattery = false
        rules = WallpaperAutomationStore(defaults: defaults)
        scheduler = self.scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    // MARK: Spaces stacking with Appearance and Schedule

    func testSpacesStackedWithAppearanceUsesExplicitSpaceOverridesAndAppearanceFallback() async throws {
        try rules.update("primary") {
            $0.mode = .appearance
            $0.spacesEnabled = true
            $0.light = target("day-light")
            $0.dark = target("night-dark")
            $0.spaces = ["space-code": target("coding")]
        }
        spaceVisits["primary"] = .init(spaceID: "space-main", token: "v1", firstSpaceID: "space-main")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "day-light", "unpinned Space follows light appearance")

        // System appearance switches to dark while staying on the unpinned Space.
        dark = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "night-dark", "unpinned Space reacts to dark appearance")

        // Swiping to a pinned Space uses its explicit override.
        spaceVisits["primary"] = .init(spaceID: "space-code", token: "v2", firstSpaceID: "space-main")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "coding", "explicit Space override wins over appearance")

        // System appearance switches back to light while on the pinned Space -> stays on pinned Space wallpaper.
        dark = false; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "coding")

        // Swiping back to the unpinned Space applies light appearance.
        spaceVisits["primary"] = .init(spaceID: "space-main", token: "v3", firstSpaceID: "space-main")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "day-light")

        // A manual choice on an unpinned stacked Space is temporary and does not permanently pin that Space.
        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary", wallpaperID: "manual")
        XCTAssertNil(rules.configuration(for: "primary").spaces["space-main"])
        dark = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "night-dark", "next appearance event resumes stacked rule")

        // A manual choice on an already-pinned Space updates that Space's override.
        spaceVisits["primary"] = .init(spaceID: "space-code", token: "v4", firstSpaceID: "space-main")
        scheduler.evaluate(); await settle()
        states["primary"]?.wallpaperID = "coding-v2"
        scheduler.noteManualChoice("primary", wallpaperID: "coding-v2")
        XCTAssertEqual(rules.configuration(for: "primary").spaces["space-code"], target("coding-v2"))
    }

    func testSpacesStackedWithScheduleAndOverridesRestoreCorrectTargetPerSpace() async throws {
        try rules.update("primary") {
            $0.mode = .schedule
            $0.spacesEnabled = true
            $0.rules = [
                .init(minute: 8 * 60, target: target("morning")),
                .init(minute: 14 * 60, target: target("afternoon")),
            ]
            $0.spaces = ["space-pinned": target("pinned-daynight", .playlist)]
            $0.batteryTarget = target("battery")
        }
        spaceVisits["primary"] = .init(spaceID: "space-1", token: "v1", firstSpaceID: "space-1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "morning")

        // Battery override takes over while on unpinned Space; time advances past 14:00.
        onBattery = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "battery")
        clock.addTimeInterval(5 * 3600)
        // Return to AC -> catches up to afternoon schedule on the unpinned Space.
        onBattery = false; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "afternoon")

        // Enter pinned Space with a saved playlist target (e.g. Day/Night playlist).
        spaceVisits["primary"] = .init(spaceID: "space-pinned", token: "v2", firstSpaceID: "space-1")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.playlist.planID, "pinned-daynight")

        // Manual choice during Battery override does NOT overwrite the pinned Space.
        onBattery = true; scheduler.evaluate(); await settle()
        states["primary"]?.wallpaperID = "manual-during-battery"
        scheduler.noteManualChoice("primary", wallpaperID: "manual-during-battery")
        XCTAssertEqual(rules.configuration(for: "primary").spaces["space-pinned"], target("pinned-daynight", .playlist))
    }
}
