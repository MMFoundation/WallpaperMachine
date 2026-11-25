import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// Settings › Playback & Power › Audio response: 30 Hz FFT output tuning (sensitivity, noise floor,
/// temporal smoothing) and optional per-app CoreAudio capture target.
@MainActor
final class AudioResponseSettingsTests: PanelTestCase {
  func testDefaultsReadoutsAndSliderStepConversionsMatchLegacyBehavior() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      let audio = panel.controller.audioResponseSettings

      XCTAssertEqual(audio.sensitivity, 1.0, accuracy: 1e-6)
      XCTAssertEqual(audio.noiseFloorDb, -48.0, accuracy: 1e-6)
      XCTAssertEqual(audio.smoothing, 0.0, accuracy: 1e-6)
      XCTAssertNil(audio.targetAppBundleID)
      XCTAssertTrue(audio.isDefault)

      XCTAssertEqual(audio.sensitivityStep, 20)
      XCTAssertEqual(audio.noiseFloorDbInt, -48)
      XCTAssertEqual(audio.smoothingPercent, 0)

      XCTAssertEqual(AudioResponseSettings.sensitivityReadout(step: 5), "0.25×")
      XCTAssertEqual(AudioResponseSettings.sensitivityReadout(step: 20), "1.00×")
      XCTAssertEqual(AudioResponseSettings.sensitivityReadout(step: 80), "4.00×")
      XCTAssertEqual(AudioResponseSettings.noiseFloorReadout(db: -72), "-72 dB")
      XCTAssertEqual(AudioResponseSettings.noiseFloorReadout(db: -48), "-48 dB")
      XCTAssertEqual(AudioResponseSettings.noiseFloorReadout(db: -24), "-24 dB")
      XCTAssertEqual(AudioResponseSettings.smoothingReadout(percent: 0), "0%")
      XCTAssertEqual(AudioResponseSettings.smoothingReadout(percent: 90), "90%")

