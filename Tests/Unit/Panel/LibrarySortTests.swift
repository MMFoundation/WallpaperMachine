import XCTest

@testable import WallpaperMachine

/// Installed's seven sort keys, in both directions.
@MainActor
final class LibrarySortTests: XCTestCase {
  private let locale = Locale(identifier: "en_US")

  /// Wallpapers `b` Beta/Video/300/3000, `a` alpha/Scene/100/nil, `c` Gamma/Scene/nil/1000 and
  /// `d` Delta/Web/200/2000, with `c` and `a` favorites.
  private let rows = [
    LibraryRows.row("b", "Beta", kind: .video, size: 300, added: 3000),
    LibraryRows.row("a", "alpha", kind: .scene, size: 100, added: nil),
    LibraryRows.row("c", "Gamma", kind: .scene, size: nil, added: 1000),
    LibraryRows.row("d", "Delta", kind: .web, size: 200, added: 2000),
  ]

  private func order(_ sort: LibrarySort, flipped: Bool = false) -> [String] {
    let descending = flipped ? !sort.startsDescending : sort.startsDescending
    return LibraryRows.titles(
      sort.sorted(rows, descending: descending, favorites: ["c", "a"], locale: locale))
  }

  func testNamesReadFromAToZIgnoringCase() {
    XCTAssertEqual(order(.title), ["alpha", "Beta", "Delta", "Gamma"])
    XCTAssertEqual(order(.title, flipped: true), ["Gamma", "Delta", "Beta", "alpha"])
  }

  func testTheTypeSortBreaksTiesByNameInTheNaturalDirectionWhicheverWayItRuns() {
    XCTAssertEqual(order(.type), ["alpha", "Gamma", "Beta", "Delta"], "Scene, Video, Web")
    XCTAssertEqual(
      order(.type, flipped: true), ["Delta", "Beta", "alpha", "Gamma"],
      "the kinds reverse; the two scenes keep A to Z")
  }

  func testFavoritesComeFirstAndFlippingPutsThemLast() {
    XCTAssertEqual(order(.favorites), ["alpha", "Gamma", "Beta", "Delta"])
    XCTAssertEqual(order(.favorites, flipped: true), ["Beta", "Delta", "alpha", "Gamma"])
  }

  func testSizeAndDateSortBiggestAndNewestFirstWithUnmeasuredRowsLastEitherWay() {
    XCTAssertEqual(order(.size), ["Beta", "Delta", "alpha", "Gamma"], "largest first")
    XCTAssertEqual(
      order(.size, flipped: true), ["alpha", "Delta", "Beta", "Gamma"],
      "an unmeasured folder sorts last in both directions")
    XCTAssertEqual(order(.added), ["Beta", "Delta", "Gamma", "alpha"], "newest first")
    XCTAssertEqual(
      order(.added, flipped: true), ["Gamma", "Delta", "Beta", "alpha"], "no date still last")
  }

  func testLastUsedPutsTheNewestUseFirstWithNeverUsedRowsLastEitherWayAndTiesByName() {
    let used: [String: Date] = [
      "b": Date(timeIntervalSince1970: 500), "d": Date(timeIntervalSince1970: 900),
      "c": Date(timeIntervalSince1970: 500),
    ]
    func order(descending: Bool) -> [String] {
      LibraryRows.titles(
        LibrarySort.lastUsed.sorted(
          rows, descending: descending, favorites: [], lastUsed: used, locale: locale))
    }
    XCTAssertTrue(LibrarySort.lastUsed.startsDescending)
    XCTAssertEqual(order(descending: true), ["Delta", "Beta", "Gamma", "alpha"], "most recent first")
    XCTAssertEqual(
      order(descending: false), ["Beta", "Gamma", "Delta", "alpha"],
      "a wallpaper never used sorts last in both directions, and equal dates read A to Z")
  }

  func testEnergyUseSortsHeaviestFirstWithUnratedRowsLastEitherWayAndTiesByName() {
    func rating(_ milliwatts: Double) -> LibraryEnergyRating {
      LibraryEnergyRating(snapshot: [
        "level": EnergyLevel(milliwatts: milliwatts).rawValue,
        "milliwatts": milliwatts,
        "displays": 1,
        "renderScale": 1.0,
      ])!
    }
    let rated = [
      LibraryRows.row("b", "Beta", kind: .scene, energy: rating(1_200)),
      LibraryRows.row("a", "alpha", kind: .scene, energy: nil),
      LibraryRows.row("c", "Gamma", kind: .scene, energy: rating(1_200)),
      LibraryRows.row("d", "Delta", kind: .scene, energy: rating(3_400)),
      LibraryRows.row("e", "Epsilon", kind: .scene, energy: rating(450)),
      LibraryRows.row("f", "Zeta", kind: .scene, energy: rating(.nan)),
    ]
    func order(descending: Bool) -> [String] {
      LibraryRows.titles(
        LibrarySort.energy.sorted(rated, descending: descending, favorites: [], locale: locale))
    }
    XCTAssertTrue(LibrarySort.energy.startsDescending)
    XCTAssertEqual(LibrarySort.energy.name, L("Energy use"))
    XCTAssertEqual(
      order(descending: true), ["Delta", "Beta", "Gamma", "Epsilon", "alpha", "Zeta"],
      "heaviest first, equal power reads A to Z, and unrated or non-finite rows stay last")
    XCTAssertEqual(
      order(descending: false), ["Epsilon", "Beta", "Gamma", "Delta", "alpha", "Zeta"],
      "lightest first, with ties still A to Z and unrated rows still last")
  }

  func testChoosingAKeyStartsItInItsNaturalDirection() {
    XCTAssertEqual(
      LibrarySort.allCases.filter(\.startsDescending), [.favorites, .size, .added, .lastUsed, .energy],
      "names and types read A to Z; favorites, size, dates and energy use start with the most")
  }

  func testNumbersInTitlesCountAsNumbersAndAccentsAndCaseAreIgnored() {
    let titles = ["Wallpaper 10", "wallpaper 2", "Éclair", "eclair", "Zebra", "Wallpaper 1"]
    let sorted = LibrarySort.title.sorted(
      titles.enumerated().map { LibraryRows.row("\($0.offset)", $0.element) }, descending: false,
      favorites: [], locale: locale)
    XCTAssertEqual(
      LibraryRows.titles(sorted),
      ["Éclair", "eclair", "Wallpaper 1", "wallpaper 2", "Wallpaper 10", "Zebra"],
      "equal titles keep the order they came in")
  }

  func testTheSameLibraryAlwaysListsInTheSameOrder() {
    let twins = (0..<50).map { LibraryRows.row("id\($0)", "Same", kind: .scene, size: 5) }
    for sort in LibrarySort.allCases {
      XCTAssertEqual(
        sort.sorted(twins, descending: true, favorites: [], locale: locale).map(\.id),
        twins.map(\.id), "\(sort): rows equal in every key stay as they came")
    }
  }

  func testATenThousandWallpaperLibrarySortsInReasonableTime() {
    let big = (0..<10_000).map {
      LibraryRows.row("id\($0)", "Wallpaper \(($0 * 7919) % 10_000)", size: Int64($0 % 97))
    }
    let started = Date()
    _ = LibrarySort.title.sorted(big, descending: false, favorites: [], locale: locale)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "sorted once per change, off the body")
  }
}
