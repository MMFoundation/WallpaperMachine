import AppKit
import Combine

struct AppThemePreferences: Equatable {
  enum Mode: String {
    case system, light, dark

    var appearance: NSAppearance? {
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    }
  }

  enum Tone: String {
    case neutral, warm, cool
  }

  /// When the window wears the Halloween look (`Season.halloween`).
  enum Halloween: String {
    /// During Halloween week only (`Season.halloween.covers(_:in:)`).
    case automatic
    case always, off
  }

  /// When the window wears the Christmas look (`Season.christmas`).
  enum Christmas: String {
    /// During Christmas week only (`Season.christmas.covers(_:in:)`).
    case automatic
    case always, off
  }

  /// How the window's surfaces are drawn: opaque solid surfaces or translucent Liquid Glass.
  enum WindowStyle: String {
    case solid, liquidGlass
  }

  enum Icon: String, CaseIterable {
    case minimal, day, night

    /// The asset catalog image set holding the 1024 px artwork.
    var imageName: String { "AppIcon" + rawValue.capitalized }

    func image(in bundle: Bundle = .main) throws -> NSImage {
      try AppThemePreferences.dockImage(named: imageName, in: bundle)
    }
  }

  /// Transparency percentage of the Liquid Glass window: 0 is frosted and opaque-leaning,
  /// 100 lets the most behind the window show through while keeping text readable.
  static let glassTransparencyRange = 0...100
  static let defaultGlassTransparency = 50

  var mode: Mode = .system
  var accent = "#80bbff"
  var tone: Tone = .neutral
  var icon: Icon = .day
  var halloween: Halloween = .automatic
  var christmas: Christmas = .automatic
  var windowStyle: WindowStyle = .solid
  var glassTransparency: Int = AppThemePreferences.defaultGlassTransparency

  var snapshot: [String: Any] {
    [
      "mode": mode.rawValue, "accent": accent, "tone": tone.rawValue, "icon": icon.rawValue,
      "halloween": halloween.rawValue, "christmas": christmas.rawValue,
      "windowStyle": windowStyle.rawValue, "glassTransparency": String(glassTransparency),
    ]
  }

  /// The seasonal look the window wears on `date` under these choices, nil for the person's own.
  func season(on date: Date, calendar: Calendar) -> Season? {
    if halloween == .always && christmas == .always {
      return Season.halloween.covers(date, in: calendar) ? .halloween : .christmas
    }
    if halloween == .always { return .halloween }
    if christmas == .always { return .christmas }
    if halloween == .automatic, Season.halloween.covers(date, in: calendar) { return .halloween }
    if christmas == .automatic, Season.christmas.covers(date, in: calendar) { return .christmas }
    return nil
  }

  /// The 1024-pixel artwork of an asset catalog image set as a 512-point Dock icon.
  static func dockImage(named name: String, in bundle: Bundle = .main) throws -> NSImage {
    guard let source = bundle.image(forResource: NSImage.Name(name)) else {
      throw CocoaError(.fileNoSuchFile)
    }
    // The catalog hands out one shared instance; the Dock gets its own sized copy.
    guard source.isValid, let image = source.copy() as? NSImage else {
      throw CocoaError(.fileReadCorruptFile)
    }
    image.size = NSSize(width: 512, height: 512)
    return image
  }

  static func validAccent(_ value: String) -> Bool {
    value.utf8.count == 7 && value.first == "#"
      && value.utf8.dropFirst().allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }

  static func validGlassTransparency(_ value: Int) -> Bool {
    glassTransparencyRange.contains(value)
  }

  static func parseGlassTransparency(_ raw: String) -> Int? {
    guard let value = Int(raw), String(value) == raw, validGlassTransparency(value) else {
      return nil
    }
    return value
  }
}

/// A look the window wears for a holiday instead of the person's own: its palettes and accent
/// (`PanelTheme`), the mark beside the traffic lights and the Dock icon. The person's choices are
/// kept and come back when it ends.
enum Season: String, CaseIterable, Sendable {
  case halloween
  case christmas

  /// The accent while the season is on, fitted for contrast like any other (`AccentPalette`).
  var accent: String {
    switch self {
    case .halloween: "#ff7a1a"
    case .christmas: "#d9363e"
    }
  }

  /// The asset catalog image set of its Dock icon.
  var dockImageName: String { "AppIcon" + rawValue.capitalized }

  /// Whether `date` is in the season's week by the local calendar:
  /// October 24 to November 1 for Halloween, December 18 to December 26 for Christmas.
  func covers(_ date: Date, in calendar: Calendar) -> Bool {
    let day = calendar.dateComponents([.month, .day], from: date)
    switch (self, day.month, day.day) {
    case (.halloween, 10?, let dayOfMonth?): return dayOfMonth >= 24
    case (.halloween, 11?, 1?): return true
    case (.christmas, 12?, let dayOfMonth?): return (18...26).contains(dayOfMonth)
    default: return false
    }
  }
}

