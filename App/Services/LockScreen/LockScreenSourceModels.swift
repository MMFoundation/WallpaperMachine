import Foundation

/// Source chosen for Independent Lock Screen or Screen Saver, either globally ("All displays")
/// or for one display by its stable CoreGraphics display UUID.
enum LockScreenSourceChoice: Codable, Equatable, Hashable, Sendable {
  /// Follow the desktop's applied wallpaper on each display.
  case sameAsDesktop
  /// Show one specific library wallpaper by its library ID.
  case wallpaper(String)
  /// Bind a Saved Playlist (`PlaylistPlan.id` in `PlaylistStore`), rotating at low priority after
  /// unlock (lock screen) or screensaver exit (screen saver).
  case playlist(String)

  private enum CodingKeys: String, CodingKey {
    case kind, id
  }

  private enum Kind: String, Codable {
    case sameAsDesktop, wallpaper, playlist
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .sameAsDesktop:
      self = .sameAsDesktop
    case .wallpaper:
      let id = try container.decode(String.self, forKey: .id)
      self = .wallpaper(id)
    case .playlist:
      let id = try container.decode(String.self, forKey: .id)
      self = .playlist(id)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .sameAsDesktop:
      try container.encode(Kind.sameAsDesktop, forKey: .kind)
    case .wallpaper(let id):
      try container.encode(Kind.wallpaper, forKey: .kind)
      try container.encode(id, forKey: .id)
    case .playlist(let id):
      try container.encode(Kind.playlist, forKey: .kind)
      try container.encode(id, forKey: .id)
    }
  }

  var wallpaperID: String? {
    if case .wallpaper(let id) = self { return id }
    return nil
  }

  var playlistID: String? {
    if case .playlist(let id) = self { return id }
    return nil
  }

  var automationTarget: WallpaperAutomationTarget? {
    switch self {
    case .sameAsDesktop: nil
    case .wallpaper(let id): WallpaperAutomationTarget(kind: .wallpaper, id: id)
    case .playlist(let id): WallpaperAutomationTarget(kind: .playlist, id: id)
    }
  }

  var isValid: Bool {
    switch self {
    case .sameAsDesktop:
      return true
    case .wallpaper(let id), .playlist(let id):
      return !id.isEmpty && id.utf8.count <= 256 && !id.contains("\0")
        && !id.contains(where: \.isNewline)
    }
  }
}

/// Persisted source configuration for one native mode (Lock Screen or Screen Saver): a default
/// "All displays" choice plus optional per-display overrides keyed by stable display UUID.
struct LockScreenModeSources: Codable, Equatable, Sendable {
  static let maximumPerDisplayEntries = 64
  static let maximumEncodedBytes = 64 * 1024

  var allDisplays: LockScreenSourceChoice = .sameAsDesktop
  var usesPerDisplay: Bool = false
  var perDisplay: [String: LockScreenSourceChoice] = [:]

  init(
    allDisplays: LockScreenSourceChoice = .sameAsDesktop,
    usesPerDisplay: Bool = false,
    perDisplay: [String: LockScreenSourceChoice] = [:]
  ) {
    self.allDisplays = allDisplays
    self.usesPerDisplay = usesPerDisplay
    self.perDisplay = perDisplay
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    allDisplays = try container.decodeIfPresent(LockScreenSourceChoice.self, forKey: .allDisplays)
      ?? .sameAsDesktop
    usesPerDisplay = try container.decodeIfPresent(Bool.self, forKey: .usesPerDisplay) ?? false
    perDisplay = try container.decodeIfPresent([String: LockScreenSourceChoice].self, forKey: .perDisplay)
      ?? [:]
  }

  /// Effective choice for a connected display identified by `displayUUID`.
  func effectiveChoice(for displayUUID: String?) -> LockScreenSourceChoice {
    guard usesPerDisplay, let displayUUID else { return allDisplays }
    if let exact = perDisplay[displayUUID] { return exact }
    if let match = perDisplay.first(where: { $0.key.caseInsensitiveCompare(displayUUID) == .orderedSame }) {
      return match.value
    }
    return allDisplays
  }

  /// True when at least one configured slot selects a Saved Playlist.
  var hasAnyPlaylistChoice: Bool {
    if case .playlist = allDisplays { return true }
    if usesPerDisplay, perDisplay.values.contains(where: { $0.playlistID != nil }) { return true }
    return false
  }

  /// True when every possible display follows the desktop.
  var alwaysFollowsDesktop: Bool {
    allDisplays == .sameAsDesktop
      && (!usesPerDisplay || perDisplay.values.allSatisfy { $0 == .sameAsDesktop })
  }

