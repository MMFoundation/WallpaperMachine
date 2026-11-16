import Foundation

struct NativeWallpaperSource: Equatable, Sendable {
  let wallpaperID: String?
  let wallpaperTitle: String?
  let isEnabled: Bool

  var isUnavailable: Bool { wallpaperID != nil && wallpaperTitle == nil }

  @MainActor var title: String {
    guard let wallpaperID else { return L("Same as desktop") }
    return wallpaperTitle ?? L("Unavailable wallpaper: \(wallpaperID)")
  }
}

extension PanelController {
  func nativeWallpaperSource(_ kind: LockScreenState.Kind) -> NativeWallpaperSource {
    let service = store.lockScreenWallpaper
    let id = kind == .lockScreen ? service?.lockScreenWallpaperID : service?.screenSaverWallpaperID
    let state = kind == .lockScreen ? lockScreenState : screenSaverState
    return NativeWallpaperSource(
      wallpaperID: id,
      wallpaperTitle: id.flatMap { id in automationTargets.wallpapers.first { $0.target.id == id }?.title },
      isEnabled: state.isSwitchEnabled)
  }
}
