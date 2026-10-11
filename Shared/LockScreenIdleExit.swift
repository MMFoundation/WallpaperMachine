import Foundation

/// Ends the extension process once no wallpaper host or surface uses it.
///
/// RunningBoard hands a still-running process to WallpaperAgent even after macOS has
/// registered another copy of the extension (an app update or a second build). That
/// process never receives the new connection, and WallpaperAgent then stalls about
/// 30 seconds per request; lock-screen, screen-saver and System Settings wallpaper
/// requests queue behind it. Exiting while idle makes the next launch use the
/// registered copy.
@MainActor
final class LockScreenIdleExit {
  private let grace: Duration
  private let isBusy: () -> Bool
  private let exit: () -> Void
  private var connections = 0
  private var pending: Task<Void, Never>?

  init(grace: Duration, isBusy: @escaping () -> Bool, exit: @escaping () -> Void) {
    self.grace = grace
    self.isBusy = isBusy
    self.exit = exit
  }

  func connectionOpened() {
    connections += 1
    pending?.cancel()
    pending = nil
  }

  func connectionClosed() {
    connections = max(0, connections - 1)
    scheduleIfIdle()
  }

  func surfacesChanged() { scheduleIfIdle() }

  private func scheduleIfIdle() {
    guard connections == 0, !isBusy(), pending == nil else { return }
    pending = Task { [weak self, grace] in
      try? await Task.sleep(for: grace)
      guard let self, !Task.isCancelled else { return }
      self.pending = nil
      if self.connections == 0, !self.isBusy() { self.exit() }
    }
  }
}
