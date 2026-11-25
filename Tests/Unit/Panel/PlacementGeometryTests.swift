import AppKit
import CoreGraphics
import XCTest

@testable import WallpaperMachine

/// The arithmetic of the Position on screen frame, ported from `placement.js`: the box the picture
/// fills for each fit, what a drag and a key press do to it, and the limits of its values.
final class PlacementGeometryTests: XCTestCase {
  private let stage = CGSize(width: 160, height: 100)

  private func box(
    fit: StillImageWallpaper.Fit?, aspect: Double? = 2, pixels: CGSize? = nil,
    viewport: CGSize? = nil, x: Double = 0.5, y: Double = 0.5, zoom: Double = 1
  ) -> PlacementGeometry.Box? {
    PlacementGeometry.box(
      stage: stage, imageAspect: aspect, fit: fit, imagePixelSize: pixels, viewportSize: viewport,
      x: x, y: y, zoom: zoom)
  }

  func testFillCoversTheFrameAndFitKeepsThePictureInsideIt() throws {
    // A 2:1 picture in a 1.6:1 frame: Fill grows to the frame's height, Fit shrinks to its width.
    let fill = try XCTUnwrap(box(fit: .fill))
    XCTAssertEqual(fill.size.width, 200, accuracy: 0.001)
    XCTAssertEqual(fill.size.height, 100, accuracy: 0.001)
    XCTAssertEqual(fill.overflow.width, 40, accuracy: 0.001)
    XCTAssertTrue(fill.isPannable)
    XCTAssertEqual(fill.origin.x, -20, accuracy: 0.001, "centred: half the overflow on each side")

    for fit in [StillImageWallpaper.Fit.fit, .blur] {
      let inside = try XCTUnwrap(box(fit: fit))
      XCTAssertEqual(inside.size.width, 160, accuracy: 0.001)
      XCTAssertEqual(inside.size.height, 80, accuracy: 0.001)
      XCTAssertFalse(inside.isPannable)
      XCTAssertEqual(inside.origin.y, 10, accuracy: 0.001)
    }
    XCTAssertEqual(try XCTUnwrap(box(fit: nil)).size.width, 200, "no fit reads as Fill")
    XCTAssertEqual(try XCTUnwrap(box(fit: .fillTop)).size.width, 200)
  }

  func testOriginalSizeDrawsThePictureAtItsPixelWidthAsAShareOfTheDisplay() throws {
    let original = try XCTUnwrap(
      box(
        fit: .center, aspect: 2, pixels: CGSize(width: 1_000, height: 500),
        viewport: CGSize(width: 2_000, height: 1_250)))
    XCTAssertEqual(original.size.width, 80, accuracy: 0.001, "1000 of 2000 points across a 160-point frame")
    // Without both sizes the frame shows the picture fitted, and says so.
    let fitted = try XCTUnwrap(box(fit: .center, aspect: 2))
    XCTAssertEqual(fitted.size.width, 160, accuracy: 0.001)
  }

  func testTheZoomScalesTheBoxAndThePositionAlignsItsOverflow() throws {
    let zoomed = try XCTUnwrap(box(fit: .fill, x: 0, y: 1, zoom: 2))
    XCTAssertEqual(zoomed.size.width, 400, accuracy: 0.001)
    XCTAssertEqual(zoomed.size.height, 200, accuracy: 0.001)
    XCTAssertEqual(zoomed.origin.x, 0, accuracy: 0.001, "0 keeps the leading edge in view")
    XCTAssertEqual(zoomed.origin.y, -100, accuracy: 0.001, "1 keeps the trailing edge in view")
    XCTAssertEqual(zoomed.overflow.width, 240, accuracy: 0.001)
  }

  func testThereIsNoBoxWithoutAFrameOrTheProportionsOfThePicture() {
    XCTAssertNil(box(fit: .fill, aspect: nil))
    XCTAssertNil(box(fit: .fill, aspect: 0))
    XCTAssertNil(box(fit: .fill, aspect: .infinity))
    XCTAssertNil(
      PlacementGeometry.box(
        stage: .zero, imageAspect: 2, fit: .fill, imagePixelSize: nil, viewportSize: nil, x: 0.5,
        y: 0.5, zoom: 1))
  }

