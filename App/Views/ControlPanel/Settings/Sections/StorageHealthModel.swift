import Foundation
import Observation

/// View model for the on-demand Library Storage Health & Cleanup Center in Settings › Storage.
///
/// Never runs at app launch and holds no idle timers: scans begin only when requested and cancel
/// cleanly when dismissed or when the panel stops. All wallpaper removals route through
/// `PanelController.trashStorageHealthWallpapers`, which uses `WallpaperDeletionService.moveToTrash`.
@MainActor
@Observable
final class StorageHealthModel {
  enum Tab: String, CaseIterable, Identifiable, Sendable {
    case duplicates
    case unused
    case maintenance

    var id: String { rawValue }

    @MainActor var title: String {
      switch self {
      case .duplicates: L("Duplicates")
      case .unused: L("Not used recently")
      case .maintenance: L("References & orphans")
      }
    }
  }

  enum ScanState: Equatable {
    case idle
    case scanning(LibraryStorageHealthService.ScanProgress)
    case ready(LibraryStorageHealthService.Report)
    case failed(String)
  }

  /// Single flattened row representation for the Maintenance tab so its `LazyVStack` renders one
  /// `ForEach` over stable ids.
  enum MaintenanceRow: Equatable, Identifiable {
    case brokenHeader
    case brokenEmpty
    case broken(LibraryStorageHealthService.BrokenReferenceItem)
    case orphanHeader
    case orphanEmpty
    case orphan(LibraryStorageHealthService.OrphanedStorageItem)

    var id: String {
      switch self {
      case .brokenHeader: "header.broken"
      case .brokenEmpty: "empty.broken"
      case .broken(let item): "broken.\(item.id)"
      case .orphanHeader: "header.orphan"
      case .orphanEmpty: "empty.orphan"
      case .orphan(let item): "orphan.\(item.id)"
      }
    }
  }

  unowned let controller: PanelController

  var isSheetPresented = false
  var selectedTab: Tab = .duplicates
  var minimumSize: LibraryStorageHealthService.MinimumSizeFilter = .mb100
  var recencyFilter: LibraryStorageHealthService.RecencyFilter = .days30
  private(set) var state: ScanState = .idle
  private(set) var selectedDuplicateIDs: Set<String> = []
  private(set) var selectedUnusedIDs: Set<String> = []
  private(set) var selectedOrphanIDs: Set<String> = []
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var isCleaning = false

  @ObservationIgnored private var previousReport: LibraryStorageHealthService.Report?
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var scanGeneration: UInt64 = 0
  @ObservationIgnored var service = LibraryStorageHealthService()
  @ObservationIgnored var nowProvider: @MainActor () -> Date = { Date() }

  init(controller: PanelController) {
    self.controller = controller
  }

  // MARK: - Derived state

  var report: LibraryStorageHealthService.Report? {
    if case .ready(let report) = state { return report }
    return nil
  }

  var isScanning: Bool {
    if case .scanning = state { return true }
    return false
  }

  var scanProgress: LibraryStorageHealthService.ScanProgress? {
    if case .scanning(let progress) = state { return progress }
    return nil
  }

  var filteredUnusedWallpapers: [LibraryStorageHealthService.UnusedWallpaperCandidate] {
    report?.unusedWallpapers(minimumSize: minimumSize, recency: recencyFilter) ?? []
  }

  var selectedDuplicateOrderedIDs: [String] {
    guard let report else { return [] }
    return report.duplicateGroups.flatMap { group in
      group.items.map(\.id).filter { selectedDuplicateIDs.contains($0) }
    }
  }

  var selectedDuplicateBytes: Int64 {
    guard let report else { return 0 }
    return report.duplicateGroups.reduce(0) { sum, group in
      sum + group.items
        .filter { selectedDuplicateIDs.contains($0.id) }
        .reduce(0) { $0 + max(0, $1.diskSizeBytes) }
    }
  }

