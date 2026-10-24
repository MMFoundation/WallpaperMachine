import XCTest
@testable import WallpaperMachine

/// The update window's notes translation: it opens in the app's language and the title bar's
/// switch changes only what this window shows.
@MainActor
final class UpdateWindowTests: XCTestCase {
    func testTitleBarSwitchChangesTheNotesTranslation() {
        let notesLanguage = UpdateNotesLanguage(.english)
        let accessory = UpdateLanguageAccessory(notesLanguage)
        accessory.loadViewIfNeeded()
        XCTAssertEqual(accessory.control.selectedSegment, AppReleaseHistory.Language.english.rawValue)
        XCTAssertEqual(accessory.control.segmentCount, AppReleaseHistory.Language.allCases.count)

        for language in [AppReleaseHistory.Language.korean, .chinese, .english] {
            accessory.control.selectedSegment = language.rawValue
            accessory.control.sendAction(accessory.control.action, to: accessory.control.target)
            XCTAssertEqual(notesLanguage.selection, language)
        }
    }

    func testWindowOpensOnTheTranslationItIsGiven() throws {
        let store = AppUpdateStore(
            currentVersion: "1.0.0", client: DisabledAppUpdateClient(),
            defaults: try TemporaryDefaults.make(for: self).defaults)
        let window = UpdateWindow.make(
            store: store, actions: .init(skip: {}, later: {}, install: {}), language: .korean)
        defer {
            window.contentViewController = nil
            window.close()
        }
        let accessory = try XCTUnwrap(
            window.titlebarAccessoryViewControllers.first as? UpdateLanguageAccessory)
        accessory.loadViewIfNeeded()
        XCTAssertEqual(accessory.control.selectedSegment, AppReleaseHistory.Language.korean.rawValue)
        XCTAssertEqual(accessory.layoutAttribute, .trailing)
    }
}