      // Out-of-range slider readouts clamp to supported bounds.
      XCTAssertEqual(AudioResponseSettings.sensitivityReadout(step: 0), "0.25×")
      XCTAssertEqual(AudioResponseSettings.sensitivityReadout(step: 500), "4.00×")
      XCTAssertEqual(AudioResponseSettings.noiseFloorReadout(db: -120), "-72 dB")
      XCTAssertEqual(AudioResponseSettings.noiseFloorReadout(db: 0), "-24 dB")
      XCTAssertEqual(AudioResponseSettings.smoothingReadout(percent: -10), "0%")
      XCTAssertEqual(AudioResponseSettings.smoothingReadout(percent: 150), "90%")
    }
  }

  /// Changing one tuning parameter merges with the other two saved values, clamps finite
  /// out-of-range inputs, and rejects non-finite numbers before they reach the bridge.
  func testTuningSettersMergeClampAndRefuseNonFiniteValues() async throws {
    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      let controller = panel.controller

      try await controller.setAudioResponseSensitivity(2.5)
      XCTAssertEqual(
        bridge.audioResponseTuningCalls.last,
        .init(sensitivity: 2.5, noiseFloorDb: -48.0, smoothing: 0.0))
      XCTAssertFalse(controller.audioResponseSettings.isDefault)

      try await controller.setAudioResponseNoiseFloorDb(-60.0)
      XCTAssertEqual(
        bridge.audioResponseTuningCalls.last,
        .init(sensitivity: 2.5, noiseFloorDb: -60.0, smoothing: 0.0))

      try await controller.setAudioResponseSmoothing(0.45)
      XCTAssertEqual(
        bridge.audioResponseTuningCalls.last,
        .init(sensitivity: 2.5, noiseFloorDb: -60.0, smoothing: 0.45))

      // Finite outliers clamp to the documented bounds.
      try await controller.setAudioResponseSensitivity(12.0)
      XCTAssertEqual(bridge.audioResponseTuningCalls.last?.sensitivity, 4.0)
      try await controller.setAudioResponseSensitivity(0.01)
      XCTAssertEqual(bridge.audioResponseTuningCalls.last?.sensitivity, 0.25)

      try await controller.setAudioResponseNoiseFloorDb(-100.0)
      XCTAssertEqual(bridge.audioResponseTuningCalls.last?.noiseFloorDb, -72.0)
      try await controller.setAudioResponseNoiseFloorDb(-5.0)
      XCTAssertEqual(bridge.audioResponseTuningCalls.last?.noiseFloorDb, -24.0)

      try await controller.setAudioResponseSmoothing(0.99)
      XCTAssertEqual(bridge.audioResponseTuningCalls.last?.smoothing, 0.90)
      try await controller.setAudioResponseSmoothing(-0.2)
      XCTAssertEqual(bridge.audioResponseTuningCalls.last?.smoothing, 0.0)

      let callsBeforeInvalid = bridge.audioResponseTuningCalls.count
      for bad in [Float.nan, Float.infinity, -Float.infinity] {
        do {
          try await controller.setAudioResponseSensitivity(bad)
          XCTFail("Non-finite sensitivity must be refused")
        } catch is InvalidControlValue {}
        do {
          try await controller.setAudioResponseNoiseFloorDb(bad)
          XCTFail("Non-finite noise floor must be refused")
        } catch is InvalidControlValue {}
        do {
          try await controller.setAudioResponseSmoothing(bad)
          XCTFail("Non-finite smoothing must be refused")
        } catch is InvalidControlValue {}
      }
      XCTAssertEqual(
        bridge.audioResponseTuningCalls.count, callsBeforeInvalid,
        "Refused non-finite values must never reach the bridge")
    }
  }

  func testTargetAppNormalizesBlankValuesAndResetRestoresDefaults() async throws {
    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      let controller = panel.controller

      try await controller.setAudioResponseTargetApp("  com.apple.Music \n")
      XCTAssertEqual(bridge.audioResponseTargetAppCalls, ["com.apple.Music"])
      XCTAssertEqual(controller.audioResponseSettings.targetAppBundleID, "com.apple.Music")
      XCTAssertFalse(controller.audioResponseSettings.isDefault)

      try await controller.setAudioResponseTargetApp("   ")
      XCTAssertEqual(bridge.audioResponseTargetAppCalls, ["com.apple.Music", nil])
      XCTAssertNil(controller.audioResponseSettings.targetAppBundleID)

      try await controller.setAudioResponseSensitivity(1.75)
      try await controller.setAudioResponseNoiseFloorDb(-56.0)
      try await controller.setAudioResponseSmoothing(0.35)
      try await controller.setAudioResponseTargetApp("com.spotify.client")
      XCTAssertFalse(controller.audioResponseSettings.isDefault)

      try await controller.resetAudioResponseSettings()
      XCTAssertEqual(
        bridge.audioResponseTuningCalls.last,
        .init(sensitivity: 1.0, noiseFloorDb: -48.0, smoothing: 0.0))
      XCTAssertEqual(bridge.audioResponseTargetAppCalls.last, Optional<String>.none)
      XCTAssertTrue(controller.audioResponseSettings.isDefault)
    }
  }

  func testChooseAudioResponseTargetAppAcceptsValidBundleAndRejectsMissingIdentifier() async throws {
    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      let controller = panel.controller

      let sampleApp = panel.root.appendingPathComponent("MusicPlayer.app")
      try FileManager.default.createDirectory(at: sampleApp, withIntermediateDirectories: true)
      try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.musicplayer</string>
        <key>CFBundleName</key><string>Music Player</string>
        </dict></plist>
        """.write(
        to: sampleApp.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

      controller.chooseApplication = { sampleApp }
      try await controller.chooseAudioResponseTargetApp()
      XCTAssertEqual(bridge.audioResponseTargetAppCalls, ["com.example.musicplayer"])
      XCTAssertEqual(controller.audioResponseSettings.targetAppBundleID, "com.example.musicplayer")

      // A cancelled picker leaves the saved target untouched.
      controller.chooseApplication = { nil }
      try await controller.chooseAudioResponseTargetApp()
      XCTAssertEqual(bridge.audioResponseTargetAppCalls, ["com.example.musicplayer"])

      // An app package without CFBundleIdentifier is rejected with a clear action error.
      let bareApp = panel.root.appendingPathComponent("Bare.app")
      try FileManager.default.createDirectory(at: bareApp, withIntermediateDirectories: true)
      controller.chooseApplication = { bareApp }
      do {
        try await controller.chooseAudioResponseTargetApp()
        XCTFail("An app without CFBundleIdentifier must be rejected")
      } catch let error as WallpaperActionError {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
      XCTAssertEqual(bridge.audioResponseTargetAppCalls, ["com.example.musicplayer"])

      // Selecting WallpaperMachine itself is rejected so the UI never pins to an excluded self PID.
      if let ownBundleID = Bundle.main.bundleIdentifier {
        let selfApp = panel.root.appendingPathComponent("WallpaperMachine.app")
        try FileManager.default.createDirectory(at: selfApp, withIntermediateDirectories: true)
        try """
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>\(ownBundleID)</string>
          </dict></plist>
          """.write(
          to: selfApp.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        controller.chooseApplication = { selfApp }
        do {
          try await controller.chooseAudioResponseTargetApp()
          XCTFail("Choosing this app itself as an audio capture source must be rejected")
        } catch let error as WallpaperActionError {
          XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        do {
          try await controller.setAudioResponseTargetApp(ownBundleID.uppercased())
          XCTFail("Setting this app's own bundle ID must be rejected case-insensitively")
        } catch let error as WallpaperActionError {
          XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(bridge.audioResponseTargetAppCalls, ["com.example.musicplayer"])
      }
      XCTAssertTrue(
        AudioResponseSettings.isOwnBundleID(
          "COM.EXAMPLE.SELF", ownBundleID: "com.example.self"))
      XCTAssertFalse(
        AudioResponseSettings.isOwnBundleID(
          "com.example.other", ownBundleID: "com.example.self"))
    }
  }

  func testCandidateAppsExcludeSelfDeduplicateCaseInsensitivelyAndSortByName() throws {
    let candidates = AudioResponseSettings.candidateApps(
      from: [
        (bundleIdentifier: "com.spotify.client", name: "Spotify"),
        (bundleIdentifier: "COM.SPOTIFY.CLIENT", name: "Spotify Duplicate"),
        (bundleIdentifier: "com.wallpapermachine.app", name: "WallpaperMachine"),
        (bundleIdentifier: "com.apple.Music", name: "Music"),
        (bundleIdentifier: "   ", name: "Blank"),
        (bundleIdentifier: "com.example.noname", name: nil),
      ],
      excludingOwnBundleID: "COM.WALLPAPERMACHINE.APP")

    XCTAssertEqual(
      candidates,
      [
        AudioResponseAppOption(bundleIdentifier: "com.example.noname", name: "com.example.noname"),
        AudioResponseAppOption(bundleIdentifier: "com.apple.Music", name: "Music"),
        AudioResponseAppOption(bundleIdentifier: "com.spotify.client", name: "Spotify"),
      ])

    // Running apps resolve case-insensitively before falling back to Launch Services or bundle ID.
    XCTAssertEqual(
      AudioResponseSettings.appDisplayName(
        for: "COM.APPLE.MUSIC", runningApps: candidates, urlLookup: { _ in nil }),
      "Music")
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AudioResponseSettingsTests-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }
    let installedApp = tempRoot.appendingPathComponent("VLC.app")
    try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
    XCTAssertEqual(
      AudioResponseSettings.appDisplayName(
        for: "org.videolan.vlc", runningApps: candidates, urlLookup: { _ in installedApp }),
      "VLC")
    XCTAssertEqual(
      AudioResponseSettings.appDisplayName(
        for: "com.unknown.player", runningApps: candidates, urlLookup: { _ in nil }),
      "com.unknown.player")
  }

  /// Regression tests for #15 (zero IPC/disk I/O in `View.body`) and #17 (case-insensitive bundle ID
  /// canonicalization for SwiftUI `Picker` tag selection).
  func testSourceModelCanonicalizesCaseInsensitiveSelectionAndCachesDisplayNameWithoutBodyIO()
    async throws
  {
    var runningProviderCalls = 0
    var resolverCalls: [String] = []
    var currentRunning = [
      AudioResponseAppOption(bundleIdentifier: "com.apple.Music", name: "Music"),
      AudioResponseAppOption(bundleIdentifier: "com.spotify.client", name: "Spotify"),
    ]

    let model = AudioResponseSourceModel(
      runningAppsProvider: {
        runningProviderCalls += 1
        return currentRunning
      },
      displayNameResolver: { bundleID in
        resolverCalls.append(bundleID)
        return bundleID.caseInsensitiveCompare("org.videolan.vlc") == .orderedSame ? "VLC" : nil
      })

    // Before `.onAppear` refreshes, synchronous body reads perform zero provider/resolver I/O
    // and fall back cleanly to the raw bundle ID.
    XCTAssertEqual(model.canonicalSelectionValue(for: "org.videolan.vlc"), "org.videolan.vlc")
    XCTAssertEqual(model.displayName(for: "org.videolan.vlc"), "org.videolan.vlc")
    let initialOptions = model.sourceOptions(savedTarget: "org.videolan.vlc", allAppsTitle: "All apps")
    XCTAssertEqual(initialOptions.map(\.value), ["", "org.videolan.vlc"])
    XCTAssertEqual(initialOptions.map(\.title), ["All apps", "org.videolan.vlc"])
    XCTAssertEqual(runningProviderCalls, 0)
    XCTAssertTrue(resolverCalls.isEmpty)

    // After refresh, a saved target differing only in case canonicalizes to the exact Picker tag
    // of the matching running app and is not duplicated in sourceOptions.
    model.refreshRunningApps()
    XCTAssertEqual(runningProviderCalls, 1)
    let canonical = model.canonicalSelectionValue(for: "com.apple.music")
    let runningOptions = model.sourceOptions(savedTarget: "com.apple.music", allAppsTitle: "All apps")
    XCTAssertEqual(canonical, "com.apple.Music")
    XCTAssertTrue(
      runningOptions.contains(where: { $0.value == canonical }),
      "Canonicalized Picker selection must match an exact option tag")
    XCTAssertEqual(
      runningOptions.map(\.value), ["", "com.apple.Music", "com.spotify.client"])
    XCTAssertTrue(model.isRunning("com.apple.music"))
    XCTAssertEqual(model.displayName(for: "com.apple.music"), "Music")
    XCTAssertTrue(resolverCalls.isEmpty, "Running apps must never trigger Launch Services lookup")

    // Resolving a non-running target caches its name after a single lookup.
    model.resolveDisplayNameIfNeeded(for: "org.videolan.vlc")
    model.resolveDisplayNameIfNeeded(for: "ORG.VIDEOLAN.VLC")
    XCTAssertEqual(resolverCalls, ["org.videolan.vlc"])
    XCTAssertEqual(model.displayName(for: "org.videolan.vlc"), "VLC")
    let offlineOptions = model.sourceOptions(savedTarget: "org.videolan.vlc", allAppsTitle: "All apps")
    XCTAssertEqual(offlineOptions.last?.value, "org.videolan.vlc")
    XCTAssertEqual(offlineOptions.last?.title, "VLC")

    // When a running app later quits, its cached display name remains available with zero IPC.
    currentRunning = [AudioResponseAppOption(bundleIdentifier: "com.apple.Music", name: "Music")]
    model.refreshRunningApps()
    XCTAssertFalse(model.isRunning("com.spotify.client"))
    XCTAssertEqual(model.displayName(for: "com.spotify.client"), "Spotify")
    model.resolveDisplayNameIfNeeded(for: "com.spotify.client")
    XCTAssertEqual(resolverCalls, ["org.videolan.vlc"])
  }

  /// Hosting `AudioResponseSettingsGroup` with an injected `AudioResponseSourceModel` lays out
  /// inside the narrowest 460 pt Settings column without touching live `NSWorkspace.shared`.
  func testAudioResponseSettingsGroupLaysOutInNarrowColumnWithInjectedSourceModel() async throws {
    try await withRecordingPanel { panel, _ in
      var settings = BridgeSnapshotFixtures.settings()
      settings.audioResponseTargetApp = "com.apple.music"
      panel.store.settingsSnapshot = settings
      panel.store.snapshotRevision = 1
      let controller = panel.controller

      var providerCalls = 0
      var resolverCalls = 0
      let model = AudioResponseSourceModel(
        runningAppsProvider: {
          providerCalls += 1
          return [
            AudioResponseAppOption(
              bundleIdentifier: "com.apple.Music",
              name: "Music Player With A Fairly Long Name"),
            AudioResponseAppOption(
              bundleIdentifier: "com.google.Chrome",
              name: "Google Chrome"),
          ]
        },
        displayNameResolver: { _ in
          resolverCalls += 1
          return "Resolved"
        })

      let hosting = NSHostingController(
        rootView: AudioResponseSettingsGroup(sourceModel: model)
          .environment(controller)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared))
      hosting.sizingOptions = []
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      let narrow = NSSize(width: 460, height: 560)
      window.setContentSize(narrow)
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.06))
      hosting.view.layoutSubtreeIfNeeded()

      let least = hosting.sizeThatFits(in: NSSize(width: 0, height: narrow.height))
      XCTAssertGreaterThan(least.height, 10, "AudioResponseSettingsGroup must render content")
      XCTAssertLessThanOrEqual(
        least.width, narrow.width,
        "AudioResponseSettingsGroup must fit within the 460 pt narrow column")
      XCTAssertEqual(
        model.canonicalSelectionValue(for: controller.audioResponseSettings.targetAppBundleID),
        "com.apple.Music")
      XCTAssertEqual(resolverCalls, 0, "Running app target must not hit display-name resolver")
      XCTAssertGreaterThanOrEqual(providerCalls, 1)

      window.contentViewController = nil
      window.close()
    }
  }
}
