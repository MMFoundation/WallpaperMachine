import Foundation
import UniformTypeIdentifiers

struct SetupPackFailure: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Hard caps enforced before and during `.wmpack` parsing so untrusted shared files cannot exhaust
/// memory, stack depth or store limits.
struct SetupPackLimits: Equatable, Sendable {
    var maximumFileBytes: Int = 2 * 1024 * 1024
    var maximumJSONDepth: Int = 24
    var maximumJSONNodes: Int = 50_000
    var maximumWorkshopItems: Int = 256
    var maximumDisplays: Int = 32
    var maximumPresets: Int = 128
    var maximumWidgets: Int = DesktopWidgetStore.limit
    var maximumLayouts: Int = WallpaperDisplayLayoutStore.limit
    var maximumTitleLength: Int = 256
    var maximumNameLength: Int = 128
}

/// A portable description of a display referenced inside a `.wmpack` file. Never carries raw
/// CoreGraphics hardware UUIDs or serial numbers.
struct SetupPackDisplayDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var isPrimary: Bool
    var width: Int?
    var height: Int?

    init(id: String, name: String, isPrimary: Bool = false, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.name = name
        self.isPrimary = isPrimary
        self.width = width
        self.height = height
    }
}

/// A connected display on the current Mac used as export source or import remapping target.
struct SetupPackTargetDisplay: Equatable, Identifiable, Sendable {
    /// Bridge/layout display ID (e.g. `"primary"`, `"1"`, or `"identity:..."`).
    var displayID: String
    /// CoreGraphics stable UUID string when available (used for `DesktopWidget.Placement.display`).
    var displayUUID: String?
    /// Human-readable display title.
    var title: String
    var isPrimary: Bool
    var width: Int?
    var height: Int?

    var id: String { displayID }

    init(
        displayID: String,
        displayUUID: String? = nil,
        title: String,
        isPrimary: Bool = false,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.title = title
        self.isPrimary = isPrimary
        self.width = width
        self.height = height
    }
}

/// A Steam Workshop wallpaper referenced by a `.wmpack` file (numeric ID + optional preview title).
struct SetupPackWorkshopItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String?

    init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

/// Counts of non-portable elements stripped or downgraded during export so both the exporter and
/// the recipient's import preview can explain what changed without leaking private identifiers.
struct SetupPackSanitizationSummary: Codable, Equatable, Sendable {
    var downgradedSpaceWidgets: Int = 0
    var omittedImageWidgets: Int = 0
    var strippedPresetPaths: Int = 0
    var omittedNonWorkshopPresets: Int = 0
    var omittedNonWorkshopLayouts: Int = 0
    var omittedNonWorkshopAssignments: Int = 0
    var omittedNonWorkshopWidgetScopes: Int = 0

    var hasAdjustments: Bool {
        downgradedSpaceWidgets > 0 || omittedImageWidgets > 0 || strippedPresetPaths > 0
            || omittedNonWorkshopPresets > 0 || omittedNonWorkshopLayouts > 0
            || omittedNonWorkshopAssignments > 0 || omittedNonWorkshopWidgetScopes > 0
    }
}

/// Top-level JSON document serialized into a lightweight `.wmpack` file.
///
/// Deliberately contains NO media binaries, NO Steam credentials or sessions, NO local user paths,
/// and NO machine-local macOS Space UUIDs.
struct SetupPackDocument: Codable, Equatable, Sendable {
    static let formatIdentifier = "app.wallpapermachine.setup-pack"
    static let currentVersion = 1

    var format: String = Self.formatIdentifier
    var version: Int = Self.currentVersion
    var createdAt: Date
    var name: String?
    var displays: [SetupPackDisplayDescriptor]
    var workshopItems: [SetupPackWorkshopItem]
    var presets: [WallpaperPresetDocument]
    var widgets: [DesktopWidget]
    var layouts: [WallpaperDisplayLayout]
    var sanitization: SetupPackSanitizationSummary?

    init(
        format: String = Self.formatIdentifier,
        version: Int = Self.currentVersion,
        createdAt: Date = Date(),
        name: String? = nil,
        displays: [SetupPackDisplayDescriptor] = [],
        workshopItems: [SetupPackWorkshopItem] = [],
        presets: [WallpaperPresetDocument] = [],
        widgets: [DesktopWidget] = [],
        layouts: [WallpaperDisplayLayout] = [],
        sanitization: SetupPackSanitizationSummary? = nil
    ) {
        self.format = format
        self.version = version
        self.createdAt = createdAt
        self.name = name
        self.displays = displays
        self.workshopItems = workshopItems
        self.presets = presets
        self.widgets = widgets
        self.layouts = layouts
        self.sanitization = sanitization
    }
}

