import Foundation

/// Per-wallpaper user metadata: custom tags, 1–5 star rating, optional short note, and whether
/// the wallpaper is excluded from automatic rotation and Random Wallpaper.
struct WallpaperMetadata: Codable, Equatable, Hashable, Sendable {
    static let ratingRange = 1...5
    static let maximumTagLength = 64
    static let maximumTagsPerWallpaper = 32
    static let maximumNoteLength = 280

    var customTags: [String] = []
    /// User rating from 1 to 5 stars, or nil when unrated.
    var rating: Int? = nil
    /// Optional short user note; nil when unset.
    var note: String? = nil
    /// When true, skipped by All wallpapers, Favorites, Smart playlists and Random Wallpaper.
    /// Explicit display lists and local collections still play it.
    var excludedFromRotation: Bool = false

    init(
        customTags: [String] = [],
        rating: Int? = nil,
        note: String? = nil,
        excludedFromRotation: Bool = false
    ) {
        self.customTags = Self.normalizedTags(customTags)
        self.rating = Self.normalizedRating(rating)
        self.note = Self.normalizedNote(note)
        self.excludedFromRotation = excludedFromRotation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTags = (try? container.decodeIfPresent([String].self, forKey: .customTags)) ?? []
        let rawRating = (try? container.decodeIfPresent(Int.self, forKey: .rating)) ?? nil
        let rawNote = (try? container.decodeIfPresent(String.self, forKey: .note)) ?? nil
        let rawExcluded = (try? container.decodeIfPresent(Bool.self, forKey: .excludedFromRotation)) ?? false
        self.init(
            customTags: rawTags,
            rating: rawRating,
            note: rawNote,
            excludedFromRotation: rawExcluded
        )
    }

    /// True when every field is at its default value, so the store can prune the entry.
    var isEmpty: Bool {
        customTags.isEmpty && rating == nil && (note == nil || note?.isEmpty == true) && !excludedFromRotation
    }

    /// Clamps a provided rating into `1...5`, leaving nil as nil.
    static func normalizedRating(_ value: Int?) -> Int? {
        value.map { min(max($0, ratingRange.lowerBound), ratingRange.upperBound) }
    }

    /// Trims, removes empty/invalid entries, deduplicates case-insensitively preserving first
    /// spelling, and enforces `maximumTagsPerWallpaper`.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maximumTagLength,
                  !trimmed.contains(where: { $0.isNewline || $0 == "\0" }) else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                result.append(trimmed)
                if result.count >= maximumTagsPerWallpaper { break }
            }
        }
        return result
    }

    /// Trims surrounding whitespace, drops NUL bytes, caps length, and returns nil for blank text.
    static func normalizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let cleaned = note.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumNoteLength))
    }

    /// Validates one user-entered tag strictly for interactive editing.
    static func validatedTag(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumTagLength,
              !trimmed.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw WallpaperMetadataError.invalidTag
        }
        return trimmed
    }

    /// Validates an optional user-entered note strictly for interactive editing.
    static func validatedNote(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.contains("\0") else { throw WallpaperMetadataError.invalidNote }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumNoteLength else { throw WallpaperMetadataError.invalidNote }
        return trimmed
    }
}

/// Per-wallpaper user metadata (custom tags, star ratings, notes, rotation exclusions),
/// persisted in UserDefaults via `PreservedJSON` and pruned whenever all fields return to default.
@MainActor
final class WallpaperMetadataStore {
    static let shared = WallpaperMetadataStore()
    nonisolated static let storageKey = "WallpaperMachine.wallpaperMetadata"
    static let didChangeNotification = Notification.Name("WallpaperMachine.wallpaperMetadataDidChange")

    private let defaults: UserDefaults
    private(set) var entries: [String: WallpaperMetadata]
    /// Saved metadata entries this build could not read, kept intact (`PreservedJSON`).
    private var unread: [String: Data] = [:]

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { PreservedJSON.readObject($0, as: WallpaperMetadata.self) }
        entries = (saved?.values ?? [:]).filter { !$0.key.isEmpty && !$0.value.isEmpty }
        unread = saved?.unread ?? [:]
    }

    func metadata(for id: String) -> WallpaperMetadata {
        entries[id] ?? WallpaperMetadata()
    }

    func isExcluded(_ id: String) -> Bool {
        entries[id]?.excludedFromRotation == true
    }

    /// All wallpaper ids marked excluded from automatic rotation and Random Wallpaper.
    var excludedIDs: Set<String> {
        Set(entries.compactMap { $0.value.excludedFromRotation ? $0.key : nil })
    }

    /// All custom tags across every wallpaper, deduplicated case-insensitively and sorted.
    var allCustomTags: [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for entry in entries.values {
            for tag in entry.customTags where seen.insert(tag.lowercased()).inserted {
                tags.append(tag)
            }
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Rating map for weighted shuffle (`wallpaperID -> 1...5`).
    var ratings: [String: Int] {
        entries.compactMapValues(\.rating)
    }

    func update(_ id: String, _ change: (inout WallpaperMetadata) -> Void) {
        guard !id.isEmpty else { return }
        let before = metadata(for: id)
        var after = before
        change(&after)
        after = WallpaperMetadata(
            customTags: after.customTags,
            rating: after.rating,
            note: after.note,
            excludedFromRotation: after.excludedFromRotation
        )
        guard after != before else { return }
        if after.isEmpty {
            entries[id] = nil
        } else {
            entries[id] = after
        }
        persist()
    }

    func setRating(_ rating: Int?, for id: String) {
        update(id) { $0.rating = WallpaperMetadata.normalizedRating(rating) }
    }

    func addTag(_ raw: String, to id: String) throws {
        let tag = try WallpaperMetadata.validatedTag(raw)
        let current = metadata(for: id)
        if current.customTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            return
        }
        guard current.customTags.count < WallpaperMetadata.maximumTagsPerWallpaper else {
            throw WallpaperMetadataError.tooManyTags
        }
        update(id) { $0.customTags.append(tag) }
    }

    func removeTag(_ tag: String, from id: String) {
        update(id) { meta in
            meta.customTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    func setNote(_ raw: String?, for id: String) throws {
        let note = try WallpaperMetadata.validatedNote(raw)
        update(id) { $0.note = note }
    }

    func setExcludedFromRotation(_ excluded: Bool, for id: String) {
        update(id) { $0.excludedFromRotation = excluded }
    }

    /// Drops metadata for wallpapers removed from the library.
    func forget(_ ids: [String]) {
        var changed = false
        for id in ids {
            if entries.removeValue(forKey: id) != nil { changed = true }
            if unread.removeValue(forKey: id) != nil { changed = true }
        }
        if changed { persist() }
    }

    private func persist() {
        if entries.isEmpty, unread.isEmpty {
            if defaults.object(forKey: Self.storageKey) != nil {
                defaults.removeObject(forKey: Self.storageKey)
            }
        } else if let data = try? PreservedJSON.writeObject(entries, keeping: unread) {
            defaults.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

enum WallpaperMetadataError: LocalizedError, Equatable {
    case invalidTag
    case tooManyTags
    case invalidNote

    var errorDescription: String? {
        switch self {
        case .invalidTag:
            String(localized: "Enter a tag between 1 and 64 characters, on one line.")
        case .tooManyTags:
            String(localized: "A wallpaper can have at most 32 custom tags.")
        case .invalidNote:
            String(localized: "Enter a note of at most 280 characters.")
        }
    }
}
