import AppKit
import SwiftUI

/// The popover the menu bar icon opens: `StatusPanelView` under the icon, transient, so a click
/// anywhere else closes it.
///
/// Each opening builds the controller and the hosting view afresh and starts the controller; the
/// close stops it and lets both go, so nothing the panel needs runs while it is closed. What
/// outlives an opening is two small facts: the display it showed and its quick-switcher batch,
/// which the next batch avoids. Opening it does not activate the app; an action that opens a
/// window closes it first (`StatusPanelController.openControlPanel`).
@MainActor
final class StatusPanelPopover: NSObject, NSPopoverDelegate {
  private weak var source: (any StatusPanelSource)?
  private var popover: NSPopover?
  private(set) var controller: StatusPanelController?
  private var lastDisplayID: String?
  private var lastStrip: [String] = []
  /// When the popover last began to close, by the system's uptime clock.
  private var closedAt: TimeInterval?
  /// How soon after a close a click on the icon is the one that closed it rather than a new one.
  private static let closingClick: TimeInterval = 0.3
  /// Space reserved for the popover arrow and breathing room below the menu bar and above the Dock.
  nonisolated static let verticalMargin: CGFloat = 48
  /// Floor so the popover remains usable even on an unexpectedly small visible frame.
  nonisolated static let minimumMaxHeight: CGFloat = 320
  /// Fallback maximum height when no screen visible frame is available.
  nonisolated static let defaultMaxHeight: CGFloat = 720

  init(source: any StatusPanelSource) {
    self.source = source
  }

  /// Maximum content height for a popover anchored on a screen with `visibleFrame`.
  ///
  /// `NSHostingController.sizingOptions = [.preferredContentSize]` sizes the popover to its
  /// content; passing this cap lets `StatusPanelView` size naturally when it fits and scroll its
  /// body above the pinned footer on shorter screens without ever collapsing.
  nonisolated static func maxContentHeight(for visibleFrame: NSRect?) -> CGFloat {
    guard let visibleFrame, visibleFrame.height > 0 else { return defaultMaxHeight }
    return max(minimumMaxHeight, (visibleFrame.height - verticalMargin).rounded(.down))
  }

  var isShown: Bool { popover?.isShown ?? false }

  /// Opens the panel under `button`, or closes it when it is open. Returns whether it opened.
  @discardableResult
  func toggle(from button: NSView) -> Bool {
    if let popover, popover.isShown {
      popover.performClose(nil)
      return false
    }
    // A transient popover closes on the press outside it, so the release of a click on the icon
    // that closed it must not open it again.
    if let closedAt, ProcessInfo.processInfo.systemUptime - closedAt < Self.closingClick { return false }
    return show(from: button)
  }

  func close() {
    popover?.performClose(nil)
  }

  private func show(from button: NSView) -> Bool {
    guard let source, popover == nil else { return false }
    let controller = StatusPanelController(
      source: source, display: lastDisplayID, previousStrip: lastStrip,
      dismiss: { [weak self] in self?.close() })
    let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    let maxHeight = Self.maxContentHeight(for: screen?.visibleFrame)
    let hosting = NSHostingController(
      rootView: StatusPanelRoot(controller: controller, maxHeight: maxHeight))
    hosting.sizingOptions = [.preferredContentSize]
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.delegate = self
    popover.contentViewController = hosting
    self.controller = controller
    self.popover = popover
    controller.start()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    return true
  }

  func popoverWillClose(_ notification: Notification) {
    closedAt = ProcessInfo.processInfo.systemUptime
  }

  func popoverDidClose(_ notification: Notification) {
    if let controller {
      lastDisplayID = controller.displayID
      lastStrip = controller.stripIDs
      controller.stop()
    }
    controller = nil
    popover?.contentViewController = nil
    popover?.delegate = nil
    popover = nil
  }
}
