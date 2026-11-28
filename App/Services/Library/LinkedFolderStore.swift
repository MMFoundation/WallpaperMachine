import Foundation

/// Keeps the linked folders and their records in `LinkedFolders.json` in the app-support folder.
struct LinkedFolderStore: Sendable {
    private struct File: Codable {
        var version = 1
        var folders: [LinkedFolder]
    }

    let file: URL

    init(file: URL = ClientPaths.linkedFoldersURL) {
        self.file = file
    }

    /// The saved links; none when nothing was saved yet. A file that cannot be read is set aside
    /// rather than overwritten by the next save, so the links it held can still be recovered.
    func load() -> [LinkedFolder] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try JSONDecoder().decode(File.self, from: data).folders
        } catch {
            AppLog.warn("linked folders: \(file.lastPathComponent) could not be read (\(error.localizedDescription)); starting without links")
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
    }

    func save(_ folders: [LinkedFolder]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(folders: folders)).write(to: file, options: .atomic)
    }
}
