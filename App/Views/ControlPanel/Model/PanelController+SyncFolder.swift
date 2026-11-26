import AppKit
import Foundation

/// Typed manual Cross-Mac Sync Folder actions on `PanelController`.
///
/// Phase 1 is deliberately manual (Push now / Pull & Review) with zero `DirectoryWatcher`
/// write-loops and zero real-time store races. Works with iCloud Drive, Syncthing, Dropbox,
/// OneDrive, SMB/NAS or external drives, keeps folder binding strictly local in `UserDefaults`,
/// detects evicted iCloud placeholders, previews per-category diffs & conflicts, remaps displays
/// cleanly (always saving imported layouts with `autoApplyOnConnect: false`), requires explicit
/// confirmation before queueing any missing Workshop download, and applies in place with no restart.
extension PanelController {
  /// Currently bound local-only sync folder, or nil if none is configured. Reads only `UserDefaults`
  /// and performs zero disk I/O.
  func syncFolderBinding() -> SyncFolderBinding? {
    SyncFolderBindingStore.load(from: defaults)
  }

  /// Opens a folder picker (unless `url` is supplied), validates the folder is outside
  /// WallpaperMachine's support and library folders, and persists the local-only binding in
  /// `UserDefaults`.
  @discardableResult
  func chooseSyncFolder(
    url: URL? = nil,
    service: SyncFolderService? = nil
  ) async throws -> SyncFolderBinding? {
    errors.clearAction()
    let chosenURL: URL
    if let url {
      chosenURL = url
    } else {
      let panel = NSOpenPanel()
      panel.title = L("Choose Sync Folder")
      panel.message = L(
        "Choose any folder synced by iCloud Drive, Syncthing, Dropbox, OneDrive, NAS or an external drive. Only your folder choice stays local to this Mac."
      )
      panel.prompt = L("Choose")
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      if let existing = syncFolderBinding() {
        panel.directoryURL = existing.folderURL
      }
      guard let selected = await dialogs.choose(panel) else { return nil }
      chosenURL = selected
    }

    var saved: SyncFolderBinding?
    try await run(.immediate) {
      let syncService = service ?? makeDefaultSyncFolderService()
      let scoped = chosenURL.startAccessingSecurityScopedResource()
      defer { if scoped { chosenURL.stopAccessingSecurityScopedResource() } }
      let validated = try await Task.detached(priority: .utility) {
        try syncService.validateSyncFolder(chosenURL)
      }.value
      saved = SyncFolderBindingStore.save(folderURL: validated, in: defaults)
    }
    return saved
  }

  /// Clears the local sync folder binding without deleting any files inside the folder.
  func clearSyncFolder() async throws {
    errors.clearAction()
    try await run(.immediate) {
      SyncFolderBindingStore.clear(in: defaults)
    }
  }

  /// Inspects `WallpaperMachineSync.json` in the currently bound sync folder off the main actor.
  /// Always checks iCloud placeholder status before opening so evicted files never hang.
  func inspectSyncFolderSummary(service: SyncFolderService? = nil) async -> SyncFolderRemoteSummary {
    guard let binding = syncFolderBinding() else { return .noFolder }
    let syncService = service ?? makeDefaultSyncFolderService()
    let (summary, resolved) = await Task.detached(priority: .utility) {
      let resolved = SyncFolderBindingStore.resolveBookmarkOffMainActor(for: binding)
      let scoped = resolved.isSecurityScoped && resolved.url.startAccessingSecurityScopedResource()
      defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
      return (syncService.inspectFolderSummary(at: resolved.url), resolved)
    }.value
    if let refreshed = resolved.refreshedBookmarkData {
      SyncFolderBindingStore.persistRefreshedBookmark(refreshed, for: resolved.url, in: defaults)
    }
    return summary
  }

  /// Captures an immutable `Sendable` snapshot of local syncable state on the main actor.
  func makeSyncFolderLocalState(now: Date = Date()) -> SyncFolderLocalState {
    _ = revisions.collections
    _ = revisions.metadata
    _ = revisions.playlists
    _ = revisions.presets
    _ = revisions.displayLayouts
    let libraryTitles = Dictionary(
      store.librarySnapshot.wallpapers.map { ($0.id, $0.title) },
      uniquingKeysWith: { first, _ in first }
    )
    let installedIDs = Set(store.librarySnapshot.wallpapers.map(\.id))
    return SyncFolderLocalState(
      displays: connectedSetupPackDisplays,
      libraryTitles: libraryTitles,
      installedWallpaperIDs: installedIDs,
      favorites: favoriteIDs,
      collections: collections.collections,
      metadata: metadata.entries,
      playlists: playlists.plans,
      presets: presets.items,
      widgets: desktopWidgets.widgets,
      layouts: displayLayouts.layouts,
      videoTrims: videoTrim.allRanges(),
      now: now
    )
  }

