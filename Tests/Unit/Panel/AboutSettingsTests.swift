import AppKit
import XCTest

@testable import WallpaperMachine

/// The update controls and bundled release history available in Settings › About.
@MainActor
final class AboutSettingsTests: SettingsBTestCase {
  func testSettingsSearchOffersOnlyConfiguredUpdatesButAlwaysFindsBundledNotes() async throws {
    try await withPanel { panel in
      let updater = panel.controller.updater
      let settings = panel.controller.settings
      updater.notesReleases = try AppReleaseHistory(markdown: Self.changelogEntry("1.3.0")).entries
      settings.query = "Release notes"
      XCTAssertTrue(settings.search.shows(AboutSettingsSection.updateNotes))
      XCTAssertFalse(settings.search.shows(AboutSettingsSection.earlierReleases))
      for query in ["Show Update", "automatically"] {
        settings.query = query
        XCTAssertFalse(settings.search.shows(AboutSettingsSection.updateActions))
        XCTAssertFalse(settings.search.shows(AboutSettingsSection.updateAutomatic))
      }

      updater.isAvailable = true
      XCTAssertTrue(settings.search.shows(AboutSettingsSection.updateAutomatic))
      settings.query = "Show Update"
      XCTAssertTrue(settings.search.shows(AboutSettingsSection.updateActions))
      updater.isAvailable = false
      XCTAssertFalse(settings.search.shows(AboutSettingsSection.updateActions))
    }
  }

  func testReleaseNotesHaveTheirOwnCardWithEarlierVersionsFoldedAndFitEveryLanguage() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let updater = controller.updater
      updater.isAvailable = true
      updater.canCheck = true
      updater.waitingVersion = "1.4.0"
      updater.notesReleases = try AppReleaseHistory(
        markdown: ["1.3.0", "1.2.0", "1.1.0"].map(Self.changelogEntry).joined(separator: "\n")).entries
      XCTAssertEqual(updater.notesReleases.map(\.version.display), ["1.3.0", "1.2.0", "1.1.0"])

      let settings = controller.settings
      XCTAssertFalse(settings.isOpen(AboutSettingsSection.earlierReleases), "earlier versions start folded")
      settings.query = "Earlier versions"
      XCTAssertTrue(settings.search.shows(AboutSettingsSection.earlierReleases))
      XCTAssertFalse(settings.search.shows(AboutSettingsSection.updateAutomatic))
      settings.query = ""

