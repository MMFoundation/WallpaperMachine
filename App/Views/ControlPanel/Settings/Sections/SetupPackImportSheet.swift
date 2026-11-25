import SwiftUI

/// Interactive preview and import confirmation sheet for a validated `.wmpack` setup pack.
///
/// Displays installed vs missing Workshop items, lets the user interactively remap exported
/// displays onto this Mac's connected displays, lets the user pick which component groups to apply
/// in place, and keeps missing-item download queueing strictly opt-in behind explicit confirmation.
struct SetupPackImportSheet: View {
  let preview: SetupPackPreview
  let onApplied: (SetupPackApplyReport) -> Void
  let onCancel: () -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  @State private var includePresets: Bool
  @State private var includeLayouts: Bool
  @State private var includeWidgets: Bool
  @State private var displayMapping: [String: String?]
  /// Strictly off by default so missing Workshop items are never downloaded silently.
  @State private var queueMissingDownloads = false
  @State private var isApplying = false
  @State private var applyError: String?

  init(
    preview: SetupPackPreview,
    onApplied: @escaping (SetupPackApplyReport) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preview = preview
    self.onApplied = onApplied
    self.onCancel = onCancel
    _includePresets = State(initialValue: !preview.document.presets.isEmpty)
    _includeLayouts = State(initialValue: !preview.document.layouts.isEmpty)
    _includeWidgets = State(initialValue: !preview.document.widgets.isEmpty)
    var initialMap: [String: String?] = [:]
    for source in preview.sourceDisplays {
      initialMap[source.id] = preview.suggestedDisplayMapping[source.id]
    }
    _displayMapping = State(initialValue: initialMap)
  }

  var body: some View {
    let connected = controller.connectedSetupPackDisplays
    VStack(alignment: .leading, spacing: 14) {
      headerSection

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if !preview.notes.isEmpty {
            notesCard
          }
          workshopItemsCard
          if !preview.sourceDisplays.isEmpty {
            displayMappingCard(connected: connected)
          }
          componentsCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 420)

      if let applyError {
        Text(verbatim: applyError)
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.danger.color)
      }

