import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Exports, validates, previews and remaps lightweight shareable `.wmpack` setup packs.
///
/// A `.wmpack` file is a compact, strictly validated UTF-8 JSON document containing referenced
/// Steam Workshop IDs, sanitized property presets, portable desktop widget configurations and
/// display layouts. It never contains media binaries, Steam credentials/sessions, machine-local
/// Space UUIDs or private local filesystem paths.
struct SetupPackService: Sendable {
    static let fileExtension = "wmpack"
    static let contentType = UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json

    let supportRoot: URL
    let storageRoot: URL
    let limits: SetupPackLimits

    private static let allowedTopLevelKeys: Set<String> = [
        "format", "version", "createdAt", "name", "displays",
        "workshopItems", "presets", "widgets", "layouts", "sanitization",
    ]

    init(
        supportRoot: URL = ClientPaths.supportURL,
        storageRoot: URL? = nil,
        limits: SetupPackLimits = .init()
    ) {
        self.supportRoot = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.storageRoot = (storageRoot ?? supportRoot).standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
    }

    // MARK: - Strict Workshop ID & identifier validation

    /// Returns the canonical ASCII decimal Workshop ID, or nil if `raw` is not a strict positive
    /// integer without leading zeros, signs, whitespace, path separators or traversal characters.
    static func validatedWorkshopID(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 20,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = UInt64(raw), parsed > 0,
              String(parsed) == raw
        else { return nil }
        return raw
    }

    static func isSafeDisplaySlotID(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= 128 && raw != "." && raw != ".."
            && !raw.contains("/") && !raw.contains("\\") && !raw.contains("\0")
            && !raw.contains(where: \.isNewline)
    }

