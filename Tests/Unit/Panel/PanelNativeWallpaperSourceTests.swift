import XCTest

@testable import WallpaperMachine

@MainActor
final class PanelNativeWallpaperSourceTests: PanelTestCase {
  func testSourcesDefaultToDesktopAndChangeIndependentlyWithoutApplyingToDesktop() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      try await withNativeWallpaperService(panel) { service in
        let controller = panel.controller
        let desktopAssignments = bridge.assignments
        for kind in [LockScreenState.Kind.lockScreen, .screenSaver] {
          XCTAssertNil(controller.nativeWallpaperSource(kind).wallpaperID)
          XCTAssertTrue(controller.nativeWallpaperSource(kind).isEnabled)
        }

        try await controller.setNativeWallpaperSource("c", for: .lockScreen)
        XCTAssertEqual(service.lockScreenWallpaperID, "c")
        XCTAssertNil(service.screenSaverWallpaperID)
        try await controller.setNativeWallpaperSource("b", for: .screenSaver)
        XCTAssertEqual(service.lockScreenWallpaperID, "c")
        XCTAssertEqual(service.screenSaverWallpaperID, "b")

        try await controller.setNativeWallpaperSource(nil, for: .lockScreen)
        XCTAssertNil(service.lockScreenWallpaperID)
        XCTAssertEqual(service.screenSaverWallpaperID, "b")
        try await controller.setNativeWallpaperSource("a", for: .lockScreen)
        try await controller.setNativeWallpaperSource(nil, for: .screenSaver)
        XCTAssertEqual(service.lockScreenWallpaperID, "a")
        XCTAssertNil(service.screenSaverWallpaperID)
        XCTAssertFalse(service.isRequested)
        XCTAssertFalse(service.screenSaverRequested)
        XCTAssertEqual(bridge.assignments, desktopAssignments)
        XCTAssertTrue(bridge.events.isEmpty)
      }
    }
  }

  func testMissingSelectionsStayVisibleAndUninstalledOrUnsupportedChoicesAreRefused() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("chosen", title: "Ocean <img src=x>"),
        OrganizationFixtures.wallpaper("unsupported", supported: false),
      ]
      try await withNativeWallpaperService(panel) { service in
        let controller = panel.controller
        try await controller.setNativeWallpaperSource("chosen", for: .lockScreen)
        try await controller.setNativeWallpaperSource("chosen", for: .screenSaver)
        XCTAssertEqual(controller.nativeWallpaperSource(.lockScreen).wallpaperTitle, "Ocean <img src=x>")
        panel.store.librarySnapshot.wallpapers.removeAll { $0.id == "chosen" }

        for kind in [LockScreenState.Kind.lockScreen, .screenSaver] {
          let source = controller.nativeWallpaperSource(kind)
          XCTAssertEqual(source.wallpaperID, "chosen")
          XCTAssertTrue(source.isUnavailable)
          XCTAssertTrue(source.title.contains("chosen"))
          for id in ["gone", "unsupported", ""] {
            do {
              try await controller.setNativeWallpaperSource(id, for: kind)
              XCTFail("A source must be a supported library wallpaper")
            } catch { XCTAssertTrue(error is InvalidControlValue) }
          }
        }
        XCTAssertEqual(service.lockScreenWallpaperID, "chosen")
        XCTAssertEqual(service.screenSaverWallpaperID, "chosen")
        try await controller.setNativeWallpaperSource(nil, for: .lockScreen)
        XCTAssertNil(service.lockScreenWallpaperID)
        XCTAssertEqual(service.screenSaverWallpaperID, "chosen")
      }
    }
  }

  func testSourceActionsRefuseAnUnavailableService() async throws {
    try await withRecordingPanel { panel, _ in
      for kind in [LockScreenState.Kind.lockScreen, .screenSaver] {
        XCTAssertFalse(panel.controller.nativeWallpaperSource(kind).isEnabled)
        do {
          try await panel.controller.setNativeWallpaperSource(nil, for: kind)
          XCTFail("No service can save this source")
        } catch { XCTAssertTrue(error is WallpaperActionError) }
      }
    }
  }

  func testBothSourceControlsWaitForTheServiceButCanBeChangedWhileTheirSwitchesAreOff() async throws {
    try await withRecordingPanel { panel, _ in
      try await withNativeWallpaperService(panel) { service in
        for kind in [LockScreenState.Kind.lockScreen, .screenSaver] {
          XCTAssertTrue(panel.controller.nativeWallpaperSource(kind).isEnabled)
        }
        service.refresh()
        XCTAssertTrue(service.isBusy)
        for kind in [LockScreenState.Kind.lockScreen, .screenSaver] {
          XCTAssertFalse(panel.controller.nativeWallpaperSource(kind).isEnabled)
        }
        try await panel.waitUntil { !service.isBusy }
        for kind in [LockScreenState.Kind.lockScreen, .screenSaver] {
          XCTAssertTrue(panel.controller.nativeWallpaperSource(kind).isEnabled)
        }
      }
    }
  }

  func testResetClearsBothSourcesOnlyAfterConfirmation() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.librarySnapshot.wallpapers = [OrganizationFixtures.wallpaper("chosen")]
      try await withNativeWallpaperService(panel) { service in
        try await panel.controller.setNativeWallpaperSource("chosen", for: .lockScreen)
        try await panel.controller.setNativeWallpaperSource("chosen", for: .screenSaver)
        try await panel.controller.resetAllSettings()
        XCTAssertEqual(service.lockScreenWallpaperID, "chosen")
        XCTAssertEqual(service.screenSaverWallpaperID, "chosen")

        panel.dialogs.confirmAnswer = true
        try await panel.controller.resetAllSettings()
        XCTAssertNil(service.lockScreenWallpaperID)
        XCTAssertNil(service.screenSaverWallpaperID)
        XCTAssertNil(panel.controller.nativeWallpaperSource(.lockScreen).wallpaperID)
        XCTAssertNil(panel.controller.nativeWallpaperSource(.screenSaver).wallpaperID)
      }
    }
  }
}

extension PanelTestCase {
  func withNativeWallpaperService(
    _ panel: PanelFixture, _ body: (LockScreenWallpaperService) async throws -> Void
  ) async throws {
    let root = panel.root.appendingPathComponent("native-wallpaper")
    let service = LockScreenWallpaperService(
      prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [] },
      selection: LockScreenWallpaperSelection(
        storeURL: root.appendingPathComponent("Index.plist"),
        journalURL: root.appendingPathComponent("journal.plist"), reload: {}),
      exchange: root, defaults: panel.defaults,
      scheduleMonitor: { _ in Timer(timeInterval: 2, repeats: true) { _ in } })
    try await service.start()
    panel.store.lockScreenWallpaper = service
    do {
      try await body(service)
    } catch {
      try? await service.shutdown()
      panel.store.lockScreenWallpaper = nil
      throw error
    }
    try await service.shutdown()
    panel.store.lockScreenWallpaper = nil
  }
}
