import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import WallpaperMachine

@MainActor
final class SyncFolderTests: PanelTestCase {
  // MARK: - In-place Pull Apply (Merge & Selective Replace)

  func testPanelPushAndPullAppliesInPlaceAcrossAllStoresAndPreservesLocalAutoApply() async throws {
    try await withRecordingPanel { panel, _ in
      let syncDir = panel.root.deletingLastPathComponent().appendingPathComponent(
        "sync-panel-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: syncDir) }

      let service = SyncFolderService(supportRoot: panel.root, storageRoot: panel.root)

      // 1. Seed source snapshot on disk (as if pushed from another Mac).
      let sourceTarget = SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "SRC-MAIN-UUID", title: "Mac Studio Display", isPrimary: true)
      var smart = DisplayPlaylist()
      smart.mode = .rotate
      smart.source = .smart
      smart.smartQuery = SmartPlaylistQuery(requiredTags: ["Anime"], minimumRating: 4)
      var widget = DesktopWidget(id: UUID().uuidString, kind: .text)
      widget.text = "Synced Clock Note"
      widget.placement = .main
      let sourceState = SyncFolderLocalState(
        deviceName: "Mac Studio",
        appVersion: "2.3.0",
        displays: [sourceTarget],
        libraryTitles: ["100001": "Installed Scene", "200002": "Missing Scene"],
        favorites: ["100001", "200002"],
        collections: [
          WallpaperCollection(id: "src-col-1", name: "Favorites Pack", wallpaperIDs: ["100001", "200002"]),
          WallpaperCollection(id: "src-col-2", name: "Remote Only", wallpaperIDs: ["200002"]),
        ],
        metadata: [
          "100001": WallpaperMetadata(customTags: ["Neon", "Night"], rating: 2, note: "Remote note", excludedFromRotation: true),
          "200002": WallpaperMetadata(customTags: ["Anime"], rating: 5, note: "Must download", excludedFromRotation: false),
        ],
        playlists: [PlaylistPlan(id: "src-plan-1", name: "Anime 4+", playlist: smart)],
        presets: [
          WallpaperPropertyPreset(
            id: UUID().uuidString, wallpaperID: "100001", name: "Studio Preset",
            properties: [WallpaperPresetProperty(id: "bloom", kind: "bool", value: .bool(true), usesDefault: false, retainedPath: nil)])
        ],
        widgets: [widget],
        layouts: [
          WallpaperDisplayLayout(
            name: "Studio Desk",
            assignments: [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "100001")],
            autoApplyOnConnect: true)
        ],
        videoTrims: [
          "100001": try VideoTrimRange(startSeconds: 3.0, endSeconds: 9.0),
          "200002": try VideoTrimRange(startSeconds: 1.0, endSeconds: 5.0),
        ]
      )
      _ = try service.push(to: syncDir, state: sourceState)

      // 2. Seed local recipient Mac state (including an armed auto-apply layout).
      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("100001", title: "Installed Scene")
      ]
      try PanelPreferences.saveFavorites(["100001", "900009"], in: panel.defaults)
      panel.controller.favoriteIDs = ["100001", "900009"]
      _ = try panel.collections.create(name: "Favorites Pack", wallpaperIDs: ["100001"])
      panel.metadata.update("100001") {
        $0 = WallpaperMetadata(customTags: ["Night"], rating: 5, note: "Local note", excludedFromRotation: false)
      }
      let existingAutoLayout = try panel.controller.displayLayouts.save(
        name: "My Own Desk",
        assignments: [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "900009")],
        autoApplyOnConnect: true)
      try panel.controller.videoTrim.set(try VideoTrimRange(startSeconds: 0.0, endSeconds: 4.0), for: "100001")

      // 3. Bind sync folder locally and preview pull.
      let bound = try await panel.controller.chooseSyncFolder(url: syncDir, service: service)
      XCTAssertNotNil(bound)
      let preview = try await panel.controller.previewSyncFolderPull(service: service)
      XCTAssertEqual(preview.installedWorkshopItems.map(\.id), ["100001"])
      XCTAssertEqual(preview.missingWorkshopItems.map(\.id), ["200002"])

      // 4. Apply Merge in place without queueing downloads.
      let report = try await panel.controller.applySyncFolderPull(
        preview,
        options: SyncFolderPullOptions(
          selectedCategories: Set(SyncFolderCategory.allCases),
          conflictStrategy: .merge,
          queueMissingDownloadsConfirmed: false
        ),
        service: service
      )
      XCTAssertEqual(report.queuedDownloadsCount, 0)
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)

      // Verify in-place merged state across all 8 stores:
      XCTAssertEqual(panel.controller.favoriteIDs, Set(["100001", "200002", "900009"]))
      XCTAssertEqual(Set(panel.collections.collections.map(\.name)), Set(["Favorites Pack", "Remote Only"]))
      let mergedCol = try XCTUnwrap(panel.collections.collections.first { $0.name == "Favorites Pack" })
      XCTAssertEqual(Set(mergedCol.wallpaperIDs), Set(["100001", "200002"]))
      // Local metadata preserved on conflict + tags unioned + new entry added.
      let localMeta = panel.metadata.metadata(for: "100001")
      XCTAssertEqual(localMeta.rating, 5)
      XCTAssertEqual(localMeta.note, "Local note")
      XCTAssertFalse(localMeta.excludedFromRotation)
      XCTAssertEqual(Set(localMeta.customTags), Set(["Night", "Neon"]))
      XCTAssertEqual(panel.metadata.metadata(for: "200002").rating, 5)
      // Smart playlist added.
      XCTAssertTrue(panel.playlists.plans.contains { $0.name == "Anime 4+" && $0.playlist.source == .smart })
      // Preset & widget added.
      XCTAssertTrue(panel.presets.items.contains { $0.name == "Studio Preset" })
      XCTAssertTrue(panel.controller.desktopWidgets.widgets.contains { $0.text == "Synced Clock Note" })
      // Existing auto-apply layout STILL armed, imported layout saved with autoApplyOnConnect: false!
      XCTAssertTrue(try panel.controller.displayLayouts.layout(existingAutoLayout.id).autoApplyOnConnect)
      let importedLayout = try XCTUnwrap(
        panel.controller.displayLayouts.layouts.first { $0.name == "Studio Desk" })
      XCTAssertFalse(importedLayout.autoApplyOnConnect)
      // Local video trim preserved on conflict, new trim added.
      XCTAssertEqual(panel.controller.videoTrim.trimRange(for: "100001")?.startSeconds, 0.0)
      XCTAssertEqual(panel.controller.videoTrim.trimRange(for: "200002")?.startSeconds, 1.0)

      // 5. Selective Replace on ONLY `.videoTrims` replaces video trims while leaving favorites/layouts untouched!
      _ = try await panel.controller.applySyncFolderPull(
        preview,
        options: SyncFolderPullOptions(
          selectedCategories: [.videoTrims],
          conflictStrategy: .replace,
          queueMissingDownloadsConfirmed: false
        ),
        service: service
      )
      XCTAssertEqual(panel.controller.videoTrim.trimRange(for: "100001")?.startSeconds, 3.0)
      XCTAssertEqual(panel.controller.favoriteIDs, Set(["100001", "200002", "900009"]))
      XCTAssertTrue(try panel.controller.displayLayouts.layout(existingAutoLayout.id).autoApplyOnConnect)

      // 6. Push from panel updates lastPushAt in local binding and writes valid snapshot.
      let pushReport = try await panel.controller.pushToSyncFolder(service: service)
      XCTAssertGreaterThan(pushReport.byteCount, 0)
      XCTAssertNotNil(panel.controller.syncFolderBinding()?.lastPushAt)
    }
  }

  // MARK: - Explicit Opt-In Download Confirmation Gate

  func testPullRequiresExplicitConfirmationBeforeQueueingMissingWorkshopDownloads() async throws {
    try await withRecordingPanel { panel, _ in
      let syncDir = panel.root.deletingLastPathComponent().appendingPathComponent(
        "sync-confirm-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: syncDir) }

      let service = SyncFolderService(supportRoot: panel.root, storageRoot: panel.root)
      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("100001", title: "Already Installed")
      ]
      let source = SyncFolderLocalState(
        libraryTitles: ["100001": "Already Installed", "200002": "Missing One", "300003": "Missing Two"],
        favorites: ["100001", "200002", "300003"]
      )
      _ = try service.push(to: syncDir, state: source)

      let preview = try await panel.controller.previewSyncFolderPull(from: syncDir, service: service)
      XCTAssertEqual(preview.installedWorkshopItems.map(\.id), ["100001"])
      XCTAssertEqual(Set(preview.missingWorkshopItems.map(\.id)), Set(["200002", "300003"]))

      // 1. Default options (queueMissingDownloadsConfirmed == false): NEVER queues.
      let reportOff = try await panel.controller.applySyncFolderPull(
        preview,
        options: SyncFolderPullOptions(selectedCategories: [.favorites], queueMissingDownloadsConfirmed: false),
        service: service
      )
      XCTAssertEqual(reportOff.queuedDownloadsCount, 0)
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)

      // 2. Opt-in checked, but user cancels confirmation dialog: still ZERO downloads queued.
      panel.dialogs.confirmAnswer = false
      let reportDeclined = try await panel.controller.applySyncFolderPull(
        preview,
        options: SyncFolderPullOptions(selectedCategories: [], queueMissingDownloadsConfirmed: true),
        service: service
      )
      XCTAssertEqual(reportDeclined.queuedDownloadsCount, 0)
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)

      // 3. Explicit confirmation granted: queues ONLY missing Workshop items (never already-installed 100001).
      panel.dialogs.confirmAnswer = true
      let reportConfirmed = try await panel.controller.applySyncFolderPull(
        preview,
        options: SyncFolderPullOptions(selectedCategories: [], queueMissingDownloadsConfirmed: true),
        service: service
      )
      XCTAssertEqual(reportConfirmed.queuedDownloadsCount, 2)
      XCTAssertEqual(Set(panel.workshop.downloadRequests.map(\.id)), Set(["200002", "300003"]))
    }
  }

  // MARK: - Panel Zero-Body-I/O & Settings Search Coverage

  func testSyncFolderSectionRendersWithoutBodyDiskIOAndIndexesCleanlyInSettingsSearch() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      // Point local binding at a nonexistent path: if SwiftUI `body` performed synchronous disk I/O
      // or threw on missing folders, layout would block or fail.
      controller.defaults.set("/nonexistent/sync/folder/path", forKey: SyncFolderBindingStore.folderPathKey)

      let hosting = NSHostingController(
        rootView: SyncFolderSection()
          .environment(controller)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared)
      )
      hosting.sizingOptions = []
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      defer {
        window.contentViewController = nil
        window.close()
      }
      window.setContentSize(NSSize(width: 760, height: 320))
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()

      // Verify Settings search indexes every SyncFolderSection item with zero registry problems.
      XCTAssertEqual(SettingsRegistry.problems(in: SyncFolderSection.items), [])
      let english = PanelLocale(language: .english, region: nil)
      let index = SettingsIndex(items: SyncFolderSection.items) { english.string(resolving: $0) }

      XCTAssertTrue(SettingsSearch(query: "Cross-Mac sync folder", index: index).shows(SyncFolderSection.syncFolderLocation))
      XCTAssertTrue(SettingsSearch(query: "iCloud Drive", index: index).shows(SyncFolderSection.syncFolderLocation))
      XCTAssertTrue(SettingsSearch(query: "Push now", index: index).shows(SyncFolderSection.syncFolderActions))
      XCTAssertTrue(SettingsSearch(query: "Pull & Review", index: index).shows(SyncFolderSection.syncFolderActions))
      XCTAssertTrue(SettingsSearch(query: "Merge", index: index).shows(SyncFolderSection.syncFolderActions))
      XCTAssertTrue(SettingsSearch(query: "Replace", index: index).shows(SyncFolderSection.syncFolderActions))
    }
  }
}
