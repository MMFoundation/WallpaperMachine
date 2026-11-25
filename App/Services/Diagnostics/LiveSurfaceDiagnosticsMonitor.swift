import Foundation
import Observation

/// Polls per-surface renderer VRAM gauges and live surface counters ONLY while the Live Diagnostics
/// disclosure in Settings › Performance is expanded and the panel window is visible.
///
/// When closed or hidden (`setActive(false)`), the polling task is cancelled immediately and no
/// timer, IPC call, or background work runs. If this monitor turned renderer event counting on,
/// closing it turns counting back off; if another session (such as `TelemetrySampler` or
/// `RuntimeDiagnosticsSession`) already had counting on, this monitor leaves it alone.
@MainActor
@Observable
final class LiveSurfaceDiagnosticsMonitor {
    static let pollInterval: Duration = .seconds(2)

    private(set) var isActive = false
    private(set) var latestReport: BridgeRendererCountersReport?
    private(set) var isLoading = false

    @ObservationIgnored private let fetchCounters: @MainActor () async throws -> BridgeRendererCountersReport
    @ObservationIgnored private let setCountersEnabled: @MainActor (Bool) async throws -> Void
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var enabledCountersSelf = false

    init(
        fetchCounters: @escaping @MainActor () async throws -> BridgeRendererCountersReport,
        setCountersEnabled: @escaping @MainActor (Bool) async throws -> Void,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.fetchCounters = fetchCounters
        self.setCountersEnabled = setCountersEnabled
        self.sleep = sleep
    }

    convenience init(store: BridgeStore) {
        self.init(
            fetchCounters: { [weak store] in
                guard let store else { throw CancellationError() }
                return try await store.rendererCountersAsync()
            },
            setCountersEnabled: { [weak store] enabled in
                guard let store else { return }
                try await store.setRendererCountersEnabledAsync(enabled)
            }
        )
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        isLoading = latestReport == nil
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isLoading = false
        if enabledCountersSelf {
            enabledCountersSelf = false
            let disable = setCountersEnabled
            Task { @MainActor in
                try? await disable(false)
            }
        }
    }

    private func runLoop() async {
        defer { isLoading = false }
        while isActive && !Task.isCancelled {
            do {
                let report = try await fetchCounters()
                guard isActive, !Task.isCancelled else { break }
                latestReport = report
                isLoading = false
                // Turn event counting on only if nothing else owns it, so skipped/dropped
                // present counters advance while Live Diagnostics is open.
                if !report.recording && !enabledCountersSelf {
                    try await setCountersEnabled(true)
                    if isActive && !Task.isCancelled {
                        enabledCountersSelf = true
                    } else {
                        try? await setCountersEnabled(false)
                        break
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                isLoading = false
                AppLog.warn("live surface diagnostics read failed: \(error.localizedDescription)")
            }
            do {
                try await sleep(Self.pollInterval)
            } catch {
                break
            }
        }
    }
}
