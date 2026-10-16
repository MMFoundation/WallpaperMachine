import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class DockIconBackupTests: XCTestCase {
    func testStartupRestoreReadsBothChoicesAndAcceptsOlderBackupsWithoutTheKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dock-backup-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, hidden) in ([nil, true, false] as [Bool?]).enumerated() {
            let (original, originalSuite) = try TemporaryDefaults.make(for: self)
            let (restored, restoredSuite) = try TemporaryDefaults.make(for: self)
            if let hidden {
                DockIconVisibility.setHidden(hidden, defaults: original, center: NotificationCenter())
                DockIconVisibility.setHidden(!hidden, defaults: restored, center: NotificationCenter())
            }
            let source = root.appendingPathComponent("source-\(index)")
            let destination = root.appendingPathComponent("destination-\(index)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let package = root.appendingPathComponent("Dock-\(index).wmbackup")
            try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: false,
                preferences: .init(defaults: original, domainName: originalSuite))
            let service = WallpaperBackupService(supportRoot: destination)
            let preview = try service.preview(package: package,
                preferences: .init(defaults: restored, domainName: restoredSuite))
            try service.stageRestore(package: package, preview: preview, policy: .replace)
            XCTAssertEqual(DockIconVisibility.isHidden(defaults: restored), hidden.map { !$0 } ?? false)
            XCTAssertNotNil(try WallpaperBackupService.applyPendingRestore(supportRoot: destination,
                defaults: restored, domainName: restoredSuite))
            XCTAssertEqual(DockIconVisibility.isHidden(defaults: restored), hidden ?? false)
            XCTAssertEqual(DockIconVisibility.presence(hidesDockIcon: DockIconVisibility.isHidden(defaults: restored),
                hasOpenWindow: true), hidden == true ? .accessory : .regular)
        }
    }

    func testBackupIncludesTheExplicitVisibilityChoiceWithoutResettingTheIcon() throws {
        let (defaults, suite) = try TemporaryDefaults.make(for: self)
        let theme = ["mode": "system", "accent": "#80bbff", "tone": "neutral", "icon": "night"]
        defaults.set(theme, forKey: "WallpaperMachine.appTheme")
        for hidden in [true, false] {
            DockIconVisibility.setHidden(hidden, defaults: defaults, center: NotificationCenter())
            let backup = try WallpaperBackupPreferences(defaults: defaults, domainName: suite)
            let encoded = try XCTUnwrap(backup.values[DockIconVisibility.defaultsKey])
            let decoded = try WallpaperBackupPreferences.decode(encoded)
            XCTAssertEqual(decoded as? Bool, hidden)
            XCTAssertNoThrow(try WallpaperBackupPreferences.validate(decoded, forKey: DockIconVisibility.defaultsKey))
            let storedTheme = try XCTUnwrap(backup.values["WallpaperMachine.appTheme"])
            XCTAssertEqual(try WallpaperBackupPreferences.decode(storedTheme) as? [String: String], theme)
        }
    }

    func testBackupRejectsNonBooleanVisibilityValues() {
        for invalid: Any in ["true", "false", 0, 1, NSNull(), [true]] {
            XCTAssertThrowsError(try WallpaperBackupPreferences.validate(invalid, forKey: DockIconVisibility.defaultsKey))
        }
    }
}
