import Foundation
import XCTest

@testable import WallpaperMachine

final class LibraryStorageHealthServiceTests: XCTestCase {
    private var root: URL!
    private var libraryURL: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var sceneStorageURL: URL { root.appendingPathComponent("SceneStorage", isDirectory: true) }
    private var spacePostersURL: URL { root.appendingPathComponent("Cache/SpacePosters", isDirectory: true) }
    private var previousHome: String?
    private let service = LibraryStorageHealthService()
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sceneStorageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spacePostersURL, withIntermediateDirectories: true)
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome {
            setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
        } else {
            unsetenv("WALLPAPER_MACHINE_HOME")
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func writeFile(_ data: Data, at relativePath: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func makeVideoWallpaper(
        id: String, title: String, fileName: String, content: Data, preview: Data = Data("prev".utf8)
    ) throws -> LibraryStorageHealthService.WallpaperRecord {
        let folder = libraryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"type":"video","title":"\#(title)","file":"\#(fileName)","preview":"preview.jpg"}"#
        try writeFile(Data(manifest.utf8), at: "project.json", in: folder)
        try writeFile(preview, at: "preview.jpg", in: folder)
        try writeFile(content, at: fileName, in: folder)
        return .init(id: id, title: title, kind: .video, cachedSizeBytes: nil, addedAt: nil)
    }

    private func makeImageWallpaper(
        id: String, title: String, imageFile: String, content: Data, preview: Data = Data("thumb".utf8)
    ) throws -> LibraryStorageHealthService.WallpaperRecord {
        let folder = libraryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"type":"web","title":"\#(title)","file":"index.html","preview":"preview.jpg","image":{"file":"\#(imageFile)"}}"#
        try writeFile(Data(manifest.utf8), at: "project.json", in: folder)
        try writeFile(Data("<html></html>".utf8), at: "index.html", in: folder)
        try writeFile(preview, at: "preview.jpg", in: folder)
        try writeFile(content, at: imageFile, in: folder)
        return .init(id: id, title: title, kind: .webpage, cachedSizeBytes: nil, addedAt: nil)
    }

    private func makeSceneWallpaper(
        id: String, title: String, files: [String: Data], preview: Data = Data("scene-prev".utf8)
    ) throws -> LibraryStorageHealthService.WallpaperRecord {
        let folder = libraryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"type":"scene","title":"\#(title)","file":"scene.json","preview":"preview.jpg"}"#
        try writeFile(Data(manifest.utf8), at: "project.json", in: folder)
        try writeFile(preview, at: "preview.jpg", in: folder)
        for (relative, data) in files {
            try writeFile(data, at: relative, in: folder)
        }
        return .init(id: id, title: title, kind: .projectScene, cachedSizeBytes: nil, addedAt: nil)
    }

    private func makePayload(byteCount: Int, fill: UInt8) -> Data {
        Data(repeating: fill, count: byteCount)
    }

    // MARK: - Stage 1 / Stage 2 / Stage 3 duplicate pipeline

    func testThreeStageDuplicatePipelineFiltersSizeFastHashAndMiddleByteDiffs() async throws {
        // 200 KB payload > 2 * 64 KB so head (64 KB), middle (72 KB), and tail (64 KB) are distinct.
        let basePayload = makePayload(byteCount: 200 * 1024, fill: 0x41)
        var headDiffPayload = basePayload
        headDiffPayload[128] = 0x99
        var middleDiffPayload = basePayload
        middleDiffPayload[100 * 1024] = 0x77

        let dupA = try makeVideoWallpaper(
            id: "vid-a", title: "Ocean Copy A", fileName: "ocean.mp4", content: basePayload,
            preview: Data("preview-one".utf8))
        let dupB = try makeVideoWallpaper(
            id: "vid-b", title: "Ocean Copy B", fileName: "ocean_renamed.mp4", content: basePayload,
            preview: Data("preview-two-different".utf8))
        let sameSizeHeadDiff = try makeVideoWallpaper(
            id: "vid-head-diff", title: "Same Size Diff Head", fileName: "other.mp4",
            content: headDiffPayload)
        let sameSizeMiddleDiff = try makeVideoWallpaper(
            id: "vid-mid-diff", title: "Same Size Diff Middle", fileName: "mid.mp4",
            content: middleDiffPayload)
        let uniqueSize = try makeVideoWallpaper(
            id: "vid-unique", title: "Unique Size", fileName: "unique.mp4",
            content: makePayload(byteCount: 4096, fill: 0x22))
        let zeroByte = try makeVideoWallpaper(
            id: "vid-empty", title: "Empty", fileName: "empty.mp4", content: Data())

        let imgPayload = makePayload(byteCount: 8192, fill: 0x5A)
        let imgA = try makeImageWallpaper(
            id: "image-1", title: "Sunset 1", imageFile: "art.png", content: imgPayload,
            preview: Data("p1".utf8))
        let imgB = try makeImageWallpaper(
            id: "pixiv-2", title: "Sunset 2", imageFile: "illustration.png", content: imgPayload,
            preview: Data("p2-other".utf8))

        let input = LibraryStorageHealthService.Input(
            libraryURL: libraryURL,
            sceneStorageURL: sceneStorageURL,
            spacePosterCacheURL: spacePostersURL,
            now: referenceDate,
            wallpapers: [dupA, dupB, sameSizeHeadDiff, sameSizeMiddleDiff, uniqueSize, zeroByte, imgA, imgB])

        let report = try await service.scan(input: input)

        // Stage 1: 4 videos of 200 KB + 2 images of 8 KB = 6 collision candidates (unique + zero-byte skipped).
        XCTAssertEqual(report.pipelineStats.stage1SizeCollisionCandidates, 6)
        // Stage 2: vid-head-diff eliminated by 64 KB head+tail fingerprint; 3 videos + 2 images remain = 5.
        XCTAssertEqual(report.pipelineStats.stage2FastHashCollisionCandidates, 5)
        // Stage 3: vid-mid-diff eliminated by full SHA-256; 2 exact duplicate groups remain.
        XCTAssertEqual(report.pipelineStats.stage3VerifiedDuplicateGroups, 2)
        XCTAssertEqual(report.duplicateGroups.count, 2)

        let videoGroup = try XCTUnwrap(report.duplicateGroups.first { $0.contentSizeBytes == 200 * 1024 })
        XCTAssertEqual(Set(videoGroup.items.map(\.id)), ["vid-a", "vid-b"])
        XCTAssertEqual(videoGroup.items.filter(\.isRecommendedKeep).count, 1)

        let imageGroup = try XCTUnwrap(report.duplicateGroups.first { $0.contentSizeBytes == 8192 })
        XCTAssertEqual(Set(imageGroup.items.map(\.id)), ["image-1", "pixiv-2"])
    }

    func testMultiFileSceneFoldersHashScenePkgAndAssetsNotManifestOrPreview() async throws {
        let pkgA = makePayload(byteCount: 150 * 1024, fill: 0x11)
        var pkgB = pkgA
        pkgB[75 * 1024] = 0xFE // same size, different middle byte in scene.pkg

        // Exact duplicate scenes despite different project.json title & preview.jpg.
        let scene1 = try makeSceneWallpaper(
            id: "scene-1", title: "Forest Rain",
            files: ["scene.pkg": pkgA, "sounds/loop.mp3": Data("rain-audio".utf8)],
            preview: Data("preview-a".utf8))
        let scene2 = try makeSceneWallpaper(
            id: "scene-2", title: "Forest Rain (Reimport)",
            files: ["scene.pkg": pkgA, "sounds/loop.mp3": Data("rain-audio".utf8)],
            preview: Data("preview-b-larger".utf8))

        // Same project.json/preview and same total size, but different scene.pkg content -> NOT duplicate.
        let sceneDiffPkg = try makeSceneWallpaper(
            id: "scene-3", title: "Forest Rain",
            files: ["scene.pkg": pkgB, "sounds/loop.mp3": Data("rain-audio".utf8)],
            preview: Data("preview-a".utf8))

        // Same scene.pkg, but extra/different loose sound file -> NOT duplicate.
        let sceneDiffLoose = try makeSceneWallpaper(
            id: "scene-4", title: "Forest Rain",
            files: ["scene.pkg": pkgA, "sounds/loop.mp3": Data("wind-audio".utf8)],
            preview: Data("preview-a".utf8))

        // Unpacked multi-file scene with identical sorted relative paths vs renamed path.
        let unpacked1 = try makeSceneWallpaper(
            id: "unpacked-1", title: "Unpacked A",
            files: ["scene.json": Data("{}".utf8), "shaders/glow.frag": Data("void main(){}".utf8)])
        let unpacked2 = try makeSceneWallpaper(
            id: "unpacked-2", title: "Unpacked B",
            files: ["scene.json": Data("{}".utf8), "shaders/glow.frag": Data("void main(){}".utf8)])
        let unpackedRenamed = try makeSceneWallpaper(
            id: "unpacked-3", title: "Unpacked C",
            files: ["scene.json": Data("{}".utf8), "shaders/blur.frag": Data("void main(){}".utf8)])

        let input = LibraryStorageHealthService.Input(
            libraryURL: libraryURL,
            sceneStorageURL: sceneStorageURL,
            spacePosterCacheURL: spacePostersURL,
            now: referenceDate,
            wallpapers: [scene1, scene2, sceneDiffPkg, sceneDiffLoose, unpacked1, unpacked2, unpackedRenamed])

        let report = try await service.scan(input: input)
        XCTAssertEqual(report.duplicateGroups.count, 2)

        let groupSets = Set(report.duplicateGroups.map { Set($0.items.map(\.id)) })
        XCTAssertTrue(groupSets.contains(["scene-1", "scene-2"]))
        XCTAssertTrue(groupSets.contains(["unpacked-1", "unpacked-2"]))
    }

    func testDuplicateKeepRecommendationPrefersActiveFavoriteReferencedThenNewest() async throws {
        let payload = makePayload(byteCount: 16_384, fill: 0x33)
        var wOld = try makeVideoWallpaper(id: "w-old", title: "Old", fileName: "v.mp4", content: payload)
        wOld.addedAt = referenceDate.addingTimeInterval(-100 * 86_400)
        var wNew = try makeVideoWallpaper(id: "w-new", title: "New", fileName: "v.mp4", content: payload)
        wNew.addedAt = referenceDate.addingTimeInterval(-1 * 86_400)
        var wFav = try makeVideoWallpaper(id: "w-fav", title: "Fav", fileName: "v.mp4", content: payload)
        wFav.addedAt = referenceDate.addingTimeInterval(-50 * 86_400)
        var wActive = try makeVideoWallpaper(id: "w-active", title: "Active", fileName: "v.mp4", content: payload)
        wActive.addedAt = referenceDate.addingTimeInterval(-200 * 86_400)

        // Active beats favorite and newest.
        let activeRefs = LibraryStorageHealthService.ReferenceSnapshot(
            activeDisplayWallpaperIDs: ["w-active"],
            favoriteIDs: ["w-fav"])
        let reportActive = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: [wOld, wNew, wFav, wActive], references: activeRefs))
        XCTAssertEqual(reportActive.duplicateGroups.first?.recommendedKeepID, "w-active")

        // Without active, favorite beats newest.
        let favRefs = LibraryStorageHealthService.ReferenceSnapshot(favoriteIDs: ["w-fav"])
        let reportFav = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: [wOld, wNew, wFav], references: favRefs))
        XCTAssertEqual(reportFav.duplicateGroups.first?.recommendedKeepID, "w-fav")

        // Among unreferenced copies, newest wins.
        let reportNew = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: [wOld, wNew]))
        XCTAssertEqual(reportNew.duplicateGroups.first?.recommendedKeepID, "w-new")
    }

    // MARK: - Category 2: Large, not-recently-used & full reference protection

    func testUnusedCandidatesExcludeAllProtectionSetsAndHonorSizeAndRecencyFilters() async throws {
        let mb: Int64 = 1024 * 1024
        func stub(_ id: String, sizeMB: Int64) throws -> LibraryStorageHealthService.WallpaperRecord {
            let folder = libraryURL.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeFile(Data("x".utf8), at: "asset.bin", in: folder)
            return .init(id: id, title: id, kind: .video, cachedSizeBytes: sizeMB * mb, addedAt: nil)
        }

        let wallpapers = try [
            stub("active-1", sizeMB: 400),
            stub("fav-1", sizeMB: 400),
            stub("col-1", sizeMB: 400),
            stub("pl-list", sizeMB: 400),
            stub("pl-day", sizeMB: 400),
            stub("pl-plan", sizeMB: 400),
            stub("auto-rule", sizeMB: 400),
            stub("auto-dark", sizeMB: 400),
            stub("auto-space", sizeMB: 400),
            stub("layout-1", sizeMB: 400),
            stub("lock-1", sizeMB: 400),
            stub("saver-1", sizeMB: 400),
            // Unreferenced candidates:
            stub("unused-small-old", sizeMB: 50),
            stub("unused-150-recent", sizeMB: 150),
            stub("unused-150-45d", sizeMB: 150),
            stub("unused-300-120d", sizeMB: 300),
            stub("unused-600-unrecorded", sizeMB: 600),
        ]

        let refs = LibraryStorageHealthService.ReferenceSnapshot(
            activeDisplayWallpaperIDs: ["active-1"],
            favoriteIDs: ["fav-1"],
            collections: [.init(id: "c1", name: "Nature", wallpaperIDs: ["col-1"])],
            displayPlaylists: [
                .init(
                    displayID: "d1", displayTitle: "Main", wallpaperIDs: ["pl-list"],
                    dayWallpaperID: "pl-day", nightWallpaperID: nil)
            ],
            playlistPlans: [
                .init(
                    id: "p1", name: "Work", wallpaperIDs: ["pl-plan"],
                    dayWallpaperID: nil, nightWallpaperID: nil)
            ],
            automations: [
                .init(
                    displayID: "d1", displayTitle: "Main", mode: .spaces,
                    ruleWallpaperIDs: ["auto-rule"], lightWallpaperID: nil,
                    darkWallpaperID: "auto-dark", spaceWallpaperIDs: ["s1": "auto-space"])
            ],
            displayLayouts: [.init(id: "l1", name: "Desk", wallpaperIDs: ["layout-1"])],
            lockScreenWallpaperIDs: ["lock-1"],
            screenSaverWallpaperIDs: ["saver-1"])

        let lastUsed: [String: Date] = [
            "unused-small-old": referenceDate.addingTimeInterval(-100 * 86_400),
            "unused-150-recent": referenceDate.addingTimeInterval(-10 * 86_400),
            "unused-150-45d": referenceDate.addingTimeInterval(-45 * 86_400),
            "unused-300-120d": referenceDate.addingTimeInterval(-120 * 86_400),
            // unused-600-unrecorded intentionally absent (bounded history / unrecorded)
        ]

        let report = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: wallpapers, lastUsedDates: lastUsed, references: refs))

        // Every referenced/active wallpaper MUST be excluded from unreferencedWallpapers.
        let unreferencedIDs = Set(report.unreferencedWallpapers.map(\.id))
        XCTAssertEqual(
            unreferencedIDs,
            ["unused-small-old", "unused-150-recent", "unused-150-45d", "unused-300-120d", "unused-600-unrecorded"])

        // Filter: >= 100 MB, not used in 30+ days (includes no recent record).
        let mb100Days30 = report.unusedWallpapers(minimumSize: .mb100, recency: .days30).map(\.id)
        XCTAssertEqual(mb100Days30, ["unused-600-unrecorded", "unused-300-120d", "unused-150-45d"])

        // Filter: >= 250 MB, not used in 90+ days.
        let mb250Days90 = report.unusedWallpapers(minimumSize: .mb250, recency: .days90).map(\.id)
        XCTAssertEqual(mb250Days90, ["unused-600-unrecorded", "unused-300-120d"])

        // Filter: >= 500 MB, no recent use recorded only.
        let mb500Unrecorded = report.unusedWallpapers(minimumSize: .mb500, recency: .noRecentRecordOnly).map(\.id)
        XCTAssertEqual(mb500Unrecorded, ["unused-600-unrecorded"])

        // Filter: Any size, 30+ days includes small old wallpaper too.
        let anyDays30 = Set(report.unusedWallpapers(minimumSize: .any, recency: .days30).map(\.id))
        XCTAssertTrue(anyDays30.contains("unused-small-old"))
        XCTAssertFalse(anyDays30.contains("unused-150-recent"))
    }

    // MARK: - Category 3: Broken references & orphaned storage

    func testDetectsBrokenReferencesAcrossAllStoresAndIgnoresInstalledIDs() async throws {
        let installed = try makeVideoWallpaper(
            id: "installed-1", title: "Installed", fileName: "ok.mp4", content: Data("ok".utf8))
        let refs = LibraryStorageHealthService.ReferenceSnapshot(
            favoriteIDs: ["installed-1", "gone-fav"],
            collections: [.init(id: "c1", name: "Favs", wallpaperIDs: ["installed-1", "gone-col"])],
            displayPlaylists: [
                .init(
                    displayID: "d1", displayTitle: "Studio", wallpaperIDs: ["installed-1", "gone-pl"],
                    dayWallpaperID: "gone-day", nightWallpaperID: "installed-1")
            ],
            playlistPlans: [
                .init(
                    id: "plan-1", name: "Evening", wallpaperIDs: ["gone-plan"],
                    dayWallpaperID: nil, nightWallpaperID: nil)
            ],
            automations: [
                .init(
                    displayID: "d1", displayTitle: "Studio", mode: .schedule,
                    ruleWallpaperIDs: ["gone-auto"], lightWallpaperID: nil, darkWallpaperID: nil,
                    spaceWallpaperIDs: [:])
            ],
            displayLayouts: [.init(id: "l1", name: "Office", wallpaperIDs: ["installed-1", "gone-layout"])],
            metadataWallpaperIDs: ["installed-1", "gone-meta"],
            presets: [
                .init(id: "pr1", name: "Good Preset", wallpaperID: "installed-1"),
                .init(id: "pr2", name: "Orphan Preset", wallpaperID: "gone-preset"),
            ])

        let report = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: [installed], references: refs))

        XCTAssertFalse(report.brokenReferences.contains { $0.wallpaperID == "installed-1" })
        let bySource = Dictionary(grouping: report.brokenReferences, by: \.source)
        XCTAssertEqual(bySource[.favorites]?.map(\.wallpaperID), ["gone-fav"])
        XCTAssertEqual(bySource[.collections]?.map(\.wallpaperID), ["gone-col"])
        XCTAssertEqual(Set(bySource[.playlists]?.map(\.wallpaperID) ?? []), ["gone-pl", "gone-day", "gone-plan"])
        XCTAssertEqual(bySource[.automation]?.map(\.wallpaperID), ["gone-auto"])
        XCTAssertEqual(bySource[.metadata]?.map(\.wallpaperID), ["gone-meta"])
        XCTAssertEqual(bySource[.presets]?.map(\.wallpaperID), ["gone-preset"])
        XCTAssertEqual(bySource[.displayLayouts]?.map(\.wallpaperID), ["gone-layout"])
    }

    func testOrphanedSceneStorageAndSpacePostersDetectionAndSafeSymlinkResistantCleanup() async throws {
        let installed = try makeSceneWallpaper(
            id: "installed-scene", title: "Live Scene", files: ["scene.pkg": Data("pkg".utf8)])

        // Live SceneStorage (must be preserved).
        let liveStorage = sceneStorageURL.appendingPathComponent("installed-scene", isDirectory: true)
        try FileManager.default.createDirectory(at: liveStorage, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 512).write(to: liveStorage.appendingPathComponent("global.json"))

        // Orphaned SceneStorage (must be flagged and cleaned).
        let orphanStorage = sceneStorageURL.appendingPathComponent("deleted-scene", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanStorage, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1024).write(to: orphanStorage.appendingPathComponent("global.json"))

        // Active SpacePoster (must be preserved).
        let activePosterName = LibraryStorageHealthService.spacePosterFileName(
            display: "d1", wallpaperID: "installed-scene")
        let activePosterURL = spacePostersURL.appendingPathComponent(activePosterName)
        try Data(repeating: 3, count: 2048).write(to: activePosterURL)

        // Orphaned SpacePoster for an uninstalled wallpaper (must be flagged and cleaned).
        let orphanPosterName = LibraryStorageHealthService.spacePosterFileName(
            display: "d1", wallpaperID: "deleted-scene")
        let orphanPosterURL = spacePostersURL.appendingPathComponent(orphanPosterName)
        try Data(repeating: 4, count: 3072).write(to: orphanPosterURL)

        // Symlink escapes planted inside managed directories MUST be ignored on scan and refused on cleanup.
        let outsideDir = root.appendingPathComponent("OutsideVictim", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let victimFile = outsideDir.appendingPathComponent("keep.txt")
        try Data("precious".utf8).write(to: victimFile)
        try FileManager.default.createSymbolicLink(
            at: sceneStorageURL.appendingPathComponent("escape-link"),
            withDestinationURL: outsideDir)
        try FileManager.default.createSymbolicLink(
            at: spacePostersURL.appendingPathComponent("escape-poster.jpg"),
            withDestinationURL: victimFile)

        let refs = LibraryStorageHealthService.ReferenceSnapshot(
            automations: [
                .init(
                    displayID: "d1", displayTitle: "Main", mode: .spaces,
                    ruleWallpaperIDs: [], lightWallpaperID: nil, darkWallpaperID: nil,
                    spaceWallpaperIDs: ["space-1": "installed-scene"])
            ])

        let report = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: [installed], references: refs))

        XCTAssertEqual(report.orphanedStorage.count, 2)
        XCTAssertEqual(Set(report.orphanedStorage.map(\.name)), ["deleted-scene", orphanPosterName])
        XCTAssertEqual(report.orphanedStorageBytes, 1024 + 3072)

        // Attempt to trick cleanup with traversal and symlink entries alongside genuine orphans.
        let forgedTraversal = LibraryStorageHealthService.OrphanedStorageItem(
            id: "forged-traversal", kind: .sceneStorage, name: "../OutsideVictim",
            url: outsideDir, sizeBytes: 8)
        let forgedSymlink = LibraryStorageHealthService.OrphanedStorageItem(
            id: "forged-symlink", kind: .sceneStorage, name: "escape-link",
            url: sceneStorageURL.appendingPathComponent("escape-link"), sizeBytes: 8)
        let forgedPosterSymlink = LibraryStorageHealthService.OrphanedStorageItem(
            id: "forged-poster-symlink", kind: .spacePoster, name: "escape-poster.jpg",
            url: spacePostersURL.appendingPathComponent("escape-poster.jpg"), sizeBytes: 8)

        let cleanup = try await service.cleanOrphanedStorage(
            report.orphanedStorage + [forgedTraversal, forgedSymlink, forgedPosterSymlink],
            sceneStorageURL: sceneStorageURL,
            spacePosterCacheURL: spacePostersURL)

        XCTAssertEqual(cleanup.removedIDs.count, 2)
        XCTAssertEqual(cleanup.reclaimedBytes, 1024 + 3072)
        XCTAssertEqual(cleanup.failures.count, 3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanStorage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPosterURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveStorage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activePosterURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimFile.path))
    }

    func testCrossFeatureProtectionsBatteryAppRulesStackedSpacesAndPerDisplayLockScreen() async throws {
        let mb: Int64 = 1024 * 1024
        func stub(_ id: String) throws -> LibraryStorageHealthService.WallpaperRecord {
            let folder = libraryURL.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeFile(Data("x".utf8), at: "asset.bin", in: folder)
            return .init(id: id, title: id, kind: .video, cachedSizeBytes: 300 * mb, addedAt: nil)
        }

        let wallpapers = try [
            stub("battery-global"),
            stub("battery-display"),
            stub("app-rule-target"),
            stub("stacked-space"),
            stub("lock-per-display"),
            stub("saver-per-display"),
            stub("truly-unused"),
        ]

        // Stacked Spaces + Schedule SpacePoster MUST be preserved (usesSpaces == true even when mode == .schedule).
        let stackedPosterName = LibraryStorageHealthService.spacePosterFileName(
            display: "d1", wallpaperID: "stacked-space")
        try Data(repeating: 9, count: 1024).write(
            to: spacePostersURL.appendingPathComponent(stackedPosterName))

        let lockSources = LockScreenModeSources(
            allDisplays: .sameAsDesktop,
            usesPerDisplay: true,
            perDisplay: ["UUID-1": .wallpaper("lock-per-display")])
        let saverSources = LockScreenModeSources(
            allDisplays: .sameAsDesktop,
            usesPerDisplay: true,
            perDisplay: ["UUID-2": .wallpaper("saver-per-display")])

        let refs = LibraryStorageHealthService.ReferenceSnapshot(
            automations: [
                .init(
                    displayID: WallpaperAutomationStore.globalDisplayID,
                    displayTitle: "All displays",
                    mode: .off,
                    usesSpaces: false,
                    ruleWallpaperIDs: [],
                    lightWallpaperID: nil,
                    darkWallpaperID: nil,
                    batteryWallpaperID: "battery-global",
                    spaceWallpaperIDs: [:]),
                .init(
                    displayID: "d1",
                    displayTitle: "Main",
                    mode: .schedule,
                    usesSpaces: true,
                    ruleWallpaperIDs: [],
                    lightWallpaperID: nil,
                    darkWallpaperID: nil,
                    batteryWallpaperID: "battery-display",
                    spaceWallpaperIDs: ["space-1": "stacked-space"]),
            ],
            appRuleWallpaperIDs: ["app-rule-target"],
            lockScreenWallpaperIDs: lockSources.referencedWallpaperIDs,
            screenSaverWallpaperIDs: saverSources.referencedWallpaperIDs)

        let report = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: wallpapers, references: refs))

        XCTAssertEqual(report.unreferencedWallpapers.map(\.id), ["truly-unused"])
        XCTAssertTrue(
            report.orphanedStorage.isEmpty,
            "SpacePoster for a stacked Spaces + Schedule display must not be flagged as orphaned")
    }

    func testStackedSpacesRetainsAppearanceAndEnabledSchedulePostersOnly() async throws {
        let mb: Int64 = 1024 * 1024
        func stub(_ id: String) throws -> LibraryStorageHealthService.WallpaperRecord {
            let folder = libraryURL.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeFile(Data("x".utf8), at: "asset.bin", in: folder)
            return .init(id: id, title: id, kind: .video, cachedSizeBytes: 10 * mb, addedAt: nil)
        }

        let wallpapers = try [
            stub("light-wp"),
            stub("dark-wp"),
            stub("sched-enabled"),
            stub("sched-disabled"),
            stub("nonstacked-sched"),
        ]

        func writePoster(display: String, id: String) throws -> String {
            let name = LibraryStorageHealthService.spacePosterFileName(display: display, wallpaperID: id)
            try Data(repeating: 7, count: 512).write(to: spacePostersURL.appendingPathComponent(name))
            return name
        }

        _ = try writePoster(display: "d-app", id: "light-wp")
        _ = try writePoster(display: "d-app", id: "dark-wp")
        _ = try writePoster(display: "d-sched", id: "sched-enabled")
        let disabledPoster = try writePoster(display: "d-sched", id: "sched-disabled")
        let nonStackedPoster = try writePoster(display: "d-plain", id: "nonstacked-sched")

        let refs = LibraryStorageHealthService.ReferenceSnapshot(
            automations: [
                .init(
                    displayID: "d-app", displayTitle: "Appearance Display",
                    mode: .appearance, usesSpaces: true,
                    ruleWallpaperIDs: [],
                    lightWallpaperID: "light-wp", darkWallpaperID: "dark-wp",
                    spaceWallpaperIDs: [:]),
                .init(
                    displayID: "d-sched", displayTitle: "Schedule Display",
                    mode: .schedule, usesSpaces: true,
                    ruleWallpaperIDs: ["sched-enabled", "sched-disabled"],
                    enabledRuleWallpaperIDs: ["sched-enabled"],
                    lightWallpaperID: nil, darkWallpaperID: nil,
                    spaceWallpaperIDs: [:]),
                .init(
                    displayID: "d-plain", displayTitle: "Non-Spaces Schedule Display",
                    mode: .schedule, usesSpaces: false,
                    ruleWallpaperIDs: ["nonstacked-sched"],
                    enabledRuleWallpaperIDs: ["nonstacked-sched"],
                    lightWallpaperID: nil, darkWallpaperID: nil,
                    spaceWallpaperIDs: [:]),
            ])

        let report = try await service.scan(
            input: .init(
                libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
                spacePosterCacheURL: spacePostersURL, now: referenceDate,
                wallpapers: wallpapers, references: refs))

        XCTAssertEqual(
            Set(report.orphanedStorage.map(\.name)),
            [disabledPoster, nonStackedPoster],
            "Active stacked appearance and enabled schedule SpacePosters must be retained; disabled/non-stacked posters are orphans")
    }

    // MARK: - Display layout pruning

    @MainActor
    func testDisplayLayoutStorePruneWallpapersKeepsValidAssignmentsAndPreservesAutoApplyInvariant() throws {
        let (defaults, _) = TemporaryDefaults.makeForCurrentTest()
        let store = WallpaperDisplayLayoutStore(defaults: defaults)
        let keepAuto = try store.save(
            name: "Single",
            assignments: [.init(displayID: "d1", displayTitle: "Main", wallpaperID: "valid")],
            autoApplyOnConnect: true)
        let partial = try store.save(
            name: "Dual",
            assignments: [
                .init(displayID: "d1", displayTitle: "Main", wallpaperID: "valid"),
                .init(displayID: "d2", displayTitle: "Side", wallpaperID: "gone"),
            ],
            autoApplyOnConnect: true)
        _ = try store.save(
            name: "All Gone",
            assignments: [.init(displayID: "d3", displayTitle: "Old", wallpaperID: "gone")],
            autoApplyOnConnect: false)

        let removed = try store.pruneWallpapers(["gone"])
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.layouts.count, 2)

        let keptSingle = try store.layout(keepAuto.id)
        let prunedDual = try store.layout(partial.id)
        XCTAssertEqual(prunedDual.assignments.map(\.wallpaperID), ["valid"])
        XCTAssertTrue(keptSingle.autoApplyOnConnect)
        XCTAssertFalse(
            prunedDual.autoApplyOnConnect,
            "pruning down to a topology that already has an auto-apply layout preserves the single-auto-apply invariant")
    }

    // MARK: - Cancellation

    func testScanCancelsCleanly() async throws {
        var wallpapers: [LibraryStorageHealthService.WallpaperRecord] = []
        let payload = makePayload(byteCount: 8192, fill: 0xAA)
        for idx in 0..<4 {
            wallpapers.append(
                try makeVideoWallpaper(id: "c-\(idx)", title: "Item \(idx)", fileName: "v.mp4", content: payload))
        }
        let input = LibraryStorageHealthService.Input(
            libraryURL: libraryURL, sceneStorageURL: sceneStorageURL,
            spacePosterCacheURL: spacePostersURL, now: referenceDate, wallpapers: wallpapers)

        let task = Task { try await self.service.scan(input: input) }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected cancellation path.
        }
    }
}
