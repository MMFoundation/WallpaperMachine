import CoreGraphics
import Foundation
import XCTest

@testable import WallpaperMachine

final class LockScreenPerDisplayAndPlaylistTests: XCTestCase {
  private var root: URL!
  private var home: URL!
  private var defaults: UserDefaults!
  private var timers: [Timer] = []
  private var previousHome: String?

  private var storeURL: URL { root.appendingPathComponent("Index.plist") }
  private var journalURL: URL { root.appendingPathComponent("journal.plist") }
  private var exchangeURL: URL { root.appendingPathComponent("Exchange") }
  private var projectsRoot: URL { root.appendingPathComponent("Projects") }

  override func setUpWithError() throws {
    defaults = try TemporaryDefaults.make(for: self).defaults
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lock-screen-per-display-tests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("Home", isDirectory: true)
    try FileManager.default.createDirectory(at: exchangeURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    try writeStore(storeFixture())
  }

  override func tearDownWithError() throws {
    timers.forEach { $0.invalidate() }
    timers.removeAll()
    try? FileManager.default.removeItem(at: root)
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
  }

  @MainActor
  private func scheduleMonitor(_ callback: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: 2, repeats: true) { _ in
      MainActor.assumeIsolated { callback() }
    }
    timers.append(timer)
    return timer
  }

