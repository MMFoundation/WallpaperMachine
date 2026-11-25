import SwiftUI

/// Self-contained Settings › Storage card for exporting and importing lightweight shareable
/// `.wmpack` setup packs. Designed to drop into `StorageSettingsSection` in two lines
/// (`SetupPackSection.items` + `SetupPackSection()`).
struct SetupPackSection: View {
  static let group = SettingsItem.Group("setup-pack", title: "Shareable setup pack")

  static let setupPackExport = SettingsItem(
    id: "storage.setup-pack-export", section: .storage, group: group,
    title: "Export setup pack",
    note:
      "Saves a lightweight .wmpack file with Workshop wallpaper IDs, sanitized property presets, portable desktop widgets and display layouts. Never includes media files, Steam sign-ins or macOS Space IDs.",
    keywords: ["Export…", "Setup pack"])

  static let setupPackImport = SettingsItem(
    id: "storage.setup-pack-import", section: .storage, group: group,
    title: "Import setup pack",
    note:
      "Preview a .wmpack file, remap displays to this Mac, and choose what to import in place without restarting. Missing Workshop wallpapers are downloaded only if you confirm.",
    keywords: ["Import…", "Apply Setup Pack", "Display mapping"])

  static let items = [setupPackExport, setupPackImport]

  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale
  @State private var showingExportSheet = false
  @State private var pendingImportPreview: SetupPackPreview?
  @State private var isWorking = false
  @State private var statusMessage: String?
  @State private var notes: [String] = []
  @State private var errorMessage: String?

  var body: some View {
    SettingsGroup(Self.group, in: .storage) {
      let busy = isWorking || controller.isStoreBusy

      DisplaysRow(item: Self.setupPackExport, labelsControl: false) {
        Button("Export…") {
          showingExportSheet = true
        }
        .buttonStyle(.panelSecondary)
        .disabled(busy)
      }

      DisplaysRow(item: Self.setupPackImport, labelsControl: false) {
        Button("Import…") {
          openImportPreview()
        }
        .buttonStyle(.panelSecondary)
        .disabled(busy)
      }

      if isWorking {
        ProgressBar(value: nil)
          .accessibilityLabel(Text("Setup pack progress"))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      }

      if let errorMessage, !errorMessage.isEmpty {
        DisplaysMessageRow(text: errorMessage, isError: true)
      } else if let statusMessage, !statusMessage.isEmpty {
        DisplaysMessageRow(text: statusMessage)
      }

      ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
        DisplaysNote(text: note, tone: .warning)
      }

      Color.clear
        .frame(height: 0)
        .accessibilityHidden(true)
        .announcesChanges(of: errorMessage ?? statusMessage)
    }
    .sheet(isPresented: $showingExportSheet) {
      SetupPackExportSheet(
        onExported: { report in
          showingExportSheet = false
          errorMessage = nil
          let size = ByteSize.format(Double(report.byteCount), locale: locale)
          statusMessage = L(
            "Setup pack exported (\(size)): \(report.workshopItemCount) Workshop item(s), \(report.presetCount) preset(s), \(report.layoutCount) layout(s), \(report.widgetCount) widget(s)."
          )
          notes = report.notes
        },
        onCancel: { showingExportSheet = false }
      )
      .panelPresentationLocale()
    }
    .sheet(item: previewBinding) { wrapper in
      SetupPackImportSheet(
        preview: wrapper.preview,
        onApplied: { report in
          pendingImportPreview = nil
          errorMessage = nil
          statusMessage = L(
            "Setup pack applied: \(report.importedPresetsCount) preset(s), \(report.importedLayoutsCount) layout(s), \(report.importedWidgetsCount) widget(s), \(report.queuedDownloadsCount) download(s) queued."
          )
          notes = report.notes
        },
        onCancel: { pendingImportPreview = nil }
      )
      .panelPresentationLocale()
    }
  }

  private var previewBinding: Binding<IdentifiableSetupPackPreview?> {
    Binding(
      get: { pendingImportPreview.map(IdentifiableSetupPackPreview.init) },
      set: { pendingImportPreview = $0?.preview })
  }

  private func openImportPreview() {
    errorMessage = nil
    statusMessage = nil
    notes = []
    isWorking = true
    controller.launch(PanelActionCoordinator.key("setupPackPreview")) {
      defer { isWorking = false }
      do {
        if let preview = try await controller.previewSetupPack() {
          pendingImportPreview = preview
        }
      } catch {
        errorMessage = error.localizedDescription
        throw error
      }
    }
  }
}

private struct IdentifiableSetupPackPreview: Identifiable {
  let preview: SetupPackPreview
  var id: String { preview.digest }
}

/// Compact selection sheet allowing the user to name the `.wmpack` file and choose which
/// components (active Workshop wallpapers, presets, layouts, portable widgets) to export.
private struct SetupPackExportSheet: View {
  let onExported: (SetupPackExportReport) -> Void
  let onCancel: () -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var selection = SetupPackExportSelection()
  @State private var hasSeeded = false
  @State private var isExporting = false
  @State private var sheetError: String?

