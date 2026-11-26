import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

@MainActor
final class ControlPanelWindowSizingTests: XCTestCase {
  func testHostedPanelWindowKeepsItsSizeFloor() async throws {
    let bridge = SizingBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    let session = FileManager.default.temporaryDirectory.appendingPathComponent(
      "window-sizing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: session) }
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: session),
      supportDirectory: session, defaults: defaults)
    let updater = SoftwareUpdateStatus()
    let controller = NSHostingController(
      rootView: AnyView(
        ControlPanelView(
          store: store, navigation: ControlPanelNavigation(), workshop: workshop,
          pixiv: PixivStore(), updater: updater, imports: LibraryImportStore(),
          defaults: defaults)))
    controller.sizingOptions = []
    let delegate = SizingDelegate()
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: delegate)
    defer { window.close() }
    XCTAssertFalse(window.isVisible, "The window must stay offscreen")

    let minimum = ControlPanelWindow.minimumFrameSize(for: window)
    XCTAssertGreaterThanOrEqual(minimum.width, 760)
    XCTAssertGreaterThanOrEqual(minimum.height, 560)

    // Let SwiftUI attach to the window and apply whatever sizing it wants; the hosting
    // controller is known to zero `contentMinSize`, so the floor must not depend on it.
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))

    let clamped = ControlPanelWindow.clampedFrameSize(NSSize(width: 100, height: 80), for: window)
    XCTAssertEqual(clamped, minimum, "A tiny live-resize proposal must snap to the floor")
    let larger = NSSize(width: minimum.width + 200, height: minimum.height + 100)
    XCTAssertEqual(ControlPanelWindow.clampedFrameSize(larger, for: window), larger)

    window.setFrame(NSRect(x: 0, y: 0, width: 100, height: 80), display: false)
    ControlPanelWindow.constrainToScreen(window)
    XCTAssertGreaterThanOrEqual(window.frame.width, minimum.width, "Reopening must grow a shrunken frame")
    XCTAssertGreaterThanOrEqual(window.frame.height, minimum.height)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 760)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 560)
    XCTAssertFalse(window.isVisible, "The window must stay offscreen")
    await workshop.steamCMDSetup.shutdown()
  }

  func testHostedKeyViewLoopMovesForwardBackwardAndWrapsWithoutShowingWindow() async throws {
    let first = NSTextField(string: "First")
    let second = NSTextField(string: "Second")
    let controller = NSHostingController(rootView: KeyLoopHost(fields: [first, second]))
    controller.sizingOptions = []
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: nil)
    defer { window.close() }
    window.layoutIfNeeded()
    let deadline = Date().addingTimeInterval(5)
    while (first.window !== window || second.window !== window) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard first.window === window, second.window === window else {
      XCTFail("Hosted fields did not attach to the test window before the deadline")
      return
    }
    controller.view.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()
    XCTAssertTrue(window.makeFirstResponder(first))
    XCTAssertTrue(window.firstResponder === first.currentEditor())
    try XCTUnwrap(first.currentEditor()).insertTab(nil)
    XCTAssertTrue(window.firstResponder === second.currentEditor(), "Tab must pass through the hosting wrapper")
    try XCTUnwrap(second.currentEditor()).insertTab(nil)
    XCTAssertTrue(window.firstResponder === first.currentEditor(), "The forward loop must wrap")
    try XCTUnwrap(first.currentEditor()).insertBacktab(nil)
    XCTAssertTrue(window.firstResponder === second.currentEditor(), "Shift-Tab must wrap backward")
    XCTAssertFalse(window.isVisible, "No desktop focus or window ordering is needed")
  }

  func testControlPanelWindowStaysSpaceManagedAndKeepsFullScreen() {
    let window = ControlPanelWindow.make(contentViewController: NSViewController(), delegate: nil)
    defer { window.close() }
    XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace),
      "The panel must not carry .moveToActiveSpace, which breaks Space-return focus")
    XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces),
      "An ordinary window must not follow the person to every Space")
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone),
      "The green button must still offer full screen")

    // Existing normal flags survive: the helper only strips conflicting Space behaviors.
    let carrying = Self.unorderedWindow()
    carrying.collectionBehavior = [.managed, .fullScreenPrimary, .ignoresCycle]
    ControlPanelWindow.moveToActiveSpace(carrying, activeSpace: { 42 }, moveWindow: { _, _ in
      XCTFail("Unordered windows must never call CGSMoveWindowsToManagedSpace")
    })
    XCTAssertEqual(carrying.collectionBehavior, [.managed, .fullScreenPrimary, .ignoresCycle])

    let everywhere = Self.unorderedWindow()
    everywhere.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
    ControlPanelWindow.moveToActiveSpace(everywhere, activeSpace: { 42 }, moveWindow: { _, _ in })
    XCTAssertEqual(everywhere.collectionBehavior, [.fullScreenPrimary])

    let transient = Self.unorderedWindow()
    transient.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
    ControlPanelWindow.moveToActiveSpace(transient, activeSpace: { 42 }, moveWindow: { _, _ in })
    XCTAssertEqual(transient.collectionBehavior, [.fullScreenPrimary])

    // Applying it again changes nothing.
    ControlPanelWindow.moveToActiveSpace(transient, activeSpace: { 42 }, moveWindow: { _, _ in })
    XCTAssertEqual(transient.collectionBehavior, [.fullScreenPrimary])
  }

  func testMoveToActiveSpaceOnlyMovesVisibleOffSpaceNonFullScreenWindows() {
    let offSpace = RecordingWindow(simulatedWindowNumber: 101, visible: true, onActiveSpace: false)
    offSpace.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
    var moves: [(Int, UInt64)] = []
    ControlPanelWindow.moveToActiveSpace(offSpace, activeSpace: { 275 }, moveWindow: { moves.append(($0, $1)) })
    XCTAssertEqual(offSpace.collectionBehavior, [.fullScreenPrimary])
    XCTAssertEqual(moves.count, 1)
    XCTAssertEqual(moves.first?.0, 101)
    XCTAssertEqual(moves.first?.1, 275)

    // Already on active Space, hidden, full-screen, or without an active managed Space ID: never moves.
    let sameSpace = RecordingWindow(simulatedWindowNumber: 102, visible: true, onActiveSpace: true)
    let hidden = RecordingWindow(simulatedWindowNumber: 103, visible: false, onActiveSpace: false)
    let fullScreen = RecordingWindow(
      simulatedWindowNumber: 104, visible: true, onActiveSpace: false,
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullScreen])
    var skippedMoves: [(Int, UInt64)] = []
    for candidate in [sameSpace, hidden, fullScreen] {
      ControlPanelWindow.moveToActiveSpace(candidate, activeSpace: { 275 }, moveWindow: { skippedMoves.append(($0, $1)) })
    }
    ControlPanelWindow.moveToActiveSpace(offSpace, activeSpace: { nil }, moveWindow: { skippedMoves.append(($0, $1)) })
    XCTAssertTrue(skippedMoves.isEmpty)
  }

  func testCurrentManagedSpaceIDSelectionForDisplay() {
    let displays: [String: WallpaperDisplaySpaces] = [
      "1": .init(displayUUID: "u1", spaces: [.init(id: "a", number: 1, managedID: 11)], current: "a", currentManagedID: 11),
      "2": .init(displayUUID: "u2", spaces: [.init(id: "b", number: 1, managedID: 22)], current: nil, currentManagedID: nil),
    ]
    XCTAssertEqual(WallpaperSpaceMonitor.currentManagedSpaceID(for: 1, in: displays), 11)
    XCTAssertNil(WallpaperSpaceMonitor.currentManagedSpaceID(for: 2, in: displays),
      "A full-screen display must return nil instead of stealing another monitor's managed Space")
    XCTAssertEqual(WallpaperSpaceMonitor.currentManagedSpaceID(for: 999, in: displays), 11)
    XCTAssertEqual(WallpaperSpaceMonitor.currentManagedSpaceID(for: nil, in: displays), 11)
    XCTAssertNil(WallpaperSpaceMonitor.currentManagedSpaceID(for: 1, in: nil))
  }

  func testBringForwardDeminiaturizesOnlyAMinimizedWindowAndMovesOffSpaceWindows() {
    let minimized = RecordingWindow()
    minimized.minimized = true
    ControlPanelWindow.bringForward(minimized, activeSpace: { 42 }, moveWindow: { _, _ in })
    XCTAssertEqual(minimized.calls, ["deminiaturize", "makeKeyAndOrderFront", "orderFrontRegardless"],
      "A minimized panel must leave the Dock before it is fronted")
    XCTAssertFalse(minimized.isMiniaturized)

    let open = RecordingWindow(simulatedWindowNumber: 77, visible: true, onActiveSpace: false)
    open.collectionBehavior = [.moveToActiveSpace]
    var recordedMoves: [(Int, UInt64)] = []
    ControlPanelWindow.bringForward(open, activeSpace: { 275 }, moveWindow: {
      recordedMoves.append(($0, $1))
      open.record("moveToSpace:\($1)")
    })
    XCTAssertEqual(open.calls, ["moveToSpace:275", "makeKeyAndOrderFront", "orderFrontRegardless"],
      "An already-open off-Space window moves to the active Space before ordering front")
    XCTAssertEqual(recordedMoves.map(\.0), [77])
    XCTAssertFalse(open.collectionBehavior.contains(.moveToActiveSpace))
  }

  /// A titled window that is never ordered onto the screen.
  private static func unorderedWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: true)
  }
}