  private func makeProject(_ id: String) throws -> URL {
    let dir = projectsRoot.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"type":"video","title":"\#(id)","file":"clip.mp4"}"#.utf8).write(
      to: dir.appendingPathComponent("project.json"))
    try Data([0x00, 0x01, UInt8(id.utf8.first ?? 0)]).write(
      to: dir.appendingPathComponent("clip.mp4"))
    return dir
  }

  private func makeScene(displayID: UInt32, wallpaperID: String, title: String? = nil) throws -> BridgeLockScreenScene {
    let dir = try makeProject(wallpaperID)
    return BridgeLockScreenScene(
      displayId: displayID,
      wallpaperId: wallpaperID,
      title: title ?? wallpaperID,
      projectPath: dir.appendingPathComponent("project.json").path,
      assetsPath: dir.path,
      fps: 30,
      scalingMode: .fill,
      scalingFactor: 1,
      framing: .centered,
      propertiesJson: nil,
      paused: false,
      engineOptions: nil,
      sceneQuality: nil,
      borderColor: nil)
  }

  private func choice(_ name: String) -> [String: Any] {
    [
      "Content": [
        "Choices": [["Provider": name, "Configuration": Data(name.utf8), "Files": [String]()]],
        "Shuffle": "$null",
      ],
      "LastSet": Date(timeIntervalSince1970: 1),
    ]
  }

  private func node(_ name: String) -> [String: Any] {
    [
      "Desktop": choice(name + "-desktop"),
      "Idle": choice(name + "-idle"),
      "Type": "individual",
    ]
  }

  private func storeFixture() -> [String: Any] {
    [
      "AllSpacesAndDisplays": node("global"),
      "SystemDefault": node("system"),
      "Displays": ["one": node("display-one"), "two": node("display-two")],
      "Spaces": [
        "space-a": [
          "Default": node("default-a"),
          "Displays": ["one": node("space-one"), "two": node("space-two")],
        ],
      ],
    ]
  }

  private func writeStore(_ value: [String: Any]) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(
      to: storeURL, options: .atomic)
  }

  private func acknowledgeLockScreenFrames(in exchange: URL, displays: [UInt32]) throws {
    let file = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
    let config = try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(contentsOf: file))
    for display in displays {
      let readiness = LockScreenReadiness(
        revision: config.revision, displayID: display, error: nil, held: nil, processID: nil, content: .desktop)
      try JSONEncoder().encode(readiness).write(
        to: exchange.appendingPathComponent(LockScreenReadiness.fileName(displayID: display, content: .desktop)))
    }
  }

  @MainActor
  private func waitFor(_ label: String, timeout: TimeInterval = 5, condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(condition(), "Timed out waiting for \(label)")
  }

  // MARK: - Per-display LockScreenConfiguration generation

  @MainActor
  func testPerDisplayLockScreenAndScreenSaverGenerateDistinctScenesAndPersist() async throws {
    let desk1 = try makeScene(displayID: 1, wallpaperID: "desk-1", title: "Desktop 1")
    let desk2 = try makeScene(displayID: 2, wallpaperID: "desk-2", title: "Desktop 2")
    let lock2_d1 = try makeScene(displayID: 1, wallpaperID: "lock-2", title: "Lock 2")
    let lock2_d2 = try makeScene(displayID: 2, wallpaperID: "lock-2", title: "Lock 2")
    let saver1_d1 = try makeScene(displayID: 1, wallpaperID: "saver-1", title: "Saver 1")
    let saver1_d2 = try makeScene(displayID: 2, wallpaperID: "saver-1", title: "Saver 1")
    let saver2_d1 = try makeScene(displayID: 1, wallpaperID: "saver-2", title: "Saver 2")
    let saver2_d2 = try makeScene(displayID: 2, wallpaperID: "saver-2", title: "Saver 2")

    let byWallpaper: [String: [BridgeLockScreenScene]] = [
      "lock-2": [lock2_d1, lock2_d2],
      "saver-1": [saver1_d1, saver1_d2],
      "saver-2": [saver2_d1, saver2_d2],
    ]
    let uuids: [UInt32: String] = [1: "one", 2: "two"]

    let service = LockScreenWallpaperService(
      prepareExtension: {},
      notifyConfigurationChanged: { [exchangeURL] in
        try? self.acknowledgeLockScreenFrames(in: exchangeURL, displays: [1, 2])
      },
      scenes: { [desk1, desk2] },
      wallpaperScenes: { id in
        guard let matched = byWallpaper[id] else { throw CocoaError(.fileReadNoSuchFile) }
        return matched
      },
      selection: LockScreenWallpaperSelection(storeURL: storeURL, journalURL: journalURL, reload: {}),
      exchange: exchangeURL,
      defaults: defaults,
      scheduleMonitor: scheduleMonitor,
      displayUUID: { uuids[$0] },
      onlineDisplayIDs: { [1, 2] },
      renderScale: { 0.75 })

    // Display 1 follows desktop on lock screen; Display 2 shows independent lock-2.
    service.setUsesPerDisplay(true, lockScreen: true)
    service.setSource(.sameAsDesktop, lockScreen: true, displayUUID: "one")
    service.setSource(.wallpaper("lock-2"), lockScreen: true, displayUUID: "two")

    // Display 1 shows saver-1; Display 2 shows saver-2.
    service.setUsesPerDisplay(true, lockScreen: false)
    service.setSource(.wallpaper("saver-1"), lockScreen: false, displayUUID: "one")
    service.setSource(.wallpaper("saver-2"), lockScreen: false, displayUUID: "two")

    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("per-display publication") { !service.isBusy }

    XCTAssertTrue(service.isEnabled, service.errorMessage ?? service.status)
    XCTAssertTrue(service.screenSaverEnabled, service.screenSaverError ?? service.screenSaverStatus)

    let configFile = exchangeURL.appendingPathComponent(LockScreenConfiguration.fileName)
    let config = try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(contentsOf: configFile))

    XCTAssertEqual(config.scene(for: .desktop, displayID: 1)?.title, "Desktop 1")
    XCTAssertEqual(config.scene(for: .desktop, displayID: 2)?.title, "Desktop 2")
    XCTAssertEqual(config.scene(for: .lockScreen, displayID: 1)?.title, "Desktop 1")
    XCTAssertEqual(config.scene(for: .lockScreen, displayID: 2)?.title, "Lock 2")
    XCTAssertEqual(config.scene(for: .screenSaver, displayID: 1)?.title, "Saver 1")
    XCTAssertEqual(config.scene(for: .screenSaver, displayID: 2)?.title, "Saver 2")

    // Verify only renderScale pass-through is preserved; Display 2D scene resolution is never passed.
    let encodedJSON = try XCTUnwrap(
      String(data: Data(contentsOf: configFile), encoding: .utf8))
    XCTAssertFalse(encodedJSON.contains("sceneResolution"))

    try await service.shutdown()

    // Restart over the same defaults: per-display choices survive reload.
    let restarted = LockScreenWallpaperService(
      prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [desk1, desk2] },
      selection: LockScreenWallpaperSelection(storeURL: storeURL, journalURL: journalURL, reload: {}),
      exchange: exchangeURL, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { uuids[$0] })
    XCTAssertTrue(restarted.usesPerDisplaySources(lockScreen: true))
    XCTAssertEqual(restarted.source(lockScreen: true, displayUUID: "one"), .sameAsDesktop)
    XCTAssertEqual(restarted.source(lockScreen: true, displayUUID: "two"), .wallpaper("lock-2"))
    XCTAssertTrue(restarted.usesPerDisplaySources(lockScreen: false))
    XCTAssertEqual(restarted.source(lockScreen: false, displayUUID: "one"), .wallpaper("saver-1"))
    XCTAssertEqual(restarted.source(lockScreen: false, displayUUID: "two"), .wallpaper("saver-2"))
  }

  @MainActor
  func testPerDisplayScreenSaverIgnoresDisconnectedDisplayAndWorksWithoutDesktop() async throws {
    let saver1 = try makeScene(displayID: 1, wallpaperID: "saver-1", title: "Saver 1")
    let service = LockScreenWallpaperService(
      prepareExtension: {},
      notifyConfigurationChanged: {},
      scenes: { [] },
      wallpaperScenes: { id in
        if id == "saver-1" { return [saver1] }
        throw CocoaError(.fileReadNoSuchFile)
      },
      selection: LockScreenWallpaperSelection(storeURL: storeURL, journalURL: journalURL, reload: {}),
      exchange: exchangeURL,
      defaults: defaults,
      scheduleMonitor: scheduleMonitor,
      displayUUID: { $0 == 1 ? "one" : nil },
      onlineDisplayIDs: { [1] })

    service.setUsesPerDisplay(true, lockScreen: false)
    service.setSource(.wallpaper("saver-1"), lockScreen: false, displayUUID: "one")
    service.setSource(.wallpaper("deleted-on-unplugged"), lockScreen: false, displayUUID: "unplugged")
    service.setScreenSaverEnabled(true)
    await waitFor("independent per-display saver") { !service.isBusy }

    XCTAssertTrue(service.screenSaverEnabled, service.screenSaverError ?? service.screenSaverStatus)
    let configFile = exchangeURL.appendingPathComponent(LockScreenConfiguration.fileName)
    let config = try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(contentsOf: configFile))
    XCTAssertEqual(config.scenes(for: .screenSaver).map(\.title), ["Saver 1"])
    try await service.shutdown()
  }

  // MARK: - Saved Playlist binding & low-priority unlock / screensaver-end rotation

  @MainActor
  func testSavedPlaylistRotatesAtLowPriorityAfterUnlockAndScreenSaverStopWithoutBlocking() async throws {
    let playlistStore = PlaylistStore(defaults: defaults)
    playlistStore.update("primary") { playlist in
      playlist.mode = .rotate
      playlist.source = .list
      playlist.order = .sequential
      playlist.wallpaperIDs = ["wp-1", "wp-2", "wp-3"]
    }
    let lockPlan = try playlistStore.savePlan(from: "primary", name: "Lock Rotation")

    playlistStore.update("primary") { playlist in
      playlist.mode = .rotate
      playlist.source = .list
      playlist.order = .sequential
      playlist.wallpaperIDs = ["sv-1", "sv-2"]
    }
    let saverPlan = try playlistStore.savePlan(from: "primary", name: "Saver Rotation")

    let desk = try makeScene(displayID: 1, wallpaperID: "desk", title: "Desktop")
    let scenesByID: [String: BridgeLockScreenScene] = [
      "wp-1": try makeScene(displayID: 1, wallpaperID: "wp-1", title: "Lock WP 1"),
      "wp-2": try makeScene(displayID: 1, wallpaperID: "wp-2", title: "Lock WP 2"),
      "wp-3": try makeScene(displayID: 1, wallpaperID: "wp-3", title: "Lock WP 3"),
      "sv-1": try makeScene(displayID: 1, wallpaperID: "sv-1", title: "Saver SV 1"),
      "sv-2": try makeScene(displayID: 1, wallpaperID: "sv-2", title: "Saver SV 2"),
    ]
    let resolver = LockScreenPlaylistResolver(
      planProvider: { playlistStore.plan(id: $0) },
      collectionProvider: { _ in [] },
      libraryProvider: {
        ["wp-1", "wp-2", "wp-3", "sv-1", "sv-2"].map {
          LockScreenLibraryEntry(id: $0, kind: .video, supported: true)
        }
      },
      favoritesProvider: { [] },
      metadataProvider: { [:] })

    let center = NotificationCenter()
    let gate = RotationTestGate()

    let service = LockScreenWallpaperService(
      prepareExtension: {},
      notifyConfigurationChanged: { [exchangeURL] in
        try? self.acknowledgeLockScreenFrames(in: exchangeURL, displays: [1])
      },
      scenes: { [desk] },
      wallpaperScenes: { id in
        guard let scene = scenesByID[id] else { throw CocoaError(.fileReadNoSuchFile) }
        return [scene]
      },
      selection: LockScreenWallpaperSelection(storeURL: storeURL, journalURL: journalURL, reload: {}),
      exchange: exchangeURL,
      defaults: defaults,
      scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" },
      onlineDisplayIDs: { [1] },
      playlistResolver: resolver,
      distributedCenter: center,
      rotationSettleDelay: .milliseconds(50),
      rotationSleep: { duration in
        try await gate.wait(duration: duration)
      })

    try await service.start()
    service.setSource(.playlist(lockPlan.id), lockScreen: true)
    service.setSource(.playlist(saverPlan.id), lockScreen: false)
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("initial playlist activation") { !service.isBusy }

    func currentConfig() throws -> LockScreenConfiguration {
      try JSONDecoder().decode(
        LockScreenConfiguration.self,
        from: Data(contentsOf: exchangeURL.appendingPathComponent(LockScreenConfiguration.fileName)))
    }

    XCTAssertEqual(try currentConfig().scene(for: .lockScreen, displayID: 1)?.title, "Lock WP 1")
    XCTAssertEqual(try currentConfig().scene(for: .screenSaver, displayID: 1)?.title, "Saver SV 1")

    // Routine refresh must NOT advance bound playlists.
    service.refresh()
    await waitFor("routine refresh") { !service.isBusy }
    XCTAssertEqual(try currentConfig().scene(for: .lockScreen, displayID: 1)?.title, "Lock WP 1")

    // Burst unlock notifications: posting returns immediately without publishing until settle debounce completes,
    // and multiple rapid unlock notices coalesce into a single advance.
    center.post(name: LockScreenWallpaperService.screenUnlockedNotification, object: nil)
    center.post(name: LockScreenWallpaperService.screenUnlockedNotification, object: nil)
    await waitFor("unlock rotation scheduled") { gate.pendingCount >= 1 }
    // Still WP 1 while settle debounce holds off publication on the unlock critical path!
    XCTAssertEqual(try currentConfig().scene(for: .lockScreen, displayID: 1)?.title, "Lock WP 1")
    XCTAssertEqual(gate.recordedPriorities.last, TaskPriority.utility)

    gate.releaseAll()
    await waitFor("lock screen rotated to wp-2") {
      (try? currentConfig().scene(for: .lockScreen, displayID: 1)?.title) == "Lock WP 2" && !service.isBusy
    }
    // Screen saver did not advance on unlock.
    XCTAssertEqual(try currentConfig().scene(for: .screenSaver, displayID: 1)?.title, "Saver SV 1")

    // Screensaver stop advances screen saver playlist without disturbing lock screen.
    center.post(name: LockScreenWallpaperService.screenSaverDidStopNotification, object: nil)
    await waitFor("screensaver rotation scheduled") { gate.pendingCount >= 1 }
    XCTAssertEqual(try currentConfig().scene(for: .screenSaver, displayID: 1)?.title, "Saver SV 1")

    gate.releaseAll()
    await waitFor("screen saver rotated to sv-2") {
      (try? currentConfig().scene(for: .screenSaver, displayID: 1)?.title) == "Saver SV 2" && !service.isBusy
    }
    XCTAssertEqual(try currentConfig().scene(for: .lockScreen, displayID: 1)?.title, "Lock WP 2")

    try await service.shutdown()
  }

  // MARK: - Backup allowlist validation

  func testBackupPreferencesAllowlistValidatesNewLockScreenSourceKeys() throws {
    XCTAssertTrue(
      WallpaperBackupPreferences.allowedKeys.contains(LockScreenWallpaperService.lockScreenSourcesPreference))
    XCTAssertTrue(
      WallpaperBackupPreferences.allowedKeys.contains(LockScreenWallpaperService.screenSaverSourcesPreference))

    let valid = LockScreenModeSources(
      allDisplays: .playlist("plan-1"),
      usesPerDisplay: true,
      perDisplay: ["UUID-1": .wallpaper("123456"), "UUID-2": .sameAsDesktop])
    let validData = try JSONEncoder().encode(valid)
    XCTAssertNoThrow(
      try WallpaperBackupPreferences.validate(
        validData, forKey: LockScreenWallpaperService.lockScreenSourcesPreference))
    XCTAssertNoThrow(
      try WallpaperBackupPreferences.validate(
        validData, forKey: LockScreenWallpaperService.screenSaverSourcesPreference))

    // Reject unknown keys, empty IDs, NUL bytes, and oversized display maps.
    XCTAssertThrowsError(
      try WallpaperBackupPreferences.validate(
        Data(#"{"allDisplays":{"kind":"sameAsDesktop"},"extra":true}"#.utf8),
        forKey: LockScreenWallpaperService.lockScreenSourcesPreference))
    XCTAssertThrowsError(
      try WallpaperBackupPreferences.validate(
        Data(#"{"allDisplays":{"kind":"wallpaper","id":""}}"#.utf8),
        forKey: LockScreenWallpaperService.lockScreenSourcesPreference))
    let tooMany = Dictionary(uniqueKeysWithValues: (0..<65).map { ("UUID-\($0)", LockScreenSourceChoice.sameAsDesktop) })
    let oversizedData = try JSONEncoder().encode(LockScreenModeSources(usesPerDisplay: true, perDisplay: tooMany))
    XCTAssertThrowsError(
      try WallpaperBackupPreferences.validate(
        oversizedData, forKey: LockScreenWallpaperService.screenSaverSourcesPreference))
  }
}

/// Thread-safe async gate verifying that rotation waits at `.utility` priority off the unlock path.
private final class RotationTestGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var cancelledIDs: Set<UUID> = []
  private var _recordedPriorities: [TaskPriority] = []

  var pendingCount: Int { lock.withLock { continuations.count } }
  var recordedPriorities: [TaskPriority] { lock.withLock { _recordedPriorities } }

  func wait(duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let alreadyCancelled: Bool = lock.withLock {
          if cancelledIDs.remove(id) != nil || Task.isCancelled {
            return true
          }
          _recordedPriorities.append(Task.currentPriority)
          continuations[id] = continuation
          return false
        }
        if alreadyCancelled {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let pending: CheckedContinuation<Void, Error>? = lock.withLock {
        if let existing = continuations.removeValue(forKey: id) {
          return existing
        }
        cancelledIDs.insert(id)
        return nil
      }
      pending?.resume(throwing: CancellationError())
    }
  }

  func releaseAll() {
    let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
      let items = Array(continuations.values)
      continuations.removeAll()
      return items
    }
    for item in pending { item.resume() }
  }
}

