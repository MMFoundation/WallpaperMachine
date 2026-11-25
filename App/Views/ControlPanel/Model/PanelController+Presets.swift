import AppKit
import Foundation
import UniformTypeIdentifiers

/// The property presets of the selected wallpaper, as the presets bar shows them.
struct PresetsState: Equatable {
  struct Item: Equatable, Identifiable {
    let id: String
    let name: String
  }

  let wallpaperID: String
  /// The wallpaper's saved presets, in the store's order.
  let items: [Item]
  /// The wallpaper has changes that Apply changes would save (or typed text on its way): a preset
  /// can be neither saved nor applied until they are applied or reverted.
  let isDirty: Bool
  /// Saving is possible: the options are supported and clean, nothing is being edited, applied or
  /// run, the preset store itself is healthy, and nothing is unsent.
  let canSave: Bool
  /// Applying pending edits and saving them as a new preset is possible: the options are supported
  /// and dirty, nothing is being edited, applied or run, and the preset store itself is healthy.
  let canApplyAndSave: Bool
  /// What the last preset action did, in a sentence. The store clears it whenever the list changes.
  let status: String?
  /// Why the stored presets could not be read; the only error the card shows beside its controls.
  let error: String?

  init(
    wallpaperID: String, items: [Item], isDirty: Bool, canSave: Bool,
    canApplyAndSave: Bool = false, status: String?, error: String?
  ) {
    self.wallpaperID = wallpaperID
    self.items = items
    self.isDirty = isDirty
    self.canSave = canSave
    self.canApplyAndSave = canApplyAndSave
    self.status = status
    self.error = error
  }
}

/// Property presets: save the values a wallpaper is using now, apply one, update one, rename,
/// delete, export and import. Every action is queued, and its whole validated edit-and-apply
/// sequence runs inside one turn of the command queue, so nothing can come between the checks and
/// the work. A failure reaches the banner; a result is the store's `status`.
extension PanelController {
  /// The presets bar for the selected installed wallpaper, or nil with none.
  var presetsState: PresetsState? {
    _ = revisions.presets
    guard let id = selectedInstalledWallpaperID else { return nil }
    let options = store.wallpaperOptionsSnapshot.flatMap { $0.wallpaperId == id ? $0 : nil }
    let inFlight =
      !(pendingPropertyValues[id] ?? [:]).isEmpty
      || !(pendingEngineOptionValues[id] ?? [:]).isEmpty
    let pending = store.editorState.hasPendingEdits(wallpaperID: id) || inFlight
    let isDirty = options?.dirty == true || pending
    let ready =
      options?.supported == true
      && !store.isWallpaperEditInProgress(id: id) && !store.commands.isBusy
      && store.activatingWallpaperID == nil && store.applyingWallpaperID == nil
      && presets.error == nil
    return PresetsState(
      wallpaperID: id,
      items: presets.presets(wallpaperID: id).map { PresetsState.Item(id: $0.id, name: $0.name) },
      isDirty: isDirty,
      canSave: ready && options?.dirty == false && !pending,
      canApplyAndSave: ready && isDirty && !inFlight,
      status: presets.status,
      error: presets.error)
  }