/// Native storage survives the panel's ephemeral WebKit data store and process recovery.
@MainActor
final class AppThemeStore: ObservableObject {
  static let shared = AppThemeStore()
  nonisolated static let defaultsKey = "WallpaperMachine.appTheme"
  @Published private(set) var preferences: AppThemePreferences
  /// The seasonal look in effect, nil for the person's own: the seasonal preferences read against
  /// today. It follows the preferences, and the date when the day changes.
  @Published private(set) var season: Season?
  private let defaults: UserDefaults
  private let calendar: Calendar
  private let now: () -> Date
  private var dayChange: AnyCancellable?

  /// - Parameters:
  ///   - calendar, now: The days a season covers are read with these; tests pass a fixed date.
  init(
    defaults: UserDefaults = ClientPreferences.defaults, calendar: Calendar = .autoupdatingCurrent,
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.calendar = calendar
    self.now = now
    let saved = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
    var preferences = AppThemePreferences()
    if let mode = saved["mode"] as? String, let value = AppThemePreferences.Mode(rawValue: mode) {
      preferences.mode = value
    }
    if let accent = saved["accent"] as? String, AppThemePreferences.validAccent(accent) {
      preferences.accent = accent.lowercased()
    }
    if let tone = saved["tone"] as? String, let value = AppThemePreferences.Tone(rawValue: tone) {
      preferences.tone = value
    }
    if let icon = saved["icon"] as? String, let value = AppThemePreferences.Icon(rawValue: icon) {
      preferences.icon = value
    }
    if let halloween = saved["halloween"] as? String,
      let value = AppThemePreferences.Halloween(rawValue: halloween)
    {
      preferences.halloween = value
    }
    if let christmas = saved["christmas"] as? String,
      let value = AppThemePreferences.Christmas(rawValue: christmas)
    {
      preferences.christmas = value
    }
    if let windowStyle = saved["windowStyle"] as? String,
      let value = AppThemePreferences.WindowStyle(rawValue: windowStyle)
    {
      preferences.windowStyle = value
    }
    if let raw = saved["glassTransparency"] as? String,
      let value = AppThemePreferences.parseGlassTransparency(raw)
    {
      preferences.glassTransparency = value
    } else if let number = saved["glassTransparency"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue == Double(number.intValue),
      AppThemePreferences.validGlassTransparency(number.intValue)
    {
      preferences.glassTransparency = number.intValue
    }
    self.preferences = preferences
    season = preferences.season(on: now(), calendar: calendar)
    // Posted when the calendar day changes, and on waking when it changed during sleep.
    dayChange = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshSeason() } }
  }

  /// The asset catalog image set the Dock shows: the season's while one is on, else the choice.
  var dockIconName: String { season?.dockImageName ?? preferences.icon.imageName }

  /// Reads the season again for today; the store does it itself when the day changes.
  func refreshSeason() {
    let current = preferences.season(on: now(), calendar: calendar)
    if current != season { season = current }
  }

  func setMode(_ mode: AppThemePreferences.Mode) { update { $0.mode = mode } }

  /// `hex` is `#rrggbb`; any other form is refused, as a control never offers one.
  func setAccent(_ hex: String) throws {
    guard AppThemePreferences.validAccent(hex) else { throw InvalidControlValue() }
    update { $0.accent = hex.lowercased() }
  }

  func setTone(_ tone: AppThemePreferences.Tone) { update { $0.tone = tone } }

  func setIcon(_ icon: AppThemePreferences.Icon) { update { $0.icon = icon } }

  func setHalloween(_ halloween: AppThemePreferences.Halloween) {
    update {
      $0.halloween = halloween
      if halloween == .always, $0.christmas == .always { $0.christmas = .automatic }
    }
  }

  func setChristmas(_ christmas: AppThemePreferences.Christmas) {
    update {
      $0.christmas = christmas
      if christmas == .always, $0.halloween == .always { $0.halloween = .automatic }
    }
  }

  func setWindowStyle(_ windowStyle: AppThemePreferences.WindowStyle) {
    update { $0.windowStyle = windowStyle }
  }

  /// Updates the published transparency during a slider drag without writing defaults on every step.
  func previewGlassTransparency(_ percent: Int) {
    guard AppThemePreferences.validGlassTransparency(percent) else { return }
    guard preferences.glassTransparency != percent else { return }
    var next = preferences
    next.glassTransparency = percent
    preferences = next
  }

  /// Saves the Liquid Glass transparency percentage (`0...100`); any value outside the range is refused.
  func setGlassTransparency(_ percent: Int) throws {
    guard AppThemePreferences.validGlassTransparency(percent) else { throw InvalidControlValue() }
    update(persistEvenIfUnchanged: true) { $0.glassTransparency = percent }
  }

  /// Saves `change` and publishes it, unless it changes nothing.
  private func update(
    persistEvenIfUnchanged: Bool = false, _ change: (inout AppThemePreferences) -> Void
  ) {
    var next = preferences
    change(&next)
    guard persistEvenIfUnchanged || next != preferences else { return }
    defaults.set(next.snapshot, forKey: Self.defaultsKey)
    if next != preferences { preferences = next }
    refreshSeason()
  }

  func reset() {
    defaults.removeObject(forKey: Self.defaultsKey)
    preferences = AppThemePreferences()
    refreshSeason()
  }
}
