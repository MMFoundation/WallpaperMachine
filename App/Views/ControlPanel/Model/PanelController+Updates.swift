extension PanelController {
  func checkForUpdates() async throws {
    try await run(.immediate) {
      guard updater.isAvailable, updater.canCheck else { return }
      updater.checkNow()
    }
  }

  func setAutomaticUpdateChecks(_ enabled: Bool) async throws {
    try await run(.immediate) {
      guard updater.isAvailable else { return }
      updater.checksAutomatically = enabled
    }
  }
}