  /// Selected unused IDs restricted to the currently visible filter results so changing a filter
  /// never acts on hidden wallpapers.
  var selectedFilteredUnusedIDs: [String] {
    filteredUnusedWallpapers.map(\.id).filter { selectedUnusedIDs.contains($0) }
  }

  var selectedUnusedBytes: Int64 {
    filteredUnusedWallpapers
      .filter { selectedUnusedIDs.contains($0.id) }
      .reduce(0) { $0 + max(0, $1.diskSizeBytes) }
  }

  var selectedOrphanItems: [LibraryStorageHealthService.OrphanedStorageItem] {
    guard let report else { return [] }
    return report.orphanedStorage.filter { selectedOrphanIDs.contains($0.id) }
  }

  var selectedOrphanBytes: Int64 {
    selectedOrphanItems.reduce(0) { $0 + max(0, $1.sizeBytes) }
  }

  var maintenanceIssueCount: Int {
    guard let report else { return 0 }
    return report.brokenReferences.count + report.orphanedStorage.count
  }

  var maintenanceRows: [MaintenanceRow] {
    guard let report else { return [] }
    var rows: [MaintenanceRow] = [.brokenHeader]
    if report.brokenReferences.isEmpty {
      rows.append(.brokenEmpty)
    } else {
      rows.append(contentsOf: report.brokenReferences.map(MaintenanceRow.broken))
    }
    rows.append(.orphanHeader)
    if report.orphanedStorage.isEmpty {
      rows.append(.orphanEmpty)
    } else {
      rows.append(contentsOf: report.orphanedStorage.map(MaintenanceRow.orphan))
    }
    return rows
  }

  func countBadge(for tab: Tab) -> Int {
    guard let report else { return 0 }
    switch tab {
    case .duplicates: return report.duplicateGroups.count
    case .unused: return filteredUnusedWallpapers.count
    case .maintenance: return maintenanceIssueCount
    }
  }

  /// Concise one-line summary for the Settings › Storage row.
  func summaryLine(locale: Locale = .current) -> String? {
    switch state {
    case .idle:
      return nil
    case .scanning(let progress):
      return Self.phaseTitle(progress.phase)
    case .failed(let message):
      return message
    case .ready(let report):
      let unusedCount = report.unusedWallpapers(minimumSize: minimumSize, recency: recencyFilter).count
      var parts: [String] = []
      if !report.duplicateGroups.isEmpty {
        let count = report.duplicateGroups.count
        parts.append(count == 1 ? L("1 duplicate group") : L("\(count) duplicate groups"))
      }
      if unusedCount > 0 {
        parts.append(L("\(unusedCount) not used recently"))
      }
      if !report.brokenReferences.isEmpty {
        let count = report.brokenReferences.count
        parts.append(count == 1 ? L("1 broken reference") : L("\(count) broken references"))
      }
      if !report.orphanedStorage.isEmpty {
        let count = report.orphanedStorage.count
        parts.append(count == 1 ? L("1 orphaned item") : L("\(count) orphaned items"))
      }
      if parts.isEmpty { return L("No issues found") }
      let reclaimable = report.totalReclaimableBytes(minimumSize: minimumSize, recency: recencyFilter)
      if reclaimable > 0 {
        let size = ByteSize.format(Double(reclaimable), locale: locale)
        parts.append(L("\(size) reclaimable"))
      }
      return parts.joined(separator: " · ")
    }
  }

  // MARK: - Sheet & scan lifecycle

  func openAndScan() {
    isSheetPresented = true
    switch state {
    case .idle, .failed:
      startScan()
    case .scanning, .ready:
      break
    }
  }

  func openSheet() {
    isSheetPresented = true
  }

  func closeSheet() {
    isSheetPresented = false
    if isScanning { cancelScan() }
  }

