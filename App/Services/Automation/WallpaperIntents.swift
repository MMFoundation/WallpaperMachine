import AppIntents
import Foundation

/// The kind of an installed wallpaper, exposed to Shortcuts filters and query results.
enum WallpaperKindAppEnum: String, AppEnum, Sendable {
    case scene, video, web, unknown

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper type"
    static let caseDisplayRepresentations: [WallpaperKindAppEnum: DisplayRepresentation] = [
        .scene: "Scene",
        .video: "Video",
        .web: "Web",
        .unknown: "Other",
    ]

    init(_ kind: AppAutomation.WallpaperKind) {
        switch kind {
        case .scene: self = .scene
        case .video: self = .video
        case .web: self = .web
        case .unknown: self = .unknown
        }
    }

    var automationKind: AppAutomation.WallpaperKind {
        switch self {
        case .scene: .scene
        case .video: .video
        case .web: .web
        case .unknown: .unknown
        }
    }
}

/// An installed wallpaper as the Shortcuts app lists, filters, and returns it.
struct WallpaperEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper"
    static let defaultQuery = WallpaperQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Type")
    var kind: WallpaperKindAppEnum

    @Property(title: "Favorite")
    var isFavorite: Bool

    @Property(title: "Collections")
    var collectionNames: [String]

    init(
        id: String,
        title: String,
        kind: WallpaperKindAppEnum = .scene,
        isFavorite: Bool = false,
        collectionNames: [String] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isFavorite = isFavorite
        self.collectionNames = collectionNames
    }

    init(_ info: AppAutomation.WallpaperInfo) {
        self.init(
            id: info.id,
            title: info.title,
            kind: WallpaperKindAppEnum(info.kind),
            isFavorite: info.isFavorite,
            collectionNames: info.collectionNames)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// Filter predicates used by `WallpaperQuery`'s `EntityPropertyQuery` conformance.
enum WallpaperQueryPredicate: Equatable, Sendable {
    case titleEquals(String)
    case titleContains(String)
    case kindEquals(WallpaperKindAppEnum)
    case isFavoriteEquals(Bool)
    case collectionContains(String)

    func matches(_ entity: WallpaperEntity) -> Bool {
        switch self {
        case .titleEquals(let value):
            entity.title.localizedCaseInsensitiveCompare(value) == .orderedSame
        case .titleContains(let value):
            entity.title.localizedCaseInsensitiveContains(value)
        case .kindEquals(let value):
            entity.kind == value
        case .isFavoriteEquals(let value):
            entity.isFavorite == value
        case .collectionContains(let value):
            entity.collectionNames.contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }
}

/// The installed wallpapers that can play, supporting both string search and property filtering.
struct WallpaperQuery: EntityStringQuery, EntityPropertyQuery {
    typealias ComparatorMappingType = WallpaperQueryPredicate

    static let findIntentDescription: IntentDescription? = IntentDescription(
        "Finds installed wallpapers filtered by name, type, favorite status or collection.")

    static let properties = QueryProperties {
        Property(\WallpaperEntity.$title) {
            EqualToComparator { .titleEquals($0) }
            ContainsComparator { .titleContains($0) }
        }
        Property(\WallpaperEntity.$kind) {
            EqualToComparator { .kindEquals($0) }
        }
        Property(\WallpaperEntity.$isFavorite) {
            EqualToComparator { .isFavoriteEquals($0) }
        }
        Property(\WallpaperEntity.$collectionNames) {
            ContainsComparator { .collectionContains($0) }
        }
    }

    static let sortingOptions = SortingOptions {
        SortableBy(\WallpaperEntity.$title)
    }

    func entities(for identifiers: [WallpaperEntity.ID]) async throws -> [WallpaperEntity] {
        let wanted = Set(identifiers)
        return await Self.all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [WallpaperEntity] {
        await Self.all().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func entities(
        matching comparators: [WallpaperQueryPredicate],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<WallpaperEntity>],
        limit: Int?
    ) async throws -> [WallpaperEntity] {
        let all = await Self.all()
        return Self.apply(comparators: comparators, mode: mode, sortedBy: sortedBy, limit: limit, to: all)
    }

    func suggestedEntities() async throws -> [WallpaperEntity] {
        await Self.all()
    }

    static func apply(
        comparators: [WallpaperQueryPredicate],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<WallpaperEntity>],
        limit: Int?,
        to entities: [WallpaperEntity]
    ) -> [WallpaperEntity] {
        var result: [WallpaperEntity]
        if comparators.isEmpty {
            result = entities
        } else {
            result = entities.filter { entity in
                switch mode {
                case .and:
                    comparators.allSatisfy { $0.matches(entity) }
                case .or:
                    comparators.contains { $0.matches(entity) }
                }
            }
        }
        if let sort = sortedBy.first, sort.by == \WallpaperEntity.$title {
            result.sort { first, second in
                let order = first.title.localizedCaseInsensitiveCompare(second.title)
                return sort.order == .ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        if let limit, limit >= 0 {
            result = Array(result.prefix(limit))
        }
        return result
    }

    private static func all() async -> [WallpaperEntity] {
        await AppAutomation.shared.availableWallpaperInfo().map(WallpaperEntity.init)
    }
}

/// Structured read-only snapshot returned by `GetCurrentWallpaperIntent`.
struct CurrentWallpaperEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Current Wallpaper"

    @Property(title: "Display ID")
    var displayID: String

    @Property(title: "Display")
    var displayTitle: String

    @Property(title: "Wallpaper ID")
    var wallpaperID: String?

    @Property(title: "Wallpaper Title")
    var wallpaperTitle: String?

    @Property(title: "Wallpaper")
    var wallpaper: WallpaperEntity?

    @Property(title: "Playing")
    var isPlaying: Bool

    @Property(title: "Muted")
    var isMuted: Bool

    @Property(title: "Favorite")
    var isFavorite: Bool

    @Property(title: "Presentation Mode")
    var isPresentationMode: Bool

    init() {
        displayID = ""
        displayTitle = ""
        wallpaperID = nil
        wallpaperTitle = nil
        wallpaper = nil
        isPlaying = false
        isMuted = false
        isFavorite = false
        isPresentationMode = false
    }

    init(status: AppAutomation.CurrentWallpaperStatus) {
        displayID = status.displayID
        displayTitle = status.displayTitle
        wallpaperID = status.wallpaperID
        wallpaperTitle = status.wallpaperTitle
        if let id = status.wallpaperID {
            wallpaper = WallpaperEntity(
                id: id,
                title: status.wallpaperTitle ?? id,
                kind: WallpaperKindAppEnum(status.wallpaperKind ?? .unknown),
                isFavorite: status.isFavorite)
        } else {
            wallpaper = nil
        }
        isPlaying = status.isPlaying
        isMuted = status.isMuted
        isFavorite = status.isFavorite
        isPresentationMode = status.isPresentationMode
    }

    var displayRepresentation: DisplayRepresentation {
        let title = wallpaperTitle ?? String(localized: "No wallpaper")
        let playback = isPlaying ? String(localized: "Playing") : String(localized: "Paused")
        let subtitle = isMuted ? "\(displayTitle) · \(playback) · \(String(localized: "Muted"))" : "\(displayTitle) · \(playback)"
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct GetCurrentWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Returns the current wallpaper, playback state and mute state for a display, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<CurrentWallpaperEntity> {
        let status = try await AppAutomation.shared.currentWallpaperStatus(displayID: display?.id)
        return .result(value: CurrentWallpaperEntity(status: status))
    }
}

struct FindWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Finds installed wallpapers filtered by name, type, favorite status or collection.")

    @Parameter(title: "Name contains")
    var name: String?

    @Parameter(title: "Type")
    var kind: WallpaperKindAppEnum?

    @Parameter(title: "Favorites only", default: false)
    var favoritesOnly: Bool

    @Parameter(title: "Collection")
    var collection: WallpaperCollectionEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<[WallpaperEntity]> {
        let catalog = await AppAutomation.shared.availableWallpaperInfo()
        let filtered = Self.filter(
            catalog,
            name: name,
            kind: kind?.automationKind,
            favoritesOnly: favoritesOnly,
            collectionID: collection?.id)
        return .result(value: filtered.map(WallpaperEntity.init))
    }

    static func filter(
        _ catalog: [AppAutomation.WallpaperInfo],
        name: String?,
        kind: AppAutomation.WallpaperKind?,
        favoritesOnly: Bool,
        collectionID: String?
    ) -> [AppAutomation.WallpaperInfo] {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return catalog.filter { item in
            if !trimmedName.isEmpty, !item.title.localizedCaseInsensitiveContains(trimmedName) {
                return false
            }
            if let kind, item.kind != kind {
                return false
            }
            if favoritesOnly, !item.isFavorite {
                return false
            }
            if let collectionID, !item.collectionIDs.contains(collectionID) {
                return false
            }
            return true
        }
    }
}

struct PauseWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Wallpapers"
    static let description: IntentDescription? = IntentDescription("Pauses every wallpaper, as Pause in the menu bar does.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.pause)
        return .result()
    }
}

struct ResumeWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Wallpapers"
    static let description: IntentDescription? = IntentDescription("Plays every wallpaper again after a pause.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.play)
        return .result()
    }
}

struct ToggleWallpaperPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause Wallpapers"
    static let description: IntentDescription? = IntentDescription("Pauses wallpapers that are playing, and plays them when paused.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.togglePlayback)
        return .result()
    }
}

