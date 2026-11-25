import XCTest

@testable import WallpaperMachine

/// Verifies persisted post-download/post-import compatibility pre-check caching, invalidation on
/// app version / shared assets / project fingerprint / video stamp changes, and background queue
/// scheduling.
final class WallpaperCompatibilityCacheTests: XCTestCase {
    private var root: URL!
    private var cacheFile: URL { root.appendingPathComponent("Cache/CompatibilityCache.json") }
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var assets: URL { root.appendingPathComponent("SceneAssets", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try installSharedAssets(markerContent: "v1")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installSharedAssets(markerContent: String) throws {
        for relative in [
            "shaders/genericimage2.vert",
            "shaders/genericimage2.frag",
            "materials/util/effectpassthrough.json",
        ] {
            let url = assets.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(markerContent.utf8).write(to: url)
        }
    }

    private func installVideo(id: String, body: String = "video-bytes-v1") throws {
        let dir = library.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"video","title":"Clip","file":"clip.mp4"}"#.utf8)
            .write(to: dir.appendingPathComponent("project.json"))
        try Data(body.utf8).write(to: dir.appendingPathComponent("clip.mp4"))
    }

    private func installScene(id: String, sceneBody: String = "{}") throws {
        let dir = library.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","title":"Scene","file":"scene.json"}"#.utf8)
            .write(to: dir.appendingPathComponent("project.json"))
        try Data(sceneBody.utf8).write(to: dir.appendingPathComponent("scene.json"))
    }

    private func makeCache(
        appVersion: String = "1.0 (1)",
        probeResult: NativeVideoProbeOutcome = .probed(NativeVideoTrackProbe(isPlayable: true, hasVideoTrack: true))
    ) -> WallpaperCompatibilityCache {
        let library = self.library
        let assets = self.assets
        let service = WallpaperCompatibilityService(
            libraryURL: library,
            assetsURL: { assets },
            probe: { _ in probeResult }
        )
        return WallpaperCompatibilityCache(
            file: cacheFile,
            library: { library },
            assetsURL: { assets },
            appVersion: { appVersion },
            service: service
        )
    }

    func testPersistsAndInvalidatesOnAppVersionAndVideoFileChange() async throws {
        try installVideo(id: "vid-1", body: "frame-data-v1")
        let cache = makeCache(appVersion: "1.0 (1)")
        let first = await cache.precheck(wallpaperID: "vid-1", kind: .video, supported: true)
        XCTAssertEqual(first?.status, .ok)

        // Persisted hit survives reopen under the same app version and file stamp.
        let reopened = makeCache(appVersion: "1.0 (1)")
        let hit = await reopened.cachedSummary(for: "vid-1", kind: .video)
        XCTAssertEqual(hit?.status, .ok)

        // App version change invalidates the cached entry.
        let newerBuild = makeCache(appVersion: "1.1 (2)")
        let afterUpdate = await newerBuild.cachedSummary(for: "vid-1", kind: .video)
        XCTAssertNil(afterUpdate, "an app version bump must invalidate cached compatibility verdicts")

        // Re-populate under 1.0 (1), then mutate video file -> VideoFileStamp + fingerprint invalidate it.
        _ = await reopened.precheck(wallpaperID: "vid-1", kind: .video, supported: true)
        try installVideo(id: "vid-1", body: "replaced-longer-video-bytes-v2")
        let afterReplace = await reopened.cachedSummary(for: "vid-1", kind: .video)
        XCTAssertNil(afterReplace, "replacing the video file must invalidate the cached verdict")
    }

    func testInvalidatesSceneVerdictWhenSharedAssetsOrProjectChange() async throws {
        try installScene(id: "scene-1", sceneBody: #"{"v":1}"#)
        let cache = makeCache()
        let summary = await cache.precheck(wallpaperID: "scene-1", kind: .scene, supported: true)
        XCTAssertNotNil(summary)

        // Changing a shared asset marker invalidates the scene entry.
        try installSharedAssets(markerContent: "updated-shared-assets-v2")
        let afterAssets = await cache.cachedSummary(for: "scene-1", kind: .scene)
        XCTAssertNil(afterAssets, "shared scene assets changes must invalidate cached scene verdicts")

        // Re-cache, then change scene project contents -> invalidated.
        _ = await cache.precheck(wallpaperID: "scene-1", kind: .scene, supported: true)
        try installScene(id: "scene-1", sceneBody: #"{"v":2,"extra":true}"#)
        let afterProject = await cache.cachedSummary(for: "scene-1", kind: .scene)
        XCTAssertNil(afterProject, "project file edits must invalidate the cached verdict")
    }

    @MainActor
    func testBackgroundStoreSchedulesPrecheckAndPopulatesInMemorySummaries() async throws {
        try installVideo(id: "bad-codec", body: "vp9-ish")
        let cache = makeCache(
            probeResult: .refused(.unsupportedFormat("AV1 video is not supported on this Mac."))
        )
        let store = WallpaperCompatibilityCacheStore(cache: cache)
        let entry = BridgeWallpaperEntry(
            id: "bad-codec",
            title: "Bad Codec",
            kind: .video,
            supported: true,
            active: false,
            selected: false,
            previewPath: nil
        )

        store.schedulePrecheck(wallpaperIDs: ["bad-codec"], entries: [entry], libraryRevision: 1)
        await store.drainForTests()

        let badge = try XCTUnwrap(store.summaries["bad-codec"])
        XCTAssertEqual(badge.status, .warning)
        XCTAssertTrue(badge.detail.contains("AV1"))
    }
}