  /// Atomically exports `WallpaperMachineSync.json` into the bound sync folder (or `folderURL`).
  @discardableResult
  func pushToSyncFolder(
    to folderURL: URL? = nil,
    service: SyncFolderService? = nil
  ) async throws -> SyncFolderPushReport {
    errors.clearAction()
    let targetSource = try syncFolderTargetSource(override: folderURL)
    let localState = makeSyncFolderLocalState()
    let syncService = service ?? makeDefaultSyncFolderService()

    var outcome: SyncFolderPushReport?
    try await run(.immediate) {
      let (report, resolved) = try await Task.detached(priority: .utility) {
        let resolved: SyncFolderBindingStore.ResolvedBookmark =
          if let overrideURL = targetSource.overrideURL {
            .init(url: overrideURL, isSecurityScoped: false, refreshedBookmarkData: nil)
          } else {
            SyncFolderBindingStore.resolveBookmarkOffMainActor(for: targetSource.binding!)
          }
        let scoped = resolved.isSecurityScoped && resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        return (try syncService.push(to: resolved.url, state: localState), resolved)
      }.value
      if let refreshed = resolved.refreshedBookmarkData {
        SyncFolderBindingStore.persistRefreshedBookmark(refreshed, for: resolved.url, in: defaults)
      }
      if syncFolderBinding() != nil {
        SyncFolderBindingStore.recordPush(at: report.exportedAt, in: defaults)
      }
      outcome = report
    }
    guard let outcome else { throw CancellationError() }
    return outcome
  }

  /// Strictly reads and validates `WallpaperMachineSync.json` from the bound sync folder (or
  /// `folderURL`) off the main actor and returns a full per-category diff & conflict preview.
  func previewSyncFolderPull(
    from folderURL: URL? = nil,
    service: SyncFolderService? = nil
  ) async throws -> SyncFolderPullPreview {
    errors.clearAction()
    let targetSource = try syncFolderTargetSource(override: folderURL)
    let localState = makeSyncFolderLocalState()
    let syncService = service ?? makeDefaultSyncFolderService()

    var preview: SyncFolderPullPreview?
    try await run(.immediate) {
      let (loaded, resolved) = try await Task.detached(priority: .utility) {
        let resolved: SyncFolderBindingStore.ResolvedBookmark =
          if let overrideURL = targetSource.overrideURL {
            .init(url: overrideURL, isSecurityScoped: false, refreshedBookmarkData: nil)
          } else {
            SyncFolderBindingStore.resolveBookmarkOffMainActor(for: targetSource.binding!)
          }
        let scoped = resolved.isSecurityScoped && resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        return (try syncService.previewPull(from: resolved.url, localState: localState), resolved)
      }.value
      if let refreshed = resolved.refreshedBookmarkData {
        SyncFolderBindingStore.persistRefreshedBookmark(refreshed, for: resolved.url, in: defaults)
      }
      preview = loaded
    }
    guard let preview else { throw CancellationError() }
    return preview
  }

