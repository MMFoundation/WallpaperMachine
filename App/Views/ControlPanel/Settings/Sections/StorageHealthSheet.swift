import SwiftUI

/// On-demand Library Storage Health & Cleanup Center presented as a sheet from Settings › Storage.
///
/// Performs zero disk I/O in views: every scan, Trash deletion, broken-reference repair and orphan
/// cleanup runs through typed actions on `PanelController` via `controller.launch`.
struct StorageHealthSheet: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  var body: some View {
    let model = controller.storageHealth
    VStack(spacing: 0) {
      header(model)
      Divider()
      bodyContent(model)
      Divider()
      footer(model)
    }
    .frame(width: 680, height: 540)
    .foregroundStyle(theme.surface.text.color)
    .background(theme.surface.background.color)
    .controlSize(.small)
  }

  // MARK: - Header

  private func header(_ model: StorageHealthModel) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Storage health")
          .font(.panel(.headline))
        if let summary = model.summaryLine(locale: locale) {
          Text(verbatim: summary)
            .font(.panel(.callout))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
            .truncationMode(.tail)
        } else {
          Text("Scan on demand for duplicates, wallpapers not used recently, broken references and orphaned storage.")
            .font(.panel(.callout))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if model.isScanning {
        Button("Cancel") {
          controller.launch(PanelActionCoordinator.key("storageHealthCancel")) {
            try await controller.cancelStorageHealthScan()
          }
        }
        .buttonStyle(.panelSecondary(size: .small))
      } else {
        Button("Scan again") {
          controller.launch(PanelActionCoordinator.key("storageHealthScan")) {
            try await controller.scanStorageHealth()
          }
        }
        .buttonStyle(.panelSecondary(size: .small))
        .disabled(model.isCleaning)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(theme.surface.surface.color)
  }

  // MARK: - Body

  @ViewBuilder
  private func bodyContent(_ model: StorageHealthModel) -> some View {
    switch model.state {
    case .idle:
      PanelEmptyState(
        "Ready to scan library",
        systemImage: "externaldrive.badge.checkmark",
        description: "Storage Health checks duplicates, large wallpapers not used recently, broken references and orphaned storage only when you ask."
      ) {
        Button("Scan now") {
          controller.launch(PanelActionCoordinator.key("storageHealthScan")) {
            try await controller.scanStorageHealth()
          }
        }
        .buttonStyle(.panelPrimary(size: .compact))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .scanning(let progress):
      scanningView(progress)

    case .failed(let message):
      PanelEmptyState(
        verbatim: L("Scan failed"),
        systemImage: "exclamationmark.triangle",
        description: message
      ) {
        Button("Scan again") {
          controller.launch(PanelActionCoordinator.key("storageHealthScan")) {
            try await controller.scanStorageHealth()
          }
        }
        .buttonStyle(.panelPrimary(size: .compact))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .ready(let report):
      VStack(spacing: 0) {
        tabBar(model)
        if let error = model.errorMessage {
          bannerRow(text: error, isError: true)
        } else if let status = model.statusMessage {
          bannerRow(text: status, isError: false)
        }
        Color.clear.frame(height: 0).accessibilityHidden(true)
          .announcesChanges(of: model.errorMessage ?? model.statusMessage)

        switch model.selectedTab {
        case .duplicates:
          duplicatesTab(model: model, report: report)
        case .unused:
          unusedTab(model: model)
        case .maintenance:
          maintenanceTab(model: model, report: report)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func scanningView(_ progress: LibraryStorageHealthService.ScanProgress) -> some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        LoadingRing()
        Text(verbatim: StorageHealthModel.phaseTitle(progress.phase))
          .font(.panel(.sectionHeader))
      }
      ProgressBar(value: progress.fraction)
        .accessibilityLabel(Text("Storage health scan progress"))
        .frame(maxWidth: 320)
      if progress.total > 0 {
        Text(verbatim: L("\(progress.completed) of \(progress.total)"))
          .font(.panel(.caption).monospacedDigit())
          .foregroundStyle(theme.surface.muted.color)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func tabBar(_ model: StorageHealthModel) -> some View {
    let segments: [SettingsSegmentedControl<StorageHealthModel.Tab>.Segment] =
      StorageHealthModel.Tab.allCases.map { tab in
        let count = model.countBadge(for: tab)
        let label = count > 0 ? "\(tab.title) (\(count))" : tab.title
        return .init(value: tab, title: label)
      }
    return SettingsSegmentedControl(
      segments: segments,
      selection: model.selectedTab,
      isEnabled: !model.isCleaning,
      fillsWidth: true
    ) { tab in
      model.selectedTab = tab
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func bannerRow(text: String, isError: Bool) -> some View {
    Text(verbatim: text)
      .font(.panel(.footnote))
      .foregroundStyle(isError ? theme.surface.danger.color : theme.surface.approved.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
  }

  // MARK: - Tab 1: Exact Duplicates

  @ViewBuilder
  private func duplicatesTab(
    model: StorageHealthModel, report: LibraryStorageHealthService.Report
  ) -> some View {
    if report.duplicateGroups.isEmpty {
      PanelEmptyState(
        "No exact duplicates found",
        systemImage: "checkmark.circle",
        description: "Every installed wallpaper has unique content."
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Button("Select recommended") { model.selectRecommendedDuplicates() }
            .buttonStyle(.panelSecondary(size: .small))
            .disabled(model.isCleaning)
          Button("Clear selection") { model.clearDuplicateSelection() }
            .buttonStyle(.panelSecondary(size: .small))
            .disabled(model.isCleaning || model.selectedDuplicateIDs.isEmpty)
          Spacer(minLength: 8)
          let selectedCount = model.selectedDuplicateOrderedIDs.count
          if selectedCount > 0 {
            Text(verbatim: ByteSize.format(Double(model.selectedDuplicateBytes), locale: locale))
              .font(.panel(.caption).monospacedDigit())
              .foregroundStyle(theme.surface.muted.color)
          }
          Button(role: .destructive) {
            controller.launch(PanelActionCoordinator.key("storageHealthTrashDuplicates")) {
              try await model.trashSelectedDuplicates()
            }
          } label: {
            Text("Move selected to Trash…")
          }
          .buttonStyle(.panelSecondary(size: .small))
          .disabled(model.isCleaning || selectedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

        Text("Verified by size, head and tail fingerprint, and full SHA-256 checksum. At least one copy in each group is always kept.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.bottom, 8)

        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(report.duplicateGroups) { group in
              duplicateGroupCard(group: group, model: model)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
      }
    }
  }

  private func duplicateGroupCard(
    group: LibraryStorageHealthService.DuplicateGroup, model: StorageHealthModel
  ) -> some View {
    let sizeText = ByteSize.format(Double(group.contentSizeBytes), locale: locale)
    let reclaimableText = ByteSize.format(Double(group.reclaimableBytes), locale: locale)
    return PanelCard {
      HStack(spacing: 8) {
        Text(verbatim: L("\(group.items.count) identical copies"))
          .font(.panel(.calloutStrong))
        Text(verbatim: sizeText)
          .font(.panel(.caption).monospacedDigit())
          .foregroundStyle(theme.surface.muted.color)
        Spacer(minLength: 8)
        CapsuleBadge(style: .neutral) {
          Text(verbatim: L("\(reclaimableText) reclaimable"))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      ForEach(group.items) { item in
        duplicateItemRow(item: item, group: group, model: model)
      }
    }
  }

  private func duplicateItemRow(
    item: LibraryStorageHealthService.DuplicateItem,
    group: LibraryStorageHealthService.DuplicateGroup,
    model: StorageHealthModel
  ) -> some View {
    let isSelected = model.selectedDuplicateIDs.contains(item.id)
    let canToggle = model.canToggleDuplicate(item.id, in: group)
    return HStack(spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { isSelected },
          set: { _ in _ = model.toggleDuplicate(item.id, in: group) }
        )
      ) {
        EmptyView()
      }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(model.isCleaning || !canToggle)
      .accessibilityLabel(Text(verbatim: item.title))
      .help(canToggle ? "" : L("At least one copy in each duplicate group must be kept."))

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: item.title)
            .font(.panel(.body))
            .lineLimit(1)
            .truncationMode(.tail)
          if item.isRecommendedKeep {
            CapsuleBadge(style: .accent) {
              Text("Keep")
            }
          }
          if let badge = StorageHealthModel.referenceBadgeTitle(item.references) {
            CapsuleBadge(style: .neutral) {
              Text(verbatim: badge)
            }
          }
        }
        HStack(spacing: 6) {
          Text(verbatim: item.id)
            .font(.panel(.caption, design: .monospaced))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(verbatim: "·")
            .font(.panel(.caption))
            .foregroundStyle(theme.surface.faint.color)
          Text(verbatim: StorageHealthModel.lastUsedText(item.lastUsedAt, locale: locale))
            .font(.panel(.caption))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(verbatim: ByteSize.format(Double(item.diskSizeBytes), locale: locale))
        .font(.panel(.caption).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)

      Button {
        controller.launch(PanelActionCoordinator.key("reveal", detail: item.id)) {
          try await controller.reveal(item.id)
        }
      } label: {
        Image(systemName: "folder")
      }
      .buttonStyle(.panelSecondary(size: .small))
      .help(L("Show in Finder"))
      .accessibilityLabel(Text(verbatim: L("Show in Finder")))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Tab 2: Large, Not-Recently-Used

  private func unusedTab(model: StorageHealthModel) -> some View {
    let candidates = model.filteredUnusedWallpapers
    let selectedIDs = model.selectedFilteredUnusedIDs
    return VStack(spacing: 0) {
      HStack(spacing: 8) {
        Picker(
          "Minimum size",
          selection: Binding(get: { model.minimumSize }, set: { model.minimumSize = $0 })
        ) {
          ForEach(LibraryStorageHealthService.MinimumSizeFilter.allCases) { option in
            Text(verbatim: StorageHealthModel.sizeFilterTitle(option)).tag(option)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Minimum size"))

        Picker(
          "Recency",
          selection: Binding(get: { model.recencyFilter }, set: { model.recencyFilter = $0 })
        ) {
          ForEach(LibraryStorageHealthService.RecencyFilter.allCases) { option in
            Text(verbatim: StorageHealthModel.recencyFilterTitle(option)).tag(option)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Recency"))

        Spacer(minLength: 8)

        if !candidates.isEmpty {
          Button("Select all") { model.selectAllFilteredUnused() }
            .buttonStyle(.panelSecondary(size: .small))
            .disabled(model.isCleaning)
          Button("Clear selection") { model.clearUnusedSelection() }
            .buttonStyle(.panelSecondary(size: .small))
            .disabled(model.isCleaning || selectedIDs.isEmpty)
        }

        Button(role: .destructive) {
          controller.launch(PanelActionCoordinator.key("storageHealthTrashUnused")) {
            try await model.trashSelectedUnused()
          }
        } label: {
          Text("Move selected to Trash…")
        }
        .buttonStyle(.panelSecondary(size: .small))
        .disabled(model.isCleaning || selectedIDs.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 8)

      Text("Active, favorited and referenced wallpapers are excluded. History keeps up to 1,000 recent wallpapers per display, so older uses may show as no recent use recorded.")
        .font(.panel(.footnote))
        .foregroundStyle(theme.surface.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

      if candidates.isEmpty {
        PanelEmptyState(
          "No wallpapers match these filters",
          systemImage: "checkmark.circle",
          description: "No unreferenced wallpapers match the chosen size and recency filters."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(candidates) { candidate in
              unusedRow(candidate: candidate, model: model)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
      }
    }
  }

  private func unusedRow(
    candidate: LibraryStorageHealthService.UnusedWallpaperCandidate,
    model: StorageHealthModel
  ) -> some View {
    let isSelected = model.selectedUnusedIDs.contains(candidate.id)
    return HStack(spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { isSelected },
          set: { _ in model.toggleUnused(candidate.id) }
        )
      ) {
        EmptyView()
      }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(model.isCleaning)
      .accessibilityLabel(Text(verbatim: candidate.title))

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: candidate.title)
          .font(.panel(.body))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(verbatim: StorageHealthModel.lastUsedText(candidate.lastUsedAt, locale: locale))
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.muted.color)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(verbatim: ByteSize.format(Double(candidate.diskSizeBytes), locale: locale))
        .font(.panel(.calloutStrong).monospacedDigit())
        .foregroundStyle(theme.surface.text.color)

      Button {
        controller.launch(PanelActionCoordinator.key("reveal", detail: candidate.id)) {
          try await controller.reveal(candidate.id)
        }
      } label: {
        Image(systemName: "folder")
      }
      .buttonStyle(.panelSecondary(size: .small))
      .help(L("Show in Finder"))
      .accessibilityLabel(Text(verbatim: L("Show in Finder")))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .panelCardSurface()
  }

  // MARK: - Tab 3: Broken References & Orphaned Storage

  private func maintenanceTab(
    model: StorageHealthModel, report: LibraryStorageHealthService.Report
  ) -> some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(model.maintenanceRows) { row in
          switch row {
          case .brokenHeader:
            brokenHeaderRow(model: model, count: report.brokenReferences.count)
          case .brokenEmpty:
            emptyInlineRow(L("No broken references found."))
          case .broken(let item):
            brokenReferenceRow(item)
          case .orphanHeader:
            orphanHeaderRow(model: model, report: report)
              .padding(.top, 8)
          case .orphanEmpty:
            emptyInlineRow(L("No orphaned storage found."))
          case .orphan(let item):
            orphanRow(item: item, model: model)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 16)
    }
  }

  private func brokenHeaderRow(model: StorageHealthModel, count: Int) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Broken references")
          .font(.panel(.sectionHeader))
        Text("References in Favorites, Collections, Playlists, Automations, Metadata, Presets or Display Layouts pointing to missing wallpapers.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Repair all") {
        controller.launch(PanelActionCoordinator.key("storageHealthRepairBroken")) {
          try await model.repairAllBrokenReferences()
        }
      }
      .buttonStyle(.panelPrimary(size: .small))
      .disabled(model.isCleaning || count == 0)
    }
    .padding(.vertical, 4)
  }

  private func brokenReferenceRow(_ item: LibraryStorageHealthService.BrokenReferenceItem) -> some View {
    HStack(spacing: 8) {
      CapsuleBadge(style: .neutral) {
        Text(verbatim: StorageHealthModel.brokenSourceTitle(item.source))
      }
      VStack(alignment: .leading, spacing: 2) {
        if !item.containerName.isEmpty {
          Text(verbatim: item.containerName)
            .font(.panel(.body))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Text(verbatim: item.wallpaperID)
          .font(.panel(.caption, design: .monospaced))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .panelCardSurface()
  }

  private func orphanHeaderRow(
    model: StorageHealthModel, report: LibraryStorageHealthService.Report
  ) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("Orphaned storage")
            .font(.panel(.sectionHeader))
          if report.orphanedStorageBytes > 0 {
            Text(verbatim: ByteSize.format(Double(report.orphanedStorageBytes), locale: locale))
              .font(.panel(.caption).monospacedDigit())
              .foregroundStyle(theme.surface.muted.color)
          }
        }
        Text("Unused internal SceneStorage folders and cached SpacePosters files with no matching wallpaper or active Space assignment.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(role: .destructive) {
        controller.launch(PanelActionCoordinator.key("storageHealthCleanOrphans")) {
          try await model.cleanSelectedOrphans(locale: locale)
        }
      } label: {
        Text("Remove selected…")
      }
      .buttonStyle(.panelSecondary(size: .small))
      .disabled(model.isCleaning || model.selectedOrphanItems.isEmpty)
    }
    .padding(.vertical, 4)
  }

  private func orphanRow(
    item: LibraryStorageHealthService.OrphanedStorageItem,
    model: StorageHealthModel
  ) -> some View {
    let isSelected = model.selectedOrphanIDs.contains(item.id)
    return HStack(spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { isSelected },
          set: { _ in model.toggleOrphan(item.id) }
        )
      ) {
        EmptyView()
      }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(model.isCleaning)
      .accessibilityLabel(Text(verbatim: item.name))

      CapsuleBadge(style: .neutral) {
        Text(verbatim: StorageHealthModel.orphanKindTitle(item.kind))
      }

      Text(verbatim: item.name)
        .font(.panel(.caption, design: .monospaced))
        .foregroundStyle(theme.surface.text.color)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(verbatim: ByteSize.format(Double(item.sizeBytes), locale: locale))
        .font(.panel(.caption).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .panelCardSurface()
  }

  private func emptyInlineRow(_ message: String) -> some View {
    Text(verbatim: message)
      .font(.panel(.callout))
      .foregroundStyle(theme.surface.muted.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .panelCardSurface()
  }

  // MARK: - Footer

  private func footer(_ model: StorageHealthModel) -> some View {
    HStack(spacing: 10) {
      if let report = model.report {
        let count = report.scannedWallpaperCount
        Text(
          verbatim: count == 1
            ? L("1 wallpaper scanned") : L("\(count) wallpapers scanned")
        )
        .font(.panel(.caption).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)
      }
      Spacer(minLength: 8)
      Button("Done") { model.closeSheet() }
        .buttonStyle(.panelPrimary(size: .small))
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(theme.surface.surface.color)
  }
}