  var body: some View {
    let candidates = controller.setupPackExportCandidates
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Export Setup Pack")
          .font(.panel(.headline))
          .foregroundStyle(theme.surface.text.color)
        Text(
          "Creates a compact .wmpack file you can share. Media files, Steam sign-ins, local paths and macOS Space IDs are never included."
        )
        .font(.panel(.callout))
        .foregroundStyle(theme.surface.muted.color)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Pack name (optional)")
          .font(.panel(.calloutStrong))
          .foregroundStyle(theme.surface.text.color)
        TextField(L("My Desktop Setup"), text: $selection.name)
          .textFieldStyle(.roundedBorder)
          .font(.panel(.body))
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !candidates.activeWorkshopIDs.isEmpty {
            Toggle(isOn: $selection.includeActiveWallpapers) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Active Workshop wallpapers (\(candidates.activeWorkshopIDs.count))")
                  .font(.panel(.body))
                  .foregroundStyle(theme.surface.text.color)
                Text("Includes numeric Workshop IDs currently shown on your displays.")
                  .font(.panel(.footnote))
                  .foregroundStyle(theme.surface.muted.color)
              }
            }
            .toggleStyle(.checkbox)
          }

          if !candidates.layouts.isEmpty {
            selectionGroup(
              title: L("Display layouts (\(selection.selectedLayoutIDs.count)/\(candidates.layouts.count))"),
              items: candidates.layouts.map { ($0.id, $0.name) },
              selected: $selection.selectedLayoutIDs)
          }

          if !candidates.presets.isEmpty {
            selectionGroup(
              title: L("Property presets (\(selection.selectedPresetIDs.count)/\(candidates.presets.count))"),
              items: candidates.presets.map { ($0.id, $0.name) },
              selected: $selection.selectedPresetIDs)
          }

          if !candidates.widgets.isEmpty {
            selectionGroup(
              title: L("Desktop widgets (\(selection.selectedWidgetIDs.count)/\(candidates.widgets.count))"),
              items: candidates.widgets.map { ($0.id, widgetLabel($0)) },
              selected: $selection.selectedWidgetIDs)
            if candidates.widgets.contains(where: { $0.pinnedSpaceIDs != nil }) {
              Text(
                "Widgets pinned to specific Spaces will be exported to show on all Spaces."
              )
              .font(.panel(.footnote))
              .foregroundStyle(theme.surface.warning.color)
            }
            if candidates.widgets.contains(where: { $0.kind == .image || $0.imageAsset != nil }) {
              Text(
                "Static image sticker widgets are omitted because setup packs do not bundle image files."
              )
              .font(.panel(.footnote))
              .foregroundStyle(theme.surface.warning.color)
            }
          }

          if !candidates.hasAnyContent {
            Text(
              "No shareable Workshop wallpapers, presets, layouts or desktop widgets were found to export."
            )
            .font(.panel(.callout))
            .foregroundStyle(theme.surface.muted.color)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)

      if let sheetError {
        Text(verbatim: sheetError)
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.danger.color)
      }

      HStack(spacing: 8) {
        if isExporting {
          LoadingRing()
        }
        Spacer(minLength: 0)
        Button("Cancel", role: .cancel, action: onCancel)
          .buttonStyle(.panelSecondary)
          .keyboardShortcut(.cancelAction)
          .disabled(isExporting)
        Button("Export…") {
          performExport()
        }
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(isExporting || !hasSelectedContent)
      }
    }
    .padding(18)
    .frame(width: 480)
    .onAppear {
      if !hasSeeded {
        selection = controller.setupPackExportCandidates.defaultSelection
        hasSeeded = true
      }
    }
  }

  private var hasSelectedContent: Bool {
    selection.includeActiveWallpapers
      || !selection.selectedLayoutIDs.isEmpty
      || !selection.selectedPresetIDs.isEmpty
      || !selection.selectedWidgetIDs.isEmpty
  }

  private func selectionGroup(
    title: String,
    items: [(id: String, name: String)],
    selected: Binding<Set<String>>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: title)
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.text.color)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(items, id: \.id) { item in
          Toggle(isOn: Binding(
            get: { selected.wrappedValue.contains(item.id) },
            set: { isOn in
              if isOn { selected.wrappedValue.insert(item.id) }
              else { selected.wrappedValue.remove(item.id) }
            })
          ) {
            Text(verbatim: item.name)
              .font(.panel(.body))
              .foregroundStyle(theme.surface.text.color)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .toggleStyle(.checkbox)
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(theme.surface.well.color))
    }
  }

  private func widgetLabel(_ widget: DesktopWidget) -> String {
    let trimmed = widget.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return "\(widget.kind.rawValue) — \(trimmed)"
    }
    return widget.kind.rawValue
  }

  private func performExport() {
    sheetError = nil
    isExporting = true
    controller.launch(PanelActionCoordinator.key("setupPackExport")) {
      defer { isExporting = false }
      do {
        if let report = try await controller.exportSetupPack(selection: selection) {
          onExported(report)
        }
      } catch {
        sheetError = error.localizedDescription
        throw error
      }
    }
  }
}
