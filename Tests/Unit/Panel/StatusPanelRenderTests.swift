import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The menu bar panel drawn offscreen: what VoiceOver finds in it, and that it keeps its width in
/// every language, as a popover under the menu bar must.
@MainActor
final class StatusPanelRenderTests: PanelTestCase {
  typealias Source = StatusPanelControllerTests.Source

  /// Long enough to wrap, as Workshop titles are.
  private static func title(_ id: String) -> String { "A very long wallpaper title that will not fit on one line \(id)" }

  private func input(
    displays: Int, muted: Bool = false, playlists: [String: StatusPanelModel.PlaylistBadge] = [:]
  ) -> StatusPanelModel.Input {
    let ids = (1...12).map { "w\($0)" }
    let all: [StatusMenuModel.Display] = (1...displays).map { index in
      StatusMenuModel.Display(
        id: index == 1 ? "primary" : "\(index)", title: "Studio Display (\(index) - Role)",
        wallpaperID: "w\(index)", canPrevious: true, canNext: true, canRandom: true,
        recent: ["w\(index)", "w10", "w11"].map { .init(id: $0, title: "Wallpaper \($0)") })
    }
    return StatusPanelModel.Input(
      menu: .init(playbackIsCurrent: true, hasActiveWallpapers: true, paused: false, wallpapersMuted: muted,
                  displays: all, canLockScreen: true),
      library: ids.map { .init(id: $0, title: Self.title($0), kind: .scene, previewFile: nil, isPlayable: true) },
      hold: .rule(stopped: false), playlists: playlists)
  }

  private func host(
    _ source: Source, maxHeight: CGFloat? = nil
  ) -> (NSHostingView<StatusPanelRoot>, StatusPanelController) {
    let controller = StatusPanelController(source: source, random: PlaylistPlannerTests.SplitMix(state: 1))
    controller.start()
    addTeardownBlock { @MainActor in
      controller.stop()
      withExtendedLifetime(source) {}
    }
    let hosting = NSHostingView(rootView: StatusPanelRoot(controller: controller, maxHeight: maxHeight))
    hosting.layoutSubtreeIfNeeded()
    return (hosting, controller)
  }

  /// A source whose meter holds a graded reading, as the panel finds it with the menu bar figure on.
  private func source(_ input: StatusPanelModel.Input, energy: Bool) -> Source {
    let source = Source(input)
    guard energy else { return source }
    let counters = SteadyEnergy()
    let monitor = EnergyUsageMonitor(source: counters)
    let meter = MenuBarEnergyMeter(monitor: monitor, showsInMenuBar: true)
    monitor.record(counters.sample())
    monitor.record(counters.sample())
    addTeardownBlock { @MainActor in meter.stop() }
    source.energy = meter
    return source
  }

  func testVoiceOverFindsEveryControlAndTheDisplayPickerOnlyWithTwoDisplays() throws {
    try pinPanelLanguageToEnglish()
    let playlist = StatusPanelModel.PlaylistBadge(kind: .dayNight)
    let (two, _) = host(source(input(displays: 2, playlists: ["primary": playlist]), energy: true))
    let elements = AccessibilityElement.everything(in: two)
    for identifier in [
      "status-panel-displays", "status-panel-artwork", "status-panel-title", "status-panel-playlist",
      "status-panel-previous", "status-panel-toggle", "status-panel-next",
      "status-panel-random", "status-panel-favorite", "status-panel-mute", "status-panel-mute-all",
      "status-panel-shuffle", "status-panel-energy",
      "status-panel-control-panel", "status-panel-settings", "status-panel-quit",
    ] {
      XCTAssertTrue(elements.contains { $0.identifier == identifier }, "\(identifier) is reachable")
    }
    XCTAssertTrue(elements.contains { $0.text == Self.title("w10") }, "Recently used names its wallpapers")
    XCTAssertTrue(elements.contains { $0.text == "Quit WallpaperMachine" }, "The icon-only Quit is named")

    let (one, _) = host(Source(input(displays: 1)))
    let oneElements = AccessibilityElement.everything(in: one)
    XCTAssertFalse(oneElements.contains { $0.identifier == "status-panel-displays" },
                   "One display needs no picker")
    XCTAssertFalse(oneElements.contains { $0.identifier == "status-panel-playlist" },
                   "A display with no active playlist shows no playlist badge")
  }