      let host = SettingsBHost(panel: panel)
      defer { host.close() }
      let size = NSSize(width: 760, height: 560)
      let folder = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_ABOUT_SNAPSHOTS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "pt-BR"] {
        for open in [false, true] {
          settings.setOpen(open, for: AboutSettingsSection.earlierReleases)
          host.use(language: language, dark: false, panel: panel)
          try await host.show(.about, size: size)
          try await host.settle(size)
          XCTAssertTrue(host.fits(size), "About \(language) \(open ? "open" : "folded") fits 760 x 560")
          if let folder {
            try await host.scroll(to: open ? 420 : 170)
            try host.snapshot(to: folder.appendingPathComponent("about-\(language)-\(open ? "open" : "folded").png"))
          }
        }
      }
      if let folder {
        host.use(language: "zh-Hans", dark: true, panel: panel)
        try await host.show(.about, size: NSSize(width: 1240, height: 800))
        try await host.scroll(to: 300)
        try host.snapshot(to: folder.appendingPathComponent("about-zh-Hans-dark-wide.png"))
      }
    }
  }

  func testReleaseDaysAreWrittenInThePanelsLanguage() {
    XCTAssertEqual(ReleaseNotesEntryView.day("2026-11-09", locale: english), "Nov 9, 2026")
    XCTAssertEqual(ReleaseNotesEntryView.day("2026-11-09", locale: Locale(identifier: "zh-Hans")), "2026年11月9日")
    XCTAssertEqual(ReleaseNotesEntryView.day("soon", locale: english), "soon", "not a day: as written")
    XCTAssertNil(ReleaseNotesEntryView.day(nil, locale: english))
  }

  private static func changelogEntry(_ version: String) -> String {
    let previous = "1.\(max(0, (Int(version.split(separator: ".")[1]) ?? 1) - 1)).0"
    let link = "([abc1234](https://github.com/o/r/commit/abc1234def))"
    return """
      ## [\(version)](https://github.com/o/r/compare/v\(previous)...v\(version)) (2026-11-09)
      ### English
      This release makes switching between desktops feel quicker
      #### Improvements
      - Switching to another desktop shows its wallpaper sooner \(link)
      #### Bug Fixes
      - Mission Control no longer leaves trails of foreground windows across the desktop, and wallpapers keep playing during the transition \(link)
      ### 简体中文
      本次更新让切换桌面更加迅速
      #### 改进
      - 切换桌面时壁纸会更快出现 \(link)
      #### 问题修复
      - 打开调度中心时，前台窗口不再在桌面上留下残影，壁纸在过渡期间也会继续播放 \(link)
      ### 한국어
      이번 업데이트로 데스크탑 전환이 더 빨라졌습니다
      #### 개선 사항
      - 다른 데스크탑으로 전환하면 배경화면이 더 빨리 표시됩니다 \(link)

      """
  }

  func testTheVersionRowsReadTheBundleAndTheProductHasAnIconForEveryDockChoice() async throws {
    try await withPanel { panel in
      let info = panel.controller.aboutInfo
      XCTAssertEqual(
        info.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        "what a bug report is filed with")
      for icon in AppThemePreferences.Icon.allCases {
        XCTAssertNoThrow(try icon.image(), "\(icon)")
      }
    }
  }

  func testEveryRowOfThePagesIsASearchableItemWithItsOwnId() {
    let sections: [(String, [SettingsItem])] = [
      ("displays", DisplaysSettingsSection.items), ("shortcuts", ShortcutsSettingsSection.items),
      ("library", LibrarySettingsSection.items), ("storage", StorageSettingsSection.items),
      ("about", AboutSettingsSection.items),
    ]
    for (name, items) in sections {
      XCTAssertFalse(items.isEmpty, name)
      XCTAssertTrue(items.allSatisfy { $0.id.hasPrefix("\(name).") }, name)
    }
    XCTAssertEqual(SettingsRegistry.problems(in: SettingsRegistry.items), [], "no duplicate id, no lost disclosure")
  }

  func testASearchFindsTheChoicesOfARowAndTheLabelsOfItsButtons() {
    let search = { (query: String) -> SettingsSearch in
      SettingsSearch(query: query, index: SettingsIndex(locale: PanelLocale.shared))
    }
    XCTAssertTrue(search("Shuffle").shows(DisplaysSettingsSection.playlistOrder), "an option label finds its row")
    XCTAssertTrue(search("Shuffle").opens(DisplaysSettingsSection.playlist), "and opens the disclosure around it")
    XCTAssertTrue(search("Eject").shows(DisplaysSettingsSection.wallpaper))
    XCTAssertTrue(search("Locate").shows(LibrarySettingsSection.steamActions))
    XCTAssertTrue(search("Diagnostics").shows(StorageSettingsSection.diagnostics))
    XCTAssertTrue(search("Check Now").shows(AboutSettingsSection.updateActions))
    XCTAssertTrue(search("Show Update").shows(AboutSettingsSection.updateActions))
    XCTAssertFalse(search("Restart and Install").shows(AboutSettingsSection.updateActions))
    XCTAssertTrue(search("Record").shows(ShortcutsSettingsSection.togglePlayback))
    XCTAssertTrue(
      search("Keyboard shortcuts").shows(ShortcutsSettingsSection.nextWallpaper),
      "the page's name, which its card no longer repeats as a title, still finds every shortcut")
    XCTAssertFalse(search("Shuffle").shows(DisplaysSettingsSection.playlistInterval))
  }
}
