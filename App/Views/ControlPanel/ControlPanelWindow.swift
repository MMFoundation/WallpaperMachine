import AppKit

/// Builds the control-panel window and owns its size floor.
///
/// `contentMinSize` alone does not hold: once the SwiftUI hosting controller attaches, it
/// resets the window's content minimum to zero even with `sizingOptions = []`, so the
/// window delegate clamps every user resize through `clampedFrameSize` instead.
///
/// The window carries no chrome of its own. The hosted page's `.toolbar` (the tabs and the
/// trailing tools) and `.navigationTitle` reach the window through the hosting controller's
/// `sceneBridgingOptions`; a manually assigned `NSToolbar` would fight them.
@MainActor
enum ControlPanelWindow {
    /// Smallest content area the panel lays out without clipping; the layout tests use it too.
    static let minimumContentSize = NSSize(width: 760, height: 560)
    static let initialContentSize = NSSize(width: 1240, height: 800)
    static let frameAutosaveName = "WallpaperMachineMainWindow"

    static func make(contentViewController: NSViewController, delegate: NSWindowDelegate?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "WallpaperMachine"
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.contentViewController = contentViewController
        // Attaching a controller sizes the window to its view, which a hosting controller with
        // `sizingOptions = []` has not laid out yet.
        window.setContentSize(initialContentSize)
        window.contentMinSize = minimumContentSize
        return window
    }

    /// Lets go of a closing panel window's content. The toolbar the hosted page bridged in comes
    /// off first: its SwiftUI items (the target-display `Menu` among them) register notification
    /// and key-value observers that are removed only when they leave a window, so a toolbar left on
    /// the closed window keeps them, and everything in their environment, the `PanelController`
    /// included, for as long as the app runs.
    static func tearDown(_ window: NSWindow) {
        window.toolbar = nil
        window.contentViewController = nil
    }

    /// Moves an already-open off-Space ordinary window onto the active managed Space and clears
    /// `.moveToActiveSpace` / `.canJoinAllSpaces` so AppKit continues managing it as a normal Space
    /// window.
    ///
    /// Keeping `.moveToActiveSpace` on an ordinary window — even transiently — causes macOS to
    /// skip the window and activate a window behind it when returning to its Space. Only an
    /// already-visible non-fullscreen window on another Space is moved via
    /// `CGSMoveWindowsToManagedSpace`.
    static func moveToActiveSpace(
        _ window: NSWindow,
        activeSpace: (() -> UInt64?)? = nil,
        moveWindow: ((Int, UInt64) -> Void)? = nil
    ) {
        var behavior = window.collectionBehavior
        behavior.subtract([.moveToActiveSpace, .canJoinAllSpaces])
        if behavior != window.collectionBehavior {
            window.collectionBehavior = behavior
        }
        guard window.isVisible,
              !window.isOnActiveSpace,
              !window.styleMask.contains(.fullScreen),
              window.windowNumber > 0 else { return }
        let resolveSpace = activeSpace ?? {
            WallpaperSpaceMonitor.currentManagedSpaceID(for: windowScreenDisplayID(window))
        }
        guard let spaceID = resolveSpace() else { return }
        if let moveWindow {
            moveWindow(window.windowNumber, spaceID)
        } else {
            _ = SystemSpaceWindowMover.shared?.move(windows: [window.windowNumber], toSpace: spaceID)
        }
    }

    private static func windowScreenDisplayID(_ window: NSWindow) -> UInt32? {
        (window.screen ?? NSScreen.main).flatMap(SystemDisplays.id(of:))
    }

    /// Fronts a window, bringing it back from the Dock first when it is minimized and moving an
    /// already-open off-Space window onto the active Space before ordering it front.
    ///
    /// `makeKeyAndOrderFront` only fronts the window among the app's own windows while the app
    /// is inactive, and macOS may decline the activation that follows: after an update the
    /// helper's `open` relaunches the app while another app is active, so What's New and the
    /// panel opened behind it, reachable only through Mission Control. `orderFrontRegardless`
    /// puts the window above the active app either way; it becomes key once the app activates.
    static func bringForward(
        _ window: NSWindow,
        activeSpace: (() -> UInt64?)? = nil,
        moveWindow: ((Int, UInt64) -> Void)? = nil
    ) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        moveToActiveSpace(window, activeSpace: activeSpace, moveWindow: moveWindow)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// The frame size the window may not shrink below: the minimum content size plus
    /// window chrome, capped by the visible frame of the screen it is on.
    static func minimumFrameSize(for window: NSWindow) -> NSSize {
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize))
        guard let visible = visibleFrame(for: window) else { return minimumFrame.size }
        return NSSize(width: min(minimumFrame.width, visible.width),
                      height: min(minimumFrame.height, visible.height))
    }

    /// Clamps a proposed frame size to the size floor; used from `windowWillResize`.
    static func clampedFrameSize(_ proposed: NSSize, for window: NSWindow) -> NSSize {
        let minimum = minimumFrameSize(for: window)
        return NSSize(width: max(proposed.width, minimum.width),
                      height: max(proposed.height, minimum.height))
    }

    /// Re-asserts the size floor and keeps the whole frame on the visible screen.
    static func constrainToScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let visible = visibleFrame(for: window) else { return }
        let minimumSize = minimumFrameSize(for: window)
        window.contentMinSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minimumSize)).size
        var frame = window.frame
        frame.size.width = min(max(frame.width, minimumSize.width), visible.width)
        frame.size.height = min(max(frame.height, minimumSize.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private static func visibleFrame(for window: NSWindow) -> NSRect? {
        (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }
}
