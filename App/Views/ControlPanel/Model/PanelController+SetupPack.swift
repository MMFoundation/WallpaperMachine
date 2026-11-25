import AppKit
import CoreGraphics
import Foundation

/// What the user chose to include when exporting a lightweight `.wmpack` setup pack.
struct SetupPackExportSelection: Equatable, Sendable {
  var name: String = ""
  var includeActiveWallpapers: Bool = true
  var selectedPresetIDs: Set<String> = []
  var selectedWidgetIDs: Set<String> = []
  var selectedLayoutIDs: Set<String> = []
}

/// Snapshot of exportable presets, portable widgets, layouts and active Workshop wallpapers.
struct SetupPackExportCandidates: Equatable, Sendable {
  var activeWorkshopIDs: [String]
  var presets: [WallpaperPropertyPreset]
  var widgets: [DesktopWidget]
  var layouts: [WallpaperDisplayLayout]

  var defaultSelection: SetupPackExportSelection {
    SetupPackExportSelection(
      name: "",
      includeActiveWallpapers: !activeWorkshopIDs.isEmpty,
      selectedPresetIDs: Set(presets.map(\.id)),
      selectedWidgetIDs: Set(widgets.map(\.id)),
      selectedLayoutIDs: Set(layouts.map(\.id)))
  }

  var hasAnyContent: Bool {
    !activeWorkshopIDs.isEmpty || !presets.isEmpty || !widgets.isEmpty || !layouts.isEmpty
  }
}

/// Typed Setup Pack (`.wmpack`) actions on `PanelController`.
///
/// Export builds a compact, strictly sanitized JSON file with zero media binaries, zero Steam
/// credentials and zero machine-local Space UUIDs. Import validates strictly before previewing,
/// remaps displays to this Mac's connected displays, requires explicit confirmation before queueing
/// any Workshop download, and applies chosen components in place with no restart.
extension PanelController {
  /// Connected independent displays formatted as source/target descriptors for Setup Pack export
  /// and display remapping.
  var connectedSetupPackDisplays: [SetupPackTargetDisplay] {
    let screens = desktopWidgetScreens()
    let rows = standaloneDisplayRows
    if rows.isEmpty {
      return screens.map { screen in
        SetupPackTargetDisplay(
          displayID: screen.isMain ? "primary" : String(screen.displayID),
          displayUUID: screen.uuid,
          title: screen.name,
          isPrimary: screen.isMain,
          width: Int(screen.frame.width.rounded()),
          height: Int(screen.frame.height.rounded()))
      }
    }
    return rows.map { row in
      let liveID = ResolvedDisplayTitles.liveDisplayID(row.id, title: row.title)
        ?? (row.isPrimary ? CGMainDisplayID() : nil)
      let screen = screens.first { screen in
        if let liveID, screen.displayID == liveID { return true }
        return row.isPrimary && screen.isMain
      }
      let uuid = screen?.uuid ?? liveID.flatMap(Self.displayUUIDString(for:))
      return SetupPackTargetDisplay(
        displayID: row.id,
        displayUUID: uuid,
        title: row.title,
        isPrimary: row.isPrimary || screen?.isMain == true,
        width: screen.map { Int($0.frame.width.rounded()) },
        height: screen.map { Int($0.frame.height.rounded()) })
    }
  }

  /// Current presets, widgets, display layouts and active Workshop wallpapers available to export.
  var setupPackExportCandidates: SetupPackExportCandidates {
    _ = revisions.presets
    _ = revisions.displayLayouts
    let activeIDs = standaloneDisplayRows.compactMap(\.wallpaperID).compactMap(SetupPackService.validatedWorkshopID)
    var seenActive = Set<String>()
    let uniqueActive = activeIDs.filter { seenActive.insert($0).inserted }
    return SetupPackExportCandidates(
      activeWorkshopIDs: uniqueActive,
      presets: presets.items,
      widgets: desktopWidgets.widgets,
      layouts: displayLayouts.layouts)
  }

