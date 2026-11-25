import Foundation

/// What a global keyboard shortcut does.
enum HotKeyAction: String, CaseIterable, Sendable {
    case togglePlayback, toggleMute, previousWallpaper, nextWallpaper, randomWallpaper, openControlPanel
    case toggleDesktopWidgets, toggleDesktopIcons, togglePresentationMode

    var command: AutomationCommand {
        switch self {
        case .togglePlayback: .togglePlayback
        case .toggleMute: .toggleMute
        case .nextWallpaper: .next(display: nil)
        case .previousWallpaper: .previous(display: nil)
        case .randomWallpaper: .random(display: nil, pool: .all)
        case .openControlPanel: .open(page: nil)
        case .toggleDesktopWidgets: .toggleDesktopWidgets
        case .toggleDesktopIcons: .toggleDesktopIcons
        case .togglePresentationMode: .togglePresentationMode
        }
    }

    /// The id the system hands back when the shortcut is pressed; stable, never zero.
    var identifier: UInt32 {
        switch self {
        case .togglePlayback: 1
        case .nextWallpaper: 2
        case .openControlPanel: 3
        case .previousWallpaper: 4
        case .randomWallpaper: 5
        case .toggleMute: 6
        case .toggleDesktopWidgets: 7
        case .toggleDesktopIcons: 8
        case .togglePresentationMode: 9
        }
    }

    var title: String {
        switch self {
        case .togglePlayback: String(localized: "Play or pause wallpapers")
        case .toggleMute: String(localized: "Mute or unmute wallpapers")
        case .nextWallpaper: String(localized: "Next wallpaper")
        case .previousWallpaper: String(localized: "Previous wallpaper")
        case .randomWallpaper: String(localized: "Random wallpaper")
        case .openControlPanel: String(localized: "Open the control panel")
        case .toggleDesktopWidgets: String(localized: "Toggle desktop widgets")
        case .toggleDesktopIcons: String(localized: "Toggle desktop icons")
        case .togglePresentationMode: String(localized: "Presentation mode")
        }
    }
}

/// A key and its modifiers as the system registers them: a Carbon virtual key code, which
/// names a key's position rather than its letter, and Carbon's modifier bits.
struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// How the panel shows it, such as ⌃⌥⌘P.
    var label: String
}

/// The user's global keyboard shortcuts, saved in UserDefaults. None is set until the user
/// records one, so the app never takes a key combination another app expects. Changes post
/// `didChangeNotification`; `GlobalHotKeys` registers them and records here any the system
/// refused.
@MainActor
final class HotKeyPreferences {
    static let shared = HotKeyPreferences()
    static let didChangeNotification = Notification.Name("WallpaperMachine.hotKeysDidChange")
    nonisolated static let bindingsKey = "WallpaperMachine.hotKeys"
    /// Stored separately from `bindingsKey` so existing backup validation of `bindingsKey`
    /// (`HotKeyAction(rawValue:)`) stays 100% backward-compatible.
    nonisolated static let layoutBindingsKey = "WallpaperMachine.displayLayoutHotKeys"