  /// All library wallpaper IDs referenced by either the all-displays choice or any per-display slot.
  var referencedWallpaperIDs: Set<String> {
    var ids = Set<String>()
    if let id = allDisplays.wallpaperID, !id.isEmpty { ids.insert(id) }
    for choice in perDisplay.values {
      if let id = choice.wallpaperID, !id.isEmpty { ids.insert(id) }
    }
    return ids
  }

  /// Strict decoder used both at restore-validation time (`WallpaperBackupModels`) and when
  /// reading persisted preferences.
  static func decode(_ data: Data) throws -> LockScreenModeSources {
    guard data.count <= maximumEncodedBytes else {
      throw WallpaperBackupFailure(message: String(localized: "The backup contains an invalid preference value."))
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw WallpaperBackupFailure(message: String(localized: "The backup contains an invalid preference value."))
    }
    let allowedKeys: Set<String> = ["allDisplays", "usesPerDisplay", "perDisplay"]
    guard Set(object.keys).isSubset(of: allowedKeys) else {
      throw WallpaperBackupFailure(message: String(localized: "The backup contains an invalid preference value."))
    }
    let decoded = try JSONDecoder().decode(LockScreenModeSources.self, from: data)
    guard decoded.allDisplays.isValid,
          decoded.perDisplay.count <= maximumPerDisplayEntries,
          decoded.perDisplay.allSatisfy({ key, choice in
            !key.isEmpty && key.utf8.count <= 128 && !key.contains("\0")
              && !key.contains(where: \.isNewline) && choice.isValid
          })
    else {
      throw WallpaperBackupFailure(message: String(localized: "The backup contains an invalid preference value."))
    }
    return decoded
  }
}

/// Lightweight library record read by `LockScreenPlaylistResolver` when evaluating a Saved Playlist.
struct LockScreenLibraryEntry: Equatable {
  var id: String
  var kind: BridgeWallpaperKind
  var supported: Bool
}

/// Resolves and advances Saved Playlists bound to Independent Lock Screen or Screen Saver slots
/// without touching desktop playlist deadlines or blocking unlock.
@MainActor
final class LockScreenPlaylistResolver {
  struct SlotKey: Hashable, Sendable {
    var lockScreen: Bool
    /// `"all"` for global mode, or lowercased display UUID for per-display mode.
    var scope: String

    init(lockScreen: Bool, scope: String) {
      self.lockScreen = lockScreen
      self.scope = scope.lowercased()
    }
  }

  struct SlotState: Equatable, Sendable {
    var planID: String
    var currentWallpaperID: String
    var recent: [String]
  }

  private let planProvider: @MainActor (String) -> PlaylistPlan?
  private let collectionProvider: @MainActor (String) -> [String]
  private let libraryProvider: @MainActor () async throws -> [LockScreenLibraryEntry]
  private let favoritesProvider: @MainActor () -> Set<String>
  private let metadataProvider: @MainActor () -> [String: WallpaperMetadata]
  private let lastUsedProvider: @MainActor () -> [String: Date]
  private let energyLevelProvider: @MainActor (String, BridgeWallpaperKind) -> EnergyLevel?
  private let manifestTagsProvider: (@MainActor ([String]) async -> [String: [String]])?
  private let now: @MainActor () -> Date
  private let calendar: Calendar
  private var random = SystemRandomNumberGenerator()
  private var slots: [SlotKey: SlotState] = [:]

  init(
    planProvider: @escaping @MainActor (String) -> PlaylistPlan? = { PlaylistStore.shared.plan(id: $0) },
    collectionProvider: @escaping @MainActor (String) -> [String] = {
      WallpaperCollectionStore.shared.collection(id: $0)?.wallpaperIDs ?? []
    },
    libraryProvider: @escaping @MainActor () async throws -> [LockScreenLibraryEntry],
    favoritesProvider: @escaping @MainActor () -> Set<String> = {
      PanelPreferences.favorites(in: ClientPreferences.defaults)
    },
    metadataProvider: @escaping @MainActor () -> [String: WallpaperMetadata] = {
      WallpaperMetadataStore.shared.entries
    },
    lastUsedProvider: @escaping @MainActor () -> [String: Date] = { [:] },
    energyLevelProvider: @escaping @MainActor (String, BridgeWallpaperKind) -> EnergyLevel? = { _, _ in nil },
    manifestTagsProvider: (@MainActor ([String]) async -> [String: [String]])? = nil,
    now: @escaping @MainActor () -> Date = Date.init,
    calendar: Calendar = .autoupdatingCurrent
  ) {
    self.planProvider = planProvider
    self.collectionProvider = collectionProvider
    self.libraryProvider = libraryProvider
    self.favoritesProvider = favoritesProvider
    self.metadataProvider = metadataProvider
    self.lastUsedProvider = lastUsedProvider
    self.energyLevelProvider = energyLevelProvider
    self.manifestTagsProvider = manifestTagsProvider
    self.now = now
    self.calendar = calendar
  }