struct MuteWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Silences every wallpaper without changing their saved sound settings.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.mute)
        return .result()
    }
}

struct UnmuteWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Lets every wallpaper play its saved sound again after Mute Wallpapers.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.unmute)
        return .result()
    }
}

struct ToggleWallpaperMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Silences every wallpaper, or lets them play their saved sound again when they are already silenced.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.toggleMute)
        return .result()
    }
}

struct NextWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Changes a chosen display to its next wallpaper, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.next(display: display?.id))
        return .result()
    }
}

struct PreviousWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Returns a chosen display to its previous wallpaper, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.previous(display: display?.id))
        return .result()
    }
}

/// Where Random Wallpaper draws from.
enum RandomWallpaperSource: String, AppEnum {
    case all, favorites

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Choose from"
    static let caseDisplayRepresentations: [RandomWallpaperSource: DisplayRepresentation] = [
        .all: "All wallpapers", .favorites: "Favorites",
    ]

    var pool: AutomationCommand.RandomPool {
        switch self {
        case .all: .all
        case .favorites: .favorites
        }
    }
}

struct RandomWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Random Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Changes a chosen display to a random wallpaper other than the one it shows, optionally from a collection, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    @Parameter(title: "Choose from", default: .all)
    var source: RandomWallpaperSource

    @Parameter(title: "Collection")
    var collection: WallpaperCollectionEntity?

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(
            .random(display: display?.id, pool: source.pool, collection: collection?.id))
        return .result()
    }
}

