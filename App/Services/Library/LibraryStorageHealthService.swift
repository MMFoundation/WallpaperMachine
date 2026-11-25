import CryptoKit
import Foundation

/// On-demand, cancellable background audit of wallpaper library storage health:
///
/// 1. **Exact duplicates** via a 3-stage pipeline:
///    - Stage 1: Group candidates by total content byte size (ignoring zero-byte or metadata-only items).
///    - Stage 2: Fast 64 KB head + 64 KB tail SHA-256 fingerprint on size collisions.
///    - Stage 3: Full streaming SHA-256 verification on fast-hash collisions.
///    Scene folders hash `scene.pkg` and all non-metadata asset files deterministically by sorted
///    relative path and byte contents (never just `project.json` or a preview thumbnail). Video and
///    still-image wallpapers hash their primary content file bytes directly so identical media with
///    different titles or filenames still match.
/// 2. **Large, not-recently-used wallpapers** cross-referenced against disk sizes, bounded usage
///    history (`WallpaperHistoryStore`), and full reference protection sets across active displays,
///    Favorites, Collections, Playlists, Automation Rules, Saved Display Layouts, and Lock Screen /
///    Screen Saver assignments.
/// 3. **Broken references & orphaned storage**: dangling wallpaper IDs across persisted stores, plus
///    orphaned `SceneStorage` directories and orphaned `SpacePosters` files under managed paths.
///
/// Performs zero work at app launch and runs all filesystem and cryptographic I/O off the main actor.
struct LibraryStorageHealthService: Sendable {
    /// Chunk size read from the start and end of each content file during Stage 2 fast fingerprinting.
    static let fastHashChunkSize = 64 * 1024
    /// Streaming read buffer size during Stage 3 full SHA-256 verification.
    static let fullHashBufferSize = 256 * 1024

    // MARK: - Filter types

    enum MinimumSizeFilter: Int64, CaseIterable, Identifiable, Sendable {
        case mb100 = 104_857_600
        case mb250 = 262_144_000
        case mb500 = 524_288_000
        case any = 0

        var id: Int64 { rawValue }
    }

    enum RecencyFilter: String, CaseIterable, Identifiable, Sendable {
        case days30
        case days90
        case noRecentRecordOnly

        var id: String { rawValue }

        /// Matches wallpapers whose recorded last use is at least the chosen age old, or that have
        /// no recent use recorded (`lastUsedAt == nil`). Because `WallpaperHistoryStore` keeps a
        /// bounded number of recent entries per display, `nil` always means "no recent use recorded",
        /// never "never used".
        func matches(lastUsedAt: Date?, relativeTo now: Date) -> Bool {
            switch self {
            case .days30:
                guard let lastUsedAt else { return true }
                return now.timeIntervalSince(lastUsedAt) >= 30 * 86_400
            case .days90:
                guard let lastUsedAt else { return true }
                return now.timeIntervalSince(lastUsedAt) >= 90 * 86_400
            case .noRecentRecordOnly:
                return lastUsedAt == nil
            }
        }
    }

    // MARK: - Domain models

    enum WallpaperReferenceKind: String, Hashable, CaseIterable, Sendable {
        case activeDisplay
        case favorite
        case collection
        case playlist
        case automation
        case displayLayout
        case lockScreen
        case screenSaver
    }

    enum BrokenReferenceSource: String, Hashable, CaseIterable, Sendable {
        case favorites
        case collections
        case playlists
        case automation
        case metadata
        case presets
        case displayLayouts
    }

    enum OrphanedStorageKind: String, Hashable, CaseIterable, Sendable {
        case sceneStorage
        case spacePoster
    }

    struct SpacePosterKey: Hashable, Sendable {
        var display: String
        var wallpaperID: String
    }

    struct WallpaperRecord: Equatable, Hashable, Sendable {
        var id: String
        var title: String
        var kind: BridgeWallpaperKind
        /// Previously measured folder size from `LibraryMetricsService`, when available.
        var cachedSizeBytes: Int64?
        /// Previously read added/creation date from `LibraryMetricsService`, when available.
        var addedAt: Date?
    }

    struct CollectionRef: Equatable, Hashable, Sendable {
        var id: String
        var name: String
        var wallpaperIDs: [String]
    }

    struct DisplayPlaylistRef: Equatable, Hashable, Sendable {
        var displayID: String
        var displayTitle: String
        var wallpaperIDs: [String]
        var dayWallpaperID: String?
        var nightWallpaperID: String?
    }

    struct PlaylistPlanRef: Equatable, Hashable, Sendable {
        var id: String
        var name: String
        var wallpaperIDs: [String]
        var dayWallpaperID: String?
        var nightWallpaperID: String?
    }

    struct AutomationRef: Equatable, Hashable, Sendable {
        var displayID: String
        var displayTitle: String
        var mode: DisplayWallpaperAutomation.Mode
        var usesSpaces: Bool
        var ruleWallpaperIDs: [String]
        var enabledRuleWallpaperIDs: [String]
        var lightWallpaperID: String?
        var darkWallpaperID: String?
        var batteryWallpaperID: String?
        var spaceWallpaperIDs: [String: String]

