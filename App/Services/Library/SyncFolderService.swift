import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Manual cross-Mac Sync Folder service (Phase 1 Push / Pull with Conflict Preview).
///
/// Works with any user-chosen folder synced by iCloud Drive, Syncthing, Dropbox, OneDrive, SMB/NAS
/// or an external drive — with zero `DirectoryWatcher` write-loops, zero real-time store races,
/// and zero CloudKit entitlements.
///
/// Security & hygiene contract:
/// - Writes `WallpaperMachineSync.json` atomically via a same-directory temp file (`O_EXCL | O_NOFOLLOW`
///   + `fsync`) followed by atomic replacement so cloud sync daemons never upload half-written JSON.
/// - NEVER exports Steam/Pixiv credentials or sessions, `UserShortcutStore` or `app:`/`shortcut:`
///   values, media binaries, caches, logs, local folder bookmarks, or hardware/Space UUIDs.
/// - Detects evicted / un-downloaded iCloud Drive placeholders (`*.icloud` stubs and
///   `URLResourceValues.ubiquitousItemDownloadingStatus == .notDownloaded`) before opening files.
/// - Enforces `O_NOFOLLOW | S_IFREG`, an 8 MB max file size cap, linear pre-parse JSON depth & node
///   count bounds, strict top-level allowlists, schema version checks, numeric Workshop ID checks,
///   and strict per-field validation on every category.
struct SyncFolderService: Sendable {
    static let snapshotFileName = "WallpaperMachineSync.json"

    enum CloudFileState: Equatable, Sendable {
        case localOrReady
        case iCloudNotDownloaded
    }

    let supportRoot: URL
    let storageRoot: URL
    let limits: SyncFolderLimits
    /// Injectable iCloud status probe so unit tests can verify `ubiquitousItemDownloadingStatus`
    /// handling without requiring a live iCloud Drive container.
    let cloudStateInspector: @Sendable (URL) -> CloudFileState

    private static let allowedTopLevelKeys: Set<String> = [
        "format", "schemaVersion", "exportedAt", "deviceName", "appVersion",
        "displays", "workshopItems", "favorites", "collections", "metadata",
        "playlists", "presets", "widgets", "layouts", "videoTrims", "sanitization",
    ]

    init(
        supportRoot: URL = ClientPaths.supportURL,
        storageRoot: URL? = nil,
        limits: SyncFolderLimits = .init(),
        cloudStateInspector: @escaping @Sendable (URL) -> CloudFileState = {
            SyncFolderService.defaultCloudState(at: $0)
        }
    ) {
        self.supportRoot = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.storageRoot = (storageRoot ?? supportRoot).standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
        self.cloudStateInspector = cloudStateInspector
    }

    // MARK: - Strict Identifiers & Sanitizers

