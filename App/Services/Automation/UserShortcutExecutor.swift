import AppKit
import Foundation

/// Result of attempting to carry out a wallpaper `usershortcut` custom action (`app:` / `shortcut:`).
enum UserShortcutExecutionResult: Equatable, Sendable {
    case executed(UserShortcutTarget)
    case rejectedEmptyOrUnsupported
    case rejectedUnapproved
    case rateLimitedPerShortcut(retryAfter: TimeInterval)
    case rateLimitedGlobalBurst(retryAfter: TimeInterval)
    case failed(String)
}

/// Injectable side-effect boundary for launching macOS apps and running Apple Shortcuts.
///
/// Unit tests inject a recording runner so tests NEVER launch real apps or spawn `/usr/bin/shortcuts`.
@MainActor
struct UserShortcutRunner {
    var openApplication: @MainActor (_ bundleID: String) async -> Bool
    var runShortcut: @MainActor (_ name: String) async -> Bool

    nonisolated static let shortcutsExecutablePath = "/usr/bin/shortcuts"
    nonisolated static let defaultShortcutTimeout: Duration = .seconds(15)

    /// Exact `Process.arguments` array for `/usr/bin/shortcuts` without any shell interpolation.
    /// Returns nil when `name` fails strict validation.
    nonisolated static func shortcutsProcessArguments(for name: String) -> [String]? {
        guard UserShortcutTarget.isValidShortcutName(name) else { return nil }
        return ["run", name]
    }

    static let live = UserShortcutRunner(
        openApplication: { bundleID in
            await Self.liveOpenApplication(bundleID: bundleID)
        },
        runShortcut: { name in
            await Self.liveRunShortcut(name: name)
        })

    /// Safe no-op runner for tests that only exercise rejection or rate-limiting paths.
    static let noop = UserShortcutRunner(
        openApplication: { _ in false },
        runShortcut: { _ in false })

    private static func liveOpenApplication(bundleID: String) async -> Bool {
        guard UserShortcutTarget.isValidBundleIdentifier(bundleID),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error {
                    AppLog.warn("User shortcut failed to open app \(bundleID): \(error.localizedDescription)")
                }
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }

    /// Runs an Apple Shortcut directly via `/usr/bin/shortcuts run <name>` using non-blocking
    /// `Process.terminationHandler` with a bounded timeout and cancellation cleanup — NEVER
    /// `sh -c`, shell interpolation, or synchronous `waitUntilExit()`.
    private static func liveRunShortcut(
        name: String,
        timeout: Duration = defaultShortcutTimeout
    ) async -> Bool {
        guard let arguments = shortcutsProcessArguments(for: name) else { return false }
        let executableURL = URL(fileURLWithPath: shortcutsExecutablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            AppLog.warn("User shortcut runner missing \(shortcutsExecutablePath)")
            return false
        }
        return await runProcess(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }

    /// Non-blocking subprocess runner backed by `terminationHandler`, terminating the child cleanly
    /// if `timeout` elapses or the enclosing Swift `Task` is cancelled.
    nonisolated static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: Duration = defaultShortcutTimeout
    ) async -> Bool {
        let state = ProcessCompletionState()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if !state.install(process: process, continuation: continuation) {
                    continuation.resume(returning: false)
                    return
                }
                process.terminationHandler = { finished in
                    let succeeded = finished.terminationReason == .exit && finished.terminationStatus == 0
                    if !succeeded, !state.wasCancelledOrTimedOut {
                        AppLog.warn("User shortcut subprocess exited with status \(finished.terminationStatus)")
                    }
                    state.finish(result: succeeded)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    AppLog.warn("User shortcut subprocess failed to launch: \(error.localizedDescription)")
                    state.finish(result: false)
                    return
                }
                let timeoutTask = Task.detached(priority: .utility) {
                    try? await Task.sleep(for: timeout)
                    state.terminateAndFinish(timedOut: true)
                }
                state.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.terminateAndFinish(timedOut: false)
        }
    }

    /// Thread-safe one-shot coordinator between `terminationHandler`, timeout timer, and Task cancellation.
    private final class ProcessCompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var completed = false
        private var cancelledOrTimedOut = false

        var wasCancelledOrTimedOut: Bool {
            lock.withLock { cancelledOrTimedOut }
        }

        func install(process: Process, continuation: CheckedContinuation<Bool, Never>) -> Bool {
            lock.withLock {
                guard !completed else { return false }
                self.process = process
                self.continuation = continuation
                return true
            }
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            let cancelImmediately: Bool = lock.withLock {
                if completed { return true }
                self.timeoutTask = task
                return false
            }
            if cancelImmediately { task.cancel() }
        }

        func finish(result: Bool) {
            let (cont, timer) = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
                guard !completed else { return (nil, nil) }
                completed = true
                let cont = continuation
                let timer = timeoutTask
                continuation = nil
                timeoutTask = nil
                process?.terminationHandler = nil
                process = nil
                return (cont, timer)
            }
            timer?.cancel()
            cont?.resume(returning: result)
        }

        func terminateAndFinish(timedOut: Bool) {
            let (proc, cont, timer) = lock.withLock {
                () -> (Process?, CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
                guard !completed else { return (nil, nil, nil) }
                completed = true
                cancelledOrTimedOut = true
                let proc = process
                let cont = continuation
                let timer = timeoutTask
                process = nil
                continuation = nil
                timeoutTask = nil
                proc?.terminationHandler = nil
                return (proc, cont, timer)
            }
            timer?.cancel()
            if let proc, proc.isRunning {
                if timedOut {
                    AppLog.warn("User shortcut subprocess timed out and was terminated.")
                }
                proc.terminate()
            }
            cont?.resume(returning: false)
        }
    }
}

