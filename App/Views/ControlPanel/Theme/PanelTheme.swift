import SwiftUI

/// Whether the panel is drawn light or dark; the resolved appearance, never the stored mode.
enum PanelAppearance: Sendable {
  case light, dark

  init(_ scheme: ColorScheme) {
    self = scheme == .dark ? .dark : .light
  }
}

/// Everything the panel's look derives from the appearance preferences: the contrast-fitted
/// accent tokens, the tone's surface tokens for the resolved light or dark appearance, and the
/// Liquid Glass translucency settings. While a season is on, its accent and surfaces stand in for
/// the person's.
struct PanelTheme: Equatable, Sendable {
  let tone: AppThemePreferences.Tone
  let appearance: PanelAppearance
  /// The seasonal look the panel wears, nil for the person's own.
  let season: Season?
  let windowStyle: AppThemePreferences.WindowStyle
  /// The Liquid Glass transparency percentage (`0...100`), read when `windowStyle == .liquidGlass`.
  let glassTransparency: Int
  let accent: AccentPalette
  let surface: SurfacePalette

  var isLiquidGlass: Bool { windowStyle == .liquidGlass }

  /// How far a control that cannot be used fades: one amount for every button, capsule, link and
  /// row, so a disabled control reads the same wherever it is (`panelDisabledOpacity(_:)`).
  static let disabledOpacity: Double = 0.4

  init(
    preferences: AppThemePreferences = AppThemePreferences(), season: Season? = nil,
    appearance: PanelAppearance
  ) {
    tone = preferences.tone
    self.appearance = appearance
    self.season = season
    windowStyle = preferences.windowStyle
    glassTransparency = min(
      AppThemePreferences.glassTransparencyRange.upperBound,
      max(AppThemePreferences.glassTransparencyRange.lowerBound, preferences.glassTransparency))
    if let season {
      accent = AccentPalette(accent: season.accent, appearance: appearance)
      surface = SurfacePalette(season: season, appearance: appearance)
    } else {
      accent = AccentPalette(accent: preferences.accent, appearance: appearance)
      surface = SurfacePalette(tone: preferences.tone, appearance: appearance)
    }
  }

  private var glassFactor: Double { Double(glassTransparency) / 100.0 }

  /// Opacity of the tinted background laid over the behind-window glass blur.
  /// Stays `1` when Solid or macOS Reduce Transparency is on; otherwise moves smoothly from `0.86`
  /// (0% transparency) down to `0.16` (100% transparency) so labels keep their contrast floor.
  func windowBackgroundOpacity(reduceTransparency: Bool) -> Double {
    guard isLiquidGlass, !reduceTransparency else { return 1 }
    return 0.86 - 0.70 * glassFactor
  }

  /// Opacity of secondary structural surfaces (Settings pages, inspector column, bottom bar).
  func panelSurfaceOpacity(reduceTransparency: Bool) -> Double {
    guard isLiquidGlass, !reduceTransparency else { return 1 }
    return 0.78 - 0.56 * glassFactor
  }

  /// Opacity of grouped cards over the translucent backdrop. Stays higher than the canvas so
  /// settings rows and inspector controls remain crisp even at maximum transparency.
  func cardSurfaceOpacity(reduceTransparency: Bool) -> Double {
    guard isLiquidGlass, !reduceTransparency else { return 1 }
    return 0.88 - 0.42 * glassFactor
  }

  /// Opacity of the seasonal ground bar (`NowPlayingBar`) under `SeasonHorizon`.
  func seasonalGroundOpacity(reduceTransparency: Bool) -> Double {
    guard isLiquidGlass, !reduceTransparency else { return 1 }
    return 0.94 - 0.24 * glassFactor
  }

  func backgroundFill(reduceTransparency: Bool) -> Color {
    surface.background.color.opacity(windowBackgroundOpacity(reduceTransparency: reduceTransparency))
  }

  func surfaceFill(reduceTransparency: Bool) -> Color {
    surface.surface.color.opacity(panelSurfaceOpacity(reduceTransparency: reduceTransparency))
  }

  func cardFill(reduceTransparency: Bool) -> Color {
    surface.card.color.opacity(cardSurfaceOpacity(reduceTransparency: reduceTransparency))
  }
}

extension View {
  /// Fades the view by `PanelTheme.disabledOpacity` while it cannot be used.
  func panelDisabledOpacity(_ isEnabled: Bool) -> some View {
    opacity(isEnabled ? 1 : PanelTheme.disabledOpacity)
  }
}

extension EnvironmentValues {
  /// The palettes of the panel the view is in; the defaults outside one (previews, tests).
  @Entry var panelTheme = PanelTheme(appearance: .light)
}

extension View {
  /// Applies the panel's look and language to every view below: the accent as the tint, the
  /// palettes in `\.panelTheme`, and the formatting locale for literals that localize themselves.
  ///
  /// The root view calls this once. It re-renders its content when the stored accent or tone
  /// changes, when a season starts or ends, when the language does, and when the resolved
  /// appearance flips. It does not
  /// choose light or dark: `AppDelegate` applies the mode through `NSApp.appearance`, the
  /// single writer, and this reads the result from the environment.
  func panelTheme(theme: AppThemeStore, locale: PanelLocale) -> some View {
    modifier(PanelThemeModifier(theme: theme, locale: locale))
  }
}

private struct PanelThemeModifier: ViewModifier {
  @ObservedObject var theme: AppThemeStore
  let locale: PanelLocale
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let resolved = PanelTheme(
      preferences: theme.preferences, season: theme.season, appearance: PanelAppearance(colorScheme))
    content
      .environment(\.panelTheme, resolved)
      .environment(\.locale, locale.locale)
      .tint(resolved.accent.accent.color)
  }
}
