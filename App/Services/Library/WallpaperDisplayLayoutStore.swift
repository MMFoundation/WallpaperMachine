import Foundation

struct WallpaperDisplayAssignment: Codable, Equatable, Sendable {
    var displayID: String
    var displayTitle: String
    var wallpaperID: String
}

struct WallpaperDisplayLayout: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var assignments: [WallpaperDisplayAssignment]
    var autoApplyOnConnect: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, assignments, autoApplyOnConnect
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        assignments: [WallpaperDisplayAssignment],
        autoApplyOnConnect: Bool = false
    ) {
        self.id = id
        self.name = name
        self.assignments = assignments
        self.autoApplyOnConnect = autoApplyOnConnect
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        assignments = try container.decode([WallpaperDisplayAssignment].self, forKey: .assignments)
        autoApplyOnConnect = try container.decodeIfPresent(Bool.self, forKey: .autoApplyOnConnect) ?? false
    }

    /// Canonical sorted unique display selector set used to match a connected display topology
    /// regardless of assignment order.
    nonisolated func normalizedDisplayTopology() -> [String] {
        Self.normalizedDisplayTopology(for: assignments.map(\.displayID))
    }

    nonisolated static func normalizedDisplayTopology(for displayIDs: some Sequence<String>) -> [String] {
        Set(
            displayIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ).sorted()
    }
}

