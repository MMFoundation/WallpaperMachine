import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperDisplayLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let assignments = [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "a")]
    override func setUpWithError() throws { try super.setUpWithError(); defaults = try TemporaryDefaults.make(for: self).defaults }

    func testSaveRenameAndDeletePersist() throws {
        let store = WallpaperDisplayLayoutStore(defaults: defaults)
        let value = try store.save(name: "  Work  ", assignments: assignments)
        XCTAssertEqual(value.name, "Work")
        try store.rename(value.id, name: "Evening")
        let loaded = WallpaperDisplayLayoutStore(defaults: defaults)
        XCTAssertEqual(try loaded.layout(value.id).assignments, assignments)
        XCTAssertEqual(try loaded.layout(value.id).name, "Evening")
        try loaded.delete(value.id)
        XCTAssertTrue(WallpaperDisplayLayoutStore(defaults: defaults).layouts.isEmpty)
    }

    func testInvalidAndDuplicateAssignmentsNeverReplaceSavedLayouts() throws {
        let store = WallpaperDisplayLayoutStore(defaults: defaults)
        _ = try store.save(name: "Work", assignments: assignments)
        let before = defaults.data(forKey: WallpaperDisplayLayoutStore.storageKey)
        XCTAssertThrowsError(try store.save(name: "", assignments: assignments))
        XCTAssertThrowsError(try store.save(name: "Empty", assignments: []))
        XCTAssertThrowsError(try store.save(name: "Duplicate", assignments: assignments + assignments))
        XCTAssertEqual(defaults.data(forKey: WallpaperDisplayLayoutStore.storageKey), before)
    }

    func testBoundsCorruptionAndRemovedContentRemainVisible() throws {
        let values = (0..<65).map { _ in WallpaperDisplayLayout(name: "Layout", assignments: assignments) }
        let data = try JSONEncoder().encode(values)
        XCTAssertThrowsError(try WallpaperDisplayLayoutStore.decode(data))
        defaults.set(data, forKey: WallpaperDisplayLayoutStore.storageKey)
        let invalid = WallpaperDisplayLayoutStore(defaults: defaults)
        XCTAssertTrue(invalid.layouts.isEmpty)
        XCTAssertNotNil(invalid.loadError)
        let missing = WallpaperDisplayAssignment(displayID: "unplugged", displayTitle: "Dock", wallpaperID: "removed")
        _ = try invalid.save(name: "Reconnect later", assignments: [missing])
        XCTAssertEqual(WallpaperDisplayLayoutStore(defaults: defaults).layouts.first?.assignments, [missing])
    }

    func testLegacyJSONWithoutAutoApplyDecodesAsFalse() throws {
        let legacyJSON = Data("""
            [{"id":"legacy-1","name":"Desk","assignments":[{"displayID":"primary","displayTitle":"Main","wallpaperID":"a"}]}]
            """.utf8)
        let decoded = try WallpaperDisplayLayoutStore.decode(legacyJSON)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "legacy-1")
        XCTAssertFalse(decoded[0].autoApplyOnConnect)
    }

    func testNormalizedTopologyAndSingleAutoApplyEnforcement() throws {
        let store = WallpaperDisplayLayoutStore(defaults: defaults)
        let deskA = [
            WallpaperDisplayAssignment(displayID: "secondary", displayTitle: "Side", wallpaperID: "b"),
            WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "a"),
        ]
        let deskB = [
            WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "c"),
            WallpaperDisplayAssignment(displayID: "secondary", displayTitle: "Side", wallpaperID: "d"),
        ]
        let mobile = [
            WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "e"),
        ]

        let first = try store.save(name: "Desk A", assignments: deskA)
        let second = try store.save(name: "Desk B", assignments: deskB)
        let laptop = try store.save(name: "Laptop", assignments: mobile, autoApplyOnConnect: true)

        XCTAssertEqual(first.normalizedDisplayTopology(), ["primary", "secondary"])
        XCTAssertEqual(second.normalizedDisplayTopology(), ["primary", "secondary"])
        XCTAssertEqual(WallpaperDisplayLayout.normalizedDisplayTopology(for: [" secondary ", "primary", "primary", ""]),
                       ["primary", "secondary"])
        XCTAssertTrue(laptop.autoApplyOnConnect)

        try store.setAutoApplyOnConnect(true, for: first.id)
        XCTAssertTrue(try store.layout(first.id).autoApplyOnConnect)
        XCTAssertFalse(try store.layout(second.id).autoApplyOnConnect)
        XCTAssertTrue(try store.layout(laptop.id).autoApplyOnConnect, "a different topology stays enabled")
        XCTAssertEqual(store.autoApplyLayout(for: ["secondary", "primary"])?.id, first.id)
        XCTAssertEqual(store.autoApplyLayout(for: ["primary"])?.id, laptop.id)

        // Enabling on Desk B clears Desk A because they share the same normalized topology.
        try store.setAutoApplyOnConnect(true, for: second.id)
        XCTAssertFalse(try store.layout(first.id).autoApplyOnConnect)
        XCTAssertTrue(try store.layout(second.id).autoApplyOnConnect)
        XCTAssertTrue(try store.layout(laptop.id).autoApplyOnConnect)

        let reloaded = WallpaperDisplayLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.autoApplyLayout(for: ["primary", "secondary"])?.id, second.id)
        XCTAssertEqual(reloaded.autoApplyLayout(for: ["primary"])?.id, laptop.id)

        try reloaded.setAutoApplyOnConnect(false, for: second.id)
        XCTAssertNil(reloaded.autoApplyLayout(for: ["primary", "secondary"]))
    }

    func testDecodeDeduplicatesAutoApplyOnConnectPerNormalizedTopology() throws {
        let sameA = WallpaperDisplayLayout(
            id: "layout-a", name: "Desk A",
            assignments: [
                WallpaperDisplayAssignment(displayID: "secondary", displayTitle: "Side", wallpaperID: "b"),
                WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "a"),
            ],
            autoApplyOnConnect: true)
        let sameB = WallpaperDisplayLayout(
            id: "layout-b", name: "Desk B",
            assignments: [
                WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "c"),
                WallpaperDisplayAssignment(displayID: "secondary", displayTitle: "Side", wallpaperID: "d"),
            ],
            autoApplyOnConnect: true)
        let single = WallpaperDisplayLayout(
            id: "layout-c", name: "Mobile",
            assignments: [
                WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "e"),
            ],
            autoApplyOnConnect: true)

        let raw = try JSONEncoder().encode([sameA, sameB, single])
        let decoded = try WallpaperDisplayLayoutStore.decode(raw)
        XCTAssertEqual(decoded.map(\.autoApplyOnConnect), [true, false, true],
                       "only the first layout per normalized topology stays auto-apply")
    }
}
