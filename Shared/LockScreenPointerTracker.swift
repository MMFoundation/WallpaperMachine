import AppKit
import CoreGraphics
import Foundation

/// Display-normalized cursor coordinates (0...1 across the display, x left-to-right, y top-to-bottom),
/// matching `owe_scene_wallpaper_mouse_input` and `NormalizedMousePosition`.
struct LockScreenPointerPosition: Equatable, Sendable {
  let x: Double
  let y: Double

  /// Maps a global CoreGraphics cursor location (top-left primary origin, y down) into a
  /// display's CoreGraphics bounds. Returns nil when outside the display (half-open on the
  /// far edges so adjacent displays never claim the same border point) or when any input is
  /// non-finite or empty.
  static func normalized(cursor: CGPoint, in bounds: CGRect) -> LockScreenPointerPosition? {
    guard cursor.x.isFinite, cursor.y.isFinite,
      LockScreenPointerProbe.isValidBounds(bounds)
    else { return nil }
    let dx = cursor.x - bounds.origin.x
    let dy = cursor.y - bounds.origin.y
    guard dx >= 0, dx < bounds.width, dy >= 0, dy < bounds.height else { return nil }
    let nx = min(max(dx / bounds.width, 0), 1)
    let ny = min(max(dy / bounds.height, 0), 1)
    return LockScreenPointerPosition(x: nx, y: ny)
  }
}

/// Minimal state changes to deliver to one lock-screen surface for a cursor sample.
struct LockScreenPointerUpdate: Equatable, Sendable {
  /// Non-nil only when enter/leave state changed and needs delivery.
  let entered: Bool?
  /// Non-nil only when the cursor is inside this display and moved (or just entered).
  let position: LockScreenPointerPosition?

  var isEmpty: Bool { entered == nil && position == nil }
}

/// Per-surface deduplication and enter/leave tracker for lock-screen hover input.
///
/// Leaving a display emits `entered = false` without snapping the position back to center
/// (matching desktop `DisplayPlane`), and a surface whose display never held the cursor
/// records `entered = false` without waking an idle scene.
struct LockScreenPointerDelivery: Equatable, Sendable {
  private(set) var entered: Bool?
  private(set) var position: LockScreenPointerPosition?

  mutating func update(cursor: CGPoint, in bounds: CGRect) -> LockScreenPointerUpdate {
    if let next = LockScreenPointerPosition.normalized(cursor: cursor, in: bounds) {
      let enteredChange: Bool? = entered == true ? nil : true
      let positionChange: LockScreenPointerPosition? = position == next ? nil : next
      entered = true
      position = next
      return LockScreenPointerUpdate(entered: enteredChange, position: positionChange)
    }
    position = nil
    if entered == true {
      entered = false
      return LockScreenPointerUpdate(entered: false, position: nil)
    }
    entered = false
    return LockScreenPointerUpdate(entered: nil, position: nil)
  }

  /// Clears hover state when a surface stops being eligible (pause, unlock, sleep, screen saver).
  /// Returns `true` when the surface had been told the cursor was inside and now needs an exit.
  mutating func exit() -> Bool {
    let wasEntered = entered == true
    entered = nil
    position = nil
    return wasEntered
  }

  /// Drops tracked state when the underlying renderer is torn down or replaced.
  mutating func reset() {
    entered = nil
    position = nil
  }
}

/// Which lock-screen surfaces may receive hover cursor updates.
///
/// Only active, unpaused Lock Screen Scene and Web surfaces track the cursor: previews,
/// unlocked desktop settle surfaces, screen savers (which dismiss on mouse movement),
/// paused or held surfaces, and plain video wallpapers never poll the cursor.
enum LockScreenPointerPolicy {
  enum SurfaceKind: Equatable, Sendable {
    case scene(acceptsPointerInput: Bool)
    case web(ready: Bool, hasError: Bool)
    case video
    case none
  }

