import Foundation

/// A folder of the user's own wallpapers that the library follows: files added to it are imported,
/// and with `mirrorsDeletions` files deleted from it leave the library (docs/features/linked-folders.md).
///
/// Local to this Mac: never part of a backup or a sync folder snapshot, since paths and bookmarks
/// differ between Macs.
struct LinkedFolder: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var path: String
    /// A plain bookmark, not a security-scoped one: the app is not sandboxed. It finds the folder
    /// again after it is renamed or moved on its disk.
    var bookmark: Data?
    /// Off by default: a file deleted from the folder leaves its wallpaper in the library.
    var mirrorsDeletions: Bool
    var record: LinkedFolderRecord

    init(id: UUID = UUID(), path: String, bookmark: Data? = nil, mirrorsDeletions: Bool = false,
         record: LinkedFolderRecord = LinkedFolderRecord()) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.mirrorsDeletions = mirrorsDeletions
        self.record = record
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// What one link knows about its folder: which library item each file became, and what it saw of
/// the files it has not imported yet.
struct LinkedFolderRecord: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case present
            /// The file left the folder while Mirror deletions was off, or the user chose to keep
            /// its wallpaper: the wallpaper stays and is never removed for it later.
            case missing
        }

        /// The file's name inside the folder.
        var path: String
        var libraryID: String
        var stamp: LinkedFolderStamp
        /// The file system's id of the file (`URLResourceKey.fileIdentifierKey`), which a rename
        /// keeps: a renamed file keeps its wallpaper, favorites and playlist entries.
        var fileID: UInt64?
        /// True when this link put the item in the library. An item that was already there (a
        /// Workshop item, a hand import of the same name, another link's) is never replaced or
        /// removed for this folder.
        var owned: Bool
        var state: State = .present
    }

    var entries: [Entry] = []
    /// What the last check saw of files waiting to be imported. One is imported once two checks
    /// in a row see the same size and modification date, so a file still being copied is not.
    var pending: [String: LinkedFolderStamp] = [:]
    /// Files whose last import failed, as they were then: not tried again until they change.
    var failed: [String: LinkedFolderStamp] = [:]
    /// Library items whose files left the folder and are due to be removed from the library.
    var pendingRemovals: [String] = []
}

/// A file's size and modification time, enough to tell that it changed or is still being written.
struct LinkedFolderStamp: Codable, Equatable, Sendable {
    var size: Int64
    /// Milliseconds since 1970, so a stamp read back from disk compares equal to a fresh one.
    var modified: Int64

    init(size: Int64, modified: Int64) {
        self.size = size
        self.modified = modified
    }

    init(size: Int64, modified date: Date) {
        self.init(size: size, modified: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

/// What a look at a linked folder found.
enum LinkedFolderScan: Equatable, Sendable {
    /// The folder is missing, unreadable, in the Trash or on a disk that is not connected:
    /// nothing may be concluded from it, and nothing is removed.
    case unavailable
    case contents(Contents)

    struct Contents: Equatable, Sendable {
        /// Where the folder is now, which a bookmark may have followed to a new name.
        var folder: URL
        var items: [Item]
        /// Names of files iCloud Drive evicted to a `.name.icloud` placeholder: still in the folder.
        var evicted: Set<String> = []
    }

    /// A file the library can import, or a Wallpaper Engine project folder.
    struct Item: Equatable, Sendable {
        var path: String
        /// The library id an import gives it (`WallpaperImportService.libraryID(forSourceNamed:isDirectory:)`).
        var libraryID: String
        var stamp: LinkedFolderStamp
        var fileID: UInt64?
    }
}
