import Foundation

/// Moving wallpapers to the Trash and forgetting everything the app kept about them.
extension PanelController {
  /// `delete`: asks first, trashes the managed copy and replaces it on affected displays,
  /// then forgets its metadata. A panel with no window cannot ask, so it deletes nothing.
  ///
  /// The confirmation is asked before queueing, so an open sheet holds up nothing else.
  func delete(_ id: String) async throws {
    try await run(.direct) {
      let id = try installedWallpaperID(id)
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
      guard
        await dialogs.confirm(
          L("Move \(title) to Trash?"),
          detail: L(
            "Affected displays switch to another available wallpaper when possible. The original files you imported are not affected."
          ),
          button: L("Move to Trash"))
      else { return }
      try await store.commands.run(choosing: deletionDisplaySlots) {
        let report = try await store.deleteWallpapersAsync(ids: [id], recycle: recycleWallpaperFolder)
        try await forgetLibraryMetadata(report.deleted)
        if let failure = report.failures.first {
          throw deletionError(failure.error, playback: report.playbackError)
        }
        if let error = report.playbackError { throw error }
      }
    }
  }

  /// `deleteMany`: the same for a selection. Wallpapers that could not be moved are reported after
  /// the ones that could have been cleaned up.
  func deleteMany(_ ids: [String]) async throws {
    try await run(.direct) {
      let ids = try installedWallpaperIDs(ids)
      let name = store.librarySnapshot.wallpapers.first { $0.id == ids[0] }?.title ?? ids[0]
      let title = ids.count == 1 ? L("Move \(name) to Trash?") : L("Move \(ids.count) wallpapers to Trash?")
      guard
        await dialogs.confirm(
          title,
          detail: L(
            "Affected displays switch to another available wallpaper when possible. The original files you imported are not affected."
          ),
          button: L("Move to Trash"))
      else { return }
      try await store.commands.run(choosing: deletionDisplaySlots) {
        let report = try await store.deleteWallpapersAsync(ids: ids, recycle: recycleWallpaperFolder)
        try await forgetLibraryMetadata(report.deleted)
        if !report.failures.isEmpty {
          let titles = Dictionary(
            store.librarySnapshot.wallpapers.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
          let details = report.failures.map {
            "\(titles[$0.id] ?? $0.id): \($0.error.localizedDescription)"
          }
          throw deletionError(WallpaperActionError(
            message: L(
              "Moved \(report.deleted.count) of \(ids.count) wallpapers to Trash. Couldn’t move \(details.joined(separator: "; "))"
            )), playback: report.playbackError)
        }
        if let error = report.playbackError { throw error }
      }
    }
  }

  /// The same removal as `deleteMany`, without asking, for wallpapers whose files left a linked
  /// folder with Mirror deletions on (`LinkedFolderCoordinator`); a large share was already
  /// confirmed in Settings. `stillDue` is asked in the command queue's turn, just before
  /// anything moves, and only ids it still names are removed. Ids no longer installed count as
  /// removed. Answers the removed ids; one that could not be moved stays due.
  func removeLinkedFolderWallpapers(
    _ ids: [String], destinations: [String: LinkedFolderDestinationIdentity],
    stillDue: @escaping @MainActor () -> Set<String>
  ) async throws -> [String] {
    var removed: [String] = []
    try await store.commands.run(choosing: deletionDisplaySlots) {
      let current = stillDue()
      let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
      let wanted = ids.filter(current.contains)
      removed = wanted.filter { !installed.contains($0) }
      var due: [String] = []
      for id in wanted.filter(installed.contains).prefix(Self.batchLimit) {
        guard let expected = destinations[id] else { removed.append(id); continue }
        guard let actual = LinkedFolderDestinationIdentity.read(ClientPaths.libraryURL.appendingPathComponent(id)) else { continue }
        if actual == expected { due.append(id) } else { removed.append(id) }
      }
      guard !due.isEmpty else { return }
      let report = try await store.deleteWallpapersAsync(ids: due) { url in
        let id = url.lastPathComponent
        guard stillDue().contains(id), let expected = destinations[id],
              LinkedFolderDestinationIdentity.read(url) == expected else { throw CancellationError() }
        try recycleWallpaperFolder(url)
      }
      removed += report.deleted
      try await forgetLibraryMetadata(report.deleted)
      for failure in report.failures {
        AppLog.warn("linked folders: could not move \(failure.id) to Trash: \(failure.error.localizedDescription)")
      }
      if let error = report.playbackError { throw error }
    }
    return removed
  }

  /// Deletion can affect every independent display. Automatic choices give way while its
  /// ejections and replacements run; a later user choice still runs after the deletion.
  private var deletionDisplaySlots: [String] {
    store.settingsSnapshot.displays.filter(\.isIndependent).map {
      BridgeStore.activationSlot(displayId: $0.displayId)
    }
  }

  private func deletionError(_ deletion: Error, playback: Error?) -> Error {
    guard let playback else { return deletion }
    return WallpaperActionError(message: "\(deletion.localizedDescription)\n\n\(playback.localizedDescription)")
  }

  /// Everything the app kept about wallpapers that are gone: favorites, playlist entries,
  /// automation rules, history, update marks, collection membership, saved presets and image
  /// placements. Every cleanup runs even when one throws, and the first error is the one raised.
  func forgetLibraryMetadata(_ ids: [String]) async throws {
    var firstError: Error?
    do { try forgetFavorites(ids) } catch { firstError = error }
    playlists.forget(ids)
    do { try automations.forgetWallpapers(Set(ids)) } catch { firstError = firstError ?? error }
    store.history.forget(Set(ids))
    workshop.updates.forget(ids)
    do { try collections.forget(ids) } catch { firstError = firstError ?? error }
    metadata.forget(ids)
    do { try await presets.forget(wallpaperIDs: ids) } catch { firstError = firstError ?? error }
    do { try imagePlacement.forget(Set(ids)) } catch { firstError = firstError ?? error }
    userShortcuts.removeAll(for: Set(ids))
    do { try videoTrim.forget(Set(ids)) } catch { firstError = firstError ?? error }
    if let firstError { throw firstError }
  }
}
