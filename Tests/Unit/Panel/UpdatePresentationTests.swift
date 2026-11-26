import XCTest

@testable import WallpaperMachine

@MainActor
final class UpdatePresentationTests: SettingsBTestCase {
  func testAWaitingVersionTakesPrecedenceOverTheTimeOfTheLastCheck() {
    let updater = SoftwareUpdateStatus()
    updater.isAvailable = true
    var card = UpdatePresentation(status: updater, locale: english)
    XCTAssertEqual(card.statusText, L("Updates not yet checked"))
    XCTAssertEqual(card.actionLabel, L("Check Now"))

    let lastCheck = Date(timeIntervalSinceNow: -86_400)
    updater.lastCheckedAt = lastCheck
    let time = lastCheck.formatted(.relative(presentation: .named).locale(english))
    card = UpdatePresentation(status: updater, locale: english)
    XCTAssertEqual(card.statusText, L("Last checked \(time)"))
    XCTAssertEqual(card.actionLabel, L("Check Now"))

    let version = "2.0.0"
    updater.waitingVersion = version
    card = UpdatePresentation(status: updater, locale: english)
    XCTAssertEqual(card.statusText, L("Version \(version) is available"))
    XCTAssertEqual(card.actionLabel, L("Show Update…"))
    updater.waitingVersion = nil
    XCTAssertEqual(UpdatePresentation(status: updater, locale: english).statusText, L("Last checked \(time)"))
  }

  func testOnlyAnExplicitRequestStartsTheUpdateFlowAndItLeavesWallpaperErrorsAlone() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let updater = controller.updater
      let requests = SettingsCallCounter()
      updater.checkNow = requests.bump
      controller.errors.actionError = "A wallpaper could not play."
      updater.canCheck = true
      try await controller.checkForUpdates()
      XCTAssertEqual(requests.count, 0, "an unconfigured build cannot start an update")

      updater.isAvailable = true
      updater.canCheck = false
      try await controller.checkForUpdates()
      XCTAssertEqual(requests.count, 0, "an updater that is busy is not asked again")
      try await controller.setAutomaticUpdateChecks(false)
      XCTAssertFalse(updater.checksAutomatically, "the preference is independent of a check in progress")
      updater.canCheck = true
      try await controller.checkForUpdates()
      XCTAssertEqual(requests.count, 1, "turning off automatic checks does not disable Check Now")

      updater.waitingVersion = "2.0.0"
      try await controller.setAutomaticUpdateChecks(true)
      XCTAssertTrue(updater.checksAutomatically)
      XCTAssertEqual(requests.count, 1, "a preference change or a waiting update is not a user-initiated check")
      try await controller.checkForUpdates()
      XCTAssertEqual(requests.count, 2)
      XCTAssertEqual(controller.errors.actionError, "A wallpaper could not play.")

      panel.navigation.revealSettingsSection(.about)
      XCTAssertEqual(panel.navigation.settingsSection, .about)
      XCTAssertEqual(panel.navigation.settingsSectionToken, 1)
    }
  }
}
