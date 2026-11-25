import Foundation

struct NativeWallpaperSource: Equatable, Sendable {
  let choice: LockScreenSourceChoice
  let wallpaperID: String?
  let wallpaperTitle: String?
  let playlistID: String?
  let playlistTitle: String?
  let isEnabled: Bool

  init(
    wallpaperID: String?,
    wallpaperTitle: String?,
    isEnabled: Bool
  ) {
    choice = wallpaperID.map { .wallpaper($0) } ?? .sameAsDesktop
    self.wallpaperID = wallpaperID
    self.wallpaperTitle = wallpaperTitle
    playlistID = nil
    playlistTitle = nil
    self.isEnabled = isEnabled
  }

  init(
    choice: LockScreenSourceChoice,
    wallpaperTitle: String? = nil,
    playlistTitle: String? = nil,
    isEnabled: Bool
  ) {
    self.choice = choice
    wallpaperID = choice.wallpaperID
    self.wallpaperTitle = wallpaperTitle
    playlistID = choice.playlistID
    self.playlistTitle = playlistTitle
    self.isEnabled = isEnabled
  }

  var selectedTarget: WallpaperAutomationTarget? { choice.automationTarget }

  var isUnavailable: Bool {
    switch choice {
    case .sameAsDesktop: false
    case .wallpaper: wallpaperTitle == nil
    case .playlist: playlistTitle == nil
    }
  }

  @MainActor var title: String {
    switch choice {
    case .sameAsDesktop:
      return L("Same as desktop")
    case .wallpaper(let id):
      return wallpaperTitle ?? L("Unavailable wallpaper: \(id)")
    case .playlist(let id):
      return playlistTitle ?? L("Unavailable playlist: \(id)")
    }
  }
}

/// One connected display's independent Lock Screen or Screen Saver source row.
struct NativeWallpaperDisplayOption: Identifiable, Equatable, Sendable {
  /// Stable display UUID (or display ID fallback) used as the override key.
  let id: String
  let title: String
  let source: NativeWallpaperSource
}

extension PanelController {
  func nativeWallpaperSource(
    _ kind: LockScreenState.Kind, displayUUID: String? = nil
  ) -> NativeWallpaperSource {
    _ = revisions.playlists
    let service = store.lockScreenWallpaper
    let choice = service?.source(lockScreen: kind == .lockScreen, displayUUID: displayUUID) ?? .sameAsDesktop
    let state = kind == .lockScreen ? lockScreenState : screenSaverState
    let targets = automationTargets
    let wallpaperTitle = choice.wallpaperID.flatMap { id in
      targets.wallpapers.first { $0.target.id == id }?.title
    }
    let playlistTitle = choice.playlistID.flatMap { id in
      targets.playlists.first { $0.target.id == id }?.title
    }
    return NativeWallpaperSource(
      choice: choice,
      wallpaperTitle: wallpaperTitle,
      playlistTitle: playlistTitle,
      isEnabled: state.isSwitchEnabled)
  }

  func nativeWallpaperUsesPerDisplay(_ kind: LockScreenState.Kind) -> Bool {
    store.lockScreenWallpaper?.usesPerDisplaySources(lockScreen: kind == .lockScreen) ?? false
  }

  /// Connected independent displays with their effective Lock Screen or Screen Saver source.
  func nativeWallpaperDisplaySources(_ kind: LockScreenState.Kind) -> [NativeWallpaperDisplayOption] {
    var seen = Set<String>()
    var options: [NativeWallpaperDisplayOption] = []
    for display in connectedSetupPackDisplays {
      let key = display.displayUUID ?? display.displayID
      guard seen.insert(key.lowercased()).inserted else { continue }
      options.append(
        NativeWallpaperDisplayOption(
          id: key,
          title: display.title,
          source: nativeWallpaperSource(kind, displayUUID: key)))
    }
    return options
  }
}