  func testThreeDisplaysSwitchToTheCompactDisplayMenuWithoutGrowingWider() throws {
    try pinPanelLanguageToEnglish()
    let (three, controller) = host(Source(input(displays: 3)))
    XCTAssertTrue(controller.panel.usesCompactDisplayPicker)
    XCTAssertEqual(three.fittingSize.width, StatusPanelView.width, accuracy: 1)
    let elements = AccessibilityElement.everything(in: three)
    let pickers = elements.filter { $0.identifier == "status-panel-displays" }
    XCTAssertFalse(pickers.isEmpty, "Compact display menu remains reachable by VoiceOver")
    XCTAssertTrue(
      pickers.contains { $0.value == "Studio Display (1 - Role)" || $0.help == "Studio Display (1 - Role)" },
      "Compact display menu exposes the active display's full title")
  }

  func testShortScreenMaxHeightCapsPopoverWithoutCollapsingAndKeepsFooterReachable() throws {
    try pinPanelLanguageToEnglish()
    let shortCap: CGFloat = 420
    let (capped, _) = host(
      source(input(displays: 3, muted: true, playlists: ["primary": .init(kind: .dayNight)]), energy: true),
      maxHeight: shortCap)
    let cappedSize = capped.fittingSize
    XCTAssertEqual(cappedSize.width, StatusPanelView.width, accuracy: 1)
    XCTAssertEqual(cappedSize.height, shortCap, accuracy: 1,
                   "A tall popover on a short screen caps at maxHeight instead of overflowing or collapsing")

    capped.setFrameSize(cappedSize)
    capped.layoutSubtreeIfNeeded()
    let cappedElements = AccessibilityElement.everything(in: capped)
    for identifier in ["status-panel-control-panel", "status-panel-settings", "status-panel-quit"] {
      XCTAssertTrue(cappedElements.contains { $0.identifier == identifier },
                    "Pinned footer control \(identifier) stays reachable when the body scrolls")
    }

    // On a tall display with short content, the popover fits naturally rather than stretching or collapsing.
    let emptyDisplay = StatusMenuModel.Display(
      id: "primary", title: "Built-in Display (1 - Primary)", wallpaperID: nil,
      canPrevious: false, canNext: false, canRandom: false, recent: [])
    let shortInput = StatusPanelModel.Input(
      menu: .init(playbackIsCurrent: true, hasActiveWallpapers: false, paused: false,
                  wallpapersMuted: false, displays: [emptyDisplay], canLockScreen: true),
      library: [])
    let (natural, _) = host(Source(shortInput), maxHeight: 1200)
    let naturalSize = natural.fittingSize
    XCTAssertEqual(naturalSize.width, StatusPanelView.width, accuracy: 1)
    XCTAssertGreaterThan(naturalSize.height, 180, "A scrollable status panel must never collapse")
    XCTAssertLessThan(naturalSize.height, 550, "Short content fits naturally without stretching to maxHeight")
  }

  func testPlaylistBadgeTitlesMatchNowPlayingRotationConventions() throws {
    try pinPanelLanguageToEnglish()
    let dayNight = StatusPanelModel.PlaylistBadge(kind: .dayNight)
    XCTAssertEqual(dayNight.title, "Day and night")
    XCTAssertEqual(dayNight.systemImage, "sunrise")

    let favoritesShuffle = StatusPanelModel.PlaylistBadge(kind: .rotate(source: .favorites, order: .shuffle))
    XCTAssertEqual(favoritesShuffle.title, "Favorites")
    XCTAssertEqual(favoritesShuffle.systemImage, "shuffle")

    let collection = StatusPanelModel.PlaylistBadge(
      kind: .rotate(source: .collection(name: "Night"), order: .sequential), isPaused: true)
    XCTAssertEqual(collection.title, "Night")
    XCTAssertEqual(collection.systemImage, "repeat")
    XCTAssertTrue(collection.accessibilityText.contains("Playlist paused"))
  }