  func currentWallpaperID(lockScreen: Bool, scope: String) -> String? {
    slots[SlotKey(lockScreen: lockScreen, scope: scope)]?.currentWallpaperID
  }

  func clearSlot(lockScreen: Bool, scope: String? = nil) {
    if let scope {
      slots.removeValue(forKey: SlotKey(lockScreen: lockScreen, scope: scope))
    } else {
      slots = slots.filter { $0.key.lockScreen != lockScreen }
    }
  }

  /// Resolves the active wallpaper ID for a bound Saved Playlist slot.
  ///
  /// When `advance` is `false`, preserves the slot's current wallpaper as long as it still belongs
  /// to the playlist's playable candidate pool (preventing routine monitor refreshes from rotating).
  /// When `advance` is `true` (after unlock or screensaver end), picks the next wallpaper via
  /// `PlaylistPlanner.next` and updates the slot's shuffle round.
  func resolveWallpaperID(
    planID: String,
    lockScreen: Bool,
    scope: String,
    advance: Bool = false
  ) async throws -> String {
    guard let plan = planProvider(planID) else {
      throw LockScreenWallpaperFailure(
        message: String(localized: "The selected saved playlist is no longer available.")
      )
    }
    let entries = try await libraryProvider()
    let playableEntries = entries.filter(\.supported)
    let playableIDs = playableEntries.map(\.id)
    let playableSet = Set(playableIDs)
    let key = SlotKey(lockScreen: lockScreen, scope: scope)
    let existing = slots[key].flatMap { $0.planID == planID ? $0 : nil }

    if plan.playlist.mode == .dayNight {
      let phase = PlaylistPlanner.phase(
        at: now(),
        dayStart: plan.playlist.dayStart,
        nightStart: plan.playlist.nightStart,
        calendar: calendar)
      let desired = phase.phase == .day ? plan.playlist.dayWallpaperID : plan.playlist.nightWallpaperID
      guard let pick = desired, playableSet.contains(pick) else {
        throw LockScreenWallpaperFailure(
          message: String(localized: "The selected saved playlist “\(plan.name)” has no playable wallpaper for this time of day.")
        )
      }
      slots[key] = SlotState(planID: planID, currentWallpaperID: pick, recent: [])
      return pick
    }

    let favorites = favoritesProvider()
    let collectionIDs = plan.playlist.collectionID.map(collectionProvider) ?? []
    let metadata = metadataProvider()
    let lastUsed = lastUsedProvider()

    var facts: [String: SmartWallpaperFacts] = [:]
    if plan.playlist.source == .smart {
      let query = plan.playlist.effectiveSmartQuery
      let manifestTags: [String: [String]]
      if query.needsManifestMetadata, let manifestTagsProvider {
        manifestTags = await manifestTagsProvider(playableIDs)
      } else {
        manifestTags = [:]
      }
      for entry in playableEntries {
        facts[entry.id] = SmartWallpaperFacts(
          type: SmartWallpaperType.of(id: entry.id, kind: entry.kind),
          manifestTags: manifestTags[entry.id] ?? [],
          energyLevel: energyLevelProvider(entry.id, entry.kind))
      }
    }

    let candidates = PlaylistPlanner.candidates(
      for: plan.playlist,
      library: playableIDs,
      favorites: favorites,
      collectionIDs: collectionIDs,
      metadata: metadata,
      facts: facts,
      lastUsed: lastUsed,
      now: now(),
      current: existing?.currentWallpaperID)

    guard !candidates.isEmpty else {
      throw LockScreenWallpaperFailure(
        message: String(localized: "The selected saved playlist “\(plan.name)” has no playable wallpapers.")
      )
    }

    if !advance, let existing, candidates.contains(existing.currentWallpaperID) {
      return existing.currentWallpaperID
    }

    let pick: String
    if candidates.count == 1 {
      pick = candidates[0]
    } else {
      let ratings = metadata.compactMapValues(\.rating)
      pick = PlaylistPlanner.next(
        after: existing?.currentWallpaperID,
        in: candidates,
        order: plan.playlist.order,
        recent: existing?.recent ?? [],
        preferHigherRated: plan.playlist.preferHigherRated,
        ratings: ratings,
        using: &random) ?? candidates[0]
    }
    let nextRecent = PlaylistPlanner.remember(pick, in: existing?.recent ?? [], candidates: candidates)
    slots[key] = SlotState(planID: planID, currentWallpaperID: pick, recent: nextRecent)
    return pick
  }
}