        init(
            displayID: String,
            displayTitle: String,
            mode: DisplayWallpaperAutomation.Mode,
            usesSpaces: Bool? = nil,
            ruleWallpaperIDs: [String],
            enabledRuleWallpaperIDs: [String]? = nil,
            lightWallpaperID: String?,
            darkWallpaperID: String?,
            batteryWallpaperID: String? = nil,
            spaceWallpaperIDs: [String: String]
        ) {
            self.displayID = displayID
            self.displayTitle = displayTitle
            self.mode = mode
            self.usesSpaces = usesSpaces ?? (mode == .spaces)
            self.ruleWallpaperIDs = ruleWallpaperIDs
            self.enabledRuleWallpaperIDs = enabledRuleWallpaperIDs ?? ruleWallpaperIDs
            self.lightWallpaperID = lightWallpaperID
            self.darkWallpaperID = darkWallpaperID
            self.batteryWallpaperID = batteryWallpaperID
            self.spaceWallpaperIDs = spaceWallpaperIDs
        }
    }

    struct DisplayLayoutRef: Equatable, Hashable, Sendable {
        var id: String
        var name: String
        var wallpaperIDs: [String]
    }

    struct PresetRef: Equatable, Hashable, Sendable {
        var id: String
        var name: String
        var wallpaperID: String
    }

    /// Snapshot of all store references gathered on the main actor before running background I/O.
    struct ReferenceSnapshot: Equatable, Sendable {
        var activeDisplayWallpaperIDs: Set<String> = []
        var favoriteIDs: Set<String> = []
        var collections: [CollectionRef] = []
        var displayPlaylists: [DisplayPlaylistRef] = []
        var playlistPlans: [PlaylistPlanRef] = []
        var automations: [AutomationRef] = []
        var appRuleWallpaperIDs: Set<String> = []
        var displayLayouts: [DisplayLayoutRef] = []
        var metadataWallpaperIDs: Set<String> = []
        var presets: [PresetRef] = []
        var lockScreenWallpaperIDs: Set<String> = []
        var screenSaverWallpaperIDs: Set<String> = []
        var activeSpacePosterKeys: Set<SpacePosterKey> = []

        /// Returns all protection reasons blocking `wallpaperID` from being flagged as an
        /// unreferenced cleanup candidate.
        func referenceReasons(for wallpaperID: String) -> Set<WallpaperReferenceKind> {
            var reasons = Set<WallpaperReferenceKind>()
            if activeDisplayWallpaperIDs.contains(wallpaperID) { reasons.insert(.activeDisplay) }
            if favoriteIDs.contains(wallpaperID) { reasons.insert(.favorite) }
            if collections.contains(where: { $0.wallpaperIDs.contains(wallpaperID) }) {
                reasons.insert(.collection)
            }
            let inDisplayPlaylist = displayPlaylists.contains { playlist in
                playlist.wallpaperIDs.contains(wallpaperID)
                    || playlist.dayWallpaperID == wallpaperID
                    || playlist.nightWallpaperID == wallpaperID
            }
            let inPlan = playlistPlans.contains { plan in
                plan.wallpaperIDs.contains(wallpaperID)
                    || plan.dayWallpaperID == wallpaperID
                    || plan.nightWallpaperID == wallpaperID
            }
            if inDisplayPlaylist || inPlan { reasons.insert(.playlist) }
            let inAutomation = automations.contains { config in
                config.ruleWallpaperIDs.contains(wallpaperID)
                    || config.lightWallpaperID == wallpaperID
                    || config.darkWallpaperID == wallpaperID
                    || config.batteryWallpaperID == wallpaperID
                    || config.spaceWallpaperIDs.values.contains(wallpaperID)
            }
            if inAutomation || appRuleWallpaperIDs.contains(wallpaperID) {
                reasons.insert(.automation)
            }
            if displayLayouts.contains(where: { $0.wallpaperIDs.contains(wallpaperID) }) {
                reasons.insert(.displayLayout)
            }
            if lockScreenWallpaperIDs.contains(wallpaperID) { reasons.insert(.lockScreen) }
            if screenSaverWallpaperIDs.contains(wallpaperID) { reasons.insert(.screenSaver) }
            return reasons
        }

        func hasMetadataOrPresets(for wallpaperID: String) -> Bool {
            metadataWallpaperIDs.contains(wallpaperID)
                || presets.contains(where: { $0.wallpaperID == wallpaperID })
        }

        /// Expected filenames inside `ClientPaths.spacePosterCacheURL` matching active Space
        /// wallpaper assignments (including stacked appearance/schedule rule posters, mirroring
        /// `AppDelegate.retainSpacePosters()`) for currently installed wallpapers.
        func expectedSpacePosterFileNames(installedIDs: Set<String>) -> Set<String> {
            var keys = Set<SpacePosterKey>()
            for config in automations where config.usesSpaces {
                for wallpaperID in config.spaceWallpaperIDs.values where installedIDs.contains(wallpaperID) {
                    keys.insert(SpacePosterKey(display: config.displayID, wallpaperID: wallpaperID))
                }
                switch config.mode {
                case .appearance:
                    for wallpaperID in [config.lightWallpaperID, config.darkWallpaperID].compactMap({ $0 })
                    where installedIDs.contains(wallpaperID) {
                        keys.insert(SpacePosterKey(display: config.displayID, wallpaperID: wallpaperID))
                    }
                case .schedule:
                    for wallpaperID in config.enabledRuleWallpaperIDs where installedIDs.contains(wallpaperID) {
                        keys.insert(SpacePosterKey(display: config.displayID, wallpaperID: wallpaperID))
                    }
                case .off, .spaces:
                    break
                }
            }
            for key in activeSpacePosterKeys where installedIDs.contains(key.wallpaperID) {
                keys.insert(key)
            }
            return Set(keys.map { LibraryStorageHealthService.spacePosterFileName(display: $0.display, wallpaperID: $0.wallpaperID) })
        }
    }