  func testSegmentedControlSegmentsExposeHoverTooltipsForChoosableAndStaticSegments() {
    let view = SettingsSegmentedControl(
      segments: [
        .init(value: "low", title: "Low Power"),
        .init(value: "high", title: "Ultra High Quality", help: "Ultra High Quality (60 fps)"),
        .init(value: "custom", title: "Custom", isEnabled: false),
      ],
      selection: "custom",
      onSelect: { _ in }
    )
    .panelTheme(theme: .shared, locale: .shared)
    .frame(width: 240)
    let hosting = NSHostingView(rootView: view)
    hosting.layoutSubtreeIfNeeded()
    let tooltips = Set(AccessibilityElement.everything(in: hosting).map(\.help))
    XCTAssertTrue(tooltips.contains("Low Power"))
    XCTAssertTrue(tooltips.contains("Ultra High Quality (60 fps)"))
    XCTAssertTrue(tooltips.contains("Custom"))
  }

  /// An empty display says what to do: pick from the switcher below it, or, with nothing in the
  /// switcher, look in the Control Panel the footer opens. It never points at a switcher that is
  /// not there.
  func testAnEmptyDisplaySaysWhereToFindAWallpaperWithOrWithoutTheSwitcher() throws {
    try pinPanelLanguageToEnglish()
    func panel(library: [String]) -> StatusPanelModel.Panel {
      let display = StatusMenuModel.Display(
        id: "primary", title: "Studio Display (1 - Role)", wallpaperID: nil, canPrevious: false,
        canNext: false, canRandom: false, recent: [])
      let input = StatusPanelModel.Input(
        menu: .init(playbackIsCurrent: true, hasActiveWallpapers: false, paused: false, wallpapersMuted: false,
                    displays: [display], canLockScreen: true),
        library: library.map { .init(id: $0, title: $0, kind: .scene, previewFile: nil, isPlayable: true) })
      return StatusPanelModel.make(input, display: nil, strip: library)
    }
    let unstocked = panel(library: [])
    let stocked = panel(library: ["a", "b"])
    XCTAssertEqual(unstocked.state, .empty)
    XCTAssertEqual(stocked.state, .empty)
    XCTAssertTrue(unstocked.strip.isEmpty)
    XCTAssertFalse(stocked.strip.isEmpty)
    XCTAssertFalse(unstocked.stateLine.isEmpty)
    XCTAssertFalse(stocked.stateLine.isEmpty)
    XCTAssertNotEqual(unstocked.stateLine, stocked.stateLine, "with no switcher, the line points elsewhere")
  }

  func testThePanelKeepsItsWidthInEveryLanguage() throws {
    let languages = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: ["en"])
    PanelLocale.shared.bind(to: languages)
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    for language in AppLanguage.supported.map(\.tag) {
      try languages.set(language)
      let (hosting, _) = host(source(input(displays: 3, muted: true), energy: true))
      let size = hosting.fittingSize
      XCTAssertEqual(size.width, StatusPanelView.width, accuracy: 1, "\(language): the panel keeps its width")
      XCTAssertLessThan(size.height, 820, "\(language): the panel fits under the menu bar of a small screen")
    }
  }
}

/// 1.2 W of CPU, two seconds a sample, however often it is asked.
private final class SteadyEnergy: EnergyUsageSource, @unchecked Sendable {
  private let lock = NSLock()
  private var step: UInt64 = 0

  func sample() -> EnergyUsageSample? {
    lock.lock()
    defer { lock.unlock() }
    step += 1
    return EnergyUsageSample(
      uptimeNanoseconds: step * 2_000_000_000,
      own: [1: CoalitionEnergyCounters(
        cpuEnergyNanojoules: step * 2_400_000_000, gpuEnergyNanojoules: 0, gpuTimeNanoseconds: 0)],
      otherGPUTime: [:])
  }
}