  func startScan() {
    scanTask?.cancel()
    scanGeneration &+= 1
    let generation = scanGeneration
    if case .ready(let existing) = state {
      previousReport = existing
    }
    statusMessage = nil
    errorMessage = nil
    let input = controller.makeStorageHealthInput(now: nowProvider())
    state = .scanning(
      LibraryStorageHealthService.ScanProgress(
        phase: .measuring, completed: 0, total: input.wallpapers.count))
    let service = self.service
    scanTask = Task { @MainActor [weak self] in
      await self?.runScan(input: input, generation: generation, service: service)
    }
  }

  /// Async entry point used by typed controller actions and tests to await scan completion.
  func scanNow() async {
    startScan()
    await scanTask?.value
  }

  func cancelScan() {
    scanGeneration &+= 1
    scanTask?.cancel()
    scanTask = nil
    if case .scanning = state {
      if let previousReport {
        state = .ready(previousReport)
      } else {
        state = .idle
      }
    }
  }

  private func runScan(
    input: LibraryStorageHealthService.Input,
    generation: UInt64,
    service: LibraryStorageHealthService
  ) async {
    do {
      let report = try await service.scan(input: input) { [weak self] progress in
        Task { @MainActor [weak self] in
          guard let self, self.scanGeneration == generation, case .scanning = self.state else { return }
          self.state = .scanning(progress)
        }
      }
      guard !Task.isCancelled, scanGeneration == generation else { return }
      applyReport(report)
      scanTask = nil
    } catch is CancellationError {
      guard scanGeneration == generation else { return }
      if let previousReport {
        state = .ready(previousReport)
      } else {
        state = .idle
      }
      scanTask = nil
    } catch {
      guard scanGeneration == generation else { return }
      state = .failed(error.localizedDescription)
      errorMessage = error.localizedDescription
      scanTask = nil
    }
  }

  private func applyReport(_ report: LibraryStorageHealthService.Report) {
    previousReport = report
    state = .ready(report)
    // Pre-select redundant copies while strictly preserving every recommended keep copy.
    selectedDuplicateIDs = Self.recommendedDuplicateTrashIDs(in: report)
    // Unused wallpapers are always opt-in so nothing is selected without review.
    selectedUnusedIDs = []
    selectedOrphanIDs = Set(report.orphanedStorage.map(\.id))
    // Default to the first tab with actionable items so the user lands directly on findings.
    if !report.duplicateGroups.isEmpty {
      selectedTab = .duplicates
    } else if !filteredUnusedWallpapers.isEmpty {
      selectedTab = .unused
    } else if !report.brokenReferences.isEmpty || !report.orphanedStorage.isEmpty {
      selectedTab = .maintenance
    }
  }

  static func recommendedDuplicateTrashIDs(
    in report: LibraryStorageHealthService.Report
  ) -> Set<String> {
    var ids = Set<String>()
    for group in report.duplicateGroups {
      let nonKeep = group.items.filter { !$0.isRecommendedKeep }.map(\.id)
      // Safety guard: never select every copy of a duplicate group.
      if nonKeep.count < group.items.count {
        ids.formUnion(nonKeep)
      }
    }
    return ids
  }

  // MARK: - Selection management

  /// True when toggling `wallpaperID` preserves at least one unselected copy in `group`.
  func canToggleDuplicate(
    _ wallpaperID: String, in group: LibraryStorageHealthService.DuplicateGroup
  ) -> Bool {
    if selectedDuplicateIDs.contains(wallpaperID) { return true }
    let selectedInGroup = group.items.filter { selectedDuplicateIDs.contains($0.id) }.count
    return selectedInGroup + 1 < group.items.count
  }

  @discardableResult
  func toggleDuplicate(
    _ wallpaperID: String, in group: LibraryStorageHealthService.DuplicateGroup
  ) -> Bool {
    if selectedDuplicateIDs.contains(wallpaperID) {
      selectedDuplicateIDs.remove(wallpaperID)
      return true
    }
    guard canToggleDuplicate(wallpaperID, in: group) else { return false }
    selectedDuplicateIDs.insert(wallpaperID)
    return true
  }

