import Foundation

/// How a display changes wallpaper on its own.
enum PlaylistMode: String, Codable, CaseIterable, Sendable {
    /// The wallpaper changes only when the user changes it.
    case off
    /// A new wallpaper from `PlaylistSource` every `interval` minutes.
    case rotate
    /// One wallpaper by day and another by night, switched at two times of day.
    case dayNight
}

/// Which wallpapers a rotation draws from.
enum PlaylistSource: String, Codable, CaseIterable, Sendable {
    case all
    case favorites
    /// The wallpapers the user added to this display's list, in the order they were added.
    case list
    /// The live membership of a reusable local collection.
    case collection
    /// A dynamic query over installed wallpapers evaluated in memory on each pick.
    case smart
}

/// Wallpaper kind filter used by `SmartPlaylistQuery`, separating packaged still images from
/// interactive web wallpapers without disk I/O.
enum SmartWallpaperType: String, Codable, CaseIterable, Hashable, Sendable {
    case scene
    case video
    case web
    case still

    /// Classifies an installed wallpaper from its id and renderer kind without reading disk.
    static func of(id: String, kind: BridgeWallpaperKind) -> SmartWallpaperType? {
        if id.hasPrefix("pixiv-") || id.hasPrefix("image-") { return .still }
        switch kind {
        case .projectScene: return .scene
        case .video: return .video
        case .webpage: return .web
        case .unknown: return nil
        }
    }
}

extension EnergyLevel {
    /// Numeric ordering for maximum-energy comparisons (`low < medium < high`).
    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

/// Filter rules for a Smart Dynamic Playlist (`PlaylistSource.smart`), evaluated in memory on demand.
struct SmartPlaylistQuery: Codable, Equatable, Hashable, Sendable {
    static let maximumTags = 32
    static let maximumTagLength = 64

    /// Every tag listed here must appear in the wallpaper's manifest tags or user custom tags.
    var requiredTags: [String] = []
    /// Wallpapers carrying any of these tags (manifest or user custom tags) are excluded.
    var excludedTags: [String] = []
    /// Allowed wallpaper types; empty matches every playable type.
    var types: [SmartWallpaperType] = []
    /// Minimum star rating (1...5); nil matches any rating (including unrated).
    var minimumRating: Int? = nil
    /// Maximum energy level; nil matches any energy level (including unrated). When set, only
    /// wallpapers with a recorded energy rating at or below this level match.
    var maximumEnergy: EnergyLevel? = nil
    /// When true, only favorited wallpapers match.
    var favoritesOnly: Bool = false
    /// When true, wallpapers marked Mature / R-18 (manifest content rating or tags) are excluded.
    var excludeMature: Bool = false

    init(
        requiredTags: [String] = [],
        excludedTags: [String] = [],
        types: [SmartWallpaperType] = [],
        minimumRating: Int? = nil,
        maximumEnergy: EnergyLevel? = nil,
        favoritesOnly: Bool = false,
        excludeMature: Bool = false
    ) {
        self.requiredTags = Self.normalizedTags(requiredTags)
        self.excludedTags = Self.normalizedTags(excludedTags)
        self.types = Self.normalizedTypes(types)
        self.minimumRating = WallpaperMetadata.normalizedRating(minimumRating)
        self.maximumEnergy = maximumEnergy
        self.favoritesOnly = favoritesOnly
        self.excludeMature = excludeMature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let required = (try? container.decodeIfPresent([String].self, forKey: .requiredTags)) ?? []
        let excluded = (try? container.decodeIfPresent([String].self, forKey: .excludedTags)) ?? []
        let types = (try? container.decodeIfPresent([SmartWallpaperType].self, forKey: .types)) ?? []
        let minimumRating = (try? container.decodeIfPresent(Int.self, forKey: .minimumRating)) ?? nil
        let maximumEnergy = (try? container.decodeIfPresent(EnergyLevel.self, forKey: .maximumEnergy)) ?? nil
        let favoritesOnly = (try? container.decodeIfPresent(Bool.self, forKey: .favoritesOnly)) ?? false
        let excludeMature = (try? container.decodeIfPresent(Bool.self, forKey: .excludeMature)) ?? false
        self.init(
            requiredTags: required,
            excludedTags: excluded,
            types: types,
            minimumRating: minimumRating,
            maximumEnergy: maximumEnergy,
            favoritesOnly: favoritesOnly,
            excludeMature: excludeMature
        )
    }

