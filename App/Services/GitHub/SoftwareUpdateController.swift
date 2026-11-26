import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class SoftwareUpdateStatus {
    var isAvailable = false
    var canCheck = false
    var waitingVersion: String?
    var lastCheckedAt: Date?
    var checksAutomatically = true {
        didSet {
            if checksAutomatically != oldValue { checksChanged(checksAutomatically) }
        }
    }
    var notesReleases: [AppReleaseHistory.Entry] = []
    @ObservationIgnored var checkNow: () -> Void = {}
    @ObservationIgnored fileprivate var checksChanged: (Bool) -> Void = { _ in }
}

@MainActor
protocol SoftwareUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    func checkForUpdates()
    func checkForUpdateInformation()
}

extension SPUUpdater: SoftwareUpdateDriving {}

@MainActor
final class SoftwareUpdateController: NSObject, SPUUpdaterDelegate {
    static let interval: TimeInterval = 6 * 60 * 60
    private static let automaticKey = "WallpaperMachine.updates.checksAutomatically"
    private static let pendingKey = "WallpaperMachine.updates.sparklePending"
    private static let skippedKey = "WallpaperMachine.updates.skippedVersion"
    private static let deferredVersionKey = "WallpaperMachine.updates.deferredVersion"
    private static let deferredUntilKey = "WallpaperMachine.updates.deferredUntil"

    let status = SoftwareUpdateStatus()
    private let defaults: UserDefaults
    private let installedBuild: Int
    private let didChange: () -> Void
    private let canRun: () -> Bool
    private var controller: SPUStandardUpdaterController?
    private var driver: (any SoftwareUpdateDriving)?
    private var observation: NSKeyValueObservation?
    private var retry: Task<Void, Never>?
    private(set) var usingDirectFeed = false
    private(set) var isRelaunching = false

    init(defaults: UserDefaults = ClientPreferences.defaults,
         installedBuild: Int = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
         canRun: @escaping () -> Bool, didChange: @escaping () -> Void) {
        self.defaults = defaults
        self.installedBuild = installedBuild
        self.canRun = canRun
        self.didChange = didChange
        super.init()
        status.checksAutomatically = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        status.checkNow = { [weak self] in self?.checkNow() }
        status.checksChanged = { [weak self] enabled in
            guard let self else { return }
            defaults.set(enabled, forKey: Self.automaticKey)
            if enabled { checkInBackgroundIfDue() }
        }
    }

