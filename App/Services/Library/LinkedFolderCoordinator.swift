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
    @ObservationIgnored var importer: (@MainActor ([URL]) async throws -> WallpaperImportService.Report)?
    /// Moves wallpapers to the Trash and forgets them as the panel's Delete does, answering the
    /// ids it removed. Set by an open panel, nil while none is.
    @ObservationIgnored var remover: (@MainActor ([String]) async throws -> [String])? {
        didSet { if remover != nil, folders.contains(where: { !$0.record.pendingRemovals.isEmpty }) { reconcileAll() } }
    }

    @ObservationIgnored private let store: LinkedFolderStore
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

    /// A file still being copied is looked at again after `recheckDelay`; only then, if it kept
    /// its size, is it imported.
    init(
        store: LinkedFolderStore = LinkedFolderStore(),
        scanner: any LinkedFolderScanning = LinkedFolderScanner(),
        watch: @escaping @MainActor (URL, @escaping @MainActor () -> Void) -> (any DirectoryWatching)? = {
            DirectoryWatcher(url: $0, onChange: $1)
        },
        recheckDelay: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
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
        guard !folders.contains(where: { $0.path == folder.path }) else {
            throw WallpaperActionError(message: String(localized: "This folder is already linked."))
        }
        let link = LinkedFolder(path: folder.path, bookmark: bookmark)
        folders.append(link)
        try save()
        schedule(link.id)
        return link
    }

    /// Stops following a folder. What it imported stays in the library.
    func unlink(_ id: UUID) throws {
        loadIfNeeded()
        folders.removeAll { $0.id == id }
        stopWatching(id)
        statuses[id] = nil
        rechecks.removeValue(forKey: id)?.cancel()
        try save()
    }

    /// Mirror deletions applies to files deleted from now on; wallpapers already kept stay.
    func setMirrorsDeletions(_ on: Bool, for id: UUID) throws {
        try update(id) { $0.mirrorsDeletions = on }
        if !on { statuses[id]?.held = [] }
        schedule(id)
    }

    /// Removes the held wallpapers whose files left the folder.
    func removeHeld(for id: UUID) throws {
        let held = status(of: id).held
        guard !held.isEmpty else { return }
        try update(id) { LinkedFolderPlanner.confirmHeld(held, in: &$0.record) }
        statuses[id]?.held = []
        schedule(id)
    }

    /// Keeps the held wallpapers in the library; their files are not asked about again.
    func keepHeld(for id: UUID) throws {
        let held = status(of: id).held
        guard !held.isEmpty else { return }
        try update(id) { LinkedFolderPlanner.keepHeld(held, in: &$0.record) }
        statuses[id]?.held = []
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
        guard let installed = installedIDs?() else {
            recheck(id)  // the library is not read yet
            return
        }
        let scan = await scanner.scan(folder)
        guard isStarted, let current = folders.first(where: { $0.id == id }) else { return }
        let plan = LinkedFolderPlanner.plan(record: current.record, scan: scan,
                                            mirrorsDeletions: current.mirrorsDeletions, installed: installed)
        var status = self.status(of: id)
        status.isUnavailable = plan.isUnavailable
        status.held = plan.held
        statuses[id] = status
        guard case .contents(let contents) = scan else {
            stopWatching(id)
            return
        }
        commit(id) { folder in
            folder.record = plan.record
            if contents.folder.path != folder.path { folder.path = contents.folder.path }
        }
        startWatching(id, at: contents.folder)
        if !plan.imports.isEmpty { await runImports(plan.imports, from: contents.folder, for: id) }
        if !plan.removals.isEmpty { await runRemovals(plan.removals, for: id) }
        if plan.needsRecheck { recheck(id) }
    }

    private func runImports(_ items: [LinkedFolderScan.Item], from folder: URL, for id: UUID) async {
        guard let importer else { return recheck(id) }
        let report: WallpaperImportService.Report
        do {
            report = try await importer(items.map { folder.appendingPathComponent($0.path) })
        } catch {
            // Another import is running: its files are looked at again once it had time to finish.
            AppLog.info("linked folders: import waits: \(error.localizedDescription)")
            return recheck(id)
        }
        var notReached = false
        commit(id) { link in
            for item in items {
                switch LinkedFolderPlanner.outcome(of: item, in: report) {
                case .imported(let libraryID):
                    LinkedFolderPlanner.recordImport(item, importedID: libraryID, mirrorsDeletions: link.mirrorsDeletions,
                                                     in: &link.record)
                case .failed:
                    LinkedFolderPlanner.recordImport(item, importedID: nil, mirrorsDeletions: link.mirrorsDeletions,
                                                     in: &link.record)
                case .notReached:
                    notReached = true
                }
            }
        }
        statuses[id]?.failure = report.failures.first
        if !report.failures.isEmpty {
            AppLog.warn("linked folders: \(report.failures.count) file(s) could not be imported: \(report.failures.joined(separator: "; "))")
        }
        if notReached { recheck(id) }
    }

    private func runRemovals(_ ids: [String], for id: UUID) async {
        guard let remover else {
            AppLog.info("linked folders: \(ids.count) removal(s) wait for the control panel to open")
            return
        }
        do {
            let removed = Set(try await remover(ids))
            commit(id) { $0.record.pendingRemovals.removeAll { removed.contains($0) } }
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
        guard let watcher = watch(folder, { [weak self] in self?.schedule(id) }) else { return }
        watchers[id] = watcher
        watchedPaths[id] = folder.path
    }

    private func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.stop()
        watchedPaths[id] = nil
    }

    // MARK: Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        folders = store.load()
    }

    private func update(_ id: UUID, _ change: (inout LinkedFolder) -> Void) throws {
        loadIfNeeded()
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            throw WallpaperActionError(message: String(localized: "This folder is no longer linked."))
        }
        change(&folders[index])
        try save()
    }

    /// Applies a change from a reconcile; a failed save is logged, and the change is kept in memory.
    private func commit(_ id: UUID, _ change: (inout LinkedFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var folder = folders[index]
        change(&folder)
        guard folder != folders[index] else { return }
        folders[index] = folder
        do { try save() } catch { AppLog.warn("linked folders: could not save: \(error.localizedDescription)") }
    }

    private func save() throws { try store.save(folders) }

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
