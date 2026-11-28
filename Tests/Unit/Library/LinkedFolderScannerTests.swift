import Foundation
import XCTest

@testable import WallpaperMachine

/// `LinkedFolderScanner` on a folder in the temporary directory.
final class LinkedFolderScannerTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "linked-folder-scanner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let folder {
      if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
        for name in names {
          try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
      }
      try? FileManager.default.removeItem(at: folder)
    }
  }

  private func project(_ name: String, manifest: String = "{}", files: [String: Int] = [:]) throws -> URL {
    let url = folder.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(manifest.utf8).write(to: url.appendingPathComponent("project.json"))
    for (file, size) in files { try Data(count: size).write(to: url.appendingPathComponent(file)) }
    return url
  }

  private func contents() throws -> LinkedFolderScan.Contents {
    guard case .contents(let contents) = LinkedFolderScanner.scanNow(at: folder) else {
      XCTFail("the folder could not be scanned")
      throw CocoaError(.fileReadUnknown)
    }
    return contents
  }

  func testWorkshopCopyIsFiledUnderItsManifestsID() throws {
    _ = try project("My copy", manifest: #"{"workshopid": "123456"}"#)
    XCTAssertEqual(try contents().items.map(\.libraryID), ["123456"])
  }

  func testSwappingTwoFilesNamesChangesAProjectsStamp() throws {
    let url = try project("Day", files: ["day.png": 10, "night.png": 20])
    let before = try XCTUnwrap(LinkedFolderScanner.projectStamp(url))
    let files = FileManager.default
    try files.moveItem(at: url.appendingPathComponent("day.png"), to: url.appendingPathComponent("swap"))
    try files.moveItem(at: url.appendingPathComponent("night.png"), to: url.appendingPathComponent("day.png"))
    try files.moveItem(at: url.appendingPathComponent("swap"), to: url.appendingPathComponent("night.png"))
    let after = try XCTUnwrap(LinkedFolderScanner.projectStamp(url))
    XCTAssertEqual(before.size, after.size)
    XCTAssertEqual(before.modified, after.modified)
    XCTAssertNotEqual(before, after)
  }

  func testUnreadableProjectIsStillPresent() throws {
    let url = try project("Ocean")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    let contents = try contents()
    XCTAssertEqual(contents.items, [])
    XCTAssertTrue(contents.present.contains("Ocean"))
  }

  func testEvictedNestedAssetKeepsTheCompleteInstalledProject() throws {
    let url = try project("Ocean")
    let nested = url.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let asset = nested.appendingPathComponent("ocean.png")
    try Data([1]).write(to: asset)
    let before = try contents()
    let item = try XCTUnwrap(before.items.first)
    var record = LinkedFolderRecord(entries: [.init(path: item.path, libraryID: item.libraryID, stamp: item.stamp,
                                                    fileID: item.fileID, owned: true)])
    try FileManager.default.moveItem(at: asset, to: nested.appendingPathComponent(".ocean.png.icloud"))
    for _ in 0..<2 {
      let scan = try contents()
      XCTAssertEqual(scan.items, [])
      XCTAssertTrue(scan.present.contains("Ocean"))
      let plan = LinkedFolderPlanner.plan(record: record, scan: .contents(scan), mirrorsDeletions: true, installed: ["Ocean"])
      XCTAssertEqual(plan.imports, [])
      XCTAssertEqual(plan.removals, [])
      record = plan.record
    }
    try FileManager.default.moveItem(at: nested.appendingPathComponent(".ocean.png.icloud"), to: asset)
    XCTAssertEqual(try contents().items.map(\.libraryID), ["Ocean"])
  }

  func testExternalVolumeTrashIsUnavailableEvenWhenReadable() throws {
    let trashed = folder.appendingPathComponent(".Trashes/501/Ocean")
    try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
    XCTAssertEqual(LinkedFolderScanner.scanNow(at: trashed), .unavailable)
  }
}
