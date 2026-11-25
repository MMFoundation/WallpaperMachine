import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import WallpaperMachine

@MainActor
final class StorageHealthTests: SettingsBTestCase {
  // MARK: - On-demand guarantee

  func testStorageHealthPerformsZeroWorkAtLaunchAndSettingsOpen() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertNil(controller.storageHealthModel, "Storage Health must not allocate or scan at launch")

      let hosting = NSHostingController(
        rootView: StorageSettingsSection()
          .environment(controller)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared))
      hosting.sizingOptions = []
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      defer {
        window.contentViewController = nil
        window.close()
      }
      window.setContentSize(NSSize(width: 760, height: 600))
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()

      XCTAssertNil(
        controller.storageHealthModel,
        "Opening Settings › Storage must never trigger an automatic Storage Health scan")
    }
  }

  // MARK: - Duplicate selection guard & Trash-based deletion

  func testDuplicateSelectionProtectsAtLeastOneCopyAndMovesOnlyRedundantCopyToTrash() async throws {
    try await withRecordingPanel { panel, bridge in
      let controller = panel.controller
      let payload = Data(repeating: 0x42, count: 16_384)
      for (id, title) in [("dup-keep", "Aurora Original"), ("dup-extra", "Aurora Copy")] {
        let folder = ClientPaths.libraryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"type":"video","title":"\#(title)","file":"clip.mp4"}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
        try payload.write(to: folder.appendingPathComponent("clip.mp4"))
      }

      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("dup-keep", title: "Aurora Original"),
        OrganizationFixtures.wallpaper("dup-extra", title: "Aurora Copy"),
      ]
      panel.store.monitorInformationSnapshot.rows = [
        OrganizationFixtures.monitor("primary", wallpaper: "dup-keep")
      ]
      panel.store.settingsSnapshot.displays = [
        OrganizationFixtures.display("primary", title: "Main Display")
      ]

      var trashedFolders: [URL] = []
      controller.recycleWallpaperFolder = { url in
        trashedFolders.append(url)
        try FileManager.default.removeItem(at: url)
      }

      try await controller.scanStorageHealth()
      let model = controller.storageHealth
      let report = try XCTUnwrap(model.report)
      XCTAssertEqual(report.duplicateGroups.count, 1)

      let group = try XCTUnwrap(report.duplicateGroups.first)
      XCTAssertEqual(group.recommendedKeepID, "dup-keep")
      XCTAssertEqual(model.selectedDuplicateIDs, ["dup-extra"])

      // Attempting to also select the keep copy (leaving zero copies kept) MUST be blocked.
      XCTAssertFalse(model.canToggleDuplicate("dup-keep", in: group))
      XCTAssertFalse(model.toggleDuplicate("dup-keep", in: group))
      XCTAssertEqual(model.selectedDuplicateIDs, ["dup-extra"])

      // Deselecting dup-extra unlocks selecting dup-keep, and vice versa.
      XCTAssertTrue(model.toggleDuplicate("dup-extra", in: group))
      XCTAssertTrue(model.canToggleDuplicate("dup-keep", in: group))
      model.selectRecommendedDuplicates()
      XCTAssertEqual(model.selectedDuplicateIDs, ["dup-extra"])

      // Declining confirmation moves nothing to Trash.
      panel.dialogs.confirmAnswer = false
      try await model.trashSelectedDuplicates()
      XCTAssertTrue(trashedFolders.isEmpty)

      // Confirming moves ONLY dup-extra through WallpaperDeletionService.moveToTrash (recycle seam).
      panel.dialogs.confirmAnswer = true
      var remainingLibrary = panel.store.librarySnapshot
      remainingLibrary.wallpapers = [
        OrganizationFixtures.wallpaper("dup-keep", title: "Aurora Original")
      ]
      bridge.bundleProvider = { [store = panel.store, remainingLibrary] in
        BridgeSnapshotBundle(
          app: store.appSnapshot, library: remainingLibrary, wallpaperOptions: nil,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
      bridge.snapshot = bridge.bundleProvider?()

      try await model.trashSelectedDuplicates()
      XCTAssertEqual(trashedFolders.map(\.lastPathComponent), ["dup-extra"])
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: ClientPaths.libraryURL.appendingPathComponent("dup-keep").path))
      XCTAssertTrue(model.report?.duplicateGroups.isEmpty == true)
    }
  }

  // MARK: - Bounded history wording & unused filtering

  func testUnusedWallpapersUseNoRecentUseRecordedWordingNeverClaimsNeverUsed() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let recordedDate = fixedNow.addingTimeInterval(-60 * 86_400)

    let unrecordedText = StorageHealthModel.lastUsedText(nil, locale: english)
    XCTAssertEqual(unrecordedText, "No recent use recorded")
    XCTAssertFalse(unrecordedText.localizedCaseInsensitiveContains("never"))

    let recordedText = StorageHealthModel.lastUsedText(recordedDate, locale: english)
    XCTAssertTrue(recordedText.hasPrefix("Last used "))

    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      controller.storageHealth.nowProvider = { fixedNow }

      for id in ["unused-big", "fav-big"] {
        let folder = ClientPaths.libraryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: folder.appendingPathComponent("clip.mp4"))
      }
      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("unused-big", title: "Large Unused"),
        OrganizationFixtures.wallpaper("fav-big", title: "Large Favorite"),
      ]
      try await controller.toggleFavorite("fav-big")

      try await controller.scanStorageHealth()
      let model = controller.storageHealth
      model.minimumSize = .any
      model.recencyFilter = .noRecentRecordOnly
      XCTAssertEqual(model.filteredUnusedWallpapers.map(\.id), ["unused-big"])
    }
  }

  // MARK: - Broken reference repair & orphan cleanup

  func testOneClickBrokenReferenceRepairAndOrphanCleanupEndToEnd() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller

      let installedFolder = ClientPaths.libraryURL.appendingPathComponent("live-1", isDirectory: true)
      try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
      try Data(#"{"type":"scene","title":"Live"}"#.utf8).write(
        to: installedFolder.appendingPathComponent("project.json"))
      try Data("scene-bytes".utf8).write(to: installedFolder.appendingPathComponent("scene.pkg"))
      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("live-1", title: "Live")
      ]

      // Seed dangling references across every audited store.
      controller.favoriteIDs = ["live-1", "gone-fav"]
      try PanelPreferences.saveFavorites(controller.favoriteIDs, in: panel.defaults)
      _ = try panel.collections.create(name: "My Collection", wallpaperIDs: ["live-1", "gone-col"])
      panel.playlists.update("primary") {
        $0.mode = .rotate
        $0.source = .list
        $0.wallpaperIDs = ["live-1", "gone-pl"]
      }
      _ = try panel.playlists.savePlan(from: "primary", name: "Saved Plan")
      try panel.automations.update("primary") {
        $0.mode = .schedule
        $0.rules = [
          WallpaperAutomationRule(
            weekdays: Set(1...7), event: .time, minute: 540,
            target: .init(kind: .wallpaper, id: "gone-auto"))
        ]
      }
      panel.metadata.setRating(5, for: "gone-meta")
      _ = try controller.displayLayouts.save(
        name: "Desk",
        assignments: [
          .init(displayID: "primary", displayTitle: "Main", wallpaperID: "live-1"),
          .init(displayID: "secondary", displayTitle: "Side", wallpaperID: "gone-layout"),
        ])

      // Seed orphaned SceneStorage and SpacePosters under isolated ClientPaths.
      let orphanScene = ClientPaths.sceneStorageURL.appendingPathComponent("gone-scene", isDirectory: true)
      try FileManager.default.createDirectory(at: orphanScene, withIntermediateDirectories: true)
      try Data(repeating: 9, count: 2048).write(to: orphanScene.appendingPathComponent("global.json"))
      try FileManager.default.createDirectory(
        at: ClientPaths.spacePosterCacheURL, withIntermediateDirectories: true)
      let orphanPoster = ClientPaths.spacePosterCacheURL.appendingPathComponent("stale-poster.jpg")
      try Data(repeating: 7, count: 4096).write(to: orphanPoster)

      try await controller.scanStorageHealth()
      let model = controller.storageHealth
      let report = try XCTUnwrap(model.report)
      XCTAssertFalse(report.brokenReferences.isEmpty)
      XCTAssertEqual(report.orphanedStorage.count, 2)

      // One-click broken reference repair cleans every store cleanly.
      try await model.repairAllBrokenReferences()
      XCTAssertEqual(controller.favoriteIDs, ["live-1"])
      XCTAssertEqual(panel.collections.collections.first?.wallpaperIDs, ["live-1"])
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["live-1"])
      XCTAssertEqual(panel.playlists.plans.first?.playlist.wallpaperIDs, ["live-1"])
      XCTAssertTrue(panel.automations.configuration(for: "primary").rules.isEmpty)
      XCTAssertNil(panel.metadata.entries["gone-meta"])
      XCTAssertEqual(controller.displayLayouts.layouts.first?.assignments.map(\.wallpaperID), ["live-1"])
      XCTAssertTrue(model.report?.brokenReferences.isEmpty == true)

      // Orphan cleanup requires confirmation and deletes only verified orphans.
      panel.dialogs.confirmAnswer = false
      try await model.cleanSelectedOrphans(locale: english)
      XCTAssertTrue(FileManager.default.fileExists(atPath: orphanScene.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: orphanPoster.path))

      panel.dialogs.confirmAnswer = true
      try await model.cleanSelectedOrphans(locale: english)
      XCTAssertFalse(FileManager.default.fileExists(atPath: orphanScene.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPoster.path))
      XCTAssertTrue(model.report?.orphanedStorage.isEmpty == true)
    }
  }

  // MARK: - Search & sheet render

  func testStorageHealthIsSearchableAndSheetRendersCleanly() async throws {
    try await withRecordingPanel { panel, _ in
      let index = SettingsIndex(items: StorageSettingsSection.items, locale: PanelLocale.shared)
      for query in ["Storage health", "Duplicates", "Not used recently", "Broken references", "Orphaned storage"] {
        let search = SettingsSearch(query: query, index: index)
        XCTAssertTrue(
          search.shows(StorageSettingsSection.storageHealth),
          "Settings search for '\(query)' should reveal Storage health")
      }

      try await panel.controller.scanStorageHealth()
      let hosting = NSHostingController(
        rootView: StorageHealthSheet()
          .environment(panel.controller)
          .panelTheme(theme: panel.controller.theme, locale: PanelLocale.shared))
      hosting.sizingOptions = []
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      defer {
        window.contentViewController = nil
        window.close()
      }
      window.setContentSize(NSSize(width: 680, height: 540))
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
    }
  }
}