  /// Exports a sanitized `.wmpack` file containing the chosen components. When `destination` is nil,
  /// asks the user where to save via `NSSavePanel`.
  func exportSetupPack(
    selection: SetupPackExportSelection,
    destination: URL? = nil,
    service: SetupPackService? = nil
  ) async throws -> SetupPackExportReport? {
    errors.clearAction()
    let resolvedDestination: URL
    if let destination {
      resolvedDestination = destination
    } else {
      let panel = NSSavePanel()
      panel.title = L("Export Setup Pack")
      panel.message = L(
        "Exports Workshop wallpaper IDs, sanitized property presets, portable widgets and display layouts as a compact .wmpack file. Media files, Steam sign-ins and macOS Space IDs are never included."
      )
      panel.nameFieldStringValue = Self.suggestedSetupPackFileName(named: selection.name)
      panel.allowedContentTypes = [SetupPackService.contentType]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      guard let chosen = await dialogs.choose(panel) else { return nil }
      resolvedDestination = chosen
    }

    var report: SetupPackExportReport?
    try await run(.immediate) {
      let input = makeSetupPackExportInput(selection: selection)
      let exporter = service ?? SetupPackService(
        supportRoot: ClientPaths.supportURL,
        storageRoot: ClientPaths.storageURL)
      let scoped = resolvedDestination.startAccessingSecurityScopedResource()
      defer { if scoped { resolvedDestination.stopAccessingSecurityScopedResource() } }
      report = try await Task.detached(priority: .utility) {
        try exporter.export(to: resolvedDestination, input: input)
      }.value
    }
    return report
  }

  /// Opens a file picker (unless `url` is supplied) and strictly validates a `.wmpack` file,
  /// returning a preview with installed vs missing Workshop items and suggested display mapping.
  func previewSetupPack(
    at url: URL? = nil,
    service: SetupPackService? = nil
  ) async throws -> SetupPackPreview? {
    errors.clearAction()
    let sourceURL: URL
    if let url {
      sourceURL = url
    } else {
      let panel = NSOpenPanel()
      panel.title = L("Import Setup Pack")
      panel.message = L(
        "Choose a .wmpack file to review its wallpapers, display mapping and components before anything is applied."
      )
      panel.allowedContentTypes = [SetupPackService.contentType]
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      guard let chosen = await dialogs.choose(panel) else { return nil }
      sourceURL = chosen
    }

    var preview: SetupPackPreview?
    try await run(.immediate) {
      let installedIDs = Set(store.librarySnapshot.wallpapers.map(\.id))
      let connected = connectedSetupPackDisplays
      let reader = service ?? SetupPackService(
        supportRoot: ClientPaths.supportURL,
        storageRoot: ClientPaths.storageURL)
      let scoped = sourceURL.startAccessingSecurityScopedResource()
      defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
      preview = try await Task.detached(priority: .utility) {
        try reader.preview(
          fileAt: sourceURL,
          installedWallpaperIDs: installedIDs,
          connectedDisplays: connected)
      }.value
    }
    return preview
  }

