import CoreGraphics
import Foundation
import XCTest

@testable import WallpaperMachine

final class LockScreenPointerTrackerTests: XCTestCase {
  func testNormalizationMapsPrimaryAndNegativeOriginDisplaysAndExcludesFarEdges() throws {
    let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let center = try XCTUnwrap(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 960, y: 270), in: primary))
    XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
    XCTAssertEqual(center.y, 0.25, accuracy: 1e-9)

    let origin = try XCTUnwrap(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 0, y: 0), in: primary))
    XCTAssertEqual(origin, LockScreenPointerPosition(x: 0, y: 0))

    // Far edges belong to the neighbouring display, never both displays at once.
    XCTAssertNil(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 1920, y: 540), in: primary))
    XCTAssertNil(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 960, y: 1080), in: primary))
    XCTAssertNil(LockScreenPointerPosition.normalized(cursor: CGPoint(x: -0.5, y: 540), in: primary))

    // Secondary display positioned above and to the left of primary (negative CG origin).
    let upperLeft = CGRect(x: -1440, y: -900, width: 1440, height: 900)
    let mapped = try XCTUnwrap(
      LockScreenPointerPosition.normalized(cursor: CGPoint(x: -1080, y: -225), in: upperLeft))
    XCTAssertEqual(mapped.x, 0.25, accuracy: 1e-9)
    XCTAssertEqual(mapped.y, 0.75, accuracy: 1e-9)

    // Adjacent right-hand display claims the shared border x == 1920.
    let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let border = try XCTUnwrap(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 1920, y: 720), in: right))
    XCTAssertEqual(border.x, 0, accuracy: 1e-9)
    XCTAssertEqual(border.y, 0.5, accuracy: 1e-9)

    // Invalid cursor or bounds never produce a position.
    XCTAssertNil(LockScreenPointerPosition.normalized(cursor: CGPoint(x: CGFloat.nan, y: 10), in: primary))
    XCTAssertNil(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 10, y: CGFloat.infinity), in: primary))
    XCTAssertNil(LockScreenPointerPosition.normalized(cursor: CGPoint(x: 10, y: 10), in: .zero))
    XCTAssertNil(
      LockScreenPointerPosition.normalized(
        cursor: CGPoint(x: 10, y: 10), in: CGRect(x: 0, y: 0, width: -100, height: 100)))
  }

  func testAppKitToCoreGraphicsConversionMatchesMultiMonitorGeometry() throws {
    let primaryHeight: CGFloat = 1329

    // Primary display: AppKit bottom-left (0, 0) -> CG bottom-left (0, 1329); top-left (0, 1329) -> (0, 0).
    let mid = try XCTUnwrap(
      LockScreenPointerProbe.appKitToCoreGraphics(NSPoint(x: 1129.25, y: 862.75), primaryHeight: primaryHeight))
    XCTAssertEqual(mid.x, 1129.25, accuracy: 1e-9)
    XCTAssertEqual(mid.y, 466.25, accuracy: 1e-9)

    // Secondary display directly above primary (height 1080): AppKit top-left y = 2409 -> CG y = -1080.
    let above = try XCTUnwrap(
      LockScreenPointerProbe.appKitToCoreGraphics(NSPoint(x: 200, y: 2409), primaryHeight: primaryHeight))
    XCTAssertEqual(above.x, 200, accuracy: 1e-9)
    XCTAssertEqual(above.y, -1080, accuracy: 1e-9)

    // Secondary display directly below primary: AppKit bottom-left y = -1080 -> CG y = 2409.
    let below = try XCTUnwrap(
      LockScreenPointerProbe.appKitToCoreGraphics(NSPoint(x: 200, y: -1080), primaryHeight: primaryHeight))
    XCTAssertEqual(below.x, 200, accuracy: 1e-9)
    XCTAssertEqual(below.y, 2409, accuracy: 1e-9)

    XCTAssertNil(LockScreenPointerProbe.appKitToCoreGraphics(NSPoint(x: CGFloat.nan, y: 10), primaryHeight: primaryHeight))
    XCTAssertNil(LockScreenPointerProbe.appKitToCoreGraphics(NSPoint(x: 10, y: 10), primaryHeight: 0))
    XCTAssertNil(LockScreenPointerProbe.appKitToCoreGraphics(NSPoint(x: 10, y: 10), primaryHeight: -10))
  }

  func testDeliveryDeduplicatesMotionAvoidsSpuriousSecondaryWakesAndReseedsAfterExit() {
    let primary = CGRect(x: 0, y: 0, width: 1000, height: 500)
    var delivery = LockScreenPointerDelivery()

    // Initial sample outside this display records `entered = false` without emitting an exit wake.
    let initialOutside = delivery.update(cursor: CGPoint(x: 1200, y: 250), in: primary)
    XCTAssertTrue(initialOutside.isEmpty)
    XCTAssertEqual(delivery.entered, false)

    // Entering emits both `entered = true` and the normalized position.
    let enter = delivery.update(cursor: CGPoint(x: 250, y: 125), in: primary)
    XCTAssertEqual(enter.entered, true)
    XCTAssertEqual(enter.position, LockScreenPointerPosition(x: 0.25, y: 0.25))

    // Stationary cursor emits nothing.
    XCTAssertTrue(delivery.update(cursor: CGPoint(x: 250, y: 125), in: primary).isEmpty)

    // Moving inside emits only the new position.
    let move = delivery.update(cursor: CGPoint(x: 750, y: 375), in: primary)
    XCTAssertNil(move.entered)
    XCTAssertEqual(move.position, LockScreenPointerPosition(x: 0.75, y: 0.75))

    // Leaving emits `entered = false` with no position snap.
    let leave = delivery.update(cursor: CGPoint(x: 1500, y: 250), in: primary)
    XCTAssertEqual(leave.entered, false)
    XCTAssertNil(leave.position)

    // Staying outside emits nothing.
    XCTAssertTrue(delivery.update(cursor: CGPoint(x: 1600, y: 250), in: primary).isEmpty)

    // Re-entering at the exact previous point delivers both enter and position again.
    let reenter = delivery.update(cursor: CGPoint(x: 750, y: 375), in: primary)
    XCTAssertEqual(reenter.entered, true)
    XCTAssertEqual(reenter.position, LockScreenPointerPosition(x: 0.75, y: 0.75))

    // Pausing/unlocking calls exit(): emits once, clears tracking so next lock re-seeds cleanly.
    XCTAssertTrue(delivery.exit())
    XCTAssertNil(delivery.entered)
    XCTAssertFalse(delivery.exit())

    let afterRelock = delivery.update(cursor: CGPoint(x: 750, y: 375), in: primary)
    XCTAssertEqual(afterRelock.entered, true)
    XCTAssertEqual(afterRelock.position, LockScreenPointerPosition(x: 0.75, y: 0.75))

    // Resetting for renderer replacement drops state without emitting exit.
    delivery.reset()
    XCTAssertNil(delivery.entered)
    XCTAssertNil(delivery.position)
  }

  func testEligibilityRestrictsCursorTrackingToActiveUnpausedLockScreenScenesAndWeb() {
    let scene = LockScreenPointerPolicy.SurfaceKind.scene(acceptsPointerInput: true)
    let web = LockScreenPointerPolicy.SurfaceKind.web(ready: true, hasError: false)

    XCTAssertTrue(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: scene))
    XCTAssertTrue(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: web))

    // Never track previews, desktop settle surfaces, screen savers, paused/loading/held/stopped surfaces.
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: true, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: scene))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .desktop, kind: scene))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .screenSaver, kind: scene))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: true, loading: false, held: false,
        content: .lockScreen, kind: scene))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: true, held: false,
        content: .lockScreen, kind: scene))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: true,
        content: .lockScreen, kind: scene))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: true, paused: false, loading: false, held: false,
        content: .lockScreen, kind: scene))

    // Refusing scenes, unready/errored/hoverless web pages, plain videos, and empty surfaces stay off.
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: .scene(acceptsPointerInput: false)))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: .web(ready: false, hasError: false)))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: .web(ready: true, hasError: true)))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: .video))
    XCTAssertFalse(
      LockScreenPointerPolicy.isEligible(
        preview: false, stopped: false, paused: false, loading: false, held: false,
        content: .lockScreen, kind: .none))
  }

  func testCadenceMatchesSurfaceFPSWhileMovingAndBacksOffWhenStationary() {
    XCTAssertEqual(LockScreenPointerCadence.activeInterval(forMaxFPS: 120), LockScreenPointerCadence.activeInterval(forMaxFPS: 60))
    XCTAssertEqual(LockScreenPointerCadence.activeInterval(forMaxFPS: 5), LockScreenPointerCadence.activeInterval(forMaxFPS: 15))
    XCTAssertLessThan(LockScreenPointerCadence.activeInterval(forMaxFPS: 60), LockScreenPointerCadence.activeInterval(forMaxFPS: 30))

    var cadence = LockScreenPointerCadence()
    let t0 = ContinuousClock.now
    XCTAssertTrue(cadence.recordSample(CGPoint(x: 100, y: 100), at: t0))
    XCTAssertEqual(cadence.nextInterval(maxFPS: 60, at: t0), LockScreenPointerCadence.activeInterval(forMaxFPS: 60))

    // Non-finite samples are ignored without overwriting the last valid location.
    XCTAssertFalse(cadence.recordSample(CGPoint(x: CGFloat.nan, y: 100), at: t0 + .milliseconds(100)))
    XCTAssertFalse(cadence.recordSample(CGPoint(x: 100, y: 100), at: t0 + .milliseconds(200)))
    XCTAssertEqual(
      cadence.nextInterval(maxFPS: 60, at: t0 + .milliseconds(200)),
      LockScreenPointerCadence.activeInterval(forMaxFPS: 60))

    // After 500 ms stationary, polling backs off to the relaxed stationary interval.
    let tIdle = t0 + LockScreenPointerCadence.stationaryDelay
    XCTAssertFalse(cadence.recordSample(CGPoint(x: 100, y: 100), at: tIdle))
    XCTAssertEqual(cadence.nextInterval(maxFPS: 60, at: tIdle), LockScreenPointerCadence.stationaryInterval)

    // The first motion immediately snaps back to the active surface FPS cadence.
    let tMove = tIdle + .milliseconds(80)
    XCTAssertTrue(cadence.recordSample(CGPoint(x: 104, y: 100), at: tMove))
    XCTAssertEqual(
      cadence.nextInterval(maxFPS: 60, at: tMove),
      LockScreenPointerCadence.activeInterval(forMaxFPS: 60))

    cadence.reset()
    XCTAssertTrue(cadence.recordSample(CGPoint(x: 104, y: 100), at: tMove + .seconds(1)))
  }
}
