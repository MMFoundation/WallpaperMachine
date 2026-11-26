import Foundation

/// Typed errors thrown by `SyncFolderService` so callers and tests can distinguish iCloud evicted
/// placeholders, missing snapshots, security rejections and validation failures cleanly.
enum SyncFolderFailure: LocalizedError, Equatable, Sendable {
    case invalidFolder(String)
    case snapshotNotFound
    case iCloudFileNotDownloaded(fileName: String)
    case unsafeFile(String)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder(let message):
            return message
        case .snapshotNotFound:
            return String(
                localized:
                    "No WallpaperMachineSync.json snapshot was found in this sync folder. Push from another Mac first."
            )
        case .iCloudFileNotDownloaded(let fileName):
            return String(
                localized:
                    "\(fileName) is stored in iCloud Drive and has not finished downloading to this Mac. Open the sync folder in Finder so iCloud Drive downloads the file, then try again."
            )
        case .unsafeFile(let message):
            return message
        case .invalidSnapshot(let message):
            return message
        }
    }
}

/// Hard caps enforced before and during `WallpaperMachineSync.json` parsing so untrusted or
/// corrupted sync files cannot exhaust memory, stack depth or store limits.
struct SyncFolderLimits: Equatable, Sendable {
    var maximumFileBytes: Int = 8 * 1024 * 1024
    var maximumJSONDepth: Int = 24
    var maximumJSONNodes: Int = 200_000
    var maximumWorkshopItems: Int = 10_000
    var maximumFavorites: Int = 10_000
    var maximumCollections: Int = 256
    var maximumCollectionWallpapers: Int = 10_000
    var maximumMetadataEntries: Int = 10_000
    var maximumPlaylists: Int = 256
    var maximumPresets: Int = WallpaperPresetStore.maximumPresets
    var maximumWidgets: Int = DesktopWidgetStore.limit
    var maximumLayouts: Int = WallpaperDisplayLayoutStore.limit
    var maximumVideoTrims: Int = 10_000
    var maximumDisplays: Int = 32
    var maximumTitleLength: Int = 256
    var maximumNameLength: Int = 128
    var maximumAppVersionLength: Int = 64
}

/// Local-only binding to the user's chosen cross-Mac sync folder (iCloud Drive, Syncthing,
/// Dropbox, OneDrive, SMB/NAS or external drive).
///
/// Strictly local-only: never included in `.wmbackup` packages or synced snapshots because folder
/// paths and security-scoped bookmarks differ per Mac.
struct SyncFolderBinding: Equatable, Sendable {
    var folderPath: String
    var bookmarkData: Data?
    var lastPushAt: Date?
    var lastPullAt: Date?

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }
}

/// Persists the local-only sync folder binding in `UserDefaults`.
///
/// None of these keys appear in `WallpaperBackupPreferences.allowedKeys`.
enum SyncFolderBindingStore {
    static let folderPathKey = "WallpaperMachine.syncFolderPath"
    static let folderBookmarkKey = "WallpaperMachine.syncFolderBookmark"
    static let lastPushAtKey = "WallpaperMachine.syncFolderLastPushAt"
    static let lastPullAtKey = "WallpaperMachine.syncFolderLastPullAt"

    static func load(from defaults: UserDefaults = ClientPreferences.defaults) -> SyncFolderBinding? {
        guard let path = defaults.string(forKey: folderPathKey), !path.isEmpty else { return nil }
        let bookmark = defaults.data(forKey: folderBookmarkKey)
        let lastPush = (defaults.object(forKey: lastPushAtKey) as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
        let lastPull = (defaults.object(forKey: lastPullAtKey) as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
        return SyncFolderBinding(
            folderPath: path,
            bookmarkData: bookmark,
            lastPushAt: lastPush,
            lastPullAt: lastPull
        )
    }

    @discardableResult
    static func save(
        folderURL: URL,
        in defaults: UserDefaults = ClientPreferences.defaults
    ) -> SyncFolderBinding {
        let resolved = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let previous = load(from: defaults)
        let sameFolder = previous?.folderPath == resolved.path
        let bookmark =
            (try? resolved.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ))
            ?? (try? resolved.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ))
        defaults.set(resolved.path, forKey: folderPathKey)
        if let bookmark {
            defaults.set(bookmark, forKey: folderBookmarkKey)
        } else {
            defaults.removeObject(forKey: folderBookmarkKey)
        }
        if !sameFolder {
            defaults.removeObject(forKey: lastPushAtKey)
            defaults.removeObject(forKey: lastPullAtKey)
        }
        return SyncFolderBinding(
            folderPath: resolved.path,
            bookmarkData: bookmark,
            lastPushAt: sameFolder ? previous?.lastPushAt : nil,
            lastPullAt: sameFolder ? previous?.lastPullAt : nil
        )
    }

