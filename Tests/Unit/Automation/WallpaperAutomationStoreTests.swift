import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperAutomationStoreTests: XCTestCase {
    func testPreSpacePreferencesDecodeAndSpaceChoicesRoundTrip() throws {
        let old = Data(#"{"mode":"appearance","rules":[],"revision":2,"light":{"kind":"wallpaper","id":"a"}}"#.utf8)
        var value = try JSONDecoder().decode(DisplayWallpaperAutomation.self, from: old)
        XCTAssertTrue(value.spaces.isEmpty)
        value.mode = .spaces; value.spaces["desktop-uuid"] = .init(kind: .wallpaper, id: "ocean")
        XCTAssertEqual(try JSONDecoder().decode(DisplayWallpaperAutomation.self, from: JSONEncoder().encode(value)), value)
    }
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testRulesLocationAndHandledStatePersistAndUnchangedEditsKeepTheRevision() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        let rule = WallpaperAutomationRule(weekdays: [2, 6], event: .sunset, offset: 30,
            target: .init(kind: .wallpaper, id: "sunset"))
        try store.update("screen") { $0.mode = .schedule }
        try store.saveRule(rule, on: "screen")
        let revision = store.configuration(for: "screen").revision
        try store.saveRule(rule, on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").revision, revision)
        try store.setLocation(.init(latitude: -33.87, longitude: 151.21))
        store.markHandled("event", on: "screen")
        let loaded = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(loaded.configuration(for: "screen"), store.configuration(for: "screen"))
        XCTAssertEqual(loaded.location, store.location)
        XCTAssertEqual(loaded.handled["screen"], "event")
        loaded.retry("screen")
        XCTAssertNil(WallpaperAutomationStore(defaults: defaults).handled["screen"])
    }

    func testInvalidUpdatesAreAtomicAndCorruptStoredRulesAreReported() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        try store.update("screen") { $0.mode = .appearance; $0.light = .init(kind: .wallpaper, id: "a") }
        let before = defaults.data(forKey: WallpaperAutomationStore.configurationsKey)
        XCTAssertThrowsError(try store.update("screen") { $0.dark = .init(kind: .wallpaper, id: "") })
        XCTAssertEqual(defaults.data(forKey: WallpaperAutomationStore.configurationsKey), before)
        XCTAssertThrowsError(try store.setLocation(.init(latitude: .nan, longitude: 0)))
        defaults.set(Data("not JSON".utf8), forKey: WallpaperAutomationStore.configurationsKey)
        let corrupt = WallpaperAutomationStore(defaults: defaults)
        XCTAssertNotNil(corrupt.loadError)
        XCTAssertTrue(corrupt.configurations.isEmpty)
    }

    /// A newer build saved a mode this one does not know on one display. The other display's
    /// rules still load, and editing them leaves the unreadable display's record as it was saved.
    func testOneUnreadableDisplayKeepsItsRecordWhileAnotherIsEdited() throws {
        let readable = #"{"mode":"appearance","rules":[],"revision":3,"light":{"kind":"wallpaper","id":"a"}}"#
        let future = #"{"mode":"someFutureMode","rules":[],"revision":7,"extra":{"kept":true}}"#
        defaults.set(Data(#"{"left":\#(readable),"right":\#(future)}"#.utf8),
                     forKey: WallpaperAutomationStore.configurationsKey)

        let store = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(store.configuration(for: "left").light, .init(kind: .wallpaper, id: "a"))
        XCTAssertNil(store.configurations["right"])
        XCTAssertNotNil(store.loadError)

        try store.update("left") { $0.dark = .init(kind: .wallpaper, id: "b") }

        let saved = try XCTUnwrap(defaults.data(forKey: WallpaperAutomationStore.configurationsKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: [String: Any]])
        XCTAssertEqual(object["right"]?["mode"] as? String, "someFutureMode")
        XCTAssertEqual(object["right"]?["revision"] as? Int, 7)
        XCTAssertEqual((object["right"]?["extra"] as? [String: Bool])?["kept"], true)
        XCTAssertEqual((object["left"]?["dark"] as? [String: String])?["id"], "b")
        XCTAssertNotNil(store.loadError, "the warning stands while a display's rules are set aside")

        // Giving that display rules of its own replaces what could not be read, and clears the warning.
        try store.update("right") { $0.mode = .schedule }
        let replaced = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(replaced.configuration(for: "right").mode, .schedule)
        XCTAssertEqual(replaced.configuration(for: "left").dark, .init(kind: .wallpaper, id: "b"))
        XCTAssertNil(store.loadError)
        XCTAssertNil(replaced.loadError)
    }

    func testAnUnreadableFocusRecordSurvivesAnotherDisplaysFocus() throws {
        let playlist = String(decoding: try JSONEncoder().encode(DisplayPlaylist()), as: UTF8.self)
        defaults.set(Data(#"{"right":{"key":42,"before":{"playlist":\#(playlist)}}}"#.utf8),
                     forKey: WallpaperAutomationStore.focusRestoreKey)
        let store = WallpaperAutomationStore(defaults: defaults)
        XCTAssertNil(store.focusRestore["right"])

        let record = FocusWallpaperRestore(
            key: "focus", before: .init(playlist: .init(), wallpaperID: "a"), expectedPlaylist: .init())
        try store.rememberFocus(record, on: "left")
        try store.forgetFocus(on: "left")

        let saved = try XCTUnwrap(defaults.data(forKey: WallpaperAutomationStore.focusRestoreKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: [String: Any]])
        XCTAssertEqual(object["right"]?["key"] as? Int, 42)
        XCTAssertNil(object["left"])
    }

    func testImportedConfigurationBoundsAndDeletedWallpaperPruning() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        try store.update("screen") {
            $0.mode = .schedule
            $0.rules = [.init(target: .init(kind: .wallpaper, id: "a")), .init(target: .init(kind: .playlist, id: "p"))]
            $0.light = .init(kind: .wallpaper, id: "a")
        }
        try store.forgetWallpapers(["a"])
        XCTAssertNil(store.configuration(for: "screen").light)
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.target.id), ["p"])
        let tooMany = Dictionary(uniqueKeysWithValues: (0..<65).map { (String($0), DisplayWallpaperAutomation()) })
        let data = try JSONEncoder().encode(tooMany)
        XCTAssertThrowsError(try WallpaperAutomationStore.validateConfigurations(data))
        defaults.set(data, forKey: WallpaperAutomationStore.configurationsKey)
        XCTAssertTrue(WallpaperAutomationStore(defaults: defaults).configurations.isEmpty)
    }

    func testALocationSavedBeforeTheSourceExistedReadsAsCoordinates() throws {
        let legacy = WallpaperSolarLocation(latitude: 30.0827, longitude: 103.874)
        defaults.set(try JSONEncoder().encode(legacy), forKey: WallpaperAutomationStore.locationKey)
        let store = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(store.solar.source, .coordinates)
        XCTAssertEqual(store.solar.location, legacy)
        XCTAssertEqual(store.solar.fixedSunriseMinute, 7 * 60)
        XCTAssertEqual(store.solar.fixedSunsetMinute, 18 * 60)
        XCTAssertNil(store.loadError)
    }

    func testFixedTimesSurviveAReloadWithoutACoordinate() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        try store.setSolar(.init(
            source: .fixed, location: nil,
            fixedSunriseMinute: 6 * 60 + 15, fixedSunsetMinute: 19 * 60 + 45))
        let loaded = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(loaded.solar.source, .fixed)
        XCTAssertEqual(loaded.solar.fixedSunriseMinute, 6 * 60 + 15)
        XCTAssertEqual(loaded.solar.fixedSunsetMinute, 19 * 60 + 45)
        XCTAssertNil(loaded.location)
        XCTAssertNil(loaded.loadError)
    }

    func testAutomaticSourceKeepsTheLocationItTracks() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        let location = WallpaperSolarLocation(latitude: 30.0827, longitude: 103.874)
        try store.setSolar(.init(source: .automatic, location: location))
        let loaded = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(loaded.solar.source, .automatic)
        XCTAssertEqual(loaded.solar.location, location)
        XCTAssertNil(loaded.loadError)
    }

    func testAFixedTimeOutsideTheDayIsRefused() {
        let store = WallpaperAutomationStore(defaults: defaults)
        XCTAssertThrowsError(try store.setSolar(.init(
            source: .fixed, location: nil,
            fixedSunriseMinute: 24 * 60, fixedSunsetMinute: 18 * 60)))
    }

    func testLegacyRuleWithoutIsEnabledDecodesAsEnabledAndDisabledRuleRoundTrips() throws {
        let legacyJSON = Data(#"""
            {
              "screen": {
                "mode": "schedule",
                "rules": [
                  {
                    "id": "r1",
                    "weekdays": [2, 3, 4, 5, 6],
                    "event": "time",
                    "minute": 480,
                    "offset": 0,
                    "target": { "kind": "wallpaper", "id": "work" }
                  }
                ],
                "revision": 1
              }
            }
            """#.utf8)
        XCTAssertNoThrow(try WallpaperAutomationStore.validateConfigurations(legacyJSON))
        let decoded = try JSONDecoder().decode([String: DisplayWallpaperAutomation].self, from: legacyJSON)
        let legacyRule = try XCTUnwrap(decoded["screen"]?.rules.first)
        XCTAssertTrue(legacyRule.isEnabled, "rules saved before isEnabled existed decode as enabled")

        let disabled = WallpaperAutomationRule(
            id: "r2", weekdays: [1, 7], event: .sunset, offset: -15,
            target: .init(kind: .wallpaper, id: "night"), isEnabled: false)
        let roundTripped = try JSONDecoder().decode(
            WallpaperAutomationRule.self, from: JSONEncoder().encode(disabled))
        XCTAssertEqual(roundTripped, disabled)
        XCTAssertFalse(roundTripped.isEnabled)
    }

    func testRulesCanBeDisabledEnabledAndReorderedWithExpectedOrderValidation() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        let r1 = WallpaperAutomationRule(id: "r1", minute: 480, target: .init(kind: .wallpaper, id: "a"))
        let r2 = WallpaperAutomationRule(id: "r2", minute: 480, target: .init(kind: .wallpaper, id: "b"))
        let r3 = WallpaperAutomationRule(id: "r3", minute: 600, target: .init(kind: .wallpaper, id: "c"))
        try store.update("screen") {
            $0.mode = .schedule
            $0.rules = [r1, r2, r3]
        }

        try store.setRuleEnabled("r2", isEnabled: false, on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.isEnabled), [true, false, true])
        XCTAssertFalse(WallpaperAutomationStore(defaults: defaults).configuration(for: "screen").rules[1].isEnabled)
        try store.setRuleEnabled("r2", isEnabled: true, on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.isEnabled), [true, true, true])
        XCTAssertThrowsError(try store.setRuleEnabled("missing", isEnabled: false, on: "screen"))

        let revisionBeforeBoundary = store.configuration(for: "screen").revision
        try store.moveRule("r1", by: -1, on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.id), ["r1", "r2", "r3"])
        XCTAssertEqual(store.configuration(for: "screen").revision, revisionBeforeBoundary, "boundary move is a no-op")
        try store.moveRule("r1", by: 1, on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.id), ["r2", "r1", "r3"])
        XCTAssertThrowsError(try store.moveRule("r1", by: 2, on: "screen"))
        XCTAssertThrowsError(try store.moveRule("missing", by: 1, on: "screen"))

        try store.reorderRules(["r3", "r2", "r1"], expected: ["r2", "r1", "r3"], on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.id), ["r3", "r2", "r1"])
        XCTAssertEqual(
            WallpaperAutomationStore(defaults: defaults).configuration(for: "screen").rules.map(\.id),
            ["r3", "r2", "r1"])
        XCTAssertThrowsError(try store.reorderRules(["r1", "r2", "r3"], expected: ["r2", "r1", "r3"], on: "screen"))
        XCTAssertThrowsError(try store.reorderRules(["r3", "r2"], on: "screen"))
        XCTAssertThrowsError(try store.reorderRules(["r3", "r2", "unknown"], on: "screen"))
    }
}
