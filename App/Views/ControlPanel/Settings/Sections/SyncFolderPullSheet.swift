import SwiftUI

/// Interactive conflict preview & selective apply sheet for `WallpaperMachineSync.json`.
///
/// Displays source device metadata, per-category diff counts (added / updated / conflicts),
/// conflict strategy selection (Merge vs Replace selected categories), interactive display
/// remapping with explicit Skip option, and opt-in missing Workshop download queueing behind
/// explicit confirmation.
struct SyncFolderPullSheet: View {
  let preview: SyncFolderPullPreview
  let onApplied: (SyncFolderPullApplyReport) -> Void
  let onCancel: () -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  @State private var selectedCategories: Set<SyncFolderCategory>
  @State private var conflictStrategy: SyncFolderConflictStrategy = .merge
  @State private var displayMapping: [String: String?]
  /// Strictly off by default so missing Workshop items are never downloaded silently.
  @State private var queueMissingDownloads = false
  @State private var isApplying = false
  @State private var applyError: String?

  init(
    preview: SyncFolderPullPreview,
    onApplied: @escaping (SyncFolderPullApplyReport) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preview = preview
    self.onApplied = onApplied
    self.onCancel = onCancel
    let populated = Set(
      SyncFolderCategory.allCases.filter { preview.diff(for: $0).incomingCount > 0 }
    )
    _selectedCategories = State(
      initialValue: populated.isEmpty ? Set(SyncFolderCategory.allCases) : populated
    )
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
          conflictStrategyCard
          categoriesCard
          if shouldShowDisplayMapping {
            displayMappingCard(connected: connected)
          }
          workshopItemsCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 440)

