import Foundation
import XCTest

@testable import WallpaperMachine

/// The rules a linked folder follows (docs/features/linked-folders.md), on records and folder
/// contents built in memory: no disk, no library, no clock.
final class LinkedFolderPlannerTests: XCTestCase {
  private let folderURL = URL(fileURLWithPath: "/Linked", isDirectory: true)

  private func item(_ name: String, size: Int64 = 100, modified: Int64 = 1, fileID: UInt64? = nil)
    -> LinkedFolderScan.Item
  {
    LinkedFolderScan.Item(
      path: name, libraryID: WallpaperImportService.libraryID(forSourceNamed: name, isDirectory: false)!,
      stamp: LinkedFolderStamp(size: size, modified: modified), fileID: fileID)
  }

  private func entry(_ item: LinkedFolderScan.Item, owned: Bool = true) -> LinkedFolderRecord.Entry {
    LinkedFolderRecord.Entry(
      path: item.path, libraryID: item.libraryID, stamp: item.stamp, fileID: item.fileID, owned: owned)
  }

  private func scan(_ items: [LinkedFolderScan.Item], alsoPresent: Set<String> = []) -> LinkedFolderScan {
    .contents(.init(folder: folderURL, items: items, alsoPresent: alsoPresent))
  }

  private func plan(
    _ record: LinkedFolderRecord, _ scan: LinkedFolderScan, mirror: Bool = false, installed: Set<String> = []
  ) -> LinkedFolderPlanner.Plan {
    LinkedFolderPlanner.plan(record: record, scan: scan, mirrorsDeletions: mirror, installed: installed)
  }

  func testLibraryIDsFollowTheImport() {
    XCTAssertEqual(WallpaperImportService.libraryID(forSourceNamed: "Rain.MP4", isDirectory: false), "local-Rain.MP4")
    XCTAssertEqual(WallpaperImportService.libraryID(forSourceNamed: "a.png", isDirectory: false), "image-a.png")
    XCTAssertEqual(WallpaperImportService.libraryID(forSourceNamed: "page.html", isDirectory: false), "local-page.html")
    XCTAssertEqual(WallpaperImportService.libraryID(forSourceNamed: "Project", isDirectory: true), "Project")
    XCTAssertNil(WallpaperImportService.libraryID(forSourceNamed: "notes.txt", isDirectory: false))
  }

  func testNewFileIsImportedOnlyOnceItsSizeHoldsStill() {
    let copying = item("rain.mp4", size: 10)
    let first = plan(LinkedFolderRecord(), scan([copying]))
    XCTAssertEqual(first.imports, [])
    XCTAssertTrue(first.needsRecheck)

    let grown = item("rain.mp4", size: 20)
    let second = plan(first.record, scan([grown]))
    XCTAssertEqual(second.imports, [], "a file whose size changed between two looks is still being copied")
    XCTAssertTrue(second.needsRecheck)

    let third = plan(second.record, scan([grown]))
    XCTAssertEqual(third.imports, [grown])
    XCTAssertFalse(third.needsRecheck)
  }

  func testImportedFileIsRecordedAndNotImportedAgain() {
    let rain = item("rain.mp4")
    var record = LinkedFolderRecord()
    LinkedFolderPlanner.recordImport(rain, importedID: rain.libraryID, mirrorsDeletions: false, installedBefore: [], in: &record)
    XCTAssertEqual(record.entries, [entry(rain)])
    XCTAssertEqual(record.pending, [:])

    let again = plan(record, scan([rain]), installed: [rain.libraryID])
    XCTAssertEqual(again.imports, [])
    XCTAssertEqual(again.removals, [])
    XCTAssertFalse(again.needsRecheck)
  }

  func testChangedFileIsImportedAgainOnceSettled() {
    let old = item("rain.mp4", size: 100)
    let record = LinkedFolderRecord(entries: [entry(old)])
    let changed = item("rain.mp4", size: 200, modified: 2)

    let first = plan(record, scan([changed]), installed: [old.libraryID])
    XCTAssertEqual(first.imports, [])
    XCTAssertTrue(first.needsRecheck)
    let second = plan(first.record, scan([changed]), installed: [old.libraryID])
    XCTAssertEqual(second.imports, [changed])
  }

