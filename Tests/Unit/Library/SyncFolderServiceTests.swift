import Darwin
import Foundation
import XCTest

@testable import WallpaperMachine

final class SyncFolderServiceTests: XCTestCase {
  private var root: URL!
  private var home: URL!
  private var support: URL!
  private var syncDir: URL!
  private var previousHome: String?
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    defaults = try TemporaryDefaults.make(for: self).defaults
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sync-folder-tests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("Home", isDirectory: true)
    support = home.appendingPathComponent("Library/Application Support/WallpaperMachine", isDirectory: true)
    syncDir = root.appendingPathComponent("SyncFolder", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
  }

  override func tearDownWithError() throws {
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
    try? FileManager.default.removeItem(at: root)
  }

  private func service(
    limits: SyncFolderLimits = .init(),
    cloudStateInspector: @escaping @Sendable (URL) -> SyncFolderService.CloudFileState = {
      SyncFolderService.defaultCloudState(at: $0)
    }
  ) -> SyncFolderService {
    SyncFolderService(
      supportRoot: support,
      storageRoot: support,
      limits: limits,
      cloudStateInspector: cloudStateInspector
    )
  }

  // MARK: - Local Binding Isolation

  func testSyncFolderBindingIsLocalOnlyAndExcludedFromBackupPreferencesAllowlist() throws {
    let binding = SyncFolderBindingStore.save(folderURL: syncDir, in: defaults)
    XCTAssertEqual(binding.folderPath, syncDir.standardizedFileURL.resolvingSymlinksInPath().path)
    XCTAssertNil(binding.lastPushAt)
    XCTAssertNil(binding.lastPullAt)

    let pushDate = Date(timeIntervalSince1970: 1_800_000_100)
    let pullDate = Date(timeIntervalSince1970: 1_800_000_200)
    SyncFolderBindingStore.recordPush(at: pushDate, in: defaults)
    SyncFolderBindingStore.recordPull(at: pullDate, in: defaults)

    let reloaded = try XCTUnwrap(SyncFolderBindingStore.load(from: defaults))
    XCTAssertEqual(reloaded.folderPath, binding.folderPath)
    XCTAssertEqual(reloaded.lastPushAt?.timeIntervalSince1970 ?? 0, pushDate.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertEqual(reloaded.lastPullAt?.timeIntervalSince1970 ?? 0, pullDate.timeIntervalSince1970, accuracy: 0.001)

    // Sync folder binding keys must NEVER appear in `.wmbackup` preferences allowlist.
    XCTAssertFalse(WallpaperBackupPreferences.allowedKeys.contains(SyncFolderBindingStore.folderPathKey))
    XCTAssertFalse(WallpaperBackupPreferences.allowedKeys.contains(SyncFolderBindingStore.folderBookmarkKey))
    XCTAssertFalse(WallpaperBackupPreferences.allowedKeys.contains(SyncFolderBindingStore.lastPushAtKey))
    XCTAssertFalse(WallpaperBackupPreferences.allowedKeys.contains(SyncFolderBindingStore.lastPullAtKey))

    SyncFolderBindingStore.clear(in: defaults)
    XCTAssertNil(SyncFolderBindingStore.load(from: defaults))
  }

  // MARK: - Atomic Push & Hard Security Exclusions

  func testAtomicPushExcludesSecretsShortcutsSpaceUUIDsLocalPathsAndReplacesCleanly() throws {
    let sync = service()
    let secretSpaceUUID = "SPACE-UUID-PRIVATE-9999"
    let hardwareUUID = "HW-UUID-PRIVATE-4321"
    let shortcutPreset = WallpaperPropertyPreset(
      id: UUID().uuidString,
      wallpaperID: "2841234567",
      name: "Midnight Neon",
      properties: [
        WallpaperPresetProperty(
          id: "speed", kind: "slider", value: .number(1.25), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "custom_image", kind: "file",
          value: .string("/Users/alice/Pictures/private-photo.png"), usesDefault: false,
          retainedPath: "/Users/alice/Library/Application Support/WallpaperMachine/UserAssets/PresetAssets/abc/custom_image/private.png"),
        WallpaperPresetProperty(
          id: "custom_tex", kind: "texture",
          value: .string("/Users/alice/Desktop/secret.tex"), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "launch_app", kind: "combo",
          value: .string("app:com.apple.Terminal"), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "run_shortcut", kind: "combo",
          value: .string("shortcut:Dangerous Automation"), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "builtin_media", kind: "combo",
          value: .string("media:playpause"), usesDefault: false, retainedPath: nil),
      ]
    )

    var spaceWidget = DesktopWidget(id: UUID().uuidString, kind: .time)
    spaceWidget.scope = .spaces([secretSpaceUUID, "SPACE-UUID-PRIVATE-8888"])
    spaceWidget.placement = .display(uuid: hardwareUUID, name: "Studio Display")

    var stickerWidget = DesktopWidget(id: UUID().uuidString, kind: .image)
    stickerWidget.imageAsset = DesktopWidget.ImageAsset(
      assetID: "asset-1", fileName: "sticker.png", displayName: "Sticker")

    let layout = WallpaperDisplayLayout(
      id: UUID().uuidString,
      name: "Work Desk",
      assignments: [
        WallpaperDisplayAssignment(
          displayID: "primary", displayTitle: "Studio Display (1 - Primary)", wallpaperID: "2841234567")
      ],
      autoApplyOnConnect: true
    )

    var smartPlaylist = DisplayPlaylist()
    smartPlaylist.mode = .rotate
    smartPlaylist.source = .smart
    smartPlaylist.interval = 45
    smartPlaylist.smartQuery = SmartPlaylistQuery(
      requiredTags: ["Cyberpunk"],
      excludedTags: ["Bright"],
      types: [.scene, .video],
      minimumRating: 4,
      maximumEnergy: .medium,
      favoritesOnly: true,
      excludeMature: true
    )
    let savedPlan = PlaylistPlan(id: "plan-smart-1", name: "Night Chill", playlist: smartPlaylist)

    let state = SyncFolderLocalState(
      deviceName: "Alice’s MacBook Pro",
      appVersion: "2.3.0",
      displays: [
        SetupPackTargetDisplay(
          displayID: "primary", displayUUID: hardwareUUID, title: "Studio Display (1 - Primary)",
          isPrimary: true, width: 2560, height: 1440)
      ],
      libraryTitles: ["2841234567": "Cyberpunk Rain", "pixiv-9988": "Illust"],
      favorites: ["2841234567"],
      collections: [WallpaperCollection(id: "col-1", name: "Favorites Pack", wallpaperIDs: ["2841234567"])],
      metadata: [
        "2841234567": WallpaperMetadata(
          customTags: ["Cyberpunk", "Rain"], rating: 5, note: "Great at night", excludedFromRotation: false)
      ],
      playlists: [savedPlan],
      presets: [shortcutPreset],
      widgets: [spaceWidget, stickerWidget],
      layouts: [layout],
      videoTrims: ["2841234567": try VideoTrimRange(startSeconds: 1.5, endSeconds: 12.0)],
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let report = try sync.push(to: syncDir, state: state)
    let snapshotURL = syncDir.appendingPathComponent(SyncFolderService.snapshotFileName)
    XCTAssertEqual(report.snapshotURL.path, snapshotURL.standardizedFileURL.resolvingSymlinksInPath().path)

    // No temp files left behind after atomic write.
    let contents = try FileManager.default.contentsOfDirectory(atPath: syncDir.path)
    XCTAssertEqual(contents, [SyncFolderService.snapshotFileName])

    let rawBytes = try Data(contentsOf: snapshotURL)
    let rawText = try XCTUnwrap(String(data: rawBytes, encoding: .utf8))

    // Zero Space UUIDs, zero hardware UUIDs, zero local user paths, zero app:/shortcut: bindings,
    // zero media/sticker references, zero retainedPath, zero local folder binding keys.
    XCTAssertFalse(rawText.contains(secretSpaceUUID))
    XCTAssertFalse(rawText.contains("SPACE-UUID-PRIVATE"))
    XCTAssertFalse(rawText.contains(hardwareUUID))
    XCTAssertFalse(rawText.contains("/Users/alice"))
    XCTAssertFalse(rawText.contains("retainedPath"))
    XCTAssertFalse(rawText.contains("app:com.apple.Terminal"))
    XCTAssertFalse(rawText.contains("shortcut:Dangerous Automation"))
    XCTAssertFalse(rawText.contains("sticker.png"))
    XCTAssertFalse(rawText.contains("syncFolderPath"))
    XCTAssertFalse(rawText.contains("approvedUserShortcuts"))
    XCTAssertTrue(rawText.contains("media:playpause"))

    XCTAssertEqual(report.workshopItemCount, 1)
    XCTAssertEqual(report.sanitization.downgradedSpaceWidgets, 1)
    XCTAssertEqual(report.sanitization.omittedImageWidgets, 1)
    XCTAssertGreaterThanOrEqual(report.sanitization.strippedPresetPaths, 2)
    XCTAssertEqual(report.sanitization.strippedUserShortcutBindings, 2)
    XCTAssertFalse(report.notes.isEmpty)

    // Second push atomically replaces the existing snapshot cleanly with no leftover temp files.
    var secondState = state
    secondState.favorites = ["2841234567", "3000000001"]
    secondState.now = Date(timeIntervalSince1970: 1_800_001_000)
    let secondReport = try sync.push(to: syncDir, state: secondState)
    XCTAssertNotEqual(secondReport.digest, report.digest)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: syncDir.path), [SyncFolderService.snapshotFileName])

    // Refuses pushing inside WallpaperMachine support folder or onto a symlink destination.
    XCTAssertThrowsError(try sync.push(to: support, state: state))
    let symlinkDir = root.appendingPathComponent("SymlinkSync", isDirectory: true)
    try FileManager.default.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
    let outsideTarget = root.appendingPathComponent("outside.json")
    try Data("keep".utf8).write(to: outsideTarget)
    try FileManager.default.createSymbolicLink(
      at: symlinkDir.appendingPathComponent(SyncFolderService.snapshotFileName),
      withDestinationURL: outsideTarget)
    XCTAssertThrowsError(try sync.push(to: symlinkDir, state: state))
    XCTAssertEqual(try String(contentsOf: outsideTarget, encoding: .utf8), "keep")
  }

