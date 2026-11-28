import Foundation

/// Looks at a linked folder. A seam so the coordinator's tests need no disk.
protocol LinkedFolderScanning: Sendable {
    func scan(_ folder: LinkedFolder) async -> LinkedFolderScan
}

/// Reads a linked folder's top level: every file the library can import and every Wallpaper Engine
/// project folder in it, with their size, modification date and file id. Reads metadata only.
struct LinkedFolderScanner: LinkedFolderScanning {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .fileIdentifierKey,
    ]

    func scan(_ folder: LinkedFolder) async -> LinkedFolderScan {
        Self.scanNow(at: Self.resolve(folder))
    }

    /// Where the folder is now. The bookmark follows a rename or a move on its disk; it is
    /// resolved without mounting anything or asking anything.
    static func resolve(_ folder: LinkedFolder) -> URL {
        guard let bookmark = folder.bookmark else { return folder.url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return folder.url }
        return url.standardizedFileURL
    }

    static func scanNow(at folder: URL) -> LinkedFolderScan {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        // A folder moved to the Trash is on its way out, not a folder whose files were deleted.
        guard !folder.pathComponents.contains(".Trash"),
              files.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              files.isReadableFile(atPath: folder.path),
              let names = try? files.contentsOfDirectory(atPath: folder.path) else { return .unavailable }

        var contents = LinkedFolderScan.Contents(folder: folder, items: [])
        for name in names.sorted() {
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
                    contents.evicted.insert(String(name.dropFirst().dropLast(".icloud".count)))
                }
                continue
            }
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let isFolder = values.isDirectory == true
            guard isFolder || values.isRegularFile == true,
                  let libraryID = WallpaperImportService.libraryID(forSourceNamed: name, isDirectory: isFolder)
            else { continue }
            let stamp: LinkedFolderStamp
            if isFolder {
                guard let projectStamp = Self.projectStamp(url) else { continue }
                stamp = projectStamp
            } else {
                stamp = LinkedFolderStamp(size: Int64(values.fileSize ?? 0),
                                          modified: values.contentModificationDate ?? .distantPast)
            }
            contents.items.append(.init(path: name, libraryID: libraryID, stamp: stamp, fileID: values.fileIdentifier))
        }
        return .contents(contents)
    }

    /// A Wallpaper Engine project folder's total size and newest modification date, which change
    /// whenever any of its files does. Nil for a folder that is not a project.
    private static func projectStamp(_ folder: URL) -> LinkedFolderStamp? {
        let manifest = folder.appendingPathComponent("project.json")
        guard (try? manifest.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        else { return nil }
        var size: Int64 = 0
        var newest = Date.distantPast
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            size += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate, modified > newest { newest = modified }
        }
        return LinkedFolderStamp(size: size, modified: newest)
    }
}
