import Foundation
import XCTest
@testable import WallpaperMachine

final class DockIconVisibilityTests: XCTestCase {
    func testExistingUsersKeepWindowDependentDockBehavior() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        XCTAssertFalse(DockIconVisibility.isHidden(defaults: defaults))
        XCTAssertEqual(DockIconVisibility.presence(hidesDockIcon: false, hasOpenWindow: false), .accessory)
        XCTAssertEqual(DockIconVisibility.presence(hidesDockIcon: false, hasOpenWindow: true), .regular)
    }

    func testHiddenPreferenceKeepsBothOpenAndClosedWindowsOutOfDock() {
        XCTAssertEqual(DockIconVisibility.presence(hidesDockIcon: true, hasOpenWindow: true), .accessory)
        XCTAssertEqual(DockIconVisibility.presence(hidesDockIcon: true, hasOpenWindow: false), .accessory)
    }

    func testChoiceSurvivesANewPreferencesReaderInBothDirections() throws {
        let (defaults, suite) = try TemporaryDefaults.make(for: self)
        let center = NotificationCenter()
        DockIconVisibility.setHidden(true, defaults: defaults, center: center)
        XCTAssertTrue(DockIconVisibility.isHidden(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
        DockIconVisibility.setHidden(false, defaults: defaults, center: center)
        XCTAssertFalse(DockIconVisibility.isHidden(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
    }

    func testChangingVisibilityPublishesTheSavedChoiceNotThePreviousOne() throws {
        let (defaults, suite) = try TemporaryDefaults.make(for: self)
        let center = NotificationCenter()
        let hidden = expectation(description: "the new hidden choice is readable")
        let token = center.addObserver(forName: DockIconVisibility.didChange, object: nil, queue: nil) { _ in
            XCTAssertEqual(UserDefaults(suiteName: suite)?.object(forKey: DockIconVisibility.defaultsKey) as? Bool, true)
            hidden.fulfill()
        }
        defer { center.removeObserver(token) }
        DockIconVisibility.setHidden(true, defaults: defaults, center: center)
        wait(for: [hidden], timeout: 1)
    }

    func testRepeatingTheSavedChoiceDoesNotNotifyAgain() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let center = NotificationCenter()
        DockIconVisibility.setHidden(true, defaults: defaults, center: center)
        let repeated = expectation(description: "unchanged choice must not notify")
        repeated.isInverted = true
        let token = center.addObserver(forName: DockIconVisibility.didChange, object: nil, queue: nil) { _ in
            repeated.fulfill()
        }
        defer { center.removeObserver(token) }
        DockIconVisibility.setHidden(true, defaults: defaults, center: center)
        wait(for: [repeated], timeout: 0.05)
    }

    func testTurningVisibilityBackOnPublishesFalse() throws {
        let (defaults, suite) = try TemporaryDefaults.make(for: self)
        let center = NotificationCenter()
        DockIconVisibility.setHidden(true, defaults: defaults, center: center)
        let shown = expectation(description: "the restored choice is readable")
        let token = center.addObserver(forName: DockIconVisibility.didChange, object: nil, queue: nil) { _ in
            XCTAssertEqual(UserDefaults(suiteName: suite)?.object(forKey: DockIconVisibility.defaultsKey) as? Bool, false)
            shown.fulfill()
        }
        defer { center.removeObserver(token) }
        DockIconVisibility.setHidden(false, defaults: defaults, center: center)
        wait(for: [shown], timeout: 1)
    }

    func testChangingDockVisibilityPreservesUnrelatedPreferences() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        // A neighboring persisted preference must not be reset as a side effect.
        defaults.set("kept", forKey: "unrelated.preference")
        DockIconVisibility.setHidden(true, defaults: defaults, center: NotificationCenter())
        DockIconVisibility.setHidden(false, defaults: defaults, center: NotificationCenter())
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "kept")
    }
}