    /// Whether evaluating this query needs manifest tags or content rating (not just in-memory
    /// bridge entries, favorites, user metadata and energy ratings).
    var needsManifestMetadata: Bool {
        !requiredTags.isEmpty || !excludedTags.isEmpty || excludeMature
    }

    /// True when no rule is active, so every non-excluded playable wallpaper matches.
    var isEmpty: Bool {
        requiredTags.isEmpty && excludedTags.isEmpty && types.isEmpty
            && minimumRating == nil && maximumEnergy == nil
            && !favoritesOnly && !excludeMature
    }

    /// Canonical string for shuffle-round identity.
    var signature: String {
        let req = requiredTags.map { $0.lowercased() }.sorted().joined(separator: ",")
        let exc = excludedTags.map { $0.lowercased() }.sorted().joined(separator: ",")
        let typ = Self.normalizedTypes(types).map(\.rawValue).joined(separator: ",")
        let rat = minimumRating.map(String.init) ?? ""
        let eng = maximumEnergy?.rawValue ?? ""
        return "r=\(req);x=\(exc);t=\(typ);s=\(rat);e=\(eng);f=\(favoritesOnly ? 1 : 0);m=\(excludeMature ? 1 : 0)"
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maximumTagLength,
                  !trimmed.contains(where: { $0.isNewline || $0 == "\0" }) else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                result.append(trimmed)
                if result.count >= maximumTags { break }
            }
        }
        return result
    }

    static func normalizedTypes(_ types: [SmartWallpaperType]) -> [SmartWallpaperType] {
        let selected = Set(types)
        return SmartWallpaperType.allCases.filter(selected.contains)
    }
}

enum PlaylistOrder: String, Codable, CaseIterable, Sendable {
    case sequential
    case shuffle
}

/// What makes a rotating display move on to its next wallpaper.
enum PlaylistTrigger: String, Codable, CaseIterable, Sendable {
    /// Every `DisplayPlaylist.interval` minutes.
    case interval
    /// Each time the Mac is unlocked, and not on a timer.
    case unlock
}

/// One display's playlist. Every field has a default, so a display nobody configured is `off`
/// and a playlist saved by an older build decodes with the fields it lacks filled in.
struct DisplayPlaylist: Codable, Equatable, Sendable {
    /// The intervals the panel's menu offers, in minutes.
    static let intervals = [5, 10, 15, 30, 60, 120, 180, 360, 720, 1440]
    static let minutesPerDay = 24 * 60
    /// Any whole number of minutes from one minute to a week can be typed in as a custom interval.
    static let intervalRange = 1...(7 * minutesPerDay)
    /// The "Skip recently used" menu choices, in days (0 disables the filter).
    static let skipRecentDayChoices = [0, 1, 3, 7, 30]
    static let skipRecentDayRange = 0...365

