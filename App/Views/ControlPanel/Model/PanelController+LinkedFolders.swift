import AppKit
import Foundation

/// Linking folders of the user's own wallpapers to the library (docs/features/linked-folders.md).
extension PanelController {
  var linkedFolderRows: [LinkedFolderRow] {
    linkedFolders.folders.map { LinkedFolderRow.make($0, status: linkedFolders.status(of: $0.id)) }
  }

  /// `linkFolder`: asks for a folder in a sheet and links it; what it holds is imported once each
  /// file has finished copying. A cancelled pick, or a panel with no window, links nothing.
  func linkFolder() async throws {
    try await run(.direct) {
      let panel = NSOpenPanel()
      panel.title = L("Link a Folder")
      panel.message = L("New wallpapers you put in this folder are added to the library.")
      panel.prompt = L("Link")
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      guard let url = await dialogs.choose(panel), !isStopped else { return }
      try await linkedFolders.add(url)
    }
  }

  /// `unlinkFolder`: stops following the folder. Its wallpapers stay in the library.
  func unlinkFolder(_ id: UUID) async throws {
    try await run(.direct) { try await linkedFolders.unlink(id) }
  }

  /// `linkedFolderMirrorsDeletions`: whether a file deleted from the folder leaves the library.
  func setLinkedFolderMirrorsDeletions(_ on: Bool, for id: UUID) async throws {
    try await run(.immediate) { try await linkedFolders.setMirrorsDeletions(on, for: id) }
  }

  /// `linkedFolderRemoveHeld`: after a confirmation, moves the wallpapers whose files left the
  /// folder at once to the Trash: those the sheet counted, never more that left while it was open.
  func removeHeldLinkedFolderWallpapers(_ id: UUID) async throws {
    try await run(.direct) {
      let held = linkedFolders.status(of: id).held
      guard !held.isEmpty else { return }
      guard
        await dialogs.confirm(
          L("Move \(held.count) wallpapers to Trash?"),
          detail: L(
            "Affected displays switch to another available wallpaper when possible. The original files you imported are not affected."
          ),
          button: L("Move to Trash"))
      else { return }
      try await linkedFolders.removeHeld(held, for: id)
    }
  }

  /// `linkedFolderKeepHeld`: keeps the wallpapers whose files left the folder at once.
  func keepHeldLinkedFolderWallpapers(_ id: UUID) async throws {
    try await run(.direct) { try await linkedFolders.keepHeld(for: id) }
  }
}
