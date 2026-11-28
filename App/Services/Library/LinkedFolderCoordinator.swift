import AppKit
import Foundation
import Observation

/// Keeps the library in step with the folders the user linked to it: watches each with a
/// `DirectoryWatcher`, looks at all of them at launch, after wake and when a disk mounts (FSEvents
/// cannot report what changed while the app was not running), and applies what
/// `LinkedFolderPlanner` decides through the import store and the panel's removal path.
///
/// It belongs to the app, so a folder is followed whether or not the panel is open. Removing a
/// wallpaper also forgets its favorites, playlist entries and the rest, which the panel owns: while
/// no panel is open, removals wait in the record and run when one opens.
@MainActor
@Observable
final class LinkedFolderCoordinator {
    /// What the panel shows of a link beyond its record.
    struct Status: Equatable, Sendable {
        /// The folder could not be read at the last look: nothing is removed until it can.
        var isUnavailable = false
        /// Library items whose files left the folder in a number held for the user's go-ahead.
        var held: [String] = []
        /// Why the last import or removal for this folder did not finish.
        var failure: String?
    }

    private(set) var folders: [LinkedFolder] = []
    private(set) var statuses: [UUID: Status] = [:]

    /// The ids installed in the library, or nil while it has not been read. Set by the app.
    @ObservationIgnored var installedIDs: (@MainActor () -> Set<String>?)?
    /// Imports files with `.replaceChanged` and answers the report once the library has been
    /// rescanned (`LibraryImportStore.importAndWait`); throws while another import runs.
    @ObservationIgnored var importer: (@MainActor ([URL], [String: LinkedFolderDestinationIdentity], [String: String]) async throws -> WallpaperImportService.Report)?
    /// Moves wallpapers to the Trash and forgets them as the panel's Delete does, answering the
    /// ids it removed. Set by an open panel, nil while none is. Just before it removes anything,
    /// in its turn in the command queue, it asks the second argument which of the ids are still
    /// due, so an unlink or Mirror deletions turned off meanwhile removes nothing.
    @ObservationIgnored var remover: (@MainActor ([String], [String: LinkedFolderDestinationIdentity], @escaping @MainActor () -> Set<String>) async throws -> [String])? {
        didSet {
            // Removals found while no panel was open run now; a folder missing earlier is looked for.
            if remover != nil, folders.contains(where: { $0.record.entries.contains { $0.state == .leaving }
                || !$0.record.pendingRemovals.isEmpty || status(of: $0.id).isUnavailable }) {
                reconcileAll()
            }
        }
    }

    @ObservationIgnored private let store: any LinkedFolderStoring
    @ObservationIgnored private let scanner: any LinkedFolderScanning
    @ObservationIgnored private let watch: @MainActor (URL, @escaping @MainActor () -> Void) -> (any DirectoryWatching)?
    @ObservationIgnored private let recheckDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var watchers: [UUID: any DirectoryWatching] = [:]
    @ObservationIgnored private var watchedPaths: [UUID: String] = [:]
    @ObservationIgnored private var dirty: [UUID] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var rechecks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var saving: Task<Void, Error>?
    @ObservationIgnored private var pendingEdits: [UUID: Int] = [:]
    /// Changes the watcher reported for each folder, so a removal waiting for its turn can tell
    /// that the folder changed meanwhile.
    @ObservationIgnored private var changes: [UUID: UInt64] = [:]
    /// Why the saved links could not be read; while set nothing is saved over them.
    @ObservationIgnored private var loadFailure: Error?
    @ObservationIgnored private let home: URL

    /// A file still being copied is looked at again after `recheckDelay`; only then, if it kept
    /// its size, is it imported.
    init(
        store: any LinkedFolderStoring = LinkedFolderStore(),
        scanner: any LinkedFolderScanning = LinkedFolderScanner(),
        watch: @escaping @MainActor (URL, @escaping @MainActor () -> Void) -> (any DirectoryWatching)? = {
            DirectoryWatcher(url: $0, onChange: $1)
        },
        recheckDelay: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.home = home
        self.store = store
        self.scanner = scanner
        self.watch = watch
        self.recheckDelay = recheckDelay
        self.sleep = sleep
        self.notifications = notifications
    }

