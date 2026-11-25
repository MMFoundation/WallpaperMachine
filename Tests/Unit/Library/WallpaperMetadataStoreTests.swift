import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperMetadataStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testRatingClampsIntoOneThroughFiveAndClearsWithNil() {
        let store = WallpaperMetadataStore(defaults: defaults)
        store.setRating(0, for: "w1")
        XCTAssertEqual(store.metadata(for: "w1").rating, 1)
        store.setRating(9, for: "w1")
        XCTAssertEqual(store.metadata(for: "w1").rating, 5)
        store.setRating(4, for: "w1")
        XCTAssertEqual(WallpaperMetadataStore(defaults: defaults).metadata(for: "w1").rating, 4)
        XCTAssertEqual(store.ratings, ["w1": 4])

        store.setRating(nil, for: "w1")
        XCTAssertNil(store.metadata(for: "w1").rating)
        XCTAssertTrue(store.entries.isEmpty, "returning every field to default prunes the entry")
        XCTAssertNil(defaults.object(forKey: WallpaperMetadataStore.storageKey),
                     "an empty store clears its defaults key")
    }

    func testCustomTagsDeduplicateCaseInsensitivelyValidateAndRemove() throws {
        let store = WallpaperMetadataStore(defaults: defaults)
        try store.addTag("  Cozy  ", to: "w1")
        try store.addTag("cozy", to: "w1")
        try store.addTag("Night", to: "w1")
        XCTAssertEqual(store.metadata(for: "w1").customTags, ["Cozy", "Night"])
        XCTAssertEqual(store.allCustomTags, ["Cozy", "Night"])

        XCTAssertThrowsError(try store.addTag("   ", to: "w1")) { error in
            XCTAssertEqual(error as? WallpaperMetadataError, .invalidTag)
        }
        XCTAssertThrowsError(try store.addTag("line1\nline2", to: "w1")) { error in
            XCTAssertEqual(error as? WallpaperMetadataError, .invalidTag)
        }
        XCTAssertThrowsError(try store.addTag(String(repeating: "a", count: 65), to: "w1")) { error in
            XCTAssertEqual(error as? WallpaperMetadataError, .invalidTag)
        }

        store.removeTag("COZY", from: "w1")
        XCTAssertEqual(store.metadata(for: "w1").customTags, ["Night"])
        store.removeTag("night", from: "w1")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testCustomTagLimitRefusesExcessTags() throws {
        let store = WallpaperMetadataStore(defaults: defaults)
        for index in 1...WallpaperMetadata.maximumTagsPerWallpaper {
            try store.addTag("tag-\(index)", to: "w1")
        }
        XCTAssertThrowsError(try store.addTag("tag-overflow", to: "w1")) { error in
            XCTAssertEqual(error as? WallpaperMetadataError, .tooManyTags)
        }
    }

    func testNotesTrimClearOnBlankAndRejectInvalidValues() throws {
        let store = WallpaperMetadataStore(defaults: defaults)
        try store.setNote("  Great for evening focus  ", for: "w1")
        XCTAssertEqual(store.metadata(for: "w1").note, "Great for evening focus")
        XCTAssertEqual(WallpaperMetadataStore(defaults: defaults).metadata(for: "w1").note, "Great for evening focus")

        XCTAssertThrowsError(try store.setNote("bad\0note", for: "w1")) { error in
            XCTAssertEqual(error as? WallpaperMetadataError, .invalidNote)
        }
        XCTAssertThrowsError(try store.setNote(String(repeating: "x", count: 281), for: "w1")) { error in
            XCTAssertEqual(error as? WallpaperMetadataError, .invalidNote)
        }

        try store.setNote("   \n  ", for: "w1")
        XCTAssertNil(store.metadata(for: "w1").note)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testExclusionAndForgetCleanUpRemovedWallpapers() throws {
        let store = WallpaperMetadataStore(defaults: defaults)
        store.setExcludedFromRotation(true, for: "w1")
        try store.addTag("Focus", to: "w2")
        XCTAssertTrue(store.isExcluded("w1"))
        XCTAssertEqual(store.excludedIDs, ["w1"])

        store.forget(["w1"])
        XCTAssertFalse(store.isExcluded("w1"))
        XCTAssertTrue(store.excludedIDs.isEmpty)
        XCTAssertEqual(WallpaperMetadataStore(defaults: defaults).metadata(for: "w2").customTags, ["Focus"])
    }

    func testPreservedJSONKeepsUnreadableFutureEntriesWhenEditingOthers() throws {
        let raw = Data(#"{"known":{"rating":5,"customTags":["Calm"]},"future":"not-an-object"}"#.utf8)
        defaults.set(raw, forKey: WallpaperMetadataStore.storageKey)

        let store = WallpaperMetadataStore(defaults: defaults)
        XCTAssertEqual(store.metadata(for: "known").rating, 5)
        XCTAssertEqual(store.metadata(for: "known").customTags, ["Calm"])
        XCTAssertNil(store.entries["future"])

        store.setExcludedFromRotation(true, for: "other")
        let savedData = try XCTUnwrap(defaults.data(forKey: WallpaperMetadataStore.storageKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        XCTAssertEqual(object["future"] as? String, "not-an-object",
                       "unreadable future entry stays intact when saving another wallpaper's metadata")
        XCTAssertNotNil(object["known"])
        XCTAssertNotNil(object["other"])
    }

    func testPartialOlderJSONDecodesWithDefaults() throws {
        let decoded = try JSONDecoder().decode(
            WallpaperMetadata.self,
            from: Data(#"{"rating":4}"#.utf8)
        )
        XCTAssertEqual(decoded.rating, 4)
        XCTAssertEqual(decoded.customTags, [])
        XCTAssertNil(decoded.note)
        XCTAssertFalse(decoded.excludedFromRotation)
    }

    func testNotificationPostsOncePerChangeAndNeverOnNoOp() {
        let store = WallpaperMetadataStore(defaults: defaults)
        let posts = MetadataPostCount()
        let token = NotificationCenter.default.addObserver(
            forName: WallpaperMetadataStore.didChangeNotification,
            object: store,
            queue: nil
        ) { _ in
            posts.value += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setRating(4, for: "w1")
        store.setRating(4, for: "w1")
        store.setExcludedFromRotation(false, for: "w1")
        XCTAssertEqual(posts.value, 1)
    }
}

private final class MetadataPostCount: @unchecked Sendable {
    var value = 0
}
