import SwiftUI

/// Settings › Appearance: how the window looks. Every choice applies at once and changes only this
/// app's window, never a wallpaper, and none of them waits for the renderer.
///
/// While a seasonal look (Halloween or Christmas) is on, its group comes first under the season's
/// picture, and the tone, accent and icon rows it stands in for are dimmed: their choices are kept
/// for when it ends.
struct AppearanceSettingsSection: View {
  private static let look = SettingsItem.Group("look")
  private static let window = SettingsItem.Group("window")
  private static let icon = SettingsItem.Group("icon")
  private static let season = SettingsItem.Group("season")
  private static let reset = SettingsItem.Group("reset")

  static let mode = SettingsItem(
    id: "appearance.mode", section: .appearance, group: look, title: "Appearance",
    keywords: ["System (Auto)", "Light", "Dark"])
  static let tone = SettingsItem(
    id: "appearance.tone", section: .appearance, group: look, title: "Surface tone",
    keywords: ["Neutral", "Warm", "Cool"])
  static let accent = SettingsItem(
    id: "appearance.accent", section: .appearance, group: look, title: "Accent color",
    note: "Colors buttons, links and focus rings.", keywords: ["Custom color"])
  static let windowStyle = SettingsItem(
    id: "appearance.windowStyle", section: .appearance, group: window, title: "Window style",
    note: "Chooses opaque window surfaces or translucent Liquid Glass.",
    keywords: ["Solid", "Liquid Glass"])
  static let glassTransparency = SettingsItem(
    id: "appearance.glassTransparency", section: .appearance, group: window,
    title: "Window transparency",
    note: "Controls how much shows through the Liquid Glass window.",
    keywords: ["Transparency", "Liquid Glass"])
  static let appIcon = SettingsItem(
    id: "appearance.icon", section: .appearance, group: icon, title: "App icon",
    note:
      "Changes the Dock icon while the app is running. Finder and the menu bar stay unchanged.",
    keywords: ["Minimal", "Day", "Night"])
  static let halloween = SettingsItem(
    id: "appearance.halloween", section: .appearance, group: season, title: "Halloween look",
    note:
      "Dresses the window, its accent and the Dock icon for Halloween. Halloween week runs from October 24 to November 1.",
    keywords: ["Halloween week", "Always", "Off"])
  static let christmas = SettingsItem(
    id: "appearance.christmas", section: .appearance, group: season, title: "Christmas look",
    note:
      "Dresses the window, its accent and the Dock icon for Christmas. Christmas week runs from December 18 to December 26.",
    keywords: ["Christmas week", "Always", "Off"])
  static let resetItem = SettingsItem(
    id: "appearance.reset", section: .appearance, group: reset, title: "Theme defaults",
    note:
      "Restores System, the default accent, Neutral tone, Solid window, the Day icon and seasonal looks.",
    keywords: ["Reset appearance"])

  static let items = [
    mode, tone, accent, windowStyle, glassTransparency, appIcon, halloween, christmas, resetItem,
  ]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @FocusState private var focusedMode: AppThemePreferences.Mode?
  @FocusState private var focusedTone: AppThemePreferences.Tone?
  @FocusState private var focusedWindowStyle: AppThemePreferences.WindowStyle?
  @FocusState private var focusedIcon: AppThemePreferences.Icon?
  @FocusState private var focusedHalloween: AppThemePreferences.Halloween?
  @FocusState private var focusedChristmas: AppThemePreferences.Christmas?
  @State private var draggedTransparency: Int?

