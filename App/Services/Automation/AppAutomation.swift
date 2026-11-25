import Foundation

/// Where commands from outside the window arrive: App Intents run in the app's process and
/// reach it through `shared`, and the app delegate hands links and keyboard shortcuts to the
/// same place. The app delegate sets `handler` once the library has loaded, since a command
/// such as Apply needs it; until then a command waits a little rather than failing at once,
/// because the system may have launched the app to run it.
@MainActor
final class AppAutomation {
    enum WallpaperKind: String, CaseIterable, Codable, Equatable, Sendable {
        case scene, video, web, unknown

        init(_ bridgeKind: BridgeWallpaperKind) {
            switch bridgeKind {
            case .projectScene: self = .scene
            case .video: self = .video
            case .webpage: self = .web
            case .unknown: self = .unknown
            }
        }
    }

    struct WallpaperInfo: Equatable, Sendable {
        var id: String
        var title: String
        var kind: WallpaperKind
        var isFavorite: Bool
        var collectionIDs: [String]
        var collectionNames: [String]
    }

    struct CurrentWallpaperStatus: Equatable, Sendable {
        var displayID: String
        var displayTitle: String
        var wallpaperID: String?
        var wallpaperTitle: String?
        var wallpaperKind: WallpaperKind?
        var isFavorite: Bool
        var isPlaying: Bool
        var isMuted: Bool
        var isPresentationMode: Bool
    }

    static let shared = AppAutomation()

    /// Carries out a command; nil until the app is ready for one.
    var handler: (@MainActor (AutomationCommand) async throws -> Void)?
    /// The installed wallpapers that can play, as the Shortcuts app lists them.
    var wallpapers: (@MainActor () -> [(id: String, title: String)])?
    /// Detailed metadata for installed playable wallpapers (used by Find Wallpapers / property queries).
    var wallpaperCatalog: (@MainActor () -> [WallpaperInfo])?
    /// Local user collections, as the Shortcuts app lists them.
    var collections: (@MainActor () -> [(id: String, name: String)])?
    /// Current wallpaper, playback and mute status for the named display (or target/main display).
    var currentStatus: (@MainActor (_ displayID: String?) throws -> CurrentWallpaperStatus)?
    /// Connected, enabled independent displays, keyed by the existing stable selector.
    var displays: (@MainActor () -> [(id: String, title: String)])?
    var playlistPlans: (@MainActor () -> [(id: String, title: String)])?
    var displayLayouts: (@MainActor () -> [(id: String, title: String)])?
    var propertyPresets: (@MainActor () -> [(id: String, title: String, wallpaper: String)])?

    private let wait: Duration
    private let poll: Duration

    init(wait: Duration = .seconds(15), poll: Duration = .milliseconds(100)) {
        self.wait = wait
        self.poll = poll
    }

    func perform(_ command: AutomationCommand) async throws {
        guard let handler = await readyHandler() else { throw AutomationError.notReady }
        try await handler(command)
    }

    func availableWallpapers() async -> [(id: String, title: String)] {
        _ = await readyHandler()
        if let wallpapers { return wallpapers() }
        return wallpaperCatalog?().map { (id: $0.id, title: $0.title) } ?? []
    }

    func availableWallpaperInfo() async -> [WallpaperInfo] {
        _ = await readyHandler()
        if let wallpaperCatalog { return wallpaperCatalog() }
        return (wallpapers?() ?? []).map {
            WallpaperInfo(
                id: $0.id, title: $0.title, kind: .unknown, isFavorite: false, collectionIDs: [], collectionNames: [])
        }
    }

    func availableCollections() async -> [(id: String, name: String)] {
        _ = await readyHandler()
        return collections?() ?? []
    }

    func currentWallpaperStatus(displayID: String?) async throws -> CurrentWallpaperStatus {
        guard await readyHandler() != nil, let currentStatus else { throw AutomationError.notReady }
        return try currentStatus(displayID)
    }

    func availableDisplays() async -> [(id: String, title: String)] {
        _ = await readyHandler()
        return displays?() ?? []
    }

    func availablePlaylistPlans() async -> [(id: String, title: String)] {
        _ = await readyHandler()
        return playlistPlans?() ?? []
    }

    func availableDisplayLayouts() async -> [(id: String, title: String)] {
        _ = await readyHandler()
        return displayLayouts?() ?? []
    }

    func availablePropertyPresets() async -> [(id: String, title: String, wallpaper: String)] {
        _ = await readyHandler()
        return propertyPresets?() ?? []
    }

    private func readyHandler() async -> (@MainActor (AutomationCommand) async throws -> Void)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while handler == nil, clock.now < deadline {
            do { try await Task.sleep(for: poll) } catch { return nil }
        }
        return handler
    }
}