      if let applyError {
        Text(verbatim: applyError)
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.danger.color)
      }

      HStack(spacing: 8) {
        if isApplying {
          LoadingRing()
        }
        Text("Applies immediately without restarting. Unselected categories stay untouched.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
        Spacer(minLength: 8)
        Button("Cancel", role: .cancel, action: onCancel)
          .buttonStyle(.panelSecondary)
          .keyboardShortcut(.cancelAction)
          .disabled(isApplying)
        Button("Apply Sync") {
          performApply()
        }
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(isApplying || !canApply)
      }
    }
    .padding(18)
    .frame(width: 580)
  }

  private var shouldShowDisplayMapping: Bool {
    !preview.sourceDisplays.isEmpty
      && (selectedCategories.contains(.layouts) || selectedCategories.contains(.widgets))
  }

  private var headerSection: some View {
    let dateText = preview.snapshot.exportedAt.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
    )
    let sizeText = ByteSize.format(Double(preview.byteCount), locale: locale)
    return VStack(alignment: .leading, spacing: 4) {
      Text("Review Sync Snapshot")
        .font(.panel(.headline))
        .foregroundStyle(theme.surface.text.color)
      Text(
        verbatim:
          "\(preview.snapshot.deviceName) · v\(preview.snapshot.appVersion) · \(dateText) · \(sizeText)"
      )
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
        .fill(theme.surface.well.color)
    )
  }

  private var conflictStrategyCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Conflict strategy")
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.text.color)
      Picker(L("Conflict strategy"), selection: $conflictStrategy) {
        Text("Merge (keep local on conflict)").tag(SyncFolderConflictStrategy.merge)
        Text("Replace selected categories").tag(SyncFolderConflictStrategy.replace)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      Text(
        verbatim: conflictStrategy == .merge
          ? L(
            "Unions favorites and tags, adds new items from the sync folder, and keeps this Mac’s version whenever the same item differs."
          )
          : L(
            "Replaces only the checked categories below with the sync folder’s snapshot. Unchecked categories stay untouched."
          )
      )
      .font(.panel(.footnote))
      .foregroundStyle(
        conflictStrategy == .replace ? theme.surface.warning.color : theme.surface.muted.color
      )
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.surface.well.color)
    )
  }

  private var categoriesCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Categories to sync")
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.text.color)

      LazyVStack(alignment: .leading, spacing: 6) {
        ForEach(SyncFolderCategory.allCases) { category in
          let diff = preview.diff(for: category)
          HStack(spacing: 8) {
            Toggle(
              isOn: Binding(
                get: { selectedCategories.contains(category) },
                set: { isOn in
                  if isOn { selectedCategories.insert(category) }
                  else { selectedCategories.remove(category) }
                }
              )
            ) {
              Text(verbatim: Self.categoryTitle(category))
                .font(.panel(.body))
                .foregroundStyle(theme.surface.text.color)
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 8)

            Text(verbatim: Self.diffSummaryText(diff, strategy: conflictStrategy))
              .font(.panel(.caption))
              .foregroundStyle(
                diff.conflictingCount > 0 ? theme.surface.warning.color : theme.surface.muted.color
              )
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.surface.well.color)
      )
    }
  }

  private func displayMappingCard(connected: [SetupPackTargetDisplay]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Display mapping")
        .font(.panel(.calloutStrong))
        .foregroundStyle(theme.surface.text.color)
      Text(
        "Map each display from the sync snapshot to a display connected on this Mac. Imported display layouts always save with auto-apply turned off."
      )
      .font(.panel(.footnote))
      .foregroundStyle(theme.surface.muted.color)

      LazyVStack(alignment: .leading, spacing: 8) {
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
                  displayMapping.updateValue(
                    value == Self.skipSentinel ? nil : value,
                    forKey: source.id
                  )
                }
              )
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
          .fill(theme.surface.well.color)
      )
    }
  }

  private var workshopRows: [SyncWorkshopRow] {
    preview.installedWorkshopItems.map { SyncWorkshopRow(item: $0, installed: true) }
      + preview.missingWorkshopItems.map { SyncWorkshopRow(item: $0, installed: false) }
  }

  private var workshopItemsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "Workshop wallpapers (\(preview.installedWorkshopItems.count) installed, \(preview.missingWorkshopItems.count) missing)"
      )
      .font(.panel(.calloutStrong))
      .foregroundStyle(theme.surface.text.color)

      if workshopRows.isEmpty {
        Text("This sync snapshot does not reference any Workshop wallpapers.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
      } else {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(workshopRows) { row in
            HStack(spacing: 8) {
              Image(systemName: row.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.panel(.callout))
                .foregroundStyle(
                  row.installed ? theme.surface.approved.color : theme.surface.warning.color
                )
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.item.title ?? L("Workshop #\(row.item.id)"))
                  .font(.panel(.body))
                  .foregroundStyle(theme.surface.text.color)
                  .lineLimit(1)
                  .truncationMode(.tail)
                Text(verbatim: row.item.id)
                  .font(.panel(.caption))
                  .foregroundStyle(theme.surface.muted.color)
              }
              Spacer(minLength: 8)
              Text(verbatim: row.installed ? L("Installed") : L("Not installed"))
                .font(.panel(.badge))
                .foregroundStyle(
                  row.installed ? theme.surface.approved.color : theme.surface.warning.color
                )
            }
          }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.surface.well.color)
        )
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

  private var canApply: Bool {
    !selectedCategories.isEmpty
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
    let options = SyncFolderPullOptions(
      selectedCategories: selectedCategories,
      conflictStrategy: conflictStrategy,
      displayMapping: displayMapping,
      queueMissingDownloadsConfirmed: queueMissingDownloads
    )
    controller.launch(PanelActionCoordinator.key("syncFolderApply")) {
      defer { isApplying = false }
      do {
        let report = try await controller.applySyncFolderPull(preview, options: options)
        onApplied(report)
      } catch {
        applyError = error.localizedDescription
        throw error
      }
    }
  }

  static func categoryTitle(_ category: SyncFolderCategory) -> String {
    switch category {
    case .favorites: L("Favorites")
    case .collections: L("Collections")
    case .metadata: L("Ratings, tags & notes")
    case .playlists: L("Saved playlists")
    case .presets: L("Property presets")
    case .widgets: L("Desktop widgets")
    case .layouts: L("Display layouts")
    case .videoTrims: L("Video loop trims")
    }
  }

  static func diffSummaryText(
    _ diff: SyncFolderCategoryDiff,
    strategy: SyncFolderConflictStrategy
  ) -> String {
    var parts: [String] = []
    if diff.addedCount > 0 { parts.append(L("\(diff.addedCount) added")) }
    if diff.updatedCount > 0 { parts.append(L("\(diff.updatedCount) updated")) }
    if diff.conflictingCount > 0 { parts.append(L("\(diff.conflictingCount) conflict(s)")) }
    if strategy == .replace, diff.localOnlyCount > 0 {
      parts.append(L("\(diff.localOnlyCount) local removed"))
    }
    if parts.isEmpty {
      return diff.incomingCount == 0 && diff.localCount == 0
        ? L("Empty")
        : L("Up to date (\(diff.incomingCount))")
    }
    return parts.joined(separator: " · ")
  }

  private static let skipSentinel = "__sync_folder_skip_display__"
}

private struct SyncWorkshopRow: Identifiable {
  let item: SetupPackWorkshopItem
  let installed: Bool
  var id: String { "\(installed ? "i" : "m"):\(item.id)" }
}
