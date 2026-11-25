import Foundation

/// Lightweight on-demand cache of manifest tags for Smart Dynamic Playlists.
///
/// `LibraryMetricsService` only runs when the Control Panel is open and walks full wallpaper
/// folders to compute disk sizes and video resolutions. When the app launches at login (menu bar
/// only) and a Smart Playlist needs manifest tags or Mature content-rating checks, this reads
/// only `project.json` off the main actor, cached by each manifest's modification timestamp.
@MainActor
final class SmartPlaylistManifestCache {
    struct Entry: Equatable, Sendable {
        var stamp: Date?
        var tags: [String]
    }

    private let libraryURL: URL
    private var entries: [String: Entry] = [:]

    init(libraryURL: URL = ClientPaths.libraryURL) {
        self.libraryURL = libraryURL
    }

    /// Cached manifest tags already loaded in memory. Performs no disk I/O.
    func cachedTags(for id: String) -> [String]? {
        entries[id]?.tags
    }

    /// True if any id in `ids` has not yet been read into the cache.
    func hasMissing(in ids: [String]) -> Bool {
        ids.contains { entries[$0] == nil }
    }

    /// Reads or refreshes `project.json` tags off the main actor for `ids`, skipping manifests
    /// whose modification date has not changed.
    func refresh(ids: [String]) async {
        let wanted = Set(ids)
        for key in entries.keys where !wanted.contains(key) {
            entries[key] = nil
        }
        let known = entries
        let root = libraryURL
        let updated = await Task.detached(priority: .utility) { () -> [String: Entry] in
            var result: [String: Entry] = [:]
            for id in ids {
                guard !Task.isCancelled else { break }
                let manifest = root.appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent("project.json")
                let stamp = LibraryMetricsService.stamp(of: manifest)
                if let existing = known[id], existing.stamp == stamp {
                    result[id] = existing
                    continue
                }
                let project = LibraryResolution.readObject(manifest) ?? [:]
                let approved = LibraryMetricsService.approved(project: project)
                let tags = LibraryMetricsService.tags(project: project, approved: approved)
                result[id] = Entry(stamp: stamp, tags: tags)
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        for (id, entry) in updated where wanted.contains(id) {
            entries[id] = entry
        }
    }
}
