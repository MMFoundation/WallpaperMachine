import XCTest

@testable import WallpaperMachine

@MainActor
final class AppThemeTests: XCTestCase {
  func testThemeSurvivesRecreationAndResetLeavesOtherPreferencesUntouched() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(true, forKey: "unrelatedPreference")

    let store = AppThemeStore(defaults: defaults)
    store.setMode(.light)
    try store.setAccent("#B43271")
    store.setTone(.warm)
    store.setIcon(.night)
    store.setHalloween(.off)
    store.setChristmas(.off)
    store.setWindowStyle(.liquidGlass)
    try store.setGlassTransparency(72)
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.mode, .light)
    XCTAssertEqual(restored.preferences.accent, "#b43271")
    XCTAssertEqual(restored.preferences.tone, .warm)
    XCTAssertEqual(restored.preferences.icon, .night)
    XCTAssertEqual(restored.preferences.halloween, .off)
    XCTAssertEqual(restored.preferences.christmas, .off)
    XCTAssertEqual(restored.preferences.windowStyle, .liquidGlass)
    XCTAssertEqual(restored.preferences.glassTransparency, 72)

    restored.reset()
    let reset = AppThemeStore(defaults: defaults)
    XCTAssertEqual(reset.preferences.mode, .system)
    XCTAssertNotEqual(reset.preferences.accent, "#b43271")
    XCTAssertEqual(reset.preferences.tone, .neutral)
    XCTAssertEqual(reset.preferences.icon, .day)
    XCTAssertEqual(reset.preferences.halloween, .automatic)
    XCTAssertEqual(reset.preferences.christmas, .automatic)
    XCTAssertEqual(reset.preferences.windowStyle, .solid)
    XCTAssertEqual(reset.preferences.glassTransparency, AppThemePreferences.defaultGlassTransparency)
    XCTAssertTrue(defaults.bool(forKey: "unrelatedPreference"))
  }

  func testInvalidThemeChangeCannotOverwriteSavedPreferences() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let store = AppThemeStore(defaults: defaults)
    store.setMode(.dark)
    try store.setAccent("#aa3366")
    store.setIcon(.minimal)
    let before = store.preferences
    for accent in ["#fff';alert(1)//", "#fff", "red", ""] {
      XCTAssertThrowsError(try store.setAccent(accent))
    }
    XCTAssertEqual(store.preferences, before)
    XCTAssertEqual(AppThemeStore(defaults: defaults).preferences, before)
  }

  func testDamagedSavedColorDoesNotDiscardValidAppearanceChoice() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(
      ["mode": "dark", "accent": "not-a-color", "tone": "warm", "icon": "minimal"],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.mode, .dark)
    XCTAssertTrue(AppThemePreferences.validAccent(restored.preferences.accent))
    XCTAssertEqual(restored.preferences.tone, .warm)
    XCTAssertEqual(restored.preferences.icon, .minimal)
  }

  // MARK: The Halloween look

  /// A clock a test moves by hand.
  private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
  }

  func testHalloweenWeekRunsFromOctoberTwentyFourthToNovemberFirstByTheLocalCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
      calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour))!
    }
    for (date, covered) in [
      (day(10, 23, hour: 23), false), (day(10, 24, hour: 0), true), (day(10, 31), true),
      (day(11, 1, hour: 23), true), (day(11, 2, hour: 0), false), (day(3, 15), false),
      (day(12, 25), false),
    ] {
      XCTAssertEqual(Season.halloween.covers(date, in: calendar), covered, "\(date)")
    }
    // Midnight on November 2 in Tokyo is still November 1 in New York.
    var newYork = calendar
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    XCTAssertTrue(Season.halloween.covers(day(11, 2, hour: 0), in: newYork))
  }

  func testTheHalloweenChoiceDecidesWhenTheLookIsOnAndTheDockIconFollowsIt() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let clock = Clock(.noon(month: 10, day: 27))
    let store = AppThemeStore(defaults: defaults, now: { clock.now })
    store.setIcon(.minimal)
    XCTAssertEqual(store.preferences.halloween, .automatic, "Halloween week is the default")
    XCTAssertEqual(store.season, .halloween)
    XCTAssertEqual(store.dockIconName, Season.halloween.dockImageName)

    store.setHalloween(.off)
    XCTAssertNil(store.season)
    XCTAssertEqual(store.dockIconName, AppThemePreferences.Icon.minimal.imageName)

    clock.now = .outsideAnySeason
    store.setHalloween(.always)
    XCTAssertEqual(store.season, .halloween, "Always is on whatever the date")
    XCTAssertEqual(
      AppThemeStore(defaults: defaults, now: { clock.now }).season, .halloween,
      "The choice is restored at launch")

    store.reset()
    XCTAssertNil(store.season, "Reset goes back to Halloween week, which March is not in")
    XCTAssertEqual(store.dockIconName, AppThemePreferences.Icon.day.imageName)
  }

  func testTheLookStartsAndEndsWhenTheDayChangesWhileTheAppRuns() async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let clock = Clock(.noon(month: 10, day: 23))
    let store = AppThemeStore(defaults: defaults, now: { clock.now })
    XCTAssertNil(store.season)

    clock.now = .noon(month: 10, day: 24)
    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    for _ in 0..<40 where store.season == nil { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(store.season, .halloween, "Midnight into October 24 starts the look")

    clock.now = .noon(month: 11, day: 2)
    store.refreshSeason()
    XCTAssertNil(store.season, "November 2 ends it")
    XCTAssertEqual(store.preferences.halloween, .automatic, "The date never changes the choice")
  }

  func testUnknownSavedHalloweenChoiceFallsBackToHalloweenWeekAndKeepsTheRest() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(
      ["mode": "dark", "accent": "#aa3366", "tone": "cool", "icon": "night", "halloween": "spooky"],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults, now: { .outsideAnySeason })
    XCTAssertEqual(restored.preferences.halloween, .automatic)
    XCTAssertEqual(restored.preferences.icon, .night)
    XCTAssertEqual(restored.preferences.tone, .cool)
  }

  func testUnknownSavedIconDoesNotDiscardOtherPreferences() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(
      ["mode": "dark", "accent": "#aa3366", "tone": "cool", "icon": "unavailable"],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.icon, .day)
    XCTAssertEqual(restored.preferences.mode, .dark)
    XCTAssertEqual(restored.preferences.accent, "#aa3366")
    XCTAssertEqual(restored.preferences.tone, .cool)
  }

  // MARK: The Christmas look

  func testChristmasWeekRunsFromDecemberEighteenthToTwentySixthByTheLocalCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
      calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour))!
    }
    for (date, covered) in [
      (day(12, 17, hour: 23), false), (day(12, 18, hour: 0), true), (day(12, 24), true),
      (day(12, 25), true), (day(12, 26, hour: 23), true), (day(12, 27, hour: 0), false),
      (day(10, 31), false), (day(3, 15), false),
    ] {
      XCTAssertEqual(Season.christmas.covers(date, in: calendar), covered, "\(date)")
    }
    // Midnight on December 27 in Tokyo is still December 26 in New York.
    var newYork = calendar
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    XCTAssertTrue(Season.christmas.covers(day(12, 27, hour: 0), in: newYork))
  }

  func testChristmasChoiceMutualExclusivityWithHalloweenAndDayChanges() async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let clock = Clock(.noon(month: 12, day: 17))
    let store = AppThemeStore(defaults: defaults, now: { clock.now })
    store.setIcon(.minimal)
    XCTAssertEqual(store.preferences.christmas, .automatic, "Christmas week is the default")
    XCTAssertNil(store.season)

    clock.now = .noon(month: 12, day: 18)
    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    for _ in 0..<40 where store.season == nil { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(store.season, .christmas, "Midnight into December 18 starts the look")
    XCTAssertEqual(store.dockIconName, Season.christmas.dockImageName)

    store.setChristmas(.off)
    XCTAssertNil(store.season)
    XCTAssertEqual(store.dockIconName, AppThemePreferences.Icon.minimal.imageName)

    clock.now = .outsideAnySeason
    store.setChristmas(.always)
    XCTAssertEqual(store.season, .christmas)
    XCTAssertEqual(AppThemeStore(defaults: defaults, now: { clock.now }).season, .christmas)

    // Choosing Always for Halloween clears Always on Christmas so only one season is forced.
    store.setHalloween(.always)
    XCTAssertEqual(store.season, .halloween)
    XCTAssertEqual(store.preferences.christmas, .automatic)

    store.setChristmas(.always)
    XCTAssertEqual(store.season, .christmas)
    XCTAssertEqual(store.preferences.halloween, .automatic)

    store.setChristmas(.automatic)
    clock.now = .noon(month: 12, day: 27)
    store.refreshSeason()
    XCTAssertNil(store.season, "December 27 ends Christmas week")
  }

  // MARK: Liquid Glass and transparency

  func testLiquidGlassPreviewCommitsOnSaveAndRefusesOutOfRangeValues() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let store = AppThemeStore(defaults: defaults, now: { .outsideAnySeason })
    store.setWindowStyle(.liquidGlass)
    XCTAssertEqual(store.preferences.windowStyle, .liquidGlass)
    XCTAssertEqual(store.preferences.glassTransparency, AppThemePreferences.defaultGlassTransparency)

    // Drag preview updates in-memory preferences immediately without writing defaults on every step.
    store.previewGlassTransparency(80)
    XCTAssertEqual(store.preferences.glassTransparency, 80)
    XCTAssertEqual(
      AppThemeStore(defaults: defaults, now: { .outsideAnySeason }).preferences.glassTransparency,
      AppThemePreferences.defaultGlassTransparency,
      "Preview alone does not persist")

    // Releasing on the previewed value persists it even though in-memory state already matches.
    try store.setGlassTransparency(80)
    XCTAssertEqual(
      AppThemeStore(defaults: defaults, now: { .outsideAnySeason }).preferences.glassTransparency, 80)

    for invalid in [-1, 101, Int.min, Int.max] {
      XCTAssertThrowsError(try store.setGlassTransparency(invalid))
    }
    XCTAssertEqual(store.preferences.glassTransparency, 80)
    XCTAssertEqual(
      AppThemeStore(defaults: defaults, now: { .outsideAnySeason }).preferences.glassTransparency, 80)
  }

  func testDamagedSavedChristmasOrGlassPreferencesFallBackWithoutDiscardingTheRest() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(
      [
        "mode": "dark", "accent": "#aa3366", "tone": "warm", "icon": "night",
        "christmas": "jolly", "windowStyle": "frosted", "glassTransparency": "050",
      ],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults, now: { .outsideAnySeason })
    XCTAssertEqual(restored.preferences.mode, .dark)
    XCTAssertEqual(restored.preferences.accent, "#aa3366")
    XCTAssertEqual(restored.preferences.tone, .warm)
    XCTAssertEqual(restored.preferences.icon, .night)
    XCTAssertEqual(restored.preferences.christmas, .automatic)
    XCTAssertEqual(restored.preferences.windowStyle, .solid)
    XCTAssertEqual(restored.preferences.glassTransparency, AppThemePreferences.defaultGlassTransparency)
  }
}