    static func clear(in defaults: UserDefaults = ClientPreferences.defaults) {
        defaults.removeObject(forKey: folderPathKey)
        defaults.removeObject(forKey: folderBookmarkKey)
        defaults.removeObject(forKey: lastPushAtKey)
        defaults.removeObject(forKey: lastPullAtKey)
    }

    static func recordPush(at date: Date = Date(), in defaults: UserDefaults = ClientPreferences.defaults) {
        defaults.set(date.timeIntervalSince1970, forKey: lastPushAtKey)
    }

    static func recordPull(at date: Date = Date(), in defaults: UserDefaults = ClientPreferences.defaults) {
        defaults.set(date.timeIntervalSince1970, forKey: lastPullAtKey)
    }

    /// Bookmark resolution result produced off the main actor.
    struct ResolvedBookmark: Sendable {
        var url: URL
        var isSecurityScoped: Bool
        var refreshedBookmarkData: Data?
    }

    /// Resolves a stored security-scoped bookmark off the main actor without touching
    /// `UserDefaults`, returning any refreshed stale bookmark data for persistence on `@MainActor`.
    nonisolated static func resolveBookmarkOffMainActor(
        for binding: SyncFolderBinding
    ) -> ResolvedBookmark {
        if let bookmarkData = binding.bookmarkData {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let refreshed: Data? = isStale
                    ? (try? resolved.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ))
                    : nil
                return ResolvedBookmark(url: resolved, isSecurityScoped: true, refreshedBookmarkData: refreshed)
            }
            isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let refreshed: Data? = isStale
                    ? (try? resolved.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ))
                    : nil
                return ResolvedBookmark(url: resolved, isSecurityScoped: false, refreshedBookmarkData: refreshed)
            }
        }
        return ResolvedBookmark(url: binding.folderURL, isSecurityScoped: false, refreshedBookmarkData: nil)
    }

    /// Persists refreshed bookmark bytes if `folderURL` still matches the currently bound folder.
    static func persistRefreshedBookmark(
        _ data: Data,
        for folderURL: URL,
        in defaults: UserDefaults = ClientPreferences.defaults
    ) {
        let resolvedPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard defaults.string(forKey: folderPathKey) == resolvedPath else { return }
        defaults.set(data, forKey: folderBookmarkKey)
    }

    /// Resolves the stored security-scoped bookmark when available (refreshing it if stale),
    /// falling back to the stored local path.
    static func resolveURL(
        for binding: SyncFolderBinding,
        refreshingIn defaults: UserDefaults? = nil
    ) -> (url: URL, isSecurityScoped: Bool) {
        let resolved = resolveBookmarkOffMainActor(for: binding)
        if let refreshed = resolved.refreshedBookmarkData, let defaults {
            persistRefreshedBookmark(refreshed, for: resolved.url, in: defaults)
        }
        return (resolved.url, resolved.isSecurityScoped)
    }
}

/// Selectable state categories included in a cross-Mac sync folder snapshot.
enum SyncFolderCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case favorites
    case collections
    case metadata
    case playlists
    case presets
    case widgets
    case layouts
    case videoTrims

    var id: String { rawValue }
}

/// How same-item conflicts are resolved when pulling selected categories from a sync folder.
enum SyncFolderConflictStrategy: String, CaseIterable, Codable, Hashable, Sendable {
    /// Union sets, keep local values on same-item conflicts, and append non-duplicate items cleanly.
    case merge
    /// Replace user-selected categories with the sync folder's snapshot, leaving unselected categories untouched.
    case replace
}