/// Executes user-approved `app:<bundleID>` and `shortcut:<shortcutName>` wallpaper shortcuts
/// while enforcing two non-negotiable security redlines:
///
/// 1. Explicit user approval: a target executes ONLY if `UserShortcutStore` contains an exact
///    user-approved binding for `(wallpaperID, propertyID)`. Author-supplied defaults from
///    `project.json`, other wallpapers' approvals, missing wallpaper IDs, or tampered values
///    fail closed and are rejected.
/// 2. Anti-spam rate limiting: enforces BOTH a per-`(wallpaperID, propertyID)` cooldown (1.5 s)
///    and a global burst cap (3 launches per 10 s sliding window) recorded synchronously before
///    any async suspension so per-frame script loops can never spam-launch apps or Shortcuts.
@MainActor
final class UserShortcutExecutor {
    struct RateLimitPolicy: Equatable, Sendable {
        var perShortcutCooldown: TimeInterval = 1.5
        var globalBurstLimit: Int = 3
        var globalBurstWindow: TimeInterval = 10.0
    }

    enum Admission: Equatable, Sendable {
        case admitted(UserShortcutTarget)
        case rejected(UserShortcutExecutionResult)
    }

    private let store: UserShortcutStore
    private let runner: UserShortcutRunner
    private let policy: RateLimitPolicy
    private let now: @MainActor () -> TimeInterval
    private var lastExecutedByKey: [UserShortcutKey: TimeInterval] = [:]
    private var recentGlobalLaunches: [TimeInterval] = []

    init(
        store: UserShortcutStore = .shared,
        runner: UserShortcutRunner = .live,
        policy: RateLimitPolicy = RateLimitPolicy(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.runner = runner
        self.policy = policy
        self.now = now
    }

    /// Synchronously validates exact `(wallpaperID, propertyID, target)` approval and enforces
    /// per-shortcut cooldown + global burst limits, recording timestamps before any launch begins.
    /// Always fails closed if `wallpaperID` is empty.
    func admit(wallpaperID: String, propertyID: String, value: String) -> Admission {
        guard let target = UserShortcutTarget(rawValue: value) else {
            return .rejected(.rejectedEmptyOrUnsupported)
        }
        guard !wallpaperID.isEmpty,
              store.isApproved(wallpaperID: wallpaperID, propertyID: propertyID, target: target)
        else {
            return .rejected(.rejectedUnapproved)
        }

        let key = UserShortcutKey(wallpaperID: wallpaperID, propertyID: propertyID)
        let timestamp = now()

        // Prune expired cooldown entries so retired wallpapers/properties never accumulate.
        lastExecutedByKey = lastExecutedByKey.filter { timestamp - $0.value < policy.perShortcutCooldown }
        if let previous = lastExecutedByKey[key] {
            let elapsed = timestamp - previous
            return .rejected(.rateLimitedPerShortcut(retryAfter: max(0, policy.perShortcutCooldown - elapsed)))
        }

        recentGlobalLaunches.removeAll { timestamp - $0 >= policy.globalBurstWindow }
        if recentGlobalLaunches.count >= policy.globalBurstLimit {
            let oldest = recentGlobalLaunches.first ?? timestamp
            let retryAfter = max(0, policy.globalBurstWindow - (timestamp - oldest))
            return .rejected(.rateLimitedGlobalBurst(retryAfter: retryAfter))
        }

        // Record rate-limit timestamps BEFORE launching so concurrent or per-frame triggers cannot
        // race past the cooldown or burst cap while a launch is in flight.
        lastExecutedByKey[key] = timestamp
        recentGlobalLaunches.append(timestamp)
        return .admitted(target)
    }

    /// Runs an already-admitted target via the configured runner.
    func runAdmitted(_ target: UserShortcutTarget) async -> UserShortcutExecutionResult {
        let succeeded: Bool
        switch target {
        case .application(let bundleID):
            succeeded = await runner.openApplication(bundleID)
        case .shortcut(let name):
            succeeded = await runner.runShortcut(name)
        }
        return succeeded ? .executed(target) : .failed(target.rawValue)
    }

    /// Executes `value` for the exact `(wallpaperID, propertyID)` pair if explicitly approved and
    /// within rate limits.
    @discardableResult
    func execute(wallpaperID: String, propertyID: String, value: String) async -> UserShortcutExecutionResult {
        switch admit(wallpaperID: wallpaperID, propertyID: propertyID, value: value) {
        case .rejected(let result):
            return result
        case .admitted(let target):
            return await runAdmitted(target)
        }
    }
}