struct ApplyWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Applies an installed wallpaper to a chosen display, to every display, or to the target display when none is chosen.")

    @Parameter(title: "Wallpaper")
    var wallpaper: WallpaperEntity

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    /// Wins over a chosen display: the wallpaper goes on every enabled independent display,
    /// all of them or none.
    @Parameter(title: "On all displays", default: false)
    var allDisplays: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$wallpaper)") {
            \.$display
            \.$allDisplays
        }
    }

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(
            allDisplays ? .applyEverywhere(wallpaperID: wallpaper.id) : .apply(wallpaperID: wallpaper.id, display: display?.id))
        return .result()
    }
}

struct ToggleFavoriteWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Favorite Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Adds or removes a wallpaper from Favorites. Leave Wallpaper empty to toggle the current wallpaper on the chosen or target display.")

    @Parameter(title: "Wallpaper")
    var wallpaper: WallpaperEntity?

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.toggleFavorite(wallpaperID: wallpaper?.id, display: display?.id))
        return .result()
    }
}

struct SetWallpaperVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Wallpaper Volume"
    static let description: IntentDescription? = IntentDescription(
        "Sets the wallpaper audio volume (0 to 100%) for a display, or the target display when none is chosen.")

    @Parameter(title: "Volume", controlStyle: .slider, inclusiveRange: (0, 100))
    var volume: Double

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult {
        guard volume.isFinite, (0...100).contains(volume) else {
            throw AutomationError(message: String(localized: "Volume must be between 0% and 100%."))
        }
        try await AppAutomation.shared.perform(.setVolume(Float(volume / 100.0), displayID: display?.id))
        return .result()
    }
}

