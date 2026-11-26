import SwiftUI

/// Self-contained Settings › Storage card for manual cross-Mac Sync Folder push and pull.
///
/// Designed to drop into `StorageSettingsSection` in two lines
/// (`+ SyncFolderSection.items` and `SyncFolderSection()`).
///
/// Performs ZERO disk I/O inside `body`: remote snapshot metadata is inspected asynchronously on
/// `.onAppear` and whenever the bound folder changes or a push/pull completes.
struct SyncFolderSection: View {
  static let group = SettingsItem.Group("sync-folder", title: "Cross-Mac sync folder")

  static let syncFolderLocation = SettingsItem(
    id: "storage.sync-folder-location", section: .storage, group: group,
    title: "Sync folder",
    note:
      "Choose any folder synced by iCloud Drive, Syncthing, Dropbox, OneDrive, NAS or an external drive. Only your folder choice stays local to this Mac.",
    keywords: ["Choose folder…", "Clear"])

  static let syncFolderActions = SettingsItem(
    id: "storage.sync-folder-actions", section: .storage, group: group,
    title: "Manual sync",
    note:
      "Push a portable snapshot of your Workshop index, favorites, collections, metadata, playlists, presets, widgets, layouts and video trims, or pull and review conflicts before applying in place. Media files, sign-ins, local paths and custom shortcuts are never synced.",
    keywords: ["Push now", "Pull & Review…", "Merge", "Replace"])

  static let items = [syncFolderLocation, syncFolderActions]

  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale
  @State private var binding: SyncFolderBinding?
  @State private var remoteSummary: SyncFolderRemoteSummary = .noFolder
  @State private var isRefreshingSummary = false
  @State private var summaryTask: Task<Void, Never>?
  @State private var pendingPullPreview: SyncFolderPullPreview?
  @State private var isWorking = false
  @State private var statusMessage: String?
  @State private var notes: [String] = []
  @State private var errorMessage: String?