  func testTheFrameTakesTheShapeOfTheDisplayElseItsViewportElseOneAndSixTenths() {
    XCTAssertEqual(PlacementGeometry.stageAspect(displayAspect: 1.78, viewport: nil), 1.78)
    XCTAssertEqual(
      PlacementGeometry.stageAspect(displayAspect: nil, viewport: CGSize(width: 2_000, height: 1_000)), 2)
    XCTAssertEqual(PlacementGeometry.stageAspect(displayAspect: 0, viewport: nil), 1.6)
    XCTAssertEqual(PlacementGeometry.stageAspect(displayAspect: -1, viewport: .zero), 1.6)
    XCTAssertEqual(PlacementGeometry.stageAspect(displayAspect: nil, viewport: nil), 1.6)
  }

  func testDraggingMovesThePictureTheOtherWayAndAnAxisItDoesNotOverflowStaysPut() {
    let overflow = CGSize(width: 40, height: 0)
    // Right by 10 points shows more of the left: x falls by 10/40.
    let moved = PlacementGeometry.dragged(
      from: (0.5, 0.5), overflow: overflow, translation: CGSize(width: 10, height: 30))
    XCTAssertEqual(moved.x, 0.25, accuracy: 1e-9)
    XCTAssertEqual(moved.y, 0.5, "no vertical overflow: it does not move")
    let clamped = PlacementGeometry.dragged(
      from: (0.9, 0.5), overflow: overflow, translation: CGSize(width: -100, height: 0))
    XCTAssertEqual(clamped.x, 1)
    let small = PlacementGeometry.dragged(
      from: (0.5, 0.5), overflow: CGSize(width: 0.4, height: -20), translation: CGSize(width: 50, height: 50))
    XCTAssertEqual(small.x, 0.5, "an overflow of half a point or less is none")
    XCTAssertEqual(small.y, 0.5)
  }

  func testAClickThatBarelyMovesIsNotADrag() {
    XCTAssertFalse(PlacementGeometry.isDrag(CGSize(width: 1, height: 1)))
    XCTAssertFalse(PlacementGeometry.isDrag(CGSize(width: 2, height: 0)))
    XCTAssertTrue(PlacementGeometry.isDrag(CGSize(width: 2, height: 1)))
    XCTAssertTrue(PlacementGeometry.isDrag(CGSize(width: -3, height: 0)))
  }

  func testAKeyMovesAHundredthAndShiftFiveHundredthsWithinTheRange() {
    var moved = PlacementGeometry.nudged(x: 0.5, y: 0.5, dx: 1, dy: 0, large: false)
    XCTAssertEqual(moved.x, 0.51, accuracy: 1e-9)
    moved = PlacementGeometry.nudged(x: 0.5, y: 0.5, dx: 0, dy: -1, large: true)
    XCTAssertEqual(moved.y, 0.45, accuracy: 1e-9)
    moved = PlacementGeometry.nudged(x: 0.995, y: 0.002, dx: 1, dy: -1, large: false)
    XCTAssertEqual(moved.x, 1)
    XCTAssertEqual(moved.y, 0)
  }

  func testValuesAreHeldToTheirRangesAndSentToThreeDecimals() {
    XCTAssertEqual(PlacementGeometry.fraction(1.4, fallback: 0.5), 1)
    XCTAssertEqual(PlacementGeometry.fraction(-0.2, fallback: 0.5), 0)
    XCTAssertEqual(PlacementGeometry.fraction(.nan, fallback: 0.25), 0.25)
    XCTAssertEqual(PlacementGeometry.fraction(nil, fallback: 0.75), 0.75)
    XCTAssertEqual(PlacementGeometry.zoom(0.2), 1)
    XCTAssertEqual(PlacementGeometry.zoom(5), 3)
    XCTAssertEqual(PlacementGeometry.zoom(.infinity), 1)
    XCTAssertEqual(PlacementGeometry.zoom(nil), 1)
    XCTAssertEqual(PlacementGeometry.rounded(0.123456), 0.123)
    XCTAssertEqual(PlacementGeometry.rounded(0.9996), 1)
    XCTAssertEqual(PlacementGeometry.keyDebounce, .milliseconds(400))
  }