  /// Applies the selected categories from `preview` cleanly in place with zero app restart.
  ///
  /// Guarantees:
  /// - Unselected categories are never touched.
  /// - Imported Display Layouts ALWAYS save with `autoApplyOnConnect: false` so an existing local
  ///   auto-apply layout is never disarmed or replaced silently.
  /// - Missing Workshop wallpapers are NEVER downloaded unless `options.queueMissingDownloadsConfirmed`
  ///   is true AND explicitly confirmed by the user.
  @discardableResult
  func applySyncFolderPull(
    _ preview: SyncFolderPullPreview,
    options: SyncFolderPullOptions,
    requireDownloadConfirmationDialog: Bool = true,
    service: SyncFolderService? = nil
  ) async throws -> SyncFolderPullApplyReport {
    errors.clearAction()
    var effectiveOptions = options
    if effectiveOptions.queueMissingDownloadsConfirmed, !preview.missingWorkshopItems.isEmpty,
      requireDownloadConfirmationDialog
    {
      let count = preview.missingWorkshopItems.count
      let title =
        count == 1
        ? L("Queue 1 missing Workshop wallpaper?")
        : L("Queue \(count) missing Workshop wallpapers?")
      let detail = L(
        "WallpaperMachine will add the missing Steam Workshop wallpapers to your download queue using your configured Steam download settings. Already-installed wallpapers are skipped."
      )
      let confirmed = await dialogs.confirm(title, detail: detail, button: L("Queue Downloads"))
      if !confirmed {
        effectiveOptions.queueMissingDownloadsConfirmed = false
      }
    }

    var outcome: SyncFolderPullApplyReport?
    try await run(.immediate) {
      let localState = makeSyncFolderLocalState()
      let syncService = service ?? makeDefaultSyncFolderService()
      let plan = try syncService.preparePullPlan(
        preview: preview,
        options: effectiveOptions,
        localState: localState
      )

      var notes = plan.notes

      // Pre-validate names before mutating any store so a malformed entry cannot leave half-applied state.
      if let collectionsPlan = plan.collections {
        for item in collectionsPlan.collectionsToCreate {
          _ = try WallpaperCollectionStore.validatedName(item.name)
        }
      }
      if let playlistsPlan = plan.playlists {
        for item in playlistsPlan.plansToCreate {
          _ = try WallpaperCollectionStore.validatedName(item.name)
        }
      }
      if let layoutsPlan = plan.layouts {
        for item in layoutsPlan.layoutsToSave {
          _ = try WallpaperCollectionStore.validatedName(item.name)
          try WallpaperDisplayLayoutStore.validateAssignments(item.assignments)
        }
      }

      // 1. Favorites
      var favoritesApplied = false
      var favoritesCount = 0
      if let nextFavorites = plan.favorites {
        try PanelPreferences.saveFavorites(nextFavorites, in: defaults)
        favoriteIDs = nextFavorites
        favoritesApplied = true
        favoritesCount = nextFavorites.count
      }

      // 2. Collections (also tracks incoming collectionID -> local collectionID for playlist remapping)
      var collectionIDMap: [String: String] = [:]
      var collectionsCreatedCount = 0
      var collectionsUpdatedCount = 0
      if let collectionsPlan = plan.collections {
        collectionIDMap = collectionsPlan.matchedExistingIDByIncomingID
        if collectionsPlan.replaceAll {
          for existing in collections.collections {
            try collections.delete(existing.id)
          }
        }
        for update in collectionsPlan.collectionsToUpdate {
          try collections.add(update.addedWallpaperIDs, to: update.existingID)
          collectionsUpdatedCount += 1
        }
        for item in collectionsPlan.collectionsToCreate {
          let created = try collections.create(name: item.name, wallpaperIDs: item.wallpaperIDs)
          collectionIDMap[item.id] = created.id
          collectionsCreatedCount += 1
        }
      }

      // 3. Metadata
      var metadataWrittenCount = 0
      if let metadataPlan = plan.metadata {
        if !metadataPlan.keysToForget.isEmpty {
          metadata.forget(metadataPlan.keysToForget)
        }
        for (wallpaperID, entry) in metadataPlan.entriesToWrite {
          metadata.update(wallpaperID) { $0 = entry }
          metadataWrittenCount += 1
        }
      }

      // 4. Saved Playlists (including Smart Playlists)
      var playlistsAppliedCount = 0
      if let playlistsPlan = plan.playlists {
        if playlistsPlan.replaceAll {
          for existing in playlists.plans {
            try playlists.deletePlan(existing.id)
          }
        }
        for item in playlistsPlan.plansToCreate {
          var playlist = item.playlist
          playlist.planID = nil
          if let cid = playlist.collectionID, let mapped = collectionIDMap[cid] {
            playlist.collectionID = mapped
          }
          _ = try playlists.savePlan(name: item.name, playlist: playlist)
          playlistsAppliedCount += 1
        }
      }

      // 5. Portable Property Presets
      var presetsAppliedCount = 0
      if let presetsPlan = plan.presets {
        if presetsPlan.replaceAll {
          for existing in presets.items {
            try await presets.delete(id: existing.id)
          }
        }
        if !presetsPlan.presetsToImport.isEmpty {
          let remaining = max(0, WallpaperPresetStore.maximumPresets - presets.items.count)
          let batch = Array(presetsPlan.presetsToImport.prefix(remaining))
          if batch.count < presetsPlan.presetsToImport.count {
            notes.append(
              L("Imported \(batch.count) of \(presetsPlan.presetsToImport.count) presets because the preset limit was reached.")
            )
          }
          let imported = try presets.importPortablePresets(batch)
          presetsAppliedCount = imported.count
        }
      }

      // 6. Portable Desktop Widgets
      var widgetsAppliedCount = 0
      if let widgetsPlan = plan.widgets {
        if widgetsPlan.replaceAll {
          let replaced = widgetsPlan.widgets.prefix(DesktopWidgetStore.limit).map { widget -> DesktopWidget in
            var copy = widget.clamped()
            copy.id = UUID().uuidString
            copy.imageAsset = nil
            if case .spaces = copy.scope { copy.scope = .everywhere }
            return copy
          }
          try desktopWidgets.restore(Array(replaced))
          widgetsAppliedCount = replaced.count
        } else if !widgetsPlan.widgets.isEmpty {
          let remaining = max(0, DesktopWidgetStore.limit - desktopWidgets.widgets.count)
          let batch = Array(widgetsPlan.widgets.prefix(remaining))
          if batch.count < widgetsPlan.widgets.count {
            notes.append(
              L("Imported \(batch.count) of \(widgetsPlan.widgets.count) widgets because the limit of 24 widgets was reached.")
            )
          }
          if !batch.isEmpty {
            let added = try desktopWidgets.add(batch)
            widgetsAppliedCount = added.count
          }
        }
      }

      // 7. Portable Display Layouts (ALWAYS saved with autoApplyOnConnect: false!)
      var layoutsAppliedCount = 0
      if let layoutsPlan = plan.layouts {
        if layoutsPlan.replaceAll {
          for existing in displayLayouts.layouts {
            try displayLayouts.delete(existing.id)
          }
        }
        var skippedDueToLimit = 0
        for layout in layoutsPlan.layoutsToSave {
          if displayLayouts.layouts.count >= WallpaperDisplayLayoutStore.limit {
            skippedDueToLimit += 1
            continue
          }
          _ = try displayLayouts.save(
            name: layout.name,
            assignments: layout.assignments,
            autoApplyOnConnect: false
          )
          layoutsAppliedCount += 1
        }
        if skippedDueToLimit > 0 {
          notes.append(
            L("Skipped \(skippedDueToLimit) display layout(s) because the limit of 64 saved layouts was reached.")
          )
        }
      }

      // 8. Video Trim Ranges
      var videoTrimsAppliedCount = 0
      if let trimsPlan = plan.videoTrims {
        if !trimsPlan.keysToForget.isEmpty {
          try videoTrim.forget(trimsPlan.keysToForget)
        }
        for (wallpaperID, range) in trimsPlan.rangesToSet {
          try videoTrim.set(range, for: wallpaperID)
          videoTrimsAppliedCount += 1
        }
      }

      // 9. Missing Workshop Downloads (STRICTLY only when explicitly confirmed)
      let queuedCount = queueConfirmedSyncDownloads(plan.confirmedDownloadWorkshopItems)

      let appliedAt = Date()
      if syncFolderBinding() != nil {
        SyncFolderBindingStore.recordPull(at: appliedAt, in: defaults)
      }

      outcome = SyncFolderPullApplyReport(
        appliedAt: appliedAt,
        strategy: effectiveOptions.conflictStrategy,
        favoritesApplied: favoritesApplied,
        favoritesCount: favoritesCount,
        collectionsCreatedCount: collectionsCreatedCount,
        collectionsUpdatedCount: collectionsUpdatedCount,
        metadataWrittenCount: metadataWrittenCount,
        playlistsAppliedCount: playlistsAppliedCount,
        presetsAppliedCount: presetsAppliedCount,
        widgetsAppliedCount: widgetsAppliedCount,
        layoutsAppliedCount: layoutsAppliedCount,
        videoTrimsAppliedCount: videoTrimsAppliedCount,
        queuedDownloadsCount: queuedCount,
        notes: notes
      )
    }
    guard let outcome else { throw CancellationError() }
    return outcome
  }

