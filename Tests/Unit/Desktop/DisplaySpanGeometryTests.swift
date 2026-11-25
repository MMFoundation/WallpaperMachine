import AVFoundation
import AppKit
import CoreGraphics
import XCTest
import os

@testable import WallpaperMachine

/// Fake still-image span surface for testing `DisplaySpanStillImageHost` without desktop windows.
@MainActor
private final class FakeStillSpanSurface: StillImageSpanSurface {
    let displayID: UInt32
    let windowNumber: Int
    var posterLayer: CALayer? = CALayer()
    private(set) var screenFrame: NSRect
    private(set) var appliedImage: CGImage?
    private(set) var appliedSlice: DisplaySpanGeometry.DisplaySlice?
    private(set) var presented = false
    private(set) var stopped = false

    init(frame: NSRect, displayID: UInt32, windowNumber: Int) {
        self.screenFrame = frame
        self.displayID = displayID
        self.windowNumber = windowNumber
    }

    var isReadyForDisplay: Bool { !stopped && appliedImage != nil && appliedSlice != nil }
    func setScreenFrame(_ frame: NSRect) { screenFrame = frame }
    func apply(image: CGImage, slice: DisplaySpanGeometry.DisplaySlice) {
        appliedImage = image
        appliedSlice = slice
    }
    func posterImage() -> CGImage? {
        guard let appliedImage, let appliedSlice else { return nil }
        return DisplaySpanGeometry.composePoster(from: appliedImage, slice: appliedSlice)
    }
    func present() { presented = true }
    func stop() { stopped = true }
}

/// Fake native video surface for testing `NativeVideoWallpaperHost` span coordination without desktop windows.
@MainActor
private final class FakeSpanVideoSurface: NativeVideoSurface {
    let displayID: UInt32
    let isFollower: Bool
    let leaderDisplayID: UInt32?
    let windowNumber: Int
    var posterLayer: CALayer? = CALayer()
    var isReadyForDisplay = true
    var onReadyForDisplay: (@MainActor () -> Void)? {
        didSet { if isReadyForDisplay { onReadyForDisplay?() } }
    }
    var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)?
    var onAudioDropped: (@MainActor (String) -> Void)?
    var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)?

    private(set) var frame: NSRect
    private(set) var spanDisplays: [DisplayConfiguration.Display]?
    private(set) var clearedSpanCount = 0
    private(set) var trimRange: VideoTrimRange?
    private(set) var userPaused = false
    private(set) var presentationSuspended = false
    private(set) var volume: Float = 1
    private(set) var muted = false
    private(set) var presented = false
    private(set) var stopped = false
    private var loopWatchHandler: (@MainActor () -> Void)?

    init(
        displayID: UInt32, frame: NSRect, windowNumber: Int,
        isFollower: Bool = false, leaderDisplayID: UInt32? = nil,
        initiallyReady: Bool = true
    ) {
        self.displayID = displayID
        self.frame = frame
        self.windowNumber = windowNumber
        self.isFollower = isFollower
        self.leaderDisplayID = leaderDisplayID
        self.isReadyForDisplay = initiallyReady
    }

    func markReady() {
        guard !stopped else { return }
        isReadyForDisplay = true
        onReadyForDisplay?()
    }

    func fireLoopEnd() {
        guard !stopped, let handler = loopWatchHandler else { return }
        loopWatchHandler = nil
        handler()
    }

    func setScreenFrame(_ frame: NSRect) { self.frame = frame }
    func setVolume(_ volume: Float, muted: Bool) { self.volume = volume; self.muted = muted }
    func setScaling(_ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {}
    func setEngineOptions(_ options: WallpaperEngineOptions, lut: VideoLut?, borderColor: CGColor?) {}
    func setTrimRange(_ range: VideoTrimRange?) { trimRange = range }
    func setSpanDisplays(_ displays: [DisplayConfiguration.Display], displayID: UInt32) {
        spanDisplays = displays
    }
    func clearSpanLayout() {
        spanDisplays = nil
        clearedSpanCount += 1
    }
    func setUserPaused(_ paused: Bool) { userPaused = paused }
    func setPresentationSuspended(_ suspended: Bool) { presentationSuspended = suspended }
    var isPlaying: Bool { !stopped && !userPaused && !presentationSuspended }
    func posterImage() async -> CGImage? { nil }
    var stateSummary: String { "fake" }
    func restartPlayback(reason: String) -> Bool { false }
    func verifyPlayback(reason: String) {}
    func watchNextLoop(_ handler: @escaping @MainActor () -> Void) -> Bool {
        guard !stopped else { return false }
        loopWatchHandler = handler
        return true
    }
    func cancelLoopWatch() { loopWatchHandler = nil }
    func present() { presented = true }
    func stop() { stopped = true; loopWatchHandler = nil }
}

@MainActor
final class DisplaySpanGeometryTests: XCTestCase {
    private func display(_ id: UInt32, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat = 1) -> DisplayConfiguration.Display {
        DisplayConfiguration.Display(id: id, frame: CGRect(x: x, y: y, width: w, height: h), scale: scale, refreshRate: 60)
    }

