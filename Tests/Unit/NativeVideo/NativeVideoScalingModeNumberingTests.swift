import XCTest

@testable import WallpaperMachine

/// The numbers the renderer and the lock-screen configuration carry for a scaling mode become the
/// native player's layout mode; Fit with a blurred backdrop (4) must not fall back to Fill.
final class NativeVideoScalingModeNumberingTests: XCTestCase {
    func testEveryRendererNumberNamesItsLayoutMode() {
        let expected: [(Int32, NativeVideoScalingMode)] = [
            (0, .none), (1, .stretch), (2, .match), (3, .fill), (4, .matchBlurred),
            (5, .fillBlurred),
        ]
        for (number, mode) in expected {
            XCTAssertEqual(NativeVideoScalingMode(rendererValue: number), mode, "mode \(number)")
        }
        XCTAssertNil(NativeVideoScalingMode(rendererValue: 6))
        XCTAssertNil(NativeVideoScalingMode(rendererValue: -1))
    }

    func testTheBridgesModesKeepTheirRendererNumberThroughTheLayoutMode() {
        for bridge in [
            BridgeScalingMode.none, .stretch, .match, .fill, .matchBlurred, .fillBlurred,
        ] {
            XCTAssertEqual(NativeVideoScalingMode(rendererValue: bridge.rendererValue), bridge.layoutMode)
        }
        XCTAssertEqual(BridgeScalingMode.matchBlurred.layoutMode, .matchBlurred)
        XCTAssertEqual(BridgeScalingMode.fillBlurred.layoutMode, .fillBlurred)
    }
}