  func testDraggingSnapsGentlyToCenterOnPannableAxesOnly() {
    // 200pt horizontal overflow -> threshold is 5 / 200 = 0.025 (5pt on screen).
    let overflow = CGSize(width: 200, height: 0)
    // Start at 0.45, drag left by 8pt -> raw x = 0.45 + 8/200 = 0.49 (within 0.025 of 0.5).
    let snapped = PlacementGeometry.draggedWithCenterSnap(
      from: (0.45, 0.5), overflow: overflow, translation: CGSize(width: -8, height: 20))
    XCTAssertEqual(snapped.x, 0.5)
    XCTAssertTrue(snapped.snappedX)
    XCTAssertEqual(snapped.y, 0.5)
    XCTAssertFalse(snapped.snappedY, "an axis with no overflow never snaps or shows a guide")

    // Drag further past the snap zone -> raw x = 0.45 + 30/200 = 0.60 (unsnapped).
    let unsnapped = PlacementGeometry.draggedWithCenterSnap(
      from: (0.45, 0.5), overflow: overflow, translation: CGSize(width: -30, height: 0))
    XCTAssertEqual(unsnapped.x, 0.60, accuracy: 1e-9)
    XCTAssertFalse(unsnapped.snappedX)

    // Both axes overflowing can snap together when dragged near (0.5, 0.5).
    let both = PlacementGeometry.draggedWithCenterSnap(
      from: (0.52, 0.48), overflow: CGSize(width: 200, height: 200),
      translation: CGSize(width: 2, height: -2))
    XCTAssertEqual(both.x, 0.5)
    XCTAssertEqual(both.y, 0.5)
    XCTAssertTrue(both.snappedX)
    XCTAssertTrue(both.snappedY)
  }

  func testPinchAndOptionScrollZoomClampWithinZoomRange() {
    XCTAssertEqual(PlacementGeometry.magnified(from: 1.5, scale: 1.2), 1.8, accuracy: 1e-9)
    XCTAssertEqual(PlacementGeometry.magnified(from: 2.0, scale: 2.5), 3.0)
    XCTAssertEqual(PlacementGeometry.magnified(from: 1.2, scale: 0.5), 1.0)
    XCTAssertEqual(PlacementGeometry.magnified(from: 1.5, scale: .nan), 1.5)
    XCTAssertEqual(PlacementGeometry.magnified(from: 1.5, scale: -1), 1.5)

    // Precise trackpad delta and discrete mouse wheel delta.
    XCTAssertEqual(
      PlacementGeometry.scrollZoomed(from: 1.5, deltaY: 50, hasPreciseDeltas: true),
      1.5 + 50 * PlacementGeometry.preciseScrollZoomStep, accuracy: 1e-9)
    XCTAssertEqual(
      PlacementGeometry.scrollZoomed(from: 1.5, deltaY: -2, hasPreciseDeltas: false),
      1.5 - 2 * PlacementGeometry.wheelScrollZoomStep, accuracy: 1e-9)
    XCTAssertEqual(PlacementGeometry.scrollZoomed(from: 2.9, deltaY: 10, hasPreciseDeltas: false), 3.0)
    XCTAssertEqual(PlacementGeometry.scrollZoomed(from: 1.05, deltaY: -10, hasPreciseDeltas: false), 1.0)
    XCTAssertEqual(PlacementGeometry.scrollZoomed(from: 1.5, deltaY: 0, hasPreciseDeltas: true), 1.5)
    XCTAssertEqual(PlacementGeometry.scrollZoomed(from: 1.5, deltaY: .nan, hasPreciseDeltas: true), 1.5)
  }

  func testOptionScrollMonitorNeverCapturesBareScrollWheel() {
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [], windowMatches: true, isHidden: false, pointInVisibleBounds: true, isEnabled: true),
      "bare scroll wheel must always scroll the outer inspector")
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.command], windowMatches: true, isHidden: false, pointInVisibleBounds: true, isEnabled: true))
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.option, .command], windowMatches: true, isHidden: false, pointInVisibleBounds: true, isEnabled: true))
    XCTAssertTrue(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.option], windowMatches: true, isHidden: false, pointInVisibleBounds: true, isEnabled: true))
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.option], windowMatches: true, isHidden: false, pointInVisibleBounds: false, isEnabled: true))
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.option], windowMatches: false, isHidden: false, pointInVisibleBounds: true, isEnabled: true))
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.option], windowMatches: true, isHidden: true, pointInVisibleBounds: true, isEnabled: true))
    XCTAssertFalse(
      OptionScrollZoomMonitor.shouldHandleScrollEvent(
        modifiers: [.option], windowMatches: true, isHidden: false, pointInVisibleBounds: true, isEnabled: false))
  }
}
