import Foundation

/// What Settings › Library & Steam shows of one linked folder.
struct LinkedFolderRow: Identifiable, Equatable {
  let id: UUID
  let path: String
  let mirrorsDeletions: Bool
  /// Wallpapers this link imported whose files are still in the folder.
  let wallpaperCount: Int
  /// Wallpapers kept in the library although their files left the folder.
  let missingCount: Int
  /// Wallpapers whose files left at once in a number that waits for the user's go-ahead.
  let heldCount: Int
  let isUnavailable: Bool
  let failure: String?

  static func make(_ folder: LinkedFolder, status: LinkedFolderCoordinator.Status) -> LinkedFolderRow {
    let owned = folder.record.entries.filter(\.owned)
    return LinkedFolderRow(
      id: folder.id, path: folder.path, mirrorsDeletions: folder.mirrorsDeletions,
      wallpaperCount: owned.filter { $0.state == .present }.count,
      missingCount: owned.filter { $0.state == .missing }.count,
      heldCount: status.held.count, isUnavailable: status.isUnavailable, failure: status.failure)
  }
}