/// Counts of non-portable elements stripped or downgraded during sync push so both Macs can explain
/// what changed without leaking private identifiers, paths or shortcuts.
struct SyncFolderSanitizationSummary: Codable, Equatable, Sendable {
    var downgradedSpaceWidgets: Int = 0
    var omittedImageWidgets: Int = 0
    var strippedPresetPaths: Int = 0
    var strippedUserShortcutBindings: Int = 0
    var omittedUnsafeItems: Int = 0

    var hasAdjustments: Bool {
        downgradedSpaceWidgets > 0 || omittedImageWidgets > 0 || strippedPresetPaths > 0
            || strippedUserShortcutBindings > 0 || omittedUnsafeItems > 0
    }
}

/// Versioned JSON snapshot stored as `WallpaperMachineSync.json` inside a user-chosen sync folder.
///
/// Deliberately contains NO media binaries, NO Steam/Pixiv credentials or sessions, NO
/// `UserShortcutStore` or `app:`/`shortcut:` bindings, NO local folder bookmarks, NO caches/logs,
/// and NO machine-local hardware or macOS Space UUIDs.
struct SyncFolderSnapshot: Codable, Equatable, Sendable {
    static let formatIdentifier = "app.wallpapermachine.sync-snapshot"
    static let currentSchemaVersion = 1

    var format: String = Self.formatIdentifier
    var schemaVersion: Int = Self.currentSchemaVersion
    var exportedAt: Date
    var deviceName: String
    var appVersion: String
    var displays: [SetupPackDisplayDescriptor]
    var workshopItems: [SetupPackWorkshopItem]
    var favorites: [String]
    var collections: [WallpaperCollection]
    var metadata: [String: WallpaperMetadata]
    var playlists: [PlaylistPlan]
    var presets: [WallpaperPresetDocument]
    var widgets: [DesktopWidget]
    var layouts: [WallpaperDisplayLayout]
    var videoTrims: [String: VideoTrimRange]
    var sanitization: SyncFolderSanitizationSummary?

    init(
        format: String = Self.formatIdentifier,
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = Date(),
        deviceName: String = "Mac",
        appVersion: String = "0.0.0",
        displays: [SetupPackDisplayDescriptor] = [],
        workshopItems: [SetupPackWorkshopItem] = [],
        favorites: [String] = [],
        collections: [WallpaperCollection] = [],
        metadata: [String: WallpaperMetadata] = [:],
        playlists: [PlaylistPlan] = [],
        presets: [WallpaperPresetDocument] = [],
        widgets: [DesktopWidget] = [],
        layouts: [WallpaperDisplayLayout] = [],
        videoTrims: [String: VideoTrimRange] = [:],
        sanitization: SyncFolderSanitizationSummary? = nil
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.displays = displays
        self.workshopItems = workshopItems
        self.favorites = favorites
        self.collections = collections
        self.metadata = metadata
        self.playlists = playlists
        self.presets = presets
        self.widgets = widgets
        self.layouts = layouts
        self.videoTrims = videoTrims
        self.sanitization = sanitization
    }
}

/// Immutable local state snapshot collected on the main actor before background push or diffing.
struct SyncFolderLocalState: Equatable, Sendable {
    var deviceName: String
    var appVersion: String
    var displays: [SetupPackTargetDisplay]
    /// Map of installed wallpaper ID -> display title (used to populate the Workshop index).
    var libraryTitles: [String: String]
    var installedWallpaperIDs: Set<String>
    var favorites: Set<String>
    var collections: [WallpaperCollection]
    var metadata: [String: WallpaperMetadata]
    var playlists: [PlaylistPlan]
    var presets: [WallpaperPropertyPreset]
    var widgets: [DesktopWidget]
    var layouts: [WallpaperDisplayLayout]
    var videoTrims: [String: VideoTrimRange]
    var now: Date

