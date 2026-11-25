import AppKit

/// Resolves one automatic choice per display; all mutations share the user's command queue.
///
/// Precedence (highest to lowest):
/// 1. Presentation Mode / Manual Pause (`isPresentationPaused`) — holds all automatic changes.
/// 2. Focus Filter wallpaper / playlist override (`focus.selection`).
/// 3. App-driven wallpaper switch (`appWallpaperSwitch`).
/// 4. Power-source (Battery) wallpaper override (`onBattery` + `store.effectiveBatteryTarget`).
/// 5. Spaces (per-desktop override) stacked with Appearance / Time Schedule / Day-Night rules.
@MainActor
final class WallpaperAutomationScheduler {
    /// Runs the change in the display's command slot and says how that ended: whether it ran, and
    /// when it did not, whether a choice of the user's or another automatic command took its place.
    typealias Queue = @MainActor (String, @escaping @MainActor () async throws -> Void) async throws
        -> UserCommandQueue.Outcome
    typealias Apply = @MainActor (WallpaperAutomationTarget, String) async throws -> Void
    typealias Restore = @MainActor (WallpaperAutomationDisplayState, String, Bool) async throws -> Void

    private let store: WallpaperAutomationStore
    private let focus: FocusFilterState
    private let displays: @MainActor () -> [String]
    private let targetDisplay: @MainActor () -> String
    private let canRun: @MainActor (String) -> Bool
    private let capture: @MainActor (String) -> WallpaperAutomationDisplayState
    private let queue: Queue
    private let apply: Apply
    private let restore: Restore
    private let dark: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private let center: NotificationCenter
    private let appearanceCenter: NotificationCenter
    private let sleep: @Sendable (Duration) async throws -> Void
    private let spaceVisit: @MainActor (String) -> WallpaperSpaceVisit?
    private let spaceMonitor: WallpaperSpaceMonitor?
    private let isPresentationPaused: @MainActor () -> Bool
    private let onBattery: @MainActor () -> Bool
    private let appWallpaperSwitch: @MainActor (String) -> AppWallpaperSwitch?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Task<Void, Never>?
    private var armedFor: Date?
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var inFlight = Set<String>()
    private var started = false
    private var focusKey: String?
    private var focusDisplay: String?
    var onSettled: (() -> Void)?
    var onInputsChanged: ((Notification.Name) -> Void)?
    private struct CachedResolution {
        let revision: UInt64
        let solar: WallpaperSolarSettings?
        let dark: Bool
        let computedAt: Date
        let result: WallpaperAutomationPlanner.Result
    }
    private var resolutions: [String: CachedResolution] = [:]

