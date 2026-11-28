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

        var items: [LinkedFolderScan.Item] = []
        var present = Set<String>()
        for name in names.sorted() {
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
                    present.insert(String(name.dropFirst().dropLast(".icloud".count)))
                }
                continue
            }
            // Listed is present, whatever reading it says: a file or project that cannot be read
            // is never taken for deleted.
            present.insert(name)
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let isFolder = values.isDirectory == true
            guard isFolder || values.isRegularFile == true,
                  WallpaperImportService.libraryID(forSourceNamed: name, isDirectory: isFolder) != nil
            else { continue }
            let stamp: LinkedFolderStamp
            if isFolder {
                guard let projectStamp = Self.projectStamp(url) else { continue }
                stamp = projectStamp
            } else {
                stamp = LinkedFolderStamp(size: Int64(values.fileSize ?? 0),
                                          modified: values.contentModificationDate ?? .distantPast)
            }
            // A project copied from the Workshop under another name is filed under its item's id.
            guard let libraryID = WallpaperImportService.libraryID(forSourceAt: url, isDirectory: isFolder) else { continue }
            items.append(.init(path: name, libraryID: libraryID, stamp: stamp, fileID: values.fileIdentifier))
        }
        let contents = LinkedFolderScan.Contents(folder: folder, items: items, alsoPresent: present)
        return .contents(contents)
    }

    /// A Wallpaper Engine project folder's total size and newest modification date, which change
    /// whenever any of its files does, and a digest of every file's relative path, size, date and
    /// file id, which changes when two files swap names. Nil for a folder that is not a project.
    static func projectStamp(_ folder: URL) -> LinkedFolderStamp? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileIdentifierKey]
        let manifest = folder.appendingPathComponent("project.json")
        guard (try? manifest.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        else { return nil }
        var size: Int64 = 0
        var newest = Date.distantPast
        var lines: [String] = []
        let base = folder.standardizedFileURL.path.count + 1
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            size += bytes
            if modified > newest { newest = modified }
            let relative = String(file.standardizedFileURL.path.dropFirst(base))
            lines.append("\(relative)\u{0}\(bytes)\u{0}\(LinkedFolderStamp.milliseconds(modified))\u{0}\(values.fileIdentifier ?? 0)")
        }
        // FNV-1a over the sorted lines: stable across launches, unlike `Hasher`.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in lines.sorted().joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return LinkedFolderStamp(size: size, modified: newest, fingerprint: String(hash, radix: 16))
    }
}