@MainActor
final class LockScreenBoundariesTests: PanelTestCase {
  func testSpacesExclusivityAndMacOS26GateRemainIntactWithPerDisplayAndPlaylistSources() async throws {
    try await withTwoDisplayPanel { panel, _ in
      // 1. Simulate macOS < 26 / unavailable service (lockScreenWallpaper == nil)
      XCTAssertNil(panel.store.lockScreenWallpaper)
      let unavailableState = LockScreenState.make(.lockScreen, service: nil)
      XCTAssertFalse(unavailableState.isAvailable)
      do {
        try await panel.controller.setNativeWallpaperUsesPerDisplay(true, for: .lockScreen)
        XCTFail("Expected unavailable service error")
      } catch {
        XCTAssertTrue(error is WallpaperActionError)
      }

      // 2. With service present, Animated Lock Screen remains mutually exclusive with Spaces.
      try await withNativeWallpaperService(panel) { service in
        try panel.automations.update("primary") { $0.mode = .spaces }
        panel.playlists.update("primary") { playlist in
          playlist.mode = .rotate
          playlist.source = .list
          playlist.wallpaperIDs = ["a", "b"]
        }
        let plan = try panel.playlists.savePlan(from: "primary", name: "Lock Plan")
        try await panel.controller.setNativeWallpaperUsesPerDisplay(true, for: .lockScreen)
        try await panel.controller.setNativeWallpaperSource(.playlist(plan.id), for: .lockScreen, displayUUID: "one")
        XCTAssertEqual(
          panel.controller.nativeWallpaperSource(.lockScreen, displayUUID: "one").playlistTitle,
          "Lock Plan")

        do {
          try await panel.controller.setLockScreenEnabled(true)
          XCTFail("Animated Lock Screen must remain mutually exclusive with Spaces")
        } catch {
          XCTAssertTrue(error is WallpaperActionError)
        }
        XCTAssertFalse(service.isRequested)
      }
    }
  }
}
