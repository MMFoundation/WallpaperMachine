import XCTest

@testable import WallpaperMachine

final class LockScreenContentSelectionTests: XCTestCase {
  private func scene(_ title: String, display: UInt32 = 1) -> LockScreenScene {
    LockScreenScene(
      displayID: display, title: title, projectPath: title + "/project.json", assetsPath: title,
      fps: 30, scalingMode: 3, scalingFactor: 1, paused: false)
  }

  func testIndependentContentFollowsHostModeAndReturnsToDesktopOnUnlock() throws {
    let desktop = scene("desktop")
    let lock = scene("lock")
    let saver = scene("saver")
    let configuration = LockScreenConfiguration(
      scenes: [desktop], screenSaverEnabled: true, lockScreenScenes: [lock], screenSaverScenes: [saver])
    let decoded = try JSONDecoder().decode(
      LockScreenConfiguration.self, from: JSONEncoder().encode(configuration))
    for (mode, locked, expected) in [
      ("active", false, desktop), ("active", true, lock), ("locked", false, lock),
      ("idle", false, saver), ("idle", true, saver), ("active", false, desktop),
    ] {
      let content = decoded.content(presentationMode: mode, sessionLocked: locked)
      XCTAssertEqual(decoded.scene(for: content, displayID: 1), expected)
    }
    XCTAssertNil(decoded.scene(for: .lockScreen, displayID: 2))
  }

  func testPreviousManifestLoadsWithDesktopFollowingAndWritesTheCurrentVersion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = LockScreenConfiguration(version: 2, scenes: [scene("desktop")], screenSaverEnabled: true)
    try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent(LockScreenConfiguration.fileName))
    let loaded = try LockScreenExtensionStatus.loadConfiguration(
      exchange: root, bundleURL: root, reportWriteFailure: { XCTFail($0.localizedDescription) })
    XCTAssertEqual(loaded.scenes(for: .lockScreen), legacy.scenes)
    XCTAssertEqual(loaded.scenes(for: .screenSaver), legacy.scenes)
    let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
    XCTAssertEqual(encoded["version"] as? Int, LockScreenConfiguration.supportedVersion)
    XCTAssertThrowsError(try LockScreenExtensionStatus.loadConfiguration(
      exchange: root, bundleURL: root, supportedVersion: 1, reportWriteFailure: { XCTFail($0.localizedDescription) }))
  }

  func testMissingOptionalSourcesFollowDesktopButEmptyExplicitSourcesDoNot() throws {
    let desktop = scene("desktop")
    let original = LockScreenConfiguration(scenes: [desktop], screenSaverEnabled: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LockScreenConfiguration.self, from: data)
    XCTAssertEqual(decoded.scene(for: .lockScreen, displayID: 1), desktop)
    XCTAssertEqual(decoded.scene(for: .screenSaver, displayID: 1), desktop)
    var explicit = decoded
    explicit.lockScreenScenes = []
    explicit.screenSaverScenes = []
    XCTAssertNil(explicit.scene(for: .lockScreen, displayID: 1))
    XCTAssertNil(explicit.scene(for: .screenSaver, displayID: 1))
    XCTAssertNil(explicit.scene(for: .desktop, displayID: 1))
  }

  func testSaverCanBeAcquiredWithoutDesktopAndDisabledModesDoNotLeakContent() {
    let saver = scene("saver", display: 2)
    var configuration = LockScreenConfiguration(
      scenes: [], lockScreenEnabled: false, screenSaverEnabled: true, screenSaverScenes: [saver])
    let content = configuration.content(presentationMode: "active", sessionLocked: false)
    XCTAssertEqual(configuration.scene(for: content, displayID: 2), saver)
    XCTAssertNil(configuration.scene(for: .desktop, displayID: 2))
    configuration.screenSaverEnabled = false
    XCTAssertNil(configuration.scene(for: .screenSaver, displayID: 2))
  }

  func testSaverOnAnAdditionalDisplayDoesNotRequireALockScreenSurfaceThere() {
    let desktop = scene("desktop")
    let saver = scene("saver", display: 2)
    let configuration = LockScreenConfiguration(
      scenes: [desktop], screenSaverEnabled: true, lockScreenScenes: [scene("lock")], screenSaverScenes: [saver])
    let content = configuration.content(presentationMode: "active", sessionLocked: false, displayID: 2)
    XCTAssertEqual(configuration.scene(for: content, displayID: 2), saver)
    XCTAssertNil(configuration.scene(for: .lockScreen, displayID: 2))
    XCTAssertNil(configuration.scene(for: .desktop, displayID: 2))
  }

  func testReadinessForThreePresentationsCannotOverwriteAnotherPresentation() throws {
    let files = [LockScreenContent.desktop, .lockScreen, .screenSaver].map {
      LockScreenReadiness.fileName(displayID: 1, content: $0)
    }
    XCTAssertEqual(Set(files).count, 3)
    let readiness = LockScreenReadiness(revision: "r", displayID: 1, content: .screenSaver)
    XCTAssertEqual(
      try JSONDecoder().decode(LockScreenReadiness.self, from: JSONEncoder().encode(readiness)).content,
      .screenSaver)
  }
}