    struct Input: Sendable {
        var libraryURL: URL
        var sceneStorageURL: URL
        var spacePosterCacheURL: URL
        var now: Date = Date()
        var wallpapers: [WallpaperRecord]
        var lastUsedDates: [String: Date] = [:]
        var references: ReferenceSnapshot = ReferenceSnapshot()
    }

    struct ScanProgress: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case measuring
            case fingerprinting
            case verifying
            case auditingStorage
        }

        var phase: Phase
        var completed: Int
        var total: Int

        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(max(Double(completed) / Double(total), 0), 1)
        }
    }

    struct DuplicateItem: Equatable, Hashable, Identifiable, Sendable {
        let id: String
        let title: String
        let kind: BridgeWallpaperKind
        let diskSizeBytes: Int64
        let addedAt: Date?
        let lastUsedAt: Date?
        let references: Set<WallpaperReferenceKind>
        let isRecommendedKeep: Bool
    }

    struct DuplicateGroup: Equatable, Hashable, Identifiable, Sendable {
        let id: String
        let contentDigest: String
        let contentSizeBytes: Int64
        /// Ordered with the recommended keep copy first.
        let items: [DuplicateItem]

        var recommendedKeepID: String? {
            items.first(where: \.isRecommendedKeep)?.id
        }

        /// Disk bytes freed if every non-recommended copy in this group is moved to Trash.
        var reclaimableBytes: Int64 {
            items.filter { !$0.isRecommendedKeep }.reduce(0) { $0 + max(0, $1.diskSizeBytes) }
        }
    }

    struct UnusedWallpaperCandidate: Equatable, Hashable, Identifiable, Sendable {
        let id: String
        let title: String
        let kind: BridgeWallpaperKind
        let diskSizeBytes: Int64
        let addedAt: Date?
        let lastUsedAt: Date?
    }

    struct BrokenReferenceItem: Equatable, Hashable, Identifiable, Sendable {
        let id: String
        let source: BrokenReferenceSource
        let containerID: String
        let containerName: String
        let wallpaperID: String
    }

    struct OrphanedStorageItem: Equatable, Hashable, Identifiable, Sendable {
        let id: String
        let kind: OrphanedStorageKind
        let name: String
        let url: URL
        let sizeBytes: Int64
    }

    struct PipelineStats: Equatable, Sendable {
        var candidatesScanned: Int = 0
        var stage1SizeCollisionCandidates: Int = 0
        var stage2FastHashCollisionCandidates: Int = 0
        var stage3VerifiedDuplicateGroups: Int = 0
    }

    struct Report: Equatable, Sendable {
        var scannedAt: Date
        var scannedWallpaperCount: Int
        var duplicateGroups: [DuplicateGroup]
        var unreferencedWallpapers: [UnusedWallpaperCandidate]
        var brokenReferences: [BrokenReferenceItem]
        var orphanedStorage: [OrphanedStorageItem]
        var pipelineStats: PipelineStats

        var duplicateReclaimableBytes: Int64 {
            duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        }

        var duplicateRedundantCopyCount: Int {
            duplicateGroups.reduce(0) { $0 + max(0, $1.items.count - 1) }
        }

        var orphanedStorageBytes: Int64 {
            orphanedStorage.reduce(0) { $0 + max(0, $1.sizeBytes) }
        }

        func unusedWallpapers(
            minimumSize: MinimumSizeFilter, recency: RecencyFilter
        ) -> [UnusedWallpaperCandidate] {
            unreferencedWallpapers.filter { candidate in
                candidate.diskSizeBytes >= minimumSize.rawValue
                    && recency.matches(lastUsedAt: candidate.lastUsedAt, relativeTo: scannedAt)
            }
        }

        func unusedReclaimableBytes(
            minimumSize: MinimumSizeFilter, recency: RecencyFilter
        ) -> Int64 {
            unusedWallpapers(minimumSize: minimumSize, recency: recency)
                .reduce(0) { $0 + max(0, $1.diskSizeBytes) }
        }

        func totalReclaimableBytes(
            minimumSize: MinimumSizeFilter = .mb100, recency: RecencyFilter = .days30
        ) -> Int64 {
            let duplicateIDs = Set(duplicateGroups.flatMap { group in
                group.items.filter { !$0.isRecommendedKeep }.map(\.id)
            })
            let unusedOnlyBytes = unusedWallpapers(minimumSize: minimumSize, recency: recency)
                .filter { !duplicateIDs.contains($0.id) }
                .reduce(Int64(0)) { $0 + max(0, $1.diskSizeBytes) }
            return duplicateReclaimableBytes + unusedOnlyBytes + orphanedStorageBytes
        }

        /// Returns a copy with trashed wallpaper IDs pruned immediately in memory without requiring
        /// a full disk re-scan.
        func removingDeletedWallpapers(_ deletedIDs: Set<String>) -> Report {
            guard !deletedIDs.isEmpty else { return self }
            var copy = self
            copy.duplicateGroups = duplicateGroups.compactMap { group in
                let remaining = group.items.filter { !deletedIDs.contains($0.id) }
                guard remaining.count >= 2 else { return nil }
                if remaining.contains(where: \.isRecommendedKeep) {
                    return DuplicateGroup(
                        id: group.id, contentDigest: group.contentDigest,
                        contentSizeBytes: group.contentSizeBytes, items: remaining)
                }
                // If the previous recommended keep copy was explicitly removed, promote the next best.
                let promoted = remaining.enumerated().map { index, item in
                    DuplicateItem(
                        id: item.id, title: item.title, kind: item.kind,
                        diskSizeBytes: item.diskSizeBytes, addedAt: item.addedAt,
                        lastUsedAt: item.lastUsedAt, references: item.references,
                        isRecommendedKeep: index == 0)
                }
                return DuplicateGroup(
                    id: group.id, contentDigest: group.contentDigest,
                    contentSizeBytes: group.contentSizeBytes, items: promoted)
            }
            copy.unreferencedWallpapers = unreferencedWallpapers.filter { !deletedIDs.contains($0.id) }
            copy.scannedWallpaperCount = max(0, scannedWallpaperCount - deletedIDs.count)
            return copy
        }

        func removingBrokenReferences(_ repairedIDs: Set<String>) -> Report {
            guard !repairedIDs.isEmpty else { return self }
            var copy = self
            copy.brokenReferences = brokenReferences.filter { !repairedIDs.contains($0.id) }
            return copy
        }

        func removingOrphanedStorage(_ removedIDs: Set<String>) -> Report {
            guard !removedIDs.isEmpty else { return self }
            var copy = self
            copy.orphanedStorage = orphanedStorage.filter { !removedIDs.contains($0.id) }
            return copy
        }
    }

    struct OrphanCleanupReport: Equatable, Sendable {
        struct Failure: Equatable, Sendable {
            let id: String
            let name: String
            let message: String
        }

        var removedIDs: [String] = []
        var reclaimedBytes: Int64 = 0
        var failures: [Failure] = []
    }

    // MARK: - Internal content descriptors

    private struct AssetFile: Sendable {
        let relativePath: String
        let url: URL
        let size: Int64
    }

    private enum ContentTarget: Sendable {
        /// Primary media file for video or packaged still-image wallpapers (filename ignored so
        /// renamed identical files still match).
        case primaryFile(url: URL, size: Int64)
        /// Multi-file scene (`scene.pkg` + asset files) or web wallpaper bundle, hashed with
        /// deterministic sorted relative paths and file sizes + contents.
        case directoryAssets([AssetFile])

        var domainTag: String {
            switch self {
            case .primaryFile: return "primary\0"
            case .directoryAssets: return "assets\0"
            }
        }

        var totalContentBytes: Int64 {
            switch self {
            case .primaryFile(_, let size): return size
            case .directoryAssets(let files): return files.reduce(0) { $0 + $1.size }
            }
        }
    }

    private struct ScannedCandidate: Sendable {
        let record: WallpaperRecord
        let diskSizeBytes: Int64
        let addedAt: Date?
        let lastUsedAt: Date?
        let references: Set<WallpaperReferenceKind>
        let hasMetadataOrPresets: Bool
        let content: ContentTarget?
    }

    // MARK: - Public operations

    /// Runs the full 3-category storage health audit off the main actor.
    func scan(
        input: Input,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> Report {
        let worker = Task.detached(priority: .utility) { () throws -> Report in
            try Self.performScan(input: input, onProgress: onProgress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Safely deletes verified orphaned internal cache/storage artifacts (`SceneStorage` folders
    /// and `SpacePosters` files) after validating every target strictly stays inside its owning
    /// directory with no symlink escapes or path traversal. Never touches user wallpaper folders.
    func cleanOrphanedStorage(
        _ items: [OrphanedStorageItem],
        sceneStorageURL: URL,
        spacePosterCacheURL: URL
    ) async throws -> OrphanCleanupReport {
        let worker = Task.detached(priority: .utility) { () throws -> OrphanCleanupReport in
            try Self.performOrphanCleanup(
                items: items, sceneStorageURL: sceneStorageURL, spacePosterCacheURL: spacePosterCacheURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Matches `DesktopSpacePosterCache.url(for:)` filename hashing identically.
    static func spacePosterFileName(display: String, wallpaperID: String) -> String {
        let digest = SHA256.hash(data: Data((display + "\u{0}" + wallpaperID).utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    // MARK: - Scan implementation

    private static func performScan(
        input: Input,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> Report {
        let fileManager = FileManager.default
        let canonicalLibrary = input.libraryURL.resolvingSymlinksInPath().standardizedFileURL
        let sortedWallpapers = input.wallpapers.sorted { $0.id < $1.id }
        let installedIDs = Set(sortedWallpapers.map(\.id))

        var stats = PipelineStats()
        stats.candidatesScanned = sortedWallpapers.count

        // Stage 1: Inspect folders, gather disk sizes & content descriptors.
        onProgress?(ScanProgress(phase: .measuring, completed: 0, total: sortedWallpapers.count))
        var scanned: [ScannedCandidate] = []
        scanned.reserveCapacity(sortedWallpapers.count)
        for (index, record) in sortedWallpapers.enumerated() {
            try Task.checkCancellation()
            let folder = input.libraryURL.appendingPathComponent(record.id, isDirectory: true)
            let inspection = inspectWallpaperFolder(
                record: record, folder: folder, canonicalLibrary: canonicalLibrary, fileManager: fileManager)
            let diskSize = record.cachedSizeBytes ?? inspection.measuredFolderBytes
            let addedAt = record.addedAt ?? inspection.addedAt
            let lastUsedAt = input.lastUsedDates[record.id]
            let refs = input.references.referenceReasons(for: record.id)
            let hasMeta = input.references.hasMetadataOrPresets(for: record.id)
            scanned.append(
                ScannedCandidate(
                    record: record, diskSizeBytes: max(0, diskSize), addedAt: addedAt,
                    lastUsedAt: lastUsedAt, references: refs, hasMetadataOrPresets: hasMeta,
                    content: inspection.content))
            if (index + 1) % 8 == 0 || index + 1 == sortedWallpapers.count {
                onProgress?(ScanProgress(phase: .measuring, completed: index + 1, total: sortedWallpapers.count))
            }
        }

        // Stage 1 grouping: Group by total content byte size (ignoring zero-byte / empty content).
        var sizeBuckets: [Int64: [ScannedCandidate]] = [:]
        for candidate in scanned {
            guard let content = candidate.content else { continue }
            let size = content.totalContentBytes
            guard size > 0 else { continue }
            sizeBuckets[size, default: []].append(candidate)
        }
        let stage1Collisions = sizeBuckets.values
            .filter { $0.count >= 2 }
            .flatMap { $0 }
        stats.stage1SizeCollisionCandidates = stage1Collisions.count

        // Stage 2: Fast 64 KB head + 64 KB tail SHA-256 fingerprint on size collisions.
        onProgress?(ScanProgress(phase: .fingerprinting, completed: 0, total: stage1Collisions.count))
        var fastBuckets: [String: [ScannedCandidate]] = [:]
        for (index, candidate) in stage1Collisions.enumerated() {
            try Task.checkCancellation()
            guard let content = candidate.content else { continue }
            if let fastDigest = try computeFastFingerprint(content) {
                fastBuckets[fastDigest, default: []].append(candidate)
            }
            onProgress?(ScanProgress(phase: .fingerprinting, completed: index + 1, total: stage1Collisions.count))
        }
        let stage2Collisions = fastBuckets.values
            .filter { $0.count >= 2 }
            .flatMap { $0 }
        stats.stage2FastHashCollisionCandidates = stage2Collisions.count

        // Stage 3: Full streaming SHA-256 verification on fast-hash collisions.
        onProgress?(ScanProgress(phase: .verifying, completed: 0, total: stage2Collisions.count))
        var fullBuckets: [String: [ScannedCandidate]] = [:]
        for (index, candidate) in stage2Collisions.enumerated() {
            try Task.checkCancellation()
            guard let content = candidate.content else { continue }
            if let fullDigest = try computeFullDigest(content) {
                fullBuckets[fullDigest, default: []].append(candidate)
            }
            onProgress?(ScanProgress(phase: .verifying, completed: index + 1, total: stage2Collisions.count))
        }

        let duplicateGroups: [DuplicateGroup] = fullBuckets
            .compactMap { digest, members -> DuplicateGroup? in
                guard members.count >= 2 else { return nil }
                let contentBytes = members.first?.content?.totalContentBytes ?? 0
                let ordered = members.sorted(by: prefersToKeep)
                let items = ordered.enumerated().map { index, member in
                    DuplicateItem(
                        id: member.record.id,
                        title: member.record.title.isEmpty ? member.record.id : member.record.title,
                        kind: member.record.kind,
                        diskSizeBytes: member.diskSizeBytes,
                        addedAt: member.addedAt,
                        lastUsedAt: member.lastUsedAt,
                        references: member.references,
                        isRecommendedKeep: index == 0)
                }
                return DuplicateGroup(
                    id: digest, contentDigest: digest, contentSizeBytes: contentBytes, items: items)
            }
            .sorted { lhs, rhs in
                if lhs.reclaimableBytes != rhs.reclaimableBytes {
                    return lhs.reclaimableBytes > rhs.reclaimableBytes
                }
                return lhs.id < rhs.id
            }
        stats.stage3VerifiedDuplicateGroups = duplicateGroups.count

        // Category 2: Unreferenced wallpapers (strictly excluding active & referenced wallpapers).
        let unreferenced: [UnusedWallpaperCandidate] = scanned
            .filter { $0.references.isEmpty }
            .map { candidate in
                UnusedWallpaperCandidate(
                    id: candidate.record.id,
                    title: candidate.record.title.isEmpty ? candidate.record.id : candidate.record.title,
                    kind: candidate.record.kind,
                    diskSizeBytes: candidate.diskSizeBytes,
                    addedAt: candidate.addedAt,
                    lastUsedAt: candidate.lastUsedAt)
            }
            .sorted { lhs, rhs in
                if lhs.diskSizeBytes != rhs.diskSizeBytes {
                    return lhs.diskSizeBytes > rhs.diskSizeBytes
                }
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case (nil, .some): return true
                case (.some, nil): return false
                case (let a?, let b?) where a != b: return a < b
                default: return lhs.id < rhs.id
                }
            }

        // Category 3: Broken references & orphaned storage.
        onProgress?(ScanProgress(phase: .auditingStorage, completed: 0, total: 2))
        try Task.checkCancellation()
        let brokenReferences = findBrokenReferences(
            references: input.references, installedIDs: installedIDs)
        onProgress?(ScanProgress(phase: .auditingStorage, completed: 1, total: 2))
        try Task.checkCancellation()
        let orphanedStorage = findOrphanedStorage(
            installedIDs: installedIDs,
            references: input.references,
            sceneStorageURL: input.sceneStorageURL,
            spacePosterCacheURL: input.spacePosterCacheURL,
            fileManager: fileManager)
        onProgress?(ScanProgress(phase: .auditingStorage, completed: 2, total: 2))

        return Report(
            scannedAt: input.now,
            scannedWallpaperCount: sortedWallpapers.count,
            duplicateGroups: duplicateGroups,
            unreferencedWallpapers: unreferenced,
            brokenReferences: brokenReferences,
            orphanedStorage: orphanedStorage,
            pipelineStats: stats)
    }

    // MARK: - Duplicate ranking

    /// Deterministic "keep" preference within a duplicate group:
    /// active display / lock screen / screen saver > favorite > more references >
    /// has user metadata or presets > most recently used > newest added > id.
    private static func prefersToKeep(_ lhs: ScannedCandidate, _ rhs: ScannedCandidate) -> Bool {
        let lhsLive = lhs.references.contains(.activeDisplay)
            || lhs.references.contains(.lockScreen)
            || lhs.references.contains(.screenSaver)
        let rhsLive = rhs.references.contains(.activeDisplay)
            || rhs.references.contains(.lockScreen)
            || rhs.references.contains(.screenSaver)
        if lhsLive != rhsLive { return lhsLive }

        let lhsFav = lhs.references.contains(.favorite)
        let rhsFav = rhs.references.contains(.favorite)
        if lhsFav != rhsFav { return lhsFav }

        if lhs.references.count != rhs.references.count {
            return lhs.references.count > rhs.references.count
        }
        if lhs.hasMetadataOrPresets != rhs.hasMetadataOrPresets {
            return lhs.hasMetadataOrPresets
        }
        switch (lhs.lastUsedAt, rhs.lastUsedAt) {
        case (.some, nil): return true
        case (nil, .some): return false
        case (let a?, let b?) where a != b: return a > b
        default: break
        }
        switch (lhs.addedAt, rhs.addedAt) {
        case (.some, nil): return true
        case (nil, .some): return false
        case (let a?, let b?) where a != b: return a > b
        default: break
        }
        return lhs.record.id < rhs.record.id
    }

    // MARK: - Folder inspection & content resolution

    private struct FolderInspection {
        var measuredFolderBytes: Int64 = 0
        var addedAt: Date?
        var content: ContentTarget?
    }

    private static let metadataPreviewNames: Set<String> = [
        "preview.jpg", "preview.jpeg", "preview.png", "preview.gif", "preview.webp",
    ]

    private static let ignoredSystemNames: Set<String> = [
        ".ds_store", "thumbs.db",
    ]

    private static func inspectWallpaperFolder(
        record: WallpaperRecord,
        folder: URL,
        canonicalLibrary: URL,
        fileManager: FileManager
    ) -> FolderInspection {
        guard isSafeSingleComponent(record.id) else { return FolderInspection() }
        guard let values = try? folder.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .addedToDirectoryDateKey, .creationDateKey,
        ]), values.isDirectory == true, values.isSymbolicLink != true else {
            return FolderInspection()
        }
        let canonicalFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalFolder.deletingLastPathComponent().path == canonicalLibrary.path else {
            return FolderInspection()
        }

        var inspection = FolderInspection()
        inspection.addedAt = values.addedToDirectoryDate ?? values.creationDate

        let manifestURL = canonicalFolder.appendingPathComponent("project.json")
        let project = LibraryResolution.readObject(manifestURL)
        let manifestType = (project?["type"] as? String)?.lowercased()
        let previewName = (project?["preview"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Measure regular files and collect non-metadata assets in a single safe walk.
        var measuredBytes: Int64 = 0
        var assets: [AssetFile] = []
        let folderPrefix = canonicalFolder.path.hasSuffix("/") ? canonicalFolder.path : canonicalFolder.path + "/"

        if let enumerator = fileManager.enumerator(
            at: canonicalFolder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                guard let fileValues = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                    fileValues.isRegularFile == true,
                    fileValues.isSymbolicLink != true
                else { continue }
                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(folderPrefix) else { continue }
                let size = Int64(max(0, fileValues.fileSize ?? 0))
                measuredBytes += size

                let relativePath = String(resolved.path.dropFirst(folderPrefix.count))
                let lowerRelative = relativePath.lowercased()
                let lowerName = resolved.lastPathComponent.lowercased()
                if ignoredSystemNames.contains(lowerName) { continue }
                // Exclude root-level manifest and preview thumbnails from content identity so
                // trivial metadata/title/thumbnail differences never hide or cause duplicates.
                if lowerRelative == "project.json" { continue }
                if let previewName, !previewName.isEmpty, lowerRelative == previewName { continue }
                if !lowerRelative.contains("/"), metadataPreviewNames.contains(lowerRelative) { continue }

                assets.append(AssetFile(relativePath: relativePath, url: resolved, size: size))
            }
        }
        inspection.measuredFolderBytes = measuredBytes

        // Determine primary content target based on wallpaper kind/manifest.
        let isVideo = manifestType == "video" || (manifestType == nil && record.kind == .video)
        let isWeb = manifestType == "web" || (manifestType == nil && record.kind == .webpage)

        if isVideo, let primary = resolveSafeLocalFile(project?["file"], in: canonicalFolder) {
            inspection.content = .primaryFile(url: primary.url, size: primary.size)
            return inspection
        }

        if isWeb {
            // Packaged still images (imported images and pixiv saves) name their original artwork
            // under `project["image"]["file"]` or `project["pixiv"]["file"]`.
            for key in ["image", "pixiv"] {
                if let block = project?[key] as? [String: Any],
                   let primary = resolveSafeLocalFile(block["file"], in: canonicalFolder)
                {
                    inspection.content = .primaryFile(url: primary.url, size: primary.size)
                    return inspection
                }
            }
        }

        // Scene folders (`scene.pkg` and/or loose asset directories) and general web bundles:
        // sort asset files deterministically by UTF-8 relative path.
        if !assets.isEmpty {
            assets.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
            inspection.content = .directoryAssets(assets)
        }
        return inspection
    }

    private static func resolveSafeLocalFile(
        _ value: Any?, in canonicalFolder: URL
    ) -> (url: URL, size: Int64)? {
        guard let raw = value as? String, !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\0") else {
            return nil
        }
        let candidate = canonicalFolder.appendingPathComponent(raw)
        guard let values = try? candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonicalFolder.path.hasSuffix("/") ? canonicalFolder.path : canonicalFolder.path + "/"
        guard resolved.path.hasPrefix(prefix) else { return nil }
        let size = Int64(max(0, values.fileSize ?? 0))
        guard size > 0 else { return nil }
        return (resolved, size)
    }

    // MARK: - Stage 2 & Stage 3 cryptographic hashing

    private static func computeFastFingerprint(_ target: ContentTarget) throws -> String? {
        var hasher = SHA256()
        hasher.update(data: Data(target.domainTag.utf8))
        switch target {
        case .primaryFile(let url, let size):
            update(&hasher, int64: size)
            guard try feedHeadAndTail(url: url, size: size, into: &hasher) else { return nil }
        case .directoryAssets(let files):
            update(&hasher, int64: Int64(files.count))
            for file in files {
                try Task.checkCancellation()
                update(&hasher, string: file.relativePath)
                update(&hasher, int64: file.size)
                guard try feedHeadAndTail(url: file.url, size: file.size, into: &hasher) else {
                    return nil
                }
            }
        }
        return hexString(hasher.finalize())
    }

    private static func computeFullDigest(_ target: ContentTarget) throws -> String? {
        var hasher = SHA256()
        hasher.update(data: Data(target.domainTag.utf8))
        switch target {
        case .primaryFile(let url, let size):
            update(&hasher, int64: size)
            guard try feedFullFile(url: url, into: &hasher) else { return nil }
        case .directoryAssets(let files):
            update(&hasher, int64: Int64(files.count))
            for file in files {
                try Task.checkCancellation()
                update(&hasher, string: file.relativePath)
                update(&hasher, int64: file.size)
                guard try feedFullFile(url: file.url, into: &hasher) else { return nil }
            }
        }
        return hexString(hasher.finalize())
    }

    private static func feedHeadAndTail(
        url: URL, size: Int64, into hasher: inout SHA256
    ) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            let head = try handle.read(upToCount: fastHashChunkSize) ?? Data()
            hasher.update(data: head)
            if size > Int64(fastHashChunkSize) {
                let tailOffset = UInt64(max(0, size - Int64(fastHashChunkSize)))
                try handle.seek(toOffset: tailOffset)
                let tail = try handle.read(upToCount: fastHashChunkSize) ?? Data()
                hasher.update(data: tail)
            }
            return true
        } catch {
            return false
        }
    }

    private static func feedFullFile(url: URL, into hasher: inout SHA256) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var chunkCount = 0
        while true {
            if chunkCount % 4 == 0 { try Task.checkCancellation() }
            let chunk: Data?
            do {
                chunk = try autoreleasepool {
                    try handle.read(upToCount: fullHashBufferSize)
                }
            } catch {
                return false
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            chunkCount += 1
        }
        return true
    }

    private static func update(_ hasher: inout SHA256, int64 value: Int64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(bufferPointer: bytes)
        }
    }

    private static func update(_ hasher: inout SHA256, string: String) {
        let utf8 = Data(string.utf8)
        update(&hasher, int64: Int64(utf8.count))
        hasher.update(data: utf8)
        hasher.update(data: Data([0]))
    }

    private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Category 3: Broken references & orphaned storage

    private static func findBrokenReferences(
        references: ReferenceSnapshot, installedIDs: Set<String>
    ) -> [BrokenReferenceItem] {
        var results: [BrokenReferenceItem] = []

        func appendUnique(
            source: BrokenReferenceSource, containerID: String, containerName: String,
            candidates: [String]
        ) {
            var seen = Set<String>()
            for wallpaperID in candidates where !wallpaperID.isEmpty && !installedIDs.contains(wallpaperID) {
                guard seen.insert(wallpaperID).inserted else { continue }
                results.append(
                    BrokenReferenceItem(
                        id: "\(source.rawValue)|\(containerID)|\(wallpaperID)",
                        source: source,
                        containerID: containerID,
                        containerName: containerName,
                        wallpaperID: wallpaperID))
            }
        }

        appendUnique(
            source: .favorites, containerID: "favorites", containerName: "",
            candidates: references.favoriteIDs.sorted())

        for collection in references.collections.sorted(by: { $0.id < $1.id }) {
            appendUnique(
                source: .collections, containerID: collection.id, containerName: collection.name,
                candidates: collection.wallpaperIDs)
        }

        for playlist in references.displayPlaylists.sorted(by: { $0.displayID < $1.displayID }) {
            let ids = playlist.wallpaperIDs
                + [playlist.dayWallpaperID, playlist.nightWallpaperID].compactMap { $0 }
            appendUnique(
                source: .playlists, containerID: "display:\(playlist.displayID)",
                containerName: playlist.displayTitle, candidates: ids)
        }

        for plan in references.playlistPlans.sorted(by: { $0.id < $1.id }) {
            let ids = plan.wallpaperIDs
                + [plan.dayWallpaperID, plan.nightWallpaperID].compactMap { $0 }
            appendUnique(
                source: .playlists, containerID: "plan:\(plan.id)", containerName: plan.name,
                candidates: ids)
        }

        for config in references.automations.sorted(by: { $0.displayID < $1.displayID }) {
            let ids = config.ruleWallpaperIDs
                + [config.lightWallpaperID, config.darkWallpaperID, config.batteryWallpaperID].compactMap { $0 }
                + config.spaceWallpaperIDs.values.sorted()
            appendUnique(
                source: .automation, containerID: config.displayID,
                containerName: config.displayTitle, candidates: ids)
        }

        appendUnique(
            source: .metadata, containerID: "metadata", containerName: "",
            candidates: references.metadataWallpaperIDs.sorted())

        for preset in references.presets.sorted(by: { $0.id < $1.id }) {
            appendUnique(
                source: .presets, containerID: preset.id, containerName: preset.name,
                candidates: [preset.wallpaperID])
        }

        for layout in references.displayLayouts.sorted(by: { $0.id < $1.id }) {
            appendUnique(
                source: .displayLayouts, containerID: layout.id, containerName: layout.name,
                candidates: layout.wallpaperIDs)
        }

        return results
    }

    private static func findOrphanedStorage(
        installedIDs: Set<String>,
        references: ReferenceSnapshot,
        sceneStorageURL: URL,
        spacePosterCacheURL: URL,
        fileManager: FileManager
    ) -> [OrphanedStorageItem] {
        var orphans: [OrphanedStorageItem] = []

        // 1. Orphaned SceneStorage subdirectories (not matching any installed wallpaper).
        if let rootValues = try? sceneStorageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
           let entries = try? fileManager.contentsOfDirectory(
               at: sceneStorageURL,
               includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
               options: [.skipsHiddenFiles])
        {
            let canonicalRoot = sceneStorageURL.resolvingSymlinksInPath().standardizedFileURL
            for entry in entries {
                let name = entry.lastPathComponent
                guard isSafeSingleComponent(name), !installedIDs.contains(name) else { continue }
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.deletingLastPathComponent().path == canonicalRoot.path else { continue }
                let bytes = safeDirectorySize(resolved, fileManager: fileManager)
                orphans.append(
                    OrphanedStorageItem(
                        id: "\(OrphanedStorageKind.sceneStorage.rawValue)|\(name)",
                        kind: .sceneStorage, name: name, url: resolved, sizeBytes: bytes))
            }
        }

        // 2. Orphaned SpacePosters files (not matching any active Space poster for an installed wallpaper).
        let expectedPosters = references.expectedSpacePosterFileNames(installedIDs: installedIDs)
        if let rootValues = try? spacePosterCacheURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
           let entries = try? fileManager.contentsOfDirectory(
               at: spacePosterCacheURL,
               includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
               options: [.skipsHiddenFiles])
        {
            let canonicalRoot = spacePosterCacheURL.resolvingSymlinksInPath().standardizedFileURL
            for entry in entries {
                let name = entry.lastPathComponent
                guard isSafeSingleComponent(name), !expectedPosters.contains(name) else { continue }
                guard let values = try? entry.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                    values.isRegularFile == true, values.isSymbolicLink != true
                else { continue }
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.deletingLastPathComponent().path == canonicalRoot.path else { continue }
                let bytes = Int64(max(0, values.fileSize ?? 0))
                orphans.append(
                    OrphanedStorageItem(
                        id: "\(OrphanedStorageKind.spacePoster.rawValue)|\(name)",
                        kind: .spacePoster, name: name, url: resolved, sizeBytes: bytes))
            }
        }

        return orphans.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.id < rhs.id
        }
    }

    private static func performOrphanCleanup(
        items: [OrphanedStorageItem],
        sceneStorageURL: URL,
        spacePosterCacheURL: URL
    ) throws -> OrphanCleanupReport {
        let fileManager = FileManager.default
        var report = OrphanCleanupReport()
        var visited = Set<String>()

        for item in items where visited.insert(item.id).inserted {
            try Task.checkCancellation()
            let root = item.kind == .sceneStorage ? sceneStorageURL : spacePosterCacheURL
            guard isSafeSingleComponent(item.name) else {
                report.failures.append(.init(
                    id: item.id, name: item.name,
                    message: String(localized: "Refused to remove an item outside managed storage.")))
                continue
            }
            guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  rootValues.isDirectory == true, rootValues.isSymbolicLink != true
            else {
                report.failures.append(.init(
                    id: item.id, name: item.name,
                    message: String(localized: "Managed storage folder is unavailable.")))
                continue
            }
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let target = canonicalRoot.appendingPathComponent(
                item.name, isDirectory: item.kind == .sceneStorage)
            guard fileManager.fileExists(atPath: target.path) else {
                report.removedIDs.append(item.id)
                continue
            }
            guard let targetValues = try? target.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                targetValues.isSymbolicLink != true,
                target.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path
                    == canonicalRoot.path
            else {
                report.failures.append(.init(
                    id: item.id, name: item.name,
                    message: String(localized: "Refused to remove an item outside managed storage.")))
                continue
            }
            let expectedTypeMatches: Bool =
                switch item.kind {
                case .sceneStorage: targetValues.isDirectory == true
                case .spacePoster: targetValues.isRegularFile == true
                }
            guard expectedTypeMatches else {
                report.failures.append(.init(
                    id: item.id, name: item.name,
                    message: String(localized: "Refused to remove an item whose file type changed.")))
                continue
            }

            let actualBytes: Int64 =
                switch item.kind {
                case .sceneStorage: safeDirectorySize(target, fileManager: fileManager)
                case .spacePoster: Int64(max(0, targetValues.fileSize ?? 0))
                }
            do {
                try fileManager.removeItem(at: target)
                report.removedIDs.append(item.id)
                report.reclaimedBytes += actualBytes
            } catch {
                report.failures.append(.init(
                    id: item.id, name: item.name, message: error.localizedDescription))
            }
        }
        return report
    }

    private static func isSafeSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func safeDirectorySize(_ folder: URL, fileManager: FileManager) -> Int64 {
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonical.path.hasSuffix("/") ? canonical.path : canonical.path + "/"
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: canonical,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix) else {
                continue
            }
            total += Int64(max(0, values.fileSize ?? 0))
        }
        return total
    }
}