    /// Validates a portable wallpaper identifier (numeric Workshop ID or safe non-path identifier
    /// such as `pixiv-12345`). Refuses paths, traversal, URL/shortcut schemes, whitespace and control chars.
    static func isSafeWallpaperID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 256,
              raw != ".", raw != "..",
              !raw.hasPrefix("~"),
              !raw.contains("/"), !raw.contains("\\"), !raw.contains(":"),
              !raw.contains(".."), !raw.contains("\0"),
              !raw.contains(where: \.isNewline),
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw
        else { return false }
        return true
    }

    /// Validates an internal record identifier (collection ID, plan ID, layout ID, display slot).
    static func isSafeIdentifier(_ raw: String, limit: Int = 128) -> Bool {
        !raw.isEmpty && raw.utf8.count <= limit && raw != "." && raw != ".."
            && !raw.contains("/") && !raw.contains("\\") && !raw.contains("\0")
            && !raw.contains(where: \.isNewline)
    }

    /// Nonisolated equivalent of `WallpaperCollectionStore.validatedName` (1...128 characters,
    /// single line, no NUL bytes), safe to call off the main actor.
    static func validatedRecordName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128,
              !trimmed.contains(where: { $0.isNewline || $0 == "\0" })
        else { return nil }
        return trimmed
    }

    /// Returns true if `raw` is a machine-local `app:` or `shortcut:` binding value (which must
    /// NEVER be exported into or accepted from a synced snapshot).
    static func isUserShortcutBindingValue(_ raw: String) -> Bool {
        if UserShortcutTarget(rawValue: raw) != nil { return true }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix(UserShortcutTarget.applicationPrefix)
            || lowered.hasPrefix(UserShortcutTarget.shortcutPrefix)
    }

    static func sanitizedSingleLine(_ raw: String, limit: Int, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(limit))
    }

    /// Validates that `folder` is an existing directory outside WallpaperMachine's own support and
    /// library storage folders.
    func validateSyncFolder(_ folder: URL) throws -> URL {
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SyncFolderFailure.invalidFolder(
                String(localized: "Choose an existing folder for syncing.")
            )
        }
        guard !contains(resolved, in: supportRoot), !contains(resolved, in: storageRoot) else {
            throw SyncFolderFailure.invalidFolder(
                String(localized: "Choose a sync folder outside WallpaperMachine’s support and library folders.")
            )
        }
        return resolved
    }

    // MARK: - iCloud Evicted Placeholder Detection

    /// Default probe combining `.icloud` placeholder stub detection and `URLResourceValues`
    /// ubiquitous download state checks.
    static func defaultCloudState(at snapshotURL: URL) -> CloudFileState {
        let directory = snapshotURL.deletingLastPathComponent()
        let fileName = snapshotURL.lastPathComponent
        let fm = FileManager.default

        // 1. Classic iCloud evicted stub: `.<name>.icloud` beside a missing materialized file.
        let canonicalStub = directory.appendingPathComponent(".\(fileName).icloud")
        if fm.fileExists(atPath: canonicalStub.path), !fm.fileExists(atPath: snapshotURL.path) {
            return .iCloudNotDownloaded
        }
        // Also check any `*.WallpaperMachineSync.json.icloud` placeholder name in the directory.
        if !fm.fileExists(atPath: snapshotURL.path),
           let entries = try? fm.contentsOfDirectory(atPath: directory.path),
           entries.contains(where: { $0.hasSuffix(".\(fileName).icloud") || $0 == ".\(fileName).icloud" })
        {
            return .iCloudNotDownloaded
        }

        // 2. FileProvider dataless placeholder: materialized URL exists but downloadingStatus is `.notDownloaded`.
        if let values = try? snapshotURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]) {
            if values.isUbiquitousItem == true {
                if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    return .iCloudNotDownloaded
                }
                if values.ubiquitousItemIsDownloading == true,
                   values.ubiquitousItemDownloadingStatus != .current,
                   values.ubiquitousItemDownloadingStatus != .downloaded
                {
                    return .iCloudNotDownloaded
                }
            }
        }
        return .localOrReady
    }

    // MARK: - Build & Atomic Push

    /// Builds a clean, portable `SyncFolderSnapshot` from `state`, encodes it to deterministic UTF-8
    /// JSON, and self-validates the encoded bytes through `parseAndValidate(data:)`.
    func buildSnapshot(from state: SyncFolderLocalState) throws -> (snapshot: SyncFolderSnapshot, data: Data, sanitization: SyncFolderSanitizationSummary, notes: [String]) {
        var sanitization = SyncFolderSanitizationSummary()
        var workshopIDs = Set<String>()
        var slotBySourceKey: [String: String] = [:]
        var descriptors: [SetupPackDisplayDescriptor] = []

        func cleanDisplayName(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return String(localized: "Display") }
            if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open > trimmed.startIndex {
                let prefix = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty { return String(prefix.prefix(limits.maximumTitleLength)) }
            }
            return String(trimmed.prefix(limits.maximumTitleLength))
        }

        func registerDisplaySlot(sourceKey: String, fallbackName: String) -> (slotID: String, name: String) {
            let normalizedKey = sourceKey.lowercased()
            if let existing = slotBySourceKey[normalizedKey],
               let descriptor = descriptors.first(where: { $0.id == existing })
            {
                return (existing, descriptor.name)
            }
            let matched = state.displays.first { target in
                target.displayID.caseInsensitiveCompare(sourceKey) == .orderedSame
                    || (target.displayUUID?.caseInsensitiveCompare(sourceKey) == .orderedSame)
            }
            let canonicalKey = (matched?.displayID ?? sourceKey).lowercased()
            if let existing = slotBySourceKey[canonicalKey],
               let descriptor = descriptors.first(where: { $0.id == existing })
            {
                slotBySourceKey[normalizedKey] = existing
                return (existing, descriptor.name)
            }
            let slotID = "display-\(descriptors.count + 1)"
            let name = cleanDisplayName(matched?.title ?? fallbackName)
            let descriptor = SetupPackDisplayDescriptor(
                id: slotID,
                name: name,
                isPrimary: matched?.isPrimary ?? (sourceKey == "primary"),
                width: matched?.width,
                height: matched?.height
            )
            descriptors.append(descriptor)
            slotBySourceKey[normalizedKey] = slotID
            slotBySourceKey[canonicalKey] = slotID
            if let uuid = matched?.displayUUID?.lowercased(), !uuid.isEmpty {
                slotBySourceKey[uuid] = slotID
            }
            return (slotID, name)
        }

        func collectWorkshopID(_ id: String) {
            if let valid = SetupPackService.validatedWorkshopID(id) {
                workshopIDs.insert(valid)
            }
        }

        // 1. Installed Workshop items index
        for id in state.installedWallpaperIDs {
            collectWorkshopID(id)
        }
        for id in state.libraryTitles.keys {
            collectWorkshopID(id)
        }

        // 2. Favorites
        let sanitizedFavorites = state.favorites
            .filter(Self.isSafeWallpaperID)
            .sorted()
        for id in sanitizedFavorites { collectWorkshopID(id) }

        // 3. Collections
        var sanitizedCollections: [WallpaperCollection] = []
        var seenCollectionIDs = Set<String>()
        for collection in state.collections {
            guard Self.isSafeIdentifier(collection.id),
                  seenCollectionIDs.insert(collection.id.lowercased()).inserted,
                  let validName = Self.validatedRecordName(collection.name)
            else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            var seenMembers = Set<String>()
            let members = collection.wallpaperIDs.filter { id in
                Self.isSafeWallpaperID(id) && seenMembers.insert(id).inserted
            }
            for id in members { collectWorkshopID(id) }
            sanitizedCollections.append(
                WallpaperCollection(id: collection.id, name: validName, wallpaperIDs: members)
            )
        }

        // 4. Metadata
        var sanitizedMetadata: [String: WallpaperMetadata] = [:]
        for (wallpaperID, rawMeta) in state.metadata {
            guard Self.isSafeWallpaperID(wallpaperID) else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            let normalized = WallpaperMetadata(
                customTags: rawMeta.customTags,
                rating: rawMeta.rating,
                note: rawMeta.note,
                excludedFromRotation: rawMeta.excludedFromRotation
            )
            guard !normalized.isEmpty else { continue }
            sanitizedMetadata[wallpaperID] = normalized
            collectWorkshopID(wallpaperID)
        }

        // 5. Saved Playlists (including Smart Playlists)
        var sanitizedPlaylists: [PlaylistPlan] = []
        var seenPlanIDs = Set<String>()
        for plan in state.playlists {
            guard Self.isSafeIdentifier(plan.id),
                  seenPlanIDs.insert(plan.id.lowercased()).inserted,
                  let validName = Self.validatedRecordName(plan.name)
            else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            var playlist = plan.playlist
            playlist.planID = nil
            var seenList = Set<String>()
            playlist.wallpaperIDs = playlist.wallpaperIDs.filter {
                Self.isSafeWallpaperID($0) && seenList.insert($0).inserted
            }
            if let day = playlist.dayWallpaperID, !Self.isSafeWallpaperID(day) {
                playlist.dayWallpaperID = nil
            }
            if let night = playlist.nightWallpaperID, !Self.isSafeWallpaperID(night) {
                playlist.nightWallpaperID = nil
            }
            if let cid = playlist.collectionID, !Self.isSafeIdentifier(cid) {
                playlist.collectionID = nil
            }
            if let query = playlist.smartQuery {
                playlist.smartQuery = SmartPlaylistQuery(
                    requiredTags: query.requiredTags,
                    excludedTags: query.excludedTags,
                    types: query.types,
                    minimumRating: query.minimumRating,
                    maximumEnergy: query.maximumEnergy,
                    favoritesOnly: query.favoritesOnly,
                    excludeMature: query.excludeMature
                )
            }
            for id in playlist.wallpaperIDs { collectWorkshopID(id) }
            if let day = playlist.dayWallpaperID { collectWorkshopID(day) }
            if let night = playlist.nightWallpaperID { collectWorkshopID(night) }
            sanitizedPlaylists.append(PlaylistPlan(id: plan.id, name: validName, playlist: playlist))
        }

        // 6. Portable Presets (NO retainedPath, NO local/external paths, NO app:/shortcut: values!)
        var sanitizedPresets: [WallpaperPresetDocument] = []
        var seenPresetIDs = Set<String>()
        for preset in state.presets {
            guard Self.isSafeWallpaperID(preset.wallpaperID),
                  seenPresetIDs.insert(preset.id.lowercased()).inserted
            else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            var copy = preset
            for index in copy.properties.indices {
                var property = copy.properties[index]
                var strippedPath = false
                var strippedShortcut = false
                if property.retainedPath != nil {
                    property.retainedPath = nil
                    strippedPath = true
                }
                if property.kind == "file" || property.kind == "directory" {
                    if !property.usesDefault && property.value != .empty && property.value != .string("") {
                        property.usesDefault = true
                        property.value = .empty
                        strippedPath = true
                    } else if property.usesDefault, case .string(let s) = property.value, !s.isEmpty {
                        property.value = .empty
                    }
                } else if property.kind == "texture", case .string(let path) = property.value,
                          WallpaperPresetStore.looksLikeLocalOrUnsafePath(path)
                {
                    property.usesDefault = true
                    property.value = .string("")
                    strippedPath = true
                }
                if case .string(let raw) = property.value, Self.isUserShortcutBindingValue(raw) {
                    property.usesDefault = true
                    property.value = .string("")
                    strippedShortcut = true
                }
                if strippedPath { sanitization.strippedPresetPaths += 1 }
                if strippedShortcut { sanitization.strippedUserShortcutBindings += 1 }
                copy.properties[index] = property
            }
            do {
                try WallpaperPresetStore.validatePortableStructure(copy)
                try Self.validateNoUserShortcutValues(in: copy)
                collectWorkshopID(copy.wallpaperID)
                sanitizedPresets.append(WallpaperPresetDocument(preset: copy, assets: [:]))
            } catch {
                sanitization.omittedUnsafeItems += 1
            }
        }

        // 7. Portable Desktop Widgets (omit static image stickers, downgrade Space UUIDs, canonicalize display slots)
        var sanitizedWidgets: [DesktopWidget] = []
        var seenWidgetIDs = Set<String>()
        for widget in state.widgets {
            if widget.kind == .image || widget.imageAsset != nil {
                sanitization.omittedImageWidgets += 1
                continue
            }
            guard seenWidgetIDs.insert(widget.id.lowercased()).inserted else { continue }
            var copy = widget.clamped()
            copy.imageAsset = nil
            switch copy.scope {
            case .everywhere:
                break
            case .spaces:
                // Never export macOS Space UUIDs.
                copy.scope = .everywhere
                sanitization.downgradedSpaceWidgets += 1
            case .wallpapers(let ids):
                let portableIDs = ids.filter(Self.isSafeWallpaperID)
                if portableIDs.isEmpty {
                    copy.scope = .everywhere
                } else {
                    copy.scope = .wallpapers(portableIDs)
                    for id in portableIDs { collectWorkshopID(id) }
                }
            }
            if case .display(let uuid, let name) = copy.placement {
                let slot = registerDisplaySlot(sourceKey: uuid, fallbackName: name)
                copy.placement = .display(uuid: slot.slotID, name: slot.name)
            }
            guard copy.isValid else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            sanitizedWidgets.append(copy)
        }

        // 8. Portable Display Layouts (canonicalized display slots; autoApplyOnConnect never exported armed)
        var sanitizedLayouts: [WallpaperDisplayLayout] = []
        var seenLayoutIDs = Set<String>()
        for layout in state.layouts {
            guard Self.isSafeIdentifier(layout.id),
                  seenLayoutIDs.insert(layout.id.lowercased()).inserted,
                  let validName = Self.validatedRecordName(layout.name)
            else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            var portableAssignments: [WallpaperDisplayAssignment] = []
            var seenSlots = Set<String>()
            for assignment in layout.assignments {
                guard Self.isSafeWallpaperID(assignment.wallpaperID) else {
                    sanitization.omittedUnsafeItems += 1
                    continue
                }
                let slot = registerDisplaySlot(
                    sourceKey: assignment.displayID,
                    fallbackName: assignment.displayTitle
                )
                guard seenSlots.insert(slot.slotID).inserted else { continue }
                collectWorkshopID(assignment.wallpaperID)
                portableAssignments.append(
                    WallpaperDisplayAssignment(
                        displayID: slot.slotID,
                        displayTitle: slot.name,
                        wallpaperID: assignment.wallpaperID
                    )
                )
            }
            guard !portableAssignments.isEmpty else { continue }
            sanitizedLayouts.append(
                WallpaperDisplayLayout(
                    id: layout.id,
                    name: validName,
                    assignments: portableAssignments,
                    autoApplyOnConnect: false
                )
            )
        }

        // Canonicalize display slot numbering so the primary display is always `display-1`.
        if descriptors.count > 1,
           let primaryIndex = descriptors.firstIndex(where: \.isPrimary),
           primaryIndex != 0
        {
            var ordered = descriptors
            let primary = ordered.remove(at: primaryIndex)
            ordered.insert(primary, at: 0)
            var slotRemap: [String: String] = [:]
            descriptors = ordered.enumerated().map { index, descriptor in
                let newID = "display-\(index + 1)"
                slotRemap[descriptor.id] = newID
                return SetupPackDisplayDescriptor(
                    id: newID,
                    name: descriptor.name,
                    isPrimary: descriptor.isPrimary,
                    width: descriptor.width,
                    height: descriptor.height
                )
            }
            sanitizedWidgets = sanitizedWidgets.map { widget in
                var updated = widget
                if case .display(let oldSlot, let name) = updated.placement,
                   let newSlot = slotRemap[oldSlot]
                {
                    updated.placement = .display(uuid: newSlot, name: name)
                }
                return updated
            }
            sanitizedLayouts = sanitizedLayouts.map { layout in
                var updated = layout
                updated.assignments = layout.assignments.map { assignment in
                    WallpaperDisplayAssignment(
                        displayID: slotRemap[assignment.displayID] ?? assignment.displayID,
                        displayTitle: assignment.displayTitle,
                        wallpaperID: assignment.wallpaperID
                    )
                }
                return updated
            }
        }

        // 9. Video Trim Ranges
        var sanitizedTrims: [String: VideoTrimRange] = [:]
        for (wallpaperID, range) in state.videoTrims {
            guard Self.isSafeWallpaperID(wallpaperID),
                  let validated = try? VideoTrimRange(
                      startSeconds: range.startSeconds,
                      endSeconds: range.endSeconds
                  )
            else {
                sanitization.omittedUnsafeItems += 1
                continue
            }
            sanitizedTrims[wallpaperID] = validated
            collectWorkshopID(wallpaperID)
        }

        let workshopItems = workshopIDs.sorted().map { id -> SetupPackWorkshopItem in
            let title = state.libraryTitles[id].flatMap { raw -> String? in
                let cleaned = Self.sanitizedSingleLine(raw, limit: limits.maximumTitleLength, fallback: "")
                return cleaned.isEmpty ? nil : cleaned
            }
            return SetupPackWorkshopItem(id: id, title: title)
        }

        let snapshot = SyncFolderSnapshot(
            exportedAt: state.now,
            deviceName: Self.sanitizedSingleLine(state.deviceName, limit: limits.maximumNameLength, fallback: "Mac"),
            appVersion: Self.sanitizedSingleLine(state.appVersion, limit: limits.maximumAppVersionLength, fallback: "0.0.0"),
            displays: descriptors,
            workshopItems: workshopItems,
            favorites: sanitizedFavorites,
            collections: sanitizedCollections,
            metadata: sanitizedMetadata,
            playlists: sanitizedPlaylists,
            presets: sanitizedPresets,
            widgets: sanitizedWidgets,
            layouts: sanitizedLayouts,
            videoTrims: sanitizedTrims,
            sanitization: sanitization.hasAdjustments ? sanitization : nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)

        // Round-trip self-check before publishing bytes into the sync folder.
        _ = try parseAndValidate(data: data)

        let notes = Self.sanitizationNotes(for: sanitization)
        return (snapshot, data, sanitization, notes)
    }

    /// Atomically pushes `WallpaperMachineSync.json` into `folder` via a same-directory temporary
    /// file (`O_EXCL | O_NOFOLLOW` + `fsync`) and atomic swap so cloud sync daemons never observe
    /// a half-written JSON file.
    @discardableResult
    func push(to folder: URL, state: SyncFolderLocalState) throws -> SyncFolderPushReport {
        try Task.checkCancellation()
        let resolvedFolder = try validateSyncFolder(folder)
        let built = try buildSnapshot(from: state)
        try Task.checkCancellation()

        let destination = resolvedFolder.appendingPathComponent(Self.snapshotFileName)
        try writeAtomically(built.data, to: destination)

        return SyncFolderPushReport(
            snapshotURL: destination,
            exportedAt: built.snapshot.exportedAt,
            byteCount: built.data.count,
            digest: WallpaperBackupFiles.digest(built.data),
            workshopItemCount: built.snapshot.workshopItems.count,
            favoritesCount: built.snapshot.favorites.count,
            collectionsCount: built.snapshot.collections.count,
            metadataCount: built.snapshot.metadata.count,
            playlistsCount: built.snapshot.playlists.count,
            presetsCount: built.snapshot.presets.count,
            widgetsCount: built.snapshot.widgets.count,
            layoutsCount: built.snapshot.layouts.count,
            videoTrimsCount: built.snapshot.videoTrims.count,
            sanitization: built.sanitization,
            notes: built.notes
        )
    }

    /// Lightweight inspection of `WallpaperMachineSync.json` in `folder` for UI status display.
    /// Checks iCloud placeholder status before opening so evicted files never hang.
    func inspectFolderSummary(at folder: URL) -> SyncFolderRemoteSummary {
        let resolvedFolder: URL
        do {
            resolvedFolder = try validateSyncFolder(folder)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        let snapshotURL = resolvedFolder.appendingPathComponent(Self.snapshotFileName)
        if cloudStateInspector(snapshotURL) == .iCloudNotDownloaded {
            return .iCloudNotDownloaded
        }
        var status = stat()
        if lstat(snapshotURL.path, &status) != 0 {
            if errno == ENOENT {
                return .missingSnapshot
            }
            return .unreadable(
                String(localized: "The sync snapshot could not be read.")
            )
        }
        do {
            let data = try readRegularFile(at: snapshotURL)
            let (snapshot, _) = try parseAndValidate(data: data)
            return .available(
                .init(
                    deviceName: snapshot.deviceName,
                    exportedAt: snapshot.exportedAt,
                    appVersion: snapshot.appVersion,
                    byteCount: data.count,
                    workshopItemCount: snapshot.workshopItems.count,
                    digest: WallpaperBackupFiles.digest(data)
                )
            )
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: - Strict Read, Validation & Conflict Preview

    /// Strictly reads and validates `WallpaperMachineSync.json` in `folder` and computes a full
    /// per-category diff & conflict preview against `localState`.
    func previewPull(from folder: URL, localState: SyncFolderLocalState) throws -> SyncFolderPullPreview {
        try Task.checkCancellation()
        let resolvedFolder = try validateSyncFolder(folder)
        let snapshotURL = resolvedFolder.appendingPathComponent(Self.snapshotFileName)

        // Check iCloud placeholder BEFORE calling open() so evicted files never hang or throw raw POSIX errors.
        if cloudStateInspector(snapshotURL) == .iCloudNotDownloaded {
            throw SyncFolderFailure.iCloudFileNotDownloaded(fileName: Self.snapshotFileName)
        }

        var status = stat()
        if lstat(snapshotURL.path, &status) != 0 {
            if errno == ENOENT {
                throw SyncFolderFailure.snapshotNotFound
            }
            throw SyncFolderFailure.unsafeFile(
                String(localized: "WallpaperMachineSync.json must be a regular file, not a symbolic link or folder.")
            )
        }

        let data = try readRegularFile(at: snapshotURL)
        return try previewPull(data: data, folderURL: resolvedFolder, localState: localState)
    }

    func previewPull(
        data: Data,
        folderURL: URL,
        localState: SyncFolderLocalState
    ) throws -> SyncFolderPullPreview {
        let validated = try parseAndValidate(data: data)
        let snapshot = validated.snapshot

        let allWorkshopItems = Self.allReferencedWorkshopItems(in: snapshot)
        let installed = allWorkshopItems.filter { localState.installedWallpaperIDs.contains($0.id) }
        let missing = allWorkshopItems.filter { !localState.installedWallpaperIDs.contains($0.id) }

        let sourceDisplays = Self.allReferencedDisplays(in: snapshot)
        let suggested = SetupPackService.suggestDisplayMapping(
            sourceDisplays: sourceDisplays,
            targetDisplays: localState.displays
        )

        let diffs = Self.computeDiffs(
            snapshot: snapshot,
            localState: localState,
            suggestedDisplayMapping: suggested
        )

        var notes = validated.importWarnings
        if let sanitization = snapshot.sanitization {
            notes.append(contentsOf: Self.sanitizationNotes(for: sanitization))
        }

        return SyncFolderPullPreview(
            folderURL: folderURL,
            snapshot: snapshot,
            byteCount: data.count,
            digest: WallpaperBackupFiles.digest(data),
            categoryDiffs: diffs,
            installedWorkshopItems: installed,
            missingWorkshopItems: missing,
            sourceDisplays: sourceDisplays,
            suggestedDisplayMapping: suggested,
            notes: notes
        )
    }

    /// Parses and strictly validates raw `WallpaperMachineSync.json` bytes with
    /// `WallpaperBackupService`-grade hygiene.
    func parseAndValidate(data: Data) throws -> (snapshot: SyncFolderSnapshot, importWarnings: [String]) {
        guard !data.isEmpty, data.count <= limits.maximumFileBytes else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot is empty or exceeds the 8 MB size limit.")
            )
        }
        guard let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot is not valid UTF-8 text.")
            )
        }

        // O(n) raw-byte nesting & node-count guard runs BEFORE JSONSerialization so hostile
        // payloads cannot exhaust the call stack or allocate unbounded trees.
        try validateJSONStructure(
            data,
            maximumDepth: limits.maximumJSONDepth,
            maximumNodes: limits.maximumJSONNodes
        )

        let rawJSON: Any
        do {
            rawJSON = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This file is not a valid WallpaperMachine sync snapshot.")
            )
        }
        guard let rootObject = rawJSON as? [String: Any] else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This file is not a valid WallpaperMachine sync snapshot.")
            )
        }
        guard Set(rootObject.keys).isSubset(of: Self.allowedTopLevelKeys) else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot contains unsupported fields and was rejected.")
            )
        }

        var visitedNodes = 0
        try validateJSONTree(rootObject, depth: 0, visited: &visitedNodes)

        // Validate raw JSON fields that have lenient Decodable initializers BEFORE JSONDecoder runs,
        // so out-of-range ratings, invalid trim ranges, bad playlist values or unknown keys are rejected.
        try validateRawMetadata(rootObject["metadata"])
        try validateRawPlaylists(rootObject["playlists"])
        try validateRawVideoTrims(rootObject["videoTrims"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshot: SyncFolderSnapshot
        do {
            snapshot = try decoder.decode(SyncFolderSnapshot.self, from: data)
        } catch {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This file is not a supported WallpaperMachine sync snapshot.")
            )
        }

        guard snapshot.format == SyncFolderSnapshot.formatIdentifier,
              snapshot.schemaVersion == SyncFolderSnapshot.currentSchemaVersion,
              snapshot.exportedAt.timeIntervalSince1970.isFinite
        else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot version is not supported.")
            )
        }
        guard SetupPackService.isSafeTitle(snapshot.deviceName, limit: limits.maximumNameLength),
              SetupPackService.isSafeTitle(snapshot.appVersion, limit: limits.maximumAppVersionLength)
        else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot contains an invalid device name or app version.")
            )
        }

        // Validate display descriptors
        guard snapshot.displays.count <= limits.maximumDisplays else { throw oversizedError() }
        var seenDisplayIDs = Set<String>()
        for display in snapshot.displays {
            guard SetupPackService.isSafeDisplaySlotID(display.id),
                  seenDisplayIDs.insert(display.id).inserted,
                  SetupPackService.isSafeTitle(display.name, limit: limits.maximumTitleLength)
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid display entry.")
                )
            }
            if let width = display.width, !(1...32_768).contains(width) {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid display resolution.")
                )
            }
            if let height = display.height, !(1...32_768).contains(height) {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid display resolution.")
                )
            }
        }

        // Validate Workshop items (STRICT numeric Workshop IDs only)
        guard snapshot.workshopItems.count <= limits.maximumWorkshopItems else { throw oversizedError() }
        var seenWorkshopIDs = Set<String>()
        for item in snapshot.workshopItems {
            guard SetupPackService.validatedWorkshopID(item.id) != nil,
                  seenWorkshopIDs.insert(item.id).inserted
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid or duplicate Workshop ID.")
                )
            }
            if let title = item.title, !SetupPackService.isSafeTitle(title, limit: limits.maximumTitleLength) {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid wallpaper title.")
                )
            }
        }

        // Validate Favorites
        guard snapshot.favorites.count <= limits.maximumFavorites else { throw oversizedError() }
        var seenFavorites = Set<String>()
        for id in snapshot.favorites {
            guard Self.isSafeWallpaperID(id), seenFavorites.insert(id).inserted else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid favorite wallpaper entry.")
                )
            }
        }

        // Validate Collections
        guard snapshot.collections.count <= limits.maximumCollections else { throw oversizedError() }
        var seenCollectionIDs = Set<String>()
        for collection in snapshot.collections {
            guard Self.isSafeIdentifier(collection.id),
                  seenCollectionIDs.insert(collection.id.lowercased()).inserted,
                  let validName = Self.validatedRecordName(collection.name),
                  validName == collection.name,
                  collection.wallpaperIDs.count <= limits.maximumCollectionWallpapers
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid collection.")
                )
            }
            var seenMembers = Set<String>()
            for id in collection.wallpaperIDs {
                guard Self.isSafeWallpaperID(id), seenMembers.insert(id).inserted else {
                    throw SyncFolderFailure.invalidSnapshot(
                        String(localized: "This sync snapshot contains an invalid wallpaper ID in a collection.")
                    )
                }
            }
        }

        // Validate Metadata count & keys (fields already strictly checked in validateRawMetadata)
        guard snapshot.metadata.count <= limits.maximumMetadataEntries else { throw oversizedError() }
        for id in snapshot.metadata.keys {
            guard Self.isSafeWallpaperID(id) else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid wallpaper metadata entry.")
                )
            }
        }

        // Validate Saved Playlists count & uniqueness (fields already strictly checked in validateRawPlaylists)
        guard snapshot.playlists.count <= limits.maximumPlaylists else { throw oversizedError() }
        var seenPlanIDs = Set<String>()
        for plan in snapshot.playlists {
            guard Self.isSafeIdentifier(plan.id),
                  seenPlanIDs.insert(plan.id.lowercased()).inserted,
                  let validName = Self.validatedRecordName(plan.name),
                  validName == plan.name
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid saved playlist.")
                )
            }
        }

        // Validate Portable Presets (no binaries, no local paths, NO app:/shortcut: values)
        guard snapshot.presets.count <= limits.maximumPresets else { throw oversizedError() }
        var seenPresetIDs = Set<String>()
        for presetDoc in snapshot.presets {
            guard presetDoc.version == WallpaperPresetDocument.currentVersion,
                  presetDoc.assets.isEmpty,
                  Self.isSafeWallpaperID(presetDoc.preset.wallpaperID),
                  seenPresetIDs.insert(presetDoc.preset.id.lowercased()).inserted
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid or non-portable property preset.")
                )
            }
            do {
                try WallpaperPresetStore.validatePortableStructure(presetDoc.preset)
                try Self.validateNoUserShortcutValues(in: presetDoc.preset)
            } catch {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid or non-portable property preset.")
                )
            }
        }

        // Validate Portable Desktop Widgets
        guard snapshot.widgets.count <= limits.maximumWidgets else { throw oversizedError() }
        var seenWidgetIDs = Set<String>()
        var downgradedIncomingSpaceWidgets = 0
        for index in snapshot.widgets.indices {
            var widget = snapshot.widgets[index]
            guard widget.isValid,
                  seenWidgetIDs.insert(widget.id.lowercased()).inserted,
                  widget.kind != .image,
                  widget.imageAsset == nil
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid or non-portable desktop widget.")
                )
            }
            if case .display(let slotID, let name) = widget.placement {
                guard SetupPackService.isSafeDisplaySlotID(slotID),
                      !name.contains("\0"), !name.contains(where: \.isNewline)
                else {
                    throw SyncFolderFailure.invalidSnapshot(
                        String(localized: "This sync snapshot contains an invalid display reference in a widget.")
                    )
                }
            }
            switch widget.scope {
            case .everywhere:
                break
            case .wallpapers(let ids):
                guard ids.allSatisfy(Self.isSafeWallpaperID) else {
                    throw SyncFolderFailure.invalidSnapshot(
                        String(localized: "This sync snapshot contains an invalid wallpaper ID in a widget scope.")
                    )
                }
            case .spaces:
                widget.scope = .everywhere
                snapshot.widgets[index] = widget
                downgradedIncomingSpaceWidgets += 1
            }
        }

        // Validate Portable Display Layouts
        guard snapshot.layouts.count <= limits.maximumLayouts else { throw oversizedError() }
        var seenLayoutIDs = Set<String>()
        for layout in snapshot.layouts {
            guard SetupPackService.isSafeDisplaySlotID(layout.id),
                  seenLayoutIDs.insert(layout.id.lowercased()).inserted,
                  let validName = Self.validatedRecordName(layout.name),
                  validName == layout.name,
                  !layout.assignments.isEmpty,
                  layout.assignments.count <= 64,
                  Set(layout.assignments.map(\.displayID)).count == layout.assignments.count
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid display layout.")
                )
            }
            for assignment in layout.assignments {
                guard SetupPackService.isSafeDisplaySlotID(assignment.displayID),
                      SetupPackService.isSafeTitle(assignment.displayTitle, limit: limits.maximumTitleLength),
                      Self.isSafeWallpaperID(assignment.wallpaperID)
                else {
                    throw SyncFolderFailure.invalidSnapshot(
                        String(localized: "This sync snapshot contains an invalid wallpaper or display assignment.")
                    )
                }
            }
        }

        // Validate Video Trim Ranges
        guard snapshot.videoTrims.count <= limits.maximumVideoTrims else { throw oversizedError() }
        for (wallpaperID, range) in snapshot.videoTrims {
            guard Self.isSafeWallpaperID(wallpaperID),
                  (try? VideoTrimRange(startSeconds: range.startSeconds, endSeconds: range.endSeconds)) != nil
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid video trim range.")
                )
            }
        }

        var importWarnings: [String] = []
        if downgradedIncomingSpaceWidgets > 0 {
            importWarnings.append(
                String(
                    localized:
                        "Space-pinned widgets were set to show on all Spaces because macOS Space IDs are specific to each Mac."
                )
            )
        }
        return (snapshot, importWarnings)
    }

    // MARK: - Pull Plan Preparation (Merge vs Replace + Display Remapping)

    /// Builds a pure, in-place mutation plan for `preview` given `options` and `localState`.
    ///
    /// Guarantees:
    /// - Unselected categories produce `nil` actions and are NEVER touched.
    /// - Imported Display Layouts ALWAYS have `autoApplyOnConnect == false`.
    /// - Missing Workshop items are NEVER queued unless `options.queueMissingDownloadsConfirmed == true`.
    func preparePullPlan(
        preview: SyncFolderPullPreview,
        options: SyncFolderPullOptions,
        localState: SyncFolderLocalState
    ) throws -> SyncFolderPullPlan {
        let snapshot = preview.snapshot
        let targetsByID = Dictionary(
            localState.displays.map { ($0.displayID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func resolvedTarget(for sourceID: String) -> SetupPackTargetDisplay? {
            if let explicit = options.displayMapping[sourceID] {
                return explicit.flatMap { targetsByID[$0] }
            }
            return preview.suggestedDisplayMapping[sourceID].flatMap { targetsByID[$0] }
        }

        var notes: [String] = []

        // 1. Favorites
        let favoritesResult: Set<String>?
        if options.selectedCategories.contains(.favorites) {
            let incoming = Set(snapshot.favorites)
            switch options.conflictStrategy {
            case .merge:
                favoritesResult = localState.favorites.union(incoming)
            case .replace:
                favoritesResult = incoming
            }
        } else {
            favoritesResult = nil
        }

        // 2. Collections
        let collectionsAction: SyncFolderPullPlan.CollectionsAction?
        if options.selectedCategories.contains(.collections) {
            switch options.conflictStrategy {
            case .replace:
                collectionsAction = .init(
                    replaceAll: true,
                    collectionsToCreate: snapshot.collections,
                    collectionsToUpdate: [],
                    matchedExistingIDByIncomingID: [:]
                )
            case .merge:
                var toCreate: [WallpaperCollection] = []
                var toUpdate: [SyncFolderPullPlan.CollectionMergeUpdate] = []
                var matchedIDMap: [String: String] = [:]
                for incoming in snapshot.collections {
                    if let match = Self.matchCollection(incoming, in: localState.collections) {
                        matchedIDMap[incoming.id] = match.id
                        let existingMembers = Set(match.wallpaperIDs)
                        let additions = incoming.wallpaperIDs.filter { !existingMembers.contains($0) }
                        if !additions.isEmpty {
                            toUpdate.append(.init(existingID: match.id, addedWallpaperIDs: additions))
                        }
                    } else {
                        toCreate.append(incoming)
                    }
                }
                collectionsAction = .init(
                    replaceAll: false,
                    collectionsToCreate: toCreate,
                    collectionsToUpdate: toUpdate,
                    matchedExistingIDByIncomingID: matchedIDMap
                )
            }
        } else {
            collectionsAction = nil
        }

        // 3. Metadata
        let metadataAction: SyncFolderPullPlan.MetadataAction?
        if options.selectedCategories.contains(.metadata) {
            switch options.conflictStrategy {
            case .replace:
                let toForget = Array(Set(localState.metadata.keys).subtracting(snapshot.metadata.keys)).sorted()
                metadataAction = .init(keysToForget: toForget, entriesToWrite: snapshot.metadata)
            case .merge:
                var toWrite: [String: WallpaperMetadata] = [:]
                for (id, incoming) in snapshot.metadata {
                    if let local = localState.metadata[id], !local.isEmpty {
                        // Union tags (keeping local first), keep local rating/note/exclusion on conflict.
                        let mergedTags = WallpaperMetadata.normalizedTags(local.customTags + incoming.customTags)
                        let merged = WallpaperMetadata(
                            customTags: mergedTags,
                            rating: local.rating ?? incoming.rating,
                            note: local.note ?? incoming.note,
                            excludedFromRotation: local.excludedFromRotation
                        )
                        if merged != local {
                            toWrite[id] = merged
                        }
                    } else {
                        toWrite[id] = incoming
                    }
                }
                metadataAction = .init(keysToForget: [], entriesToWrite: toWrite)
            }
        } else {
            metadataAction = nil
        }

        // 4. Saved Playlists (including Smart Playlists)
        let playlistsAction: SyncFolderPullPlan.PlaylistsAction?
        if options.selectedCategories.contains(.playlists) {
            switch options.conflictStrategy {
            case .replace:
                playlistsAction = .init(
                    replaceAll: true,
                    plansToCreate: snapshot.playlists
                )
            case .merge:
                var plansToCreate: [PlaylistPlan] = []
                for incoming in snapshot.playlists {
                    // Keep local plan on same-ID or same-name conflict.
                    if Self.matchPlan(incoming, in: localState.playlists) != nil {
                        continue
                    }
                    plansToCreate.append(incoming)
                }
                playlistsAction = .init(
                    replaceAll: false,
                    plansToCreate: plansToCreate
                )
            }
        } else {
            playlistsAction = nil
        }

        // 5. Portable Presets
        let presetsAction: SyncFolderPullPlan.PresetsAction?
        if options.selectedCategories.contains(.presets) {
            let incomingPresets = snapshot.presets.map(\.preset)
            switch options.conflictStrategy {
            case .replace:
                presetsAction = .init(replaceAll: true, presetsToImport: incomingPresets)
            case .merge:
                let filtered = incomingPresets.filter { incoming in
                    // Keep local preset on same-wallpaper + same-name conflict (or exact duplicate).
                    !localState.presets.contains { existing in
                        existing.wallpaperID == incoming.wallpaperID
                            && (existing.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                                || existing.properties == incoming.properties && existing.name == incoming.name)
                    }
                }
                presetsAction = .init(replaceAll: false, presetsToImport: filtered)
            }
        } else {
            presetsAction = nil
        }

        // 6. Portable Desktop Widgets (remapped with Skip support)
        let widgetsAction: SyncFolderPullPlan.WidgetsAction?
        if options.selectedCategories.contains(.widgets) {
            var remappedWidgets: [DesktopWidget] = []
            var skippedWidgets = 0
            for raw in snapshot.widgets {
                var widget = raw.clamped()
                widget.imageAsset = nil
                if case .spaces = widget.scope {
                    widget.scope = .everywhere
                }
                if case .display(let sourceID, _) = widget.placement {
                    if let target = resolvedTarget(for: sourceID) {
                        if let uuid = target.displayUUID, !uuid.isEmpty {
                            widget.placement = .display(uuid: uuid, name: target.title)
                        } else if target.isPrimary {
                            widget.placement = .main
                        } else {
                            widget.placement = .display(uuid: target.displayID, name: target.title)
                        }
                    } else if let explicit = options.displayMapping[sourceID], explicit == nil {
                        skippedWidgets += 1
                        continue
                    } else {
                        widget.placement = .main
                    }
                }
                remappedWidgets.append(widget)
            }
            if skippedWidgets > 0 {
                notes.append(
                    String(localized: "Skipped \(skippedWidgets) widget(s) pinned to unmapped displays.")
                )
            }

            switch options.conflictStrategy {
            case .replace:
                widgetsAction = .init(
                    replaceAll: true,
                    widgets: Array(remappedWidgets.prefix(DesktopWidgetStore.limit))
                )
            case .merge:
                let filtered = remappedWidgets.filter { incoming in
                    !localState.widgets.contains { existing in
                        existing.id == incoming.id
                            || Self.widgetContentMatches(existing, incoming)
                    }
                }
                widgetsAction = .init(replaceAll: false, widgets: filtered)
            }
        } else {
            widgetsAction = nil
        }

        // 7. Portable Display Layouts (remapped with Skip support, ALWAYS autoApplyOnConnect: false!)
        let layoutsAction: SyncFolderPullPlan.LayoutsAction?
        if options.selectedCategories.contains(.layouts) {
            var remappedLayouts: [WallpaperDisplayLayout] = []
            var skippedLayouts = 0
            for raw in snapshot.layouts {
                var remapped: [WallpaperDisplayAssignment] = []
                var seenTargets = Set<String>()
                for assignment in raw.assignments {
                    guard let target = resolvedTarget(for: assignment.displayID) else { continue }
                    guard seenTargets.insert(target.displayID).inserted else { continue }
                    remapped.append(
                        WallpaperDisplayAssignment(
                            displayID: target.displayID,
                            displayTitle: target.title,
                            wallpaperID: assignment.wallpaperID
                        )
                    )
                }
                guard !remapped.isEmpty else {
                    skippedLayouts += 1
                    continue
                }
                remappedLayouts.append(
                    WallpaperDisplayLayout(
                        id: raw.id,
                        name: raw.name,
                        assignments: remapped,
                        autoApplyOnConnect: false
                    )
                )
            }
            if skippedLayouts > 0 {
                notes.append(
                    String(localized: "Skipped \(skippedLayouts) display layout(s) with no mapped target displays.")
                )
            }

            switch options.conflictStrategy {
            case .replace:
                layoutsAction = .init(
                    replaceAll: true,
                    layoutsToSave: Array(remappedLayouts.prefix(WallpaperDisplayLayoutStore.limit))
                )
            case .merge:
                let filtered = remappedLayouts.filter { incoming in
                    // Keep local layout on same-ID, same-name, or exact-duplicate conflict.
                    !localState.layouts.contains { existing in
                        existing.id == incoming.id
                            || existing.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                            || (existing.name == incoming.name && existing.assignments == incoming.assignments)
                    }
                }
                layoutsAction = .init(replaceAll: false, layoutsToSave: filtered)
            }
        } else {
            layoutsAction = nil
        }

        // 8. Video Trim Ranges
        let videoTrimsAction: SyncFolderPullPlan.VideoTrimsAction?
        if options.selectedCategories.contains(.videoTrims) {
            switch options.conflictStrategy {
            case .replace:
                let toForget = Set(localState.videoTrims.keys).subtracting(snapshot.videoTrims.keys)
                videoTrimsAction = .init(keysToForget: toForget, rangesToSet: snapshot.videoTrims)
            case .merge:
                var toSet: [String: VideoTrimRange] = [:]
                for (id, range) in snapshot.videoTrims where localState.videoTrims[id] == nil {
                    toSet[id] = range
                }
                videoTrimsAction = .init(keysToForget: [], rangesToSet: toSet)
            }
        } else {
            videoTrimsAction = nil
        }

        // 9. Missing Workshop items: STRICTLY gated on explicit user confirmation.
        let confirmedDownloads: [SetupPackWorkshopItem] = options.queueMissingDownloadsConfirmed
            ? preview.missingWorkshopItems
            : []

        return SyncFolderPullPlan(
            favorites: favoritesResult,
            collections: collectionsAction,
            metadata: metadataAction,
            playlists: playlistsAction,
            presets: presetsAction,
            widgets: widgetsAction,
            layouts: layoutsAction,
            videoTrims: videoTrimsAction,
            confirmedDownloadWorkshopItems: confirmedDownloads,
            notes: notes
        )
    }

    // MARK: - Diff Calculation

    private static func computeDiffs(
        snapshot: SyncFolderSnapshot,
        localState: SyncFolderLocalState,
        suggestedDisplayMapping: [String: String]
    ) -> [SyncFolderCategoryDiff] {
        var diffs: [SyncFolderCategoryDiff] = []

        // 1. Favorites
        let incomingFavs = Set(snapshot.favorites)
        let localFavs = localState.favorites
        diffs.append(
            SyncFolderCategoryDiff(
                category: .favorites,
                incomingCount: incomingFavs.count,
                localCount: localFavs.count,
                addedCount: incomingFavs.subtracting(localFavs).count,
                updatedCount: 0,
                conflictingCount: 0,
                unchangedCount: incomingFavs.intersection(localFavs).count,
                localOnlyCount: localFavs.subtracting(incomingFavs).count
            )
        )

        // 2. Collections
        do {
            var added = 0, updated = 0, conflicting = 0, unchanged = 0
            var matchedLocalIDs = Set<String>()
            for incoming in snapshot.collections {
                if let local = matchCollection(incoming, in: localState.collections) {
                    matchedLocalIDs.insert(local.id)
                    let incSet = Set(incoming.wallpaperIDs)
                    let locSet = Set(local.wallpaperIDs)
                    if incSet == locSet && incoming.name == local.name {
                        unchanged += 1
                    } else if locSet.isSubset(of: incSet)
                        && incoming.name.caseInsensitiveCompare(local.name) == .orderedSame
                    {
                        updated += 1
                    } else {
                        conflicting += 1
                    }
                } else {
                    added += 1
                }
            }
            let localOnly = localState.collections.filter { !matchedLocalIDs.contains($0.id) }.count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .collections,
                    incomingCount: snapshot.collections.count,
                    localCount: localState.collections.count,
                    addedCount: added,
                    updatedCount: updated,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        // 3. Metadata
        do {
            var added = 0, updated = 0, conflicting = 0, unchanged = 0
            for (id, inc) in snapshot.metadata {
                guard let loc = localState.metadata[id], !loc.isEmpty else {
                    added += 1
                    continue
                }
                if loc == inc {
                    unchanged += 1
                } else {
                    let ratingConflict = loc.rating != nil && inc.rating != nil && loc.rating != inc.rating
                    let noteConflict = loc.note != nil && inc.note != nil && loc.note != inc.note
                    let excludedConflict = loc.excludedFromRotation != inc.excludedFromRotation
                    if ratingConflict || noteConflict || excludedConflict {
                        conflicting += 1
                    } else {
                        updated += 1
                    }
                }
            }
            let localOnly = Set(localState.metadata.keys).subtracting(snapshot.metadata.keys).count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .metadata,
                    incomingCount: snapshot.metadata.count,
                    localCount: localState.metadata.count,
                    addedCount: added,
                    updatedCount: updated,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        // 4. Saved Playlists
        do {
            var added = 0, conflicting = 0, unchanged = 0
            var matchedLocalIDs = Set<String>()
            for incoming in snapshot.playlists {
                if let local = matchPlan(incoming, in: localState.playlists) {
                    matchedLocalIDs.insert(local.id)
                    var normInc = incoming.playlist
                    var normLoc = local.playlist
                    normInc.planID = nil
                    normLoc.planID = nil
                    if normInc == normLoc {
                        unchanged += 1
                    } else {
                        conflicting += 1
                    }
                } else {
                    added += 1
                }
            }
            let localOnly = localState.playlists.filter { !matchedLocalIDs.contains($0.id) }.count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .playlists,
                    incomingCount: snapshot.playlists.count,
                    localCount: localState.playlists.count,
                    addedCount: added,
                    updatedCount: 0,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        // 5. Property Presets
        do {
            var added = 0, conflicting = 0, unchanged = 0
            var matchedLocalIDs = Set<String>()
            for incomingDoc in snapshot.presets {
                let inc = incomingDoc.preset
                if let exact = localState.presets.first(where: {
                    $0.wallpaperID == inc.wallpaperID && $0.name == inc.name && $0.properties == inc.properties
                }) {
                    matchedLocalIDs.insert(exact.id)
                    unchanged += 1
                } else if let sameName = localState.presets.first(where: {
                    $0.wallpaperID == inc.wallpaperID && $0.name.caseInsensitiveCompare(inc.name) == .orderedSame
                }) {
                    matchedLocalIDs.insert(sameName.id)
                    conflicting += 1
                } else {
                    added += 1
                }
            }
            let localOnly = localState.presets.filter { !matchedLocalIDs.contains($0.id) }.count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .presets,
                    incomingCount: snapshot.presets.count,
                    localCount: localState.presets.count,
                    addedCount: added,
                    updatedCount: 0,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        // 6. Desktop Widgets
        do {
            let targetsByID = Dictionary(
                localState.displays.map { ($0.displayID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var added = 0, conflicting = 0, unchanged = 0
            var matchedLocalIDs = Set<String>()
            for rawIncoming in snapshot.widgets {
                var incoming = rawIncoming
                if case .display(let sourceID, _) = incoming.placement {
                    if let mappedID = suggestedDisplayMapping[sourceID], let target = targetsByID[mappedID] {
                        if let uuid = target.displayUUID, !uuid.isEmpty {
                            incoming.placement = .display(uuid: uuid, name: target.title)
                        } else if target.isPrimary {
                            incoming.placement = .main
                        } else {
                            incoming.placement = .display(uuid: target.displayID, name: target.title)
                        }
                    } else {
                        incoming.placement = .main
                    }
                }
                if let byID = localState.widgets.first(where: { $0.id == incoming.id }) {
                    matchedLocalIDs.insert(byID.id)
                    if widgetContentMatches(byID, incoming) {
                        unchanged += 1
                    } else {
                        conflicting += 1
                    }
                } else if let byContent = localState.widgets.first(where: { widgetContentMatches($0, incoming) }) {
                    matchedLocalIDs.insert(byContent.id)
                    unchanged += 1
                } else {
                    added += 1
                }
            }
            let localOnly = localState.widgets.filter { !matchedLocalIDs.contains($0.id) }.count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .widgets,
                    incomingCount: snapshot.widgets.count,
                    localCount: localState.widgets.count,
                    addedCount: added,
                    updatedCount: 0,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        // 7. Display Layouts
        do {
            var added = 0, conflicting = 0, unchanged = 0
            var matchedLocalIDs = Set<String>()
            for incoming in snapshot.layouts {
                if let local = localState.layouts.first(where: { $0.id == incoming.id })
                    ?? localState.layouts.first(where: { $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame })
                {
                    matchedLocalIDs.insert(local.id)
                    let remappedPairs = Set(
                        incoming.assignments.compactMap { assignment -> String? in
                            let mappedDisplay = suggestedDisplayMapping[assignment.displayID] ?? assignment.displayID
                            return "\(mappedDisplay)=\(assignment.wallpaperID)"
                        }
                    )
                    let localPairs = Set(local.assignments.map { "\($0.displayID)=\($0.wallpaperID)" })
                    if remappedPairs == localPairs {
                        unchanged += 1
                    } else {
                        conflicting += 1
                    }
                } else {
                    added += 1
                }
            }
            let localOnly = localState.layouts.filter { !matchedLocalIDs.contains($0.id) }.count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .layouts,
                    incomingCount: snapshot.layouts.count,
                    localCount: localState.layouts.count,
                    addedCount: added,
                    updatedCount: 0,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        // 8. Video Trim Ranges
        do {
            var added = 0, conflicting = 0, unchanged = 0
            for (id, inc) in snapshot.videoTrims {
                if let loc = localState.videoTrims[id] {
                    if loc == inc { unchanged += 1 } else { conflicting += 1 }
                } else {
                    added += 1
                }
            }
            let localOnly = Set(localState.videoTrims.keys).subtracting(snapshot.videoTrims.keys).count
            diffs.append(
                SyncFolderCategoryDiff(
                    category: .videoTrims,
                    incomingCount: snapshot.videoTrims.count,
                    localCount: localState.videoTrims.count,
                    addedCount: added,
                    updatedCount: 0,
                    conflictingCount: conflicting,
                    unchangedCount: unchanged,
                    localOnlyCount: localOnly
                )
            )
        }

        return diffs
    }

    // MARK: - Matching & Reference Helpers

    private static func matchCollection(
        _ incoming: WallpaperCollection,
        in existing: [WallpaperCollection]
    ) -> WallpaperCollection? {
        if let byID = existing.first(where: { $0.id == incoming.id }) { return byID }
        let trimmed = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private static func matchPlan(
        _ incoming: PlaylistPlan,
        in existing: [PlaylistPlan]
    ) -> PlaylistPlan? {
        if let byID = existing.first(where: { $0.id == incoming.id }) { return byID }
        let trimmed = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private static func widgetContentMatches(_ lhs: DesktopWidget, _ rhs: DesktopWidget) -> Bool {
        var a = lhs
        var b = rhs
        a.id = ""
        b.id = ""
        // Preserve distinct target displays while ignoring display title wording changes.
        if case .display(let uuid, _) = a.placement {
            a.placement = .display(uuid: uuid, name: "")
        }
        if case .display(let uuid, _) = b.placement {
            b.placement = .display(uuid: uuid, name: "")
        }
        return a == b
    }

    private static func validateNoUserShortcutValues(in preset: WallpaperPropertyPreset) throws {
        for property in preset.properties {
            if case .string(let raw) = property.value, Self.isUserShortcutBindingValue(raw) {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid or non-portable property preset.")
                )
            }
        }
    }

    private static func allReferencedWorkshopItems(in snapshot: SyncFolderSnapshot) -> [SetupPackWorkshopItem] {
        var byID: [String: SetupPackWorkshopItem] = [:]
        var orderedIDs: [String] = []
        func register(_ rawID: String, title: String? = nil) {
            guard let id = SetupPackService.validatedWorkshopID(rawID) else { return }
            if var existing = byID[id] {
                if existing.title == nil, let title { existing.title = title; byID[id] = existing }
            } else {
                byID[id] = SetupPackWorkshopItem(id: id, title: title)
                orderedIDs.append(id)
            }
        }
        for item in snapshot.workshopItems { register(item.id, title: item.title) }
        for id in snapshot.favorites { register(id) }
        for collection in snapshot.collections {
            for id in collection.wallpaperIDs { register(id) }
        }
        for id in snapshot.metadata.keys { register(id) }
        for plan in snapshot.playlists {
            for id in plan.playlist.wallpaperIDs { register(id) }
            if let day = plan.playlist.dayWallpaperID { register(day) }
            if let night = plan.playlist.nightWallpaperID { register(night) }
        }
        for preset in snapshot.presets { register(preset.preset.wallpaperID) }
        for widget in snapshot.widgets {
            if case .wallpapers(let ids) = widget.scope {
                for id in ids { register(id) }
            }
        }
        for layout in snapshot.layouts {
            for assignment in layout.assignments { register(assignment.wallpaperID) }
        }
        for id in snapshot.videoTrims.keys { register(id) }
        return orderedIDs.compactMap { byID[$0] }
    }

    private static func allReferencedDisplays(in snapshot: SyncFolderSnapshot) -> [SetupPackDisplayDescriptor] {
        var descriptors = snapshot.displays
        var seen = Set(descriptors.map(\.id))
        for layout in snapshot.layouts {
            for assignment in layout.assignments where seen.insert(assignment.displayID).inserted {
                descriptors.append(
                    SetupPackDisplayDescriptor(
                        id: assignment.displayID,
                        name: assignment.displayTitle,
                        isPrimary: assignment.displayID == "primary" || assignment.displayID == "display-1"
                    )
                )
            }
        }
        for widget in snapshot.widgets {
            if case .display(let id, let name) = widget.placement, seen.insert(id).inserted {
                descriptors.append(
                    SetupPackDisplayDescriptor(
                        id: id,
                        name: name.isEmpty ? id : name,
                        isPrimary: id == "primary" || id == "display-1"
                    )
                )
            }
        }
        return descriptors
    }

    private static func sanitizationNotes(for summary: SyncFolderSanitizationSummary) -> [String] {
        var notes: [String] = []
        if summary.downgradedSpaceWidgets > 0 {
            notes.append(
                String(
                    localized:
                        "Space-pinned widgets were set to show on all Spaces because macOS Space IDs are specific to each Mac."
                )
            )
        }
        if summary.omittedImageWidgets > 0 {
            notes.append(
                String(
                    localized:
                        "Static image sticker widgets were omitted because sync snapshots do not copy media files."
                )
            )
        }
        if summary.strippedPresetPaths > 0 {
            notes.append(
                String(
                    localized:
                        "Local file paths in property presets were cleared so private paths are not synced."
                )
            )
        }
        if summary.strippedUserShortcutBindings > 0 {
            notes.append(
                String(
                    localized:
                        "Custom app and Apple Shortcut bindings in presets were cleared so they stay local to each Mac."
                )
            )
        }
        return notes
    }

    // MARK: - Strict Raw-JSON Validation (Pre-Decoder)

    private func validateRawMetadata(_ raw: Any?) throws {
        guard let raw else { return }
        guard let records = raw as? [String: Any] else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot contains an invalid wallpaper metadata entry.")
            )
        }
        guard records.count <= limits.maximumMetadataEntries else { throw oversizedError() }
        let allowedFields: Set<String> = ["customTags", "rating", "note", "excludedFromRotation"]
        for (wallpaperID, entryRaw) in records {
            guard Self.isSafeWallpaperID(wallpaperID),
                  let record = entryRaw as? [String: Any],
                  Set(record.keys).isSubset(of: allowedFields)
            else {
                throw SyncFolderFailure.invalidSnapshot(
                    String(localized: "This sync snapshot contains an invalid wallpaper metadata entry.")
                )
            }
            for (field, item) in record {
                switch field {
                case "customTags":
                    guard let tags = item as? [String] else { throw invalidMetadataError() }
                    try validateRawTags(
                        tags,
                        maximumCount: WallpaperMetadata.maximumTagsPerWallpaper,
                        maximumLength: WallpaperMetadata.maximumTagLength
                    )
                case "rating":
                    if item is NSNull { continue }
                    guard let value = strictInt(item), WallpaperMetadata.ratingRange.contains(value) else {
                        throw invalidMetadataError()
                    }
                case "note":
                    if item is NSNull { continue }
                    guard let text = item as? String, !text.contains("\0"),
                          text.count <= WallpaperMetadata.maximumNoteLength
                    else { throw invalidMetadataError() }
                case "excludedFromRotation":
                    guard isStrictBool(item) else { throw invalidMetadataError() }
                default:
                    throw invalidMetadataError()
                }
            }
        }
    }

    private func validateRawPlaylists(_ raw: Any?) throws {
        guard let raw else { return }
        guard let records = raw as? [[String: Any]] else {
            throw invalidPlaylistError()
        }
        guard records.count <= limits.maximumPlaylists else { throw oversizedError() }
        let allowedPlanKeys: Set<String> = ["id", "name", "playlist"]
        let allowedPlaylistKeys: Set<String> = [
            "mode", "source", "order", "trigger", "interval", "waitsForClipEnd",
            "skipRecentDays", "preferHigherRated", "smartQuery",
            "wallpaperIDs", "collectionID", "planID", "dayWallpaperID", "nightWallpaperID",
            "dayStart", "nightStart",
        ]
        for plan in records {
            guard Set(plan.keys).isSubset(of: allowedPlanKeys),
                  let playlist = plan["playlist"] as? [String: Any],
                  Set(playlist.keys).isSubset(of: allowedPlaylistKeys)
            else {
                throw invalidPlaylistError()
            }
            for (key, item) in playlist {
                switch key {
                case "mode":
                    guard let str = item as? String, PlaylistMode(rawValue: str) != nil else { throw invalidPlaylistError() }
                case "source":
                    guard let str = item as? String, PlaylistSource(rawValue: str) != nil else { throw invalidPlaylistError() }
                case "order":
                    guard let str = item as? String, PlaylistOrder(rawValue: str) != nil else { throw invalidPlaylistError() }
                case "trigger":
                    guard let str = item as? String, PlaylistTrigger(rawValue: str) != nil else { throw invalidPlaylistError() }
                case "waitsForClipEnd", "preferHigherRated":
                    guard isStrictBool(item) else { throw invalidPlaylistError() }
                case "interval":
                    guard let value = strictInt(item), DisplayPlaylist.intervalRange.contains(value) else {
                        throw invalidPlaylistError()
                    }
                case "skipRecentDays":
                    guard let value = strictInt(item), DisplayPlaylist.skipRecentDayRange.contains(value) else {
                        throw invalidPlaylistError()
                    }
                case "dayStart", "nightStart":
                    guard let value = strictInt(item), DisplayPlaylist.minuteOfDay(value) != nil else {
                        throw invalidPlaylistError()
                    }
                case "smartQuery":
                    try validateRawSmartQuery(item)
                case "wallpaperIDs":
                    guard let ids = item as? [String], ids.count <= limits.maximumCollectionWallpapers,
                          Set(ids).count == ids.count, ids.allSatisfy(Self.isSafeWallpaperID)
                    else { throw invalidPlaylistError() }
                case "dayWallpaperID", "nightWallpaperID":
                    if item is NSNull { continue }
                    guard let id = item as? String, Self.isSafeWallpaperID(id) else { throw invalidPlaylistError() }
                case "collectionID", "planID":
                    if item is NSNull { continue }
                    guard let id = item as? String, Self.isSafeIdentifier(id) else { throw invalidPlaylistError() }
                default:
                    throw invalidPlaylistError()
                }
            }
        }
    }

    private func validateRawSmartQuery(_ item: Any) throws {
        if item is NSNull { return }
        guard let query = item as? [String: Any] else { throw invalidPlaylistError() }
        let allowed: Set<String> = [
            "requiredTags", "excludedTags", "types", "minimumRating", "maximumEnergy",
            "favoritesOnly", "excludeMature",
        ]
        guard Set(query.keys).isSubset(of: allowed) else { throw invalidPlaylistError() }
        for (key, value) in query {
            switch key {
            case "requiredTags", "excludedTags":
                guard let tags = value as? [String] else { throw invalidPlaylistError() }
                try validateRawTags(
                    tags,
                    maximumCount: SmartPlaylistQuery.maximumTags,
                    maximumLength: SmartPlaylistQuery.maximumTagLength
                )
            case "types":
                guard let types = value as? [String] else { throw invalidPlaylistError() }
                var seen = Set<String>()
                for raw in types {
                    guard SmartWallpaperType(rawValue: raw) != nil, seen.insert(raw).inserted else {
                        throw invalidPlaylistError()
                    }
                }
            case "minimumRating":
                if value is NSNull { continue }
                guard let rating = strictInt(value), WallpaperMetadata.ratingRange.contains(rating) else {
                    throw invalidPlaylistError()
                }
            case "maximumEnergy":
                if value is NSNull { continue }
                guard let raw = value as? String, EnergyLevel(rawValue: raw) != nil else {
                    throw invalidPlaylistError()
                }
            case "favoritesOnly", "excludeMature":
                guard isStrictBool(value) else { throw invalidPlaylistError() }
            default:
                throw invalidPlaylistError()
            }
        }
    }

    private func validateRawVideoTrims(_ raw: Any?) throws {
        guard let raw else { return }
        guard let records = raw as? [String: Any] else { throw invalidTrimError() }
        guard records.count <= limits.maximumVideoTrims else { throw oversizedError() }
        let allowed: Set<String> = ["startSeconds", "endSeconds"]
        for (wallpaperID, value) in records {
            guard Self.isSafeWallpaperID(wallpaperID),
                  let entry = value as? [String: Any],
                  Set(entry.keys) == allowed,
                  let start = strictDouble(entry["startSeconds"]),
                  let end = strictDouble(entry["endSeconds"]),
                  (try? VideoTrimRange(startSeconds: start, endSeconds: end)) != nil
            else {
                throw invalidTrimError()
            }
        }
    }

    private func validateRawTags(_ tags: [String], maximumCount: Int, maximumLength: Int) throws {
        guard tags.count <= maximumCount else { throw invalidMetadataError() }
        var seen = Set<String>()
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maximumLength,
                  !trimmed.contains(where: { $0.isNewline || $0 == "\0" }),
                  seen.insert(trimmed.lowercased()).inserted
            else { throw invalidMetadataError() }
        }
    }

    private func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue == Double(number.intValue)
        else { return nil }
        return number.intValue
    }

    private func strictDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private func isStrictBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Low-Level Safe Atomic I/O & Linear JSON Depth Guard

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let fm = FileManager.default

        // Refuse to follow a symlink or overwrite a directory at the destination path.
        var existingStat = stat()
        let destinationExists: Bool
        if lstat(destination.path, &existingStat) == 0 {
            guard (existingStat.st_mode & S_IFMT) == S_IFREG else {
                throw SyncFolderFailure.unsafeFile(
                    String(localized: "WallpaperMachineSync.json must be a regular file, not a symbolic link or folder.")
                )
            }
            destinationExists = true
        } else if errno == ENOENT {
            destinationExists = false
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let tempURL = directory.appendingPathComponent(".\(Self.snapshotFileName).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempURL) }

        let descriptor = open(
            tempURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()

        if destinationExists {
            _ = try fm.replaceItemAt(
                destination,
                withItemAt: tempURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fm.moveItem(at: tempURL, to: destination)
        }
    }

    private func readRegularFile(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SyncFolderFailure.unsafeFile(
                String(localized: "WallpaperMachineSync.json must be a regular file, not a symbolic link or folder.")
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG
        else {
            throw SyncFolderFailure.unsafeFile(
                String(localized: "WallpaperMachineSync.json must be a regular file, not a symbolic link or folder.")
            )
        }
        guard status.st_size > 0, status.st_size <= Int64(limits.maximumFileBytes) else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot is empty or exceeds the 8 MB size limit.")
            )
        }
        guard let data = try handle.read(upToCount: limits.maximumFileBytes + 1),
              data.count <= limits.maximumFileBytes
        else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This sync snapshot is empty or exceeds the 8 MB size limit.")
            )
        }
        return data
    }

    /// Scans raw UTF-8 JSON bytes in O(n) time and O(1) stack space to reject excessive nesting,
    /// unbounded value node counts, or unbalanced/unterminated structure before `JSONSerialization`
    /// allocates any memory.
    private func validateJSONStructure(_ data: Data, maximumDepth: Int, maximumNodes: Int) throws {
        var depth = 0
        var nodes = 0
        var inString = false
        var escaped = false
        var inPrimitive = false
        var justClosedString = false

        func incrementNode() throws {
            nodes += 1
            if nodes > maximumNodes {
                throw oversizedError()
            }
        }

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // '\'
                    escaped = true
                } else if byte == 0x22 { // '"'
                    inString = false
                    justClosedString = true
                }
                continue
            }

            if justClosedString {
                switch byte {
                case 0x20, 0x09, 0x0A, 0x0D:
                    continue
                case 0x3A: // ':' — previous string was an object key, not a value node
                    justClosedString = false
                    inPrimitive = false
                    continue
                default:
                    try incrementNode()
                    justClosedString = false
                }
            }

            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A: // whitespace, ',', ':'
                inPrimitive = false
            case 0x22: // '"'
                inPrimitive = false
                inString = true
            case 0x7B, 0x5B: // '{', '['
                inPrimitive = false
                depth += 1
                if depth > maximumDepth {
                    throw oversizedError()
                }
                try incrementNode()
            case 0x7D, 0x5D: // '}', ']'
                inPrimitive = false
                depth -= 1
                if depth < 0 {
                    throw SyncFolderFailure.invalidSnapshot(
                        String(localized: "This file is not a valid WallpaperMachine sync snapshot.")
                    )
                }
            default:
                if !inPrimitive {
                    inPrimitive = true
                    try incrementNode()
                }
            }
        }

        if justClosedString {
            try incrementNode()
        }
        guard depth == 0, !inString else {
            throw SyncFolderFailure.invalidSnapshot(
                String(localized: "This file is not a valid WallpaperMachine sync snapshot.")
            )
        }
    }

    private func validateJSONTree(_ node: Any, depth: Int, visited: inout Int) throws {
        guard depth <= limits.maximumJSONDepth else { throw oversizedError() }
        visited += 1
        guard visited <= limits.maximumJSONNodes else { throw oversizedError() }
        if let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            guard number.doubleValue.isFinite else { throw oversizedError() }
        } else if let dictionary = node as? [String: Any] {
            for value in dictionary.values {
                try validateJSONTree(value, depth: depth + 1, visited: &visited)
            }
        } else if let array = node as? [Any] {
            for element in array {
                try validateJSONTree(element, depth: depth + 1, visited: &visited)
            }
        }
    }

    private func contains(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    private func oversizedError() -> SyncFolderFailure {
        .invalidSnapshot(
            String(localized: "This sync snapshot exceeds the supported depth or item limits.")
        )
    }

    private func invalidMetadataError() -> SyncFolderFailure {
        .invalidSnapshot(
            String(localized: "This sync snapshot contains an invalid wallpaper metadata entry.")
        )
    }

    private func invalidPlaylistError() -> SyncFolderFailure {
        .invalidSnapshot(
            String(localized: "This sync snapshot contains an invalid saved playlist.")
        )
    }

    private func invalidTrimError() -> SyncFolderFailure {
        .invalidSnapshot(
            String(localized: "This sync snapshot contains an invalid video trim range.")
        )
    }
}
