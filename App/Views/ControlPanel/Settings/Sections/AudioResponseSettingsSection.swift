import AppKit
import SwiftUI

/// Settings › Playback & Power › Audio response: 30 Hz FFT output tuning (sensitivity, noise floor,
/// temporal smoothing) and optional per-app CoreAudio capture target.
enum AudioResponseSettingsSection {
  static let group = SettingsItem.Group("audio-response", title: "Audio response")

  static let captureSource = SettingsItem(
    id: "playback.audio-response-source", section: .playback, group: group,
    title: "Audio capture source",
    note:
      "Choose whether audio-responsive wallpapers listen to all apps or only one app. If the chosen app isn’t running, wallpapers stay quiet until it plays sound.",
    keywords: ["All apps", "Choose app…", "Waiting for app to launch"])

  static let sensitivity = SettingsItem(
    id: "playback.audio-response-sensitivity", section: .playback, group: group,
    title: "Sensitivity",
    note:
      "Scales the spectrum levels sent to audio-responsive wallpapers. Default is 1.00×.")

  static let noiseFloor = SettingsItem(
    id: "playback.audio-response-noise-floor", section: .playback, group: group,
    title: "Noise floor",
    note:
      "Sounds quieter than this level are ignored so background hiss doesn’t move the wallpaper. Default is -48 dB.")

  static let smoothing = SettingsItem(
    id: "playback.audio-response-smoothing", section: .playback, group: group,
    title: "Smoothing",
    note:
      "Blends each spectrum update with the previous one for steadier motion. Default is 0%, leaving smoothing to the wallpaper.")

  static let resetDefaults = SettingsItem(
    id: "playback.audio-response-reset", section: .playback, group: group,
    title: "Audio response defaults",
    keywords: ["Reset defaults"])

  static let items = [captureSource, sensitivity, noiseFloor, smoothing, resetDefaults]
}

/// Standalone Settings group mounted inside `PlaybackSettingsSection`.
struct AudioResponseSettingsGroup: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var ownedSourceModel = AudioResponseSourceModel()
  private let injectedSourceModel: AudioResponseSourceModel?

  init(sourceModel: AudioResponseSourceModel? = nil) {
    self.injectedSourceModel = sourceModel
  }

  private var sourceModel: AudioResponseSourceModel {
    injectedSourceModel ?? ownedSourceModel
  }

  var body: some View {
    let audio = controller.audioResponseSettings
    let canonicalTarget = sourceModel.canonicalSelectionValue(for: audio.targetAppBundleID)

    SettingsGroup(AudioResponseSettingsSection.group, in: .playback) {
      SettingsRow(AudioResponseSettingsSection.captureSource, stacked: true) {
        VStack(alignment: .leading, spacing: 4) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              captureSourceMenu(
                canonicalTarget: canonicalTarget, savedTarget: audio.targetAppBundleID)
              chooseAppButton
            }
            VStack(alignment: .leading, spacing: 6) {
              captureSourceMenu(
                canonicalTarget: canonicalTarget, savedTarget: audio.targetAppBundleID)
              chooseAppButton
            }
          }
          if let bundleID = audio.targetAppBundleID, !sourceModel.isRunning(bundleID) {
            HStack(spacing: 4) {
              Text(verbatim: sourceModel.displayName(for: bundleID))
              Text(verbatim: "—")
              Text("Waiting for app to launch")
            }
            .font(.panel(.footnote))
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityElement(children: .combine)
          }
        }
      }

      SettingsRow(AudioResponseSettingsSection.sensitivity) {
        SettingsSliderControl(
          key: "audioResponseSensitivity",
          saved: audio.sensitivityStep,
          range: AudioResponseSettings.sensitivitySliderRange,
          readout: AudioResponseSettings.sensitivityReadout(step:)
        ) { step in
          try await controller.setAudioResponseSensitivity(
            AudioResponseSettings.sensitivity(fromStep: step))
        }
      }

      SettingsRow(AudioResponseSettingsSection.noiseFloor) {
        SettingsSliderControl(
          key: "audioResponseNoiseFloor",
          saved: audio.noiseFloorDbInt,
          range: AudioResponseSettings.noiseFloorSliderRange,
          readout: AudioResponseSettings.noiseFloorReadout(db:)
        ) { db in
          try await controller.setAudioResponseNoiseFloorDb(Float(db))
        }
      }

      SettingsRow(AudioResponseSettingsSection.smoothing) {
        SettingsSliderControl(
          key: "audioResponseSmoothing",
          saved: audio.smoothingPercent,
          range: AudioResponseSettings.smoothingSliderRange,
          readout: AudioResponseSettings.smoothingReadout(percent:)
        ) { percent in
          try await controller.setAudioResponseSmoothing(Float(percent) / 100.0)
        }
      }

      SettingsRow(AudioResponseSettingsSection.resetDefaults) {
        SettingsActionButton(
          "Reset defaults",
          isDisabled: audio.isDefault
            || controller.settings.isLocked("audioResponseReset", whileRunning: true)
        ) {
          controller.settings.perform("audioResponseReset") {
            try await controller.resetAudioResponseSettings()
          }
        }
      }
    }
    .onAppear {
      sourceModel.refreshRunningApps()
      sourceModel.resolveDisplayNameIfNeeded(for: audio.targetAppBundleID)
    }
    .onChange(of: audio.targetAppBundleID) { _, newTarget in
      sourceModel.resolveDisplayNameIfNeeded(for: newTarget)
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didLaunchApplicationNotification)
    ) { _ in
      sourceModel.refreshRunningApps()
      sourceModel.resolveDisplayNameIfNeeded(
        for: controller.audioResponseSettings.targetAppBundleID)
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didTerminateApplicationNotification)
    ) { _ in
      sourceModel.refreshRunningApps()
      sourceModel.resolveDisplayNameIfNeeded(
        for: controller.audioResponseSettings.targetAppBundleID)
    }
  }

  private func captureSourceMenu(canonicalTarget: String, savedTarget: String?) -> some View {
    SettingsMenuControl(
      key: "audioResponseTargetApp",
      saved: canonicalTarget,
      options: sourceModel.sourceOptions(savedTarget: savedTarget, allAppsTitle: L("All apps"))
    ) { selected in
      try await controller.setAudioResponseTargetApp(selected.isEmpty ? nil : selected)
    }
  }

  private var chooseAppButton: some View {
    SettingsActionButton(
      "Choose app…",
      isDisabled: controller.settings.isLocked("audioResponseChooseApp", whileRunning: true)
    ) {
      controller.settings.perform("audioResponseChooseApp") {
        try await controller.chooseAudioResponseTargetApp()
        sourceModel.refreshRunningApps()
        sourceModel.resolveDisplayNameIfNeeded(
          for: controller.audioResponseSettings.targetAppBundleID,
          force: true)
      }
    }
  }
}