  var body: some View {
    SettingsGroup(Self.group, in: .storage) {
      let busy = isWorking || controller.isStoreBusy
      let hasFolder = binding != nil

      DisplaysRow(
        item: Self.syncFolderLocation,
        title: binding?.folderPath ?? L("No sync folder selected"),
        note: hasFolder ? "" : nil,
        details: folderDetailLines,
        isPath: hasFolder,
        isPlaceholder: !hasFolder,
        labelsControl: false
      ) {
        HStack(spacing: 8) {
          Button("Choose folder…") {
            chooseFolder()
          }
          .buttonStyle(.panelSecondary)
          .disabled(busy)

          if hasFolder {
            Button("Clear") {
              clearFolder()
            }
            .buttonStyle(.panelSecondary)
            .disabled(busy)
          }
        }
      }

      DisplaysRow(
        item: Self.syncFolderActions,
        details: activityDetailLines,
        labelsControl: false
      ) {
        HStack(spacing: 8) {
          Button("Push now") {
            pushNow()
          }
          .buttonStyle(.panelSecondary)
          .disabled(busy || !hasFolder)

          Button("Pull & Review…") {
            openPullPreview()
          }
          .buttonStyle(.panelPrimary(size: .small))
          .disabled(busy || !hasFolder)
        }
      }

      if isWorking {
        ProgressBar(value: nil)
          .accessibilityLabel(Text("Sync folder progress"))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      }

      if case .iCloudNotDownloaded = remoteSummary, errorMessage == nil {
        DisplaysNote(
          text: SyncFolderFailure.iCloudFileNotDownloaded(
            fileName: SyncFolderService.snapshotFileName
          ).localizedDescription,
          tone: .warning
        )
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
    .onAppear {
      binding = controller.syncFolderBinding()
      refreshRemoteSummary()
    }
    .onDisappear {
      summaryTask?.cancel()
      summaryTask = nil
    }
    .sheet(item: pullPreviewBinding) { wrapper in
      SyncFolderPullSheet(
        preview: wrapper.preview,
        onApplied: { report in
          pendingPullPreview = nil
          errorMessage = nil
          binding = controller.syncFolderBinding()
          statusMessage = Self.applySummaryText(report)
          notes = report.notes
          refreshRemoteSummary()
        },
        onCancel: { pendingPullPreview = nil }
      )
      .panelPresentationLocale()
    }
  }

  private var pullPreviewBinding: Binding<IdentifiableSyncPullPreview?> {
    Binding(
      get: { pendingPullPreview.map(IdentifiableSyncPullPreview.init) },
      set: { pendingPullPreview = $0?.preview }
    )
  }

  private var folderDetailLines: [String] {
    guard binding != nil else { return [] }
    if isRefreshingSummary, case .noFolder = remoteSummary {
      return [L("Checking sync folder…")]
    }
    switch remoteSummary {
    case .noFolder:
      return []
    case .missingSnapshot:
      return [L("No sync snapshot in this folder yet.")]
    case .iCloudNotDownloaded:
      return [L("Sync snapshot is waiting to download from iCloud Drive.")]
    case .unreadable(let message):
      return [message]
    case .available(let header):
      let when = header.exportedAt.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
      )
      let size = ByteSize.format(Double(header.byteCount), locale: locale)
      return [
        L("Latest snapshot from \(header.deviceName) · \(when) · \(size)")
      ]
    }
  }

  private var activityDetailLines: [String] {
    guard let binding else { return [] }
    var parts: [String] = []
    if let pushed = binding.lastPushAt {
      let text = pushed.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
      parts.append(L("Last push: \(text)"))
    }
    if let pulled = binding.lastPullAt {
      let text = pulled.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
      parts.append(L("Last pull: \(text)"))
    }
    return parts.isEmpty ? [] : [parts.joined(separator: " · ")]
  }

  private func refreshRemoteSummary() {
    summaryTask?.cancel()
    guard binding != nil else {
      remoteSummary = .noFolder
      isRefreshingSummary = false
      return
    }
    isRefreshingSummary = true
    summaryTask = Task { @MainActor in
      let summary = await controller.inspectSyncFolderSummary()
      guard !Task.isCancelled else { return }
      remoteSummary = summary
      isRefreshingSummary = false
      summaryTask = nil
    }
  }

  private func chooseFolder() {
    errorMessage = nil
    statusMessage = nil
    notes = []
    isWorking = true
    controller.launch(PanelActionCoordinator.key("syncFolderChoose")) {
      defer { isWorking = false }
      do {
        if let updated = try await controller.chooseSyncFolder() {
          binding = updated
          refreshRemoteSummary()
        }
      } catch {
        errorMessage = error.localizedDescription
        throw error
      }
    }
  }

  private func clearFolder() {
    errorMessage = nil
    statusMessage = nil
    notes = []
    isWorking = true
    controller.launch(PanelActionCoordinator.key("syncFolderClear")) {
      defer { isWorking = false }
      do {
        try await controller.clearSyncFolder()
        binding = nil
        remoteSummary = .noFolder
        summaryTask?.cancel()
        summaryTask = nil
      } catch {
        errorMessage = error.localizedDescription
        throw error
      }
    }
  }

  private func pushNow() {
    errorMessage = nil
    statusMessage = nil
    notes = []
    isWorking = true
    controller.launch(PanelActionCoordinator.key("syncFolderPush")) {
      defer { isWorking = false }
      do {
        let report = try await controller.pushToSyncFolder()
        binding = controller.syncFolderBinding()
        let size = ByteSize.format(Double(report.byteCount), locale: locale)
        statusMessage = L(
          "Sync snapshot pushed (\(size)): \(report.workshopItemCount) Workshop item(s), \(report.collectionsCount) collection(s), \(report.playlistsCount) playlist(s), \(report.presetsCount) preset(s)."
        )
        notes = report.notes
        refreshRemoteSummary()
      } catch {
        errorMessage = error.localizedDescription
        throw error
      }
    }
  }

  private func openPullPreview() {
    errorMessage = nil
    statusMessage = nil
    notes = []
    isWorking = true
    controller.launch(PanelActionCoordinator.key("syncFolderPreview")) {
      defer { isWorking = false }
      do {
        let preview = try await controller.previewSyncFolderPull()
        pendingPullPreview = preview
      } catch {
        errorMessage = error.localizedDescription
        throw error
      }
    }
  }

  private static func applySummaryText(_ report: SyncFolderPullApplyReport) -> String {
    let strategyLabel =
      report.strategy == .replace ? L("Replaced") : L("Merged")
    return L(
      "\(strategyLabel) sync snapshot: \(report.collectionsCreatedCount + report.collectionsUpdatedCount) collection(s), \(report.metadataWrittenCount) metadata entry(s), \(report.playlistsAppliedCount) playlist(s), \(report.presetsAppliedCount) preset(s), \(report.layoutsAppliedCount) layout(s), \(report.widgetsAppliedCount) widget(s), \(report.videoTrimsAppliedCount) video trim(s), \(report.queuedDownloadsCount) download(s) queued."
    )
  }
}

private struct IdentifiableSyncPullPreview: Identifiable {
  let preview: SyncFolderPullPreview
  var id: String { preview.digest }
}