  /// Applies the user's chosen components from `preview` cleanly in place (no app restart, no
  /// clobbering unrelated settings).
  ///
  /// Missing Workshop items are NEVER downloaded unless `options.queueMissingDownloadsConfirmed`
  /// is true AND confirmed by the user (`requireConfirmationDialog` shows an explicit alert unless
  /// tests bypass the UI prompt after verifying confirmation).
  func applySetupPack(
    _ preview: SetupPackPreview,
    options: SetupPackImportOptions,
    requireDownloadConfirmationDialog: Bool = true,
    service: SetupPackService? = nil
  ) async throws -> SetupPackApplyReport {
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

    var outcome: SetupPackApplyReport?
    try await run(.immediate) {
      let connected = connectedSetupPackDisplays
      let packService = service ?? SetupPackService(
        supportRoot: ClientPaths.supportURL,
        storageRoot: ClientPaths.storageURL)
      let plan = try packService.prepareImportPlan(
        preview: preview,
        options: effectiveOptions,
        connectedDisplays: connected)

      var notes = plan.notes

      // 1. Property presets (in-place append/dedupe without clobbering existing presets)
      let importedPresets = try presets.importPortablePresets(plan.presets)

      // 2. Desktop widgets (in-place add; `DesktopWidgetStore` notifies `DesktopWidgetController`)
      var importedWidgetsCount = 0
      if !plan.widgets.isEmpty {
        let remaining = max(0, DesktopWidgetStore.limit - desktopWidgets.widgets.count)
        let batch = Array(plan.widgets.prefix(remaining))
        if batch.count < plan.widgets.count {
          notes.append(
            L("Imported \(batch.count) of \(plan.widgets.count) widgets because the limit of 24 widgets was reached.")
          )
        }
        if !batch.isEmpty {
          let added = try desktopWidgets.add(batch)
          importedWidgetsCount = added.count
        }
      }

      // 3. Display layouts (in-place save, skipping exact duplicates and preserving existing layouts)
      var importedLayoutsCount = 0
      var skippedDueToLimit = 0
      for layout in plan.layouts {
        let duplicate = displayLayouts.layouts.contains { existing in
          existing.name == layout.name && existing.assignments == layout.assignments
        }
        if duplicate { continue }
        if displayLayouts.layouts.count >= WallpaperDisplayLayoutStore.limit {
          skippedDueToLimit += 1
          continue
        }
        // Imported layouts never silently arm auto-apply or disarm an existing user auto-apply layout.
        _ = try displayLayouts.save(
          name: layout.name,
          assignments: layout.assignments,
          autoApplyOnConnect: false)
        importedLayoutsCount += 1
      }
      if skippedDueToLimit > 0 {
        notes.append(
          L("Skipped \(skippedDueToLimit) display layout(s) because the limit of 64 saved layouts was reached.")
        )
      }

      // 4. Missing Workshop downloads (STRICTLY only when explicitly confirmed)
      let queuedCount = queueConfirmedSetupPackDownloads(plan.confirmedDownloadWorkshopIDs)

      outcome = SetupPackApplyReport(
        importedPresetsCount: importedPresets.count,
        importedWidgetsCount: importedWidgetsCount,
        importedLayoutsCount: importedLayoutsCount,
        queuedDownloadsCount: queuedCount,
        notes: notes)
    }
    guard let outcome else { throw CancellationError() }
    return outcome
  }

  /// Queues downloads for explicitly confirmed missing Workshop items. Never called unless the
  /// user explicitly confirmed downloading missing items.
  private func queueConfirmedSetupPackDownloads(_ items: [SetupPackWorkshopItem]) -> Int {
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
          subscriptions: 0)
      workshop.requestDownload(item: resolved, rememberSession: remembersSession, bridge: store)
      queued += 1
    }
    return queued
  }

  private func makeSetupPackExportInput(selection: SetupPackExportSelection) -> SetupPackExportInput {
    let candidates = setupPackExportCandidates
    let libraryTitles = Dictionary(
      store.librarySnapshot.wallpapers.map { ($0.id, $0.title) },
      uniquingKeysWith: { first, _ in first })
    let activeIDs = selection.includeActiveWallpapers ? candidates.activeWorkshopIDs : []
    let chosenPresets = candidates.presets.filter { selection.selectedPresetIDs.contains($0.id) }
    let chosenWidgets = candidates.widgets.filter { selection.selectedWidgetIDs.contains($0.id) }
    let chosenLayouts = candidates.layouts.filter { selection.selectedLayoutIDs.contains($0.id) }
    return SetupPackExportInput(
      name: selection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : selection.name,
      displays: connectedSetupPackDisplays,
      libraryTitles: libraryTitles,
      activeWallpaperIDs: activeIDs,
      presets: chosenPresets,
      widgets: chosenWidgets,
      layouts: chosenLayouts)
  }

  private static func suggestedSetupPackFileName(named raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = String(
      trimmed.map { character -> Character in
        character == "/" || character == ":" || character == "\\" || character.isNewline ? "-" : character
      }
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = cleaned.isEmpty
      ? "WallpaperMachine-Setup-\(Date().formatted(.iso8601.year().month().day()))"
      : String(cleaned.prefix(64))
    return "\(stem).\(SetupPackService.fileExtension)"
  }

  private static func displayUUIDString(for displayID: UInt32) -> String? {
    guard CGDisplayIsOnline(displayID) != 0,
      let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }
}
