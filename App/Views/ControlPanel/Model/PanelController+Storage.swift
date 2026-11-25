import AppKit
import Foundation
import UniformTypeIdentifiers

/// Settings › Storage and Library: opening the folders, clearing what can be rebuilt, exporting the
/// diagnostics report and the local backup.
///
/// The confirmations and the file picker are asked before the work is queued, so an open sheet holds
/// up no wallpaper switch; the banner is still cleared first, as it is for any queued action. Without
/// a window every confirmation and picker answers no, and the action does nothing.
extension PanelController {
  // MARK: Folders

  /// `showLibrary`: the wallpaper library in Finder.
  func showLibrary() async throws {
    try await run(.queued) { _ = openSystemURL(ClientPaths.libraryURL) }
  }

  /// `showLogs`: the folder the diagnostic logs are written to.
  func showLogs() async throws {
    try await run(.queued) { _ = openSystemURL(try store.logFolderURL()) }
  }

  /// `revealUserAssets`: the folder the files chosen in wallpaper settings are copied to, created first
  /// so the user is never shown an error for a folder they have simply not filled yet.
  func revealUserAssets() async throws {
    try await run(.queued) { UserAssetStorage.revealManagedDirectory() }
  }

  // MARK: Library location

  // A move is not queued: the copy can take minutes, and wallpapers keep switching meanwhile. The
  // store refuses a second one while one copies. The folder picker and the confirmation come first.

  /// `moveLibrary`: asks for a folder, checks it, says what the move copies and where, and prepares
  /// the move for the next launch.
  func moveLibrary() async throws {
    errors.clearAction()
    let panel = NSOpenPanel()
    panel.title = L("Move Wallpaper Library")
    panel.message = L(
      "Choose where to keep the wallpaper library and downloads, such as an external drive. WallpaperMachine creates a folder named WallpaperMachine there.")
    panel.prompt = L("Choose")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    guard let folder = await dialogs.choose(panel) else { return }
    try await prepareLibraryMove(to: folder)
  }

  /// `moveLibraryToThisMac`: brings the library and the downloads back into WallpaperMachine's own
  /// folder on this Mac, after a confirmation.
  func moveLibraryToThisMac() async throws {
    errors.clearAction()
    try await prepareLibraryMove(to: nil)
  }

  private func prepareLibraryMove(to folder: URL?) async throws {
    let plan = try await libraryLocation.plan(moveTo: folder)
    let size = ByteSize.text(Double(plan.bytes), locale: PanelLocale.shared.locale)
    let destination = plan.targetRoot.path
    let detail =
      plan.copies
      ? L(
        "WallpaperMachine copies \(size) to “\(destination)” now, and you can keep using it meanwhile. The move finishes the next time you open WallpaperMachine, which then deletes the old copy.")
      : L("The library and downloads move to “\(destination)” the next time you open WallpaperMachine.")
    let title = folder == nil ? L("Move the wallpaper library back to this Mac?") : L("Move the wallpaper library?")
    guard await dialogs.confirm(title, detail: detail, button: L("Move")) else { return }
    try await run(.immediate) { try await libraryLocation.move(plan) }
  }

  /// `cancelLibraryCopy`: stops the copy being prepared and removes what it copied.
  func cancelLibraryCopy() async throws {
    try await run(.immediate) { libraryLocation.cancel() }
  }

  /// `cancelLibraryMove`: forgets the move waiting for the next launch and removes its copy.
  func cancelLibraryMove() async throws {
    try await run(.immediate) { try libraryLocation.cancelPending() }
  }

  /// The banner line while the library's drive is disconnected and its wallpapers are stopped; nil
  /// while it is connected.
  var libraryDriveMessage: String? {
    libraryLocation.disconnectedRoot.map { root in
      L(
        "Wallpaper library unavailable: the drive that holds “\(root.path)” was disconnected, so its wallpapers stopped. They come back when you connect it again."
      )
    }
  }

  // MARK: Clearing

  /// Asks, then queues `operation`. Returns whether the user agreed.
  @discardableResult
  private func confirmedChange(
    _ title: String, detail: String, button: String, _ operation: @MainActor () async throws -> Void
  ) async throws -> Bool {
    errors.clearAction()
    guard await dialogs.confirm(title, detail: detail, button: button) else { return false }
    return try await run(.queued, operation)
  }