struct ToggleDesktopWidgetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Desktop Widgets"
    static let description: IntentDescription? = IntentDescription(
        "Temporarily hides all desktop widgets, or shows them again without changing your widget list.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.toggleDesktopWidgets)
        return .result()
    }
}

struct ToggleDesktopIconsIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Desktop Icons"
    static let description: IntentDescription? = IntentDescription(
        "Shows or hides Finder’s desktop icons. Finder restarts to apply this.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.toggleDesktopIcons)
        return .result()
    }
}

struct TogglePresentationModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Presentation Mode"
    static let description: IntentDescription? = IntentDescription(
        "Pauses and mutes wallpapers and hides desktop widgets, or restores your previous state.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.togglePresentationMode)
        return .result()
    }
}

struct OpenControlPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Open WallpaperMachine"
    static let description: IntentDescription? = IntentDescription("Opens the control panel.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.open(page: nil))
        return .result()
    }
}

/// The actions Siri and Spotlight offer without the user building a shortcut first (max 10).
struct WallpaperMachineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleWallpaperPlaybackIntent(),
            phrases: ["Play or pause \(.applicationName)", "Play or pause wallpapers in \(.applicationName)"],
            shortTitle: "Play or Pause", systemImageName: "playpause")
        AppShortcut(
            intent: ToggleWallpaperMuteIntent(),
            phrases: ["Mute or unmute wallpapers in \(.applicationName)", "Mute wallpapers with \(.applicationName)"],
            shortTitle: "Mute or Unmute", systemImageName: "speaker.slash")
        AppShortcut(
            intent: NextWallpaperIntent(),
            phrases: ["Next wallpaper in \(.applicationName)", "Change wallpaper with \(.applicationName)"],
            shortTitle: "Next Wallpaper", systemImageName: "forward")
        AppShortcut(
            intent: RandomWallpaperIntent(),
            phrases: ["Random wallpaper in \(.applicationName)", "Pick a random wallpaper with \(.applicationName)"],
            shortTitle: "Random Wallpaper", systemImageName: "dice")
        AppShortcut(
            intent: ApplyWallpaperIntent(),
            phrases: ["Apply a wallpaper with \(.applicationName)"],
            shortTitle: "Apply Wallpaper", systemImageName: "photo.on.rectangle")
        AppShortcut(
            intent: PreviousWallpaperIntent(),
            phrases: ["Previous wallpaper in \(.applicationName)"],
            shortTitle: "Previous Wallpaper", systemImageName: "backward")
        AppShortcut(
            intent: ApplyWallpaperPlaylistIntent(),
            phrases: ["Apply a playlist with \(.applicationName)"],
            shortTitle: "Apply Playlist", systemImageName: "list.bullet")
        AppShortcut(
            intent: ApplyWallpaperPropertyPresetIntent(),
            phrases: ["Apply a property preset with \(.applicationName)"],
            shortTitle: "Apply Property Preset", systemImageName: "slider.horizontal.3")
        AppShortcut(
            intent: ApplyWallpaperDisplayLayoutIntent(),
            phrases: ["Apply a display layout with \(.applicationName)"],
            shortTitle: "Apply Display Layout", systemImageName: "display.2")
        AppShortcut(
            intent: TogglePresentationModeIntent(),
            phrases: ["Toggle presentation mode in \(.applicationName)", "Presentation mode in \(.applicationName)"],
            shortTitle: "Presentation Mode", systemImageName: "rectangle.on.rectangle.slash")
    }
}
