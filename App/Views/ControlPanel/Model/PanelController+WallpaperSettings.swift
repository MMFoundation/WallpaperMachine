import Foundation

/// The inspector's General configuration and Displays cards: the wallpaper's own audio and media
/// settings, and what each display does with it.
///
/// Every setting here takes effect at once and is saved, except a display's scale factor, a draft
/// that shows on the display, and its Enabled switch, a draft too: both wait for Apply changes (the
/// bridge reports them as the display row's `staged`). Each is queued behind the user's other
/// commands and wrapped by the store in an edit, so an Apply or an activation waits for it. Start
/// them under the `InspectorAction.wallpaperSetting` / `displayConfig` keys with `.latestWins`.
extension PanelController {
  // MARK: The wallpaper's own settings

  /// `wallpaperSetting` `volume`: from 0 to 1; a value outside it is refused, not moved to the edge.
  func setVolume(_ volume: Double, for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      try await store.setVolumeAsync(wallpaperId: id, volume: try PanelValueRules.volume(volume))
    }
  }

  /// `wallpaperSetting` `muted`.
  func setMuted(_ muted: Bool, for wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.setMutedAsync(wallpaperId: installedWallpaperID(wallpaperID), muted: muted)
    }
  }

  /// `wallpaperSetting` `audioResponseEnabled`. When the capture fails the store re-reads every
  /// snapshot, so the saved option rolls back and the switch follows.
  func setAudioResponseEnabled(_ enabled: Bool, for wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.setAudioResponseEnabledAsync(
        wallpaperId: installedWallpaperID(wallpaperID), enabled: enabled)
    }
  }

  /// `wallpaperSetting` `mediaIntegrationEnabled`.
  func setMediaIntegrationEnabled(_ enabled: Bool, for wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.setMediaIntegrationEnabledAsync(
        wallpaperId: installedWallpaperID(wallpaperID), enabled: enabled)
    }
  }

  /// `wallpaperSetting` `renderScale`: sets or clears a per-wallpaper render scale override.
  func setWallpaperRenderScale(_ scale: Float?, for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let validated: Float?
      if let scale {
        guard scale.isFinite else { throw InvalidControlValue() }
        validated = min(1.0, max(0.25, scale))
      } else {
        validated = nil
      }
      try await store.setWallpaperRenderScaleAsync(wallpaperId: id, scale: validated)
    }
  }

  /// `wallpaperSetting` `sceneQuality`: sets or clears a per-wallpaper scene quality override.
  func setWallpaperSceneQuality(_ quality: BridgeSceneQuality?, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      try await store.setWallpaperSceneQualityAsync(
        wallpaperId: installedWallpaperID(wallpaperID), quality: quality)
    }
  }

  /// Clears both per-wallpaper quality overrides back to the global settings.
  func resetWallpaperQuality(for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      if options.renderScaleOverride != nil {
        try await store.setWallpaperRenderScaleAsync(wallpaperId: id, scale: nil)
      }
      if options.sceneQualityOverride != nil {
        try await store.setWallpaperSceneQualityAsync(wallpaperId: id, quality: nil)
      }
    }
  }

  /// One-click action beside a High energy rating: steps down this wallpaper's render scale
  /// (100% → 75%, 75% → 50%) and, for scenes with heavier effects, eases MSAA, shadows,
  /// volumetrics, reflections and post-processing without changing global settings.
  func lowerWallpaperQuality(for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      let settings = store.settingsSnapshot
      if options.kind == .projectScene || options.kind == .webpage {
        let currentScale = options.renderScaleOverride ?? settings.preferredRenderScale
        let nextScale = Self.loweredRenderScale(from: currentScale)
        if options.renderScaleOverride != nextScale {
          try await store.setWallpaperRenderScaleAsync(wallpaperId: id, scale: nextScale)
        }
      }
      if options.kind == .projectScene {
        let currentQuality = options.sceneQualityOverride ?? settings.sceneQuality
        let nextQuality = Self.loweredSceneQuality(from: currentQuality)
        if nextQuality != currentQuality {
          try await store.setWallpaperSceneQualityAsync(wallpaperId: id, quality: nextQuality)
        }
      }
    }
  }

  /// Next lower standard render scale step: above 75% → 75%, above 50% → 50%, otherwise keeps
  /// `current` so "Lower quality" never raises an already-lower render scale.
  static func loweredRenderScale(from current: Float) -> Float {
    guard current.isFinite else { return 0.75 }
    if current > 0.75 { return 0.75 }
    if current > 0.5 { return 0.5 }
    return current
  }

  /// Eases heavy per-scene quality features without changing global settings.
  static func loweredSceneQuality(from current: BridgeSceneQuality) -> BridgeSceneQuality {
    BridgeSceneQuality(
      msaa: .off,
      shadows: current.shadows == .off ? .off : .low,
      volumetrics: current.volumetrics == .off ? .off : .low,
      reflections: false,
      postProcessing: current.postProcessing == .disabled ? .disabled : .enabled)
  }

  // MARK: One display's setting

  /// `displayConfig` `enabled`: whether the display plays this wallpaper.
  func setDisplayEnabled(_ enabled: Bool, on displayID: String, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      try await store.setDisplayConfigEnabledAsync(
        wallpaperId: installedWallpaperID(wallpaperID), displayId: displayID, enabled: enabled)
    }
  }

  /// `displayConfig` `scalingMode`.
  func setScalingMode(_ mode: BridgeScalingMode, on displayID: String, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      try await store.setScalingModeAsync(
        wallpaperId: installedWallpaperID(wallpaperID), displayId: displayID, mode: mode)
    }
  }

  /// `displayConfig` `scalingFactor`: a finite factor greater than zero, held as a draft (it shows on
  /// the playing display, Apply changes keeps it and Revert restores the saved one). An empty or
  /// zero field is the control's to catch: it must never reach here as 0.
  func setScalingFactor(_ factor: Double, on displayID: String, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      try await store.editScalingFactorAsync(
        wallpaperId: id, displayId: displayID, factor: try PanelValueRules.scalingFactor(factor))
    }
  }

  /// `displayConfig` `fps`: a whole number from 1 to the display's own maximum, read from a fresh
  /// options snapshot of the wallpaper (a display it has no row for is refused).
  func setFrameRate(_ fps: Int, on displayID: String, for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let row = options.displayConfigurations.first(where: { $0.displayId == displayID })
      else { throw InvalidControlValue() }
      try await store.setTargetFpsAsync(
        wallpaperId: id, displayId: displayID,
        fps: try PanelValueRules.frameRate(fps, maximum: row.maxFps))
    }
  }
}