  /// `clearCache`: removes compiled shaders after a confirmation. They are rebuilt when wallpapers need them.
  func clearShaderCache() async throws {
    try await confirmedChange(
      L("Clear shader cache?"), detail: L("Shaders are rebuilt the next time wallpapers need them."),
      button: L("Clear Cache")
    ) { try await store.clearShaderCacheAsync() }
  }

  /// `clearLogs`: removes the diagnostic logs after a confirmation. Wallpapers and settings are not affected.
  func clearLogs() async throws {
    try await confirmedChange(
      L("Clear logs?"),
      detail: L("Only diagnostic logs are removed. Wallpapers and settings are not affected."),
      button: L("Clear Logs")
    ) { try store.clearLogsAsync() }
  }

  /// `purgeUnreferencedUserAssets`: removes the caches no manifest lists and the playable video
  /// copies nothing is reading now (`DerivedVideoCache`), after a confirmation, and remembers
  /// how much that released.
  ///
  /// Named for what it does: the manifest's files are user-imported originals that nothing can
  /// regenerate, so the confirmation says what is kept, not only what goes.
  func purgeUnreferencedUserAssets() async throws {
    try await confirmedChange(
      L("Clear unused caches?"),
      detail: L(
        "Only caches that can be rebuilt are removed. Files you chose in wallpaper settings are kept."),
      button: L("Clear Caches")
    ) {
      let copies = await Task.detached { DerivedVideoCache.shared.removeUnused() }.value
      let released = try await UserAssetStorage.purgeUnreferencedDerivedCaches() + copies
      // A negative figure would be a bug in the accounting, not a real amount, so it is reported as
      // nothing released rather than wrapped.
      userAssetsReleasedBytes = UInt64(max(0, released))
      refreshStorageMetrics(force: true)
    }
  }

  // MARK: Async storage metrics

