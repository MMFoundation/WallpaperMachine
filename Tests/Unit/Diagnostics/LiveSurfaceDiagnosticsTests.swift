import XCTest

@testable import WallpaperMachine

/// Verifies that Live Surface Diagnostics performs zero idle polling while closed, manages renderer
/// counter ownership without disrupting external sessions, and formats per-surface VRAM & counter
/// readouts accurately.
@MainActor
final class LiveSurfaceDiagnosticsTests: XCTestCase {
    private static func makeSurface(
        displayID: String = "7",
        renderTargetBytes: UInt64 = 48 * 1024 * 1024,
        geometryBufferBytes: UInt64 = 4 * 1024 * 1024,
        videoConversionLiveBytes: UInt64 = 8 * 1024 * 1024,
        presentsSkippedUnchanged: UInt64 = 120,
        presentsDropped: UInt64 = 2,
        edrActive: Bool = true
    ) -> BridgeRendererSurfaceCounters {
        BridgeRendererSurfaceCounters(
            displayId: displayID,
            surfaceId: "1",
            generation: 1,
            sourceId: "unknown",
            sourcePath: "/library/scene/project.json",
            sourceCount: 0,
            backend: "scene",
            effectivePauseReasons: [],
            paused: false,
            timerWakeups: 0,
            drawRequests: 0,
            drawTicksSuppressed: 0,
            drawsExecuted: 0,
            drawsDropped: 0,
            renderSubmissions: 0,
            renderFailures: 0,
            presentRequests: 0,
            gpuCompletions: 0,
            simulationTicks: 0,
            presentsSkippedUnchanged: presentsSkippedUnchanged,
            presentedFrames: 0,
            presentsDropped: presentsDropped,
            presentGaps1Vsync: 0,
            presentGaps2Vsync: 0,
            presentGaps3plusVsync: 0,
            tickIntervalMicros: 16_667,
            contentPeriodMicros: 0,
            vsyncPeriodMicros: 0,
            videoDecodeOutputs: 0,
            videoSeeks: 0,
            videoFramesSelected: 0,
            videoFramesReused: 0,
            videoFramesSkipped: 0,
            videoSelectedGeneration: 0,
            videoConversions: 0,
            videoImports: 0,
            videoConversionLiveBytes: videoConversionLiveBytes,
            videoConversionPeakLiveBytes: videoConversionLiveBytes,
            renderTargetBytes: renderTargetBytes,
            geometryBufferBytes: geometryBufferBytes,
            edrActive: edrActive
        )
    }

