import Foundation

struct LockScreenSceneLayerHandoff {
  private var episode: LockScreenSceneLayerRequest?
  private var consumed = false

  var pendingRequest: LockScreenSceneLayerRequest? { consumed ? nil : episode }

  mutating func update(
    scene: LockScreenScene, content: LockScreenContent, configuration: LockScreenConfiguration?,
    presentation: WallpaperPresentationAuthority.Request, rendererReady: Bool
  ) {
    guard rendererReady, scene.desktopLayerStateWallpaperID?.isEmpty == false,
      scene.webEntryFile == nil, scene.plainVideo != true,
      !presentation.displaysAsleep, presentation.hostActivity == .active,
      WallpaperPresentationAuthority.showingContent(for: presentation) == content,
      let configuration, configuration.scene(for: content, displayID: scene.displayID) == scene
    else {
      self = Self()
      return
    }
    if let episode, episode.revision == configuration.revision, episode.displayID == scene.displayID,
      episode.content == content { return }
    episode = LockScreenSceneLayerRequest(token: UUID(), revision: configuration.revision,
      displayID: scene.displayID, content: content)
    consumed = false
  }

  mutating func takeState(from states: [UUID: String]) -> String? {
    guard let pendingRequest, let state = states[pendingRequest.token] else { return nil }
    consumed = true
    return state
  }
}
