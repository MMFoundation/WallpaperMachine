import XCTest
@testable import WallpaperMachine

final class PlaylistPlannerTests: XCTestCase {
    /// Deterministic, so a shuffle test fails the same way every time it fails.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func playlist(_ source: PlaylistSource, list: [String] = []) -> DisplayPlaylist {
        var playlist = DisplayPlaylist()
        playlist.source = source
        playlist.wallpaperIDs = list
        return playlist
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ text: String, _ calendar: Calendar) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }

    func testCandidatesSkipWhatCannotPlay() {
        let library = ["a", "b", "c"]
        XCTAssertEqual(PlaylistPlanner.candidates(for: playlist(.all), library: library, favorites: [], collectionIDs: []), library)
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.favorites), library: library, favorites: ["c", "a", "gone"], collectionIDs: []),
            ["a", "c"], "favorites follow the library order and skip what left it")
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.list, list: ["c", "gone", "a", "c"]), library: library, favorites: [], collectionIDs: []),
            ["c", "a"], "a list keeps its own order, once each, without missing wallpapers")
    }

    func testCollectionUsesLiveMembershipWithoutFallingBackToDisplayList() {
        let configuration = playlist(.collection, list: ["a"])
        XCTAssertEqual(PlaylistPlanner.candidates(
            for: configuration, library: ["a", "b", "c"], favorites: [],
            collectionIDs: ["c", "missing", "b", "c"]), ["c", "b"])
        XCTAssertEqual(PlaylistPlanner.candidates(
            for: configuration, library: ["a", "b", "c"], favorites: [], collectionIDs: []), [])
    }

    func testOlderPlaylistDataRetainsItsSelectionsWhenNewFieldsAreMissing() throws {
        let decoded = try JSONDecoder().decode(DisplayPlaylist.self, from: Data(
            #"{"mode":"rotate","source":"list","order":"shuffle","interval":60,"wallpaperIDs":["b","a"]}"#.utf8))
        XCTAssertEqual(decoded.mode, .rotate)
        XCTAssertEqual(decoded.source, .list)
        XCTAssertEqual(decoded.order, .shuffle)
        XCTAssertEqual(decoded.interval, 60)
        XCTAssertEqual(decoded.wallpaperIDs, ["b", "a"])
        XCTAssertNil(decoded.collectionID)
        XCTAssertNil(decoded.planID)
    }

    func testInOrderWrapsAndStartsFromTheTop() {
        var random = SplitMix(state: 1)
        let candidates = ["a", "b", "c"]
        XCTAssertEqual(PlaylistPlanner.next(after: "b", in: candidates, order: .sequential, recent: [], using: &random), "c")
        XCTAssertEqual(PlaylistPlanner.next(after: "c", in: candidates, order: .sequential, recent: [], using: &random), "a")
        XCTAssertEqual(PlaylistPlanner.next(after: "x", in: candidates, order: .sequential, recent: [], using: &random), "a")
        XCTAssertEqual(PlaylistPlanner.next(after: nil, in: candidates, order: .sequential, recent: [], using: &random), "a")
        XCTAssertNil(PlaylistPlanner.next(after: "a", in: ["a"], order: .sequential, recent: [], using: &random),
                     "a display already showing the only wallpaper has nothing to change to")
        XCTAssertNil(PlaylistPlanner.next(after: nil, in: [], order: .shuffle, recent: [], using: &random))
    }

    func testShuffleShowsEveryWallpaperBeforeRepeatingOneInANewOrderEachRound() throws {
        var random = SplitMix(state: 42)
        let candidates = (1...7).map { "w\($0)" }
        var current: String?
        var recent: [String] = []
        var orders: [[String]] = []
        for round in 0..<6 {
            var order: [String] = []
            for _ in candidates {
                let next = try XCTUnwrap(PlaylistPlanner.next(
                    after: current, in: candidates, order: .shuffle, recent: recent, using: &random))
                XCTAssertNotEqual(next, current, "a change always changes something")
                XCTAssertFalse(order.contains(next), "round \(round) repeated \(next)")
                order.append(next)
                current = next
                recent = PlaylistPlanner.remember(next, in: recent, candidates: candidates)
            }
            orders.append(order)
        }
        XCTAssertGreaterThan(Set(orders).count, 1, "rounds must not settle into one fixed cycle")
    }

    func testDayRunsFromDayStartUpToNightStart() throws {
        let calendar = try calendar("Europe/Berlin")
        let noon = PlaylistPlanner.phase(at: try date("2026-06-01 12:00", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(noon.phase, .day)
        XCTAssertEqual(noon.until, try date("2026-06-01 19:00", calendar))
        let evening = PlaylistPlanner.phase(at: try date("2026-06-01 19:00", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(evening.phase, .night, "the boundary minute belongs to the half it starts")
        XCTAssertEqual(evening.until, try date("2026-06-02 07:00", calendar))
        let early = PlaylistPlanner.phase(at: try date("2026-06-02 03:00", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(early.phase, .night)
        XCTAssertEqual(early.until, try date("2026-06-02 07:00", calendar))
    }

    func testADayThatStartsAfterTheNightWrapsPastMidnight() throws {
        let calendar = try calendar("UTC")
        // Someone who lives by night: "day" from 22:00, "night" from 06:00.
        let late = PlaylistPlanner.phase(at: try date("2026-06-01 23:30", calendar), dayStart: 22 * 60, nightStart: 6 * 60, calendar: calendar)
        XCTAssertEqual(late.phase, .day)
        XCTAssertEqual(late.until, try date("2026-06-02 06:00", calendar))
        let morning = PlaylistPlanner.phase(at: try date("2026-06-02 09:00", calendar), dayStart: 22 * 60, nightStart: 6 * 60, calendar: calendar)
        XCTAssertEqual(morning.phase, .night)
        XCTAssertEqual(morning.until, try date("2026-06-02 22:00", calendar))
    }

    func testClockChangeDaysSwitchAtTheTimeOnTheClock() throws {
        let calendar = try calendar("America/New_York")
        // Clocks skip 02:00–03:00 on 8 March 2026, so 07:30 is only 6.5 hours after midnight.
        let morning = PlaylistPlanner.phase(at: try date("2026-03-08 07:30", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(morning.phase, .day)
        XCTAssertEqual(morning.until, try date("2026-03-08 19:00", calendar))
    }

    func testSavedPlaylistsDecodeWithWhatTheyLack() throws {
        let decoded = try JSONDecoder().decode(
            DisplayPlaylist.self, from: Data(#"{"mode":"rotate","interval":0,"dayStart":9999,"source":"sideways"}"#.utf8))
        XCTAssertEqual(decoded.mode, .rotate)
        XCTAssertEqual(decoded.interval, DisplayPlaylist().interval, "an interval outside the range falls back")
        XCTAssertEqual(decoded.dayStart, DisplayPlaylist().dayStart)
        XCTAssertEqual(decoded.source, .all)
    }

    func testAPlaylistSavedBeforeTheVideoOptionDoesNotWaitForVideos() throws {
        let old = try JSONDecoder().decode(DisplayPlaylist.self, from: Data(#"{"mode":"rotate","interval":60}"#.utf8))
        XCTAssertFalse(old.waitsForClipEnd)
        let unreadable = try JSONDecoder().decode(
            DisplayPlaylist.self, from: Data(#"{"mode":"rotate","waitsForClipEnd":"yes"}"#.utf8))
        XCTAssertFalse(unreadable.waitsForClipEnd)
        var playlist = DisplayPlaylist()
        playlist.mode = .rotate
        playlist.waitsForClipEnd = true
        XCTAssertEqual(try JSONDecoder().decode(DisplayPlaylist.self, from: JSONEncoder().encode(playlist)), playlist)
    }

    func testExcludeFromRotationSkipsAllFavoritesAndSmartButKeepsExplicitListsAndCollections() {
        let library = ["a", "b", "c"]
        let metadata: [String: WallpaperMetadata] = [
            "b": WallpaperMetadata(excludedFromRotation: true),
        ]
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.all), library: library, favorites: [], collectionIDs: [], metadata: metadata),
            ["a", "c"]
        )
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.favorites), library: library, favorites: ["a", "b", "c"], collectionIDs: [], metadata: metadata),
            ["a", "c"]
        )
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.smart), library: library, favorites: [], collectionIDs: [], metadata: metadata),
            ["a", "c"]
        )
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.list, list: ["b", "a"]), library: library, favorites: [], collectionIDs: [], metadata: metadata),
            ["b", "a"],
            "explicit display list still plays what the user explicitly added"
        )
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.collection), library: library, favorites: [], collectionIDs: ["b", "c"], metadata: metadata),
            ["b", "c"],
            "explicit local collection still plays its explicit members"
        )
    }

    func testSkipRecentlyUsedFiltersRecentWallpapersAndFallsBackWhenAllWereUsedRecently() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var config = playlist(.all)
        config.skipRecentDays = 7
        let lastUsed: [String: Date] = [
            "a": now.addingTimeInterval(-2 * 86_400),
            "b": now.addingTimeInterval(-10 * 86_400),
        ]
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: config, library: ["a", "b", "c"], favorites: [], collectionIDs: [], lastUsed: lastUsed, now: now),
            ["b", "c"],
            "a was used 2 days ago (< 7), b was used 10 days ago, c was never used"
        )

        let allRecent: [String: Date] = [
            "a": now.addingTimeInterval(-1 * 86_400),
            "b": now.addingTimeInterval(-2 * 86_400),
            "c": now.addingTimeInterval(-3 * 86_400),
        ]
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: config, library: ["a", "b", "c"], favorites: [], collectionIDs: [], lastUsed: allRecent, now: now),
            ["a", "b", "c"],
            "falls back to full candidate pool when every candidate was used recently"
        )

        // Only candidate outside recent window is the wallpaper currently on screen -> falls back.
        let onlyCurrentFresh: [String: Date] = [
            "b": now.addingTimeInterval(-1 * 86_400),
        ]
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: config, library: ["a", "b"], favorites: [], collectionIDs: [], lastUsed: onlyCurrentFresh, now: now, current: "a"),
            ["a", "b"],
            "falls back when every alternative to current was used recently"
        )
    }

    func testWeightedShuffleFavorsHigherRatedWallpapersDeterministically() throws {
        var random = SplitMix(state: 12345)
        let candidates = ["five", "four", "unrated", "one"]
        let ratings = ["five": 5, "four": 4, "one": 1]
        var counts: [String: Int] = [:]
        var current: String?
        for _ in 0..<2_000 {
            let pick = try XCTUnwrap(PlaylistPlanner.next(
                after: current, in: candidates, order: .shuffle, recent: [],
                preferHigherRated: true, ratings: ratings, using: &random
            ))
            XCTAssertNotEqual(pick, current, "weighted shuffle never repeats the wallpaper on screen")
            counts[pick, default: 0] += 1
            current = pick
        }
        XCTAssertGreaterThan(counts["five", default: 0], counts["four", default: 0])
        XCTAssertGreaterThan(counts["four", default: 0], counts["unrated", default: 0])
        XCTAssertGreaterThan(counts["unrated", default: 0], counts["one", default: 0])

        // Sequential order ignores preferHigherRated.
        var seqRandom = SplitMix(state: 1)
        XCTAssertEqual(
            PlaylistPlanner.next(
                after: "five", in: candidates, order: .sequential, recent: [],
                preferHigherRated: true, ratings: ratings, using: &seqRandom),
            "four"
        )
    }

    func testSmartPlaylistQueryMatchesAcrossTagsCustomTagsTypeRatingEnergyFavoritesAndMature() {
        let library = ["scene-cozy", "video-heavy", "web-mature", "pixiv-123-p0", "image-calm"]
        let favorites: Set<String> = ["scene-cozy", "pixiv-123-p0", "video-heavy"]
        let metadata: [String: WallpaperMetadata] = [
            "scene-cozy": WallpaperMetadata(customTags: ["Focus", "Lo-Fi"], rating: 5),
            "video-heavy": WallpaperMetadata(customTags: ["Focus"], rating: 4),
            "web-mature": WallpaperMetadata(customTags: ["Focus"], rating: 5),
            "pixiv-123-p0": WallpaperMetadata(customTags: ["Relax"], rating: 4),
            "image-calm": WallpaperMetadata(customTags: ["Focus"], rating: 2),
        ]
        let facts: [String: SmartWallpaperFacts] = [
            "scene-cozy": SmartWallpaperFacts(type: .scene, manifestTags: ["Anime", "Everyone"], energyLevel: .low),
            "video-heavy": SmartWallpaperFacts(type: .video, manifestTags: ["Cyberpunk", "Audio responsive"], energyLevel: .high),
            "web-mature": SmartWallpaperFacts(type: .web, manifestTags: ["Mature", "Anime"], energyLevel: .low),
            "pixiv-123-p0": SmartWallpaperFacts(type: .still, manifestTags: ["Illustration"], energyLevel: .medium),
            "image-calm": SmartWallpaperFacts(type: .still, manifestTags: ["Nature"], energyLevel: nil),
        ]

        func matching(_ query: SmartPlaylistQuery) -> [String] {
            var config = playlist(.smart)
            config.smartQuery = query
            return PlaylistPlanner.candidates(
                for: config, library: library, favorites: favorites, collectionIDs: [],
                metadata: metadata, facts: facts
            )
        }

        // Combined manifest tag + user custom tag + excludeMature + max energy + min rating + favorites
        XCTAssertEqual(
            matching(SmartPlaylistQuery(
                requiredTags: ["anime", "focus"],
                minimumRating: 4,
                maximumEnergy: .medium,
                favoritesOnly: true,
                excludeMature: true
            )),
            ["scene-cozy"]
        )

        // Excluded tag removes matching manifest or custom tags
        XCTAssertEqual(
            matching(SmartPlaylistQuery(requiredTags: ["focus"], excludedTags: ["cyberpunk", "mature"])),
            ["scene-cozy", "image-calm"]
        )

        // Type filter distinguishes still images from web pages
        XCTAssertEqual(
            matching(SmartPlaylistQuery(types: [.still])),
            ["pixiv-123-p0", "image-calm"]
        )
        XCTAssertEqual(
            matching(SmartPlaylistQuery(types: [.still], maximumEnergy: .medium)),
            ["pixiv-123-p0"],
            "unrated wallpapers do not match an explicit energy cap"
        )
        XCTAssertEqual(
            matching(SmartPlaylistQuery(excludeMature: true)),
            ["scene-cozy", "video-heavy", "pixiv-123-p0", "image-calm"]
        )
    }

    func testOlderPlaylistsDecodeNewFieldsWithDefaultsAndRoundTripSmartQuery() throws {
        let old = try JSONDecoder().decode(
            DisplayPlaylist.self,
            from: Data(#"{"mode":"rotate","interval":30}"#.utf8)
        )
        XCTAssertEqual(old.skipRecentDays, 0)
        XCTAssertFalse(old.preferHigherRated)
        XCTAssertNil(old.smartQuery)

        let outOfRange = try JSONDecoder().decode(
            DisplayPlaylist.self,
            from: Data(#"{"mode":"rotate","skipRecentDays":-5,"preferHigherRated":"yes"}"#.utf8)
        )
        XCTAssertEqual(outOfRange.skipRecentDays, 0)
        XCTAssertFalse(outOfRange.preferHigherRated)

        var smart = DisplayPlaylist()
        smart.mode = .rotate
        smart.source = .smart
        smart.order = .shuffle
        smart.skipRecentDays = 7
        smart.preferHigherRated = true
        smart.smartQuery = SmartPlaylistQuery(
            requiredTags: ["Nature", "Cozy"],
            excludedTags: ["Horror"],
            types: [.scene, .still],
            minimumRating: 4,
            maximumEnergy: .medium,
            favoritesOnly: true,
            excludeMature: true
        )
        let roundTripped = try JSONDecoder().decode(DisplayPlaylist.self, from: JSONEncoder().encode(smart))
        XCTAssertEqual(roundTripped, smart)
    }
}
