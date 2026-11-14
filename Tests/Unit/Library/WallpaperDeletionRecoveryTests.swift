import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperDeletionRecoveryTests: XCTestCase {
    private var root: URL!
    private var previousHome: String?
    private var bridge: DisplayTransferTestBridge!
    private var store: BridgeStore!

    override func setUp() async throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-recovery-" + UUID().uuidString)
        setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
        bridge = DisplayTransferTestBridge(noPointer: .init())
        try bridge.installProjects(in: root.appendingPathComponent("Library"))
        store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
    }

    override func tearDown() async throws {
        if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
        else { unsetenv("WALLPAPER_MACHINE_HOME") }
        try FileManager.default.removeItem(at: root)
    }

    func testDeletingActiveWallpaperReturnsToThatDisplaysRecentWallpaper() async throws {
        store.history.recordSwitch(from: "c", to: "b", on: "primary")
        store.history.recordSwitch(from: "b", to: "a", on: "primary")
        var removals = 0
        store.onUserWallpaperRemoved = { _, _ in removals += 1 }

        let report = try await store.deleteWallpapersAsync(ids: ["a"]) {
            try FileManager.default.removeItem(at: $0)
        }

        XCTAssertEqual(report.deleted, ["a"])
        XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "b"])
        XCTAssertEqual(bridge.events, ["eject primary a", "apply primary b"])
        XCTAssertEqual(removals, 0, "Deleting a library item must not pause its display's playlist")
        XCTAssertEqual(store.history.recent(on: "primary", available: ["a", "b", "c"]), ["b", "c"])
    }

    func testFailedTrashRestoresTheWallpaperAndKeepsItsHistory() async throws {
        store.history.recordSwitch(from: "c", to: "a", on: "primary")
        let history = store.history.entries

        let report = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertEqual(report.failures.map(\.id), ["a"])
        XCTAssertEqual(bridge.assignments["primary"], "a")
        XCTAssertEqual(store.history.entries, history)
    }

    func testBatchNeverFallsBackToAnotherRequestedDeletionAndRestoresFailedDeletions() async throws {
        store.history.recordSwitch(from: "c", to: "b", on: "primary")
        store.history.recordSwitch(from: "b", to: "a", on: "primary")
        let report = try await store.deleteWallpapersAsync(ids: ["a", "b", "a"]) { url in
            if url.lastPathComponent == "b" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertEqual(report.deleted, ["a"])
        XCTAssertEqual(report.failures.map(\.id), ["b"])
        XCTAssertTrue(report.playbackFailures.isEmpty)
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "b"])
        XCTAssertEqual(bridge.ejections.map(\.0), ["primary", "secondary"])
        XCTAssertFalse(store.history.recent(on: "primary", available: ["a", "b", "c"]).contains("a"))
    }

    func testEachIndependentDisplayUsesItsOwnHistoryAndMirrorsFollowTheirSource() async throws {
        bridge.assignments = ["primary": "a", "secondary": "a"]
        try await store.refreshAllAsync()
        store.history.recordSwitch(from: "b", to: "a", on: "primary")
        store.history.recordSwitch(from: "c", to: "a", on: "secondary")
        _ = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in }
        XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "c"])

        bridge.assignments = ["primary": "b"]
        bridge.mirrors = ["secondary": "primary"]
        try await store.refreshAllAsync()
        store.history.recordSwitch(from: "c", to: "b", on: "primary")
        let previousApplies = bridge.applications.count
        _ = try await store.deleteWallpapersAsync(ids: ["b"]) { _ in }
        XCTAssertEqual(bridge.assignments, ["primary": "c"])
        XCTAssertEqual(store.monitorInformationSnapshot.rows.first { $0.displayId == "secondary" }?.wallpaperId, "c")
        XCTAssertEqual(bridge.applications.dropFirst(previousApplies).map(\.0), ["primary"])
    }

    func testMissingAndHeldHistoryEntriesAreSkippedWithoutLoadingThem() async throws {
        store.history.recordSwitch(from: "b", to: "c", on: "primary")
        store.history.recordSwitch(from: "c", to: "a", on: "primary")
        bridge.held = ["c"]
        try await store.refreshAllAsync()
        _ = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in }
        XCTAssertEqual(bridge.assignments["primary"], "b")

        bridge.assignments["primary"] = "a"
        bridge.held = []
        store.history.recordSwitch(from: "c", to: "b", on: "primary")
        store.history.recordSwitch(from: "b", to: "a", on: "primary")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Library/b"))
        try await store.refreshAllAsync()
        _ = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in }
        XCTAssertEqual(bridge.assignments["primary"], "c")
    }

    func testNoHistoryLeavesTheDisplayEmptyAndDeletingAnUnusedWallpaperDoesNotSwitchIt() async throws {
        _ = try await store.deleteWallpapersAsync(ids: ["c"]) { _ in }
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
        _ = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in }
        XCTAssertNil(bridge.assignments["primary"])
        XCTAssertEqual(bridge.assignments["secondary"], "b")
        XCTAssertTrue(bridge.applications.isEmpty)
    }

    func testUnsupportedHistoryIsSkipped() async throws {
        store.history.recordSwitch(from: "b", to: "c", on: "primary")
        store.history.recordSwitch(from: "c", to: "a", on: "primary")
        bridge.unsupported = ["c"]
        try await store.refreshAllAsync()
        _ = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in }
        XCTAssertEqual(bridge.assignments["primary"], "b")
    }

    func testFailedReplacementReportsPlaybackSeparatelyAndDoesNotWalkThroughHistory() async throws {
        store.history.recordSwitch(from: "b", to: "c", on: "primary")
        store.history.recordSwitch(from: "c", to: "a", on: "primary")
        bridge.failOnce = "primary=c"
        bridge.failAfterMutation = true
        let report = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in }

        XCTAssertEqual(report.deleted, ["a"])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.playbackFailures.map(\.display), ["primary"])
        XCTAssertNotNil(report.playbackError)
        XCTAssertNil(bridge.assignments["primary"])
        XCTAssertFalse(bridge.applications.contains { $0.0 == "primary" && $0.1 == "b" })
        XCTAssertEqual(store.history.recent(on: "primary", available: ["a", "b", "c"]), ["c", "b"])
    }

    func testFailedEjectionNeitherDeletesNorSwitchesWallpapers() async throws {
        store.history.recordSwitch(from: "c", to: "a", on: "primary")
        bridge.ejectFailure = CocoaError(.fileWriteUnknown)
        let report = try await store.deleteWallpapersAsync(ids: ["a"]) { _ in
            XCTFail("A wallpaper still in use must not be deleted")
        }
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertEqual(report.failures.map(\.id), ["a"])
        XCTAssertEqual(bridge.assignments["primary"], "a")
        XCTAssertTrue(bridge.applications.isEmpty)
    }

    func testPlaylistContinuationUsesTheDeletionCommandAndDoesNotReplayItsTimer() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let playlists = PlaylistStore(defaults: defaults)
        let collections = WallpaperCollectionStore(defaults: defaults)
        let clock = Date()
        playlists.update("primary") {
            $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["b", "a", "c"]
        }
        let scheduler = PlaylistScheduler(
            store: playlists, collections: collections, displays: { ["primary"] },
            library: { self.store.librarySnapshot.wallpapers.map(\.id) }, favorites: { [] },
            current: { self.store.shownWallpaperID(on: $0) }, isRunning: { _ in true },
            activate: { display, choose in
                var result: String?
                try await self.store.commands.run(slot: BridgeStore.activationSlot(displayId: display), origin: .playlist) {
                    guard let id = choose() else { return }
                    try await self.store.activateWallpaperAsync(id: id, displayId: display, origin: .playlist)
                    result = id
                }
                return result
            }, now: { clock }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        scheduler.start()
        defer { scheduler.stop() }
        store.continuePlaylistAfterDeletion = { display, deleted, before, available in
            try await scheduler.continueAfterDeletion(on: display, after: deleted,
                libraryBefore: before, available: available) { id in
                try await self.store.applyDeletionReplacement(id, on: display, origin: .playlist)
            }
        }
        store.history.recordSwitch(from: "b", to: "a", on: "primary")
        bridge.beforeApply = {
            self.bridge.beforeApply = nil
            playlists.schedule("primary", at: clock.addingTimeInterval(-1))
            scheduler.evaluate()
            await Task.yield()
        }

        try await store.commands.run(choosing: [BridgeStore.activationSlot(displayId: "primary")]) {
            let report = try await self.store.deleteWallpapersAsync(ids: ["a"]) {
                try FileManager.default.removeItem(at: $0)
            }
            XCTAssertTrue(report.playbackFailures.isEmpty)
            playlists.forget(report.deleted)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(bridge.assignments["primary"], "c", "The playlist order wins over history")
        XCTAssertEqual(bridge.events.filter { $0.hasPrefix("apply primary") }, ["apply primary c"])
        XCTAssertEqual(playlists.nextChange["primary"], clock.addingTimeInterval(30 * 60))
    }

    func testLaterUserChoiceRunsAfterTheDeletionReplacementAndWins() async throws {
        store.history.recordSwitch(from: "c", to: "a", on: "primary")
        let applying = expectation(description: "replacement started")
        var release: CheckedContinuation<Void, Never>?
        bridge.beforeApply = {
            self.bridge.beforeApply = nil
            applying.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        let deletion = Task { @MainActor in
            try await self.store.commands.run(choosing: [BridgeStore.activationSlot(displayId: "primary")]) {
                _ = try await self.store.deleteWallpapersAsync(ids: ["a"]) { _ in }
            }
        }
        await fulfillment(of: [applying], timeout: 5)
        let manual = Task { @MainActor in
            try await self.store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
                try await self.store.activateWallpaperAsync(id: "b", displayId: "primary", origin: .user)
            }
        }
        await Task.yield()
        let continuation = try XCTUnwrap(release)
        continuation.resume()
        try await deletion.value
        try await manual.value
        XCTAssertEqual(bridge.assignments["primary"], "b")
        XCTAssertEqual(bridge.events.filter { $0.hasPrefix("apply primary") }, ["apply primary c", "apply primary b"])
    }
}