    static func isSafeTitle(_ raw: String, limit: Int) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && raw.count <= limit
            && !raw.contains("\0")
            && !raw.contains(where: \.isNewline)
    }

    // MARK: - Export

    /// Builds a sanitized `SetupPackDocument` and returns its encoded UTF-8 JSON bytes and report.
    func buildDocument(from input: SetupPackExportInput) throws -> (document: SetupPackDocument, data: Data, report: SetupPackExportReport) {
        var sanitization = SetupPackSanitizationSummary()
        var workshopIDs = Set<String>()
        var slotBySourceKey: [String: String] = [:]
        var descriptors: [SetupPackDisplayDescriptor] = []

        func cleanDisplayName(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return String(localized: "Display") }
            // Strip renderer's trailing `(id - Role)` suffix so exported display names stay clean.
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
            let matched = input.displays.first { target in
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

        // 1. Collect active Workshop IDs if provided.
        for id in input.activeWallpaperIDs {
            if let valid = Self.validatedWorkshopID(id) {
                workshopIDs.insert(valid)
            }
        }

        // 2. Sanitize selected property presets (strip retainedPath, local/external file paths, and binary assets).
        var sanitizedPresets: [WallpaperPresetDocument] = []
        for preset in input.presets {
            guard let validWorkshopID = Self.validatedWorkshopID(preset.wallpaperID) else {
                sanitization.omittedNonWorkshopPresets += 1
                continue
            }
            var copy = preset
            copy.wallpaperID = validWorkshopID
            for index in copy.properties.indices {
                var property = copy.properties[index]
                var stripped = false
                if property.retainedPath != nil {
                    property.retainedPath = nil
                    stripped = true
                }
                if property.kind == "file" || property.kind == "directory" {
                    if !property.usesDefault && property.value != .empty && property.value != .string("") {
                        property.usesDefault = true
                        property.value = .empty
                        stripped = true
                    } else if property.usesDefault, case .string(let s) = property.value, !s.isEmpty {
                        property.value = .empty
                    }
                } else if property.kind == "texture", case .string(let path) = property.value,
                          WallpaperPresetStore.looksLikeLocalOrUnsafePath(path)
                {
                    property.usesDefault = true
                    property.value = .string("")
                    stripped = true
                }
                if stripped { sanitization.strippedPresetPaths += 1 }
                copy.properties[index] = property
            }
            try WallpaperPresetStore.validatePortableStructure(copy)
            workshopIDs.insert(validWorkshopID)
            sanitizedPresets.append(WallpaperPresetDocument(preset: copy, assets: [:]))
        }

        // 3. Sanitize desktop widgets (omit static image stickers, downgrade Space UUID bindings, remap displays).
        var sanitizedWidgets: [DesktopWidget] = []
        for widget in input.widgets {
            if widget.kind == .image || widget.imageAsset != nil {
                sanitization.omittedImageWidgets += 1
                continue
            }
            var copy = widget.clamped()
            copy.imageAsset = nil
            switch copy.scope {
            case .everywhere:
                break
            case .spaces:
                // Never export machine-local Space UUIDs.
                copy.scope = .everywhere
                sanitization.downgradedSpaceWidgets += 1
            case .wallpapers(let ids):
                let portableIDs = ids.compactMap(Self.validatedWorkshopID)
                if portableIDs.count != ids.count {
                    sanitization.omittedNonWorkshopWidgetScopes += (ids.count - portableIDs.count)
                }
                if portableIDs.isEmpty {
                    copy.scope = .everywhere
                } else {
                    copy.scope = .wallpapers(portableIDs)
                    workshopIDs.formUnion(portableIDs)
                }
            }
            if case .display(let uuid, let name) = copy.placement {
                let slot = registerDisplaySlot(sourceKey: uuid, fallbackName: name)
                copy.placement = .display(uuid: slot.slotID, name: slot.name)
            }
            sanitizedWidgets.append(copy)
        }

        // 4. Sanitize display layouts (keep only Workshop assignments and remap display IDs to portable slots).
        var sanitizedLayouts: [WallpaperDisplayLayout] = []
        for layout in input.layouts {
            var portableAssignments: [WallpaperDisplayAssignment] = []
            var seenSlots = Set<String>()
            for assignment in layout.assignments {
                guard let validWorkshopID = Self.validatedWorkshopID(assignment.wallpaperID) else {
                    sanitization.omittedNonWorkshopAssignments += 1
                    continue
                }
                let slot = registerDisplaySlot(
                    sourceKey: assignment.displayID,
                    fallbackName: assignment.displayTitle
                )
                guard seenSlots.insert(slot.slotID).inserted else { continue }
                workshopIDs.insert(validWorkshopID)
                portableAssignments.append(
                    WallpaperDisplayAssignment(
                        displayID: slot.slotID,
                        displayTitle: slot.name,
                        wallpaperID: validWorkshopID
                    )
                )
            }
            if portableAssignments.isEmpty {
                sanitization.omittedNonWorkshopLayouts += 1
                continue
            }
            sanitizedLayouts.append(
                WallpaperDisplayLayout(
                    id: layout.id,
                    name: layout.name,
                    assignments: portableAssignments,
                    autoApplyOnConnect: layout.autoApplyOnConnect
                )
            )
        }

        // Canonicalize display slot numbering so the primary display is always `display-1`,
        // regardless of whether widgets or layouts referenced a secondary display first.
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

        let trimmedName = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validName: String?
        if let trimmedName, !trimmedName.isEmpty {
            guard Self.isSafeTitle(trimmedName, limit: limits.maximumNameLength) else {
                throw SetupPackFailure(message: String(localized: "Enter a setup pack name of 1–128 characters."))
            }
            validName = trimmedName
        } else {
            validName = nil
        }

        let workshopItems = workshopIDs.sorted().map { id -> SetupPackWorkshopItem in
            let title = input.libraryTitles[id].flatMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\0", with: "")
                guard !trimmed.isEmpty else { return nil }
                return String(trimmed.prefix(limits.maximumTitleLength))
            }
            return SetupPackWorkshopItem(id: id, title: title)
        }

        let document = SetupPackDocument(
            createdAt: input.createdAt,
            name: validName,
            displays: descriptors,
            workshopItems: workshopItems,
            presets: sanitizedPresets,
            widgets: sanitizedWidgets,
            layouts: sanitizedLayouts,
            sanitization: sanitization.hasAdjustments ? sanitization : nil
        )

        guard !document.workshopItems.isEmpty || !document.presets.isEmpty
            || !document.widgets.isEmpty || !document.layouts.isEmpty
        else {
            throw SetupPackFailure(
                message: String(localized: "Nothing shareable was selected. Choose at least one Workshop wallpaper, preset, layout or portable widget.")
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(document)

        // Round-trip self-check through strict validation before publishing bytes.
        _ = try parseAndValidate(data: data)

        let notes = Self.sanitizationNotes(for: sanitization, context: .export)
        let report = SetupPackExportReport(
            destination: nil,
            byteCount: data.count,
            workshopItemCount: document.workshopItems.count,
            presetCount: document.presets.count,
            widgetCount: document.widgets.count,
            layoutCount: document.layouts.count,
            sanitization: sanitization,
            notes: notes
        )
        return (document, data, report)
    }

    /// Exports a sanitized `.wmpack` file atomically to `destination`, refusing locations inside
    /// WallpaperMachine's support or library storage folders.
    @discardableResult
    func export(to destination: URL, input: SetupPackExportInput) throws -> SetupPackExportReport {
        try Task.checkCancellation()
        let standardized = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
        guard standardized.pathExtension.lowercased() == Self.fileExtension,
              !contains(standardized, in: supportRoot),
              !contains(standardized, in: storageRoot)
        else {
            throw SetupPackFailure(
                message: String(localized: "Save the setup pack outside WallpaperMachine’s support folder with the .wmpack extension.")
            )
        }
        let built = try buildDocument(from: input)
        try Task.checkCancellation()
        try built.data.write(to: standardized, options: .atomic)
        var report = built.report
        report.destination = standardized
        return report
    }

    // MARK: - Strict Read, Validation & Preview

    /// Safely reads a regular `.wmpack` file without following symlinks and enforces size, UTF-8,
    /// JSON depth/node count and schema limits before returning a preview.
    func preview(
        fileAt url: URL,
        installedWallpaperIDs: Set<String>,
        connectedDisplays: [SetupPackTargetDisplay]
    ) throws -> SetupPackPreview {
        let data = try readRegularFile(at: url)
        return try preview(
            data: data,
            fileName: url.lastPathComponent,
            installedWallpaperIDs: installedWallpaperIDs,
            connectedDisplays: connectedDisplays
        )
    }

    func preview(
        data: Data,
        fileName: String,
        installedWallpaperIDs: Set<String>,
        connectedDisplays: [SetupPackTargetDisplay]
    ) throws -> SetupPackPreview {
        let validated = try parseAndValidate(data: data)
        let document = validated.document
        let allWorkshopItems = Self.allReferencedWorkshopItems(in: document)
        let installed = allWorkshopItems.filter { installedWallpaperIDs.contains($0.id) }
        let missing = allWorkshopItems.filter { !installedWallpaperIDs.contains($0.id) }
        let sourceDisplays = Self.allReferencedDisplays(in: document)
        let suggested = Self.suggestDisplayMapping(
            sourceDisplays: sourceDisplays,
            targetDisplays: connectedDisplays
        )
        var notes = validated.importWarnings
        if let sanitization = document.sanitization {
            notes.append(contentsOf: Self.sanitizationNotes(for: sanitization, context: .importPreview))
        }
        return SetupPackPreview(
            fileName: fileName,
            document: document,
            byteCount: data.count,
            digest: WallpaperBackupFiles.digest(data),
            installedWorkshopItems: installed,
            missingWorkshopItems: missing,
            sourceDisplays: sourceDisplays,
            suggestedDisplayMapping: suggested,
            notes: notes
        )
    }

    /// Parses and strictly validates raw `.wmpack` bytes. Rejects oversized files, malformed UTF-8,
    /// deeply nested JSON, unknown top-level keys, unsupported schema versions, non-numeric Workshop
    /// IDs, path traversal, binary preset attachments and local image widget references.
    func parseAndValidate(data: Data) throws -> (document: SetupPackDocument, importWarnings: [String]) {
        guard !data.isEmpty, data.count <= limits.maximumFileBytes else {
            throw SetupPackFailure(
                message: String(localized: "This setup pack is empty or exceeds the 2 MB size limit.")
            )
        }
        guard let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") else {
            throw SetupPackFailure(
                message: String(localized: "This setup pack is not valid UTF-8 text.")
            )
        }
        // O(n) raw-byte nesting guard runs BEFORE JSONSerialization so hostile payloads cannot
        // exhaust the call stack.
        try validateJSONDepth(data, maximumDepth: limits.maximumJSONDepth)

        let rawJSON: Any
        do {
            rawJSON = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SetupPackFailure(
                message: String(localized: "This file is not a valid WallpaperMachine setup pack.")
            )
        }
        guard let rootObject = rawJSON as? [String: Any] else {
            throw SetupPackFailure(
                message: String(localized: "This file is not a valid WallpaperMachine setup pack.")
            )
        }
        guard Set(rootObject.keys).isSubset(of: Self.allowedTopLevelKeys) else {
            throw SetupPackFailure(
                message: String(localized: "This setup pack contains unsupported fields and was rejected.")
            )
        }
        var visitedNodes = 0
        try validateJSONTree(rootObject, depth: 0, visited: &visitedNodes)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document: SetupPackDocument
        do {
            document = try decoder.decode(SetupPackDocument.self, from: data)
        } catch {
            throw SetupPackFailure(
                message: String(localized: "This file is not a supported WallpaperMachine setup pack.")
            )
        }

        guard document.format == SetupPackDocument.formatIdentifier,
              document.version == SetupPackDocument.currentVersion,
              document.createdAt.timeIntervalSince1970.isFinite
        else {
            throw SetupPackFailure(
                message: String(localized: "This setup pack version is not supported.")
            )
        }
        if let name = document.name {
            guard Self.isSafeTitle(name, limit: limits.maximumNameLength) else {
                throw SetupPackFailure(message: String(localized: "This setup pack contains an invalid name."))
            }
        }

        // Validate Workshop items.
        guard document.workshopItems.count <= limits.maximumWorkshopItems else {
            throw oversizedElementsError()
        }
        var seenWorkshopIDs = Set<String>()
        for item in document.workshopItems {
            guard Self.validatedWorkshopID(item.id) != nil,
                  seenWorkshopIDs.insert(item.id).inserted
            else {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid or duplicate Workshop ID.")
                )
            }
            if let title = item.title, !Self.isSafeTitle(title, limit: limits.maximumTitleLength) {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid wallpaper title.")
                )
            }
        }

        // Validate display descriptors.
        guard document.displays.count <= limits.maximumDisplays else {
            throw oversizedElementsError()
        }
        var seenDisplayIDs = Set<String>()
        for display in document.displays {
            guard Self.isSafeDisplaySlotID(display.id),
                  seenDisplayIDs.insert(display.id).inserted,
                  Self.isSafeTitle(display.name, limit: limits.maximumTitleLength)
            else {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid display entry.")
                )
            }
            if let width = display.width, !(1...32_768).contains(width) {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid display resolution.")
                )
            }
            if let height = display.height, !(1...32_768).contains(height) {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid display resolution.")
                )
            }
        }

        // Validate property presets (no binaries, no local paths, strict numeric Workshop IDs).
        guard document.presets.count <= limits.maximumPresets else {
            throw oversizedElementsError()
        }
        var seenPresetIDs = Set<String>()
        for presetDoc in document.presets {
            guard presetDoc.version == WallpaperPresetDocument.currentVersion,
                  presetDoc.assets.isEmpty,
                  Self.validatedWorkshopID(presetDoc.preset.wallpaperID) != nil,
                  seenPresetIDs.insert(presetDoc.preset.id.lowercased()).inserted
            else {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid or non-portable property preset.")
                )
            }
            do {
                try WallpaperPresetStore.validatePortableStructure(presetDoc.preset)
            } catch {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid or non-portable property preset.")
                )
            }
        }

        // Validate widgets (no static image sticker references; downgrade any stray Space UUID scopes).
        guard document.widgets.count <= limits.maximumWidgets else {
            throw oversizedElementsError()
        }
        var seenWidgetIDs = Set<String>()
        var downgradedIncomingSpaceWidgets = 0
        for index in document.widgets.indices {
            var widget = document.widgets[index]
            guard widget.isValid,
                  seenWidgetIDs.insert(widget.id.lowercased()).inserted,
                  widget.kind != .image,
                  widget.imageAsset == nil
            else {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid or non-portable desktop widget.")
                )
            }
            if case .display(let uuid, let name) = widget.placement {
                guard Self.isSafeDisplaySlotID(uuid),
                      !name.contains("\0"), !name.contains(where: \.isNewline)
                else {
                    throw SetupPackFailure(
                        message: String(localized: "This setup pack contains an invalid display reference in a widget.")
                    )
                }
            }
            switch widget.scope {
            case .everywhere:
                break
            case .wallpapers(let ids):
                guard ids.allSatisfy({ Self.validatedWorkshopID($0) != nil }) else {
                    throw SetupPackFailure(
                        message: String(localized: "This setup pack contains an invalid Workshop ID in a widget scope.")
                    )
                }
            case .spaces:
                // Never let foreign Space UUIDs enter local preferences.
                widget.scope = .everywhere
                document.widgets[index] = widget
                downgradedIncomingSpaceWidgets += 1
            }
        }

        // Validate display layouts.
        guard document.layouts.count <= limits.maximumLayouts else {
            throw oversizedElementsError()
        }
        var seenLayoutIDs = Set<String>()
        for layout in document.layouts {
            guard Self.isSafeDisplaySlotID(layout.id),
                  seenLayoutIDs.insert(layout.id.lowercased()).inserted,
                  Self.isSafeTitle(layout.name, limit: limits.maximumNameLength),
                  layout.name == layout.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !layout.assignments.isEmpty,
                  layout.assignments.count <= 64,
                  Set(layout.assignments.map(\.displayID)).count == layout.assignments.count
            else {
                throw SetupPackFailure(
                    message: String(localized: "This setup pack contains an invalid display layout.")
                )
            }
            for assignment in layout.assignments {
                guard Self.isSafeDisplaySlotID(assignment.displayID),
                      Self.isSafeTitle(assignment.displayTitle, limit: limits.maximumTitleLength),
                      Self.validatedWorkshopID(assignment.wallpaperID) != nil
                else {
                    throw SetupPackFailure(
                        message: String(localized: "This setup pack contains an invalid wallpaper or display assignment.")
                    )
                }
            }
        }

        var importWarnings: [String] = []
        if downgradedIncomingSpaceWidgets > 0 {
            importWarnings.append(
                String(localized: "Space-pinned widgets were set to show on all Spaces because macOS Space IDs are specific to each Mac.")
            )
        }
        return (document, importWarnings)
    }

    // MARK: - Automatic Display Remapping & Import Plan

    /// Computes a best-fit automatic mapping from exported source displays to the connected
    /// displays on this Mac: primary-to-primary first, then normalized name match, then resolution /
    /// aspect ratio match, then remaining unused displays, falling back to primary when the pack
    /// has more displays than this Mac.
    static func suggestDisplayMapping(
        sourceDisplays: [SetupPackDisplayDescriptor],
        targetDisplays: [SetupPackTargetDisplay]
    ) -> [String: String] {
        guard !sourceDisplays.isEmpty, !targetDisplays.isEmpty else { return [:] }
        var mapping: [String: String] = [:]
        var usedTargets = Set<String>()

        func normalizedName(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasSuffix(")"), let open = s.lastIndex(of: "("), open > s.startIndex {
                s = String(s[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return s.lowercased()
        }

        // Pass 1: primary -> primary
        if let primarySource = sourceDisplays.first(where: \.isPrimary),
           let primaryTarget = targetDisplays.first(where: \.isPrimary)
        {
            mapping[primarySource.id] = primaryTarget.displayID
            usedTargets.insert(primaryTarget.displayID)
        }

        // Pass 2: exact cleaned display name match
        for source in sourceDisplays where mapping[source.id] == nil {
            let wanted = normalizedName(source.name)
            if let match = targetDisplays.first(where: {
                !usedTargets.contains($0.displayID) && normalizedName($0.title) == wanted
            }) {
                mapping[source.id] = match.displayID
                usedTargets.insert(match.displayID)
            }
        }

        // Pass 3: exact resolution match
        for source in sourceDisplays where mapping[source.id] == nil {
            if let w = source.width, let h = source.height,
               let match = targetDisplays.first(where: {
                   !usedTargets.contains($0.displayID) && $0.width == w && $0.height == h
               })
            {
                mapping[source.id] = match.displayID
                usedTargets.insert(match.displayID)
            }
        }

        // Pass 4: remaining unused displays in order, else primary / first connected display
        let fallbackTarget = targetDisplays.first(where: \.isPrimary) ?? targetDisplays[0]
        for source in sourceDisplays where mapping[source.id] == nil {
            if let unused = targetDisplays.first(where: { !usedTargets.contains($0.displayID) }) {
                mapping[source.id] = unused.displayID
                usedTargets.insert(unused.displayID)
            } else {
                mapping[source.id] = fallbackTarget.displayID
            }
        }

        return mapping
    }

    /// Builds the remapped, ready-to-apply payload for `preview` using the user's `options`.
    /// Never includes missing Workshop downloads unless `options.queueMissingDownloadsConfirmed` is true.
    func prepareImportPlan(
        preview: SetupPackPreview,
        options: SetupPackImportOptions,
        connectedDisplays: [SetupPackTargetDisplay]
    ) throws -> SetupPackImportPlan {
        let targetsByID = Dictionary(
            uniqueKeysWithValues: connectedDisplays.map { ($0.displayID, $0) }
        )

        func resolvedTarget(for sourceID: String) -> SetupPackTargetDisplay? {
            if let explicit = options.displayMapping[sourceID] {
                return explicit.flatMap { targetsByID[$0] }
            }
            return preview.suggestedDisplayMapping[sourceID].flatMap { targetsByID[$0] }
        }

        var notes: [String] = []

        // 1. Presets
        let presets: [WallpaperPropertyPreset] = options.includePresets
            ? preview.document.presets.map(\.preset)
            : []

        // 2. Widgets (remap `.display(uuid:name:)` to target display's CoreGraphics UUID or `.main`)
        var widgets: [DesktopWidget] = []
        if options.includeWidgets {
            var skippedWidgets = 0
            for raw in preview.document.widgets {
                var widget = raw.clamped()
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
                widgets.append(widget)
            }
            if skippedWidgets > 0 {
                notes.append(
                    String(localized: "Skipped \(skippedWidgets) widget(s) pinned to unmapped displays.")
                )
            }
        }

        // 3. Display Layouts (remap assignment displayID + deduplicate when multiple source displays map to one target)
        var layouts: [WallpaperDisplayLayout] = []
        if options.includeLayouts {
            var skippedLayouts = 0
            for raw in preview.document.layouts {
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
                layouts.append(
                    WallpaperDisplayLayout(
                        id: UUID().uuidString,
                        name: raw.name,
                        assignments: remapped,
                        autoApplyOnConnect: raw.autoApplyOnConnect
                    )
                )
            }
            if skippedLayouts > 0 {
                notes.append(
                    String(localized: "Skipped \(skippedLayouts) display layout(s) with no mapped target displays.")
                )
            }
        }

        // 4. Missing Workshop items: strictly gated on explicit user confirmation.
        let confirmedDownloads: [SetupPackWorkshopItem] = options.queueMissingDownloadsConfirmed
            ? preview.missingWorkshopItems
            : []

        return SetupPackImportPlan(
            presets: presets,
            widgets: widgets,
            layouts: layouts,
            confirmedDownloadWorkshopIDs: confirmedDownloads,
            notes: notes
        )
    }

    // MARK: - Private helpers

    private enum NoteContext { case export, importPreview }

    private static func sanitizationNotes(
        for summary: SetupPackSanitizationSummary,
        context: NoteContext
    ) -> [String] {
        var notes: [String] = []
        if summary.downgradedSpaceWidgets > 0 {
            notes.append(
                String(localized: "Space-pinned widgets were set to show on all Spaces because macOS Space IDs are specific to each Mac.")
            )
        }
        if summary.omittedImageWidgets > 0 {
            notes.append(
                String(localized: "Static image sticker widgets were omitted because setup packs do not bundle media files.")
            )
        }
        if summary.strippedPresetPaths > 0 {
            notes.append(
                String(localized: "Local file paths in property presets were cleared so private paths are not shared.")
            )
        }
        if summary.omittedNonWorkshopPresets > 0 || summary.omittedNonWorkshopLayouts > 0
            || summary.omittedNonWorkshopAssignments > 0 || summary.omittedNonWorkshopWidgetScopes > 0
        {
            switch context {
            case .export:
                notes.append(
                    String(localized: "Local and non-Workshop wallpapers were omitted because setup packs share only Steam Workshop items.")
                )
            case .importPreview:
                notes.append(
                    String(localized: "Some local wallpapers from the original Mac were omitted during export.")
                )
            }
        }
        return notes
    }

    private static func allReferencedWorkshopItems(in document: SetupPackDocument) -> [SetupPackWorkshopItem] {
        var byID: [String: SetupPackWorkshopItem] = [:]
        var orderedIDs: [String] = []
        func register(_ id: String, title: String? = nil) {
            if var existing = byID[id] {
                if existing.title == nil, let title { existing.title = title; byID[id] = existing }
            } else {
                byID[id] = SetupPackWorkshopItem(id: id, title: title)
                orderedIDs.append(id)
            }
        }
        for item in document.workshopItems { register(item.id, title: item.title) }
        for preset in document.presets { register(preset.preset.wallpaperID) }
        for layout in document.layouts {
            for assignment in layout.assignments { register(assignment.wallpaperID) }
        }
        for widget in document.widgets {
            if case .wallpapers(let ids) = widget.scope {
                for id in ids { register(id) }
            }
        }
        return orderedIDs.compactMap { byID[$0] }
    }

    private static func allReferencedDisplays(in document: SetupPackDocument) -> [SetupPackDisplayDescriptor] {
        var descriptors = document.displays
        var seen = Set(descriptors.map(\.id))
        for layout in document.layouts {
            for assignment in layout.assignments where seen.insert(assignment.displayID).inserted {
                descriptors.append(
                    SetupPackDisplayDescriptor(
                        id: assignment.displayID,
                        name: assignment.displayTitle,
                        isPrimary: assignment.displayID == "primary"
                    )
                )
            }
        }
        for widget in document.widgets {
            if case .display(let id, let name) = widget.placement, seen.insert(id).inserted {
                descriptors.append(
                    SetupPackDisplayDescriptor(
                        id: id,
                        name: name.isEmpty ? id : name,
                        isPrimary: id == "primary"
                    )
                )
            }
        }
        return descriptors
    }

    private func readRegularFile(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SetupPackFailure(
                message: String(localized: "Choose a regular .wmpack file, not a symbolic link or folder.")
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG
        else {
            throw SetupPackFailure(
                message: String(localized: "Choose a regular .wmpack file, not a symbolic link or folder.")
            )
        }
        guard status.st_size > 0, status.st_size <= Int64(limits.maximumFileBytes) else {
            throw SetupPackFailure(
                message: String(localized: "This setup pack is empty or exceeds the 2 MB size limit.")
            )
        }
        guard let data = try handle.read(upToCount: limits.maximumFileBytes + 1),
              data.count <= limits.maximumFileBytes
        else {
            throw SetupPackFailure(
                message: String(localized: "This setup pack is empty or exceeds the 2 MB size limit.")
            )
        }
        return data
    }

    /// Scans raw UTF-8 JSON bytes in O(n) time and O(1) stack space to reject excessive nesting
    /// before invoking `JSONSerialization`.
    private func validateJSONDepth(_ data: Data, maximumDepth: Int) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // '\'
                    escaped = true
                } else if byte == 0x22 { // '"'
                    inString = false
                }
            } else {
                switch byte {
                case 0x22: // '"'
                    inString = true
                case 0x7B, 0x5B: // '{', '['
                    depth += 1
                    if depth > maximumDepth {
                        throw oversizedElementsError()
                    }
                case 0x7D, 0x5D: // '}', ']'
                    depth -= 1
                    if depth < 0 {
                        throw SetupPackFailure(
                            message: String(localized: "This file is not a valid WallpaperMachine setup pack.")
                        )
                    }
                default:
                    break
                }
            }
        }
    }

    private func validateJSONTree(_ node: Any, depth: Int, visited: inout Int) throws {
        guard depth <= limits.maximumJSONDepth else { throw oversizedElementsError() }
        visited += 1
        guard visited <= limits.maximumJSONNodes else { throw oversizedElementsError() }
        if let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            guard number.doubleValue.isFinite else { throw oversizedElementsError() }
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

    private func oversizedElementsError() -> SetupPackFailure {
        SetupPackFailure(
            message: String(localized: "This setup pack exceeds the supported depth or item limits.")
        )
    }
}