    /// Creates a 4-quadrant sRGB image (top-left Red, top-right Green, bottom-left Blue, bottom-right Yellow).
    private func makeQuadrantImage(width: Int = 200, height: Int = 100) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
        let halfW = CGFloat(width) / 2
        let halfH = CGFloat(height) / 2
        // CGContext uses y-up coordinates: y = 0 is bottom, y = halfH is top.
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1) // bottom-left Blue
        ctx.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1) // bottom-right Yellow
        ctx.fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1) // top-left Red
        ctx.fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1) // top-right Green
        ctx.fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func sampleRGB(of image: CGImage, x: Int, yFromTop: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
        // Draw shifted so (x, yFromTop) lands on the single output pixel (0, 0).
        let yFromBottom = image.height - 1 - yFromTop
        ctx.draw(image, in: CGRect(x: -x, y: -yFromBottom, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }

    // MARK: - Pure Coordinate Math

    func testSideBySideEqualDisplaysSliceExactHalvesWithSeamlessBezel() throws {
        let config = DisplayConfiguration(displays: [
            display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 1),
            display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1),
        ])
        let geom = try XCTUnwrap(DisplaySpanGeometry.compute(configuration: config, mediaSize: CGSize(width: 3840, height: 1080)))

        XCTAssertTrue(geom.isMultiDisplay)
        XCTAssertEqual(geom.unionBounds, CGRect(x: 0, y: 0, width: 3840, height: 1080))
        XCTAssertEqual(geom.mediaGlobalRect, CGRect(x: 0, y: 0, width: 3840, height: 1080))

        let left = try XCTUnwrap(geom.slice(for: 1))
        let right = try XCTUnwrap(geom.slice(for: 2))

        XCTAssertEqual(left.mediaFrameInDisplay, CGRect(x: 0, y: 0, width: 3840, height: 1080))
        XCTAssertEqual(right.mediaFrameInDisplay, CGRect(x: -1920, y: 0, width: 3840, height: 1080))
        XCTAssertEqual(left.contentsRect, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(right.contentsRect, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(left.contentsRect.maxX, right.contentsRect.minX, accuracy: 1e-9)
    }

    func testMixedDPIRetinaAndNonRetinaPreservePointContinuityAndPerDisplayPixels() throws {
        // 14" MacBook Pro (1512x982 @ 2x) beside external 1080p monitor (1920x1080 @ 1x).
        let config = DisplayConfiguration(displays: [
            display(1, x: 0, y: 0, w: 1512, h: 982, scale: 2),
            display(2, x: 1512, y: 0, w: 1920, h: 1080, scale: 1),
        ])
        let geom = try XCTUnwrap(DisplaySpanGeometry.compute(configuration: config, mediaSize: CGSize(width: 3840, height: 2160)))

        XCTAssertEqual(geom.unionBounds, CGRect(x: 0, y: 0, width: 3432, height: 1080))
        XCTAssertEqual(geom.maxBackingScale, 2)

        // 16:9 media filling 3432x1080 scales to width 3432, height 1930.5 centered vertically around y = 540.
        XCTAssertEqual(geom.mediaGlobalRect.width, 3432, accuracy: 0.01)
        XCTAssertEqual(geom.mediaGlobalRect.height, 1930.5, accuracy: 0.01)
        XCTAssertEqual(geom.mediaGlobalRect.midY, 540, accuracy: 0.01)

        let retina = try XCTUnwrap(geom.slice(for: 1))
        let external = try XCTUnwrap(geom.slice(for: 2))

        XCTAssertEqual(retina.pixelSize, CGSize(width: 3024, height: 1964))
        XCTAssertEqual(external.pixelSize, CGSize(width: 1920, height: 1080))
        // Bezel continuity at x = 1512 in normalized media space:
        XCTAssertEqual(retina.contentsRect.maxX, external.contentsRect.minX, accuracy: 1e-9)
        // Bottom edge aligned at y = 0:
        XCTAssertEqual(retina.contentsRect.minY, external.contentsRect.minY, accuracy: 1e-9)
        // Both slices stay strictly inside [0, 1] x [0, 1].
        for slice in [retina, external] {
            XCTAssertGreaterThanOrEqual(slice.contentsRect.minX, -1e-9)
            XCTAssertLessThanOrEqual(slice.contentsRect.maxX, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(slice.contentsRect.minY, -1e-9)
            XCTAssertLessThanOrEqual(slice.contentsRect.maxY, 1 + 1e-9)
        }
    }

    func testNegativeCoordinatesLeftAndBelowPrimary() throws {
        // Left monitor at x = -1920, primary at (0, 0), bottom monitor at y = -1080.
        let config = DisplayConfiguration(displays: [
            display(10, x: -1920, y: 0, w: 1920, h: 1080, scale: 1),
            display(20, x: 0, y: 0, w: 1920, h: 1080, scale: 2),
            display(30, x: 0, y: -1080, w: 1920, h: 1080, scale: 1),
        ])
        let geom = try XCTUnwrap(DisplaySpanGeometry.compute(configuration: config, mediaSize: CGSize(width: 3840, height: 2160)))

        XCTAssertEqual(geom.unionBounds, CGRect(x: -1920, y: -1080, width: 3840, height: 2160))
        XCTAssertEqual(geom.mediaGlobalRect, geom.unionBounds)

        let left = try XCTUnwrap(geom.slice(for: 10))
        let primary = try XCTUnwrap(geom.slice(for: 20))
        let bottom = try XCTUnwrap(geom.slice(for: 30))

        // Left is top-left quadrant in AppKit y-up coordinates: x in [0, 0.5], y in [0.5, 1.0].
        XCTAssertEqual(left.contentsRect, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(left.normalizedTopDownRect, CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(left.unionFrameInDisplay, CGRect(x: 0, y: -1080, width: 3840, height: 2160))

        // Primary is top-right quadrant: x in [0.5, 1.0], y in [0.5, 1.0].
        XCTAssertEqual(primary.contentsRect, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(primary.unionFrameInDisplay, CGRect(x: -1920, y: -1080, width: 3840, height: 2160))

        // Bottom is bottom-right quadrant: x in [0.5, 1.0], y in [0.0, 0.5].
        XCTAssertEqual(bottom.contentsRect, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(bottom.normalizedTopDownRect, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(bottom.unionFrameInDisplay, CGRect(x: -1920, y: 0, width: 3840, height: 2160))
    }

    func testVerticalStackedDisplaysAndLShapedArrangement() throws {
        // Vertically stacked displays: display 1 on bottom, display 2 on top.
        let stacked = try XCTUnwrap(DisplaySpanGeometry.compute(
            displays: [
                display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 1),
                display(2, x: 0, y: 1080, w: 1920, h: 1080, scale: 1),
            ],
            mediaSize: CGSize(width: 1920, height: 2160)))
        let bottomSlice = try XCTUnwrap(stacked.slice(for: 1))
        let topSlice = try XCTUnwrap(stacked.slice(for: 2))

        // macOS non-flipped CALayer.contentsRect is y-up: bottom display takes y = [0, 0.5], top takes [0.5, 1].
        XCTAssertEqual(bottomSlice.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(topSlice.contentsRect, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        // Top-down image cropping is inverted: top display takes y = [0, 0.5], bottom takes [0.5, 1].
        XCTAssertEqual(topSlice.normalizedTopDownRect, CGRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(bottomSlice.normalizedTopDownRect, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))

        // L-shaped 3 displays: bottom-left (1), bottom-right (2), top-right (3).
        let lShape = try XCTUnwrap(DisplaySpanGeometry.compute(
            displays: [
                display(1, x: 0, y: 0, w: 1000, h: 1000, scale: 1),
                display(2, x: 1000, y: 0, w: 1000, h: 1000, scale: 1),
                display(3, x: 1000, y: 1000, w: 1000, h: 1000, scale: 1),
            ],
            mediaSize: CGSize(width: 2000, height: 2000)))
        XCTAssertEqual(lShape.unionBounds, CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let s1 = try XCTUnwrap(lShape.slice(for: 1))
        let s2 = try XCTUnwrap(lShape.slice(for: 2))
        let s3 = try XCTUnwrap(lShape.slice(for: 3))
        XCTAssertEqual(s1.contentsRect.maxX, s2.contentsRect.minX, accuracy: 1e-9)
        XCTAssertEqual(s2.contentsRect.maxY, s3.contentsRect.minY, accuracy: 1e-9)
        XCTAssertEqual(s2.contentsRect.minX, s3.contentsRect.minX, accuracy: 1e-9)
    }

    func testDegenerateAndDuplicateDisplaysAreFilteredCleanly() throws {
        XCTAssertNil(DisplaySpanGeometry.compute(displays: []))
        XCTAssertNil(DisplaySpanGeometry.compute(displays: [display(1, x: 0, y: 0, w: 0, h: 1080)]))

        let dedup = try XCTUnwrap(DisplaySpanGeometry.compute(displays: [
            display(1, x: 0, y: 0, w: 1000, h: 1000),
            display(1, x: 1000, y: 0, w: 1000, h: 1000),
            display(2, x: 1000, y: 0, w: 1000, h: 1000),
        ]))
        XCTAssertEqual(dedup.slices.count, 2)
        XCTAssertEqual(dedup.slice(for: 1)?.displayFrame.origin.x, 0)
    }

    // MARK: - Poster Slicing Pixel Verification

    func testComposePosterSlicesExactQuadrantsIncludingHorizontalFlip() throws {
        let image = try makeQuadrantImage(width: 200, height: 200)
        // 4 quadrants across a 2x2 grid of 100x100 displays:
        // d1 bottom-left (Blue), d2 bottom-right (Yellow), d3 top-left (Red), d4 top-right (Green).
        let geom = try XCTUnwrap(DisplaySpanGeometry.compute(
            displays: [
                display(1, x: 0, y: 0, w: 100, h: 100, scale: 1),
                display(2, x: 100, y: 0, w: 100, h: 100, scale: 1),
                display(3, x: 0, y: 100, w: 100, h: 100, scale: 1),
                display(4, x: 100, y: 100, w: 100, h: 100, scale: 1),
            ],
            mediaSize: CGSize(width: 200, height: 200)))

        let pBottomLeft = try XCTUnwrap(DisplaySpanGeometry.composePoster(from: image, slice: try XCTUnwrap(geom.slice(for: 1))))
        let pBottomRight = try XCTUnwrap(DisplaySpanGeometry.composePoster(from: image, slice: try XCTUnwrap(geom.slice(for: 2))))
        let pTopLeft = try XCTUnwrap(DisplaySpanGeometry.composePoster(from: image, slice: try XCTUnwrap(geom.slice(for: 3))))
        let pTopRight = try XCTUnwrap(DisplaySpanGeometry.composePoster(from: image, slice: try XCTUnwrap(geom.slice(for: 4))))

        let cBL = try sampleRGB(of: pBottomLeft, x: 50, yFromTop: 50)
        let cBR = try sampleRGB(of: pBottomRight, x: 50, yFromTop: 50)
        let cTL = try sampleRGB(of: pTopLeft, x: 50, yFromTop: 50)
        let cTR = try sampleRGB(of: pTopRight, x: 50, yFromTop: 50)

        XCTAssertGreaterThan(cBL.b, 220); XCTAssertLessThan(cBL.r, 30)   // Blue
        XCTAssertGreaterThan(cBR.r, 220); XCTAssertGreaterThan(cBR.g, 220); XCTAssertLessThan(cBR.b, 30) // Yellow
        XCTAssertGreaterThan(cTL.r, 220); XCTAssertLessThan(cTL.g, 30)   // Red
        XCTAssertGreaterThan(cTR.g, 220); XCTAssertLessThan(cTR.r, 30)   // Green

        // With flipHorizontal = true, top-left receives Green (mirrored top-right).
        let pTopLeftFlipped = try XCTUnwrap(DisplaySpanGeometry.composePoster(
            from: image, slice: try XCTUnwrap(geom.slice(for: 3)), flipHorizontal: true))
        let cTLFlipped = try sampleRGB(of: pTopLeftFlipped, x: 50, yFromTop: 50)
        XCTAssertGreaterThan(cTLFlipped.g, 220)
        XCTAssertLessThan(cTLFlipped.r, 30)
    }

    // MARK: - Single-AVPlayer Multi-Layer Span Coordination

    func testSingleAVPlayerDrivesMultiplePerDisplayLayersWithExactSlicesAndHotplug() {
        let player = NativeVideoPlayer(
            surface: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 1, generation: 1),
            counters: RuntimeCounters(),
            paused: true)
        defer { player.stop() }

        let primaryView = NSView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        primaryView.wantsLayer = true
        let secondaryView = NSView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        secondaryView.wantsLayer = true

        player.attach(to: primaryView)
        let d1 = display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 2)
        let d2 = display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1)

        player.setSpanLayout(primaryDisplayID: 1, displays: [d1, d2])
        let secondaryLayer = player.attachSpanLayer(displayID: 2, to: secondaryView)

        // Single shared AVQueuePlayer across both per-display AVPlayerLayers (zero extra decoder).
        XCTAssertTrue(secondaryLayer.player === player.avPlayerForTest)
        XCTAssertEqual(primaryView.layer?.masksToBounds, true)
        XCTAssertEqual(secondaryView.layer?.masksToBounds, true)
        XCTAssertTrue(player.isSpanningForTest)
        XCTAssertEqual(player.spanLayerCountForTest, 1)

        // Primary layer spans [0, 3840] (midX = 1920), secondary layer spans [-1920, 1920] (midX = 0).
        XCTAssertEqual(player.layerBoundsForTest.size, CGSize(width: 3840, height: 1080))
        XCTAssertEqual(player.layerPositionForTest.x, 1920, accuracy: 0.5)
        XCTAssertEqual(secondaryLayer.bounds.size, CGSize(width: 3840, height: 1080))
        XCTAssertEqual(secondaryLayer.position.x, 0, accuracy: 0.5)

        // Hotplug: move display 2 to the left (negative origin x = -1920) and verify immediate relayout.
        let d2Left = display(2, x: -1920, y: 0, w: 1920, h: 1080, scale: 1)
        player.setSpanLayout(primaryDisplayID: 1, displays: [d2Left, d1])
        XCTAssertEqual(player.layerPositionForTest.x, 0, accuracy: 0.5)
        XCTAssertEqual(secondaryLayer.position.x, 1920, accuracy: 0.5)

        // Detaching secondary and clearing span restores clean single-display state.
        player.detachSpanLayer(displayID: 2)
        XCTAssertNil(secondaryLayer.player)
        XCTAssertNil(secondaryLayer.superlayer)
        XCTAssertEqual(player.spanLayerCountForTest, 0)
        player.clearSpanLayout()
        XCTAssertFalse(player.isSpanningForTest)
    }

    func testNativeVideoHostCoordinatesSharedLeaderFollowerSpanAndSuspension() async throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let spanStore = DisplaySpanStore(defaults: defaults)
        let trimStore = VideoTrimStore(defaults: defaults)
        spanStore.setEnabled(true)

        var connectedDisplays: [DisplayConfiguration.Display] = [
            display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 2),
            display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1),
        ]
        var createdPrimary: [FakeSpanVideoSurface] = []
        var createdFollowers: [FakeSpanVideoSurface] = []
        var nextWindowNumber = 100

        let host = NativeVideoWallpaperHost(
            fetch: { [] },
            screens: { connectedDisplays.map { ($0.id, $0.frame) } },
            refusal: { _ in nil },
            makeSurface: { _, frame, key, _ in
                nextWindowNumber += 1
                let surface = FakeSpanVideoSurface(displayID: key.displayID, frame: frame, windowNumber: nextWindowNumber)
                createdPrimary.append(surface)
                return surface
            },
            trimStore: trimStore,
            spanStore: spanStore,
            displayConfiguration: { DisplayConfiguration(displays: connectedDisplays) },
            makeSpanFollower: { displayID, frame, leader in
                nextWindowNumber += 1
                let leaderID = (leader as? FakeSpanVideoSurface)?.displayID
                let follower = FakeSpanVideoSurface(
                    displayID: displayID, frame: frame, windowNumber: nextWindowNumber,
                    isFollower: true, leaderDisplayID: leaderID)
                createdFollowers.append(follower)
                return follower
            })
        defer { host.shutdown() }
        host.start()

        func offer(_ displayID: UInt32, audioSource: UInt32 = 1) -> BridgeNativeVideoWallpaper {
            BridgeNativeVideoWallpaper(
                displayId: displayID, startupRevision: 1, audioSourceDisplayId: audioSource,
                wallpaperId: "clip-1", title: "Clip", mediaPath: "/tmp/clip.mp4", admissionKey: 42,
                framing: BridgeFraming(panX: 0.5, panY: 0.5), paused: false, volume: 0.8, muted: false,
                scalingMode: .fill, scalingFactor: 1.0,
                engineOptions: BridgeSnapshotFixtures.engineOptionValues(),
                lutPath: nil, borderColor: nil)
        }

        await host.apply([offer(1), offer(2)])

        // Only ONE primary decoder surface was created; display 2 is a follower bound to leader 1.
        XCTAssertEqual(createdPrimary.count, 1)
        XCTAssertEqual(createdPrimary[0].displayID, 1)
        XCTAssertEqual(createdFollowers.count, 1)
        XCTAssertEqual(createdFollowers[0].displayID, 2)
        XCTAssertEqual(host.spanFollowerLeadersForTest, [2: 1])
        XCTAssertEqual(createdPrimary[0].spanDisplays?.map(\.id), [1, 2])

        // Suspending only display 1 keeps shared leader playing because display 2 is still visible.
        host.setPresentationSuspended(true, forDisplay: 1)
        XCTAssertFalse(createdPrimary[0].presentationSuspended)
        // Suspending both displays suspends the shared leader.
        host.setPresentationSuspended(true, forDisplay: 2)
        XCTAssertTrue(createdPrimary[0].presentationSuspended)
        // Resuming display 2 resumes the shared leader.
        host.setPresentationSuspended(false, forDisplay: 2)
        XCTAssertFalse(createdPrimary[0].presentationSuspended)

        // Turning Span off closes the follower, clears span on leader, and opens a standalone surface on display 2.
        spanStore.setEnabled(false)
        await host.apply([offer(1), offer(2)])
        XCTAssertTrue(createdFollowers[0].stopped)
        XCTAssertTrue(host.spanFollowerLeadersForTest.isEmpty)
        XCTAssertNil(createdPrimary[0].spanDisplays)
        XCTAssertEqual(createdPrimary.count, 2)
        XCTAssertEqual(createdPrimary[1].displayID, 2)

        // Turning Span back on re-groups cleanly and stops the redundant standalone surface on display 2.
        spanStore.setEnabled(true)
        await host.apply([offer(1), offer(2)])
        XCTAssertTrue(createdPrimary[1].stopped)
        XCTAssertEqual(host.spanFollowerLeadersForTest, [2: 1])

        // Display hotplug disconnect leaving 1 screen clears span cleanly.
        connectedDisplays = [connectedDisplays[0]]
        await host.apply([offer(1)])
        XCTAssertTrue(host.spanFollowerLeadersForTest.isEmpty)
        XCTAssertNil(createdPrimary[0].spanDisplays)
    }

    // MARK: - DisplaySpanStore & Still Image Span Host

    func testDisplaySpanStorePersistsNotifiesAndResets() throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let store = DisplaySpanStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled)

        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: DisplaySpanStore.didChangeNotification, object: store, queue: .main
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(notifications, 1)

        let reloaded = DisplaySpanStore(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)

        store.resetToDefaults()
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(notifications, 2)
    }

    func testStillImageSpanHostDecodesOnceSharesCGImageAndSkipsInteractiveWebWallpapers() async throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let spanStore = DisplaySpanStore(defaults: defaults)
        spanStore.setEnabled(true)

        let sharedCGImage = try makeQuadrantImage(width: 400, height: 200)
        var decodeCalls = 0
        var surfacesByDisplay: [UInt32: FakeStillSpanSurface] = [:]
        var nextWindow = 500

        let displays = [
            display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 2),
            display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1),
        ]

        let host = DisplaySpanStillImageHost(
            fetch: { [] },
            screens: { displays.map { ($0.id, $0.frame) } },
            displayConfiguration: { DisplayConfiguration(displays: displays) },
            spanStore: spanStore,
            resolveImageURL: { wallpaper in
                wallpaper.wallpaperId.hasPrefix("image-") ? URL(fileURLWithPath: "/tmp/\(wallpaper.wallpaperId).jpg") : nil
            },
            decodeImage: { _ in
                decodeCalls += 1
                return sharedCGImage
            },
            makeSurface: { frame, displayID in
                nextWindow += 1
                let surface = FakeStillSpanSurface(frame: frame, displayID: displayID, windowNumber: nextWindow)
                surfacesByDisplay[displayID] = surface
                return surface
            })
        defer { host.shutdown() }
        host.start()

        func webWallpaper(displayID: UInt32, id: String) -> BridgeWebWallpaper {
            BridgeWebWallpaper(
                displayId: displayID, startupRevision: 1, displayKey: "display-\(displayID)",
                audioSourceDisplayId: 1, wallpaperId: id, title: id,
                projectPath: "/tmp/\(id)", entryFile: "index.html", fps: 60, renderScale: 1,
                paused: false, volume: 0, muted: true, audioResponseEnabled: false,
                mediaIntegrationEnabled: false, propertiesJson: "{}")
        }

        // Interactive Web wallpaper is NEVER claimed by Still Image Span (Phase 1 graceful fallback).
        let interactiveWeb = [webWallpaper(displayID: 1, id: "123456"), webWallpaper(displayID: 2, id: "123456")]
        XCTAssertEqual(host.filterForWebHost(interactiveWeb).count, 2)
        await host.apply(interactiveWeb)
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(decodeCalls, 0)

        // Packaged still image assigned to 2 displays is claimed, decoded ONCE, and shared across both surfaces.
        let stillSpan = [webWallpaper(displayID: 1, id: "image-panorama"), webWallpaper(displayID: 2, id: "image-panorama")]
        XCTAssertTrue(host.filterForWebHost(stillSpan).isEmpty)
        await host.apply(stillSpan)

        XCTAssertEqual(decodeCalls, 1, "still image must be decoded once and shared across displays")
        XCTAssertEqual(host.activeDisplayIDs, [1, 2])
        let s1 = try XCTUnwrap(surfacesByDisplay[1])
        let s2 = try XCTUnwrap(surfacesByDisplay[2])
        XCTAssertTrue(s1.presented && s2.presented)
        XCTAssertTrue(s1.appliedImage === sharedCGImage)
        XCTAssertTrue(s2.appliedImage === sharedCGImage)
        XCTAssertEqual(s1.appliedSlice?.contentsRect.maxX ?? -1, s2.appliedSlice?.contentsRect.minX ?? -2, accuracy: 1e-9)

        // Turning Span off closes both still-image span windows and restores them to WebWallpaperHost.
        spanStore.setEnabled(false)
        XCTAssertEqual(host.filterForWebHost(stillSpan).count, 2)
        await host.apply(stillSpan)
        XCTAssertTrue(host.isEmpty)
        XCTAssertTrue(s1.stopped && s2.stopped)
    }

    func testStillImageSpanDecodeFailureFallsBackToWebHostAndSequencesReconcile() async throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let spanStore = DisplaySpanStore(defaults: defaults)
        spanStore.setEnabled(true)

        let sharedCGImage = try makeQuadrantImage(width: 400, height: 200)
        let shouldFailDecode = OSAllocatedUnfairLock(initialState: false)
        let displays = [
            display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 2),
            display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1),
        ]
        var nextWindow = 700

        func webWallpaper(displayID: UInt32, id: String) -> BridgeWebWallpaper {
            BridgeWebWallpaper(
                displayId: displayID, startupRevision: 1, displayKey: "display-\(displayID)",
                audioSourceDisplayId: 1, wallpaperId: id, title: id,
                projectPath: "/tmp/\(id)", entryFile: "index.html", fps: 60, renderScale: 1,
                paused: false, volume: 0, muted: true, audioResponseEnabled: false,
                mediaIntegrationEnabled: false, propertiesJson: "{}")
        }

        // 1. Standalone decode failure records localized `.failed` and stops excluding displays from WebWallpaperHost.
        var standaloneStates: [HostWallpaperState] = []
        let standaloneHost = DisplaySpanStillImageHost(
            fetch: { [] },
            screens: { displays.map { ($0.id, $0.frame) } },
            displayConfiguration: { DisplayConfiguration(displays: displays) },
            spanStore: spanStore,
            resolveImageURL: { URL(fileURLWithPath: "/tmp/\($0.wallpaperId).jpg") },
            decodeImage: { _ in nil },
            makeSurface: { frame, displayID in
                nextWindow += 1
                return FakeStillSpanSurface(frame: frame, displayID: displayID, windowNumber: nextWindow)
            })
        defer { standaloneHost.shutdown() }
        standaloneHost.onStateChanged = { standaloneStates.append($0) }

        let brokenSpan = [webWallpaper(displayID: 1, id: "image-broken"), webWallpaper(displayID: 2, id: "image-broken")]
        XCTAssertTrue(standaloneHost.filterForWebHost(brokenSpan).isEmpty)
        await standaloneHost.apply(brokenSpan)
        XCTAssertTrue(standaloneHost.isEmpty)
        XCTAssertEqual(standaloneHost.decodeFailedCountForTest, 1)
        XCTAssertEqual(
            standaloneHost.filterForWebHost(brokenSpan).count, 2,
            "decode-failed still image must not be excluded from WebWallpaperHost")
        let failedStates = standaloneStates.filter { $0.phase == .failed }
        XCTAssertEqual(failedStates.count, 2)
        XCTAssertEqual(
            failedStates.first?.message,
            String(localized: "The still image could not be decoded for multi-display span."))

        // 2. Coordinated sequential handoff with `applyWebHost`: outgoing host always closes before
        //    incoming host opens, and decode failure falls straight back to WebWallpaperHost.
        var currentOffer = [webWallpaper(displayID: 1, id: "image-good"), webWallpaper(displayID: 2, id: "image-good")]
        var events: [String] = []
        var webHostOwned: [UInt32] = []
        shouldFailDecode.withLock { $0 = false }

        let coordinatedHost = DisplaySpanStillImageHost(
            fetch: { currentOffer },
            screens: { displays.map { ($0.id, $0.frame) } },
            displayConfiguration: { DisplayConfiguration(displays: displays) },
            spanStore: spanStore,
            resolveImageURL: { URL(fileURLWithPath: "/tmp/\($0.wallpaperId).jpg") },
            decodeImage: { _ in shouldFailDecode.withLock { $0 } ? nil : sharedCGImage },
            makeSurface: { frame, displayID in
                nextWindow += 1
                return FakeStillSpanSurface(frame: frame, displayID: displayID, windowNumber: nextWindow)
            })
        defer { coordinatedHost.shutdown() }
        coordinatedHost.onStateChanged = { state in
            events.append("still:\(state.displayID):\(state.phase)")
        }
        coordinatedHost.applyWebHost = { filtered in
            webHostOwned = filtered.map(\.displayId).sorted()
            events.append("web:\(webHostOwned)")
        }
        coordinatedHost.start()

        // Span ON: WebWallpaperHost receives `[]` BEFORE still-span opens `.ready`.
        coordinatedHost.reconcile()
        let onDeadline = ContinuousClock.now + .seconds(2)
        while coordinatedHost.activeDisplayIDs != [1, 2] && ContinuousClock.now < onDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinatedHost.activeDisplayIDs, [1, 2])
        XCTAssertTrue(webHostOwned.isEmpty)
        let firstWebIndex = try XCTUnwrap(events.firstIndex(of: "web:[]"))
        let firstReadyIndex = try XCTUnwrap(events.firstIndex(where: { $0.hasSuffix(":ready") }))
        XCTAssertLessThan(firstWebIndex, firstReadyIndex, "Web host must release displays before still-span opens")

        // Span OFF: still-span closes displays (`.closed`) BEFORE WebWallpaperHost opens `[1, 2]`.
        events.removeAll()
        spanStore.setEnabled(false)
        let offDeadline = ContinuousClock.now + .seconds(2)
        while webHostOwned != [1, 2] && ContinuousClock.now < offDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinatedHost.isEmpty)
        let closedIndex = try XCTUnwrap(events.firstIndex(where: { $0.hasSuffix(":closed") }))
        let webTakeoverIndex = try XCTUnwrap(events.firstIndex(of: "web:[1, 2]"))
        XCTAssertLessThan(closedIndex, webTakeoverIndex, "Still-span must emit .closed before Web host opens")

        // Span ON with decode failure: still-span fails decode, closes claim, and immediately hands
        // `[1, 2]` back to WebWallpaperHost (no black screen).
        events.removeAll()
        webHostOwned = []
        shouldFailDecode.withLock { $0 = true }
        currentOffer = brokenSpan
        spanStore.setEnabled(true)
        let fallbackDeadline = ContinuousClock.now + .seconds(2)
        while webHostOwned != [1, 2] && ContinuousClock.now < fallbackDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinatedHost.isEmpty)
        XCTAssertEqual(webHostOwned, [1, 2])
        XCTAssertFalse(events.contains(where: { $0.hasSuffix(":failed") }))
    }

    func testStillImageSpanInspectionCacheIsBounded() throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let spanStore = DisplaySpanStore(defaults: defaults)
        spanStore.setEnabled(true)

        let tempLibrary = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-span-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempLibrary) }

        let displays = [
            display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 1),
            display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1),
        ]
        let host = DisplaySpanStillImageHost(
            fetch: { [] },
            screens: { displays.map { ($0.id, $0.frame) } },
            displayConfiguration: { DisplayConfiguration(displays: displays) },
            spanStore: spanStore,
            libraryURL: tempLibrary)
        defer { host.shutdown() }

        let total = DisplaySpanStillImageHost.inspectionCacheLimit + 20
        for index in 0..<total {
            let id = "image-\(index)"
            let path = tempLibrary.appendingPathComponent(id).path
            let pair = [1, 2].map { d in
                BridgeWebWallpaper(
                    displayId: UInt32(d), startupRevision: 1, displayKey: "display-\(d)",
                    audioSourceDisplayId: 1, wallpaperId: id, title: id,
                    projectPath: path, entryFile: "index.html", fps: 60, renderScale: 1,
                    paused: false, volume: 0, muted: true, audioResponseEnabled: false,
                    mediaIntegrationEnabled: false, propertiesJson: "{}")
            }
            _ = host.filterForWebHost(pair)
        }
        XCTAssertLessThanOrEqual(
            host.inspectionCacheCountForTest, DisplaySpanStillImageHost.inspectionCacheLimit)
    }

    func testNativeVideoSpanFollowerLayoutBeforeCreationPausedOccludedStateAndLoopWatch() async throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let spanStore = DisplaySpanStore(defaults: defaults)
        let trimStore = VideoTrimStore(defaults: defaults)
        spanStore.setEnabled(true)

        let displays = [
            display(1, x: 0, y: 0, w: 1920, h: 1080, scale: 2),
            display(2, x: 1920, y: 0, w: 1920, h: 1080, scale: 1),
        ]
        var leaderSpanAtFollowerCreation: [DisplayConfiguration.Display]?
        var leaderInitialReady = true
        var followerInitialReady = false
        var leaders: [FakeSpanVideoSurface] = []
        var followers: [FakeSpanVideoSurface] = []
        var nextWindow = 800
        var currentOffers: [BridgeNativeVideoWallpaper] = []

        let host = NativeVideoWallpaperHost(
            fetch: { currentOffers },
            screens: { displays.map { ($0.id, $0.frame) } },
            refusal: { _ in nil },
            makeSurface: { _, frame, key, _ in
                nextWindow += 1
                let surface = FakeSpanVideoSurface(
                    displayID: key.displayID, frame: frame, windowNumber: nextWindow,
                    initiallyReady: leaderInitialReady)
                leaders.append(surface)
                return surface
            },
            trimStore: trimStore,
            spanStore: spanStore,
            displayConfiguration: { DisplayConfiguration(displays: displays) },
            makeSpanFollower: { displayID, frame, leader in
                let leaderFake = leader as? FakeSpanVideoSurface
                leaderSpanAtFollowerCreation = leaderFake?.spanDisplays
                nextWindow += 1
                let follower = FakeSpanVideoSurface(
                    displayID: displayID, frame: frame, windowNumber: nextWindow,
                    isFollower: true, leaderDisplayID: leaderFake?.displayID,
                    initiallyReady: followerInitialReady)
                followers.append(follower)
                return follower
            })
        defer { host.shutdown() }
        host.start()

        func offer(_ displayID: UInt32, paused: Bool = false, rev: UInt64 = 1) -> BridgeNativeVideoWallpaper {
            BridgeNativeVideoWallpaper(
                displayId: displayID, startupRevision: rev, audioSourceDisplayId: 1,
                wallpaperId: "clip-span", title: "Clip", mediaPath: "/tmp/clip.mp4", admissionKey: 99,
                framing: BridgeFraming(panX: 0.5, panY: 0.5), paused: paused, volume: 0.8, muted: false,
                scalingMode: .fill, scalingFactor: 1.0,
                engineOptions: BridgeSnapshotFixtures.engineOptionValues(),
                lutPath: nil, borderColor: nil)
        }

        // 1. Visible, playing, unready follower: leader's span layout is populated BEFORE follower
        //    creation (never 0x0), follower starts in `.loading` with armed first-frame watch, and
        //    transitions cleanly to `.ready` when its frame arrives.
        currentOffers = [offer(1), offer(2)]
        await host.apply(currentOffers)
        XCTAssertEqual(
            leaderSpanAtFollowerCreation?.map(\.id), [1, 2],
            "leader span layout must be set before attaching/presenting follower")
        XCTAssertEqual(host.hostStatesForTest[2]?.phase, .loading)
        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 1)

        followers[0].markReady()
        XCTAssertEqual(host.hostStatesForTest[2]?.phase, .ready)
        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 0)

        // Playlist `watchClipEnd` on follower fires cleanly when loop wraps.
        var followerLoopEnded = false
        let cancelWatch = host.watchClipEnd(displayID: 2, wallpaperID: "clip-span") {
            followerLoopEnded = true
        }
        XCTAssertNotNil(cancelWatch)
        followers[0].fireLoopEnd()
        XCTAssertTrue(followerLoopEnded)

        // 2. Toggle Span OFF then back ON while playback is PAUSED and follower reports not-yet-ready:
        //    leader is already ready, so follower settles cleanly to `.ready` instead of `nil`.
        currentOffers = [offer(1, paused: true, rev: 2), offer(2, paused: true, rev: 2)]
        spanStore.setEnabled(false)
        await host.apply(currentOffers)
        currentOffers = [offer(1, paused: true, rev: 3), offer(2, paused: true, rev: 3)]
        spanStore.setEnabled(true)
        await host.apply(currentOffers)
        XCTAssertEqual(
            host.hostStatesForTest[2]?.phase, .ready,
            "paused follower with ready leader must never drop host startup state")

        // 3. Leader not ready yet + display 2 occluded: follower records `.loading`, and settles to
        //    `.ready` as soon as the leader reports its first frame.
        currentOffers = []
        spanStore.setEnabled(false)
        await host.apply(currentOffers)
        leaderInitialReady = false
        followerInitialReady = false
        host.setPresentationSuspended(true, forDisplay: 2)
        currentOffers = [offer(1, paused: false, rev: 4), offer(2, paused: false, rev: 4)]
        spanStore.setEnabled(true)
        await host.apply(currentOffers)
        XCTAssertEqual(host.hostStatesForTest[1]?.phase, .loading)
        XCTAssertEqual(host.hostStatesForTest[2]?.phase, .loading)

        leaders.last?.markReady()
        XCTAssertEqual(host.hostStatesForTest[1]?.phase, .ready)
        XCTAssertEqual(
            host.hostStatesForTest[2]?.phase, .ready,
            "occluded follower must settle cleanly to .ready once its leader becomes ready")
    }

    func testNativeVideoPlayerFollowerLoopWatchIsIndependentOfLeader() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("span-loop-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = SyntheticVideoFixture.Request.constantRate(
            name: "span-watch", numerator: 30, denominator: 1, frames: 12) // 0.4s clip
        let url = try await SyntheticVideoFixture.write(request, into: directory)

        let player = NativeVideoPlayer(
            surface: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 1, generation: 1),
            counters: RuntimeCounters(),
            paused: false)
        defer { player.stop() }
        player.load(url: url)

        // Register both primary and follower watches; cancelling follower leaves primary intact.
        var primaryFired = 0
        var followerFired = 0
        XCTAssertTrue(player.watchNextLoop { primaryFired += 1 })
        XCTAssertTrue(player.watchNextLoop(forFollower: 2) { followerFired += 1 })
        player.cancelLoopWatch(forFollower: 2)
        XCTAssertTrue(player.watchNextLoop(forFollower: 2) { followerFired += 1 })

        let deadline = ContinuousClock.now + .seconds(4)
        while (primaryFired == 0 || followerFired == 0) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(primaryFired, 1, "leader watch must fire independently on loop wrap")
        XCTAssertEqual(followerFired, 1, "follower watch must fire independently on loop wrap")
    }

    func testDesktopPosterSpanLookAndTopologySignaturesTrackSpanToggleMembershipAndOrigin() {
        let d1Row = BridgeDisplaySettingsRow(
            displayId: "d1", title: "Built-in (1 - Primary)", enabled: true, mode: .standalone,
            mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
            targetFps: 60, maxFps: 120, muted: false, volume: 1)
        let d2Row = BridgeDisplaySettingsRow(
            displayId: "d2", title: "External (2)", enabled: true, mode: .standalone,
            mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
            targetFps: 60, maxFps: 120, muted: false, volume: 1)
        let settings = BridgeSnapshotFixtures.settings(displays: [d1Row, d2Row])
        let monitorsSame = [
            BridgeMonitorInfoRow(
                displayId: "d1", title: d1Row.title, wallpaperId: "video-1", wallpaperTitle: "Video",
                mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
                targetFps: "60", audioResponse: false),
            BridgeMonitorInfoRow(
                displayId: "d2", title: d2Row.title, wallpaperId: "video-1", wallpaperTitle: "Video",
                mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
                targetFps: "60", audioResponse: false),
        ]
        let monitorsDifferent = [
            monitorsSame[0],
            BridgeMonitorInfoRow(
                displayId: "d2", title: d2Row.title, wallpaperId: "video-2", wallpaperTitle: "Other",
                mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
                targetFps: "60", audioResponse: false),
        ]
        let rightScreens: [(id: String, frame: CGRect, scale: CGFloat)] = [
            (id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
            (id: "2", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1),
        ]
        let leftScreens: [(id: String, frame: CGRect, scale: CGFloat)] = [
            (id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
            (id: "2", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1),
        ]
        let physicalID: (BridgeDisplaySettingsRow) -> String? = { row in
            row.displayId == "d1" ? "1" : row.displayId == "d2" ? "2" : nil
        }

        let offSig = AppDelegate.desktopPosterSpanLookSignature(
            display: "1", wallpaperID: "video-1", kind: .video, spanEnabled: false,
            stillImageSpanActive: false, settings: settings, monitors: monitorsSame,
            screens: rightScreens, physicalDisplay: physicalID)
        let onRightSig = AppDelegate.desktopPosterSpanLookSignature(
            display: "1", wallpaperID: "video-1", kind: .video, spanEnabled: true,
            stillImageSpanActive: false, settings: settings, monitors: monitorsSame,
            screens: rightScreens, physicalDisplay: physicalID)
        let onLeftSig = AppDelegate.desktopPosterSpanLookSignature(
            display: "1", wallpaperID: "video-1", kind: .video, spanEnabled: true,
            stillImageSpanActive: false, settings: settings, monitors: monitorsSame,
            screens: leftScreens, physicalDisplay: physicalID)
        let singleSig = AppDelegate.desktopPosterSpanLookSignature(
            display: "1", wallpaperID: "video-1", kind: .video, spanEnabled: true,
            stillImageSpanActive: false, settings: settings, monitors: monitorsDifferent,
            screens: rightScreens, physicalDisplay: physicalID)
        let interactiveWebSig = AppDelegate.desktopPosterSpanLookSignature(
            display: "1", wallpaperID: "video-1", kind: .webpage, spanEnabled: true,
            stillImageSpanActive: false, settings: settings, monitors: monitorsSame,
            screens: rightScreens, physicalDisplay: physicalID)
        let stillSpanSig = AppDelegate.desktopPosterSpanLookSignature(
            display: "1", wallpaperID: "video-1", kind: .webpage, spanEnabled: true,
            stillImageSpanActive: true, settings: settings, monitors: monitorsSame,
            screens: rightScreens, physicalDisplay: physicalID)

        XCTAssertNotEqual(offSig, onRightSig, "Span toggle must invalidate settled poster look")
        XCTAssertNotEqual(
            onRightSig, onLeftSig,
            "Moving display 2 must invalidate display 1's settled poster look even when display 1 stays at (0,0)")
        XCTAssertNotEqual(onRightSig, singleSig, "Span group membership change must invalidate look")
        XCTAssertEqual(interactiveWebSig, "off", "Interactive web wallpapers are not spanned")
        XCTAssertEqual(stillSpanSig, onRightSig)

        let topoOff = AppDelegate.desktopPosterSpanTopologySignature(
            spanEnabled: false, monitors: monitorsSame, screens: rightScreens)
        let topoOnRight = AppDelegate.desktopPosterSpanTopologySignature(
            spanEnabled: true, monitors: monitorsSame, screens: rightScreens)
        let topoOnLeft = AppDelegate.desktopPosterSpanTopologySignature(
            spanEnabled: true, monitors: monitorsSame, screens: leftScreens)
        XCTAssertNotEqual(topoOff, topoOnRight)
        XCTAssertNotEqual(topoOnRight, topoOnLeft)
    }
}