    init(
        deviceName: String = SyncFolderLocalState.defaultDeviceName,
        appVersion: String = SyncFolderLocalState.defaultAppVersion,
        displays: [SetupPackTargetDisplay] = [],
        libraryTitles: [String: String] = [:],
        installedWallpaperIDs: Set<String>? = nil,
        favorites: Set<String> = [],
        collections: [WallpaperCollection] = [],
        metadata: [String: WallpaperMetadata] = [:],
        playlists: [PlaylistPlan] = [],
        presets: [WallpaperPropertyPreset] = [],
        widgets: [DesktopWidget] = [],
        layouts: [WallpaperDisplayLayout] = [],
        videoTrims: [String: VideoTrimRange] = [:],
        now: Date = Date()
    ) {
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.displays = displays
        self.libraryTitles = libraryTitles
        self.installedWallpaperIDs = installedWallpaperIDs ?? Set(libraryTitles.keys)
        self.favorites = favorites
        self.collections = collections
        self.metadata = metadata
        self.playlists = playlists
        self.presets = presets
        self.widgets = widgets
        self.layouts = layouts
        self.videoTrims = videoTrims
        self.now = now
    }

    static var defaultDeviceName: String {
        let name = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }

    static var defaultAppVersion: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "0.0.0" : version
    }
}

/// Outcome returned after atomically pushing `WallpaperMachineSync.json` into a sync folder.
struct SyncFolderPushReport: Equatable, Sendable {
    var snapshotURL: URL
    var exportedAt: Date
    var byteCount: Int
    var digest: String
    var workshopItemCount: Int
    var favoritesCount: Int
    var collectionsCount: Int
    var metadataCount: Int
    var playlistsCount: Int
    var presetsCount: Int
    var widgetsCount: Int
    var layoutsCount: Int
    var videoTrimsCount: Int
    var sanitization: SyncFolderSanitizationSummary
    var notes: [String]
}

/// Lightweight status of `WallpaperMachineSync.json` in the currently bound sync folder, loaded
/// asynchronously outside SwiftUI `body`.
enum SyncFolderRemoteSummary: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        var deviceName: String
        var exportedAt: Date
        var appVersion: String
        var byteCount: Int
        var workshopItemCount: Int
        var digest: String
    }

    case noFolder
    case missingSnapshot
    case iCloudNotDownloaded
    case unreadable(String)
    case available(Header)
}

/// Per-category diff metrics comparing an incoming sync snapshot against this Mac's local state.
struct SyncFolderCategoryDiff: Equatable, Identifiable, Sendable {
    var category: SyncFolderCategory
    var incomingCount: Int
    var localCount: Int
    var addedCount: Int
    var updatedCount: Int
    var conflictingCount: Int
    var unchangedCount: Int
    var localOnlyCount: Int

    var id: SyncFolderCategory { category }

    var hasMergeChanges: Bool {
        addedCount > 0 || updatedCount > 0
    }

    var hasAnyDifference: Bool {
        addedCount > 0 || updatedCount > 0 || conflictingCount > 0 || localOnlyCount > 0
    }
}

/// Validated preview of `WallpaperMachineSync.json` before anything is modified on this Mac.
struct SyncFolderPullPreview: Equatable, Sendable {
    var folderURL: URL
    var snapshot: SyncFolderSnapshot
    var byteCount: Int
    /// SHA-256 hex digest of the validated bytes, binding confirmation to what was reviewed.
    var digest: String
    var categoryDiffs: [SyncFolderCategoryDiff]
    var installedWorkshopItems: [SetupPackWorkshopItem]
    var missingWorkshopItems: [SetupPackWorkshopItem]
    var sourceDisplays: [SetupPackDisplayDescriptor]
    /// Best-fit automatic mapping from exported display slot ID to connected target `displayID`.
    var suggestedDisplayMapping: [String: String]
    var notes: [String]

    func diff(for category: SyncFolderCategory) -> SyncFolderCategoryDiff {
        categoryDiffs.first { $0.category == category }
            ?? SyncFolderCategoryDiff(
                category: category,
                incomingCount: 0,
                localCount: 0,
                addedCount: 0,
                updatedCount: 0,
                conflictingCount: 0,
                unchangedCount: 0,
                localOnlyCount: 0
            )
    }