  func selectRecommendedDuplicates() {
    guard let report else { return }
    selectedDuplicateIDs = Self.recommendedDuplicateTrashIDs(in: report)
  }

  func clearDuplicateSelection() {
    selectedDuplicateIDs.removeAll()
  }

  func toggleUnused(_ wallpaperID: String) {
    if !selectedUnusedIDs.insert(wallpaperID).inserted {
      selectedUnusedIDs.remove(wallpaperID)
    }
  }

  func selectAllFilteredUnused() {
    selectedUnusedIDs.formUnion(filteredUnusedWallpapers.map(\.id))
  }

  func clearUnusedSelection() {
    selectedUnusedIDs.subtract(filteredUnusedWallpapers.map(\.id))
  }

  func toggleOrphan(_ orphanID: String) {
    if !selectedOrphanIDs.insert(orphanID).inserted {
      selectedOrphanIDs.remove(orphanID)
    }
  }

  func selectAllOrphans() {
    guard let report else { return }
    selectedOrphanIDs = Set(report.orphanedStorage.map(\.id))
  }

  func clearOrphanSelection() {
    selectedOrphanIDs.removeAll()
  }

  // MARK: - Actions

  func trashSelectedDuplicates() async throws {
    guard let report, !isCleaning else { return }
    let ids = selectedDuplicateOrderedIDs
    guard !ids.isEmpty else { return }
    let selectedSet = Set(ids)
    for group in report.duplicateGroups {
      if group.items.allSatisfy({ selectedSet.contains($0.id) }) {
        let message = L("Keep at least one copy in each duplicate group.")
        errorMessage = message
        throw WallpaperActionError(message: message)
      }
    }
    isCleaning = true
    statusMessage = nil
    errorMessage = nil
    defer { isCleaning = false }
    do {
      guard let deletion = try await controller.trashStorageHealthWallpapers(ids) else { return }
      let count = deletion.deleted.count
      statusMessage =
        count == 1
        ? L("Moved 1 duplicate wallpaper to Trash.")
        : L("Moved \(count) duplicate wallpapers to Trash.")
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func trashSelectedUnused() async throws {
    guard !isCleaning else { return }
    let ids = selectedFilteredUnusedIDs
    guard !ids.isEmpty else { return }
    isCleaning = true
    statusMessage = nil
    errorMessage = nil
    defer { isCleaning = false }
    do {
      guard let deletion = try await controller.trashStorageHealthWallpapers(ids) else { return }
      let count = deletion.deleted.count
      statusMessage =
        count == 1
        ? L("Moved 1 wallpaper to Trash.")
        : L("Moved \(count) wallpapers to Trash.")
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func repairAllBrokenReferences() async throws {
    guard let report, !report.brokenReferences.isEmpty, !isCleaning else { return }
    isCleaning = true
    statusMessage = nil
    errorMessage = nil
    defer { isCleaning = false }
    do {
      let repaired = try await controller.repairBrokenReferences(report.brokenReferences)
      statusMessage =
        repaired == 1
        ? L("Repaired 1 broken reference.")
        : L("Repaired \(repaired) broken references.")
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func cleanSelectedOrphans(locale: Locale = .current) async throws {
    let items = selectedOrphanItems
    guard !items.isEmpty, !isCleaning else { return }
    isCleaning = true
    statusMessage = nil
    errorMessage = nil
    defer { isCleaning = false }
    do {
      guard let result = try await controller.cleanOrphanedStorage(items) else { return }
      let formatted = ByteSize.format(Double(result.reclaimedBytes), locale: locale)
      let count = result.removedIDs.count
      statusMessage =
        count == 1
        ? L("Removed 1 orphaned item (\(formatted)).")
        : L("Removed \(count) orphaned items (\(formatted)).")
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  // MARK: - Incremental report updates

  func recordDeletedWallpapers(_ deletedIDs: Set<String>) {
    guard !deletedIDs.isEmpty else { return }
    selectedDuplicateIDs.subtract(deletedIDs)
    selectedUnusedIDs.subtract(deletedIDs)
    if case .ready(let report) = state {
      let updated = report.removingDeletedWallpapers(deletedIDs)
      previousReport = updated
      state = .ready(updated)
      // Ensure remaining selections still respect the keep-at-least-one-copy invariant.
      for group in updated.duplicateGroups {
        if group.items.allSatisfy({ selectedDuplicateIDs.contains($0.id) }),
          let keep = group.recommendedKeepID
        {
          selectedDuplicateIDs.remove(keep)
        }
      }
    }
  }

  func recordRepairedBrokenReferences(_ repairedIDs: Set<String>) {
    guard !repairedIDs.isEmpty else { return }
    if case .ready(let report) = state {
      let updated = report.removingBrokenReferences(repairedIDs)
      previousReport = updated
      state = .ready(updated)
    }
  }

  func recordCleanedOrphans(_ removedIDs: Set<String>) {
    guard !removedIDs.isEmpty else { return }
    selectedOrphanIDs.subtract(removedIDs)
    if case .ready(let report) = state {
      let updated = report.removingOrphanedStorage(removedIDs)
      previousReport = updated
      state = .ready(updated)
    }
  }

  // MARK: - Formatting helpers

  static func phaseTitle(_ phase: LibraryStorageHealthService.ScanProgress.Phase) -> String {
    switch phase {
    case .measuring: L("Measuring library…")
    case .fingerprinting: L("Fingerprinting size matches…")
    case .verifying: L("Verifying exact duplicates…")
    case .auditingStorage: L("Checking references and orphaned storage…")
    }
  }

  static func sizeFilterTitle(
    _ filter: LibraryStorageHealthService.MinimumSizeFilter
  ) -> String {
    switch filter {
    case .mb100: L("100 MB or larger")
    case .mb250: L("250 MB or larger")
    case .mb500: L("500 MB or larger")
    case .any: L("Any size")
    }
  }

  static func recencyFilterTitle(_ filter: LibraryStorageHealthService.RecencyFilter) -> String {
    switch filter {
    case .days30: L("Not used in 30+ days")
    case .days90: L("Not used in 90+ days")
    case .noRecentRecordOnly: L("No recent use recorded")
    }
  }

  /// Never claims a wallpaper was "Never used": `WallpaperHistoryStore` keeps a bounded window per
  /// display, so an absent timestamp always reads "No recent use recorded".
  static func lastUsedText(_ date: Date?, locale: Locale = .current) -> String {
    guard let date else { return L("No recent use recorded") }
    let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    return L("Last used \(day)")
  }

  static func referenceBadgeTitle(
    _ references: Set<LibraryStorageHealthService.WallpaperReferenceKind>
  ) -> String? {
    if references.contains(.activeDisplay) { return L("Active") }
    if references.contains(.lockScreen) || references.contains(.screenSaver) {
      return L("Lock screen")
    }
    if references.contains(.favorite) { return L("Favorite") }
    if !references.isEmpty { return L("Referenced") }
    return nil
  }

  static func brokenSourceTitle(_ source: LibraryStorageHealthService.BrokenReferenceSource) -> String {
    switch source {
    case .favorites: L("Favorites")
    case .collections: L("Collections")
    case .playlists: L("Playlists")
    case .automation: L("Automation")
    case .metadata: L("Metadata")
    case .presets: L("Presets")
    case .displayLayouts: L("Display layouts")
    }
  }

  static func orphanKindTitle(_ kind: LibraryStorageHealthService.OrphanedStorageKind) -> String {
    switch kind {
    case .sceneStorage: L("Scene storage")
    case .spacePoster: L("Space poster")
    }
  }
}