  // MARK: - Strict Validation & Hygiene

  func testStrictValidationRejectsSymlinksOversizedDeepNodesBadSchemaAndInvalidFieldValues() throws {
    let sync = service()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    // 1. Empty & oversized payload
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data()))
    let tinyService = service(limits: SyncFolderLimits(maximumFileBytes: 128))
    XCTAssertThrowsError(try tinyService.parseAndValidate(data: Data(repeating: 0x20, count: 256)))

    // 2. Malformed UTF-8 & NUL byte
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data([0x7B, 0xFF, 0xFE, 0x7D])))
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data("{\"format\":\"a\0b\"}".utf8)))

    // 3. Excessively deep JSON rejected linearly before recursion
    let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data(deep.utf8)))

    // 4. Excessive node count rejected
    let lowNodeService = service(limits: SyncFolderLimits(maximumJSONNodes: 10))
    let manyFavorites = SyncFolderSnapshot(favorites: (1...30).map { "1000\($0)" })
    XCTAssertThrowsError(try lowNodeService.parseAndValidate(data: try encoder.encode(manyFavorites)))

    // 5. Symlink rejected via O_NOFOLLOW on previewPull
    let realSnapshot = root.appendingPathComponent("real-sync.json")
    try encoder.encode(SyncFolderSnapshot()).write(to: realSnapshot)
    let symlinkFolder = root.appendingPathComponent("SymlinkPull", isDirectory: true)
    try FileManager.default.createDirectory(at: symlinkFolder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: symlinkFolder.appendingPathComponent(SyncFolderService.snapshotFileName),
      withDestinationURL: realSnapshot)
    XCTAssertThrowsError(
      try sync.previewPull(from: symlinkFolder, localState: SyncFolderLocalState()))

    // 6. Directory pretending to be WallpaperMachineSync.json rejected (S_IFREG check)
    let dirFileFolder = root.appendingPathComponent("DirAsFile", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dirFileFolder.appendingPathComponent(SyncFolderService.snapshotFileName),
      withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try sync.previewPull(from: dirFileFolder, localState: SyncFolderLocalState()))

    // 7. Unknown top-level key rejected (e.g. credential or shortcut injection)
    let unknownKeyJSON = """
    {
      "format": "app.wallpapermachine.sync-snapshot",
      "schemaVersion": 1,
      "exportedAt": "2026-11-26T00:00:00Z",
      "deviceName": "Mac",
      "appVersion": "2.3.0",
      "displays": [],
      "workshopItems": [],
      "favorites": [],
      "collections": [],
      "metadata": {},
      "playlists": [],
      "presets": [],
      "widgets": [],
      "layouts": [],
      "videoTrims": {},
      "approvedUserShortcuts": {"x": "app:com.apple.Terminal"}
    }
    """
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data(unknownKeyJSON.utf8)))

    // 8. Unsupported schemaVersion rejected
    let badVersionJSON = """
    {
      "format": "app.wallpapermachine.sync-snapshot",
      "schemaVersion": 2,
      "exportedAt": "2026-11-26T00:00:00Z",
      "deviceName": "Mac",
      "appVersion": "2.3.0",
      "displays": [],
      "workshopItems": [],
      "favorites": [],
      "collections": [],
      "metadata": {},
      "playlists": [],
      "presets": [],
      "widgets": [],
      "layouts": [],
      "videoTrims": {}
    }
    """
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data(badVersionJSON.utf8)))

    // 9. Non-numeric / traversal Workshop IDs rejected in workshopItems
    for badID in ["", "0", "00123", "-7", "abc", "../etc/passwd", "123/456", "https://example.com"] {
      let badDoc = SyncFolderSnapshot(workshopItems: [SetupPackWorkshopItem(id: badID)])
      XCTAssertThrowsError(
        try sync.parseAndValidate(data: try encoder.encode(badDoc)),
        "Expected rejection for Workshop ID \(badID)")
    }

    // 10. Out-of-range metadata rating (0 and 6) rejected instead of silently clamped
    for badRating in ["0", "6", "3.5", "true"] {
      let json = """
      {
        "format": "app.wallpapermachine.sync-snapshot",
        "schemaVersion": 1,
        "exportedAt": "2026-11-26T00:00:00Z",
        "deviceName": "Mac",
        "appVersion": "2.3.0",
        "displays": [],
        "workshopItems": [],
        "favorites": [],
        "collections": [],
        "metadata": {"12345": {"customTags": [], "rating": \(badRating), "excludedFromRotation": false}},
        "playlists": [],
        "presets": [],
        "widgets": [],
        "layouts": [],
        "videoTrims": {}
      }
      """
      XCTAssertThrowsError(
        try sync.parseAndValidate(data: Data(json.utf8)),
        "Expected rejection for rating \(badRating)")
    }

    // 11. Invalid video trim ranges (< 0.5s, negative start, reversed) rejected
    for badTrim in [
      "{\"startSeconds\": -1.0, \"endSeconds\": 5.0}",
      "{\"startSeconds\": 5.0, \"endSeconds\": 5.2}",
      "{\"startSeconds\": 8.0, \"endSeconds\": 4.0}",
    ] {
      let json = """
      {
        "format": "app.wallpapermachine.sync-snapshot",
        "schemaVersion": 1,
        "exportedAt": "2026-11-26T00:00:00Z",
        "deviceName": "Mac",
        "appVersion": "2.3.0",
        "displays": [],
        "workshopItems": [],
        "favorites": [],
        "collections": [],
        "metadata": {},
        "playlists": [],
        "presets": [],
        "widgets": [],
        "layouts": [],
        "videoTrims": {"12345": \(badTrim)}
      }
      """
      XCTAssertThrowsError(
        try sync.parseAndValidate(data: Data(json.utf8)),
        "Expected rejection for video trim \(badTrim)")
    }

    // 12. Preset smuggling app:/shortcut: binding or local file path rejected
    let shortcutPreset = WallpaperPresetDocument(
      preset: WallpaperPropertyPreset(
        id: UUID().uuidString,
        wallpaperID: "12345",
        name: "Smuggled Shortcut",
        properties: [
          WallpaperPresetProperty(
            id: "btn", kind: "combo", value: .string("app:com.apple.Terminal"),
            usesDefault: false, retainedPath: nil)
        ]
      )
    )
    XCTAssertThrowsError(
      try sync.parseAndValidate(data: try encoder.encode(SyncFolderSnapshot(presets: [shortcutPreset]))))

    let shortcutPreset2 = WallpaperPresetDocument(
      preset: WallpaperPropertyPreset(
        id: UUID().uuidString,
        wallpaperID: "12345",
        name: "Smuggled Apple Shortcut",
        properties: [
          WallpaperPresetProperty(
            id: "btn", kind: "combo", value: .string("shortcut:Wipe Disk"),
            usesDefault: false, retainedPath: nil)
        ]
      )
    )
    XCTAssertThrowsError(
      try sync.parseAndValidate(data: try encoder.encode(SyncFolderSnapshot(presets: [shortcutPreset2]))))

    // 13. Invalid widget (out-of-range size & image widget) rejected; crafted Space widget downgraded
    var oversizedWidget = DesktopWidget(id: UUID().uuidString, kind: .time)
    oversizedWidget.size = 9999
    XCTAssertThrowsError(
      try sync.parseAndValidate(data: try encoder.encode(SyncFolderSnapshot(widgets: [oversizedWidget]))))

    let imageWidget = DesktopWidget(id: UUID().uuidString, kind: .image)
    XCTAssertThrowsError(
      try sync.parseAndValidate(data: try encoder.encode(SyncFolderSnapshot(widgets: [imageWidget]))))

    var foreignSpaceWidget = DesktopWidget(id: UUID().uuidString, kind: .date)
    foreignSpaceWidget.scope = .spaces(["FOREIGN-SPACE-UUID"])
    let (sanitized, warnings) = try sync.parseAndValidate(
      data: try encoder.encode(SyncFolderSnapshot(widgets: [foreignSpaceWidget])))
    XCTAssertEqual(sanitized.widgets.first?.scope, .everywhere)
    XCTAssertFalse(warnings.isEmpty)
  }

  // MARK: - iCloud Evicted Placeholder Detection

  func testICloudPlaceholderDetectionCatchesBothDotICloudStubAndEvictedStatus() throws {
    let sync = service()

    // 1. Classic `.WallpaperMachineSync.json.icloud` stub beside missing materialized file.
    let stubURL = syncDir.appendingPathComponent(".\(SyncFolderService.snapshotFileName).icloud")
    try Data("bplist00".utf8).write(to: stubURL)

    XCTAssertEqual(sync.inspectFolderSummary(at: syncDir), .iCloudNotDownloaded)
    XCTAssertThrowsError(
      try sync.previewPull(from: syncDir, localState: SyncFolderLocalState())
    ) { error in
      XCTAssertEqual(
        error as? SyncFolderFailure,
        .iCloudFileNotDownloaded(fileName: SyncFolderService.snapshotFileName))
    }

    // 2. FileProvider dataless placeholder (`ubiquitousItemDownloadingStatus == .notDownloaded`)
    // even when a materialized path entry exists on disk.
    try FileManager.default.removeItem(at: stubURL)
    let materialized = syncDir.appendingPathComponent(SyncFolderService.snapshotFileName)
    try Data("unreadable-placeholder".utf8).write(to: materialized)

    let datalessService = service(cloudStateInspector: { _ in .iCloudNotDownloaded })
    XCTAssertEqual(datalessService.inspectFolderSummary(at: syncDir), .iCloudNotDownloaded)
    XCTAssertThrowsError(
      try datalessService.previewPull(from: syncDir, localState: SyncFolderLocalState())
    ) { error in
      XCTAssertEqual(
        error as? SyncFolderFailure,
        .iCloudFileNotDownloaded(fileName: SyncFolderService.snapshotFileName))
    }
  }

  // MARK: - Diff & Conflict Preview, Merge vs Replace, Display Remapping

  func testDiffCountsMergeVsReplaceAndDisplayRemappingWithSkipAndAutoApplySafety() throws {
    let sync = service()

    // Source Mac snapshot
    let sourceDisplays = [
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "SRC-MAIN", title: "MacBook Pro (1 - Primary)",
        isPrimary: true, width: 1728, height: 1117),
      SetupPackTargetDisplay(
        displayID: "2", displayUUID: "SRC-EXT", title: "Studio Display (2 - Secondary)",
        isPrimary: false, width: 2560, height: 1440),
    ]
    var incomingSmart = DisplayPlaylist()
    incomingSmart.mode = .rotate
    incomingSmart.source = .smart
    incomingSmart.smartQuery = SmartPlaylistQuery(requiredTags: ["Space"], minimumRating: 4)
    var conflictingPlanPlaylist = DisplayPlaylist()
    conflictingPlanPlaylist.mode = .rotate
    conflictingPlanPlaylist.interval = 120

    var pinnedWidget = DesktopWidget(id: "widget-ext", kind: .time)
    pinnedWidget.placement = .display(uuid: "SRC-EXT", name: "Studio Display")

    let sourceState = SyncFolderLocalState(
      deviceName: "Mac Studio",
      appVersion: "2.3.0",
      displays: sourceDisplays,
      libraryTitles: ["1001": "Nebula", "2002": "Ocean", "3003": "Forest"],
      favorites: ["1001", "2002"],
      collections: [
        WallpaperCollection(id: "col-shared", name: "Chill", wallpaperIDs: ["1001", "2002"]),
        WallpaperCollection(id: "col-new", name: "Sci-Fi", wallpaperIDs: ["3003"]),
      ],
      metadata: [
        "1001": WallpaperMetadata(customTags: ["Neon", "Calm"], rating: 3, note: "Remote note", excludedFromRotation: true),
        "2002": WallpaperMetadata(customTags: ["Ocean"], rating: 5, note: "New remote", excludedFromRotation: false),
      ],
      playlists: [
        PlaylistPlan(id: "plan-conflict", name: "Daily", playlist: conflictingPlanPlaylist),
        PlaylistPlan(id: "plan-smart", name: "Space 4+", playlist: incomingSmart),
      ],
      presets: [
        WallpaperPropertyPreset(
          id: UUID().uuidString, wallpaperID: "1001", name: "Warm",
          properties: [WallpaperPresetProperty(id: "speed", kind: "slider", value: .number(2.0), usesDefault: false, retainedPath: nil)]),
        WallpaperPropertyPreset(
          id: UUID().uuidString, wallpaperID: "2002", name: "Cool",
          properties: [WallpaperPresetProperty(id: "speed", kind: "slider", value: .number(0.5), usesDefault: false, retainedPath: nil)]),
      ],
      widgets: [pinnedWidget],
      layouts: [
        WallpaperDisplayLayout(
          id: "layout-desk", name: "Dual Desk",
          assignments: [
            WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "1001"),
            WallpaperDisplayAssignment(displayID: "2", displayTitle: "Studio", wallpaperID: "2002"),
          ],
          autoApplyOnConnect: true)
      ],
      videoTrims: [
        "1001": try VideoTrimRange(startSeconds: 2.0, endSeconds: 10.0),
        "2002": try VideoTrimRange(startSeconds: 0.5, endSeconds: 6.0),
      ]
    )
    _ = try sync.push(to: syncDir, state: sourceState)

    // Recipient Mac local state
    let recipientDisplays = [
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "DST-MAIN", title: "MacBook Air (1 - Primary)",
        isPrimary: true, width: 1512, height: 982),
      SetupPackTargetDisplay(
        displayID: "7", displayUUID: "DST-EXT", title: "Pro Display (7 - Secondary)",
        isPrimary: false, width: 2560, height: 1440),
    ]
    var localPlanPlaylist = DisplayPlaylist()
    localPlanPlaylist.mode = .rotate
    localPlanPlaylist.interval = 15

    let localState = SyncFolderLocalState(
      deviceName: "MacBook Air",
      appVersion: "2.3.0",
      displays: recipientDisplays,
      libraryTitles: ["1001": "Nebula"],
      favorites: ["1001", "9999"],
      collections: [
        WallpaperCollection(id: "local-col-1", name: "Chill", wallpaperIDs: ["1001"]),
        WallpaperCollection(id: "local-col-only", name: "Local Only", wallpaperIDs: ["9999"]),
      ],
      metadata: [
        "1001": WallpaperMetadata(customTags: ["Calm"], rating: 5, note: "Local note", excludedFromRotation: false),
        "9999": WallpaperMetadata(customTags: ["Local"], rating: 4, note: nil, excludedFromRotation: false),
      ],
      playlists: [
        PlaylistPlan(id: "local-plan-1", name: "Daily", playlist: localPlanPlaylist)
      ],
      presets: [
        WallpaperPropertyPreset(
          id: UUID().uuidString, wallpaperID: "1001", name: "Warm",
          properties: [WallpaperPresetProperty(id: "speed", kind: "slider", value: .number(1.0), usesDefault: false, retainedPath: nil)])
      ],
      widgets: [],
      layouts: [
        WallpaperDisplayLayout(
          id: "local-auto", name: "My Auto Layout",
          assignments: [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "1001")],
          autoApplyOnConnect: true)
      ],
      videoTrims: [
        "1001": try VideoTrimRange(startSeconds: 0.0, endSeconds: 4.0)
      ]
    )

    let preview = try sync.previewPull(from: syncDir, localState: localState)
    XCTAssertEqual(preview.snapshot.deviceName, "Mac Studio")
    XCTAssertEqual(preview.installedWorkshopItems.map(\.id), ["1001"])
    XCTAssertEqual(Set(preview.missingWorkshopItems.map(\.id)), Set(["2002", "3003"]))
    XCTAssertEqual(preview.suggestedDisplayMapping["display-1"], "primary")
    XCTAssertEqual(preview.suggestedDisplayMapping["display-2"], "7")

    // Verify per-category diff counts
    XCTAssertEqual(preview.diff(for: .favorites).addedCount, 1) // 2002
    XCTAssertEqual(preview.diff(for: .favorites).localOnlyCount, 1) // 9999
    XCTAssertEqual(preview.diff(for: .collections).addedCount, 1) // Sci-Fi
    XCTAssertEqual(preview.diff(for: .collections).updatedCount, 1) // Chill gains 2002
    XCTAssertEqual(preview.diff(for: .metadata).addedCount, 1) // 2002
    XCTAssertEqual(preview.diff(for: .metadata).conflictingCount, 1) // 1001 rating/note/exclusion conflict
    XCTAssertEqual(preview.diff(for: .playlists).addedCount, 1) // Space 4+
    XCTAssertEqual(preview.diff(for: .playlists).conflictingCount, 1) // Daily
    XCTAssertEqual(preview.diff(for: .presets).addedCount, 1) // Cool
    XCTAssertEqual(preview.diff(for: .presets).conflictingCount, 1) // Warm
    XCTAssertEqual(preview.diff(for: .widgets).addedCount, 1)
    XCTAssertEqual(preview.diff(for: .layouts).addedCount, 1)
    XCTAssertEqual(preview.diff(for: .videoTrims).addedCount, 1) // 2002
    XCTAssertEqual(preview.diff(for: .videoTrims).conflictingCount, 1) // 1001

    // Merge plan keeps local values on conflicts & skips display-2 when explicitly mapped to nil.
    let mergePlan = try sync.preparePullPlan(
      preview: preview,
      options: SyncFolderPullOptions(
        selectedCategories: Set(SyncFolderCategory.allCases),
        conflictStrategy: .merge,
        displayMapping: ["display-1": "primary", "display-2": nil],
        queueMissingDownloadsConfirmed: false
      ),
      localState: localState
    )
    XCTAssertEqual(mergePlan.favorites, Set(["1001", "2002", "9999"]))
    XCTAssertEqual(mergePlan.collections?.collectionsToCreate.map(\.name), ["Sci-Fi"])
    XCTAssertEqual(mergePlan.collections?.collectionsToUpdate.first?.addedWallpaperIDs, ["2002"])
    // Metadata merge unions tags, keeps local rating=5, note="Local note", excluded=false.
    XCTAssertEqual(mergePlan.metadata?.entriesToWrite["1001"]?.rating, 5)
    XCTAssertEqual(mergePlan.metadata?.entriesToWrite["1001"]?.note, "Local note")
    XCTAssertEqual(mergePlan.metadata?.entriesToWrite["1001"]?.excludedFromRotation, false)
    XCTAssertEqual(Set(mergePlan.metadata?.entriesToWrite["1001"]?.customTags ?? []), Set(["Calm", "Neon"]))
    XCTAssertEqual(mergePlan.metadata?.entriesToWrite["2002"]?.rating, 5)
    // Playlists merge keeps local "Daily" and adds only "Space 4+".
    XCTAssertEqual(mergePlan.playlists?.plansToCreate.map(\.name), ["Space 4+"])
    // Presets merge keeps local "Warm" and adds only "Cool".
    XCTAssertEqual(mergePlan.presets?.presetsToImport.map(\.name), ["Cool"])
    // Skipped display-2 omits pinned widget and drops display-2 assignment from layout.
    XCTAssertEqual(mergePlan.widgets?.widgets.isEmpty, true)
    XCTAssertEqual(mergePlan.layouts?.layoutsToSave.count, 1)
    XCTAssertEqual(mergePlan.layouts?.layoutsToSave.first?.assignments.map(\.displayID), ["primary"])
    XCTAssertEqual(mergePlan.layouts?.layoutsToSave.first?.autoApplyOnConnect, false)
    // Video trim merge keeps local 1001 and adds only 2002.
    XCTAssertEqual(Array((mergePlan.videoTrims?.rangesToSet ?? [:]).keys), ["2002"])
    // Downloads NEVER queued unless confirmed.
    XCTAssertTrue(mergePlan.confirmedDownloadWorkshopItems.isEmpty)

    // Replace plan with ONLY `.favorites` and `.videoTrims` leaves every other category nil!
    let selectiveReplace = try sync.preparePullPlan(
      preview: preview,
      options: SyncFolderPullOptions(
        selectedCategories: [.favorites, .videoTrims],
        conflictStrategy: .replace,
        queueMissingDownloadsConfirmed: true
      ),
      localState: localState
    )
    XCTAssertEqual(selectiveReplace.favorites, Set(["1001", "2002"]))
    XCTAssertNil(selectiveReplace.collections)
    XCTAssertNil(selectiveReplace.metadata)
    XCTAssertNil(selectiveReplace.playlists)
    XCTAssertNil(selectiveReplace.presets)
    XCTAssertNil(selectiveReplace.widgets)
    XCTAssertNil(selectiveReplace.layouts)
    XCTAssertEqual(selectiveReplace.videoTrims?.rangesToSet["1001"]?.startSeconds, 2.0)
    XCTAssertEqual(Set(selectiveReplace.confirmedDownloadWorkshopItems.map(\.id)), Set(["2002", "3003"]))
  }

  func testPreParseJSONGuardsAndMultiDisplayWidgetMergeDoNotCollapseDistinctDisplays() throws {
    let sync = service()

    // 1. Pre-parse JSON structure guard rejects truncated/unbalanced and unterminated string JSON.
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data("{\"format\": [1, 2".utf8)))
    XCTAssertThrowsError(try sync.parseAndValidate(data: Data("{\"format\": \"unterminated".utf8)))

    // 2. Merge keeps identical desktop widgets pinned to two distinct displays instead of collapsing them.
    let sourceDisplays = [
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "SRC-1", title: "Built-in", isPrimary: true, width: 1728, height: 1117),
      SetupPackTargetDisplay(
        displayID: "2", displayUUID: "SRC-2", title: "Studio Display", isPrimary: false, width: 2560, height: 1440),
    ]
    var sourceWidget1 = DesktopWidget(id: "src-w1", kind: .time)
    sourceWidget1.placement = .display(uuid: "SRC-1", name: "Built-in")
    var sourceWidget2 = DesktopWidget(id: "src-w2", kind: .time)
    sourceWidget2.placement = .display(uuid: "SRC-2", name: "Studio Display")

    _ = try sync.push(
      to: syncDir,
      state: SyncFolderLocalState(displays: sourceDisplays, widgets: [sourceWidget1, sourceWidget2])
    )

    // Target Mac already has an identical clock widget on Display 1 (DST-1), and duplicate display IDs
    // in the local list must not crash Dictionary construction.
    let targetDisplays = [
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "DST-1", title: "Main Mac", isPrimary: true, width: 1512, height: 982),
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "DST-1", title: "Main Mac Duplicate", isPrimary: true, width: 1512, height: 982),
      SetupPackTargetDisplay(
        displayID: "9", displayUUID: "DST-2", title: "External", isPrimary: false, width: 2560, height: 1440),
    ]
    var localWidget1 = DesktopWidget(id: "local-w1", kind: .time)
    localWidget1.placement = .display(uuid: "DST-1", name: "Main Mac")

    let localState = SyncFolderLocalState(displays: targetDisplays, widgets: [localWidget1])
    let preview = try sync.previewPull(from: syncDir, localState: localState)
    XCTAssertEqual(preview.diff(for: .widgets).unchangedCount, 1)
    XCTAssertEqual(preview.diff(for: .widgets).addedCount, 1)

    let mergePlan = try sync.preparePullPlan(
      preview: preview,
      options: SyncFolderPullOptions(selectedCategories: [.widgets], conflictStrategy: .merge),
      localState: localState
    )
    XCTAssertEqual(mergePlan.widgets?.widgets.count, 1)
    XCTAssertEqual(mergePlan.widgets?.widgets.first?.placement, .display(uuid: "DST-2", name: "External"))
  }
}