  // MARK: - Helpers

  private func makeDefaultSyncFolderService() -> SyncFolderService {
    SyncFolderService(
      supportRoot: ClientPaths.supportURL,
      storageRoot: ClientPaths.storageURL
    )
  }

  private func syncFolderTargetSource(
    override folderURL: URL?
  ) throws -> (overrideURL: URL?, binding: SyncFolderBinding?) {
    if let folderURL {
      return (folderURL, nil)
    }
    guard let binding = syncFolderBinding() else {
      throw SyncFolderFailure.invalidFolder(L("Choose a sync folder first."))
    }
    return (nil, binding)
  }

  private func queueConfirmedSyncDownloads(_ items: [SetupPackWorkshopItem]) -> Int {
    guard !items.isEmpty else { return 0 }
    var queued = 0
    for item in items {
      guard let validID = SetupPackService.validatedWorkshopID(item.id) else { continue }
      if mediaLibraryContains(validID) { continue }
      if workshop.downloadRequests.contains(where: { $0.id == validID }) { continue }
      if let job = workshop.downloader.download(for: validID), job.isPending { continue }
      let resolved =
        workshop.workshopItem(id: validID)
        ?? WorkshopItem(
          id: validID,
          title: item.title ?? L("Workshop #\(validID)"),
          creator: "",
          summary: "",
          previewURL: nil,
          tags: [],
          size: 0,
          subscriptions: 0
        )
      workshop.requestDownload(item: resolved, rememberSession: remembersSession, bridge: store)
      queued += 1
    }
    return queued
  }
}
