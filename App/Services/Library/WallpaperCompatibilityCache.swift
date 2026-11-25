import CryptoKit
import Foundation
import Observation

/// Codable snapshot of a `VideoFileStamp` used to invalidate cached video compatibility verdicts
/// whenever the underlying video file is replaced or modified.
struct CachedVideoFileStamp: Codable, Equatable, Sendable {
    let size: Int
    let modifiedTimeInterval: Double?
    let identity: String

    init(size: Int, modifiedTimeInterval: Double?, identity: String) {
        self.size = size
        self.modifiedTimeInterval = modifiedTimeInterval
        self.identity = identity
    }

    init(_ stamp: VideoFileStamp) {
        self.size = stamp.size
        self.modifiedTimeInterval = stamp.modified?.timeIntervalSinceReferenceDate
        self.identity = stamp.identity
    }
}

/// Lightweight persisted compatibility verdict produced asynchronously after download or import
/// completes (or recorded when the user runs a manual Compatibility check).
///
/// Keyed by wallpaper ID and invalidated whenever the app build/version, shared scene assets
/// stamp, project directory fingerprint, or video entry file stamp changes.
struct WallpaperCompatibilitySummary: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case ok
        case warning
        case unavailable
        case unknown

        var checkStatus: WallpaperCompatibilityCheck.Status {
            switch self {
            case .ok: .ok
            case .warning: .warning
            case .unavailable: .unavailable
            case .unknown: .unknown
            }
        }
    }

    var status: Status
    /// Concise explanation for warning/unavailable/unknown verdicts; empty when OK.
    var detail: String
    /// App version/build stamp (`SceneDrawVerdicts.currentBuild`).
    var appVersion: String
    /// Shared scene assets stamp (resolved path + marker file stamps); empty for non-scenes.
    var assetsStamp: String
    /// Project directory SHA-256 fingerprint (`WallpaperProjectRevision`).
    var projectFingerprint: String
    /// Video entry file stamp (`VideoFileStamp`); nil for non-videos or missing entry.
    var videoStamp: CachedVideoFileStamp?
    var recorded: Date

    /// Reduces a full check list to a single intrinsic wallpaper verdict.
    ///
    /// Display-specific (`target`) and always-caution (`lockScreen`) rows are excluded so the
    /// badge reflects the wallpaper's own files, codec, and scene compatibility.
    static func summarize(_ checks: [WallpaperCompatibilityCheck]) -> (status: Status, detail: String) {
        let intrinsic = checks.filter { $0.id != "target" && $0.id != "lockScreen" }
        guard !intrinsic.isEmpty else { return (.unknown, "") }
        if let first = intrinsic.first(where: { $0.status == .unavailable }) {
            return (.unavailable, first.detail)
        }
        if let first = intrinsic.first(where: { $0.status == .warning }) {
            return (.warning, first.detail)
        }
        if let first = intrinsic.first(where: { $0.status == .unknown }) {
            return (.unknown, first.detail)
        }
        return (.ok, "")
    }
}

