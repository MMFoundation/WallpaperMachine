import Foundation

extension PanelController {
  // MARK: Derived state

  /// User metadata (custom tags, star rating, note, rotation exclusion) for `id`.
  func wallpaperMetadata(for id: String) -> WallpaperMetadata {
    _ = revisions.metadata
    return metadata.metadata(for: id)
  }

  /// Every custom tag currently assigned across installed wallpapers.
  var allCustomTags: [String] {
    _ = revisions.metadata
    return metadata.allCustomTags
  }

  // MARK: Actions

  /// `metadataRating`: sets the wallpaper's 1–5 star rating, or nil to clear it.
  func setWallpaperRating(_ rating: Int?, for id: String) async throws {
    if let rating, !WallpaperMetadata.ratingRange.contains(rating) { throw InvalidControlValue() }
    try await run(.immediate) {
      let id = try installedWallpaperID(id)
      metadata.setRating(rating, for: id)
    }
  }

  /// `metadataAddTag`: appends a custom tag to `id` (deduplicated case-insensitively).
  func addWallpaperTag(_ tag: String, to id: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(id)
      try metadata.addTag(tag, to: id)
    }
  }

  /// `metadataRemoveTag`: removes a custom tag from `id`.
  func removeWallpaperTag(_ tag: String, from id: String) async throws {
    try await run(.immediate) {
      metadata.removeTag(tag, from: id)
    }
  }

  /// `metadataNote`: sets or clears the wallpaper's short user note.
  func setWallpaperNote(_ note: String?, for id: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(id)
      try metadata.setNote(note, for: id)
    }
  }

  /// `metadataExclude`: excludes or re-includes `id` in automatic playlists and Random Wallpaper.
  func setWallpaperExcludedFromRotation(_ excluded: Bool, for id: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(id)
      metadata.setExcludedFromRotation(excluded, for: id)
    }
  }
}
