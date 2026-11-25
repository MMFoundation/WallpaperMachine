import XCTest
@testable import WallpaperMachine

@MainActor
final class WorkshopUpdateStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var asked: [[String]] = []
    private var answer: [WorkshopItem] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workshop-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try TemporaryDefaults.make(for: self).defaults
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        asked = []
        answer = []
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String, updated: Date?) -> WorkshopItem {
        WorkshopItem(
            id: id, title: "Item \(id)", creator: "Creator", summary: "", previewURL: nil, tags: ["Video"],
            size: 1, subscriptions: 0, timeUpdated: updated)
    }

    private func makeStore() -> WorkshopUpdateStore {
        let recorder = Recorder()
        recorder.answer = answer
        recorder.onAsk = { self.asked.append($0) }
        return WorkshopUpdateStore(
            defaults: defaults, fetch: { ids in await recorder.reply(ids) }, now: { self.clock })
    }

    /// A folder whose project.json was last written at `date`.
    private func installed(_ id: String, writtenAt date: Date) throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("project.json")
        try Data("{}".utf8).write(to: manifest)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
    }

    private func settle(_ store: WorkshopUpdateStore) async throws {
        for _ in 0..<200 where store.isChecking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isChecking)
    }

    func testOnlyItemsChangedAfterTheirInstallAreOutdated() {
        let installed = clock
        let outdated = WorkshopUpdateStore.outdated(
            remote: [
                item("1", updated: installed.addingTimeInterval(3600)),
                item("2", updated: installed.addingTimeInterval(-3600)),
                item("3", updated: installed.addingTimeInterval(30)),
                item("4", updated: nil),
                item("5", updated: installed.addingTimeInterval(3600)),
            ],
            local: ["1": installed, "2": installed, "3": installed, "4": installed])
        XCTAssertEqual(Set(outdated.keys), ["1"], "within a minute is the same version, and an unknown install is never flagged")
    }

    func testACheckComparesDownloadsAndImportsAndSkipsWhatIsNotFromTheWorkshop() async throws {
        let store = makeStore()
        store.recordInstalled("100")
        try installed("200", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("100", updated: clock.addingTimeInterval(-60)), item("200", updated: clock.addingTimeInterval(-3600))]
        let checking = makeStore()
        checking.check(installed: ["100", "200", "image-photo.png", "local-movie.mp4"], library: root)
        try await settle(checking)
        XCTAssertEqual(asked, [["100", "200"]])
        XCTAssertEqual(Set(checking.available.keys), ["200"], "the import predates its item's last change")
        XCTAssertEqual(checking.lastChecked, clock)
        XCTAssertNil(checking.errorMessage)
    }

    /// An installed preset carries its base's content, so a change to the base is an update of
    /// the preset too: the check asks Steam about the base as well, and offers the preset.
    func testAChangedBaseIsAnUpdateOfThePresetBuiltOnIt() async throws {
        try installed("300", writtenAt: clock.addingTimeInterval(-7200))
        try Data(#"{"title":"Preset","dependency":"400"}"#.utf8)
            .write(to: root.appendingPathComponent("300/project.json"))
        try FileManager.default.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-7200)],
            ofItemAtPath: root.appendingPathComponent("300/project.json").path)
        answer = [item("300", updated: clock.addingTimeInterval(-9000)), item("400", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["300"], library: root)
        try await settle(store)
        XCTAssertEqual(asked, [["300", "400"]], "the base is asked about with the preset")
        XCTAssertEqual(Set(store.available.keys), ["300"], "the preset is offered; its base is not in the library")
        XCTAssertEqual(store.available["300"]?.title, "Item 300", "with the preset's own details")

        answer = [item("300", updated: clock.addingTimeInterval(-9000)), item("400", updated: clock.addingTimeInterval(-9000))]
        asked = []
        let unchanged = makeStore()
        unchanged.check(installed: ["300"], library: root)
        try await settle(unchanged)
        XCTAssertTrue(unchanged.available.isEmpty, "a base older than the preset's install is no update")
    }

    func testDownloadingAnUpdateMakesItCurrentAndResultsOutliveTheApp() async throws {
        try installed("300", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("300", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["300"], library: root)
        try await settle(store)
        XCTAssertNotNil(makeStore().available["300"], "found updates survive a relaunch")

        store.recordInstalled("300")
        XCTAssertNil(store.available["300"])
        XCTAssertNil(makeStore().available["300"])
    }

    func testADownloadThatFinishesDuringACheckStaysCurrent() async throws {
        try installed("600", writtenAt: clock.addingTimeInterval(-7200))
        let changed = [item("600", updated: clock.addingTimeInterval(-3600))]
        let gate = Gate()
        let store = WorkshopUpdateStore(
            defaults: defaults, fetch: { _ in
                await gate.wait()
                return changed
            }, now: { self.clock })
        store.check(installed: ["600"], library: root)
        store.recordInstalled("600")
        await gate.open()
        try await settle(store)
        XCTAssertNil(store.available["600"], "the check compared the version the download replaced")
    }

    func testAnImportedItemForgottenDuringACheckDoesNotReappear() async throws {
        try installed("601", writtenAt: clock.addingTimeInterval(-7200))
        try installed("602", writtenAt: clock.addingTimeInterval(-7200))
        let changed = [item("601", updated: clock.addingTimeInterval(-3600)),
                       item("602", updated: clock.addingTimeInterval(-3600))]
        let gate = Gate()
        let store = WorkshopUpdateStore(defaults: defaults, fetch: { _ in
            await gate.wait()
            return changed
        }, now: { self.clock })
        store.check(installed: ["601", "602"], library: root)
        store.forget(["601"])
        await gate.open()
        try await settle(store)
        XCTAssertEqual(Set(store.available.keys), ["602"])
        XCTAssertNil(makeStore().available["601"], "the delayed result must not be persisted again")
    }

    func testAutomaticChecksWaitADayAndCanBeTurnedOff() async throws {
        let store = makeStore()
        store.checkIfDue(installed: ["1"], library: root)
        try await settle(store)
        XCTAssertEqual(asked.count, 1)

        clock.addTimeInterval(WorkshopUpdateStore.checkInterval - 60)
        store.checkIfDue(installed: ["1"], library: root)
        try await settle(store)
        XCTAssertEqual(asked.count, 1, "less than a day later nothing is asked")

        store.checksAutomatically = false
        clock.addTimeInterval(WorkshopUpdateStore.checkInterval)
        store.checkIfDue(installed: ["1"], library: root)
        try await settle(store)
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(makeStore().checksAutomatically, "turning it off is remembered")
    }

    func testAFailedCheckSaysWhyAndKeepsWhatWasKnown() async throws {
        try installed("400", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("400", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["400"], library: root)
        try await settle(store)
        let failing = WorkshopUpdateStore(
            defaults: defaults, fetch: { _ in throw WorkshopFailure(message: "offline") }, now: { self.clock })
        failing.check(installed: ["400"], library: root)
        try await settle(failing)
        XCTAssertNotNil(failing.errorMessage)
        XCTAssertNotNil(failing.available["400"])
    }

    func testWallpapersThatLeaveTheLibraryAreForgotten() async throws {
        try installed("500", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("500", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["500"], library: root)
        try await settle(store)
        store.forget(["500"])
        XCTAssertNil(store.available["500"])
        XCTAssertNil(makeStore().available["500"])
    }

    private func settleDetails(_ store: WorkshopUpdateStore) async throws {
        for _ in 0..<200 where store.isLoadingDetails { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isLoadingDetails)
    }

    func testCurrentItemsKeepTheirDetailsWithoutBecomingUpdates() async throws {
        try installed("700", writtenAt: clock)
        answer = [item("700", updated: clock)]
        let store = makeStore()
        store.check(installed: ["700"], library: root)
        try await settle(store)
        XCTAssertTrue(store.available.isEmpty)
        XCTAssertEqual(store.details["700"]?.tags, ["Video"])
        XCTAssertEqual(makeStore().details["700"], answer.first, "details survive relaunch even without an update")
        store.selectDetails("700")
        try await settleDetails(store)
        XCTAssertEqual(asked, [["700"]], "the update check already fetched fresh details")
    }

    func testSelectedDetailsAreCachedAndSurviveAnOfflineRefresh() async throws {
        answer = [item("701", updated: clock)]
        let store = makeStore()
        store.checksAutomatically = false
        store.selectDetails("701")
        store.selectDetails("701")
        try await settleDetails(store)
        XCTAssertEqual(asked, [["701"]], "selection reads missing details once, independently of automatic updates")
        XCTAssertNotNil(store.details["701"])
        XCTAssertTrue(store.available.isEmpty, "reading details alone makes no update claim")

        let reopened = makeStore()
        reopened.selectDetails("701")
        XCTAssertFalse(reopened.isLoadingDetails, "fresh cached details need no request")
        XCTAssertEqual(reopened.details["701"], store.details["701"])
        clock.addTimeInterval(WorkshopUpdateStore.checkInterval + 1)
        let offline = WorkshopUpdateStore(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) }, now: { self.clock })
        offline.selectDetails("701")
        try await settleDetails(offline)
        XCTAssertEqual(offline.details["701"], store.details["701"], "offline keeps the last known tags")
        XCTAssertNil(offline.errorMessage, "optional details do not report an update-check failure")
        offline.forget(["701"])
        XCTAssertNil(makeStore().details["701"], "deletion clears the persistent details too")
    }

    func testLateDetailsCannotReappearAfterDeletionOrReplaceANewDownload() async throws {
        let gate = Gate()
        let old = item("702", updated: clock.addingTimeInterval(-3600))
        let store = WorkshopUpdateStore(defaults: defaults, fetch: { _ in await gate.wait(); return [old] })
        store.selectDetails("702")
        await Task.yield()
        store.forget(["702"])
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(store.details["702"])
        XCTAssertNil(makeStore().details["702"])

        let secondGate = Gate()
        let downloading = WorkshopUpdateStore(defaults: defaults, fetch: { _ in await secondGate.wait(); return [old] })
        downloading.selectDetails("702")
        await Task.yield()
        downloading.recordInstalled("702")
        let new = item("702", updated: clock)
        downloading.rememberDetails(new)
        await secondGate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(downloading.details["702"], new)
        XCTAssertEqual(makeStore().details["702"], new)
    }

    func testLocalIdsNeverAskSteamForDetails() {
        let store = makeStore()
        for id in ["image-photo", "pixiv-123-p0", "local-clip", "../123"] {
            store.selectDetails(id)
            XCTAssertFalse(store.isLoadingDetails)
        }
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertTrue(asked.isEmpty)
    }

    func testSwitchingAwayDiscardsLateDetailsAndAllowsARetry() async throws {
        let gate = Gate()
        let old = item("704", updated: clock)
        let store = WorkshopUpdateStore(defaults: defaults, fetch: { _ in await gate.wait(); return [old] })
        store.selectDetails("704")
        await Task.yield()
        store.selectDetails("local-image")
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(store.details["704"])
        store.selectDetails("704")
        try await settleDetails(store)
        XCTAssertEqual(store.details["704"], old)
    }

    func testDismissingAnUpdateHidesThatVersionUntilANewerUpdateArrivesAndClearsOnInstall() async throws {
        let installedAt = clock.addingTimeInterval(-7200)
        let firstUpdate = clock.addingTimeInterval(-3600)
        let newerUpdate = clock.addingTimeInterval(-600)
        try installed("801", writtenAt: installedAt)
        answer = [item("801", updated: firstUpdate)]
        let store = makeStore()
        store.check(installed: ["801"], library: root)
        try await settle(store)
        XCTAssertNotNil(store.available["801"])
        XCTAssertEqual(store.remoteUpdatedDate(for: "801"), firstUpdate)

        store.dismissUpdate(for: "801", remoteUpdated: firstUpdate)
        XCTAssertNil(store.available["801"])
        XCTAssertEqual(store.dismissedUpdateDate(for: "801"), firstUpdate)

        let reopened = makeStore()
        XCTAssertNil(reopened.available["801"], "dismissal survives relaunch")
        XCTAssertEqual(reopened.dismissedUpdateDate(for: "801"), firstUpdate)
        reopened.check(installed: ["801"], library: root)
        try await settle(reopened)
        XCTAssertNil(reopened.available["801"], "the same remote version stays hidden on re-check")

        // A newer publication from the author supersedes the dismissed version.
        answer = [item("801", updated: newerUpdate)]
        let rechecking = makeStore()
        rechecking.check(installed: ["801"], library: root)
        try await settle(rechecking)
        XCTAssertEqual(rechecking.available["801"]?.timeUpdated, newerUpdate)

        // Dismissing the newer version and then manually installing clears the dismissal record.
        rechecking.dismissUpdate(for: "801", remoteUpdated: newerUpdate)
        XCTAssertNotNil(rechecking.dismissedUpdateDate(for: "801"))
        rechecking.recordInstalled("801")
        XCTAssertNil(rechecking.dismissedUpdateDate(for: "801"))
        XCTAssertNil(makeStore().dismissedUpdateDate(for: "801"))

        // An in-flight check finishing after dismissal cannot resurface the dismissed version.
        try installed("802", writtenAt: installedAt)
        let inFlight = [item("802", updated: firstUpdate)]
        let gate = Gate()
        let racing = WorkshopUpdateStore(
            defaults: defaults, fetch: { _ in await gate.wait(); return inFlight }, now: { self.clock })
        racing.check(installed: ["802"], library: root)
        racing.dismissUpdate(for: "802", remoteUpdated: firstUpdate)
        await gate.open()
        try await settle(racing)
        XCTAssertNil(racing.available["802"], "dismissal made during an in-flight check is respected")
        racing.forget(["802"])
        XCTAssertNil(makeStore().dismissedUpdateDate(for: "802"), "forgetting a removed wallpaper clears its dismissal")
    }
}

/// Answers the store's details requests in place of Steam.
private final class Recorder: @unchecked Sendable {
    var answer: [WorkshopItem] = []
    var onAsk: (@MainActor ([String]) -> Void)?

    func reply(_ ids: [String]) async -> [WorkshopItem] {
        let onAsk = onAsk
        await MainActor.run { onAsk?(ids) }
        return answer.filter { ids.contains($0.id) }
    }
}

/// Holds a details request until the test lets it answer.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
