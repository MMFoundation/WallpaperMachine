import Foundation

/// In-memory per-wallpaper facts evaluated by `PlaylistPlanner` for Smart Dynamic Playlists.
struct SmartWallpaperFacts: Equatable, Sendable {
    var type: SmartWallpaperType?
    var manifestTags: [String] = []
    var energyLevel: EnergyLevel?
}

/// The decisions a playlist makes, kept free of state and clocks so they can be checked
/// directly: which wallpapers a rotation may pick, which one comes next, and which half of
/// the day it is.
enum PlaylistPlanner {
    enum Phase: String, Sendable {
        case day, night
    }

    private static let matureTags: Set<String> = ["mature", "r-18"]

    /// Whether one playable wallpaper satisfies `query`, combining manifest tags and user custom tags.
    static func matches(
        _ query: SmartPlaylistQuery,
        facts: SmartWallpaperFacts,
        metadata: WallpaperMetadata,
        isFavorite: Bool
    ) -> Bool {
        if query.favoritesOnly, !isFavorite { return false }
        if !query.types.isEmpty {
            guard let type = facts.type, query.types.contains(type) else { return false }
        }
        if let minimumRating = query.minimumRating {
            guard let rating = metadata.rating, rating >= minimumRating else { return false }
        }
        if let maximumEnergy = query.maximumEnergy {
            guard let level = facts.energyLevel, level.rank <= maximumEnergy.rank else { return false }
        }
        if query.excludeMature || !query.requiredTags.isEmpty || !query.excludedTags.isEmpty {
            var allTags = Set<String>()
            for tag in facts.manifestTags {
                let folded = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !folded.isEmpty { allTags.insert(folded) }
            }
            for tag in metadata.customTags {
                let folded = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !folded.isEmpty { allTags.insert(folded) }
            }
            if query.excludeMature, !allTags.isDisjoint(with: matureTags) {
                return false
            }
            if !query.requiredTags.isEmpty,
               !query.requiredTags.allSatisfy({ allTags.contains($0.lowercased()) }) {
                return false
            }
            if !query.excludedTags.isEmpty,
               query.excludedTags.contains(where: { allTags.contains($0.lowercased()) }) {
                return false
            }
        }
        return true
    }

    /// The wallpapers `playlist` rotates through: `library` is every playable wallpaper in
    /// library order, so a list entry or favorite that is gone or cannot play is skipped.
    ///
    /// Wallpapers marked `excludedFromRotation` are automatically omitted from `.all`, `.favorites`
    /// and `.smart` playlists; explicit `.list` and `.collection` playlists still play what the
    /// user explicitly placed in them. When `skipRecentDays > 0`, wallpapers used within that
    /// window are skipped, falling back to the full candidate pool if every candidate (other than
    /// `current`, when supplied) was used recently.
    static func candidates(
        for playlist: DisplayPlaylist,
        library: [String],
        favorites: Set<String>,
        collectionIDs: [String],
        metadata: [String: WallpaperMetadata] = [:],
        facts: [String: SmartWallpaperFacts] = [:],
        lastUsed: [String: Date] = [:],
        now: Date = Date(),
        current: String? = nil
    ) -> [String] {
        let base: [String]
        switch playlist.source {
        case .all:
            base = library.filter { metadata[$0]?.excludedFromRotation != true }
        case .favorites:
            base = library.filter { favorites.contains($0) && metadata[$0]?.excludedFromRotation != true }
        case .smart:
            let query = playlist.effectiveSmartQuery
            base = library.filter { id in
                let meta = metadata[id] ?? WallpaperMetadata()
                guard !meta.excludedFromRotation else { return false }
                return matches(
                    query,
                    facts: facts[id] ?? SmartWallpaperFacts(),
                    metadata: meta,
                    isFavorite: favorites.contains(id)
                )
            }
        case .list, .collection:
            let playable = Set(library)
            var seen = Set<String>()
            let ids = playlist.source == .collection ? collectionIDs : playlist.wallpaperIDs
            base = ids.filter { playable.contains($0) && seen.insert($0).inserted }
        }
        return filterRecentlyUsed(
            base,
            skipRecentDays: playlist.skipRecentDays,
            lastUsed: lastUsed,
            now: now,
            current: current
        )
    }