      HStack(spacing: 8) {
        if isApplying {
          LoadingRing()
        }
        Text("Applies immediately without restarting and keeps unrelated settings intact.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
        Spacer(minLength: 8)
        Button("Cancel", role: .cancel, action: onCancel)
          .buttonStyle(.panelSecondary)
          .keyboardShortcut(.cancelAction)
          .disabled(isApplying)
        Button("Apply Setup Pack") {
          performApply()
        }
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(isApplying || !canApply)
      }
    }
    .padding(18)
    .frame(width: 560)
  }

  private var headerSection: some View {
    let title = preview.document.name ?? preview.fileName
    let dateText = preview.document.createdAt.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    let sizeText = ByteSize.format(Double(preview.byteCount), locale: locale)
    return VStack(alignment: .leading, spacing: 4) {
      Text("Review Setup Pack")
        .font(.panel(.headline))
        .foregroundStyle(theme.surface.text.color)
      Text(verbatim: "\(title) · \(dateText) · \(sizeText)")
        .font(.panel(.callout))
        .foregroundStyle(theme.surface.muted.color)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var notesCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Notes")
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.warning.color)
      ForEach(Array(preview.notes.enumerated()), id: \.offset) { _, note in
        Text(verbatim: note)
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.text.color)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.surface.well.color))
  }

  private var workshopItemsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "Workshop wallpapers (\(preview.installedWorkshopItems.count) installed, \(preview.missingWorkshopItems.count) missing)"
      )
      .font(.panel(.calloutStrong))
      .foregroundStyle(theme.surface.text.color)

      if preview.installedWorkshopItems.isEmpty && preview.missingWorkshopItems.isEmpty {
        Text("This setup pack does not reference any Workshop wallpapers.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(preview.installedWorkshopItems) { item in
            workshopRow(item: item, installed: true)
          }
          ForEach(preview.missingWorkshopItems) { item in
            workshopRow(item: item, installed: false)
          }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.surface.well.color))
      }

      if !preview.missingWorkshopItems.isEmpty {
        Toggle(isOn: $queueMissingDownloads) {
          VStack(alignment: .leading, spacing: 2) {
            Text(
              "Queue downloads for \(preview.missingWorkshopItems.count) missing Workshop wallpaper(s)"
            )
            .font(.panel(.body))
            .foregroundStyle(theme.surface.text.color)
            Text("Requires an extra confirmation before adding anything to the Steam download queue.")
              .font(.panel(.footnote))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
        .toggleStyle(.checkbox)
      }
    }
  }

  private func workshopRow(item: SetupPackWorkshopItem, installed: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
        .font(.panel(.callout))
        .foregroundStyle(installed ? theme.surface.approved.color : theme.surface.warning.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: item.title ?? L("Workshop #\(item.id)"))
          .font(.panel(.body))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(verbatim: item.id)
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.muted.color)
      }
      Spacer(minLength: 8)
      Text(verbatim: installed ? L("Installed") : L("Not installed"))
        .font(.panel(.badge))
        .foregroundStyle(installed ? theme.surface.approved.color : theme.surface.warning.color)
    }
  }

  private func displayMappingCard(connected: [SetupPackTargetDisplay]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Display mapping")
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.text.color)
      Text("Map each display from the setup pack to a display connected on this Mac.")
        .font(.panel(.footnote))
        .foregroundStyle(theme.surface.muted.color)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(preview.sourceDisplays) { source in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: source.name)
                .font(.panel(.body))
                .foregroundStyle(theme.surface.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
              if let subtitle = sourceDisplaySubtitle(source) {
                Text(verbatim: subtitle)
                  .font(.panel(.caption))
                  .foregroundStyle(theme.surface.muted.color)
              }
            }
            Spacer(minLength: 8)
            Picker(
              L("Target display for \(source.name)"),
              selection: Binding<String>(
                get: { displayMapping[source.id].flatMap { $0 } ?? Self.skipSentinel },
                set: { value in
                  displayMapping.updateValue(value == Self.skipSentinel ? nil : value, forKey: source.id)
                })
            ) {
              ForEach(connected) { target in
                Text(verbatim: target.title).tag(target.displayID)
              }
              Text("Skip").tag(Self.skipSentinel)
            }
            .labelsHidden()
            .frame(width: 220)
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.surface.well.color))
    }
  }

  private var componentsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Components to import")
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.text.color)
      VStack(alignment: .leading, spacing: 6) {
        Toggle(isOn: $includePresets) {
          Text("Property presets (\(preview.document.presets.count))")
            .font(.panel(.body))
            .foregroundStyle(theme.surface.text.color)
        }
        .toggleStyle(.checkbox)
        .disabled(preview.document.presets.isEmpty)

        Toggle(isOn: $includeLayouts) {
          Text("Display layouts (\(preview.document.layouts.count))")
            .font(.panel(.body))
            .foregroundStyle(theme.surface.text.color)
        }
        .toggleStyle(.checkbox)
        .disabled(preview.document.layouts.isEmpty)

        Toggle(isOn: $includeWidgets) {
          Text("Desktop widgets (\(preview.document.widgets.count))")
            .font(.panel(.body))
            .foregroundStyle(theme.surface.text.color)
        }
        .toggleStyle(.checkbox)
        .disabled(preview.document.widgets.isEmpty)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.surface.well.color))
    }
  }

  private var canApply: Bool {
    (includePresets && !preview.document.presets.isEmpty)
      || (includeLayouts && !preview.document.layouts.isEmpty)
      || (includeWidgets && !preview.document.widgets.isEmpty)
      || (queueMissingDownloads && !preview.missingWorkshopItems.isEmpty)
  }

  private func sourceDisplaySubtitle(_ source: SetupPackDisplayDescriptor) -> String? {
    var parts: [String] = []
    if source.isPrimary { parts.append(L("Primary")) }
    if let w = source.width, let h = source.height { parts.append("\(w) × \(h)") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func performApply() {
    applyError = nil
    isApplying = true
    let options = SetupPackImportOptions(
      includePresets: includePresets,
      includeWidgets: includeWidgets,
      includeLayouts: includeLayouts,
      displayMapping: displayMapping,
      queueMissingDownloadsConfirmed: queueMissingDownloads)
    controller.launch(PanelActionCoordinator.key("setupPackApply")) {
      defer { isApplying = false }
      do {
        let report = try await controller.applySetupPack(preview, options: options)
        onApplied(report)
      } catch {
        applyError = error.localizedDescription
        throw error
      }
    }
  }

  private static let skipSentinel = "__setup_pack_skip_display__"
}