/// Named wallpaper arrangements; playback rules and display topology stay independent.
@MainActor
final class WallpaperDisplayLayoutStore {
    static let shared = WallpaperDisplayLayoutStore()
    nonisolated static let storageKey = "WallpaperMachine.displayLayouts"
    static let didChangeNotification = Notification.Name("WallpaperMachine.displayLayoutsChanged")
    nonisolated static let limit = 64
    private let defaults: UserDefaults
    private(set) var layouts: [WallpaperDisplayLayout] = []
    private(set) var loadError: String?

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do { layouts = try Self.decode(data) }
        catch { loadError = error.localizedDescription }
    }

    func layout(_ id: String) throws -> WallpaperDisplayLayout {
        guard let value = layouts.first(where: { $0.id == id }) else { throw WallpaperDisplayLayoutError.missingLayout }
        return value
    }

    @discardableResult
    func save(
        name: String,
        assignments: [WallpaperDisplayAssignment],
        autoApplyOnConnect: Bool = false
    ) throws -> WallpaperDisplayLayout {
        let value = WallpaperDisplayLayout(
            name: try WallpaperCollectionStore.validatedName(name),
            assignments: assignments,
            autoApplyOnConnect: autoApplyOnConnect)
        var updated = layouts
        if autoApplyOnConnect {
            let topology = value.normalizedDisplayTopology()
            for index in updated.indices where updated[index].normalizedDisplayTopology() == topology {
                updated[index].autoApplyOnConnect = false
            }
        }
        updated.append(value)
        try commit(updated)
        return value
    }

    /// Sets whether `id` applies automatically when its normalized display topology connects.
    /// At most one layout per normalized topology stays enabled: enabling `id` clears any sibling
    /// layout sharing the same normalized display set.
    func setAutoApplyOnConnect(_ enabled: Bool, for id: String) throws {
        let target = try layout(id)
        let topology = target.normalizedDisplayTopology()
        let updated = layouts.map { item -> WallpaperDisplayLayout in
            var copy = item
            if copy.id == id {
                copy.autoApplyOnConnect = enabled
            } else if enabled && copy.normalizedDisplayTopology() == topology {
                copy.autoApplyOnConnect = false
            }
            return copy
        }
        try commit(updated)
    }

    /// The saved layout opted into automatic application for the given connected display IDs, or nil.
    func autoApplyLayout(for displayIDs: some Sequence<String>) -> WallpaperDisplayLayout? {
        let topology = WallpaperDisplayLayout.normalizedDisplayTopology(for: displayIDs)
        guard !topology.isEmpty else { return nil }
        return layouts.first { $0.autoApplyOnConnect && $0.normalizedDisplayTopology() == topology }
    }

    func rename(_ id: String, name: String) throws {
        _ = try layout(id)
        let name = try WallpaperCollectionStore.validatedName(name)
        try commit(layouts.map { var copy = $0; if copy.id == id { copy.name = name }; return copy })
    }

    func delete(_ id: String) throws {
        _ = try layout(id)
        try commit(layouts.filter { $0.id != id })
    }

    // Keep removed wallpapers as unavailable references so restoring never silently applies
    // only half a saved arrangement. The user may delete the layout or reinstall its content.
    nonisolated static func decode(_ data: Data) throws -> [WallpaperDisplayLayout] {
        guard data.count <= 2 * 1024 * 1024 else { throw WallpaperDisplayLayoutError.invalidLayout }
        var values = try JSONDecoder().decode([WallpaperDisplayLayout].self, from: data)
        guard values.count <= limit, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ value in
                  validText(value.id, limit: 128) && validText(value.name, limit: 128)
                    && value.name == value.name.trimmingCharacters(in: .whitespacesAndNewlines)
              }) else { throw WallpaperDisplayLayoutError.invalidLayout }
        for value in values { try validateAssignments(value.assignments) }
        // At most one saved layout per normalized topology stays opted into auto-apply (for example
        // after merging backups with `.keepExisting`); keep the first to match `autoApplyLayout(for:)`.
        var seenAutoTopologies = Set<[String]>()
        for index in values.indices where values[index].autoApplyOnConnect {
            let topology = values[index].normalizedDisplayTopology()
            if !seenAutoTopologies.insert(topology).inserted {
                values[index].autoApplyOnConnect = false
            }
        }
        return values
    }

    nonisolated static func validateAssignments(_ values: [WallpaperDisplayAssignment]) throws {
        guard !values.isEmpty, values.count <= 64, Set(values.map(\.displayID)).count == values.count,
              values.allSatisfy({ validText($0.displayID, limit: 2048)
                  && validText($0.displayTitle, limit: 2048) && validText($0.wallpaperID, limit: 1024) }) else {
            throw WallpaperDisplayLayoutError.invalidLayout
        }
    }

    nonisolated private static func validText(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }

    private func commit(_ values: [WallpaperDisplayLayout]) throws {
        let data = try JSONEncoder().encode(values)
        _ = try Self.decode(data)
        guard values != layouts else { return }
        defaults.set(data, forKey: Self.storageKey)
        layouts = values
        loadError = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

enum WallpaperDisplayLayoutError: LocalizedError {
    case invalidLayout, missingLayout, noWallpapers, sameDisplay, changed, pendingEdits, noEligibleDisplays
    case unavailableDisplay(String), unavailableWallpaper(String)
    case restored(String), incomplete(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidLayout: String(localized: "This display layout is invalid or exceeds the limit of 64 layouts and 64 displays per layout.")
        case .missingLayout: String(localized: "This display layout no longer exists. Choose another layout.")
        case .noWallpapers: String(localized: "Apply a wallpaper to an enabled independent display before saving or copying a layout.")
        case .sameDisplay: String(localized: "Choose two different independent displays.")
        case .changed: String(localized: "The display assignments changed. Review the displays and try again.")
        case .pendingEdits: String(localized: "Apply or revert wallpaper edits before changing a display layout.")
        case .noEligibleDisplays: String(localized: "Enable at least one independent display before applying a wallpaper to all displays.")
        case .unavailableDisplay(let title): String(localized: "The display “\(title)” is disconnected, disabled or mirrored. Connect and enable it as an independent display.")
        case .unavailableWallpaper(let id): String(localized: "The wallpaper “\(id)” is unavailable. Restore it to the library before applying this layout.")
        case .restored(let reason): String(localized: "The layout could not be applied. Previous wallpapers were restored. \(reason)")
        case .incomplete(let displays, let reason): String(localized: "The layout could not be completed or fully restored on: \(displays). Review these displays before retrying. \(reason)")
        }
    }
}