    init(store: WallpaperAutomationStore, focus: FocusFilterState,
         displays: @escaping @MainActor () -> [String], targetDisplay: @escaping @MainActor () -> String,
         canRun: @escaping @MainActor (String) -> Bool,
         capture: @escaping @MainActor (String) -> WallpaperAutomationDisplayState,
         queue: @escaping Queue, apply: @escaping Apply, restore: @escaping Restore,
         dark: @escaping @MainActor () -> Bool = { WallpaperAutomationScheduler.systemIsDark },
         now: @escaping @MainActor () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent,
         center: NotificationCenter = .default,
         appearanceCenter: NotificationCenter = DistributedNotificationCenter.default(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         spaceMonitor: WallpaperSpaceMonitor? = nil,
         spaceVisit: @escaping @MainActor (String) -> WallpaperSpaceVisit? = { _ in nil },
         isPresentationPaused: @escaping @MainActor () -> Bool = { false },
         onBattery: @escaping @MainActor () -> Bool = { false },
         appWallpaperSwitch: @escaping @MainActor (String) -> AppWallpaperSwitch? = { _ in nil }) {
        self.store = store; self.focus = focus; self.displays = displays; self.targetDisplay = targetDisplay
        self.canRun = canRun; self.capture = capture; self.queue = queue; self.apply = apply; self.restore = restore
        self.dark = dark; self.now = now; self.calendar = calendar; self.center = center
        self.appearanceCenter = appearanceCenter; self.sleep = sleep
        self.spaceMonitor = spaceMonitor; self.spaceVisit = spaceVisit
        self.isPresentationPaused = isPresentationPaused
        self.onBattery = onBattery
        self.appWallpaperSwitch = appWallpaperSwitch
    }

    static var systemIsDark: Bool {
        // AppTheme can override NSApp.appearance; the global preference remains the system's choice.
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }

    func start() {
        guard !started else { evaluate(); return }
        started = true
        for (name, object): (Notification.Name, AnyObject?) in [
            (WallpaperAutomationStore.didChangeNotification, store),
            (FocusFilterState.didChangeNotification, focus),
            (PowerSourceMonitor.didChangeNotification, nil),
            (AppRuleMonitor.wallpaperSwitchDidChangeNotification, nil),
            (PresentationModeController.didChangeNotification, nil),
            (.NSSystemClockDidChange, nil), (.NSSystemTimeZoneDidChange, nil),
        ] { observe(center, name: name, object: object) }
        observe(appearanceCenter, name: .init("AppleInterfaceThemeChangedNotification"), object: nil)
        if let spaceMonitor { observe(center, name: WallpaperSpaceMonitor.didChangeNotification, object: spaceMonitor) }
        evaluate()
    }

    func stop() {
        started = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.cancel(); timer = nil; armedFor = nil
        for task in tasks.values { task.cancel() }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, object: AnyObject?) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resolutions.removeAll()
                self?.evaluate()
                self?.onInputsChanged?(name)
            }
        }
        observers.append((center, token))
    }

    /// An explicit selection lasts until the next event. During an active temporary override
    /// (Focus, app switch, or battery), preserve it on exit too. On a display that has a wallpaper
    /// for each desktop, a wallpaper chosen by hand becomes the current desktop's own unless the
    /// desktop is unpinned and following a stacked schedule or appearance rule.
    func noteManualChoice(_ display: String, wallpaperID: String? = nil) {
        if let wallpaperID, assignCurrentDesktop(display, to: wallpaperID) { return }
        let resolution = desired(on: display)
        if store.focusRestore[display] != nil, resolution.activeOverride == nil {
            do { try store.forgetFocus(on: display) }
            catch { AppLog.error("could not release override restoration after a manual choice: \(error.localizedDescription)") }
        } else { store.preserveManualWallpaper(on: display) }
        if let event = resolution.event { store.markHandled(event.key, on: display) }
        else if store.errors[display] != nil { store.markHandled("manual", on: display) }
    }

    /// Saves `wallpaperID` as the current desktop's choice. False when the display does not follow
    /// desktops, the desktop is unknown, a temporary override decides its wallpaper now, or the
    /// desktop is unpinned and following a stacked schedule/appearance rule.
    private func assignCurrentDesktop(_ display: String, to wallpaperID: String) -> Bool {
        let configuration = store.configuration(for: display)
        let resolution = desired(on: display)
        guard configuration.usesSpaces, store.focusRestore[display] == nil,
              resolution.activeOverride == nil, let visit = spaceVisit(display) else { return false }
        if configuration.ruleMode != .off, configuration.spaces[visit.spaceID] == nil {
            return false
        }
        let target = WallpaperAutomationTarget(kind: .wallpaper, id: wallpaperID)
        guard target.isValid else { return false }
        if configuration.spaces[visit.spaceID] != target {
            do { try store.update(display) { $0.spaces[visit.spaceID] = target } } catch {
                AppLog.error("could not keep the wallpaper for this desktop: \(error.localizedDescription)")
                return false
            }
        }
        // What the desktop now asks for is already on screen.
        if let event = desired(on: display).event { store.markHandled(event.key, on: display) }
        return true
    }

    func evaluate() {
        guard started else { return }
        let selection = focus.selection
        if selection?.key != focusKey {
            focusKey = selection?.key
            focusDisplay = selection.map { value in
                value.displayID ?? store.focusRestore.first { $0.value.key == "focus:" + value.key }?.key ?? targetDisplay()
            }
        }
        let pausedForPresentation = isPresentationPaused()
        let connected = Set(displays())
        let ids = connected.union(store.configurations.keys).union(store.focusRestore.keys)
            .subtracting([WallpaperAutomationStore.globalDisplayID])
        var nextDate: Date?
        for display in ids {
            let resolution = desired(on: display)
            store.setStatus(
                on: display, next: resolution.next, focused: resolution.focused,
                activeOverride: resolution.activeOverride)
            if store.configuration(for: display).ruleMode == .schedule {
                nextDate = min(nextDate ?? resolution.reevaluateAt, resolution.reevaluateAt)
            }
            guard connected.contains(display), !inFlight.contains(display), !pausedForPresentation else { continue }
            if let record = store.focusRestore[display], resolution.activeOverride == nil {
                let key = restorationKey(record, base: resolution.event)
                guard resolution.baseAvailable, store.handled[display] != key, canRun(display) else { continue }
                begin(display, key: key, restoring: true)
            } else if let event = resolution.event,
                      store.handled[display] != event.key,
                      resolution.focused || canRun(display) {
                begin(display, key: event.key, restoring: false)
            }
        }
        arm(nextDate)
    }

    private struct Resolution {
        var event: WallpaperAutomationOccurrence?
        var next: WallpaperAutomationOccurrence?
        var reevaluateAt: Date
        var activeOverride: WallpaperAutomationOverrideKind?
        var baseAvailable = true
        var ruleTarget: WallpaperAutomationTarget?

        var focused: Bool { activeOverride == .focus }
    }

    /// A Space's old pixels must not be published while its replacement is still waiting.
    func selectionIsSettled(on display: String) -> Bool {
        guard !inFlight.contains(display) else { return false }
        let resolution = desired(on: display)
        if let record = store.focusRestore[display], resolution.activeOverride == nil {
            return store.handled[display] == restorationKey(record, base: resolution.event)
        }
        return resolution.event.map { store.handled[display] == $0.key } ?? true
    }

    /// The choice this display is about to change to, while that change waits or runs; nil once
    /// it is handled or while an override restoration decides instead.
    func pendingTarget(on display: String) -> WallpaperAutomationTarget? {
        let resolution = desired(on: display)
        guard store.focusRestore[display] == nil || resolution.activeOverride != nil,
              let event = resolution.event, store.handled[display] != event.key else { return nil }
        return event.target
    }

    /// The currently due schedule or appearance target on `display` (before per-Space or temporary
    /// overrides), used for Space pinning and poster caching when Spaces stacks with a rule mode.
    func stackedRuleTarget(on display: String) -> WallpaperAutomationTarget? {
        desired(on: display).ruleTarget
    }

    /// Whether this display's change has been admitted and is running now, rather than waiting
    /// for playback to be able to run it.
    func isApplying(on display: String) -> Bool { inFlight.contains(display) }

    private func desired(on display: String) -> Resolution {
        let time = now()
        let configuration = store.configuration(for: display)
        let appearance = dark()
        let result: WallpaperAutomationPlanner.Result
        if let cached = resolutions[display], cached.revision == configuration.revision,
           cached.solar == store.solar, cached.dark == appearance,
           time >= cached.computedAt, time < cached.result.reevaluateAt {
            result = cached.result
        } else {
            result = WallpaperAutomationPlanner.resolve(configuration, now: time,
                dark: appearance, solar: store.solar, calendar: calendar)
            resolutions[display] = .init(revision: configuration.revision, solar: store.solar,
                dark: appearance, computedAt: time, result: result)
        }
        var resolved = Resolution(
            event: result.current, next: result.next, reevaluateAt: result.reevaluateAt,
            ruleTarget: result.current?.target)
        if configuration.usesSpaces {
            let visit = spaceVisit(display)
            resolved.baseAvailable = visit != nil
            if let visit {
                if let explicit = configuration.spaces[visit.spaceID] {
                    let key = "space:\(configuration.revision):\(visit.spaceID):\(visit.token):\(explicit.kind.rawValue):\(explicit.id)"
                    resolved.event = .init(key: key, date: time, target: explicit)
                } else if configuration.ruleMode != .off {
                    if let ruleEvent = result.current {
                        let key = "space:\(configuration.revision):\(visit.spaceID):\(visit.token):\(ruleEvent.key)"
                        resolved.event = .init(key: key, date: ruleEvent.date, target: ruleEvent.target)
                    } else {
                        resolved.event = nil
                    }
                } else if let inherited = visit.firstSpaceID.flatMap({ configuration.spaces[$0] }) {
                    // The target is part of the event: a desktop that follows Desktop 1 changes target
                    // within one visit when the desktops are reordered and another one becomes first.
                    let key = "space:\(configuration.revision):\(visit.spaceID):\(visit.token):\(inherited.kind.rawValue):\(inherited.id)"
                    resolved.event = .init(key: key, date: time, target: inherited)
                } else {
                    resolved.event = nil
                }
            } else {
                resolved.event = nil
            }
        }
        // Temporary override precedence: Focus Filter > App-driven switch > Power-source (Battery).
        if let selection = focus.selection {
            let target = selection.displayID ?? focusDisplay ?? targetDisplay()
            if display == target {
                resolved.event = .init(key: "focus:" + selection.key, date: time, target: selection.target)
                resolved.activeOverride = .focus
                return resolved
            }
        }
        if let appSwitch = appWallpaperSwitch(display) {
            resolved.event = .init(key: "app:" + appSwitch.key, date: time, target: appSwitch.target)
            resolved.activeOverride = .app
            return resolved
        }
        if onBattery(), let batteryTarget = store.effectiveBatteryTarget(for: display) {
            let key = "battery:\(batteryTarget.kind.rawValue.utf8.count):\(batteryTarget.kind.rawValue):\(batteryTarget.id.utf8.count):\(batteryTarget.id)"
            resolved.event = .init(key: key, date: time, target: batteryTarget)
            resolved.activeOverride = .battery
            return resolved
        }
        return resolved
    }

    private func restorationKey(_ record: FocusWallpaperRestore, base: WallpaperAutomationOccurrence?) -> String {
        "restore:\(record.key):\(base?.key ?? "none")"
    }

    private func begin(_ display: String, key: String, restoring: Bool) {
        inFlight.insert(display)
        tasks[display] = Task { [weak self] in
            guard let self else { return }
            defer { inFlight.remove(display); tasks[display] = nil; evaluate(); onSettled?() }
            var performed = false
            do {
                let outcome = try await queue(display) { [self] in
                    try Task.checkCancellation()
                    guard self.started, !self.isPresentationPaused(), self.displays().contains(display) else { return }
                    let resolution = self.desired(on: display)
                    if restoring {
                        guard resolution.activeOverride == nil, resolution.baseAvailable, self.canRun(display),
                              let record = self.store.focusRestore[display],
                              self.restorationKey(record, base: resolution.event) == key else { return }
                        try await self.finishOverride(display, record: record, base: resolution.event)
                        performed = true
                    } else {
                        guard let event = resolution.event, event.key == key,
                              self.store.handled[display] != key, resolution.focused || self.canRun(display) else { return }
                        if resolution.activeOverride != nil { try await self.applyOverride(event, on: display) }
                        else { try await self.apply(event.target, display) }
                        performed = true
                        self.store.markHandled(event.key, on: display)
                    }
                }
                if !performed, outcome == .yieldedToUser || outcome == .replacedByUser {
                    // The user's command took this display's slot. Do not enqueue another copy
                    // ahead of that accepted choice while it is starting.
                    store.markHandled(key, on: display)
                }
                // Replaced by another automatic command (an update reloading the files, a playlist
                // change): nothing the user chose stands in this change's place, so it is left
                // unhandled and the evaluation that follows asks for it again. Marking it handled
                // would drop a temporary override, or the restoration after one, for good.
            } catch is CancellationError {
                return
            } catch {
                store.markHandled(key, on: display, error: error.localizedDescription)
                AppLog.warn("automatic wallpaper change on \(display) failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyOverride(_ event: WallpaperAutomationOccurrence, on display: String) async throws {
        let current = capture(display)
        let previous = store.focusRestore[display]
        var record: FocusWallpaperRestore
        if var existing = previous, existing.pending || existing.expectedPlaylist == current.playlist {
            if existing.preserveWallpaper { existing.before.wallpaperID = current.wallpaperID }
            existing.key = event.key
            existing.preserveWallpaper = false
            record = existing
        } else {
            record = .init(key: event.key, before: current, expectedPlaylist: current.playlist,
                           baselineKey: store.handled[display])
        }
        record.pending = true
        try store.rememberFocus(record, on: display)
        do {
            try await apply(event.target, display)
            record.expectedPlaylist = capture(display).playlist
            record.pending = false
            try store.rememberFocus(record, on: display)
        } catch {
            if capture(display) == current {
                if let previous { try store.rememberFocus(previous, on: display) }
                else { try store.forgetFocus(on: display) }
            }
            throw error
        }
    }

    private func finishOverride(_ display: String, record: FocusWallpaperRestore,
                                base: WallpaperAutomationOccurrence?) async throws {
        let current = capture(display)
        if !record.pending, current.playlist != record.expectedPlaylist {
            // Editing/applying another playlist is a new user decision, not a temporary override.
            try store.forgetFocus(on: display)
            store.markHandled(base?.key ?? restorationKey(record, base: nil), on: display)
            return
        }
        if let base, !record.preserveWallpaper || base.key != record.baselineKey {
            try await apply(base.target, display)
            store.markHandled(base.key, on: display)
        } else {
            try await restore(record.before, display, record.preserveWallpaper)
            store.markHandled(base?.key ?? restorationKey(record, base: nil), on: display)
        }
        try store.forgetFocus(on: display)
    }

    private func arm(_ date: Date?) {
        guard armedFor != date else { return }
        timer?.cancel(); timer = nil; armedFor = date
        guard let date else { return }
        let seconds = max(0, date.timeIntervalSince(now()))
        timer = Task { [weak self, sleep] in
            do { try await sleep(.seconds(seconds)) } catch { return }
            guard let self, started else { return }
            armedFor = nil
            evaluate()
        }
    }
}