/// Inputs collected from the live stores to build a sanitized `.wmpack` export.
struct SetupPackExportInput: Sendable {
    var name: String?
    var displays: [SetupPackTargetDisplay]
    var libraryTitles: [String: String]
    var activeWallpaperIDs: [String]
    var presets: [WallpaperPropertyPreset]
    var widgets: [DesktopWidget]
    var layouts: [WallpaperDisplayLayout]
    var createdAt: Date

    init(
        name: String? = nil,
        displays: [SetupPackTargetDisplay] = [],
        libraryTitles: [String: String] = [:],
        activeWallpaperIDs: [String] = [],
        presets: [WallpaperPropertyPreset] = [],
        widgets: [DesktopWidget] = [],
        layouts: [WallpaperDisplayLayout] = [],
        createdAt: Date = Date()
    ) {
        self.name = name
        self.displays = displays
        self.libraryTitles = libraryTitles
        self.activeWallpaperIDs = activeWallpaperIDs
        self.presets = presets
        self.widgets = widgets
        self.layouts = layouts
        self.createdAt = createdAt
    }
}

/// Result returned after exporting a `.wmpack` file.
struct SetupPackExportReport: Equatable, Sendable {
    var destination: URL?
    var byteCount: Int
    var workshopItemCount: Int
    var presetCount: Int
    var widgetCount: Int
    var layoutCount: Int
    var sanitization: SetupPackSanitizationSummary
    var notes: [String]
}

/// Validated preview of an incoming `.wmpack` file before anything is modified on this Mac.
struct SetupPackPreview: Equatable, Sendable {
    var fileName: String
    var document: SetupPackDocument
    var byteCount: Int
    /// SHA-256 hex digest of the validated bytes, binding confirmation to what was reviewed.
    var digest: String
    var installedWorkshopItems: [SetupPackWorkshopItem]
    var missingWorkshopItems: [SetupPackWorkshopItem]
    var sourceDisplays: [SetupPackDisplayDescriptor]
    /// Best-fit automatic mapping from exported display slot ID to connected target `displayID`.
    var suggestedDisplayMapping: [String: String]
    var notes: [String]

    var hasAnyImportableContent: Bool {
        !document.presets.isEmpty || !document.widgets.isEmpty || !document.layouts.isEmpty
            || !missingWorkshopItems.isEmpty
    }
}

/// User choices made inside the import preview sheet before applying a setup pack in place.
struct SetupPackImportOptions: Equatable, Sendable {
    var includePresets: Bool = true
    var includeWidgets: Bool = true
    var includeLayouts: Bool = true
    /// Maps exported source display ID -> chosen connected target `displayID` (nil skips that display).
    var displayMapping: [String: String?] = [:]
    /// Must be explicitly confirmed by the user before queueing any Workshop downloads.
    var queueMissingDownloadsConfirmed: Bool = false

    init(
        includePresets: Bool = true,
        includeWidgets: Bool = true,
        includeLayouts: Bool = true,
        displayMapping: [String: String?] = [:],
        queueMissingDownloadsConfirmed: Bool = false
    ) {
        self.includePresets = includePresets
        self.includeWidgets = includeWidgets
        self.includeLayouts = includeLayouts
        self.displayMapping = displayMapping
        self.queueMissingDownloadsConfirmed = queueMissingDownloadsConfirmed
    }
}

/// Pure remapped payloads ready to be written into the live stores in place.
struct SetupPackImportPlan: Equatable, Sendable {
    var presets: [WallpaperPropertyPreset]
    var widgets: [DesktopWidget]
    var layouts: [WallpaperDisplayLayout]
    /// Non-empty ONLY when the user explicitly confirmed queueing downloads for missing items.
    var confirmedDownloadWorkshopIDs: [SetupPackWorkshopItem]
    var notes: [String]
}

/// Outcome summary after applying a setup pack in place.
struct SetupPackApplyReport: Equatable, Sendable {
    var importedPresetsCount: Int
    var importedWidgetsCount: Int
    var importedLayoutsCount: Int
    var queuedDownloadsCount: Int
    var notes: [String]
}
