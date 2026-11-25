import SwiftUI
import XCTest
@testable import WallpaperMachine

/// The update window's notes translation and empty notes state: it opens on the language it is
/// given, the switch above the notes changes only what this window shows, and when no release
/// notes are available the switch and scrolling box give way to a centered placeholder.
@MainActor
final class UpdateWindowTests: XCTestCase {
    func testSwitchAboveTheNotesChangesTheTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "update-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = PanelUpdateClient()
        client.release = GitHubRelease(
            version: SemanticVersion("1.1.0")!,
            htmlURL: URL(string: "https://github.com/o/r/releases/tag/v1.1.0")!, prerelease: false,
            assets: PanelUpdateClient.release(version: "1.1.0").assets,
            changelog: """
                ## [1.1.0](https://github.com/o/r/compare/v1.0.0...v1.1.0) (2026-11-09)
                ### English
                #### Improvements
                - Faster startup
                ### 简体中文
                #### 改进
                - 启动更快
                ### 한국어
                #### 개선 사항
                - 더 빠른 시작
                """)
        let store = AppUpdateStore(
            currentVersion: "1.0.0", client: client, installer: PanelUpdateInstaller(),
            workspace: AppUpdateWorkspace(
                archiveURL: { _, _ in root.appendingPathComponent("update.dmg") },
                reveal: { _ in }, open: { _ in }),
            defaults: try TemporaryDefaults.make(for: self).defaults)
        _ = await store.checkForUpdates()
        XCTAssertFalse(store.notesReleases.isEmpty)

        let notesLanguage = UpdateNotesLanguage(.korean)
        let hosting = NSHostingController(
            rootView: UpdateWindowView(
                store: store, actions: .init(skip: {}, later: {}, install: {}, setMode: { _ in }),
                notesLanguage: notesLanguage))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: UpdateWindow.defaultContentSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer {
            window.contentViewController = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        let control = try XCTUnwrap(Self.segmentedControl(in: hosting.view))
        XCTAssertNotNil(Self.scrollView(in: hosting.view))
        XCTAssertEqual(control.segmentCount, AppReleaseHistory.Language.allCases.count)
        XCTAssertEqual(control.selectedSegment, AppReleaseHistory.Language.korean.rawValue)
        for language in [AppReleaseHistory.Language.chinese, .english] {
            control.selectedSegment = language.rawValue
            control.sendAction(control.action, to: control.target)
            XCTAssertEqual(notesLanguage.selection, language)
        }
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "the title bar holds only the window buttons")
    }

    func testEmptyReleaseNotesHidesTheLanguageSwitchAndShowsThePlaceholder() async throws {
        let store = AppUpdateStore(
            currentVersion: "1.0.0", client: DisabledAppUpdateClient(),
            defaults: try TemporaryDefaults.make(for: self).defaults)
        XCTAssertTrue(store.notesReleases.isEmpty)
        let notesLanguage = UpdateNotesLanguage(.english)
        let hosting = NSHostingController(
            rootView: UpdateWindowView(
                store: store, actions: .init(skip: {}, later: {}, install: {}, setMode: { _ in }),
                notesLanguage: notesLanguage))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: UpdateWindow.defaultContentSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer {
            window.contentViewController = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(Self.segmentedControl(in: hosting.view), "no language switch without release notes")
        XCTAssertNil(Self.scrollView(in: hosting.view), "no empty scrolling notes box without release notes")
        XCTAssertTrue(
            Self.containsIdentifier("update-notes-empty", in: hosting.view),
            "centered empty release notes placeholder is shown")
    }

    private static func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for child in view.subviews {
            if let found = segmentedControl(in: child) { return found }
        }
        return nil
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    private static func containsIdentifier(_ target: String, in element: Any?, depth: Int = 0) -> Bool {
        guard depth < 40, let object = element as? NSObject else { return false }
        if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           let identifier = object.value(forKey: "accessibilityIdentifier") as? String,
           identifier == target
        {
            return true
        }
        if object.responds(to: NSSelectorFromString("accessibilityChildren")),
           let children = object.value(forKey: "accessibilityChildren") as? [Any]
        {
            for child in children where containsIdentifier(target, in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }
}
