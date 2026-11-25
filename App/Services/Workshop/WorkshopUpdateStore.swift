import Foundation
import Observation

/// Which installed Workshop wallpapers their authors have changed since they were installed.
///
/// A wallpaper counts as installed from the moment this app finished downloading it. One it did
/// not download (imported, or downloaded before installs were recorded) counts from when its
/// `project.json` was last written, which for an import is when it was copied in, so an import
/// that was already out of date is not caught. Steam's public details endpoint says when each
/// item last changed; it needs no sign-in, and only the items' ids are sent. An installed
/// Workshop preset holds its base wallpaper's content too, so a change to that base after the
/// preset was installed is an update of the preset, and the base's id is asked about with it.
/// Returned details are also cached for Installed's tags, including current items; selecting
/// an item can fill missing details independently of the automatic update schedule.
@MainActor
@Observable
final class WorkshopUpdateStore {
    /// Details already read from Steam, including installed items that have no update.
    private(set) var detailsRevision: UInt64 = 0
    private(set) var details: [String: WorkshopItem] = [:] {
        didSet { if details != oldValue { detailsRevision &+= 1 } }
    }
    /// Installed items with a newer version on the Workshop, with Steam's current details.
    private(set) var availableRevision: UInt64 = 0
    private(set) var available: [String: WorkshopItem] = [:] {
        didSet { if available != oldValue { availableRevision &+= 1 } }
    }
    private(set) var isChecking = false
    private(set) var isLoadingDetails = false
    private(set) var lastChecked: Date?
    private(set) var errorMessage: String?
    /// Whether the app checks by itself, at most once a day. On unless turned off.
    var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Self.automaticKey) }
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Steam's clock and this Mac's may disagree a little; a change within this of the install
    /// is the version that was installed.
    nonisolated static let tolerance: TimeInterval = 60
    private static let installedKey = "WallpaperMachine.workshopInstalledAt"
    private static let availableKey = "WallpaperMachine.workshopUpdates"
    private static let dismissedKey = "WallpaperMachine.workshopUpdatesDismissed"
    private static let lastCheckedKey = "WallpaperMachine.workshopUpdatesCheckedAt"
    private static let detailsKey = "WallpaperMachine.workshopDetails"
    private static let detailsCheckedKey = "WallpaperMachine.workshopDetailsCheckedAt"
    nonisolated static let automaticKey = "WallpaperMachine.workshopUpdateChecks"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable ([String]) async throws -> [WorkshopItem]
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var installedAt: [String: Date]
    /// Dismissed update timestamps by published file id: an update stays hidden until Steam
    /// reports a newer `remoteUpdated > dismissedAt[id]`.
    @ObservationIgnored private var dismissedAt: [String: Date]
    /// The effective remote update date (own or preset base) of each currently available update.
    @ObservationIgnored private var remoteUpdatedAt: [String: Date] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var installedIDs: Set<String> = []
    @ObservationIgnored private var itemRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var detailsCheckedAt: [String: Date] = [:]
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var detailsContext: DetailsContext?
    @ObservationIgnored private var detailsGeneration: UInt64 = 0

    private struct DetailsContext: Equatable {
        let id: String
        let libraryRevision: UInt64
    }

    init(
        defaults: UserDefaults = ClientPreferences.defaults,
        fetch: @escaping @Sendable ([String]) async throws -> [WorkshopItem] = { try await WorkshopService().details(ids: $0) },
        now: (@MainActor () -> Date)? = nil
    ) {
        self.defaults = defaults
        self.fetch = fetch
        self.now = now ?? { Date() }
        checksAutomatically = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        installedAt = (defaults.dictionary(forKey: Self.installedKey) as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
        dismissedAt = (defaults.dictionary(forKey: Self.dismissedKey) as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
        let storedAvailable = (defaults.data(forKey: Self.availableKey))
            .flatMap { try? JSONDecoder().decode([WorkshopItem].self, from: $0) }
            .map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        available = storedAvailable.filter { id, item in
            guard let skipped = dismissedAt[id], let updated = item.timeUpdated else { return true }
            return updated > skipped
        }
        lastChecked = (defaults.object(forKey: Self.lastCheckedKey) as? Double).map(Date.init(timeIntervalSince1970:))
        details = defaults.data(forKey: Self.detailsKey)
            .flatMap { try? JSONDecoder().decode([String: WorkshopItem].self, from: $0) } ?? available
        detailsCheckedAt = (defaults.dictionary(forKey: Self.detailsCheckedKey) as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
    }

    /// Workshop ids are numbers; anything else in the library came from somewhere else.
    nonisolated static func isWorkshopID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber } && UInt64(id) != nil
    }

    /// Checks `installed` (the library's wallpaper ids) against the Workshop, unless a check is
    /// already running. `library` is where their folders are.
    func check(installed: [String], library: URL) {
        let ids = installed.filter(Self.isWorkshopID)
        let currentIDs = Set(ids)
        for id in installedIDs.subtracting(currentIDs) {
            itemRevisions[id, default: 0] &+= 1
            available[id] = nil
            dismissedAt[id] = nil
            remoteUpdatedAt[id] = nil
        }
        details = details.filter { currentIDs.contains($0.key) }
        detailsCheckedAt = detailsCheckedAt.filter { currentIDs.contains($0.key) }
        if let selected = detailsContext?.id, !currentIDs.contains(selected) { selectDetails(nil) }
        installedIDs = currentIDs
        guard task == nil else { persist(); return }
        let recorded = installedAt
        let dismissed = dismissedAt
        let revisions = itemRevisions
        let fetch = fetch
        isChecking = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                // Reading each project.json's date is file-system work; it stays off the main actor.
                let (local, bases) = await Task.detached(priority: .utility) {
                    (Self.localVersions(ids, recorded: recorded, library: library), Self.presetBases(ids, library: library))
                }.value
                let asked = ids + Set(bases.values).subtracting(ids).sorted()
                let remote = asked.isEmpty ? [] : try await fetch(asked)
                let outdated = Self.outdated(remote: remote, local: local, bases: bases, dismissed: dismissed)
                let effective = Self.effectiveUpdatedDates(remote: remote, ids: Array(outdated.keys), bases: bases)
                self?.finish(outdated, effectiveUpdated: effective, remote: remote, recorded: recorded, revisions: revisions)
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Checks when automatic checks are on and the last check is a day old.
    func checkIfDue(installed: [String], library: URL) {
        guard checksAutomatically else { return }
        if let lastChecked, now().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        check(installed: installed, library: library)
    }

    /// Hides the available update for `id` until Steam reports an even newer revision
    /// (`remoteUpdated > dismissedRemoteUpdated`). Automatically cleared if the user updates
    /// manually or removes the wallpaper.
    func dismissUpdate(for id: String, remoteUpdated: Date? = nil) {
        let version = remoteUpdated ?? remoteUpdatedAt[id] ?? available[id]?.timeUpdated ?? now()
        dismissedAt[id] = version
        if available[id] != nil { available[id] = nil }
        remoteUpdatedAt[id] = nil
        persist()
    }

    /// The dismissed remote update timestamp for `id`, if any.
    func dismissedUpdateDate(for id: String) -> Date? { dismissedAt[id] }

    /// The effective remote update timestamp (own or preset base) of the currently available update
    /// for `id`, if known.
    func remoteUpdatedDate(for id: String) -> Date? { remoteUpdatedAt[id] ?? available[id]?.timeUpdated }

    /// Records that `id` was just downloaded, which makes it current and clears any dismissed version.
    func recordInstalled(_ id: String) {
        installedIDs.insert(id)
        itemRevisions[id, default: 0] &+= 1
        installedAt[id] = now()
        available[id] = nil
        dismissedAt[id] = nil
        remoteUpdatedAt[id] = nil
        // Reinstalling can replace the tags too. The download's details or the next selection
        // will supply the new version; an older request must not publish over it.
        details[id] = nil
        detailsCheckedAt[id] = nil
        if detailsContext?.id == id { selectDetails(nil) }
        persist()
    }

    /// Keeps a downloaded item's tags even if automatic update checks are off.
    func rememberDetails(_ item: WorkshopItem) {
        guard Self.isWorkshopID(item.id) else { return }
        details[item.id] = item
        detailsCheckedAt[item.id] = now()
        persist()
    }

    /// Reads missing or day-old details for the selected installed wallpaper. Repeated context
    /// reconciliation does no work; changing selection cancels its old request. Cached details
    /// remain visible offline, and a later selection or library refresh can retry a failed read.
    func selectDetails(_ id: String?, libraryRevision: UInt64 = 0) {
        let context = id.flatMap { Self.isWorkshopID($0) ? DetailsContext(id: $0, libraryRevision: libraryRevision) : nil }
        guard context != detailsContext else { return }
        detailsGeneration &+= 1
        let generation = detailsGeneration
        detailsTask?.cancel()
        detailsTask = nil
        isLoadingDetails = false
        detailsContext = context
        guard let context else { return }
        let id = context.id
        if details[id] != nil, let checked = detailsCheckedAt[id],
           now().timeIntervalSince(checked) < Self.checkInterval { return }
        let revision = itemRevisions[id, default: 0]
        let fetch = fetch
        isLoadingDetails = true
        detailsTask = Task { [weak self] in
            defer {
                if self?.detailsGeneration == generation { self?.isLoadingDetails = false }
            }
            do {
                let items = try await fetch([id])
                try Task.checkCancellation()
                guard let self, self.detailsGeneration == generation,
                      self.itemRevisions[id, default: 0] == revision else { return }
                if let item = items.first(where: { $0.id == id }) { self.rememberDetails(item) }
            } catch is CancellationError {
                return
            } catch {
                AppLog.debug("Workshop details unavailable for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Drops wallpapers that left the library.
    func forget(_ ids: [String]) {
        for id in ids {
            installedIDs.remove(id)
            itemRevisions[id, default: 0] &+= 1
            installedAt[id] = nil
            available[id] = nil
            dismissedAt[id] = nil
            remoteUpdatedAt[id] = nil
            details[id] = nil
            detailsCheckedAt[id] = nil
            if detailsContext?.id == id { selectDetails(nil) }
        }
        persist()
    }

    /// The items whose Workshop version is newer than the one installed, and the presets (by
    /// `bases`, preset to base) whose base is, omitting versions the user dismissed until an even
    /// newer revision arrives (`remoteUpdated > dismissedRemoteUpdated`).
    nonisolated static func outdated(remote: [WorkshopItem], local: [String: Date],
                                     bases: [String: String] = [:],
                                     dismissed: [String: Date] = [:]) -> [String: WorkshopItem] {
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let effective = { (id: String) -> Date? in
            Self.effectiveUpdatedDate(for: id, byID: byID, bases: bases)
        }
        var outdated: [String: WorkshopItem] = [:]
        for (id, installed) in local {
            guard let item = byID[id], let changed = effective(id) else { continue }
            guard changed > installed.addingTimeInterval(tolerance) else { continue }
            if let skipped = dismissed[id], changed <= skipped { continue }
            outdated[id] = item
        }
        return outdated
    }

    /// The newest `timeUpdated` between `id` itself and its preset base (if any).
    nonisolated private static func effectiveUpdatedDate(
        for id: String, byID: [String: WorkshopItem], bases: [String: String]
    ) -> Date? {
        let own = byID[id]?.timeUpdated
        let base = bases[id].flatMap { byID[$0]?.timeUpdated }
        switch (own, base) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    nonisolated private static func effectiveUpdatedDates(
        remote: [WorkshopItem], ids: [String], bases: [String: String]
    ) -> [String: Date] {
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var dates: [String: Date] = [:]
        for id in ids {
            if let date = effectiveUpdatedDate(for: id, byID: byID, bases: bases) {
                dates[id] = date
            }
        }
        return dates
    }

    /// The base each installed preset names in its `project.json` (`dependency`), by the
    /// preset's id; wallpapers that are not presets are left out.
    nonisolated static func presetBases(_ ids: [String], library: URL) -> [String: String] {
        var bases: [String: String] = [:]
        for id in ids {
            let manifest = library.appendingPathComponent(id).appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let base = WallpaperImportService.workshopID(object["dependency"]), base != id
            else { continue }
            bases[id] = base
        }
        return bases
    }

    /// When each installed item was installed: recorded downloads first, then the date its
    /// `project.json` was last written. An item with neither is left out and never flagged.
    nonisolated static func localVersions(_ ids: [String], recorded: [String: Date], library: URL) -> [String: Date] {
        var versions: [String: Date] = [:]
        for id in ids {
            if let date = recorded[id] {
                versions[id] = date
            } else if let date = try? library.appendingPathComponent(id).appendingPathComponent("project.json")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            {
                versions[id] = date
            }
        }
        return versions
    }

    /// `recorded` is what the check compared against; an item downloaded or dismissed while it ran
    /// stays hidden.
    private func finish(_ outdated: [String: WorkshopItem], effectiveUpdated: [String: Date],
                        remote: [WorkshopItem], recorded: [String: Date], revisions: [String: UInt64]) {
        available = outdated.filter { id, item in
            guard installedIDs.contains(id),
                  itemRevisions[id, default: 0] == revisions[id, default: 0],
                  installedAt[id] == recorded[id]
            else { return false }
            if let skipped = dismissedAt[id],
               let updated = effectiveUpdated[id] ?? item.timeUpdated,
               updated <= skipped {
                return false
            }
            return true
        }
        remoteUpdatedAt = effectiveUpdated.filter { available[$0.key] != nil }
        for item in remote where installedIDs.contains(item.id)
            && itemRevisions[item.id, default: 0] == revisions[item.id, default: 0] {
            details[item.id] = item
            detailsCheckedAt[item.id] = now()
        }
        lastChecked = now()
        isChecking = false
        task = nil
        AppLog.info("Workshop update check: \(available.count) of the installed items have updates")
        persist()
    }

    private func fail(_ error: Error) {
        errorMessage = String(localized: "Couldn’t check the Workshop for updates: \(error.localizedDescription)")
        isChecking = false
        task = nil
        AppLog.warn("Workshop update check failed: \(error.localizedDescription)")
    }

    private func persist() {
        defaults.set(installedAt.mapValues(\.timeIntervalSince1970), forKey: Self.installedKey)
        defaults.set(dismissedAt.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedKey)
        if let data = try? JSONEncoder().encode(available.values.sorted { $0.id < $1.id }) {
            defaults.set(data, forKey: Self.availableKey)
        }
        if let data = try? JSONEncoder().encode(details) { defaults.set(data, forKey: Self.detailsKey) }
        defaults.set(detailsCheckedAt.mapValues(\.timeIntervalSince1970), forKey: Self.detailsCheckedKey)
        if let lastChecked {
            defaults.set(lastChecked.timeIntervalSince1970, forKey: Self.lastCheckedKey)
        }
    }
}
