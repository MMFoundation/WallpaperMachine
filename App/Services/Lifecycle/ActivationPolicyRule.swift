import AppKit

/// Whether the app keeps its Dock icon and menu bar (`.regular`) or lives in the status item
/// alone (`.accessory`).
///
/// The app is regular while one of its own ordinary windows is open, on screen or minimized
/// to the Dock. Every place that lowers the policy asks this one rule; whatever opens a window
/// raises the policy through `RegularActivationGate`. Pure, so it is tested without AppKit.
enum ActivationPolicyRule {
    /// One of the app's windows, as the rule sees it.
    struct Window: Equatable, Sendable {
        enum Role: Sendable {
            case controlPanel, update, preview, signIn, introduction
        }

        /// Nil for every other window: an alert, an open or save panel, the status item's, a
        /// wallpaper's borderless desktop window. Those never keep the Dock icon.
        var role: Role?
        var isVisible: Bool
        var isMiniaturized: Bool
    }

    /// True while an ordinary window is on screen or in the Dock. One that is ordered out, as
    /// a quit leaves the panel and the update window, no longer counts. While a quit runs, those two
    /// are put away (only a refused quit brings them back, and raises the policy itself), so
    /// they do not count whatever AppKit still reports for a minimized one. A quit closes a feature
    /// introduction outright.
    static func keepsRegular(_ windows: [Window], quitting: Bool) -> Bool {
        windows.contains { window in
            guard let role = window.role, window.isVisible || window.isMiniaturized else { return false }
            switch role {
            case .controlPanel, .update: return !quitting
            case .preview, .signIn, .introduction: return true
            }
        }
    }
}

/// Defers ordering the first ordinary window onto the screen until macOS has finished promoting
/// `NSApp` from `.accessory` to `.regular`.
///
/// Creating or fronting an ordinary window in the same run-loop turn as switching to `.regular`
/// causes macOS to skip that window and activate a window behind it when returning to its Space.
@MainActor
final class RegularActivationGate {
    static let defaultSettleDelay: Duration = .milliseconds(350)

    private let isRegular: () -> Bool
    private let applyRegular: () -> Void
    private let applyAccessory: () -> Void
    private let schedule: (Duration, @MainActor @escaping () -> Void) -> AnyObject
    private let settleDelay: Duration

    private var generation: UInt64 = 0
    private var scheduledToken: AnyObject?
    private var pending: [() -> Void] = []

    init(
        settleDelay: Duration = defaultSettleDelay,
        isRegular: @escaping () -> Bool = { NSApp.activationPolicy() == .regular },
        applyRegular: @escaping () -> Void = { _ = NSApp.setActivationPolicy(.regular) },
        applyAccessory: @escaping () -> Void = { _ = NSApp.setActivationPolicy(.accessory) },
        schedule: @escaping (Duration, @MainActor @escaping () -> Void) -> AnyObject = { delay, work in
            let task = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                work()
            }
            return CancellationToken(task: task)
        }
    ) {
        self.settleDelay = settleDelay
        self.isRegular = isRegular
        self.applyRegular = applyRegular
        self.applyAccessory = applyAccessory
        self.schedule = schedule
    }

    var hasPendingPresentations: Bool { !pending.isEmpty }

    /// Runs `action` right away once `NSApp` is already settled as `.regular`, or promotes the
    /// policy first and flushes queued presentations in FIFO order after `settleDelay`.
    func presentWhenRegular(_ action: @escaping () -> Void) {
        if isRegular(), pending.isEmpty {
            action()
            return
        }
        let wasIdle = pending.isEmpty
        pending.append(action)
        guard wasIdle else { return }
        applyRegular()
        generation &+= 1
        let expectedGeneration = generation
        scheduledToken = schedule(settleDelay) { [weak self] in
            self?.flush(expectedGeneration: expectedGeneration)
        }
    }

    /// Cancels any waiting presentation and drops the activation policy back to `.accessory`.
    func dropToAccessory() {
        cancelPending()
        applyAccessory()
    }

    /// Discards pending presentations without changing the current activation policy.
    func cancelPending() {
        generation &+= 1
        scheduledToken = nil
        pending.removeAll()
    }

    private func flush(expectedGeneration: UInt64) {
        guard expectedGeneration == generation else { return }
        scheduledToken = nil
        let queued = pending
        pending.removeAll()
        for action in queued {
            action()
        }
    }

    private final class CancellationToken {
        private let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
        deinit { task.cancel() }
    }
}
