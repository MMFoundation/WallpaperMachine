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
    var next: LinkedFolderScan {
      get { lock.withLock { result } }
      set { lock.withLock { result = newValue } }
    }
    func scan(_ folder: LinkedFolder) async -> LinkedFolderScan { next }
  }

  private final class FakeWatcher: DirectoryWatching {
    func stop() {}
  }

  private var root: URL!
  private var scanner: FakeScanner!
  private var imported: [[String]] = []
  private var installed: Set<String> = []
  private var coordinator: LinkedFolderCoordinator!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "linked-folder-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    scanner = FakeScanner()
    imported = []
    installed = []
    coordinator = LinkedFolderCoordinator(
      store: LinkedFolderStore(file: root.appendingPathComponent("LinkedFolders.json")),
      scanner: scanner, watch: { _, _ in FakeWatcher() },
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      notifications: NotificationCenter())
    coordinator.installedIDs = { [unowned self] in installed }
    coordinator.importer = { [unowned self] urls in
      imported.append(urls.map(\.lastPathComponent))
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

  private func contents(_ names: [String]) -> LinkedFolderScan {
    .contents(.init(folder: root.appendingPathComponent("Folder"), items: names.map {
      LinkedFolderScan.Item(
        path: $0, libraryID: WallpaperImportService.libraryID(forSourceNamed: $0, isDirectory: false)!,
        stamp: .init(size: 10, modified: 1), fileID: nil)
    }))
  }

  private func link(mirror: Bool = false) async throws -> UUID {
    let folder = root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    coordinator.start()
    let id = try await coordinator.add(folder, library: root.appendingPathComponent("Library"),
                                       support: root.appendingPathComponent("Support")).id
    await coordinator.waitForIdle()
    if mirror { try coordinator.setMirrorsDeletions(true, for: id) }
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

    let reloaded = LinkedFolderStore(file: root.appendingPathComponent("LinkedFolders.json")).load()
    XCTAssertEqual(reloaded.first?.record.entries.map(\.libraryID), ["local-rain.mp4"])
  }

  func testRemovalWaitsForThePanelThenRuns() async throws {
    scanner.next = contents(["a.mp4", "b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    let id = try await link(mirror: true)
    await look()
    XCTAssertEqual(installed.count, 5)

    scanner.next = contents(["b.mp4", "c.mp4", "d.mp4", "e.mp4"])
    await look()
    XCTAssertEqual(coordinator.folders.first?.record.pendingRemovals, ["local-a.mp4"])

    var removed: [[String]] = []
    coordinator.remover = { ids in
      removed.append(ids)
      return ids
    }
    await coordinator.waitForIdle()
    XCTAssertEqual(removed, [["local-a.mp4"]])
    XCTAssertEqual(coordinator.folders.first { $0.id == id }?.record.pendingRemovals, [])
  }

  func testUnreadableFolderRemovesNothing() async throws {
    scanner.next = contents(["a.mp4", "b.mp4"])
    let id = try await link(mirror: true)
    await look()
    var removed: [String] = []
    coordinator.remover = { ids in
      removed += ids
      return ids
    }

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
    coordinator.remover = { ids in
      removed += ids
      return ids
    }

    try coordinator.unlink(id)
    scanner.next = contents([])
    await look()
    XCTAssertEqual(coordinator.folders, [])
    XCTAssertEqual(removed, [])
    XCTAssertEqual(installed, ["local-a.mp4"])
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
}
