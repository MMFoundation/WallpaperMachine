import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stores user-chosen static image stickers for `.image` desktop widgets inside the app's managed
/// `UserAssets/` tree (`UserAssets/DesktopWidgets/stickers/<assetID>/<fileName>`), using
/// `ManagedUserAssetStore` so copies are APFS-cloned, SHA-256 deduplicated, preserved across
/// `.wmbackup` backups/restores, protected from cache purges while referenced, and reclaimed once
/// no widget or undo snapshot references them.
final class DesktopWidgetImageStore: @unchecked Sendable {
    static let shared = DesktopWidgetImageStore()

    nonisolated static let wallpaperID = "DesktopWidgets"
    nonisolated static let propertyID = "stickers"
    /// Supported sticker image formats (PNG, JPEG, WebP, HEIC).
    nonisolated static let acceptedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]
    /// Maximum file size accepted for a desktop sticker image (50 MiB).
    nonisolated static let maximumFileBytes: Int64 = 50 * 1024 * 1024
    /// Maximum decoded pixel dimension cached in memory for drawing.
    nonisolated static let defaultMaxPixelSize = 1024
    /// Bounded cache matching `DesktopWidgetStore.limit`, preventing unbounded memory growth.
    nonisolated static let cacheLimit = DesktopWidgetStore.limit

    nonisolated static var allowedContentTypes: [UTType] {
        [UTType.png, UTType.jpeg, UTType.webP, UTType.heic]
    }

    private struct CacheKey: Hashable {
        var rootPath: String
        var assetID: String
        var fileName: String
        var maxPixelSize: Int
    }

    private let explicitManaged: ManagedUserAssetStore?
    private let fileManager: FileManager
    private let cacheLock = NSLock()
    private var imageCache: [(key: CacheKey, image: CGImage)] = []

    /// When `managed` is nil, resolves `ClientPaths.userAssetsURL` dynamically so tests that
    /// override `WALLPAPER_MACHINE_HOME` always stay isolated from one another.
    init(managed: ManagedUserAssetStore? = nil, fileManager: FileManager = .default) {
        self.explicitManaged = managed
        self.fileManager = fileManager
    }

    private var managed: ManagedUserAssetStore {
        explicitManaged ?? ManagedUserAssetStore(root: ClientPaths.userAssetsURL, fileManager: fileManager)
    }

    /// Validates `sourceURL` as a supported static image and imports an independent copy into
    /// `ManagedUserAssetStore`, returning the portable `DesktopWidget.ImageAsset` reference.
    func importImage(from sourceURL: URL) throws -> DesktopWidget.ImageAsset {
        let standardized = sourceURL.standardizedFileURL
        let ext = standardized.pathExtension.lowercased()
        guard Self.acceptedExtensions.contains(ext) else {
            throw DesktopWidgetImageError.unsupportedFormat
        }
        guard fileManager.fileExists(atPath: standardized.path) else {
            throw DesktopWidgetImageError.unreadableImage
        }
        let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw DesktopWidgetImageError.unreadableImage
        }
        let fileSize = Int64(values?.fileSize ?? 0)
        guard fileSize > 0, fileSize <= Self.maximumFileBytes else {
            throw DesktopWidgetImageError.fileTooLarge
        }
        guard Self.canDecodeImage(at: standardized) else {
            throw DesktopWidgetImageError.unreadableImage
        }

        let safeFileName = "sticker.\(ext)"
        let displayName = Self.sanitizedDisplayName(standardized.lastPathComponent, fallback: safeFileName)
        let adopted = try managed.adopt(
            readingFrom: standardized,
            fileName: safeFileName,
            sourcePath: standardized.path,
            wallpaperId: Self.wallpaperID,
            propertyId: Self.propertyID,
            known: nil)

        try managed.withManifestTransaction {
            var manifest = try managed.manifest(wallpaperId: Self.wallpaperID)
            var property = manifest.properties[Self.propertyID]
                ?? ManagedUserAssetProperty(kind: .directory, sourcePath: standardized.path)
            property.sourcePath = standardized.path
            property.assets.removeAll { $0.assetId == adopted.assetId && $0.fileName == adopted.fileName }
            property.assets.append(adopted)
            property.assets.sort { ($0.assetId, $0.fileName) < ($1.assetId, $1.fileName) }
            manifest.properties[Self.propertyID] = property
            try managed.write(manifest)
        }

        return DesktopWidget.ImageAsset(
            assetID: adopted.assetId,
            fileName: adopted.fileName,
            displayName: displayName)
    }

    /// Resolves the managed file URL for `asset`, or nil if invalid or missing on disk.
    func url(for asset: DesktopWidget.ImageAsset) -> URL? {
        guard asset.isValid else { return nil }
        guard let directory = try? managed.propertyRoot(wallpaperId: Self.wallpaperID, propertyId: Self.propertyID)
        else { return nil }
        let fileURL = directory
            .appendingPathComponent(asset.assetID, isDirectory: true)
            .appendingPathComponent(asset.fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    /// Loads and downscales `asset` for static rendering, reusing a bounded LRU cache so redraws
    /// never re-decode unchanged stickers.
    func loadImage(for asset: DesktopWidget.ImageAsset, maxPixelSize: Int = defaultMaxPixelSize) -> CGImage? {
        guard asset.isValid else { return nil }
        let store = managed
        let clampedPixels = max(maxPixelSize, 64)
        let key = CacheKey(
            rootPath: store.root.path, assetID: asset.assetID, fileName: asset.fileName,
            maxPixelSize: clampedPixels)
        cacheLock.lock()
        if let index = imageCache.firstIndex(where: { $0.key == key }) {
            let entry = imageCache.remove(at: index)
            imageCache.insert(entry, at: 0)
            cacheLock.unlock()
            return entry.image
        }
        cacheLock.unlock()

        guard let fileURL = url(for: asset),
              let decoded = Self.decodeImage(at: fileURL, maxPixelSize: clampedPixels)
        else { return nil }

        cacheLock.lock()
        imageCache.removeAll { $0.key == key }
        imageCache.insert((key: key, image: decoded), at: 0)
        if imageCache.count > Self.cacheLimit {
            imageCache.removeLast(imageCache.count - Self.cacheLimit)
        }
        cacheLock.unlock()
        return decoded
    }

    /// Removes stored sticker images whose `assetID` is not in `liveAssetIDs` from both the
    /// manifest and disk. Callers pass the union of saved widgets (including hidden ones) and any
    /// active Undo/Redo history snapshots so undo never loses a deleted sticker.
    func pruneUnused(keeping liveAssetIDs: Set<String>) {
        let store = managed
        var shouldRemoveProperty = false
        var shouldPruneUnlisted = false
        store.withManifestTransaction {
            guard var manifest = try? store.manifest(wallpaperId: Self.wallpaperID),
                  var property = manifest.properties[Self.propertyID]
            else { return }
            let retained = property.assets.filter { liveAssetIDs.contains($0.assetId) }
            guard retained != property.assets else {
                shouldPruneUnlisted = !retained.isEmpty
                return
            }
            if retained.isEmpty {
                manifest.properties[Self.propertyID] = nil
                try? store.write(manifest)
                shouldRemoveProperty = true
            } else {
                property.assets = retained
                manifest.properties[Self.propertyID] = property
                try? store.write(manifest)
                shouldPruneUnlisted = true
            }
        }
        if shouldRemoveProperty {
            store.removeProperty(wallpaperId: Self.wallpaperID, propertyId: Self.propertyID)
            removeEmptyWallpaperRootIfNeeded(in: store)
        } else if shouldPruneUnlisted {
            store.pruneUnlisted(wallpaperId: Self.wallpaperID, propertyId: Self.propertyID)
        }
        let rootPath = store.root.path
        cacheLock.lock()
        imageCache.removeAll { $0.key.rootPath == rootPath && !liveAssetIDs.contains($0.key.assetID) }
        cacheLock.unlock()
    }

    /// Drops the in-memory decoded image cache (useful in tests or low-memory cleanup).
    func clearCache() {
        cacheLock.lock()
        imageCache.removeAll()
        cacheLock.unlock()
    }

    private func removeEmptyWallpaperRootIfNeeded(in store: ManagedUserAssetStore) {
        store.withManifestTransaction {
            guard let manifest = try? store.manifest(wallpaperId: Self.wallpaperID),
                  manifest.properties.isEmpty,
                  let root = try? store.wallpaperRoot(Self.wallpaperID)
            else { return }
            try? fileManager.removeItem(at: root)
        }
    }

    private static func canDecodeImage(at url: URL) -> Bool {
        decodeImage(at: url, maxPixelSize: 64) != nil
    }

    private static func decodeImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0
        else { return nil }
        return image
    }

    private static func sanitizedDisplayName(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(256))
    }
}

enum DesktopWidgetImageError: LocalizedError, Equatable {
    case unsupportedFormat
    case unreadableImage
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            String(localized: "Choose a PNG, JPEG, WebP or HEIC image.")
        case .unreadableImage:
            String(localized: "This image could not be read.")
        case .fileTooLarge:
            String(localized: "This image is too large for a desktop widget. Choose one smaller than 50 MB.")
        }
    }
}
