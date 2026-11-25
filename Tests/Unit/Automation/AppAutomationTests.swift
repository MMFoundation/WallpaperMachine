import XCTest
@testable import WallpaperMachine

@MainActor
final class AppAutomationTests: XCTestCase {
    func testPlaylistAndPresetCatalogsFollowCurrentSavedRecords() async throws {
        let automation = AppAutomation(wait: .milliseconds(30), poll: .milliseconds(5))
        automation.handler = { _ in }
        var plans = [(id: "p", title: "Calm")]
        automation.playlistPlans = { plans }
        automation.displayLayouts = { [(id: "desk", title: "Work")] }
        automation.propertyPresets = { [(id: "look", title: "Evening", wallpaper: "Ocean")] }
        let first = await automation.availablePlaylistPlans()
        XCTAssertEqual(first.map(\.id), ["p"])
        plans = []
        let second = await automation.availablePlaylistPlans()
        XCTAssertTrue(second.isEmpty)
        let presets = await automation.availablePropertyPresets()
        XCTAssertEqual(presets.first?.wallpaper, "Ocean")
        let layouts = await automation.availableDisplayLayouts()
        XCTAssertEqual(layouts.first?.id, "desk")
    }
    func testACommandWaitsForTheAppToBeReady() async throws {
        let automation = AppAutomation(wait: .seconds(5), poll: .milliseconds(5))
        var received: [AutomationCommand] = []
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(30))
            automation.handler = { received.append($0) }
        }
        try await automation.perform(.pause)
        XCTAssertEqual(received, [.pause])
    }

    func testACommandThatOutwaitsTheStartSaysSo() async {
        let automation = AppAutomation(wait: .milliseconds(30), poll: .milliseconds(5))
        do {
            try await automation.perform(.play)
            XCTFail("no handler ever arrived")
        } catch {
            XCTAssertEqual(error as? AutomationError, .notReady)
        }
    }

    func testTheHandlersFailureReachesTheCaller() async {
        let automation = AppAutomation(wait: .milliseconds(30), poll: .milliseconds(5))
        automation.handler = { _ in throw AutomationError(message: "no such wallpaper") }
        do {
            try await automation.perform(.apply(wallpaperID: "gone", display: nil))
            XCTFail("the failure must not be swallowed")
        } catch {
            XCTAssertEqual((error as? AutomationError)?.message, "no such wallpaper")
        }
    }

    func testQueryAndFindWallpapersFiltersWorkAcrossAllAttributes() {
        let catalog = [
            AppAutomation.WallpaperInfo(
                id: "w1", title: "Aurora Night", kind: .scene, isFavorite: true,
                collectionIDs: ["c-nature"], collectionNames: ["Nature"]),
            AppAutomation.WallpaperInfo(
                id: "w2", title: "Neon Rain", kind: .video, isFavorite: false,
                collectionIDs: ["c-city"], collectionNames: ["City"]),
            AppAutomation.WallpaperInfo(
                id: "w3", title: "Ocean Clock", kind: .web, isFavorite: true,
                collectionIDs: ["c-nature", "c-minimal"], collectionNames: ["Nature", "Minimal"]),
        ]

        XCTAssertEqual(
            FindWallpapersIntent.filter(catalog, name: "aurora", kind: nil, favoritesOnly: false, collectionID: nil).map(\.id),
            ["w1"])
        XCTAssertEqual(
            FindWallpapersIntent.filter(catalog, name: nil, kind: .video, favoritesOnly: false, collectionID: nil).map(\.id),
            ["w2"])
        XCTAssertEqual(
            FindWallpapersIntent.filter(catalog, name: nil, kind: nil, favoritesOnly: true, collectionID: "c-nature").map(\.id),
            ["w1", "w3"])
        XCTAssertEqual(
            FindWallpapersIntent.filter(catalog, name: "clock", kind: .web, favoritesOnly: true, collectionID: "c-minimal").map(\.id),
            ["w3"])

        let entities = catalog.map(WallpaperEntity.init)
        let andMatches = WallpaperQuery.apply(
            comparators: [.isFavoriteEquals(true), .collectionContains("nature")],
            mode: .and,
            sortedBy: [],
            limit: nil,
            to: entities)
        XCTAssertEqual(andMatches.map(\.id), ["w1", "w3"])

        let orMatches = WallpaperQuery.apply(
            comparators: [.kindEquals(.video), .titleEquals("aurora night")],
            mode: .or,
            sortedBy: [],
            limit: 1,
            to: entities)
        XCTAssertEqual(orMatches.map(\.id), ["w1"])
    }

    func testNewQueryAndActionIntentsRouteThroughAppAutomation() async throws {
        let shared = AppAutomation.shared
        let savedHandler = shared.handler
        let savedCatalog = shared.wallpaperCatalog
        let savedCollections = shared.collections
        let savedStatus = shared.currentStatus
        defer {
            shared.handler = savedHandler
            shared.wallpaperCatalog = savedCatalog
            shared.collections = savedCollections
            shared.currentStatus = savedStatus
        }

        var commands: [AutomationCommand] = []
        shared.handler = { commands.append($0) }
        shared.wallpaperCatalog = {
            [
                AppAutomation.WallpaperInfo(
                    id: "w1", title: "Aurora", kind: .scene, isFavorite: true,
                    collectionIDs: ["col-1"], collectionNames: ["Calm"]),
            ]
        }
        shared.collections = { [(id: "col-1", name: "Calm")] }
        shared.currentStatus = { displayID in
            AppAutomation.CurrentWallpaperStatus(
                displayID: displayID ?? "primary",
                displayTitle: "Main Display",
                wallpaperID: "w1",
                wallpaperTitle: "Aurora",
                wallpaperKind: .scene,
                isFavorite: true,
                isPlaying: true,
                isMuted: false,
                isPresentationMode: false)
        }

        let currentIntent = GetCurrentWallpaperIntent()
        let currentResult = try await currentIntent.perform()
        let currentEntity = try XCTUnwrap(currentResult.value)
        XCTAssertEqual(currentEntity.displayID, "primary")
        XCTAssertEqual(currentEntity.wallpaperID, "w1")
        XCTAssertEqual(currentEntity.wallpaperTitle, "Aurora")
        XCTAssertTrue(currentEntity.isPlaying)
        XCTAssertFalse(currentEntity.isMuted)
        XCTAssertTrue(currentEntity.isFavorite)

        let findIntent = FindWallpapersIntent()
        findIntent.favoritesOnly = true
        findIntent.collection = WallpaperCollectionEntity(id: "col-1", name: "Calm")
        let foundResult = try await findIntent.perform()
        XCTAssertEqual(foundResult.value?.map(\.id), ["w1"])

        let randomIntent = RandomWallpaperIntent()
        randomIntent.source = .favorites
        randomIntent.collection = WallpaperCollectionEntity(id: "col-1", name: "Calm")
        _ = try await randomIntent.perform()

        let favoriteIntent = ToggleFavoriteWallpaperIntent()
        favoriteIntent.wallpaper = WallpaperEntity(id: "w1", title: "Aurora")
        _ = try await favoriteIntent.perform()

        let volumeIntent = SetWallpaperVolumeIntent()
        volumeIntent.volume = 50
        _ = try await volumeIntent.perform()

        let badVolume = SetWallpaperVolumeIntent()
        badVolume.volume = 150
        do {
            _ = try await badVolume.perform()
            XCTFail("volume outside 0...100 must be refused")
        } catch is AutomationError {}

        _ = try await ToggleDesktopWidgetsIntent().perform()
        _ = try await ToggleDesktopIconsIntent().perform()
        _ = try await TogglePresentationModeIntent().perform()

        XCTAssertEqual(commands, [
            .random(display: nil, pool: .favorites, collection: "col-1"),
            .toggleFavorite(wallpaperID: "w1", display: nil),
            .setVolume(0.5, displayID: nil),
            .toggleDesktopWidgets,
            .toggleDesktopIcons,
            .togglePresentationMode,
        ])
    }
}