  /// `wallpaperPresetSave`: saves the values the wallpaper is using now as a new preset. Needs a
  /// clean, supported, applied state and a name of 1 to 120 characters. Returns the new preset's
  /// id, which the bar picks, or nil when the store reports none.
  @discardableResult
  func savePreset(_ wallpaperID: String, name: String) async throws -> String? {
    var created: String?
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      let pending =
        store.editorState.hasPendingEdits(wallpaperID: id) || store.isWallpaperEditInProgress(id: id)
      let saved = try await presets.save(name: name, options: options, hasPendingEdits: pending)
      presets.status = L("Saved the applied wallpaper properties.")
      created = saved.id
    }
    return created
  }

  /// Applies pending wallpaper edits first and then saves the newly applied values as a new preset,
  /// preserving `WallpaperPresetStore.save`'s clean-state and managed-asset invariants.
  @discardableResult
  func applyAndSavePreset(_ wallpaperID: String, name: String) async throws -> String? {
    var created: String?
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      _ = try WallpaperPresetStore.validateName(name)
      let drafts = store.editorState.propertyTextDrafts.filter { $0.key.wallpaperID == id }
      guard drafts.values.allSatisfy({ $0.count <= PanelValueRules.maximumTextLength }) else {
        throw InvalidControlValue()
      }
      let current = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      if current.dirty || store.editorState.hasPendingEdits(wallpaperID: id) {
        try await store.applyWallpaperOptionsAsync(wallpaperId: id, userInitiated: true)
      }
      let applied = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      let pending =
        store.editorState.hasPendingEdits(wallpaperID: id) || store.isWallpaperEditInProgress(id: id)
      let saved = try await presets.save(name: name, options: applied, hasPendingEdits: pending)
      presets.status = L("Applied changes and saved preset “\(saved.name)”.")
      created = saved.id
    }
    reconcileInspectorContext()
    return created
  }

  /// Overwrites an existing preset with the values the wallpaper is using now. Needs a clean,
  /// supported, applied state and a preset belonging to the wallpaper.
  func updatePreset(_ wallpaperID: String, preset presetID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let existing = try presets.preset(id: presetID)
      guard existing.wallpaperID == id else { throw InvalidControlValue() }
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      let pending =
        store.editorState.hasPendingEdits(wallpaperID: id) || store.isWallpaperEditInProgress(id: id)
      let updated = try await presets.update(
        id: existing.id, options: options, hasPendingEdits: pending)
      presets.status = L("Updated preset “\(updated.name)”.")
    }
  }

  /// `wallpaperPresetRename`.
  func renamePreset(_ presetID: String, to name: String) async throws {
    try await run(.queued) {
      try presets.rename(id: presetID, name: name)
    }
  }

  /// `wallpaperPresetDelete`: re-checks that the preset's wallpaper is clean, then deletes it. A
  /// folder the applied wallpaper still uses is kept.
  func deletePreset(_ presetID: String) async throws {
    try await run(.queued) {
      let preset = try presets.preset(id: presetID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: preset.wallpaperID)
      try presets.requireClean(
        options,
        hasPendingEdits: store.editorState.hasPendingEdits(wallpaperID: preset.wallpaperID)
          || store.isWallpaperEditInProgress(id: preset.wallpaperID))
      try await presets.delete(
        id: preset.id, preservingPaths: WallpaperPresetStore.resourcePaths(options))
    }
  }

  /// `wallpaperPresetApply`: validates every saved value against the wallpaper's current types and
  /// choices, stages the edits and applies; a failure reverts the draft.
  func applyPreset(_ wallpaperID: String, preset presetID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let preset = try presets.preset(id: presetID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      try await presets.apply(preset, options: options, bridge: store, userInitiated: true)
      presets.status = L("Property preset applied.")
    }
    reconcileInspectorContext()
  }

  /// `wallpaperPresetExport`: writes the preset as a file the user can share or keep. The save panel
  /// is open inside the command's turn, as before; Cancel returns quietly. The preset must belong to
  /// the wallpaper.
  func exportPreset(_ wallpaperID: String, preset presetID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let preset = try presets.preset(id: presetID)
      guard preset.wallpaperID == id else { throw InvalidControlValue() }
      let data = try await presets.exportDocument(id: preset.id)
      let name = "wallpaper-properties.json"
      let url: URL?
      if let choose = presets.chooseExportFile {
        url = await choose(name)
      } else {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Property Preset")
        panel.message = String(
          localized: "Managed assets up to 32 MB are bundled. External file references are not portable."
        )
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name
        url = await dialogs.choose(panel)
      }
      guard let url else { return }
      try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
      presets.status = L(
        "Property preset exported. External file references require choosing the files again after import."
      )
    }
  }

  /// `wallpaperPresetImport`: adds a preset from a file the user picks. The file must be a regular
  /// file, not a symlink, and at most 48 MiB, and is read off the main actor. The preset is saved
  /// and never applied.
  func importPreset(into wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let url: URL?
      if let choose = presets.chooseImportFile {
        url = await choose()
      } else {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Property Preset")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        url = await dialogs.choose(panel)
      }
      guard let url else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      // What the user picked is theirs to get wrong: an alias or a file that is too large is
      // refused with what a preset file has to be, not as a control sending nonsense.
      let megabytes = WallpaperPresetStore.maximumDocumentBytes / (1024 * 1024)
      let refusal = WallpaperActionError(
        message: L("Choose a property preset file, not an alias of one, of at most \(megabytes) MB."))
      let data = try await Task.detached(priority: .utility) {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size <= WallpaperPresetStore.maximumDocumentBytes
        else { throw refusal }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= WallpaperPresetStore.maximumDocumentBytes else { throw refusal }
        return data
      }.value
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      _ = try await presets.importDocument(data, options: options)
      presets.status = L("Property preset imported. Apply it to change this wallpaper.")
    }
  }
}
