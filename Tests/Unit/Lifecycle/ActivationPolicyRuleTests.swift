import XCTest

@testable import WallpaperMachine

/// Every place that lowers the app to `.accessory` asks the same rule, so the windows a
/// person can still reach are described here as plain values, without opening any.
final class ActivationPolicyRuleTests: XCTestCase {
    private typealias Window = ActivationPolicyRule.Window

    private func window(
        _ role: Window.Role?, visible: Bool = false, minimized: Bool = false
    ) -> Window {
        Window(role: role, isVisible: visible, isMiniaturized: minimized)
    }

    private func keepsRegular(_ windows: [Window], quitting: Bool = false) -> Bool {
        ActivationPolicyRule.keepsRegular(windows, quitting: quitting)
    }

    func testWithNoWindowTheAppLeavesTheDock() {
        XCTAssertFalse(keepsRegular([]))
    }

    func testEachOrdinaryWindowCountsOnScreenOrInTheDock() {
        let roles: [Window.Role] = [.controlPanel, .update, .preview, .signIn, .introduction]
        for role in roles {
            XCTAssertTrue(keepsRegular([window(role, visible: true)]), "\(role) on screen")
            XCTAssertTrue(keepsRegular([window(role, minimized: true)]), "\(role) minimized")
            XCTAssertFalse(keepsRegular([window(role)]), "\(role) ordered out")
        }
    }

    func testAMinimizedPanelKeepsTheDockIconWhenWhatsNewOrThePreviewCloses() {
        // The closed window is no longer one of the app's; the panel is in the Dock.
        let left = [window(.controlPanel, minimized: true), window(nil, visible: true)]
        XCTAssertTrue(keepsRegular(left))
    }

    func testASignInWindowKeepsTheDockIconAfterThePanelCloses() {
        XCTAssertTrue(keepsRegular([window(.signIn, visible: true)]))
        XCTAssertTrue(keepsRegular([window(nil, visible: true), window(.signIn, minimized: true)]))
    }

    func testAPanelAQuitPutAwayDoesNotCount() {
        XCTAssertFalse(keepsRegular([window(.controlPanel), window(.update)]))
        // Whatever AppKit still reports for a minimized one that was ordered out.
        let putAway = [window(.controlPanel, minimized: true), window(.update, visible: true)]
        XCTAssertFalse(keepsRegular(putAway, quitting: true))
        XCTAssertTrue(keepsRegular(putAway, quitting: false))
    }

    func testASignInWindowStillCountsDuringAQuit() {
        XCTAssertTrue(keepsRegular([window(.controlPanel), window(.signIn, visible: true)], quitting: true))
        XCTAssertTrue(keepsRegular([window(.preview, visible: true)], quitting: true))
    }

    func testAlertsPanelsAndWallpaperWindowsNeverCount() {
        // An alert or open panel is titled and visible; a wallpaper window is borderless and
        // on every Space. None of them is a window of the app's own.
        let others = [
            window(nil, visible: true), window(nil, minimized: true), window(nil, visible: true, minimized: true),
        ]
        XCTAssertFalse(keepsRegular(others))
        XCTAssertFalse(keepsRegular(others, quitting: true))
    }

    @MainActor
    func testGateRunsImmediatelyWhenAlreadySettledAsRegular() {
        var events: [String] = []
        var scheduledCount = 0
        final class Token {}

        let gate = RegularActivationGate(
            isRegular: { true },
            applyRegular: { events.append("regular") },
            applyAccessory: { events.append("accessory") },
            schedule: { _, _ in
                scheduledCount += 1
                return Token()
            })

        gate.presentWhenRegular { events.append("present") }
        XCTAssertEqual(events, ["present"])
        XCTAssertEqual(scheduledCount, 0)
        XCTAssertFalse(gate.hasPendingPresentations)
    }

    @MainActor
    func testGateCoalescesPendingPresentationsInFIFOOrderAcrossPromotion() {
        var policyIsRegular = false
        var events: [String] = []
        var flushWork: (@MainActor () -> Void)?
        var scheduledDelays: [Duration] = []
        final class Token {}

        let gate = RegularActivationGate(
            isRegular: { policyIsRegular },
            applyRegular: {
                policyIsRegular = true
                events.append("regular")
            },
            applyAccessory: {
                policyIsRegular = false
                events.append("accessory")
            },
            schedule: { delay, work in
                scheduledDelays.append(delay)
                flushWork = work
                return Token()
            })

        gate.presentWhenRegular { events.append("first") }
        // Even though `isRegular` now reads true, the promotion settle window is still open.
        gate.presentWhenRegular { events.append("second") }
        XCTAssertEqual(events, ["regular"])
        XCTAssertEqual(scheduledDelays, [RegularActivationGate.defaultSettleDelay])
        XCTAssertTrue(gate.hasPendingPresentations)

        flushWork?()
        XCTAssertEqual(events, ["regular", "first", "second"])
        XCTAssertFalse(gate.hasPendingPresentations)

        // Subsequent calls run synchronously once the promotion has settled.
        gate.presentWhenRegular { events.append("third") }
        XCTAssertEqual(events, ["regular", "first", "second", "third"])
    }

    @MainActor
    func testDropToAccessoryAndCancelPendingInvalidateStaleFlushes() {
        var policyIsRegular = false
        var events: [String] = []
        var flushWorks: [@MainActor () -> Void] = []
        final class Token {
            let onDeinit: () -> Void
            init(_ onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }
        var activeTokens = 0

        let gate = RegularActivationGate(
            isRegular: { policyIsRegular },
            applyRegular: {
                policyIsRegular = true
                events.append("regular")
            },
            applyAccessory: {
                policyIsRegular = false
                events.append("accessory")
            },
            schedule: { _, work in
                activeTokens += 1
                flushWorks.append(work)
                return Token { activeTokens -= 1 }
            })

        gate.presentWhenRegular { events.append("stale-1") }
        XCTAssertEqual(activeTokens, 1)
        gate.dropToAccessory()
        XCTAssertFalse(gate.hasPendingPresentations)
        XCTAssertEqual(activeTokens, 0)
        flushWorks[0]()
        XCTAssertEqual(events, ["regular", "accessory"])

        gate.presentWhenRegular { events.append("stale-2") }
        gate.cancelPending()
        XCTAssertFalse(gate.hasPendingPresentations)
        flushWorks[1]()
        XCTAssertEqual(events, ["regular", "accessory", "regular"])
    }
}