    var totalConflicts: Int {
        categoryDiffs.reduce(0) { $0 + $1.conflictingCount }
    }
}

/// User choices made inside the sync pull preview sheet before applying in place.
struct SyncFolderPullOptions: Equatable, Sendable {
    var selectedCategories: Set<SyncFolderCategory> = Set(SyncFolderCategory.allCases)
    var conflictStrategy: SyncFolderConflictStrategy = .merge
    /// Maps exported source display ID -> chosen connected target `displayID` (nil skips that display).
    var displayMapping: [String: String?] = [:]
    /// Must be explicitly confirmed by the user before queueing any Workshop downloads.
    var queueMissingDownloadsConfirmed: Bool = false

    init(
        selectedCategories: Set<SyncFolderCategory> = Set(SyncFolderCategory.allCases),
        conflictStrategy: SyncFolderConflictStrategy = .merge,
        displayMapping: [String: String?] = [:],
        queueMissingDownloadsConfirmed: Bool = false
    ) {
        self.selectedCategories = selectedCategories
        self.conflictStrategy = conflictStrategy
        self.displayMapping = displayMapping
        self.queueMissingDownloadsConfirmed = queueMissingDownloadsConfirmed
    }
}

/// Pure, pre-validated in-place mutations ready to apply across the live stores with zero restart.
struct SyncFolderPullPlan: Equatable, Sendable {
    struct CollectionMergeUpdate: Equatable, Sendable {
        var existingID: String
        var addedWallpaperIDs: [String]
    }

    struct CollectionsAction: Equatable, Sendable {
        var replaceAll: Bool
        /// For Replace: full ordered list to create. For Merge: brand-new collections to create.
        var collectionsToCreate: [WallpaperCollection]
        /// For Merge: wallpaper IDs to union into already-existing local collections.
        var collectionsToUpdate: [CollectionMergeUpdate]
        /// Maps incoming collection ID -> already-matched local collection ID (Merge only).
        var matchedExistingIDByIncomingID: [String: String]
    }

    struct MetadataAction: Equatable, Sendable {
        var keysToForget: [String]
        var entriesToWrite: [String: WallpaperMetadata]
    }

    struct PlaylistsAction: Equatable, Sendable {
        var replaceAll: Bool
        var plansToCreate: [PlaylistPlan]
    }

    struct PresetsAction: Equatable, Sendable {
        var replaceAll: Bool
        var presetsToImport: [WallpaperPropertyPreset]
    }

    struct WidgetsAction: Equatable, Sendable {
        var replaceAll: Bool
        var widgets: [DesktopWidget]
    }

    struct LayoutsAction: Equatable, Sendable {
        var replaceAll: Bool
        /// Every layout in this list ALWAYS has `autoApplyOnConnect == false`.
        var layoutsToSave: [WallpaperDisplayLayout]
    }

    struct VideoTrimsAction: Equatable, Sendable {
        var keysToForget: Set<String>
        var rangesToSet: [String: VideoTrimRange]
    }

    var favorites: Set<String>?
    var collections: CollectionsAction?
    var metadata: MetadataAction?
    var playlists: PlaylistsAction?
    var presets: PresetsAction?
    var widgets: WidgetsAction?
    var layouts: LayoutsAction?
    var videoTrims: VideoTrimsAction?
    /// Non-empty ONLY when the user explicitly confirmed queueing downloads for missing items.
    var confirmedDownloadWorkshopItems: [SetupPackWorkshopItem]
    var notes: [String]
}

/// Outcome summary returned after applying a sync pull in place.
struct SyncFolderPullApplyReport: Equatable, Sendable {
    var appliedAt: Date
    var strategy: SyncFolderConflictStrategy
    var favoritesApplied: Bool
    var favoritesCount: Int
    var collectionsCreatedCount: Int
    var collectionsUpdatedCount: Int
    var metadataWrittenCount: Int
    var playlistsAppliedCount: Int
    var presetsAppliedCount: Int
    var widgetsAppliedCount: Int
    var layoutsAppliedCount: Int
    var videoTrimsAppliedCount: Int
    var queuedDownloadsCount: Int
    var notes: [String]
}
