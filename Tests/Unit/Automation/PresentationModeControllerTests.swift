import XCTest
@testable import WallpaperMachine

/// One-click Presentation Mode save/restore semantics and opt-in Finder desktop icons guardrail.
@MainActor
final class PresentationModeControllerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testDefaultPresentationModePausesMutesHidesWidgetsAndLeavesFinderUntouched() async throws {
        XCTAssertFalse(PresentationModeController.hidesDesktopIcons(in: defaults), "hiding Finder icons is off by default")

        var paused = false
        var muted = false
        var widgetsHidden = false
        var iconReads = 0
        var iconWrites: [Bool] = []
        var changes = 0

        let controller = PresentationModeController(
            defaults: defaults,
            isPaused: { paused },
            setPaused: { paused = $0 },
            isMuted: { muted },
            setMuted: { muted = $0 },
            areDesktopWidgetsHidden: { widgetsHidden },
            setDesktopWidgetsHidden: { widgetsHidden = $0 },
            areDesktopIconsShown: { iconReads += 1; return true },
            setDesktopIconsShown: { iconWrites.append($0) })
        controller.onChange = { changes += 1 }

        try await controller.toggle()
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(paused)
        XCTAssertTrue(muted)
        XCTAssertTrue(widgetsHidden)
        XCTAssertEqual(iconReads, 0, "Finder must never be touched when opt-in is off")
        XCTAssertTrue(iconWrites.isEmpty)
        XCTAssertEqual(changes, 1)

        try await controller.toggle()
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(paused)
        XCTAssertFalse(muted)
        XCTAssertFalse(widgetsHidden)
        XCTAssertEqual(iconReads, 0)
        XCTAssertTrue(iconWrites.isEmpty)
        XCTAssertEqual(changes, 2)
    }

    func testPresentationModePreservesAlreadyPausedMutedAndHiddenStatesOnRestore() async throws {
        var paused = true
        var muted = true
        var widgetsHidden = true
        var pauseCalls = 0
        var muteCalls = 0
        var widgetCalls = 0

        let controller = PresentationModeController(
            defaults: defaults,
            isPaused: { paused },
            setPaused: { paused = $0; pauseCalls += 1 },
            isMuted: { muted },
            setMuted: { muted = $0; muteCalls += 1 },
            areDesktopWidgetsHidden: { widgetsHidden },
            setDesktopWidgetsHidden: { widgetsHidden = $0; widgetCalls += 1 },
            areDesktopIconsShown: { true },
            setDesktopIconsShown: { _ in })

        try await controller.activate()
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(pauseCalls, 0)
        XCTAssertEqual(muteCalls, 0)
        XCTAssertEqual(widgetCalls, 0)

        try await controller.deactivate()
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(paused, "already-paused playback stays paused")
        XCTAssertTrue(muted, "already-muted wallpapers stay muted")
        XCTAssertTrue(widgetsHidden, "already-hidden widgets stay hidden")
        XCTAssertEqual(pauseCalls, 0)
        XCTAssertEqual(muteCalls, 0)
        XCTAssertEqual(widgetCalls, 0)
    }

    func testOptInDesktopIconsHidesAndRestoresOnlyWhenIconsWereOriginallyShown() async throws {
        PresentationModeController.setHidesDesktopIcons(true, in: defaults)
        XCTAssertTrue(PresentationModeController.hidesDesktopIcons(in: defaults))

        var paused = false
        var muted = false
        var widgetsHidden = false
        var iconsShown = true
        var iconWrites: [Bool] = []

        let controller = PresentationModeController(
            defaults: defaults,
            isPaused: { paused },
            setPaused: { paused = $0 },
            isMuted: { muted },
            setMuted: { muted = $0 },
            areDesktopWidgetsHidden: { widgetsHidden },
            setDesktopWidgetsHidden: { widgetsHidden = $0 },
            areDesktopIconsShown: { iconsShown },
            setDesktopIconsShown: {
                iconWrites.append($0)
                iconsShown = $0
            })

        try await controller.activate()
        XCTAssertFalse(iconsShown)
        XCTAssertEqual(iconWrites, [false])

        try await controller.deactivate()
        XCTAssertTrue(iconsShown)
        XCTAssertEqual(iconWrites, [false, true])

        // If the user already hid icons beforehand, Presentation Mode leaves them hidden.
        iconsShown = false
        iconWrites = []
        try await controller.activate()
        XCTAssertEqual(iconWrites, [])
        try await controller.deactivate()
        XCTAssertFalse(iconsShown)
        XCTAssertEqual(iconWrites, [])
    }

    func testRapidDoublePressDuringAsyncPauseDoesNotCorruptSavedState() async throws {
        var paused = false
        var muted = false
        var widgetsHidden = false
        var pauseRequests: [Bool] = []
        var pendingPause: CheckedContinuation<Void, Never>?

        let controller = PresentationModeController(
            defaults: defaults,
            isPaused: { paused },
            setPaused: { target in
                pauseRequests.append(target)
                await withCheckedContinuation { continuation in
                    pendingPause = continuation
                }
                paused = target
            },
            isMuted: { muted },
            setMuted: { muted = $0 },
            areDesktopWidgetsHidden: { widgetsHidden },
            setDesktopWidgetsHidden: { widgetsHidden = $0 },
            areDesktopIconsShown: { true },
            setDesktopIconsShown: { _ in })

        // Start entering presentation mode and suspend mid-way at `await setPaused(true)`.
        let firstEnter = Task { try await controller.toggle() }
        while pendingPause == nil { await Task.yield() }

        // A second rapid toggle while the first is in flight is ignored instead of re-entering.
        try await controller.toggle()
        XCTAssertEqual(pauseRequests, [true], "in-flight activation ignores re-entrant toggle")

        pendingPause?.resume()
        pendingPause = nil
        try await firstEnter.value

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(
            controller.savedState,
            PresentationModeController.SavedState(
                wasPaused: false, wasMuted: false, wereWidgetsHidden: false, hidDesktopIcons: false))
        XCTAssertTrue(paused)
        XCTAssertTrue(muted)
        XCTAssertTrue(widgetsHidden)

        // Start exiting presentation mode and suspend mid-way at `await setPaused(false)`.
        let firstExit = Task { try await controller.toggle() }
        while pendingPause == nil { await Task.yield() }

        // A rapid toggle during deactivation must not re-activate over partial teardown.
        try await controller.toggle()
        XCTAssertEqual(pauseRequests, [true, false], "in-flight deactivation ignores re-entrant toggle")

        pendingPause?.resume()
        pendingPause = nil
        try await firstExit.value

        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.savedState)
        XCTAssertFalse(paused)
        XCTAssertFalse(muted)
        XCTAssertFalse(widgetsHidden)
    }
}