/// Persisted compatibility pre-check cache stored under `Cache/CompatibilityCache.json`.
///
/// Never runs before download (Steam Discover metadata lacks codec information): callers trigger
/// `precheck(...)` asynchronously after a download or import lands in the library.
actor WallpaperCompatibilityCache {
    static let entryLimit = 2_000

    private static let sharedAssetMarkers = [
        "shaders/genericimage2.vert",
        "shaders/genericimage2.frag",
        "materials/util/effectpassthrough.json",
    ]

    struct InvalidationStamp: Equatable, Sendable {
        let appVersion: String
        let assetsStamp: String
        let projectFingerprint: String
        let videoStamp: CachedVideoFileStamp?
    }

    private let file: URL
    private let library: @Sendable () -> URL
    private let assetsURL: @Sendable () -> URL
    private let appVersion: @Sendable () -> String
    private let service: WallpaperCompatibilityService
    private var entries: [String: WallpaperCompatibilitySummary] = [:]
    private var loadedFromDisk = false

    init(
        file: URL = ClientPaths.compatibilityCacheURL,
        library: @escaping @Sendable () -> URL = { ClientPaths.libraryURL },
        assetsURL: @escaping @Sendable () -> URL = { ClientPaths.assetsURL },
        appVersion: @escaping @Sendable () -> String = { SceneDrawVerdicts.currentBuild },
        service: WallpaperCompatibilityService? = nil
    ) {
        self.file = file
        self.library = library
        self.assetsURL = assetsURL
        self.appVersion = appVersion
        self.service = service ?? WallpaperCompatibilityService(
            libraryURL: library(),
            assetsURL: assetsURL
        )
    }

    /// Loads persisted cache entries lazily on the actor so initializing the cache during app
    /// launch performs zero synchronous disk I/O on the main actor.
    private func loadIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        do {
            entries = FileManager.default.fileExists(atPath: file.path)
                ? try JSONDecoder().decode([String: WallpaperCompatibilitySummary].self, from: Data(contentsOf: file))
                : [:]
        } catch {
            AppLog.warn("Compatibility cache could not be read and starts empty: \(error.localizedDescription)")
            entries = [:]
        }
    }

    /// Returns all currently loaded entries matching the running app version.
    func snapshotForCurrentAppVersion() -> [String: WallpaperCompatibilitySummary] {
        loadIfNeeded()
        let version = appVersion()
        return entries.filter { $0.value.appVersion == version }
    }

    /// Returns the cached summary for `wallpaperID` if and only if app version, shared assets
    /// stamp, project fingerprint, and (for videos) entry file stamp still match. Stale entries
    /// are pruned on miss.
    func cachedSummary(
        for wallpaperID: String,
        kind: WallpaperCompatibilityContext.Kind,
        libraryRevision: UInt64 = 0
    ) async -> WallpaperCompatibilitySummary? {
        loadIfNeeded()
        guard let existing = entries[wallpaperID] else { return nil }
        let version = appVersion()
        guard existing.appVersion == version else {
            entries.removeValue(forKey: wallpaperID)
            persist()
            return nil
        }
        guard let current = await computeStamp(for: wallpaperID, kind: kind, libraryRevision: libraryRevision) else {
            entries.removeValue(forKey: wallpaperID)
            persist()
            return nil
        }
        guard existing.assetsStamp == current.assetsStamp,
              existing.projectFingerprint == current.projectFingerprint,
              existing.videoStamp == current.videoStamp
        else {
            entries.removeValue(forKey: wallpaperID)
            persist()
            return nil
        }
        return existing
    }

    /// Runs a lightweight post-download/post-import pre-check for `wallpaperID` unless a valid
    /// cached verdict already exists for its current stamp.
    func precheck(
        wallpaperID: String,
        kind: WallpaperCompatibilityContext.Kind,
        supported: Bool,
        libraryRevision: UInt64 = 0
    ) async -> WallpaperCompatibilitySummary? {
        if let hit = await cachedSummary(for: wallpaperID, kind: kind, libraryRevision: libraryRevision) {
            return hit
        }
        let context = WallpaperCompatibilityContext(
            wallpaperID: wallpaperID,
            displayID: "precheck",
            kind: kind,
            supported: supported,
            targetFPS: 60,
            targetAvailable: true,
            libraryRevision: libraryRevision,
            assetsConfiguration: assetsURL().path
        )
        let checks = await service.check(context, retry: true)
        return await record(
            wallpaperID: wallpaperID,
            kind: kind,
            checks: checks,
            libraryRevision: libraryRevision
        )
    }

    /// Stores the summarized verdict of a check against the wallpaper's current invalidation stamp.
    @discardableResult
    func record(
        wallpaperID: String,
        kind: WallpaperCompatibilityContext.Kind,
        checks: [WallpaperCompatibilityCheck],
        libraryRevision: UInt64 = 0
    ) async -> WallpaperCompatibilitySummary? {
        guard let stamp = await computeStamp(for: wallpaperID, kind: kind, libraryRevision: libraryRevision) else {
            return nil
        }
        let summarized = WallpaperCompatibilitySummary.summarize(checks)
        let summary = WallpaperCompatibilitySummary(
            status: summarized.status,
            detail: summarized.detail,
            appVersion: stamp.appVersion,
            assetsStamp: stamp.assetsStamp,
            projectFingerprint: stamp.projectFingerprint,
            videoStamp: stamp.videoStamp,
            recorded: Date()
        )
        loadIfNeeded()
        entries[wallpaperID] = summary
        trimIfNeeded()
        persist()
        return summary
    }

    /// Drops the cached verdict for `wallpaperID`.
    func invalidate(wallpaperID: String) {
        loadIfNeeded()
        guard entries.removeValue(forKey: wallpaperID) != nil else { return }
        persist()
    }

    /// Computes the current invalidation stamp for an installed wallpaper.
    func computeStamp(
        for wallpaperID: String,
        kind: WallpaperCompatibilityContext.Kind,
        libraryRevision: UInt64 = 0
    ) async -> InvalidationStamp? {
        guard Self.validID(wallpaperID) else { return nil }
        let libraryRoot = library().resolvingSymlinksInPath().standardizedFileURL
        let root = libraryRoot.appendingPathComponent(wallpaperID, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(libraryRoot.path + "/") else { return nil }
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        let projectRevision = WallpaperProjectRevision()
        guard let fingerprint = try? await projectRevision.fingerprint(root, revision: libraryRevision) else {
            return nil
        }
        let assetsStamp = kind == .scene ? computeAssetsStamp() : ""
        let videoStamp = kind == .video ? computeVideoStamp(in: root) : nil
        return InvalidationStamp(
            appVersion: appVersion(),
            assetsStamp: assetsStamp,
            projectFingerprint: fingerprint,
            videoStamp: videoStamp
        )
    }

    private func computeAssetsStamp() -> String {
        let shared = assetsURL().resolvingSymlinksInPath().standardizedFileURL
        var parts = [shared.path]
        for marker in Self.sharedAssetMarkers {
            let url = shared.appendingPathComponent(marker)
            if let stamp = try? VideoFileStamp(url: url) {
                let mtime = stamp.modified?.timeIntervalSinceReferenceDate ?? 0
                parts.append("\(marker):\(stamp.size):\(mtime):\(stamp.identity)")
            } else {
                parts.append("\(marker):missing")
            }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func computeVideoStamp(in root: URL) -> CachedVideoFileStamp? {
        let manifest = root.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["file"] as? String, !entry.isEmpty,
              !entry.hasPrefix("/"), !entry.contains("\0")
        else { return nil }
        let file = root.appendingPathComponent(entry).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        guard let stamp = try? VideoFileStamp(url: file) else { return nil }
        return CachedVideoFileStamp(stamp)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".."
            && !id.contains("/") && !id.contains("\\") && !id.contains("\0")
    }

    private func trimIfNeeded() {
        guard entries.count > Self.entryLimit else { return }
        let dropCount = entries.count - Self.entryLimit
        let oldest = entries.sorted { $0.value.recorded < $1.value.recorded }.prefix(dropCount)
        for (id, _) in oldest {
            entries.removeValue(forKey: id)
        }
    }

    private func persist() {
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: file, options: .atomic)
        } catch {
            AppLog.warn("Compatibility cache could not be saved: \(error.localizedDescription)")
        }
    }
}

