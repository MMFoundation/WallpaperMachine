import Foundation
import XCTest

@testable import WallpaperMachine

/// The coordinator over fake folders, imports and removals: two looks before an import, removals
/// waiting for an open panel, a folder that cannot be read, and unlinking. Nothing here watches a
/// real folder or touches the library; the links are saved in a temporary file.
@MainActor
final class LinkedFolderCoordinatorTests: XCTestCase {
  private final class FakeScanner: LinkedFolderScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var result: LinkedFolderScan = .unavailable
    private var hook: (@MainActor () -> Void)?
    var next: LinkedFolderScan {
      get { lock.withLock { result } }
      set { lock.withLock { result = newValue } }
    }
    /// Runs while the scan is under way, before it answers.
    var whileScanning: (@MainActor () -> Void)? {
      get { lock.withLock { hook } }
      set { lock.withLock { hook = newValue } }
    }
    func scan(_ folder: LinkedFolder) async -> LinkedFolderScan {
      if let whileScanning { await whileScanning() }
      return next
    }
  }

  private final class FakeWatcher: DirectoryWatching {
    func stop() {}
  }

  /// A remover that removes whatever is still due when its turn comes, as the panel's does.
  private func remover(_ log: @escaping @MainActor ([String]) -> Void) -> @MainActor ([String], @escaping @MainActor () -> Set<String>) async throws -> [String] {
    { [unowned self] ids, stillDue in
      let due = ids.filter(stillDue().contains)
      log(due)
      installed.subtract(due)
      return due
    }
  }

  private var root: URL!
  private var scanner: FakeScanner!
  private var imported: [[String]] = []
  private var watched: [String] = []
  /// What each watched folder's watcher calls when the folder changes.
  private var changeHandlers: [String: @MainActor () -> Void] = [:]
  private var duringImport: (@MainActor () async throws -> Void)?
  private var installed: Set<String> = []
  private var coordinator: LinkedFolderCoordinator!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "linked-folder-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    scanner = FakeScanner()
    imported = []
    installed = []
    watched = []
    changeHandlers = [:]
    duringImport = nil
    coordinator = LinkedFolderCoordinator(
      store: LinkedFolderStore(file: root.appendingPathComponent("LinkedFolders.json")),
      scanner: scanner, watch: { [unowned self] url, onChange in
        watched.append(url.lastPathComponent)
        changeHandlers[url.lastPathComponent] = onChange
        return FakeWatcher()
      },
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      notifications: NotificationCenter())
    coordinator.installedIDs = { [unowned self] in installed }
    coordinator.importer = { [unowned self] urls in
      imported.append(urls.map(\.lastPathComponent))
      try await duringImport?()
      var report = WallpaperImportService.Report()
      for url in urls {
        let id = WallpaperImportService.libraryID(forSourceNamed: url.lastPathComponent, isDirectory: false)!
        report.importedIDs.append(id)
        installed.insert(id)
      }
      return report
    }
  }

  override func tearDown() async throws {
    coordinator.stop()
    try? FileManager.default.removeItem(at: root)
  }

  private func contents(_ names: [String], size: Int64 = 10, fileIDs: [String: UInt64] = [:]) -> LinkedFolderScan {
    .contents(.init(folder: root.appendingPathComponent("Folder"), items: names.map {
      LinkedFolderScan.Item(
        path: $0, libraryID: WallpaperImportService.libraryID(forSourceNamed: $0, isDirectory: false)!,
        stamp: .init(size: size, modified: 1), fileID: fileIDs[$0])
    }))
  }

  private func link(mirror: Bool = false) async throws -> UUID {
    let folder = root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    coordinator.start()
    let id = try await coordinator.add(folder, library: root.appendingPathComponent("Library"),
                                       support: root.appendingPathComponent("Support")).id
    await coordinator.waitForIdle()
    if mirror { try await coordinator.setMirrorsDeletions(true, for: id) }
    await coordinator.waitForIdle()
    return id
  }

  private func look() async {
    coordinator.reconcileAll()
    await coordinator.waitForIdle()
  }

  func testFileIsImportedAtTheSecondLookAndRemembered() async throws {
    scanner.next = contents(["rain.mp4"])
    _ = try await link()
    XCTAssertEqual(imported, [], "the first look only notes the file's size")

    await look()
    XCTAssertEqual(imported, [["rain.mp4"]])
    await look()
    XCTAssertEqual(imported, [["rain.mp4"]])

    let reloaded = try LinkedFolderStore(file: root.appendingPathComponent("LinkedFolders.json")).load()
    XCTAssertEqual(reloaded.first?.record.entries.map(\.libraryID), ["local-rain.mp4"])
  }

  func testRemovalWaitsForThePanelThenRuns() async throws {
    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    let id = try await link(mirror: true)
    await look()
    XCTAssertEqual(installed.count, 5)

    scanner.next = contents(["b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    await look()
    XCTAssertEqual(coordinator.folders.first?.record.entries.first { $0.path == "a.mp4" }?.state, .leaving)

    var removed: [[String]] = []
    coordinator.remover = remover { removed.append($0) }
    await coordinator.waitForIdle()
    XCTAssertEqual(removed, [["local-a.mp4"]])
    XCTAssertFalse(coordinator.folders.first { $0.id == id }?.record.entries.contains { $0.path == "a.mp4" } ?? true)
  }

  func testUnreadableFolderRemovesNothing() async throws {
    scanner.next = contents(["a.mp4", "b.mp4"])
    let id = try await link(mirror: true)
    await look()
    var removed: [String] = []
    coordinator.remover = remover { removed += $0 }

    scanner.next = .unavailable
    await look()
    XCTAssertTrue(coordinator.status(of: id).isUnavailable)
    XCTAssertEqual(removed, [])
    XCTAssertEqual(coordinator.folders.first?.record.entries.count, 2)
  }

  func testUnlinkingKeepsTheWallpapers() async throws {
    scanner.next = contents(["a.mp4"])
    let id = try await link(mirror: true)
    await look()
    var removed: [String] = []
    coordinator.remover = remover { removed += $0 }

    try await coordinator.unlink(id)
    scanner.next = contents([])
    await look()
    XCTAssertEqual(coordinator.folders, [])
    XCTAssertEqual(removed, [])
    XCTAssertEqual(installed, ["local-a.mp4"])
  }

  // Review of #276.

  func testUnlinkingDuringAnImportCallsOffItsRemovals() async throws {
    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    let id = try await link(mirror: true)
    var removed: [String] = []
    coordinator.remover = remover { removed += $0 }

    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4", "new.mp4"])
    await look()
    // a.mp4 leaves in the look that imports new.mp4; the user unlinks while it imports.
    scanner.next = contents(["b.mp4", "c.mp4", "d.mp4", "e.mp4", "new.mp4"])
    duringImport = { [unowned self] in try await coordinator.unlink(id) }
    await look()
    XCTAssertEqual(imported.last, ["new.mp4"])
    XCTAssertEqual(removed, [])
    XCTAssertTrue(installed.contains("local-a.mp4"))
  }

  func testMirrorDeletionsTurnedOffDuringAnImportCallsOffItsRemovals() async throws {
    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    let id = try await link(mirror: true)
    var removed: [String] = []
    coordinator.remover = remover { removed += $0 }

    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4", "new.mp4"])
    await look()
    scanner.next = contents(["b.mp4", "c.mp4", "d.mp4", "e.mp4", "new.mp4"])
    duringImport = { [unowned self] in try await coordinator.setMirrorsDeletions(false, for: id) }
    await look()
    XCTAssertEqual(imported.last, ["new.mp4"])
    XCTAssertEqual(removed, [])
    XCTAssertEqual(coordinator.folders.first?.record.entries.first { $0.path == "a.mp4" }?.state, .missing)
  }

  func testRenamedAndChangedFileReplacesItsOldWallpaperInOneLook() async throws {
    scanner.next = contents(["rain.mp4"], fileIDs: ["rain.mp4": 7])
    _ = try await link(mirror: true)
    var removed: [String] = []
    coordinator.remover = remover { removed += $0 }

    scanner.next = contents(["storm.mp4"], size: 99, fileIDs: ["storm.mp4": 7])
    await look()  // notes the new size
    await look()  // imports storm.mp4, then removes the item rain.mp4 became
    XCTAssertEqual(imported.last, ["storm.mp4"])
    XCTAssertEqual(removed, ["local-rain.mp4"])
  }

  func testConfirmationRemovesOnlyWhatItCounted() async throws {
    let names = ["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4", "f.mp4"]
    scanner.next = contents(names)
    let id = try await link(mirror: true)
    var removed: [String] = []
    coordinator.remover = remover { removed += $0 }

    scanner.next = contents(Array(names.dropFirst(2)))
    await look()
    let shown = coordinator.status(of: id).held
    XCTAssertEqual(Set(shown), ["local-a.mp4", "local-b.mp4"])

    // Two more leave while the sheet is open.
    scanner.next = contents(Array(names.dropFirst(4)))
    await look()
    XCTAssertEqual(coordinator.status(of: id).held.count, 4)

    try await coordinator.removeHeld(shown, for: id)
    await coordinator.waitForIdle()
    XCTAssertEqual(Set(removed), ["local-a.mp4", "local-b.mp4"])
    XCTAssertTrue(installed.isSuperset(of: ["local-c.mp4", "local-d.mp4"]))
  }

  /// A file that comes back while its removal waits for the panel's turn keeps its wallpaper:
  /// the folder changed, so nothing goes and the look that change scheduled decides again.
  func testFolderChangeWhileARemovalWaitsCallsItOff() async throws {
    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    let id = try await link(mirror: true)
    await look()
    scanner.next = contents(["b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    await look()

    var removed: [[String]] = []
    coordinator.remover = { [unowned self] ids, stillDue in
      scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4"])
      changeHandlers["Folder"]?()
      let due = ids.filter(stillDue().contains)
      removed.append(due)
      installed.subtract(due)
      return due
    }
    await coordinator.waitForIdle()
    XCTAssertEqual(removed, [[]])
    XCTAssertTrue(installed.contains("local-a.mp4"))
    XCTAssertEqual(coordinator.folders.first { $0.id == id }?.record.entries.first { $0.path == "a.mp4" }?.state, .present)
  }

  /// The folder is watched before its first scan, so a file that arrives while the scan runs is
  /// still reported.
  func testFolderIsWatchedBeforeItsFirstScan() async throws {
    var watchedDuringScan: [String] = []
    scanner.whileScanning = { [unowned self] in watchedDuringScan = watched }
    scanner.next = contents([])
    _ = try await link()
    XCTAssertEqual(watchedDuringScan, ["Folder"])
  }

  /// While the library is away nothing is looked at again on a timer: its drive's return looks
  /// at every folder anyway.
  func testNothingIsRecheckedWhileTheLibraryIsAway() async throws {
    final class Count: @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      func add() { lock.withLock { count += 1 } }
      var value: Int { lock.withLock { count } }
    }
    let sleeps = Count()
    coordinator.stop()
    coordinator = LinkedFolderCoordinator(
      store: LinkedFolderStore(file: root.appendingPathComponent("Away.json")),
      scanner: scanner, watch: { _, _ in FakeWatcher() },
      sleep: { _ in
        sleeps.add()
        try await Task.sleep(for: .seconds(3600))
      },
      notifications: NotificationCenter())
    coordinator.installedIDs = { nil }
    scanner.next = contents(["a.mp4"])
    _ = try await link()
    await look()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(sleeps.value, 0)
  }

  func testMissingFolderIsWatchedThroughItsParentUntilItIsBack() async throws {
    scanner.next = .unavailable
    _ = try await link()
    XCTAssertEqual(watched.last, root.lastPathComponent, "the folder's parent is watched while it is missing")

    scanner.next = contents([])
    await look()
    XCTAssertEqual(watched.last, "Folder")
  }

  func testRefusesTheLibraryAndAFolderLinkedTwice() async throws {
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library.appendingPathComponent("Inside"), withIntermediateDirectories: true)
    do {
      _ = try await coordinator.add(library.appendingPathComponent("Inside"), library: library, support: root.appendingPathComponent("Support"))
      XCTFail("a folder inside the library was linked")
    } catch {}

    _ = try await link()
    do {
      _ = try await coordinator.add(root.appendingPathComponent("Folder"), library: library, support: root.appendingPathComponent("Support"))
      XCTFail("a folder was linked twice")
    } catch {}
    XCTAssertEqual(coordinator.folders.count, 1)
  }

  func testFileAnotherImportAddsDuringTheScanIsNotClaimed() async throws {
    scanner.next = contents(["rain.mp4"])
    _ = try await link()  // the first look only notes rain.mp4
    XCTAssertEqual(imported, [])
    scanner.whileScanning = { [unowned self] in installed.insert("local-rain.mp4") }  // a drop on the Dock icon
    await look()
    scanner.whileScanning = nil
    XCTAssertEqual(imported, [])
    XCTAssertEqual(coordinator.folders.first?.record.entries.map(\.owned), [false])
  }

  func testLinkThatCouldNotBeSavedIsNotKept() async throws {
    let blocker = root.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let unsaveable = LinkedFolderCoordinator(
      store: LinkedFolderStore(file: blocker.appendingPathComponent("LinkedFolders.json")), scanner: scanner,
      watch: { _, _ in FakeWatcher() }, notifications: NotificationCenter())
    let folder = root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      _ = try await unsaveable.add(folder, library: root.appendingPathComponent("Library"), support: root.appendingPathComponent("Support"))
      XCTFail("a link that could not be saved was added")
    } catch {}
    XCTAssertEqual(unsaveable.folders, [])
  }

  func testUnreadableLinksAreNotSavedOver() async throws {
    let file = root.appendingPathComponent("Unreadable.json", isDirectory: true)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)  // a folder: no read
    let blocked = LinkedFolderCoordinator(
      store: LinkedFolderStore(file: file), scanner: scanner, watch: { _, _ in FakeWatcher() },
      notifications: NotificationCenter())
    let folder = root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      _ = try await blocked.add(folder, library: root.appendingPathComponent("Library"), support: root.appendingPathComponent("Support"))
      XCTFail("links were saved over a record that could not be read")
    } catch {}
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)

    // Once the record can be read again, the next edit reads it and goes through.
    try FileManager.default.removeItem(at: file)
    _ = try await blocked.add(folder, library: root.appendingPathComponent("Library"), support: root.appendingPathComponent("Support"))
    XCTAssertEqual(try LinkedFolderStore(file: file).load().count, 1)
    blocked.stop()
  }
}