  func testRenamedFileKeepsItsWallpaper() {
    let before = item("rain.mp4", fileID: 42)
    let record = LinkedFolderRecord(entries: [entry(before)])
    let after = item("Rain at night.mp4", fileID: 42)

    let result = plan(record, scan([after]), mirror: true, installed: [before.libraryID])
    XCTAssertEqual(result.imports, [])
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.record.entries.map(\.path), ["Rain at night.mp4"])
    XCTAssertEqual(result.record.entries.map(\.libraryID), [before.libraryID])
  }

  func testRenamedAndChangedFileRetiresTheOldItemWhenMirroring() {
    let before = item("rain.mp4", fileID: 42)
    var record = LinkedFolderRecord(entries: [entry(before)])
    let after = item("storm.mp4", size: 300, modified: 5, fileID: 42)
    record = plan(record, scan([after]), mirror: true, installed: [before.libraryID]).record
    let settled = plan(record, scan([after]), mirror: true, installed: [before.libraryID])
    XCTAssertEqual(settled.imports, [after])

    var imported = settled.record
    LinkedFolderPlanner.recordImport(
      after, importedID: after.libraryID, mirrorsDeletions: true, installedBefore: [before.libraryID], in: &imported)
    XCTAssertEqual(imported.entries.map(\.libraryID), [after.libraryID])
    XCTAssertEqual(imported.pendingRemovals, [before.libraryID])
    XCTAssertEqual(LinkedFolderPlanner.dueRemovals(imported, installed: [before.libraryID, after.libraryID]), [before.libraryID])
  }

  /// On the usual case-insensitive library volume, `Rain.mp4` and `rain.mp4` are one folder: a
  /// rename that only changes case and an edit import over it, and nothing is left to remove.
  func testCaseOnlyRenameAndEditRemovesNothing() {
    let before = item("rain.mp4", fileID: 42)
    var record = LinkedFolderRecord(entries: [entry(before)])
    let after = item("Rain.mp4", size: 300, modified: 5, fileID: 42)
    record = plan(record, scan([after]), mirror: true, installed: [before.libraryID]).record
    let settled = plan(record, scan([after]), mirror: true, installed: [before.libraryID])
    XCTAssertEqual(settled.imports, [after])

    var imported = settled.record
    LinkedFolderPlanner.recordImport(
      after, importedID: after.libraryID, mirrorsDeletions: true, installedBefore: [before.libraryID], in: &imported)
    XCTAssertEqual(imported.pendingRemovals, [])
    XCTAssertEqual(LinkedFolderPlanner.dueRemovals(imported, installed: [after.libraryID]), [])
  }

  func testDeletedFileKeepsItsWallpaperWithoutMirrorDeletions() {
    let rain = item("rain.mp4")
    let snow = item("snow.mp4")
    let record = LinkedFolderRecord(entries: [entry(rain), entry(snow)])

    let result = plan(record, scan([snow]), mirror: false, installed: [rain.libraryID, snow.libraryID])
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.record.entries.first { $0.path == "rain.mp4" }?.state, .missing)

    let laterOn = plan(result.record, scan([snow]), mirror: true, installed: [rain.libraryID, snow.libraryID])
    XCTAssertEqual(laterOn.removals, [], "turning Mirror deletions on does not remove what was already kept")
  }

  func testDeletedFileLeavesTheLibraryWithMirrorDeletions() {
    let items = (1...5).map { item("clip\($0).mp4") }
    let record = LinkedFolderRecord(entries: items.map { entry($0) })
    let installed = Set(items.map(\.libraryID))

    let result = plan(record, scan(Array(items.dropFirst())), mirror: true, installed: installed)
    XCTAssertEqual(result.removals, [items[0].libraryID])
    XCTAssertEqual(result.held, [])
    XCTAssertEqual(result.record.entries.first { $0.path == items[0].path }?.state, .leaving)

    var removed = result.record
    LinkedFolderPlanner.recordRemoved([items[0].libraryID], in: &removed)
    XCTAssertFalse(removed.entries.contains { $0.path == items[0].path })
  }

  func testOnlyWallpapersTheLinkImportedAreRemovedOrReplaced() {
    let mine = item("mine.mp4")
    let theirs = item("theirs.mp4")
    let record = LinkedFolderRecord(entries: [entry(mine), entry(theirs, owned: false)])
    let installed: Set = [mine.libraryID, theirs.libraryID]

    let removal = plan(record, scan([mine]), mirror: true, installed: installed)
    XCTAssertEqual(removal.removals, [])

    let changed = item("theirs.mp4", size: 999, modified: 9)
    var current = plan(record, scan([mine, changed]), mirror: true, installed: installed)
    current = plan(current.record, scan([mine, changed]), mirror: true, installed: installed)
    XCTAssertEqual(current.imports, [], "an item this link did not import is never copied over")
  }

  func testNewFileNamedLikeAnInstalledWallpaperIsLeftAlone() {
    let handImported = item("rain.mp4")
    let result = plan(LinkedFolderRecord(), scan([handImported]), mirror: true, installed: [handImported.libraryID])
    XCTAssertEqual(result.imports, [])
    XCTAssertEqual(result.record.entries.map(\.owned), [false])

    let gone = plan(result.record, scan([]), mirror: true, installed: [handImported.libraryID])
    XCTAssertEqual(gone.removals, [])
    XCTAssertEqual(gone.held, [])
  }

  func testUnavailableFolderChangesNothing() {
    let items = (1...3).map { item("clip\($0).mp4") }
    let record = LinkedFolderRecord(entries: items.map { entry($0) }, pendingRemovals: ["local-old.mp4"])
    let result = plan(record, .unavailable, mirror: true, installed: Set(items.map(\.libraryID) + ["local-old.mp4"]))
    XCTAssertTrue(result.isUnavailable)
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.imports, [])
    XCTAssertEqual(result.record, record)
  }

  func testEvictedICloudFileIsStillInTheFolder() {
    let rain = item("rain.mp4")
    let record = LinkedFolderRecord(entries: [entry(rain)])
    let result = plan(record, scan([], alsoPresent: ["rain.mp4"]), mirror: true, installed: [rain.libraryID])
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.record.entries, record.entries)
  }

  func testMassRemovalIsHeldUntilConfirmed() {
    let items = (1...30).map { item(String(format: "clip%02d.mp4", $0)) }
    let record = LinkedFolderRecord(entries: items.map { entry($0) })
    let installed = Set(items.map(\.libraryID))

    let held = plan(record, scan(Array(items.prefix(9))), mirror: true, installed: installed)
    XCTAssertEqual(held.removals, [])
    XCTAssertEqual(held.held.count, 21)
    XCTAssertEqual(held.record.entries.count, 30, "held items stay recorded until the user decides")
    XCTAssertEqual(held.record.entries.filter { $0.state == .leaving }, [])

    var confirmed = held.record
    LinkedFolderPlanner.confirmHeld(held.held, in: &confirmed)
    let next = plan(confirmed, scan(Array(items.prefix(9))), mirror: true, installed: installed)
    XCTAssertEqual(Set(next.removals), Set(held.held))
    XCTAssertEqual(next.held, [])
  }

  func testRemovingMoreThanAQuarterIsHeldButASingleFileIsNot() {
    XCTAssertTrue(LinkedFolderPlanner.isMassRemoval(2, of: 4))
    XCTAssertTrue(LinkedFolderPlanner.isMassRemoval(21, of: 1000))
    XCTAssertFalse(LinkedFolderPlanner.isMassRemoval(1, of: 1))
    XCTAssertFalse(LinkedFolderPlanner.isMassRemoval(2, of: 8))
    XCTAssertFalse(LinkedFolderPlanner.isMassRemoval(20, of: 100))
  }

  func testKeptHeldItemsAreNotAskedAboutAgain() {
    let items = (1...4).map { item("clip\($0).mp4") }
    let installed = Set(items.map(\.libraryID))
    let held = plan(LinkedFolderRecord(entries: items.map { entry($0) }), scan([items[0]]), mirror: true, installed: installed)
    XCTAssertEqual(held.held.count, 3)

    var kept = held.record
    LinkedFolderPlanner.keepHeld(held.held, in: &kept)
    let next = plan(kept, scan([items[0]]), mirror: true, installed: installed)
    XCTAssertEqual(next.held, [])
    XCTAssertEqual(next.removals, [])
    XCTAssertEqual(next.record.entries.filter { $0.state == .missing }.count, 3)
  }

  func testFileBackBeforeItsRemovalKeepsItsWallpaper() {
    let rain = item("rain.mp4")
    let record = LinkedFolderRecord(pendingRemovals: [rain.libraryID])
    let result = plan(record, scan([rain]), mirror: true, installed: [rain.libraryID])
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.record.entries.map(\.owned), [true])
  }

  func testFailedImportIsNotRetriedUntilTheFileChanges() {
    let broken = item("broken.mp4")
    var record = LinkedFolderRecord()
    LinkedFolderPlanner.recordImport(broken, importedID: nil, mirrorsDeletions: false, installedBefore: [], in: &record)

    let same = plan(record, scan([broken]))
    XCTAssertEqual(same.imports, [])
    XCTAssertFalse(same.needsRecheck)

    let fixed = item("broken.mp4", size: 200, modified: 2)
    let changed = plan(same.record, scan([fixed]))
    XCTAssertTrue(changed.needsRecheck)
    XCTAssertEqual(plan(changed.record, scan([fixed])).imports, [fixed])
  }

  func testOutcomeReadsTheImportReport() {
    let rain = item("rain.mp4")
    let project = LinkedFolderScan.Item(
      path: "Ocean", libraryID: "Ocean", stamp: .init(size: 1, modified: 1), fileID: nil)
    var report = WallpaperImportService.Report()
    report.importedIDs = ["123456"]
    report.recognizedWorkshopIDs = ["Ocean": "123456"]
    report.skipped = ["rain.mp4"]
    XCTAssertEqual(LinkedFolderPlanner.outcome(of: project, in: report), .imported("123456"))
    XCTAssertEqual(LinkedFolderPlanner.outcome(of: rain, in: report), .imported(rain.libraryID))

    let failed = item("bad.mp4")
    report.failures = ["bad.mp4: unreadable"]
    XCTAssertEqual(LinkedFolderPlanner.outcome(of: failed, in: report), .failed)

    var cancelled = WallpaperImportService.Report()
    cancelled.cancelled = true
    XCTAssertEqual(LinkedFolderPlanner.outcome(of: rain, in: cancelled), .notReached)
  }

  // Review of #276: what must never be removed or replaced.

  func testImportThatLandedOnAnInstalledWallpaperIsNotTheLinks() {
    // The import filed a project under its manifest's Workshop id, already installed.
    let copy = LinkedFolderScan.Item(path: "My Copy", libraryID: "My Copy", stamp: .init(size: 1, modified: 1), fileID: nil)
    var record = LinkedFolderRecord()
    LinkedFolderPlanner.recordImport(copy, importedID: "123456", mirrorsDeletions: true, installedBefore: ["123456"], in: &record)
    XCTAssertEqual(record.entries.map(\.owned), [false])

    let gone = plan(record, scan([]), mirror: true, installed: ["123456"])
    XCTAssertEqual(gone.removals, [])
    XCTAssertEqual(gone.held, [])
  }

  func testNameDifferingOnlyInCaseFromAnInstalledWallpaperIsLeftAlone() {
    let rain = item("rain.mp4")
    let result = plan(LinkedFolderRecord(), scan([rain]), mirror: true, installed: ["local-Rain.mp4"])
    XCTAssertEqual(result.imports, [])
    XCTAssertFalse(result.needsRecheck)
    XCTAssertEqual(result.record.entries.map(\.owned), [false])
  }

  func testRenamedAndChangedOntoAnotherWallpapersIDIsNotImported() {
    let before = item("rain.mp4", fileID: 42)
    let after = item("storm.mp4", size: 300, modified: 5, fileID: 42)
    let installed: Set = [before.libraryID, after.libraryID]
    var current = plan(LinkedFolderRecord(entries: [entry(before)]), scan([after]), mirror: true, installed: installed)
    current = plan(current.record, scan([after]), mirror: true, installed: installed)
    XCTAssertEqual(current.imports, [])
    XCTAssertEqual(current.removals, [])
  }

  func testUnreadableProjectIsNotTakenForDeleted() {
    let project = LinkedFolderScan.Item(path: "Ocean", libraryID: "Ocean", stamp: .init(size: 1, modified: 1), fileID: nil)
    let others = (1...4).map { item("clip\($0).mp4") }
    let record = LinkedFolderRecord(entries: ([project] + others).map { entry($0) })
    let installed = Set(([project] + others).map(\.libraryID))

    let result = plan(record, scan(others, alsoPresent: ["Ocean"]), mirror: true, installed: installed)
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.record.entries.first { $0.path == "Ocean" }?.state, .present)
  }

  func testFileBackChangedBeforeItsRemovalIsImportedInstead() {
    let rain = item("rain.mp4")
    var leaving = entry(rain)
    leaving.state = .leaving
    let changed = item("rain.mp4", size: 500, modified: 7)

    let first = plan(LinkedFolderRecord(entries: [leaving]), scan([changed]), mirror: true, installed: [rain.libraryID])
    XCTAssertEqual(first.removals, [])
    XCTAssertEqual(first.record.entries.map(\.state), [.present])
    XCTAssertEqual(plan(first.record, scan([changed]), mirror: true, installed: [rain.libraryID]).imports, [changed])
  }

  func testRenamedFileBackBeforeItsRemovalKeepsItsWallpaper() {
    // rain.mp4 was renamed storm.mp4 (keeping local-rain.mp4), then left, then came back.
    let storm = item("storm.mp4", fileID: 42)
    var leaving = LinkedFolderRecord.Entry(path: "storm.mp4", libraryID: "local-rain.mp4", stamp: storm.stamp, fileID: 42, owned: true)
    leaving.state = .leaving
    let result = plan(LinkedFolderRecord(entries: [leaving]), scan([storm]), mirror: true, installed: ["local-rain.mp4"])
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.record.entries.map(\.libraryID), ["local-rain.mp4"])
  }

  func testTurningMirrorDeletionsOffCallsOffDueRemovals() {
    let rain = item("rain.mp4")
    var leaving = entry(rain)
    leaving.state = .leaving
    var record = LinkedFolderRecord(entries: [leaving], pendingRemovals: ["local-old.mp4"])
    LinkedFolderPlanner.stopMirroring(&record)
    XCTAssertEqual(LinkedFolderPlanner.dueRemovals(record, installed: [rain.libraryID, "local-old.mp4"]), [])
    XCTAssertEqual(record.entries.map(\.state), [.missing])
  }

  func testRemovalsQueuedWhileNoPanelWasOpenCountTowardTheGuard() {
    let items = (1...30).map { item(String(format: "clip%02d.mp4", $0)) }
    let gone = Set(items.prefix(21).map(\.path))
    let record = LinkedFolderRecord(entries: items.map {
      var queued = entry($0)
      if gone.contains($0.path) { queued.state = .leaving }  // each decided alone, one look at a time
      return queued
    })
    let result = plan(record, scan(Array(items.dropFirst(21))), mirror: true, installed: Set(items.map(\.libraryID)))
    XCTAssertEqual(result.removals, [])
    XCTAssertEqual(result.held.count, 21)
  }
}