    private let defaults: UserDefaults
    private(set) var bindings: [HotKeyAction: HotKey]
    /// Global keyboard shortcuts bound to saved display layout IDs.
    private(set) var layoutBindings: [String: HotKey]
    /// Why the system refused a shortcut, by action. Not saved: registering again at the next
    /// launch may succeed.
    private(set) var failures: [HotKeyAction: String] = [:]
    /// Why the system refused a display layout shortcut, by layout ID. Not saved.
    private(set) var layoutFailures: [String: String] = [:]

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.bindingsKey)
            .flatMap { try? JSONDecoder().decode([String: HotKey].self, from: $0) } ?? [:]
        var bindings: [HotKeyAction: HotKey] = [:]
        for (name, hotKey) in stored {
            if let action = HotKeyAction(rawValue: name) { bindings[action] = hotKey }
        }
        self.bindings = bindings
        let storedLayouts = defaults.data(forKey: Self.layoutBindingsKey)
            .flatMap { try? JSONDecoder().decode([String: HotKey].self, from: $0) } ?? [:]
        self.layoutBindings = storedLayouts.filter { !$0.key.isEmpty }
    }

    /// Sets or, with nil, clears the shortcut for `action`. A combination another action or
    /// display layout already uses is refused rather than silently moved.
    func set(_ hotKey: HotKey?, for action: HotKeyAction, layoutTitles: [String: String] = [:]) throws {
        if let hotKey {
            if let other = bindings.first(where: {
                $0.key != action && $0.value.keyCode == hotKey.keyCode && $0.value.modifiers == hotKey.modifiers
            })?.key {
                throw AutomationError(message: String(localized: "That shortcut is already used for “\(other.title)”."))
            }
            if let layoutID = layoutBindings.first(where: {
                $0.value.keyCode == hotKey.keyCode && $0.value.modifiers == hotKey.modifiers
            })?.key {
                let title = layoutTitles[layoutID] ?? String(localized: "Display layout")
                throw AutomationError(message: String(localized: "That shortcut is already used for “\(title)”."))
            }
        }
        guard bindings[action] != hotKey else { return }
        bindings[action] = hotKey
        failures[action] = nil
        let stored = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.bindingsKey) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Sets or, with nil, clears the shortcut for a saved display layout. Refuses combinations
    /// already claimed by an action or another layout.
    func set(_ hotKey: HotKey?, forLayout layoutID: String, layoutTitles: [String: String] = [:]) throws {
        if let hotKey {
            if let other = bindings.first(where: {
                $0.value.keyCode == hotKey.keyCode && $0.value.modifiers == hotKey.modifiers
            })?.key {
                throw AutomationError(message: String(localized: "That shortcut is already used for “\(other.title)”."))
            }
            if let otherID = layoutBindings.first(where: {
                $0.key != layoutID && $0.value.keyCode == hotKey.keyCode && $0.value.modifiers == hotKey.modifiers
            })?.key {
                let title = layoutTitles[otherID] ?? String(localized: "Display layout")
                throw AutomationError(message: String(localized: "That shortcut is already used for “\(title)”."))
            }
        }
        guard layoutBindings[layoutID] != hotKey else { return }
        layoutBindings[layoutID] = hotKey
        layoutFailures[layoutID] = nil
        persistLayoutBindings()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Removes shortcuts for deleted display layouts.
    func removeLayoutBinding(_ layoutID: String) {
        let removedBinding = layoutBindings.removeValue(forKey: layoutID) != nil
        let removedFailure = layoutFailures.removeValue(forKey: layoutID) != nil
        guard removedBinding || removedFailure else { return }
        if removedBinding { persistLayoutBindings() }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Clears every saved display layout shortcut (used by Reset All Settings).
    func clearAllLayoutBindings() {
        guard !layoutBindings.isEmpty || !layoutFailures.isEmpty else { return }
        layoutBindings.removeAll()
        layoutFailures.removeAll()
        defaults.removeObject(forKey: Self.layoutBindingsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Records whether the system accepted `action`'s shortcut; nil means it did.
    func recordFailure(_ message: String?, for action: HotKeyAction) {
        guard failures[action] != message else { return }
        failures[action] = message
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Records whether the system accepted a display layout's shortcut; nil means it did.
    func recordLayoutFailure(_ message: String?, for layoutID: String) {
        guard layoutFailures[layoutID] != message else { return }
        layoutFailures[layoutID] = message
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func persistLayoutBindings() {
        if layoutBindings.isEmpty {
            defaults.removeObject(forKey: Self.layoutBindingsKey)
        } else if let data = try? JSONEncoder().encode(layoutBindings) {
            defaults.set(data, forKey: Self.layoutBindingsKey)
        }
    }
}
