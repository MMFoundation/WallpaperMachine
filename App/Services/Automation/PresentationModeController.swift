import Foundation

/// One-click Presentation Mode: pauses wallpaper playback, mutes wallpapers, and hides desktop
/// widgets, restoring each prior state cleanly when turned off.
///
/// Hiding Finder's desktop icons restarts Finder, so it is strictly opt-in and OFF by default
/// (`hidesDesktopIconsKey`). When left off, Finder is never inspected or modified.
@MainActor
final class PresentationModeController {
    nonisolated static let hidesDesktopIconsKey = "WallpaperMachine.presentationHidesDesktopIcons"
    static let didChangeNotification = Notification.Name("WallpaperMachine.presentationModeDidChange")

    struct SavedState: Equatable, Sendable {
        var wasPaused: Bool
        var wasMuted: Bool
        var wereWidgetsHidden: Bool
        /// True only when Presentation Mode itself hid Finder's desktop icons on entry, so
        /// turning Presentation Mode off restores them without disturbing icons that were
        /// already hidden or when the opt-in setting was off.
        var hidDesktopIcons: Bool
    }

    private let defaults: UserDefaults
    private let isPaused: @MainActor () -> Bool
    private let setPaused: @MainActor (Bool) async throws -> Void
    private let isMuted: @MainActor () -> Bool
    private let setMuted: @MainActor (Bool) -> Void
    private let areDesktopWidgetsHidden: @MainActor () -> Bool
    private let setDesktopWidgetsHidden: @MainActor (Bool) -> Void
    private let areDesktopIconsShown: @MainActor () -> Bool
    private let setDesktopIconsShown: @MainActor (Bool) throws -> Void

    private(set) var isActive = false
    private(set) var savedState: SavedState?
    private var isTransitioning = false
    var onChange: (@MainActor () -> Void)?

    init(
        defaults: UserDefaults = ClientPreferences.defaults,
        isPaused: @escaping @MainActor () -> Bool,
        setPaused: @escaping @MainActor (Bool) async throws -> Void,
        isMuted: @escaping @MainActor () -> Bool,
        setMuted: @escaping @MainActor (Bool) -> Void,
        areDesktopWidgetsHidden: @escaping @MainActor () -> Bool,
        setDesktopWidgetsHidden: @escaping @MainActor (Bool) -> Void,
        areDesktopIconsShown: @escaping @MainActor () -> Bool = { FinderDesktopIcons().areShown },
        setDesktopIconsShown: @escaping @MainActor (Bool) throws -> Void = { try FinderDesktopIcons().setShown($0) }
    ) {
        self.defaults = defaults
        self.isPaused = isPaused
        self.setPaused = setPaused
        self.isMuted = isMuted
        self.setMuted = setMuted
        self.areDesktopWidgetsHidden = areDesktopWidgetsHidden
        self.setDesktopWidgetsHidden = setDesktopWidgetsHidden
        self.areDesktopIconsShown = areDesktopIconsShown
        self.setDesktopIconsShown = setDesktopIconsShown
    }

    /// Opt-in preference controlling whether Presentation Mode also hides Finder's desktop icons
    /// (which restarts Finder). Strictly OFF by default.
    static func hidesDesktopIcons(in defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
        defaults.object(forKey: hidesDesktopIconsKey) as? Bool ?? false
    }

    static func setHidesDesktopIcons(_ hide: Bool, in defaults: UserDefaults = ClientPreferences.defaults) {
        guard hide != hidesDesktopIcons(in: defaults) else { return }
        defaults.set(hide, forKey: hidesDesktopIconsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    func toggle() async throws {
        guard !isTransitioning else { return }
        if isActive {
            try await deactivate()
        } else {
            try await activate()
        }
    }

    func activate() async throws {
        guard !isActive, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let wasPaused = isPaused()
        let wasMuted = isMuted()
        let wereWidgetsHidden = areDesktopWidgetsHidden()
        let shouldHideIcons = Self.hidesDesktopIcons(in: defaults)

        if !wasPaused {
            try await setPaused(true)
        }
        if !wasMuted {
            setMuted(true)
        }
        if !wereWidgetsHidden {
            setDesktopWidgetsHidden(true)
        }

        var hidIcons = false
        var iconError: Error?
        if shouldHideIcons, areDesktopIconsShown() {
            do {
                try setDesktopIconsShown(false)
                hidIcons = true
            } catch let error as FinderDesktopIcons.RestartFailed {
                // The preference was written; only Finder's restart failed, so exiting still restores it.
                hidIcons = true
                iconError = error
            } catch {
                iconError = error
            }
        }

        savedState = SavedState(
            wasPaused: wasPaused,
            wasMuted: wasMuted,
            wereWidgetsHidden: wereWidgetsHidden,
            hidDesktopIcons: hidIcons)
        isActive = true
        AppLog.info("presentation mode: entered (hidDesktopIcons=\(hidIcons))")
        notifyChanged()
        if let iconError { throw iconError }
    }

    func deactivate() async throws {
        guard isActive, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let prior = savedState
        savedState = nil
        isActive = false

        var firstError: Error?
        if prior?.wasMuted == false {
            setMuted(false)
        }
        if prior?.wereWidgetsHidden == false {
            setDesktopWidgetsHidden(false)
        }
        if prior?.hidDesktopIcons == true {
            do {
                try setDesktopIconsShown(true)
            } catch {
                firstError = error
            }
        }
        if prior?.wasPaused == false {
            do {
                try await setPaused(false)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        AppLog.info("presentation mode: exited")
        notifyChanged()
        if let firstError { throw firstError }
    }

    /// Synchronous best-effort cleanup during app termination so global mute does not stay stuck
    /// on after quitting in Presentation Mode. Never restarts Finder during quit.
    func restoreMuteForTermination() {
        guard isActive else { return }
        if savedState?.wasMuted == false {
            setMuted(false)
        }
        savedState = nil
        isActive = false
    }

    private func notifyChanged() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
