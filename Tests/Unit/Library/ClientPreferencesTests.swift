import XCTest
@testable import WallpaperMachine

@MainActor
final class ClientPreferencesTests: XCTestCase {
    func testAnExplicitSuiteKeepsApplicationPreferencesIndependent() throws {
        let firstName = try TemporaryDefaults.make(for: self).suite
        let secondName = try TemporaryDefaults.make(for: self).suite
        let first = ClientPreferences.resolve(environment: [ClientPreferences.suiteEnvironmentKey: firstName])
        let second = ClientPreferences.resolve(environment: [ClientPreferences.suiteEnvironmentKey: secondName])
        first.set("en", forKey: AppLanguageStore.defaultsKey)
        first.set(true, forKey: PanelPreferences.welcomeSeenKey)
        second.set("ja", forKey: AppLanguageStore.defaultsKey)
        func updater(_ defaults: UserDefaults) -> SoftwareUpdateController {
            SoftwareUpdateController(defaults: defaults, installedBuild: 1, canRun: { false }, didChange: {})
        }
        let firstUpdater = updater(first)
        firstUpdater.status.checksAutomatically = false
        let firstLanguage = AppLanguageStore(defaults: first, systemLanguages: ["zh-Hans"])
        let secondLanguage = AppLanguageStore(defaults: second, systemLanguages: ["zh-Hans"])
        XCTAssertEqual(firstLanguage.effective, .english)
        XCTAssertEqual(secondLanguage.effective.tag, "ja")
        XCTAssertTrue(first.bool(forKey: PanelPreferences.welcomeSeenKey))
        XCTAssertFalse(second.bool(forKey: PanelPreferences.welcomeSeenKey))
        XCTAssertFalse(firstUpdater.status.checksAutomatically)
        XCTAssertTrue(updater(second).status.checksAutomatically)
        let reopened = ClientPreferences.resolve(environment: [ClientPreferences.suiteEnvironmentKey: firstName])
        XCTAssertEqual(reopened.string(forKey: AppLanguageStore.defaultsKey), "en")
        XCTAssertFalse(updater(reopened).status.checksAutomatically)
        XCTAssertEqual(ClientPreferences.domainName(environment: [ClientPreferences.suiteEnvironmentKey: firstName]), firstName)
    }

    func testNoSuiteUsesExistingApplicationPreferences() {
        XCTAssertTrue(ClientPreferences.resolve(environment: [:]) === UserDefaults.standard)
        XCTAssertTrue(ClientPreferences.resolve(environment: [ClientPreferences.suiteEnvironmentKey: ""]) === UserDefaults.standard)
        XCTAssertEqual(ClientPreferences.domainName(environment: [:]), Bundle.main.bundleIdentifier ?? "app.wallpapermachine")
    }
}
