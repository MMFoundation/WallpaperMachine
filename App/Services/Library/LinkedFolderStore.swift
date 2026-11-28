import Foundation

protocol LinkedFolderStoring: Sendable {
    var file: URL { get }
    func load() throws -> [LinkedFolder]
    func save(_ folders: [LinkedFolder]) async throws
}

/// Keeps the linked folders and their records in `LinkedFolders.json` in the app-support folder.
struct LinkedFolderStore: LinkedFolderStoring {
    private struct File: Codable {
        var version = 1
        var folders: [LinkedFolder]
    }

    let file: URL

    init(file: URL = ClientPaths.linkedFoldersURL) {
        self.file = file
    }

    /// The saved links; none when nothing was saved yet. A file that is there but cannot be read
    /// throws, and the coordinator then saves nothing over it. One that reads but does not decode
    /// is set aside as `LinkedFolders.unreadable.json`, so the links it held can still be recovered.
    func load() throws -> [LinkedFolder] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        do {
            return try JSONDecoder().decode(File.self, from: data).folders
        } catch {
            AppLog.warn("linked folders: \(file.lastPathComponent) could not be read (\(error.localizedDescription)); starting without links")
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: file, to: aside)
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