    /// Removes wallpapers used within `skipRecentDays`, falling back to `candidates` when no
    /// alternative candidate remains.
    static func filterRecentlyUsed(
        _ candidates: [String],
        skipRecentDays: Int,
        lastUsed: [String: Date],
        now: Date,
        current: String? = nil
    ) -> [String] {
        guard skipRecentDays > 0, !candidates.isEmpty, !lastUsed.isEmpty else { return candidates }
        let cutoff = now.addingTimeInterval(-TimeInterval(skipRecentDays) * 86_400)
        let fresh = candidates.filter { id in
            guard let used = lastUsed[id] else { return true }
            return used < cutoff
        }
        if let current {
            return fresh.contains(where: { $0 != current }) ? fresh : candidates
        }
        return fresh.isEmpty ? candidates : fresh
    }

    /// Relative weight used when `preferHigherRated` is enabled on a shuffled playlist.
    /// 4- and 5-star wallpapers receive substantially higher weight than unrated or low-rated ones,
    /// while every wallpaper stays eligible with a positive weight.
    static func weight(forRating rating: Int?) -> Int {
        switch rating {
        case 5: 6
        case 4: 4
        case 3: 2
        case 2: 1
        case 1: 1
        default: 2
        }
    }

    /// Pure deterministic weighted pick over `items` using star-rating weights.
    static func weightedRandomElement<Random: RandomNumberGenerator>(
        from items: [String],
        ratings: [String: Int],
        using random: inout Random
    ) -> String? {
        guard !items.isEmpty else { return nil }
        let weights = items.map { weight(forRating: ratings[$0]) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return items.randomElement(using: &random) }
        var pick = Int.random(in: 0..<total, using: &random)
        for (item, weight) in zip(items, weights) {
            if pick < weight { return item }
            pick -= weight
        }
        return items.last
    }

    /// The wallpaper to show after `current`, or nil when there is nothing else to show.
    ///
    /// In order, it is the one after `current`, wrapping, or the first when `current` is not in
    /// the list. Shuffled, it is a random pick that is neither `current` nor shown yet this round
    /// (`recent`, kept by `remember(_:in:candidates:)`), so every wallpaper comes round before
    /// one repeats and each round is a new order. When `preferHigherRated` is enabled on a
    /// shuffled playlist, selection draws with rating weights over `others` so 4- and 5-star
    /// wallpapers appear more frequently instead of being locked out by a uniform full-round cycle.
    static func next<Random: RandomNumberGenerator>(
        after current: String?, in candidates: [String], order: PlaylistOrder, recent: [String],
        preferHigherRated: Bool = false, ratings: [String: Int] = [:],
        using random: inout Random
    ) -> String? {
        let others = candidates.filter { $0 != current }
        guard !others.isEmpty else { return nil }
        switch order {
        case .sequential:
            guard let current, let index = candidates.firstIndex(of: current) else { return candidates.first }
            return candidates[(index + 1) % candidates.count]
        case .shuffle:
            if preferHigherRated {
                return weightedRandomElement(from: others, ratings: ratings, using: &random)
            }
            let fresh = others.filter { !recent.contains($0) }
            return (fresh.isEmpty ? others : fresh).randomElement(using: &random)
        }
    }

    /// The wallpapers shown this round once `pick` is shown. A round ends when every candidate
    /// has been, and the next starts empty; `next` never picks the wallpaper on screen, so the
    /// last of one round cannot open the next.
    static func remember(_ pick: String, in recent: [String], candidates: [String]) -> [String] {
        let shown = recent.filter { $0 != pick && candidates.contains($0) } + [pick]
        return Set(candidates).isSubset(of: shown) ? [] : shown
    }

    /// Which half of the day `date` falls in, and when the other half begins. The day runs from
    /// `dayStart` up to `nightStart`; when the day would start after the night, the day is the
    /// part that wraps past midnight instead.
    static func phase(at date: Date, dayStart: Int, nightStart: Int, calendar: Calendar) -> (phase: Phase, until: Date) {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        let isDay = dayStart <= nightStart
            ? (dayStart..<nightStart).contains(minute)
            : !(nightStart..<dayStart).contains(minute)
        let phase: Phase = isDay ? .day : .night
        let boundary = isDay ? nightStart : dayStart
        return (phase, nextOccurrence(ofMinute: boundary, after: date, calendar: calendar))
    }

    /// The first moment after `date` at `minute` past local midnight. Built from calendar
    /// components, so a day that is 23 or 25 hours long across a clock change still switches at
    /// the time on the clock.
    static func nextOccurrence(ofMinute minute: Int, after date: Date, calendar: Calendar) -> Date {
        let components = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(TimeInterval(DisplayPlaylist.minutesPerDay * 60))
    }
}
