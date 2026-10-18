import Foundation

enum WallpaperDeletionService {
    static func wallpaperURL(id: String, library: URL) throws -> URL {
        // CLEANROOM A21: implement from specs/app/a1-app-remnants.md
        fatalError("CLEANROOM A21")
    }

    static func moveToTrash(id: String, library: URL,
                            recycle: (URL) throws -> Void = { url in
                                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                            }) throws {
        try recycle(wallpaperURL(id: id, library: library))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WallpaperMachine.Deletion", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Outcome of a batch deletion; ids keep the order they were requested in.
struct WallpaperDeletionReport {
    var deleted: [String] = []
    var failures: [(id: String, error: Error)] = []
}
