import Sparkle
import XCTest

@testable import WallpaperMachine

@MainActor
final class SoftwareUpdateControllerTests: XCTestCase {
    private final class Driver: SoftwareUpdateDriving {
        var canCheckForUpdates = true
        var sessionInProgress = false
        var lastUpdateCheckDate: Date?
        var manual = 0
        var probes = 0
        var onCheck: (() -> Void)?
        func checkForUpdates() { manual += 1; onCheck?() }
        func checkForUpdateInformation() { probes += 1; onCheck?() }
    }

    private func updater(_ defaults: UserDefaults, build: Int = 68, driver: Driver) -> SoftwareUpdateController {
        let updater = SoftwareUpdateController(defaults: defaults, installedBuild: build, canRun: { true }, didChange: {})
        updater.attach(driver)
        return updater
    }

    func testAutomaticChecksProbeOnlyAndManualChecksIgnoreOptOutAndThrottle() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let driver = Driver()
        let updater = updater(defaults, driver: driver)
        let now = Date()
        updater.checkInBackgroundIfDue(now: now)
        driver.lastUpdateCheckDate = now
        updater.checkInBackgroundIfDue(now: now.addingTimeInterval(60))
        driver.sessionInProgress = true
        updater.checkInBackgroundIfDue(now: now.addingTimeInterval(86400))
        XCTAssertEqual(driver.probes, 1)
        driver.sessionInProgress = false
        updater.checkInBackgroundIfDue(now: now.addingTimeInterval(6 * 3600))
        XCTAssertEqual(driver.probes, 2)
        XCTAssertEqual(driver.manual, 0)
        updater.status.checksAutomatically = false
        let next = self.updater(defaults, driver: driver)
        next.checkInBackgroundIfDue(now: now.addingTimeInterval(86400))
        XCTAssertFalse(next.status.checksAutomatically)
        XCTAssertEqual(driver.probes, 2)
        next.status.checkNow()
        XCTAssertEqual(driver.manual, 1)
        driver.canCheckForUpdates = false
        next.checkNow()
        XCTAssertEqual(driver.manual, 1)
    }

    func testReminderSurvivesRelaunchAndSnoozeButNotSkipOrInstall() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let driver = Driver()
        let updater = updater(defaults, driver: driver)
        let now = Date()
        updater.found(build: "69", version: "1.16.0")
        let unconfigured = SoftwareUpdateController(defaults: defaults, installedBuild: 70, canRun: { true }, didChange: {})
        XCTAssertNil(unconfigured.status.waitingVersion)
        driver.sessionInProgress = true
        XCTAssertNil(updater.takeReminder(now: now))
        driver.sessionInProgress = false
        XCTAssertEqual(updater.takeReminder(now: now), "1.16.0")
        let relaunched = self.updater(defaults, driver: driver)
        XCTAssertEqual(relaunched.status.waitingVersion, "1.16.0")
        XCTAssertNil(relaunched.takeReminder(now: now.addingTimeInterval(23 * 3600)))
        XCTAssertEqual(relaunched.takeReminder(now: now.addingTimeInterval(24 * 3600)), "1.16.0")
        relaunched.skip("1.16.0")
        relaunched.found(build: "69", version: "1.16.0")
        XCTAssertNil(relaunched.status.waitingVersion)
        relaunched.found(build: "70", version: "1.16.1")
        XCTAssertEqual(relaunched.takeReminder(now: now), "1.16.1")
        XCTAssertNil(self.updater(defaults, build: 70, driver: driver).status.waitingVersion)
        XCTAssertNil(self.updater(defaults, build: 68, driver: driver).status.waitingVersion)
    }

    func testLegacyChoicesKeepCheckingButNeverStartAnInstallation() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        for mode in ["notify", "download", "automatic"] {
            defaults.set(mode, forKey: "WallpaperMachine.updates.mode")
            let driver = Driver()
            let updater = updater(defaults, driver: driver)
            updater.checkInBackgroundIfDue()
            XCTAssertTrue(updater.status.checksAutomatically)
            XCTAssertEqual(driver.probes, 1)
            XCTAssertEqual(driver.manual, 0)
        }
        defaults.set("1.16.0", forKey: "WallpaperMachine.updates.skippedVersion")
        let updater = updater(defaults, driver: Driver())
        updater.found(build: "69", version: "1.16.0")
        XCTAssertNil(updater.status.waitingVersion)
    }

    func testOnlyExactOfficialVersionedArchivesUseTheWebsite() throws {
        let prefix = "https://github.com/MMFoundation/WallpaperMachine/releases/download/"
        let archive = "v1.16.0/WallpaperMachine-1.16.0-arm64.zip"
        XCTAssertEqual(SoftwareUpdateTransport.mirroredArchive(try XCTUnwrap(URL(string: prefix + archive)))?.absoluteString,
                       "https://www.wallpapermachine.app/updates/download/" + archive)
        for bad in [prefix + "v1.16.1/WallpaperMachine-1.16.0-arm64.zip", prefix + archive + "?download=1",
                    prefix + archive + "#x", prefix.replacingOccurrences(of: "https:", with: "http:") + archive,
                    prefix.replacingOccurrences(of: "github.com", with: "example.org") + archive,
                    prefix.replacingOccurrences(of: "github.com", with: "github.com:444") + archive,
                    prefix.replacingOccurrences(of: "github.com", with: "user@github.com") + archive,
                    prefix.replacingOccurrences(of: "WallpaperMachine", with: "OhMyShot") + archive,
                    prefix + archive.replacingOccurrences(of: ".zip", with: ".dmg")] {
            XCTAssertNil(SoftwareUpdateTransport.mirroredArchive(try XCTUnwrap(URL(string: bad))), bad)
        }
    }

    func testTransportRetriesOnceInTheSameModeButNeverOnSignatureOrOfflineErrors() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        for manual in [true, false] {
            let driver = Driver()
            let updater = updater(defaults, driver: driver)
            let network = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                                  userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
            let retried = expectation(description: "Retry the same check through GitHub")
            driver.onCheck = { retried.fulfill() }
            updater.found(build: "69", version: "1.16.0")
            updater.finished(manual: manual, error: network)
            await fulfillment(of: [retried], timeout: 2)
            XCTAssertTrue(updater.usingDirectFeed)
            updater.finished(manual: manual, error: network)
            await Task.yield()
            XCTAssertEqual(driver.manual, manual ? 1 : 0)
            XCTAssertEqual(driver.probes, manual ? 0 : 1)
            XCTAssertEqual(updater.status.waitingVersion, "1.16.0")
        }
        for cause in [URLError(.notConnectedToInternet) as NSError, URLError(.cancelled) as NSError,
                      URLError(.serverCertificateUntrusted) as NSError,
                      NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue)),
                      NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastParseError.rawValue)),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                                userInfo: [NSUnderlyingErrorKey: cause])
            XCTAssertFalse(SoftwareUpdateTransport.canRetry(error))
        }
    }

    func testBundleRequiresSignedUpdatesAndKeepsTheProductionFeedOutOfDebugBuilds() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUSignedFeedFailureExpirationInterval"] as? Int, 0)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        #if DEBUG
        XCTAssertNotEqual(info["SUFeedURL"] as? String, SoftwareUpdateTransport.siteFeed)
        #endif
        let url = try XCTUnwrap(Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"))
        let entries = try XCTUnwrap(SoftwareUpdateController.recentReleases(String(contentsOf: url, encoding: .utf8)))
        XCTAssertFalse(entries.isEmpty)
        XCTAssertLessThanOrEqual(entries.count, 20)
        XCTAssertFalse(entries[0].notes(language: .chinese).sections.isEmpty)
    }
}
