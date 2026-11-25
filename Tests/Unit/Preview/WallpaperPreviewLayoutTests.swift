import AppKit
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperPreviewLayoutTests: XCTestCase {
    func testMinimumWidthKeepsLocalizedControlsAndFailureTextInSeparateRows() async throws {
        let reason = String(repeating: "A preview resource could not load. Reload the preview. ", count: 4)
        let session = WallpaperPreviewSession(load: { _ in throw WallpaperPreviewFailure(message: reason) }, makeSurface: { _, _ in
            throw WallpaperPreviewFailure(message: "A failed load must not create a surface")
        })
        let controller = WallpaperPreviewWindowController(session: session)
        controller.onApply = { _ in }
        let root = controller.makeContentView(size: CGSize(width: 480, height: 320))
        XCTAssertNil(root.window)
        session.open(.init(wallpaperID: "fixture", displayID: "primary"))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(session.phase, .failed(reason))
        let controls = try XCTUnwrap(root.subviews.compactMap { $0 as? NSStackView }.first)
        let buttons = controls.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        let status = try XCTUnwrap(root.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "preview-status" })
        let localizedTitles = [
            ["Pause", "Unmute", "Reload", "Apply"],
            ["暂停", "取消静音", "重新载入", "应用"],
            ["暫停", "取消靜音", "重新載入", "套用"],
            ["一時停止", "消音を解除", "再読み込み", "適用"],
            ["일시 정지", "소리 켜기", "다시 불러오기", "적용"],
            ["Reproduzir", "Ativar som", "Recarregar", "Aplicar"],
        ]
        for titles in localizedTitles {
            for (button, title) in zip(buttons, titles) { button.title = title }
            root.layoutSubtreeIfNeeded()
            for button in buttons {
                let rect = button.convert(button.bounds, to: root)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThanOrEqual(rect.maxX, root.bounds.width)
                XCTAssertGreaterThanOrEqual(rect.width + 1, button.intrinsicContentSize.width)
            }
            XCTAssertGreaterThan(status.frame.width, 400)
            XCTAssertLessThanOrEqual(status.frame.maxY, controls.frame.minY)
            XCTAssertEqual(status.toolTip, reason, "the complete diagnostic remains available even when its visible lines are capped")
            XCTAssertTrue(status.isSelectable)
        }
        session.close()
    }

    // MARK: Window size for the target display's shape

    private let ordinary = CGSize(width: 1440, height: 875)

    func testWindowSizeFollowsTheDisplayShapeOnAnOrdinaryScreen() {
        let controls = WallpaperPreviewWindowController.controlsHeight
        // No display answer keeps what every preview got before: a 16:9 stage under the controls.
        let standard = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary)
        XCTAssertEqual(standard.width, 1000)
        XCTAssertEqual(standard.height, 1000 * 9 / 16 + controls, accuracy: 0.01)
        XCTAssertEqual(WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: 16.0 / 9), standard)

        let shapes: [CGFloat] = [21.0 / 9, 32.0 / 9, 4.0 / 3, 3.0 / 4, 9.0 / 16]
        for aspect in shapes {
            let size = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: aspect)
            let stageHeight = size.height - controls
            XCTAssertLessThanOrEqual(size.height, ordinary.height - 80, "\(aspect) fits the screen")
            XCTAssertLessThanOrEqual(size.width, 1000)
            // The stage the window leaves for the wallpaper has the display's shape.
            let stageWidth = stageHeight * aspect
            XCTAssertLessThanOrEqual(stageWidth, size.width + 0.01, "\(aspect) is not cropped by the window")
            if aspect >= 1 { XCTAssertEqual(stageWidth, size.width, accuracy: 0.01, "\(aspect) uses the full width") }
        }
        let ultrawide = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: 21.0 / 9)
        XCTAssertLessThan(ultrawide.height, standard.height, "an ultrawide display needs less height")
        let portrait = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: 9.0 / 16)
        XCTAssertGreaterThan(portrait.height, standard.height, "a portrait display needs more height")
        XCTAssertEqual(portrait.height, ordinary.height - 80, accuracy: 0.01, "and shrinks to the screen instead of letterboxing")
        XCTAssertGreaterThanOrEqual(portrait.width, WallpaperPreviewWindowController.minimumContentWidth)
    }

    func testWindowSizeStaysUsableOnSmallScreensAndForOddShapes() {
        for visible in [CGSize(width: 520, height: 420), CGSize(width: 1024, height: 640), CGSize(width: 300, height: 200)] {
            let aspects: [CGFloat?] = [nil, 16.0 / 9, 21.0 / 9, 9.0 / 16, 4.0 / 3, 100, 0.001, CGFloat.nan, -2]
            for aspect in aspects {
                let size = WallpaperPreviewWindowController.contentSize(visibleSize: visible, aspect: aspect)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, max(1, visible.width - 40) + 0.01, "\(visible) \(String(describing: aspect))")
                XCTAssertLessThanOrEqual(size.height, visible.height - 80 + 0.01, "\(visible) \(String(describing: aspect))")
                if visible.width >= 520 {
                    XCTAssertGreaterThanOrEqual(size.width, WallpaperPreviewWindowController.minimumContentWidth,
                        "the control row keeps room for localized buttons")
                }
            }
        }
        XCTAssertEqual(WallpaperPreviewWindowController.contentSize(visibleSize: CGSize(width: 520, height: 420), aspect: nil),
            WallpaperPreviewWindowController.contentSize(visibleSize: CGSize(width: 520, height: 420), aspect: .nan),
            "a display that has no shape is treated like an unknown one")
    }

    // MARK: Stage inside the window

    private func makeController() -> WallpaperPreviewWindowController {
        let session = WallpaperPreviewSession(load: { _ in throw WallpaperPreviewFailure(message: "unused") },
            makeSurface: { _, _ in throw WallpaperPreviewFailure(message: "unused") })
        return WallpaperPreviewWindowController(session: session)
    }

    private func stage(in root: NSView) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "preview-stage" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root))
    }

    /// The stage is the largest box of the display's shape inside the black backdrop, centred.
    private func assertStage(_ stage: NSView, aspect: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(stage.superview, file: file, line: line)
        XCTAssertEqual(stage.frame.width / stage.frame.height, aspect, accuracy: 0.01, "shape", file: file, line: line)
        XCTAssertEqual(stage.frame.midX, container.bounds.midX, accuracy: 0.5, "centred across", file: file, line: line)
        XCTAssertEqual(stage.frame.midY, container.bounds.midY, accuracy: 0.5, "centred down", file: file, line: line)
        XCTAssertLessThanOrEqual(stage.frame.width, container.bounds.width + 0.01, file: file, line: line)
        XCTAssertLessThanOrEqual(stage.frame.height, container.bounds.height + 0.01, file: file, line: line)
        let touchesWidth = abs(stage.frame.width - container.bounds.width) < 0.5
        let touchesHeight = abs(stage.frame.height - container.bounds.height) < 0.5
        XCTAssertTrue(touchesWidth || touchesHeight, "as large as the backdrop allows", file: file, line: line)
    }

    func testStageTakesTheDisplayShapeAndFollowsTheWindowSize() throws {
        let controller = makeController()
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        let stage = try stage(in: root)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 16.0 / 9)  // nothing is known about the display yet

        controller.setStageAspect(9.0 / 16)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 9.0 / 16)
        XCTAssertLessThan(stage.frame.width, stage.frame.height)

        // Switching display replaces the shape; the old one must not linger as a second constraint.
        controller.setStageAspect(21.0 / 9)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 21.0 / 9)
        controller.setStageAspect(4.0 / 3)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 4.0 / 3)

        // A window dragged to another shape keeps the display's proportions, with bars.
        for size in [CGSize(width: 480, height: 900), CGSize(width: 1400, height: 400), CGSize(width: 600, height: 600)] {
            root.setFrameSize(size)
            root.layoutSubtreeIfNeeded()
            try assertStage(stage, aspect: 4.0 / 3)
        }
    }

    func testStageClampsAnUnusableShapeAndFallsBackToWidescreen() throws {
        let controller = makeController()
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        let stage = try stage(in: root)
        let cases: [(CGFloat?, CGFloat)] = [(nil, 16.0 / 9), (CGFloat.nan, 16.0 / 9), (0, 16.0 / 9), (-1, 16.0 / 9), (100, 4), (0.001, 0.25)]
        for (given, expected) in cases {
            controller.setStageAspect(given)
            root.layoutSubtreeIfNeeded()
            try assertStage(stage, aspect: expected)
        }
    }

    func testShapeChosenBeforeTheContentViewExistsIsKept() throws {
        let controller = makeController()
        controller.setStageAspect(9.0 / 16)  // present() runs this before the window is made
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        root.layoutSubtreeIfNeeded()
        try assertStage(try stage(in: root), aspect: 9.0 / 16)
    }

    func testSurfaceFillsTheStageNotTheWholeBackdrop() throws {
        let session = WallpaperPreviewSession(load: { _ in throw WallpaperPreviewFailure(message: "unused") },
            makeSurface: { _, _ in throw WallpaperPreviewFailure(message: "unused") })
        let controller = WallpaperPreviewWindowController(session: session)
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        let stage = try stage(in: root)
        controller.setStageAspect(9.0 / 16)
        root.layoutSubtreeIfNeeded()

        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        session.onSurface?(surface)
        XCTAssertTrue(surface.superview === stage)
        XCTAssertEqual(surface.frame, stage.bounds)
        XCTAssertLessThan(surface.frame.width, 600, "a portrait display's surface is narrow, as the display will be")

        controller.setStageAspect(21.0 / 9)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.frame.size.width, stage.bounds.width, accuracy: 0.5)
        XCTAssertEqual(surface.frame.size.height, stage.bounds.height, accuracy: 0.5)
        XCTAssertEqual(surface.frame.width / surface.frame.height, 21.0 / 9, accuracy: 0.02, "the page or scene sees the new shape")

        session.onSurface?(nil)
        XCTAssertTrue(stage.subviews.isEmpty)
    }

    // MARK: Shortcuts and Apply

    private func keyEvent(
        _ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    func testKeyboardShortcutsGuardWebViewTextFieldsAndButtons() throws {
        let reload = try keyEvent("r", keyCode: 15, modifiers: .command)
        let escape = try keyEvent("\u{1B}", keyCode: 53)
        let space = try keyEvent(" ", keyCode: 49)
        let mute = try keyEvent("m", keyCode: 46)
        let commandMute = try keyEvent("m", keyCode: 46, modifiers: .command)

        let plain = NSView()
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let webChild = NSView()
        webView.addSubview(webChild)
        let textView = NSTextView()
        let textField = NSTextField()
        let button = NSButton()

        // Normal view or nil responder allows all four shortcuts.
        for responder: NSResponder? in [nil, plain] {
            XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: reload, firstResponder: responder), .reload)
            XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: escape, firstResponder: responder), .close)
            XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: space, firstResponder: responder), .togglePause)
            XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: mute, firstResponder: responder), .toggleMute)
            XCTAssertNil(WallpaperPreviewWindowController.keyboardAction(for: commandMute, firstResponder: responder))
        }

        // WKWebView, descendants of WKWebView, and text inputs never lose Space or M.
        for responder: NSResponder in [webView, webChild, textView, textField] {
            XCTAssertNil(WallpaperPreviewWindowController.keyboardAction(for: space, firstResponder: responder))
            XCTAssertNil(WallpaperPreviewWindowController.keyboardAction(for: mute, firstResponder: responder))
            XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: reload, firstResponder: responder), .reload)
            XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: escape, firstResponder: responder), .close)
        }

        // Focused AppKit buttons keep Space activation while still allowing M, Cmd+R and Esc.
        XCTAssertNil(WallpaperPreviewWindowController.keyboardAction(for: space, firstResponder: button))
        XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: mute, firstResponder: button), .toggleMute)
        XCTAssertEqual(WallpaperPreviewWindowController.keyboardAction(for: reload, firstResponder: button), .reload)
    }

    func testApplyButtonInvokesCallbackAndReportsSuccessOrFailure() async throws {
        let selection = WallpaperPreviewSession.Selection(wallpaperID: "wp-1", displayID: "primary")
        let request = try WallpaperPreviewRequest(.init(
            wallpaperId: "wp-1", title: "Aurora", kind: .projectScene,
            projectPath: "/fixture/a", entryFile: "scene.json", assetsPath: "/fixture/assets",
            propertiesJson: "{}", fps: 30, scalingMode: .fill, scalingFactor: 1, volume: 0.5,
            engineOptions: nil, lutPath: nil, sceneQuality: .wallpaperEngineDefault))
        let surface = StubPreviewSurface()
        let session = WallpaperPreviewSession(load: { _ in request }, makeSurface: { _, _ in surface })
        let controller = WallpaperPreviewWindowController(session: session)
        let root = controller.makeContentView(size: CGSize(width: 480, height: 320))
        let controls = try XCTUnwrap(root.subviews.compactMap { $0 as? NSStackView }.first)
        let applyButton = try XCTUnwrap(
            controls.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "preview-apply" })
        let status = try XCTUnwrap(
            root.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "preview-status" })

        XCTAssertTrue(applyButton.isHidden, "hidden when no onApply callback is wired")

        var applied: [WallpaperPreviewSession.Selection] = []
        var failure: Error?
        controller.onApply = { sel in
            applied.append(sel)
            if let failure { throw failure }
        }
        session.open(selection)
        session.setVisible(true)
        for _ in 0..<20 where session.phase != .playing { await Task.yield() }
        XCTAssertFalse(applyButton.isHidden)
        XCTAssertTrue(applyButton.isEnabled)

        applyButton.performClick(nil)
        for _ in 0..<30 where applied.isEmpty || status.stringValue != String(localized: "Applied to desktop.") {
            await Task.yield()
        }
        XCTAssertEqual(applied, [selection])
        XCTAssertEqual(status.stringValue, String(localized: "Applied to desktop."))

        // Keyboard Space and M control the running session, and Esc closes it.
        XCTAssertTrue(controller.handleKeyEvent(try keyEvent(" ", keyCode: 49), firstResponder: nil))
        XCTAssertTrue(session.userPaused)
        XCTAssertTrue(controller.handleKeyEvent(try keyEvent("m", keyCode: 46), firstResponder: nil))
        XCTAssertFalse(session.muted)

        failure = WallpaperPreviewFailure(message: "Display unavailable.")
        applyButton.performClick(nil)
        for _ in 0..<30 where status.stringValue != "Display unavailable." { await Task.yield() }
        XCTAssertEqual(status.stringValue, "Display unavailable.")

        var closed = false
        controller.onClosed = { closed = true }
        XCTAssertTrue(controller.handleKeyEvent(try keyEvent("\u{1B}", keyCode: 53), firstResponder: nil))
        XCTAssertEqual(session.phase, .closed)
        XCTAssertTrue(closed)
    }
}

@MainActor
private final class StubPreviewSurface: WallpaperPreviewSurface {
    let view = NSView()
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    func start() async throws { onReady?() }
    func setPaused(_ paused: Bool) throws {}
    func setMuted(_ muted: Bool) throws {}
    func applyProperties(_ json: String) throws {}
    func applyEngineOptions(_ options: WallpaperEngineOptions) throws {}
    func stop() {}
}