  /// Triggers background measurement of the wallpaper library total size (reusing
  /// `LibraryMetricsService`), managed user-assets folder size, and library volume free space.
  /// Performs zero synchronous disk I/O on the main actor.
  func refreshStorageMetrics(force: Bool = false) {
    guard !isStopped else { return }
    let ids = store.librarySnapshot.wallpapers.map(\.id)
    _ = libraryMetrics.metrics(for: ids, revision: store.libraryRefreshRevision)
    guard force || storageMetricsTask == nil else { return }
    storageMetricsTask?.cancel()
    if !storageDiskMetrics.hasMeasured {
      storageDiskMetrics.isMeasuring = true
    }
    let libraryRoot = libraryLocation.current
    let userAssetsURL = UserAssetStorage.managedRootURL
    let volumes = storageVolumeInspector
    storageMetricsTask = Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) { () -> (UInt64, UInt64?) in
        let assetsBytes = Self.measureUserAssetsBytes(at: userAssetsURL)
        let freeBytes = Self.measureVolumeFreeBytes(for: libraryRoot, volumes: volumes)
        return (assetsBytes, freeBytes)
      }.value
      guard let self, !Task.isCancelled, !self.isStopped else { return }
      self.storageDiskMetrics = StorageDiskReading(
        userAssetsBytes: result.0, volumeFreeBytes: result.1, isMeasuring: false, hasMeasured: true)
      self.storageMetricsTask = nil
    }
  }

  nonisolated static func measureUserAssetsBytes(at url: URL) -> UInt64 {
    UInt64(max(0, StorageCopier.bytes(in: [url])))
  }

  nonisolated static func measureVolumeFreeBytes(
    for url: URL, volumes: any StorageVolumeInspecting
  ) -> UInt64? {
    var candidate = url
    let manager = FileManager.default
    while !manager.fileExists(atPath: candidate.path) {
      let parent = candidate.deletingLastPathComponent()
      if parent.path == candidate.path { break }
      candidate = parent
    }
    guard let available = try? volumes.volume(of: candidate).availableBytes, available >= 0 else {
      return nil
    }
    return UInt64(available)
  }

  // MARK: Diagnostics

  /// `exportDiagnostics`: asks where to save the report, writes it, and shows it in Finder. Nothing
  /// is written until a destination is chosen.
  func exportDiagnostics() async throws {
    errors.clearAction()
    let panel = NSSavePanel()
    panel.title = L("Export Diagnostics")
    panel.message = L("Attach this file to your bug report.")
    panel.nameFieldStringValue = DiagnosticsBundle.suggestedFileName(at: Date())
    panel.allowedContentTypes = [.zip]
    panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    guard let destination = await dialogs.choose(panel) else { return }
    try await run(.queued) {
      try await exportDiagnostics(to: destination)
      revealDiagnosticsReport(destination)
    }
  }

  /// Writes the diagnostics bundle off the main actor: reading and redacting up to 64 MB of logs
  /// must not stall the panel.
  func exportDiagnostics(to destination: URL) async throws {
    let settings = store.settingsSnapshot
    let throttle = settings.qualityThrottle.map { QualityCause($0).rawValue }.joined(separator: ", ")
    var environment = DiagnosticEnvironment.current()
    environment.append(
      """
      settings: scene resolution \(settings.sceneResolution), \
      render scale \(settings.renderScale) (preferred \(settings.preferredRenderScale)), battery mode \
      \(settings.batteryMode), frame-rate cap \(settings.frameRateCap.map(String.init) ?? "none"), on battery \
      \(settings.onBatteryPower), reduced quality for \(throttle.isEmpty ? "nothing" : throttle), effective \
      frame-rate cap \(settings.effectiveFrameRateCap.map(String.init) ?? "none"), verbose logging \
      \(settings.verboseLogging)
      """)
    for scene in settings.sceneRenderers {
      let mode = settings.sceneUpdateModes.first { $0.displayId == scene.displayId }?.mode
      environment.append(DiagnosticEnvironment.runningSceneLine(scene, mode: mode))
    }
    // Read once, here: the report is the only consumer, so nothing polls the window server.
    environment.append(contentsOf: DesktopWindowDiagnostics.current())
    environment.append(
      ProcessFootprint.reportLine(
        bytes: ProcessFootprint.current(),
        wallpaperWindows: WallpaperPresentationPolicy.wallpaperWindows().count))
    let bundle = DiagnosticsBundle(
      sources: DiagnosticsBundle.sources(logsRoot: try store.logFolderURL()),
      redactor: DiagnosticsRedactor(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
        userNames: [NSUserName(), NSFullUserName()],
        secrets: [workshop.downloader.savedAccount].compactMap { $0 }))
    let date = Date()
    let report = try await Task.detached(priority: .userInitiated) {
      try bundle.export(to: destination, environment: environment, at: date)
    }.value
    AppLog.info(
      """
      diagnostics exported: \(report.included.count) files\
      \(report.missing.isEmpty ? "" : "; not included: \(report.missing.joined(separator: "; "))")
      """)
  }

  // MARK: Backup

  // The backup actions are not queued and leave an older banner alone: the store has its own
  // busy flag, status and error, and refuses a second operation while one runs ("Another backup
  // operation is already running."). A failure sets the store's error and throws, so the banner
  // shows it too.

  /// `backupExport`: copies the settings and the files chosen for wallpapers, and the library when
  /// `includeLibrary`, to a package the user names.
  func exportBackup(includeLibrary: Bool) async throws {
    try await run(.immediate) { try await backup.export(includeLibrary: includeLibrary) }
  }

  /// `backupPreview`: asks for a package and reads what it holds and where it disagrees with this Mac.
  func previewBackup() async throws {
    try await run(.immediate) { try await backup.choosePreview() }
  }

  /// `backupRestore`: stages the previewed package to be restored at the next launch. Nothing changes
  /// now, and the app neither quits nor restarts.
  func restoreBackup(policy: WallpaperBackupConflictPolicy) async throws {
    try await run(.immediate) { try await backup.stageRestore(policy: policy) }
  }

  /// `backupCancel`: stops the operation that is running.
  func cancelBackup() async throws {
    try await run(.immediate) { backup.cancel() }
  }

  /// `backupCancelRestore`: removes a staged restore.
  func cancelPendingRestore() async throws {
    try await run(.immediate) { try backup.cancelRestore() }
  }

  // MARK: Storage health

  /// On-demand Storage Health center model, lazily initialized so app launch and normal Settings
  /// visits allocate and scan nothing until the user asks.
  var storageHealth: StorageHealthModel {
    if let existing = storageHealthModel { return existing }
    let created = StorageHealthModel(controller: self)
    storageHealthModel = created
    return created
  }

  /// Captures an immutable, Sendable snapshot of installed wallpapers, usage history and all
  /// reference sets on the main actor so background scanning performs zero UI-thread disk I/O.
  func makeStorageHealthInput(now: Date = Date()) -> LibraryStorageHealthService.Input {
    let displayTitlesByID = Dictionary(
      store.settingsSnapshot.displays.map { ($0.displayId, $0.title) },
      uniquingKeysWith: { first, _ in first })
    let wallpapers = store.librarySnapshot.wallpapers.map { entry in
      let measured = libraryMetrics.measured[entry.id]
      return LibraryStorageHealthService.WallpaperRecord(
        id: entry.id,
        title: entry.title,
        kind: entry.kind,
        cachedSizeBytes: measured?.size,
        addedAt: measured?.addedAt)
    }

    let activeDisplays = Set(
      store.monitorInformationSnapshot.rows.map(\.wallpaperId).filter { !$0.isEmpty })

    let collectionRefs = collections.collections.map {
      LibraryStorageHealthService.CollectionRef(
        id: $0.id, name: $0.name, wallpaperIDs: $0.wallpaperIDs)
    }
    let displayPlaylistRefs = playlists.playlists.map { displayID, playlist in
      LibraryStorageHealthService.DisplayPlaylistRef(
        displayID: displayID,
        displayTitle: displayTitlesByID[displayID] ?? displayID,
        wallpaperIDs: playlist.wallpaperIDs,
        dayWallpaperID: playlist.dayWallpaperID,
        nightWallpaperID: playlist.nightWallpaperID)
    }
    let playlistPlanRefs = playlists.plans.map { plan in
      LibraryStorageHealthService.PlaylistPlanRef(
        id: plan.id,
        name: plan.name,
        wallpaperIDs: plan.playlist.wallpaperIDs,
        dayWallpaperID: plan.playlist.dayWallpaperID,
        nightWallpaperID: plan.playlist.nightWallpaperID)
    }
    let automationRefs = automations.configurations.map { displayID, configuration in
      LibraryStorageHealthService.AutomationRef(
        displayID: displayID,
        displayTitle: displayID == WallpaperAutomationStore.globalDisplayID
          ? L("All displays") : (displayTitlesByID[displayID] ?? displayID),
        mode: configuration.mode,
        usesSpaces: configuration.usesSpaces,
        ruleWallpaperIDs: configuration.rules.compactMap {
          $0.target.kind == .wallpaper ? $0.target.id : nil
        },
        enabledRuleWallpaperIDs: configuration.rules.compactMap {
          $0.isEnabled && $0.target.kind == .wallpaper ? $0.target.id : nil
        },
        lightWallpaperID: configuration.light?.kind == .wallpaper ? configuration.light?.id : nil,
        darkWallpaperID: configuration.dark?.kind == .wallpaper ? configuration.dark?.id : nil,
        batteryWallpaperID: configuration.batteryTarget?.kind == .wallpaper
          ? configuration.batteryTarget?.id : nil,
        spaceWallpaperIDs: configuration.spaces.compactMapValues {
          $0.kind == .wallpaper ? $0.id : nil
        })
    }
    let appRuleWallpaperIDs = Set(
      playback.appRules.compactMap { rule -> String? in
        guard rule.action == .switchWallpaper, rule.wallpaperTarget?.kind == .wallpaper else {
          return nil
        }
        return rule.wallpaperTarget?.id
      })
    let layoutRefs = displayLayouts.layouts.map { layout in
      LibraryStorageHealthService.DisplayLayoutRef(
        id: layout.id,
        name: layout.name,
        wallpaperIDs: layout.assignments.map(\.wallpaperID))
    }
    let presetRefs = presets.items.map { preset in
      LibraryStorageHealthService.PresetRef(
        id: preset.id, name: preset.name, wallpaperID: preset.wallpaperID)
    }

    var lockScreenIDs = Set<String>()
    if let liveLock = store.lockScreenWallpaper {
      lockScreenIDs.formUnion(liveLock.lockScreenSources.referencedWallpaperIDs)
    } else {
      if let data = defaults.data(forKey: LockScreenWallpaperService.lockScreenSourcesPreference),
        let decoded = try? LockScreenModeSources.decode(data)
      {
        lockScreenIDs.formUnion(decoded.referencedWallpaperIDs)
      }
      if let savedLock = defaults.string(forKey: "WallpaperMachineLockScreenWallpaperID"),
        !savedLock.isEmpty
      {
        lockScreenIDs.insert(savedLock)
      }
    }
    var screenSaverIDs = Set<String>()
    if let liveSaver = store.lockScreenWallpaper {
      screenSaverIDs.formUnion(liveSaver.screenSaverSources.referencedWallpaperIDs)
    } else {
      if let data = defaults.data(forKey: LockScreenWallpaperService.screenSaverSourcesPreference),
        let decoded = try? LockScreenModeSources.decode(data)
      {
        screenSaverIDs.formUnion(decoded.referencedWallpaperIDs)
      }
      if let savedSaver = defaults.string(forKey: "WallpaperMachineScreenSaverWallpaperID"),
        !savedSaver.isEmpty
      {
        screenSaverIDs.insert(savedSaver)
      }
    }

    let references = LibraryStorageHealthService.ReferenceSnapshot(
      activeDisplayWallpaperIDs: activeDisplays,
      favoriteIDs: favoriteIDs,
      collections: collectionRefs,
      displayPlaylists: displayPlaylistRefs,
      playlistPlans: playlistPlanRefs,
      automations: automationRefs,
      appRuleWallpaperIDs: appRuleWallpaperIDs,
      displayLayouts: layoutRefs,
      metadataWallpaperIDs: Set(metadata.entries.keys),
      presets: presetRefs,
      lockScreenWallpaperIDs: lockScreenIDs,
      screenSaverWallpaperIDs: screenSaverIDs)

    return LibraryStorageHealthService.Input(
      libraryURL: ClientPaths.libraryURL,
      sceneStorageURL: ClientPaths.sceneStorageURL,
      spacePosterCacheURL: ClientPaths.spacePosterCacheURL,
      now: now,
      wallpapers: wallpapers,
      lastUsedDates: store.history.lastUsedDates(),
      references: references)
  }

  /// Opens the Storage Health sheet and starts an on-demand scan if no report is ready yet.
  func openStorageHealth() async throws {
    try await run(.direct) {
      storageHealth.openAndScan()
    }
  }

  /// Starts or restarts an on-demand Storage Health scan.
  func scanStorageHealth() async throws {
    try await run(.direct) {
      await storageHealth.scanNow()
    }
  }

  /// Cancels an in-progress Storage Health scan.
  func cancelStorageHealthScan() async throws {
    try await run(.direct) {
      storageHealth.cancelScan()
    }
  }

  /// Moves selected wallpapers from Storage Health to the Trash through `WallpaperDeletionService`
  /// (never permanently deleting user wallpapers), updates library stores, and refreshes metrics.
  /// Returns nil when the user declines the confirmation dialog.
  @discardableResult
  func trashStorageHealthWallpapers(_ ids: [String]) async throws -> WallpaperDeletionReport? {
    var result: WallpaperDeletionReport?
    try await run(.direct) {
      let validIDs = try installedWallpaperIDs(ids)
      let name = store.librarySnapshot.wallpapers.first { $0.id == validIDs[0] }?.title ?? validIDs[0]
      let title =
        validIDs.count == 1
        ? L("Move \(name) to Trash?") : L("Move \(validIDs.count) wallpapers to Trash?")
      guard
        await dialogs.confirm(
          title,
          detail: L(
            "Affected displays switch to another available wallpaper when possible. The original files you imported are not affected."
          ),
          button: L("Move to Trash"))
      else { return }
      let slots = store.settingsSnapshot.displays.filter(\.isIndependent).map {
        BridgeStore.activationSlot(displayId: $0.displayId)
      }
      try await store.commands.run(choosing: slots) {
        let report = try await store.deleteWallpapersAsync(
          ids: validIDs, recycle: recycleWallpaperFolder)
        result = report
        if !report.deleted.isEmpty {
          storageHealthModel?.recordDeletedWallpapers(Set(report.deleted))
          try await forgetLibraryMetadata(report.deleted)
          refreshStorageMetrics(force: true)
        }
        if !report.failures.isEmpty {
          let titles = Dictionary(
            store.librarySnapshot.wallpapers.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
          let details = report.failures.map {
            "\(titles[$0.id] ?? $0.id): \($0.error.localizedDescription)"
          }
          let message = L(
            "Moved \(report.deleted.count) of \(validIDs.count) wallpapers to Trash. Couldn’t move \(details.joined(separator: "; "))"
          )
          if let playback = report.playbackError {
            throw WallpaperActionError(message: "\(message)\n\n\(playback.localizedDescription)")
          }
          throw WallpaperActionError(message: message)
        }
        if let playback = report.playbackError { throw playback }
      }
    }
    return result
  }

  /// Repairs dangling wallpaper IDs across persisted stores (Favorites, Collections, Playlists,
  /// Automations, Metadata, Presets, Display Layouts) in one step.
  @discardableResult
  func repairBrokenReferences(
    _ items: [LibraryStorageHealthService.BrokenReferenceItem]
  ) async throws -> Int {
    guard !items.isEmpty else { return 0 }
    var repairedIDs = Set<String>()
    var firstError: Error?
    try await run(.direct) {
      let grouped = Dictionary(grouping: items, by: \.source)
      for source in LibraryStorageHealthService.BrokenReferenceSource.allCases {
        guard let entries = grouped[source], !entries.isEmpty else { continue }
        let missingIDs = Array(Set(entries.map(\.wallpaperID))).sorted()
        do {
          switch source {
          case .favorites:
            try forgetFavorites(missingIDs)
          case .collections:
            try collections.forget(missingIDs)
          case .playlists:
            playlists.forget(missingIDs)
          case .automation:
            try automations.forgetWallpapers(Set(missingIDs))
          case .metadata:
            metadata.forget(missingIDs)
          case .presets:
            try await presets.forget(wallpaperIDs: missingIDs)
          case .displayLayouts:
            try displayLayouts.pruneWallpapers(Set(missingIDs))
          }
          repairedIDs.formUnion(entries.map(\.id))
        } catch {
          firstError = firstError ?? error
        }
      }
      if !repairedIDs.isEmpty {
        storageHealthModel?.recordRepairedBrokenReferences(repairedIDs)
      }
      if let firstError { throw firstError }
    }
    return repairedIDs.count
  }

  /// Safely removes verified orphaned `SceneStorage` directories and `SpacePosters` cache files
  /// after user confirmation. Returns nil when cancelled.
  @discardableResult
  func cleanOrphanedStorage(
    _ items: [LibraryStorageHealthService.OrphanedStorageItem]
  ) async throws -> LibraryStorageHealthService.OrphanCleanupReport? {
    guard !items.isEmpty else { return nil }
    var outcome: LibraryStorageHealthService.OrphanCleanupReport?
    try await run(.direct) {
      guard
        await dialogs.confirm(
          L("Remove orphaned storage?"),
          detail: L(
            "Only unused internal scene data and cached Space posters with no matching wallpaper are removed. Installed wallpapers and settings are not affected."
          ),
          button: L("Remove"))
      else { return }
      let report = try await storageHealth.service.cleanOrphanedStorage(
        items,
        sceneStorageURL: ClientPaths.sceneStorageURL,
        spacePosterCacheURL: ClientPaths.spacePosterCacheURL)
      outcome = report
      if !report.removedIDs.isEmpty {
        storageHealthModel?.recordCleanedOrphans(Set(report.removedIDs))
        refreshStorageMetrics(force: true)
      }
      if !report.failures.isEmpty {
        let details = report.failures.map { "\($0.name): \($0.message)" }.joined(separator: "; ")
        throw WallpaperActionError(
          message: L("Some orphaned storage items could not be removed: \(details)"))
      }
    }
    return outcome
  }
}