    /// Starts following every linked folder once the library has been read, and looks at each.
    func start() {
        loadIfNeeded()
        guard !isStarted else { return reconcileAll() }
        isStarted = true
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAll() }
            })
        }
        reconcileAll()
    }

    func stop() {
        isStarted = false
        for observer in observers { notifications.removeObserver(observer) }
        observers = []
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        watchedPaths = [:]
        for task in rechecks.values { task.cancel() }
        rechecks = [:]
        // The running look ends at its next step and clears `worker` itself, so a start that
        // comes first finds it still draining instead of starting a second one.
        dirty = []
    }

    /// Stops following the folders and waits for the link records still being saved, so a quit
    /// never leaves an imported wallpaper without the record that says the link owns it.
    func shutdown() async {
        stop()
        await worker?.value
        _ = try? await saving?.value
    }

    /// Looks at every linked folder: at launch, after wake, when a disk mounts or the library's
    /// drive comes back.
    func reconcileAll() {
        for folder in folders { schedule(folder.id) }
    }

    func status(of id: UUID) -> Status { statuses[id] ?? Status() }

    /// Returns once no look is running or queued; rechecks still waiting for their delay are not
    /// waited for. For tests, which drive the looks themselves.
    func waitForIdle() async {
        while let worker { await worker.value }
        _ = try? await saving?.value
    }

    // MARK: Editing links

    /// Links `url` and imports what it holds. Refuses a folder inside the library or
    /// WallpaperMachine's own folders, one that holds them, and one already linked.
    @discardableResult
    func add(_ url: URL, library: URL = ClientPaths.libraryURL, support: URL = ClientPaths.supportURL) async throws -> LinkedFolder {
        loadIfNeeded()
        let chosen = url.standardizedFileURL
        let (folder, bookmark) = try await Task.detached(priority: .userInitiated) {
            try Self.validate(chosen, library: library, support: support)
        }.value
        let link = LinkedFolder(path: folder.path, bookmark: bookmark)
        try await transact { links in
            guard !links.contains(where: { $0.path == link.path }) else {
                throw WallpaperActionError(message: String(localized: "This folder is already linked."))
            }
            links.append(link)
        }
        schedule(link.id)
        return link
    }

    /// Stops following a folder. What it imported stays in the library, and nothing it had due
    /// to remove is removed.
    func unlink(_ id: UUID) async throws {
        try await transact(holdingRemovalsFor: id) { $0.removeAll { $0.id == id } }
        stopWatching(id)
        statuses[id] = nil
        rechecks.removeValue(forKey: id)?.cancel()
    }

    /// Mirror deletions applies to files deleted from now on. Turning it off calls off every
    /// removal still due: those wallpapers are kept.
    func setMirrorsDeletions(_ on: Bool, for id: UUID) async throws {
        try await update(id) {
            $0.mirrorsDeletions = on
            if !on { LinkedFolderPlanner.stopMirroring(&$0.record) }
        }
        if !on { statuses[id]?.held = [] }
    }

    /// Removes the wallpapers of `ids`, the held ones the user was shown and confirmed; any held
    /// since then waits to be asked about.
    func removeHeld(_ ids: [String], for id: UUID) async throws {
        let confirmed = Set(ids).intersection(status(of: id).held)
        guard !confirmed.isEmpty else { return }
        try await update(id) { LinkedFolderPlanner.confirmHeld(Array(confirmed), in: &$0.record) }
        statuses[id]?.held.removeAll { confirmed.contains($0) }
    }

    /// Keeps the held wallpapers in the library; their files are not asked about again.
    func keepHeld(for id: UUID) async throws {
        let held = status(of: id).held
        guard !held.isEmpty else { return }
        try await update(id) { LinkedFolderPlanner.keepHeld(held, in: &$0.record) }
        statuses[id]?.held.removeAll { held.contains($0) }
    }

    // MARK: Reconciling

    private func schedule(_ id: UUID) {
        guard isStarted, !dirty.contains(id) else { return }
        dirty.append(id)
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    /// One folder at a time, so two looks never import the same file twice.
    private func drain() async {
        while isStarted, !dirty.isEmpty {
            await reconcile(dirty.removeFirst())
        }
        worker = nil
    }

    private func reconcile(_ id: UUID) async {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        // The library is away (its drive is disconnected) or not read: nothing to compare with.
        // No recheck: the drive's return and every launch, wake and mount look at all folders.
        guard installedIDs?() != nil else { return }
        // Watched before the scan, so a file that arrives while it runs still sends an event: the
        // watcher reports only what happens after it starts.
        if FileManager.default.fileExists(atPath: folder.url.path) { startWatching(id, at: folder.url) }
        let changesAtScan = changes[id, default: 0]
        let scan = await scanner.scan(folder)
        // Read after the scan and with no wait before the import starts, so a file another import
        // put in the library meanwhile is seen as somebody else's, never claimed by this link.
        guard isStarted, let current = folders.first(where: { $0.id == id }), let installed = installedIDs?() else { return }
        let plan = LinkedFolderPlanner.plan(record: current.record, scan: scan,
                                            mirrorsDeletions: current.mirrorsDeletions, installed: installed)
        var status = self.status(of: id)
        status.isUnavailable = plan.isUnavailable
        status.held = plan.held
        statuses[id] = status
        guard case .contents(let contents) = scan else {
            watchNearestAncestor(of: current.url, for: id)
            return
        }
        commit(id) { folder in
            folder.record = plan.record
            if folder.destinations != nil {
                let tracked = Set(plan.record.entries.filter(\.owned).map(\.libraryID))
                    .union(plan.record.pendingRemovals).union(plan.record.heldRemovals)
                folder.destinations = folder.destinations?.filter { tracked.contains($0.key) }
            }
            if contents.folder.path != folder.path { folder.path = contents.folder.path }
        }
        startWatching(id, at: contents.folder)
        if !plan.imports.isEmpty { await runImports(plan.imports, from: contents.folder, installedBefore: installed, for: id) }
        await runRemovals(for: id, unchangedSince: changesAtScan)
        if plan.needsRecheck { recheck(id) }
    }

    private func runImports(
        _ items: [LinkedFolderScan.Item], from folder: URL, installedBefore: Set<String>, for id: UUID
    ) async {
        guard let importer, let link = folders.first(where: { $0.id == id }) else { return recheck(id) }
        let expected = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.libraryID) })
        var replacing: [String: LinkedFolderDestinationIdentity] = [:]
        for entry in link.record.entries where entry.owned {
            if let target = expected[entry.path], target.lowercased() == entry.libraryID.lowercased() {
                replacing[target] = link.destinations?[entry.libraryID]
            }
        }
        let report: WallpaperImportService.Report
        do {
            report = try await importer(items.map { folder.appendingPathComponent($0.path) }, replacing, expected)
        } catch is LibraryImportStore.Busy {
            return recheck(id)
        } catch {
            statuses[id]?.failure = error.localizedDescription
            AppLog.warn("linked folders: import failed: \(error.localizedDescription)")
            return
        }
        var notReached = false
        var held: [String] = []
        commit(id) { link in
            defer {
                held = LinkedFolderPlanner.holdMassRemovals(in: &link.record)
            }
            for item in items {
                switch LinkedFolderPlanner.outcome(of: item, in: report) {
                case .imported(let libraryID):
                    let identity = report.linkedDestinations[libraryID]
                    let destination = LinkedFolderPlanner.recordImport(
                        item, importedID: libraryID, owned: identity != nil, mirrorsDeletions: link.mirrorsDeletions,
                        installedBefore: installedBefore, in: &link.record)
                    if let identity, let destination {
                        if link.destinations == nil { link.destinations = [:] }
                        link.destinations?[destination] = identity
                    }
                case .failed:
                    LinkedFolderPlanner.recordImport(item, importedID: nil, owned: false, mirrorsDeletions: link.mirrorsDeletions,
                                                     installedBefore: installedBefore, in: &link.record)
                case .notReached:
                    notReached = true
                }
            }
        }
        statuses[id]?.held = held
        statuses[id]?.failure = report.failures.first
        if !report.failures.isEmpty {
            AppLog.warn("linked folders: \(report.failures.count) file(s) could not be imported: \(report.failures.joined(separator: "; "))")
        }
        if notReached { recheck(id) }
    }

    /// What is due to be removed for the link now, read from its current record: nothing once it
    /// is unlinked or Mirror deletions is off, or while the library is not read.
    private func dueRemovals(_ id: UUID) -> [String] {
        guard isStarted, pendingEdits[id] == nil,
              let link = folders.first(where: { $0.id == id }), link.mirrorsDeletions,
              let installed = installedIDs?() else { return [] }
        return LinkedFolderPlanner.dueRemovals(link.record, installed: installed)
    }

    /// Removes what the link has due after any import of this look, so the item a renamed and
    /// changed file replaced goes in the same look.
    private func runRemovals(for id: UUID, unchangedSince changesAtScan: UInt64) async {
        // The folder changed since the scan this look is from (a file may be back): the look the
        // change scheduled scans again before anything is removed.
        let changed = { [weak self] in
            guard let self else { return true }
            return self.changes[id, default: 0] != changesAtScan || self.dirty.contains(id)
        }
        guard !changed() else { return }
        let due = dueRemovals(id)
        guard !due.isEmpty else { return }
        guard let remover, let link = folders.first(where: { $0.id == id }) else {
            AppLog.info("linked folders: \(due.count) removal(s) wait for the control panel to open")
            return
        }
        // The same while the removal waits for its turn in the panel's queue.
        do {
            let authorized = Set(due)
            let removed = Set(try await remover(due, link.destinations ?? [:]) { [weak self] in
                guard let self, self.isStarted, self.pendingEdits[id] == nil, self.remover != nil, !changed(),
                      self.folders.first(where: { $0.id == id })?.mirrorsDeletions == true else { return [] }
                return authorized
            })
            commit(id) { link in
                LinkedFolderPlanner.recordRemoved(removed, in: &link.record)
                for id in removed { link.destinations?[id] = nil }
            }
            // A batch cut at the panel's limit goes on; one that moved nothing waits for a look.
            if !removed.isEmpty, !dueRemovals(id).isEmpty { schedule(id) }
            if !removed.isEmpty { AppLog.info("linked folders: removed \(removed.count) wallpaper(s) whose files left the folder") }
        } catch {
            statuses[id]?.failure = error.localizedDescription
            AppLog.warn("linked folders: removal failed: \(error.localizedDescription)")
        }
    }

    /// Looks at the folder again after `recheckDelay`; a no-op while one is already due.
    private func recheck(_ id: UUID) {
        guard isStarted, rechecks[id] == nil else { return }
        let delay = recheckDelay
        let sleep = self.sleep
        rechecks[id] = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.rechecks[id] = nil
            self.schedule(id)
        }
    }

    private func startWatching(_ id: UUID, at folder: URL) {
        guard watchedPaths[id] != folder.path else { return }
        stopWatching(id)
        guard let watcher = watch(folder, { [weak self] in
            guard let self else { return }
            self.changes[id, default: 0] &+= 1
            self.schedule(id)
        }) else { return }
        watchers[id] = watcher
        watchedPaths[id] = folder.path
    }

    private func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.stop()
        watchedPaths[id] = nil
    }

    /// While a folder is missing, its nearest existing parent is watched, so a folder put back
    /// is noticed. Not the home folder, `/` or `/Volumes`, whose changes never stop; a folder
    /// under them waits for a wake, a disk mounting or the panel opening.
    private func watchNearestAncestor(of folder: URL, for id: UUID) {
        var ancestor = folder.deletingLastPathComponent().standardizedFileURL
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
        }
        guard !["/", "/Volumes", home.standardizedFileURL.path].contains(ancestor.path) else {
            return stopWatching(id)
        }
        startWatching(id, at: ancestor)
    }

    // MARK: Persistence

    /// Reads the links once, and again while they could not be read: a record the user repaired
    /// is picked up at the next edit, and none is saved over until then.
    private func loadIfNeeded() {
        guard !loaded || loadFailure != nil else { return }
        loaded = true
        do {
            folders = try store.load()
            loadFailure = nil
        } catch {
            loadFailure = error
            AppLog.error("linked folders: \(store.file.lastPathComponent) could not be read, so links are not changed or saved: \(error.localizedDescription)")
        }
    }

    private func update(_ id: UUID, _ change: @escaping @MainActor (inout LinkedFolder) -> Void) async throws {
        try await transact(holdingRemovalsFor: id) { links in
            guard let index = links.firstIndex(where: { $0.id == id }) else {
                throw WallpaperActionError(message: String(localized: "This folder is no longer linked."))
            }
            change(&links[index])
        }
    }

    /// Applies a change the user made only once it is saved; a failed save leaves the links as
    /// they were, so the action can simply be tried again.
    ///
    /// The change is saved on a copy, then applied to the links as they are by then: what a look
    /// recorded while the save ran is kept whether the save succeeds or fails.
    private func transact(holdingRemovalsFor id: UUID? = nil,
                          _ change: @escaping @MainActor (inout [LinkedFolder]) throws -> Void) async throws {
        loadIfNeeded()
        if let loadFailure { throw loadFailure }
        if let id { pendingEdits[id, default: 0] += 1 }
        defer {
            if let id, pendingEdits[id] == 1 {
                pendingEdits[id] = nil
                schedule(id)
            } else if let id {
                pendingEdits[id]? -= 1
            }
        }
        try await enqueueSave(change).value
    }

    /// Applies a change from a reconcile; a failed save is logged, and the change is kept in memory.
    private func commit(_ id: UUID, _ change: (inout LinkedFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var folder = folders[index]
        change(&folder)
        guard folder != folders[index] else { return }
        folders[index] = folder
        guard loadFailure == nil else { return }
        let write = enqueueSave()
        Task { do { try await write.value } catch { AppLog.warn("linked folders: could not save: \(error.localizedDescription)") } }
    }

    /// Takes each snapshot in its turn, after earlier edits have both saved and updated the model.
    private func enqueueSave(_ change: (@MainActor (inout [LinkedFolder]) throws -> Void)? = nil) -> Task<Void, Error> {
        let previous = saving
        let write = Task { [self] in
            _ = try? await previous?.value
            var snapshot = folders
            try change?(&snapshot)
            try await Task.detached(priority: .utility) { [store, snapshot] in
                try await store.save(snapshot)
            }.value
            try change?(&folders)
        }
        saving = write
        return write
    }

    /// The folder to link and a bookmark of it. Runs off the main actor: it reads the disk.
    nonisolated static func validate(_ url: URL, library: URL, support: URL) throws -> (URL, Data?) {
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder.path) else {
            throw WallpaperActionError(message: String(localized: "The folder could not be read."))
        }
        for own in [library, support].map({ $0.resolvingSymlinksInPath().standardizedFileURL }) {
            if isWithin(folder, own) || isWithin(own, folder) {
                throw WallpaperActionError(message: String(localized: "Choose a source outside WallpaperMachine’s managed library."))
            }
        }
        return (folder, try? folder.bookmarkData())
    }

    nonisolated private static func isWithin(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }
}
