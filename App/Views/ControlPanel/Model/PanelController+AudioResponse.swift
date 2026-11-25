import AppKit
import Foundation
import Observation

/// One running or installed application offered in the audio capture source picker.
struct AudioResponseAppOption: Identifiable, Hashable, Sendable {
  let bundleIdentifier: String
  let name: String
  var id: String { bundleIdentifier }
}

/// Snapshot of the global 30 Hz audio-response tuning and per-app capture target.
struct AudioResponseSettings: Equatable, Sendable {
  static let defaultSensitivity: Float = 1.0
  static let sensitivityRange: ClosedRange<Float> = 0.25...4.0
  /// Integer slider steps in 0.05x increments (5 = 0.25x, 20 = 1.00x, 80 = 4.00x).
  static let sensitivitySliderRange: ClosedRange<Int> = 5...80

  static let defaultNoiseFloorDb: Float = -48.0
  static let noiseFloorDbRange: ClosedRange<Float> = -72.0...(-24.0)
  static let noiseFloorSliderRange: ClosedRange<Int> = -72...(-24)

  static let defaultSmoothing: Float = 0.0
  static let smoothingRange: ClosedRange<Float> = 0.0...0.90
  /// Integer slider steps in whole percent (0 = 0%, 90 = 90%).
  static let smoothingSliderRange: ClosedRange<Int> = 0...90

  let sensitivity: Float
  let noiseFloorDb: Float
  let smoothing: Float
  let targetAppBundleID: String?

  init(
    sensitivity: Float = defaultSensitivity,
    noiseFloorDb: Float = defaultNoiseFloorDb,
    smoothing: Float = defaultSmoothing,
    targetAppBundleID: String? = nil
  ) {
    self.sensitivity = Self.clampSensitivity(sensitivity)
    self.noiseFloorDb = Self.clampNoiseFloorDb(noiseFloorDb)
    self.smoothing = Self.clampSmoothing(smoothing)
    self.targetAppBundleID = Self.normalizeBundleID(targetAppBundleID)
  }

  init(snapshot: BridgeSettingsSnapshot) {
    self.init(
      sensitivity: snapshot.audioResponseSensitivity,
      noiseFloorDb: snapshot.audioResponseNoiseFloorDb,
      smoothing: snapshot.audioResponseSmoothing,
      targetAppBundleID: snapshot.audioResponseTargetApp)
  }

  var sensitivityStep: Int {
    let raw = Int((Double(sensitivity) * 20.0).rounded())
    return min(max(raw, Self.sensitivitySliderRange.lowerBound), Self.sensitivitySliderRange.upperBound)
  }

  var noiseFloorDbInt: Int {
    let raw = Int(Double(noiseFloorDb).rounded())
    return min(max(raw, Self.noiseFloorSliderRange.lowerBound), Self.noiseFloorSliderRange.upperBound)
  }

  var smoothingPercent: Int {
    let raw = Int((Double(smoothing) * 100.0).rounded())
    return min(max(raw, Self.smoothingSliderRange.lowerBound), Self.smoothingSliderRange.upperBound)
  }

  var isDefault: Bool {
    abs(sensitivity - Self.defaultSensitivity) < 0.001
      && abs(noiseFloorDb - Self.defaultNoiseFloorDb) < 0.01
      && abs(smoothing - Self.defaultSmoothing) < 0.001
      && targetAppBundleID == nil
  }

  static func clampSensitivity(_ value: Float) -> Float {
    guard value.isFinite else { return defaultSensitivity }
    return min(max(value, sensitivityRange.lowerBound), sensitivityRange.upperBound)
  }

  static func clampNoiseFloorDb(_ value: Float) -> Float {
    guard value.isFinite else { return defaultNoiseFloorDb }
    return min(max(value, noiseFloorDbRange.lowerBound), noiseFloorDbRange.upperBound)
  }

  static func clampSmoothing(_ value: Float) -> Float {
    guard value.isFinite else { return defaultSmoothing }
    return min(max(value, smoothingRange.lowerBound), smoothingRange.upperBound)
  }

