import Foundation
import Observation

/// Persists the user's multi-display span preference (`Span across displays`) for Phase 1
/// (Native Video and Still Image wallpapers).
///
/// Off by default. Observable directly by SwiftUI views (`@Observable`) and also posts
/// `didChangeNotification` so `NativeVideoWallpaperHost` and `DisplaySpanStillImageHost` react
/// immediately without polling.
@MainActor
@Observable
final class DisplaySpanStore {
    static let shared = DisplaySpanStore()
    nonisolated static let enabledKey = "WallpaperMachine.displaySpanEnabled"
    static let didChangeNotification = Notification.Name("WallpaperMachine.displaySpanDidChange")

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func resetToDefaults() {
        let wasEnabled = isEnabled
        defaults.removeObject(forKey: Self.enabledKey)
        isEnabled = false
        if wasEnabled {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