  var body: some View {
    let preferences = controller.themePreferences
    let season = controller.season
    SettingsPage(.appearance) {
      if season != nil {
        if let season, controller.settings.search.isActive == false { SeasonBanner(season: season) }
        seasonalGroup(preferences, season: season)
      }
      SettingsGroup(Self.look, in: .appearance) {
        AppearanceChoiceRow(Self.mode) { modeCards(preferences.mode) }
        AppearanceChoiceRow(Self.tone) { toneCards(preferences.tone) }
          .heldBySeason(season)
        SettingsRow(Self.accent, stacked: true) { AppearanceAccentControl() }
          .heldBySeason(season)
      }
      SettingsGroup(Self.window, in: .appearance) {
        AppearanceChoiceRow(Self.windowStyle) {
          windowStyleCards(preferences.windowStyle, tone: preferences.tone, season: season)
        }
        SettingsRow(
          Self.glassTransparency,
          note: glassTransparencyNote(preferences.windowStyle)
        ) {
          glassTransparencySlider(
            preferences.glassTransparency, isEnabled: preferences.windowStyle == .liquidGlass)
        }
      }
      SettingsGroup(Self.icon, in: .appearance) {
        SettingsRow(Self.appIcon, stacked: true) { iconOptions(preferences.icon) }
          .heldBySeason(season)
      }
      if season == nil {
        seasonalGroup(preferences, season: season)
      }
      SettingsGroup(Self.reset, in: .appearance) {
        SettingsRow(Self.resetItem) {
          SettingsActionButton("Reset appearance") {
            draggedTransparency = nil
            controller.settings.applyTheme { controller.resetTheme() }
          }
        }
      }
      if controller.settings.search.isActive == false {
        Text("Appearance changes apply right away and only affect this app’s window, not your wallpapers.")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func seasonalGroup(_ preferences: AppThemePreferences, season: Season?) -> some View {
    SettingsGroup(Self.season, in: .appearance) {
      if season == .christmas {
        christmasRow(preferences.christmas, season: season)
        halloweenRow(preferences.halloween, season: season)
      } else {
        halloweenRow(preferences.halloween, season: season)
        christmasRow(preferences.christmas, season: season)
      }
    }
  }

  private func halloweenRow(
    _ current: AppThemePreferences.Halloween, season: Season?
  ) -> some View {
    AppearanceChoiceRow(Self.halloween, note: halloweenNote(current, season: season)) {
      halloweenCards(current)
    }
  }

  private func christmasRow(
    _ current: AppThemePreferences.Christmas, season: Season?
  ) -> some View {
    AppearanceChoiceRow(Self.christmas, note: christmasNote(current, season: season)) {
      christmasCards(current)
    }
  }

  /// While the look is on, the note says until when and that the person's own choices come back.
  private func halloweenNote(_ current: AppThemePreferences.Halloween, season: Season?) -> String? {
    guard season == .halloween else { return nil }
    return switch current {
    case .always:
      L("On all year. Your own accent, tone and Dock icon come back when you choose Halloween week or Off.")
    case .automatic, .off:
      L("On until November 1. Your own accent, tone and Dock icon come back after.")
    }
  }

  /// While the Christmas look is on, the note says until when and that the person's own choices come back.
  private func christmasNote(_ current: AppThemePreferences.Christmas, season: Season?) -> String? {
    guard season == .christmas else { return nil }
    return switch current {
    case .always:
      L("On all year. Your own accent, tone and Dock icon come back when you choose Christmas week or Off.")
    case .automatic, .off:
      L("On until December 26. Your own accent, tone and Dock icon come back after.")
    }
  }

  private func glassTransparencyNote(_ style: AppThemePreferences.WindowStyle) -> String? {
    switch style {
    case .solid:
      L("Switch Window style to Liquid Glass to adjust transparency.")
    case .liquidGlass:
      reduceTransparency
        ? L("macOS Reduce Transparency is on, so the window stays opaque.") : nil
    }
  }

  private func windowStyleCards(
    _ current: AppThemePreferences.WindowStyle, tone: AppThemePreferences.Tone, season: Season?
  ) -> some View {
    HStack(spacing: 14) {
      ForEach(AppThemePreferences.WindowStyle.allCases, id: \.self) { style in
        AppearanceChoiceCard(
          title: style.title,
          miniature: SurfacePalette.miniature(
            windowStyle: style, tone: tone, season: season, appearance: theme.appearance),
          isSelected: style == current
        ) {
          choose(style)
        }
        .settingsRadioKeys(
          style, in: AppThemePreferences.WindowStyle.allCases, focus: $focusedWindowStyle
        ) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func glassTransparencySlider(_ saved: Int, isEnabled: Bool) -> some View {
    let percent = draggedTransparency ?? saved
    let readout = "\(percent)%"
    return HStack(spacing: 8) {
      PanelSlider(
        value: Double(percent),
        range: Double(AppThemePreferences.glassTransparencyRange.lowerBound)...Double(
          AppThemePreferences.glassTransparencyRange.upperBound),
        step: 1,
        accessibilityLabel: L("Window transparency"),
        accessibilityValue: readout,
        events: PanelSliderEvents(
          onDrag: { value in
            let next = Int(value.rounded())
            draggedTransparency = next
            controller.previewThemeGlassTransparency(next)
          },
          onRelease: { value in
            let next = Int(value.rounded())
            draggedTransparency = nil
            commitGlassTransparency(next)
          },
          onStep: { value in
            commitGlassTransparency(Int(value.rounded()))
          })
      )
      .frame(width: 140)
      Text(verbatim: readout)
        .font(.panel(.callout).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)
        .frame(minWidth: 36, alignment: .trailing)
    }
    .disabled(!isEnabled)
    .panelDisabledOpacity(isEnabled)
    .accessibilityElement(children: .contain)
  }

  /// Halloween week shows the everyday look and the Halloween one on one diagonal, as System
  /// shows light and dark; Always shows the Halloween look and Off the everyday one.
  private func halloweenCards(_ current: AppThemePreferences.Halloween) -> some View {
    let everyday = SurfacePalette.miniature(
      tone: controller.themePreferences.tone, appearance: theme.appearance)
    let spooky = SurfacePalette.miniature(season: .halloween, appearance: theme.appearance)
    let ownAccent = AccentPalette(
      accent: controller.themePreferences.accent, appearance: theme.appearance
    ).accent.color
    let pumpkin = AccentPalette(accent: Season.halloween.accent, appearance: theme.appearance)
      .accent.color
    return HStack(spacing: 14) {
      ForEach(AppThemePreferences.Halloween.allCases, id: \.self) { choice in
        AppearanceChoiceCard(
          title: choice.title,
          miniature: choice == .always ? spooky : everyday,
          split: choice == .automatic ? spooky : nil,
          accent: choice == .always ? pumpkin : ownAccent,
          splitAccent: pumpkin,
          isSelected: choice == current
        ) {
          choose(choice)
        }
        .settingsRadioKeys(
          choice, in: AppThemePreferences.Halloween.allCases, focus: $focusedHalloween
        ) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// Christmas week shows the everyday look and the Christmas one on one diagonal, as System
  /// shows light and dark; Always shows the Christmas look and Off the everyday one.
  private func christmasCards(_ current: AppThemePreferences.Christmas) -> some View {
    let everyday = SurfacePalette.miniature(
      tone: controller.themePreferences.tone, appearance: theme.appearance)
    let festive = SurfacePalette.miniature(season: .christmas, appearance: theme.appearance)
    let ownAccent = AccentPalette(
      accent: controller.themePreferences.accent, appearance: theme.appearance
    ).accent.color
    let holly = AccentPalette(accent: Season.christmas.accent, appearance: theme.appearance)
      .accent.color
    return HStack(spacing: 14) {
      ForEach(AppThemePreferences.Christmas.allCases, id: \.self) { choice in
        AppearanceChoiceCard(
          title: choice.title,
          miniature: choice == .always ? festive : everyday,
          split: choice == .automatic ? festive : nil,
          accent: choice == .always ? holly : ownAccent,
          splitAccent: holly,
          isSelected: choice == current
        ) {
          choose(choice)
        }
        .settingsRadioKeys(
          choice, in: AppThemePreferences.Christmas.allCases, focus: $focusedChristmas
        ) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// System shows both looks on one diagonal; Light and Dark show their own.
  private func modeCards(_ current: AppThemePreferences.Mode) -> some View {
    HStack(spacing: 14) {
      ForEach(AppThemePreferences.Mode.allCases, id: \.self) { mode in
        AppearanceChoiceCard(
          title: mode.title,
          miniature: SurfacePalette.miniature(tone: .neutral, appearance: mode == .dark ? .dark : .light),
          split: mode == .system ? SurfacePalette.miniature(tone: .neutral, appearance: .dark) : nil,
          isSelected: mode == current
        ) {
          choose(mode)
        }
        .settingsRadioKeys(mode, in: AppThemePreferences.Mode.allCases, focus: $focusedMode) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// The tones are drawn in the look the window has now, so a Warm card reads as warm in the dark.
  private func toneCards(_ current: AppThemePreferences.Tone) -> some View {
    HStack(spacing: 14) {
      ForEach(AppThemePreferences.Tone.allCases, id: \.self) { tone in
        AppearanceChoiceCard(
          title: tone.title,
          miniature: SurfacePalette.miniature(tone: tone, appearance: theme.appearance),
          isSelected: tone == current
        ) {
          choose(tone)
        }
        .settingsRadioKeys(tone, in: AppThemePreferences.Tone.allCases, focus: $focusedTone) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func iconOptions(_ current: AppThemePreferences.Icon) -> some View {
    HStack(spacing: 18) {
      ForEach(AppThemePreferences.Icon.allCases, id: \.self) { icon in
        AppearanceIconOption(icon: icon, isSelected: icon == current) {
          choose(icon)
        }
        .settingsRadioKeys(icon, in: AppThemePreferences.Icon.allCases, focus: $focusedIcon) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func choose(_ mode: AppThemePreferences.Mode) {
    controller.settings.applyTheme { try controller.setThemeMode(mode) }
  }

  private func choose(_ tone: AppThemePreferences.Tone) {
    controller.settings.applyTheme { try controller.setThemeTone(tone) }
  }

  private func choose(_ windowStyle: AppThemePreferences.WindowStyle) {
    controller.settings.applyTheme { try controller.setThemeWindowStyle(windowStyle) }
  }

  private func commitGlassTransparency(_ percent: Int) {
    controller.settings.applyTheme { try controller.setThemeGlassTransparency(percent) }
  }

  private func choose(_ icon: AppThemePreferences.Icon) {
    controller.settings.applyTheme { try controller.setThemeIcon(icon) }
  }

  private func choose(_ halloween: AppThemePreferences.Halloween) {
    controller.settings.applyTheme { try controller.setThemeHalloween(halloween) }
  }

  private func choose(_ christmas: AppThemePreferences.Christmas) {
    controller.settings.applyTheme { try controller.setThemeChristmas(christmas) }
  }
}

/// The season's horizon above its group while it is on, under a night sky: the band over the Now
/// Playing bar, at the size of a picture, with nothing to read in it.
private struct SeasonBanner: View {
  let season: Season

  @Environment(\.panelTheme) private var theme

  var body: some View {
    SeasonHorizon(season: season, style: .night)
      .frame(maxWidth: .infinity)
      .frame(height: 120)
      .clipShape(
        RoundedRectangle(cornerRadius: TileGridLayout.pictureCornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: TileGridLayout.pictureCornerRadius, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
      .accessibilityHidden(true)
  }
}

extension View {
  /// Locks a row whose choice a season stands in for while it is on; the choice is kept. Its
  /// controls dim themselves, as every disabled control in Settings does.
  fileprivate func heldBySeason(_ season: Season?) -> some View {
    disabled(season != nil)
  }
}