/// Records the calls that would change what is on screen instead of making them.
private final class RecordingWindow: NSWindow {
  var minimized = false
  var simulatedWindowNumber = 0
  var simulatedVisible = false
  var simulatedOnActiveSpace = true
  private(set) var calls: [String] = []

  convenience init(
    simulatedWindowNumber: Int = 0,
    visible: Bool = false,
    onActiveSpace: Bool = true,
    styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
  ) {
    self.init(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: styleMask,
      backing: .buffered, defer: true)
    isReleasedWhenClosed = false
    self.simulatedWindowNumber = simulatedWindowNumber
    self.simulatedVisible = visible
    self.simulatedOnActiveSpace = onActiveSpace
  }

  override var windowNumber: Int { simulatedWindowNumber }
  override var isVisible: Bool { simulatedVisible }
  override var isOnActiveSpace: Bool { simulatedOnActiveSpace }
  override var isMiniaturized: Bool { minimized }
  func record(_ call: String) { calls.append(call) }
  override func deminiaturize(_ sender: Any?) {
    calls.append("deminiaturize")
    minimized = false
  }
  override func makeKeyAndOrderFront(_ sender: Any?) { calls.append("makeKeyAndOrderFront") }
  override func orderFrontRegardless() { calls.append("orderFrontRegardless") }
}

private struct KeyLoopHost: NSViewRepresentable {
  let fields: [NSTextField]

  func makeNSView(context: Context) -> NSStackView {
    let stack = NSStackView(views: fields)
    stack.orientation = .vertical
    return stack
  }
  func updateNSView(_ nsView: NSStackView, context: Context) {}
}

private final class SizingDelegate: NSObject, NSWindowDelegate {}
private final class SizingBridge: WallpaperBridge {
  override func rendererCounters() async throws -> BridgeRendererCountersReport {
    BridgeRendererCountersReport(
      recording: false, surfaces: [], audioAnalysisDeliveries: 0, audioAcceptedFrames: 0,
      audioActiveConsumers: 0, presentationFeedbackAvailable: false)
  }

  override func setRendererCountersEnabled(enabled: Bool) async throws {}
}