    func start() {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") {
            Task {
                status.notesReleases = await Task.detached(priority: .utility) {
                    (try? String(contentsOf: url, encoding: .utf8)).flatMap(Self.recentReleases) ?? []
                }.value
            }
        }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == SoftwareUpdateTransport.siteFeed,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              !Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/nix/store/") else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            AppLog.error("Could not start software updates: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.automaticallyChecksForUpdates = false
        }
        attach(controller.updater)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.status.canCheck = updater.canCheckForUpdates }
        }
    }

    func attach(_ driver: any SoftwareUpdateDriving) {
        self.driver = driver
        status.isAvailable = true
        status.canCheck = driver.canCheckForUpdates
        status.lastCheckedAt = driver.lastUpdateCheckDate
        guard let pending = defaults.dictionary(forKey: Self.pendingKey) else { return }
        if let build = pending["build"] as? Int, build > installedBuild,
           let version = pending["version"] as? String, SemanticVersion(version) != nil,
           version != defaults.string(forKey: Self.skippedKey) {
            status.waitingVersion = version
        } else {
            defaults.removeObject(forKey: Self.pendingKey)
        }
    }

    static func owns(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController else { return false }
        return Bundle(for: type(of: controller)) == Bundle(for: SPUUpdater.self)
    }

    nonisolated static func recentReleases(_ markdown: String) -> [AppReleaseHistory.Entry]? {
        var sections = 0
        let recent = markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix { line in
            if line.hasPrefix("## ") { sections += 1 }
            return sections <= 20
        }.joined(separator: "\n")
        return try? AppReleaseHistory(markdown: recent).entries
    }

    func checkNow() {
        guard canRun(), let driver, driver.canCheckForUpdates else { return }
        retry?.cancel()
        if !driver.sessionInProgress { usingDirectFeed = false }
        driver.checkForUpdates()
    }

    func checkInBackgroundIfDue(now: Date = Date()) {
        guard canRun(), status.checksAutomatically, let driver, !driver.sessionInProgress else { return }
        if let last = driver.lastUpdateCheckDate {
            let age = now.timeIntervalSince(last)
            if age >= 0 && age < Self.interval * 0.75 { return }
        }
        retry?.cancel()
        usingDirectFeed = false
        driver.checkForUpdateInformation()
    }

    func found(build: String, version: String) {
        guard let build = Int(build), build > installedBuild, SemanticVersion(version) != nil else { return }
        guard version != defaults.string(forKey: Self.skippedKey) else { clearPending(); return }
        defaults.set(["build": build, "version": version], forKey: Self.pendingKey)
        status.waitingVersion = version
        didChange()
    }

    func skip(_ version: String) {
        defaults.set(version, forKey: Self.skippedKey)
        if status.waitingVersion == version { clearPending() }
    }

    private func clearPending() {
        defaults.removeObject(forKey: Self.pendingKey)
        status.waitingVersion = nil
        didChange()
    }

    func takeReminder(now: Date = Date()) -> String? {
        guard canRun(), status.isAvailable, status.checksAutomatically, let driver, !driver.sessionInProgress,
              let version = status.waitingVersion else { return nil }
        if version == defaults.string(forKey: Self.deferredVersionKey),
           let until = defaults.object(forKey: Self.deferredUntilKey) as? Date, until > now { return nil }
        postpone(version, now: now)
        return version
    }

    func postpone(_ version: String, now: Date = Date()) {
        defaults.set(version, forKey: Self.deferredVersionKey)
        defaults.set(now.addingTimeInterval(24 * 60 * 60), forKey: Self.deferredUntilKey)
    }

    func quitWasCancelled() { isRelaunching = false }

    var isPresentingUpdate: Bool {
        controller != nil && NSApp.windows.contains { $0.isVisible && Self.owns($0) }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        usingDirectFeed ? SoftwareUpdateTransport.directFeed : SoftwareUpdateTransport.siteFeed
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if !usingDirectFeed, let url = request.url, let mirror = SoftwareUpdateTransport.mirroredArchive(url) {
            request.url = mirror
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found(build: item.versionString, version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { clearPending() }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem,
                 state: SPUUserUpdateState) {
        switch choice {
        case .skip where state.stage != .installing: skip(item.displayVersionString)
        case .dismiss: postpone(item.displayVersionString)
        default: break
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { isRelaunching = true }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        finished(manual: updateCheck == .updates, error: error as NSError?)
    }

    func finished(manual: Bool, error: NSError?) {
        status.lastCheckedAt = driver?.lastUpdateCheckDate
        if manual, let version = status.waitingVersion { postpone(version) }
        if let error, !usingDirectFeed, SoftwareUpdateTransport.canRetry(error) {
            usingDirectFeed = true
            retry = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, canRun(), let driver, !driver.sessionInProgress else { return }
                if manual { driver.checkForUpdates() }
                else if status.checksAutomatically { driver.checkForUpdateInformation() }
            }
        } else {
            isRelaunching = false
            didChange()
        }
    }
}

enum SoftwareUpdateTransport {
    static let siteFeed = "https://www.wallpapermachine.app/updates/appcast"
    static let directFeed = "https://github.com/MMFoundation/WallpaperMachine/releases/latest/download/appcast.xml"

    static func mirroredArchive(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let path = components.percentEncodedPath.components(separatedBy: "/")
        guard path.count == 7, path[0].isEmpty, path[1].lowercased() == "mmfoundation",
              path[2].lowercased() == "wallpapermachine", path[3] == "releases", path[4] == "download",
              let version = SemanticVersion(path[5]), path[5] == "v" + version.display,
              path[6] == "WallpaperMachine-\(version.display)-arm64.zip" else { return nil }
        return URL(string: "https://www.wallpapermachine.app/updates/download/\(path[5])/\(path[6])")
    }

    static func canRetry(_ error: NSError) -> Bool {
        var current = error
        for _ in 0..<6 {
            if current.domain == NSURLErrorDomain {
                return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                        .networkConnectionLost, .badServerResponse].contains(URLError.Code(rawValue: current.code))
            }
            guard current.domain == SUSparkleErrorDomain,
                  [Int(SUError.downloadError.rawValue), Int(SUError.appcastError.rawValue)].contains(current.code) else { return false }
            guard let cause = current.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return current.code == SUError.downloadError.rawValue
            }
            current = cause
        }
        return false
    }
}