  static func normalizeBundleID(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  static func sensitivity(fromStep step: Int) -> Float {
    let clamped = min(max(step, sensitivitySliderRange.lowerBound), sensitivitySliderRange.upperBound)
    return Float(clamped) / 20.0
  }

  /// Numeric multiplier readout (`"1.00×"`), identical across languages.
  static func sensitivityReadout(step: Int) -> String {
    let value = Double(sensitivity(fromStep: step))
    return String(format: "%.2f×", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  /// Decibel readout (`"-48 dB"`), using the universal SI symbol.
  static func noiseFloorReadout(db: Int) -> String {
    let clamped = min(max(db, noiseFloorSliderRange.lowerBound), noiseFloorSliderRange.upperBound)
    return "\(clamped) dB"
  }

  /// Percentage readout (`"0%"`), identical across languages.
  static func smoothingReadout(percent: Int) -> String {
    let clamped = min(max(percent, smoothingSliderRange.lowerBound), smoothingSliderRange.upperBound)
    return "\(clamped)%"
  }

  /// Running regular applications that can be selected as a per-app capture source, excluding
  /// this app itself.
  static func runningCandidateApps(
    excludingOwnBundleID ownBundleID: String? = Bundle.main.bundleIdentifier,
    from applications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
  ) -> [AudioResponseAppOption] {
    let entries: [(bundleIdentifier: String, name: String?)] = applications.compactMap { app in
      guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else {
        return nil
      }
      return (bundleIdentifier: bundleID, name: app.localizedName)
    }
    return candidateApps(from: entries, excludingOwnBundleID: ownBundleID)
  }

  /// Deduplicates, excludes this app, and sorts candidate applications by display name.
  static func candidateApps(
    from entries: [(bundleIdentifier: String, name: String?)],
    excludingOwnBundleID ownBundleID: String?
  ) -> [AudioResponseAppOption] {
    let excluded = ownBundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var seen = Set<String>()
    var options: [AudioResponseAppOption] = []
    for entry in entries {
      guard let bundleID = normalizeBundleID(entry.bundleIdentifier) else { continue }
      let lowered = bundleID.lowercased()
      if let excluded, lowered == excluded { continue }
      guard seen.insert(lowered).inserted else { continue }
      let rawName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayName = (rawName?.isEmpty == false ? rawName! : bundleID)
      options.append(AudioResponseAppOption(bundleIdentifier: bundleID, name: displayName))
    }
    return options.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Returns whether `bundleIdentifier` identifies this app itself (case-insensitively).
  static func isOwnBundleID(
    _ bundleIdentifier: String?,
    ownBundleID: String? = Bundle.main.bundleIdentifier
  ) -> Bool {
    guard let normalized = normalizeBundleID(bundleIdentifier),
      let own = normalizeBundleID(ownBundleID)
    else {
      return false
    }
    return normalized.caseInsensitiveCompare(own) == .orderedSame
  }

  /// Resolves an installed application's localized display name via Launch Services, or `nil`
  /// when no application bundle is registered for `bundleIdentifier`.
  ///
  /// Performs Launch Services IPC and filesystem metadata reads; call only outside SwiftUI
  /// `View.body` (for example through `AudioResponseSourceModel`).
  static func installedAppDisplayName(
    for bundleIdentifier: String,
    urlLookup: (String) -> URL? = {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }
  ) -> String? {
    guard let url = urlLookup(bundleIdentifier) else { return nil }
    var name = FileManager.default.displayName(atPath: url.path)
    if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
    return name.isEmpty ? nil : name
  }

  /// Resolves a human-readable application name for `bundleIdentifier`, checking running apps
  /// first, then Launch Services, and falling back to the raw identifier.
  ///
  /// Call only outside SwiftUI `View.body`; views read cached names through
  /// `AudioResponseSourceModel`.
  static func appDisplayName(
    for bundleIdentifier: String,
    runningApps: [AudioResponseAppOption],
    urlLookup: (String) -> URL? = {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }
  ) -> String {
    if let running = runningApps.first(where: {
      $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }) {
      return running.name
    }
    return installedAppDisplayName(for: bundleIdentifier, urlLookup: urlLookup) ?? bundleIdentifier
  }
}

/// Lazily refreshed, cached running-application list and installed-app display names for the
/// audio capture source picker.
///
/// All Launch Services IPC (`NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`,
/// `NSWorkspace.shared.runningApplications`) and disk metadata reads
/// (`FileManager.default.displayName(atPath:)`) happen strictly outside SwiftUI `View.body`
/// and use injectable providers so render and unit tests never hit live `NSWorkspace.shared`.
@MainActor
@Observable
final class AudioResponseSourceModel {
  typealias RunningAppsProvider = @MainActor () -> [AudioResponseAppOption]
  typealias DisplayNameResolver = @MainActor (String) -> String?

  private(set) var runningApps: [AudioResponseAppOption] = []
  private(set) var resolvedDisplayNames: [String: String] = [:]

  @ObservationIgnored private let runningAppsProvider: RunningAppsProvider
  @ObservationIgnored private let displayNameResolver: DisplayNameResolver

  init(
    runningAppsProvider: @escaping RunningAppsProvider = {
      AudioResponseSettings.runningCandidateApps()
    },
    displayNameResolver: @escaping DisplayNameResolver = { bundleIdentifier in
      AudioResponseSettings.installedAppDisplayName(for: bundleIdentifier)
    }
  ) {
    self.runningAppsProvider = runningAppsProvider
    self.displayNameResolver = displayNameResolver
  }

  /// Refreshes running candidate apps and seeds cached display names from running entries.
  /// Call only outside SwiftUI `View.body`.
  func refreshRunningApps() {
    let apps = runningAppsProvider()
    runningApps = apps
    for app in apps {
      resolvedDisplayNames[Self.cacheKey(app.bundleIdentifier)] = app.name
    }
  }

  /// Lazily resolves and caches the display name of a configured target bundle ID when it is
  /// not running and not yet cached (or when `force` is true). Call only outside `View.body`.
  func resolveDisplayNameIfNeeded(for bundleIdentifier: String?, force: Bool = false) {
    guard let normalized = AudioResponseSettings.normalizeBundleID(bundleIdentifier) else {
      return
    }
    let key = Self.cacheKey(normalized)
    if let running = runningApp(matching: normalized) {
      resolvedDisplayNames[key] = running.name
      return
    }
    guard force || resolvedDisplayNames[key] == nil else { return }
    if let resolved = displayNameResolver(normalized), !resolved.isEmpty {
      resolvedDisplayNames[key] = resolved
    }
  }

  /// Case-insensitively finds the matching running app option. Pure in-memory read.
  func runningApp(matching bundleIdentifier: String) -> AudioResponseAppOption? {
    runningApps.first {
      $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }
  }

  /// Pure in-memory check suitable for SwiftUI `View.body`.
  func isRunning(_ bundleIdentifier: String) -> Bool {
    runningApp(matching: bundleIdentifier) != nil
  }

  /// Canonicalizes `savedTarget` to match the exact casing of the matching running app option
  /// so SwiftUI `Picker(selection:)` tag comparison never leaves the menu blank when config
  /// casing differs (for example `com.apple.music` vs `com.apple.Music`). Pure in-memory read.
  func canonicalSelectionValue(for savedTarget: String?) -> String {
    guard let normalized = AudioResponseSettings.normalizeBundleID(savedTarget) else {
      return ""
    }
    return runningApp(matching: normalized)?.bundleIdentifier ?? normalized
  }

  /// Synchronous display name lookup backed strictly by cached state, falling back to
  /// `bundleIdentifier` with zero IPC or disk I/O. Safe to call in SwiftUI `View.body`.
  func displayName(for bundleIdentifier: String) -> String {
    if let running = runningApp(matching: bundleIdentifier) {
      return running.name
    }
    return resolvedDisplayNames[Self.cacheKey(bundleIdentifier)] ?? bundleIdentifier
  }

  /// Builds `SettingsMenuControl` options purely from cached state. Safe in SwiftUI `View.body`.
  func sourceOptions(
    savedTarget: String?,
    allAppsTitle: String
  ) -> [SettingsMenuOption<String>] {
    var options = [SettingsMenuOption(value: "", title: allAppsTitle)]
    options.append(
      contentsOf: runningApps.map {
        SettingsMenuOption(value: $0.bundleIdentifier, title: $0.name)
      })
    if let normalized = AudioResponseSettings.normalizeBundleID(savedTarget),
      runningApp(matching: normalized) == nil
    {
      options.append(
        SettingsMenuOption(value: normalized, title: displayName(for: normalized)))
    }
    return options
  }

  private static func cacheKey(_ bundleIdentifier: String) -> String {
    bundleIdentifier.lowercased()
  }
}

/// Typed `PanelController` actions for Settings › Playback & Power › Audio response.
extension PanelController {
  var audioResponseSettings: AudioResponseSettings {
    AudioResponseSettings(snapshot: store.settingsSnapshot)
  }

  func setAudioResponseSensitivity(_ sensitivity: Float) async throws {
    guard sensitivity.isFinite else { throw InvalidControlValue() }
    let clamped = AudioResponseSettings.clampSensitivity(sensitivity)
    try await run(.queued) {
      let current = audioResponseSettings
      try await store.setAudioResponseTuningAsync(
        sensitivity: clamped,
        noiseFloorDb: current.noiseFloorDb,
        smoothing: current.smoothing)
    }
  }

  func setAudioResponseNoiseFloorDb(_ noiseFloorDb: Float) async throws {
    guard noiseFloorDb.isFinite else { throw InvalidControlValue() }
    let clamped = AudioResponseSettings.clampNoiseFloorDb(noiseFloorDb)
    try await run(.queued) {
      let current = audioResponseSettings
      try await store.setAudioResponseTuningAsync(
        sensitivity: current.sensitivity,
        noiseFloorDb: clamped,
        smoothing: current.smoothing)
    }
  }

  func setAudioResponseSmoothing(_ smoothing: Float) async throws {
    guard smoothing.isFinite else { throw InvalidControlValue() }
    let clamped = AudioResponseSettings.clampSmoothing(smoothing)
    try await run(.queued) {
      let current = audioResponseSettings
      try await store.setAudioResponseTuningAsync(
        sensitivity: current.sensitivity,
        noiseFloorDb: current.noiseFloorDb,
        smoothing: clamped)
    }
  }

  func setAudioResponseTargetApp(_ bundleID: String?) async throws {
    let normalized = AudioResponseSettings.normalizeBundleID(bundleID)
    if AudioResponseSettings.isOwnBundleID(normalized) {
      throw WallpaperActionError(
        message: L("WallpaperMachine can’t be used as an audio capture source. Choose another app."))
    }
    try await run(.queued) {
      try await store.setAudioResponseTargetAppAsync(normalized)
    }
  }

  /// Opens the application chooser (or uses the `chooseApplication` test seam) and sets that
  /// app as the per-app audio capture target.
  func chooseAudioResponseTargetApp() async throws {
    errors.clearAction()
    guard let url = await chooseApplicationURL() else { return }
    try await run(.queued) {
      guard let bundleID = Bundle(url: url)?.bundleIdentifier,
        let normalized = AudioResponseSettings.normalizeBundleID(bundleID)
      else {
        throw WallpaperActionError(
          message: L("This app has no bundle identifier, so it can’t be used as an audio capture source."))
      }
      if AudioResponseSettings.isOwnBundleID(normalized) {
        throw WallpaperActionError(
          message: L("WallpaperMachine can’t be used as an audio capture source. Choose another app."))
      }
      try await store.setAudioResponseTargetAppAsync(normalized)
    }
  }

  /// Restores sensitivity, noise floor, smoothing, and audio capture source to their defaults.
  func resetAudioResponseSettings() async throws {
    try await run(.queued) {
      try await store.setAudioResponseTuningAsync(
        sensitivity: AudioResponseSettings.defaultSensitivity,
        noiseFloorDb: AudioResponseSettings.defaultNoiseFloorDb,
        smoothing: AudioResponseSettings.defaultSmoothing)
      try await store.setAudioResponseTargetAppAsync(nil)
    }
  }
}