  static func isEligible(
    preview: Bool,
    stopped: Bool,
    paused: Bool,
    loading: Bool,
    held: Bool,
    content: LockScreenContent,
    kind: SurfaceKind
  ) -> Bool {
    guard !preview, !stopped, !paused, !loading, !held, content == .lockScreen else {
      return false
    }
    switch kind {
    case .scene(let acceptsPointerInput):
      return acceptsPointerInput
    case .web(let ready, let hasError):
      return ready && !hasError
    case .video, .none:
      return false
    }
  }
}

/// Adaptive polling cadence for lock-screen cursor tracking.
///
/// While the cursor moves, polls at the highest eligible surface's target frame rate
/// (clamped to 15...60 Hz). After `stationaryDelay` without motion, backs off to
/// `stationaryInterval` (~12.5 Hz) and skips display-bounds lookups and renderer calls
/// until the cursor moves again.
struct LockScreenPointerCadence: Equatable, Sendable {
  static let minActiveFPS: UInt32 = 15
  static let maxActiveFPS: UInt32 = 60
  static let stationaryDelay: Duration = .milliseconds(500)
  static let stationaryInterval: Duration = .milliseconds(80)

  private(set) var lastCursorLocation: CGPoint?
  private(set) var lastMovementAt: ContinuousClock.Instant?

  static func activeInterval(forMaxFPS fps: UInt32) -> Duration {
    let clamped = min(max(fps, minActiveFPS), maxActiveFPS)
    let nanos = Int64((1_000_000_000.0 / Double(clamped)).rounded())
    return .nanoseconds(nanos)
  }

  /// Records a cursor location sample and returns `true` when it moved (or is the first sample).
  mutating func recordSample(_ cursor: CGPoint, at now: ContinuousClock.Instant) -> Bool {
    guard cursor.x.isFinite, cursor.y.isFinite else { return false }
    let changed = lastCursorLocation != cursor
    if changed {
      lastCursorLocation = cursor
      lastMovementAt = now
    }
    return changed
  }

  func nextInterval(maxFPS: UInt32, at now: ContinuousClock.Instant) -> Duration {
    let active = Self.activeInterval(forMaxFPS: maxFPS)
    guard let lastMovementAt, now - lastMovementAt >= Self.stationaryDelay else {
      return active
    }
    return max(active, Self.stationaryInterval)
  }

  mutating func reset() {
    lastCursorLocation = nil
    lastMovementAt = nil
  }
}

/// System probe for global cursor position and per-display CoreGraphics bounds.
///
/// Uses CoreGraphics (`CGEvent(source: nil)?.location`) directly in top-left global display
/// coordinates, falling back to `NSEvent.mouseLocation` converted through the primary display's
/// height if `CGEvent` is unavailable. Closures are injectable for deterministic tests.
struct LockScreenPointerProbe {
  var cursorLocation: @MainActor () -> CGPoint?
  var displayBounds: @MainActor (UInt32) -> CGRect?

  static let system = LockScreenPointerProbe(
    cursorLocation: {
      if let point = CGEvent(source: nil)?.location, point.x.isFinite, point.y.isFinite {
        return point
      }
      let appKit = NSEvent.mouseLocation
      let primary = CGDisplayBounds(CGMainDisplayID())
      return appKitToCoreGraphics(appKit, primaryHeight: primary.height)
    },
    displayBounds: { displayID in
      let bounds = CGDisplayBounds(displayID)
      return isValidBounds(bounds) ? bounds : nil
    }
  )

  /// Converts an AppKit global screen point (bottom-left primary origin, y up) to CoreGraphics
  /// global display coordinates (top-left primary origin, y down).
  static func appKitToCoreGraphics(_ point: NSPoint, primaryHeight: CGFloat) -> CGPoint? {
    guard point.x.isFinite, point.y.isFinite, primaryHeight.isFinite, primaryHeight > 0 else {
      return nil
    }
    return CGPoint(x: point.x, y: primaryHeight - point.y)
  }

  static func isValidBounds(_ bounds: CGRect) -> Bool {
    bounds.origin.x.isFinite && bounds.origin.y.isFinite
      && bounds.size.width.isFinite && bounds.size.height.isFinite
      && bounds.size.width > 0 && bounds.size.height > 0
  }
}
