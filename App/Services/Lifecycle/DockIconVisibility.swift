import Foundation

/// The app's Dock preference, separate from renderer and wallpaper settings.
enum DockIconVisibility {
    enum Presence: Equatable, Sendable {
        case accessory
        case regular
    }

    static let defaultsKey = "WallpaperMachine.hideDockIcon"
    static let didChange = Notification.Name("WallpaperMachine.DockIconVisibility.didChange")

    static func isHidden(defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? false
    }

    /// Writes before notifying so an already-open window can read the committed choice.
    /// Repeating a choice does not cause another activation-policy transition.
    static func setHidden(
        _ hidden: Bool, defaults: UserDefaults = ClientPreferences.defaults,
        center: NotificationCenter = .default
    ) {
        let changed = isHidden(defaults: defaults) != hidden
        defaults.set(hidden, forKey: defaultsKey)
        if changed { center.post(name: didChange, object: nil) }
    }

    /// Turning the preference off restores the existing window-dependent behavior;
    /// it does not put a background-only app in the Dock.
    static func presence(hidesDockIcon: Bool, hasOpenWindow: Bool) -> Presence {
        hasOpenWindow && !hidesDockIcon ? .regular : .accessory
    }
}