    var mode: PlaylistMode = .off
    var source: PlaylistSource = .all
    var order: PlaylistOrder = .sequential
    /// What a rotation waits for. A build that does not know a stored trigger rotates on the interval.
    var trigger: PlaylistTrigger = .interval
    /// Minutes between changes; one of `intervals` or a custom value in `intervalRange`.
    /// An `unlock` rotation keeps it, so choosing a time again shows the last one.
    var interval = 30
    /// Whether a timed change that falls due while a video plays on the display waits for the
    /// clip to reach its end, so it is never cut mid-scene. Off for a playlist saved before it
    /// existed.
    var waitsForClipEnd = false
    /// Avoid picking wallpapers used within this many days (0 = off). Falls back to the full
    /// candidate pool when every candidate was used recently.
    var skipRecentDays = 0
    /// When shuffling, weight 4- and 5-star wallpapers higher than unrated or low-rated ones.
    var preferHigherRated = false
    /// Filter query for `.smart` playlists; kept even if the user temporarily picks another source.
    var smartQuery: SmartPlaylistQuery?
    var wallpaperIDs: [String] = []
    var collectionID: String?
    /// Saved plan identity; an actual manual edit detaches the display's copy.
    var planID: String?
    var dayWallpaperID: String?
    var nightWallpaperID: String?
    /// Minutes after local midnight at which the day and the night wallpapers take over.
    var dayStart = 7 * 60
    var nightStart = 19 * 60

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DisplayPlaylist()
        mode = (try? container.decodeIfPresent(PlaylistMode.self, forKey: .mode)) ?? fallback.mode
        source = (try? container.decodeIfPresent(PlaylistSource.self, forKey: .source)) ?? fallback.source
        order = (try? container.decodeIfPresent(PlaylistOrder.self, forKey: .order)) ?? fallback.order
        trigger = (try? container.decodeIfPresent(PlaylistTrigger.self, forKey: .trigger)) ?? fallback.trigger
        let interval = (try? container.decodeIfPresent(Int.self, forKey: .interval)) ?? fallback.interval
        self.interval = Self.intervalRange.contains(interval) ? interval : fallback.interval
        waitsForClipEnd = (try? container.decodeIfPresent(Bool.self, forKey: .waitsForClipEnd)) ?? fallback.waitsForClipEnd
        let skipDays = (try? container.decodeIfPresent(Int.self, forKey: .skipRecentDays)) ?? fallback.skipRecentDays
        skipRecentDays = Self.skipRecentDayRange.contains(skipDays) ? skipDays : fallback.skipRecentDays
        preferHigherRated = (try? container.decodeIfPresent(Bool.self, forKey: .preferHigherRated)) ?? fallback.preferHigherRated
        smartQuery = try? container.decodeIfPresent(SmartPlaylistQuery.self, forKey: .smartQuery)
        wallpaperIDs = (try? container.decodeIfPresent([String].self, forKey: .wallpaperIDs)) ?? []
        collectionID = try? container.decodeIfPresent(String.self, forKey: .collectionID)
        planID = try? container.decodeIfPresent(String.self, forKey: .planID)
        dayWallpaperID = try? container.decodeIfPresent(String.self, forKey: .dayWallpaperID)
        nightWallpaperID = try? container.decodeIfPresent(String.self, forKey: .nightWallpaperID)
        dayStart = Self.minuteOfDay((try? container.decodeIfPresent(Int.self, forKey: .dayStart)) ?? nil)
            ?? fallback.dayStart
        nightStart = Self.minuteOfDay((try? container.decodeIfPresent(Int.self, forKey: .nightStart)) ?? nil)
            ?? fallback.nightStart
    }

    /// The Smart Playlist query in force for `.smart` mode, defaulting to an empty match-all query.
    var effectiveSmartQuery: SmartPlaylistQuery {
        smartQuery ?? SmartPlaylistQuery()
    }

    /// Whether this playlist changes wallpaper on a timer, and so has a next change to date.
    var hasTimer: Bool { mode == .rotate && trigger == .interval }

    /// A minute of the day, or nil when `value` is missing or outside 0..<1440.
    static func minuteOfDay(_ value: Int?) -> Int? {
        guard let value, (0..<minutesPerDay).contains(value) else { return nil }
        return value
    }
}

/// A reusable playlist configuration with no display identity or timer state.
struct PlaylistPlan: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var playlist: DisplayPlaylist
}