/// Main-actor observable mirror and low-priority background pre-check scheduler over
/// `WallpaperCompatibilityCache`.
///
/// SwiftUI views read `summaries[wallpaperID]` purely from memory with zero disk I/O in `body`.
/// Background pre-checks run one at a time at `.utility` priority after downloads and imports.
@MainActor
@Observable
final class WallpaperCompatibilityCacheStore {
    private(set) var summaries: [String: WallpaperCompatibilitySummary] = [:]

    @ObservationIgnored let cache: WallpaperCompatibilityCache
    @ObservationIgnored private var pendingQueue: [(id: String, kind: WallpaperCompatibilityContext.Kind, supported: Bool, revision: UInt64)] = []
    @ObservationIgnored private var pendingIDs: Set<String> = []
    @ObservationIgnored private var workerTask: Task<Void, Never>?

    init(cache: WallpaperCompatibilityCache = WallpaperCompatibilityCache()) {
        self.cache = cache
    }

    /// Hydrates the in-memory summary map once from disk asynchronously.
    func loadCachedSummaries() {
        Task.detached(priority: .utility) { [cache] in
            let loaded = await cache.snapshotForCurrentAppVersion()
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, summary) in loaded where self.summaries[id] == nil {
                    self.summaries[id] = summary
                }
            }
        }
    }

    /// Enqueues low-priority async pre-checks for newly downloaded or imported wallpapers.
    func schedulePrecheck(
        wallpaperIDs: [String],
        entries: [BridgeWallpaperEntry],
        libraryRevision: UInt64
    ) {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in wallpaperIDs where !pendingIDs.contains(id) {
            guard let entry = byID[id] else { continue }
            let kind: WallpaperCompatibilityContext.Kind
            switch entry.kind {
            case .projectScene: kind = .scene
            case .video: kind = .video
            case .webpage: kind = .web
            case .unknown: kind = .unknown
            }
            pendingIDs.insert(id)
            pendingQueue.append((id: id, kind: kind, supported: entry.supported, revision: libraryRevision))
        }
        startWorkerIfNeeded()
    }

    /// Validates a cached badge asynchronously off SwiftUI `body`, dropping it if files/assets
    /// changed since it was recorded.
    func validateInBackground(
        wallpaperID: String,
        kind: WallpaperCompatibilityContext.Kind,
        libraryRevision: UInt64
    ) {
        guard summaries[wallpaperID] != nil else { return }
        Task.detached(priority: .utility) { [cache] in
            let valid = await cache.cachedSummary(
                for: wallpaperID, kind: kind, libraryRevision: libraryRevision)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let valid {
                    self.summaries[wallpaperID] = valid
                } else {
                    self.summaries.removeValue(forKey: wallpaperID)
                }
            }
        }
    }

    /// Records the result of an explicit Compatibility check into the persisted cache and memory.
    func recordManualCheck(
        wallpaperID: String,
        kind: WallpaperCompatibilityContext.Kind,
        checks: [WallpaperCompatibilityCheck],
        libraryRevision: UInt64
    ) {
        Task.detached(priority: .utility) { [cache] in
            guard let summary = await cache.record(
                wallpaperID: wallpaperID, kind: kind, checks: checks, libraryRevision: libraryRevision)
            else { return }
            await MainActor.run { [weak self] in
                self?.summaries[wallpaperID] = summary
            }
        }
    }

    /// Waits for currently queued background pre-checks to finish (used by unit tests).
    func drainForTests() async {
        while let task = workerTask {
            await task.value
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil, !pendingQueue.isEmpty else { return }
        workerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.workerTask = nil }
            while !self.pendingQueue.isEmpty, !Task.isCancelled {
                let next = self.pendingQueue.removeFirst()
                self.pendingIDs.remove(next.id)
                let summary = await Task.detached(priority: .utility) { [cache = self.cache] in
                    await cache.precheck(
                        wallpaperID: next.id,
                        kind: next.kind,
                        supported: next.supported,
                        libraryRevision: next.revision
                    )
                }.value
                if let summary {
                    self.summaries[next.id] = summary
                }
            }
        }
    }
}