    func testZeroPollingWhenClosedAndTurnsOffOwnCountersOnClose() async throws {
        var fetches = 0
        var enabledCalls: [Bool] = []
        let report = BridgeRendererCountersReport(
            recording: false,
            surfaces: [Self.makeSurface()],
            audioAnalysisDeliveries: 0,
            audioAcceptedFrames: 0,
            audioActiveConsumers: 0,
            presentationFeedbackAvailable: true
        )

        var sleepStarted: CheckedContinuation<Void, Never>?
        let monitor = LiveSurfaceDiagnosticsMonitor(
            fetchCounters: {
                fetches += 1
                return report
            },
            setCountersEnabled: { enabled in
                enabledCalls.append(enabled)
            },
            sleep: { _ in
                try await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        sleepStarted = continuation
                    }
                    try Task.checkCancellation()
                } onCancel: {
                    Task { @MainActor in
                        sleepStarted?.resume()
                        sleepStarted = nil
                    }
                }
            }
        )

        // Inactive monitor must never fetch or toggle counters.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fetches, 0)
        XCTAssertTrue(enabledCalls.isEmpty)
        XCTAssertFalse(monitor.isActive)

        // Opening starts polling and enables counters since none were recording.
        monitor.setActive(true)
        for _ in 0..<20 where monitor.latestReport == nil || enabledCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(enabledCalls, [true])
        XCTAssertEqual(monitor.latestReport?.surfaces.count, 1)

        // Closing cancels immediately and turns off counters it enabled itself.
        monitor.setActive(false)
        for _ in 0..<20 where enabledCalls.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(enabledCalls, [true, false])
        let fetchesAtClose = fetches
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fetches, fetchesAtClose, "closing Live Diagnostics must stop polling immediately")
    }

    func testDoesNotDisableCountersOwnedByAnotherSession() async throws {
        var enabledCalls: [Bool] = []
        let alreadyRecording = BridgeRendererCountersReport(
            recording: true,
            surfaces: [Self.makeSurface()],
            audioAnalysisDeliveries: 0,
            audioAcceptedFrames: 0,
            audioActiveConsumers: 0,
            presentationFeedbackAvailable: true
        )
        let monitor = LiveSurfaceDiagnosticsMonitor(
            fetchCounters: { alreadyRecording },
            setCountersEnabled: { enabledCalls.append($0) },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        monitor.setActive(true)
        for _ in 0..<20 where monitor.latestReport == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        monitor.setActive(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(
            enabledCalls.isEmpty,
            "must not turn off renderer counters that another session already enabled")
    }

    func testSurfaceDiagnosticsReportAndRuntimeLinesIncludeVramAndEdr() throws {
        let surface = Self.makeSurface(
            displayID: "7",
            renderTargetBytes: 44 * 1024 * 1024,
            geometryBufferBytes: 4 * 1024 * 1024,
            videoConversionLiveBytes: 12 * 1024 * 1024,
            presentsSkippedUnchanged: 42,
            presentsDropped: 1,
            edrActive: true
        )
        let report = BridgeRendererCountersReport(
            recording: true,
            surfaces: [surface],
            audioAnalysisDeliveries: 0,
            audioAcceptedFrames: 0,
            audioActiveConsumers: 0,
            presentationFeedbackAvailable: true
        )
        let settings = BridgeSnapshotFixtures.settings(
            sceneRenderers: [
                BridgeSceneBackendReport(
                    displayId: 7,
                    displayName: "Studio Display",
                    wallpaperId: "100",
                    wallpaperTitle: "Aurora",
                    backend: "native_metal",
                    failureStage: nil,
                    failureReason: nil,
                    videoPath: "none",
                    optimizationApplied: true,
                    qualityInForce: nil
                )
            ]
        )

        let rows = SurfaceDiagnosticsReport.make(from: report, settings: settings)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.subject, "Studio Display — Aurora")
        XCTAssertEqual(row.totalVramBytes, 48 * 1024 * 1024)
        XCTAssertEqual(row.presentsSkippedUnchanged, 42)
        XCTAssertEqual(row.presentsDropped, 1)
        XCTAssertEqual(row.videoConversionLiveBytes, 12 * 1024 * 1024)
        XCTAssertTrue(row.edrActive)
        XCTAssertTrue(row.vramLine.contains("48 MB"))
        XCTAssertTrue(row.vramLine.contains("44 MB"))
        XCTAssertTrue(row.vramLine.contains("4 MB"))
        XCTAssertTrue(row.videoConversionLine.contains("12 MB"))
        XCTAssertTrue(row.presentsLine.contains("42"))
        XCTAssertTrue(row.presentsLine.contains("1"))
        XCTAssertTrue(row.edrLine.contains("Active"))

        let diagLines = RuntimeDiagnosticsSession.rendererLines(report)
        let surfaceLine = try XCTUnwrap(diagLines.first { $0.hasPrefix("surface=scene/7") })
        XCTAssertTrue(surfaceLine.contains("render_target_bytes=\(44 * 1024 * 1024)"))
        XCTAssertTrue(surfaceLine.contains("geometry_buffer_bytes=\(4 * 1024 * 1024)"))
        XCTAssertTrue(surfaceLine.contains("edr_active=true"))
    }
}
