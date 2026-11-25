import Foundation
import Observation

/// Settings: the sections, the search, the rows and how they edit.
///
/// The navigation and search state of the Settings pages lives here: which section is on show, what
/// the search field says, which disclosures are open. The values the rows edit come from the
/// controller and its typed settings actions. It reads and acts through `controller`, which owns
/// every store.
///
/// Editing follows one model for every control (the web page's `drafts` and `pending`): a control
/// shows the value it just sent (its *draft*) until the change has run, then the value the stores
/// report, so a refused change snaps back. A change runs through `controller.launch`, one at a time
/// per setting, and its failure reaches the panel's error banner, which is the one place errors
/// show. While a wallpaper is changing or another change is running the other controls wait.
@MainActor
@Observable
final class SettingsModel {
  unowned let controller: PanelController

  // MARK: Navigation and search

  /// The section on show. A window starts on Quick Settings.
  private(set) var selectedSection = SettingsSection.quick
  /// When non-nil during an active search, scopes the search results to this matching section
  /// without discarding `query`.
  private(set) var searchSection: SettingsSection?
  /// Counts the times a section was chosen or revealed, so the page scrolls back to its top even
  /// when the choice is the section already on show.
  private(set) var scrollEpoch = 0
  /// What the search field says, as typed.
  var query = "" {
    didSet {
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        searchSection = nil
      } else if let scoped = searchSection, !search.shows(scoped) {
        searchSection = nil
      }
    }
  }
  /// The disclosures the person opened. A search opens more for as long as it lasts.
  private(set) var openDisclosures = Set<String>()
  @ObservationIgnored private var cachedSearch:
    (query: String, tag: String, unoffered: Set<String>, live: [SettingsLiveUnit], search: SettingsSearch)?
  @ObservationIgnored private var indexes: [String: SettingsIndex] = [:]
  /// Where search phrases are read in, the panel's language.
  @ObservationIgnored var locale: PanelLocale = .shared

  // MARK: Editing

  /// A value a control has sent that the stores have not confirmed yet.
  struct Draft {
    let value: AnyHashable
    /// Tells this change from a newer one of the same setting, so an older one finishing does not
    /// take the newer one's value away.
    let token: UInt64
  }

  /// What each control shows until its change has run, by setting key. A Quick Settings tile and
  /// the full row of the same setting share a key, so they follow each other at once.
  private(set) var drafts: [String: Draft] = [:]
  @ObservationIgnored private var nextDraftToken: UInt64 = 0

  /// The icons of the apps the App rules name.
  let appIcons: AppIconCache

  init(controller: PanelController) {
    self.controller = controller
    appIcons = AppIconCache()
  }

  /// What the query keeps. Cached for the query, the language, the rows this Mac draws now and
  /// the live rows, because every row of the page asks.
  ///
  /// Only the rows the pages draw now are searched (`SettingsIndex.offering`). While a query is
  /// typed, reading this reads the facts that decide which those are
  /// (`SettingsRegistry.unofferedItems`), so the results follow a battery appearing or a choice that
  /// adds rows. Without a query it reads nothing more: every row is drawn by its own rule.
  var search: SettingsSearch {
    let tag = locale.tag
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let unoffered = trimmed.isEmpty ? [] : SettingsRegistry.unofferedItems(controller)
    // The rows built from live data (displays, layouts, saved playlists, app rules, desktop
    // widgets) are read only while a query is typed.
    let live = trimmed.isEmpty ? [] : liveSearchUnits
    if let cachedSearch, cachedSearch.query == trimmed, cachedSearch.tag == tag,
      cachedSearch.unoffered == unoffered, cachedSearch.live == live
    {
      return cachedSearch.search
    }
    let index = indexes[tag] ?? SettingsIndex(locale: locale)
    indexes[tag] = index
    let search = SettingsSearch(
      query: trimmed, index: unoffered.isEmpty ? index : index.offering { !unoffered.contains($0.id) },
      live: live)
    cachedSearch = (trimmed, tag, unoffered, live, search)
    return search
  }

  /// Live-data rows across Settings sections: Displays (cards, listed wallpapers, saved layouts,
  /// saved playlists), Playback & Power (App rules), and Desktop Widgets.
  var liveSearchUnits: [SettingsLiveUnit] {
    _ = controller.revisions.playback
    var units = controller.displaysSettings.searchUnits
    for rule in controller.playback.appRules {
      let text = PlaybackSettingsSection.appRuleSearchText(rule)
      if !text.isEmpty {
        units.append(
          SettingsLiveUnit(
            section: .playback, group: PlaybackSettingsSection.playback,
            disclosure: PlaybackSettingsSection.appRules, text: text))
      }
    }
    for widget in controller.desktopWidgets.widgets {
      let text = Self.widgetSearchText(widget, controller: controller)
      if !text.isEmpty {
        units.append(SettingsLiveUnit(section: .widgets, text: text))
      }
    }
    return units
  }

  /// Display title of a desktop widget for Settings search results.
  static func widgetDisplayName(_ widget: DesktopWidget, controller: PanelController) -> String {
    let custom = widget.text
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !custom.isEmpty { return custom }
    return WidgetsSettingsSection.title(of: widget.kind)
  }

  /// Searchable phrases for a live desktop widget: its custom label/text, kind name, city/time
  /// zone when set, and pinned display name when placed on a specific display.
  static func widgetSearchText(_ widget: DesktopWidget, controller: PanelController) -> String {
    var parts = [WidgetsSettingsSection.title(of: widget.kind)]
    let custom = widget.text
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !custom.isEmpty { parts.append(custom) }
    if let zone = widget.timeZone, !zone.isEmpty {
      parts.append(controller.widgetsSettings.city(zone))
      parts.append(zone)
    }
    if case .display(_, let name) = widget.placement, !name.isEmpty {
      parts.append(name)
    }
    return parts.joined(separator: "\n")
  }

  /// A phrase of a row or section in the panel's language.
  func text(_ resource: LocalizedStringResource) -> String { locale.string(resolving: resource) }

  /// Shows a section in full: clears any search and starts the page at its top.
  func select(_ section: SettingsSection) {
    query = ""
    searchSection = nil
    selectedSection = section
    scrollEpoch += 1
  }

  /// Handles clicking a section in `SettingsSectionList`: while searching, scopes results to a
  /// matching section without discarding the query; clicking a section with no matches clears
  /// search and opens that section directly.
  func chooseFromList(_ section: SettingsSection) {
    guard search.isActive else {
      select(section)
      return
    }
    if search.shows(section) {
      searchSection = section
      scrollEpoch += 1
    } else {
      select(section)
    }
  }

  /// Returns from a single-section search scope to all matching sections, keeping `query`.
  func clearSearchScope() {
    guard searchSection != nil else { return }
    searchSection = nil
    scrollEpoch += 1
  }

  /// Clears the search query and shows `section` (or the currently scoped/selected section).
  func exitSearch(to section: SettingsSection? = nil) {
    select(section ?? searchSection ?? selectedSection)
  }

  /// Shows the section the app asked to reveal, once. A reveal made before the window existed is
  /// picked up as the window opens; one a window already acted on is not repeated by the next
  /// window, which starts on Quick Settings.
  func adoptReveal() {
    let navigation = controller.navigation
    guard navigation.settingsSectionToken != navigation.handledSettingsRevealToken else { return }
    navigation.handledSettingsRevealToken = navigation.settingsSectionToken
    select(navigation.settingsSection)
  }

  func isOpen(_ disclosure: SettingsItem) -> Bool {
    openDisclosures.contains(disclosure.id) || search.opens(disclosure)
  }

  func setOpen(_ isOpen: Bool, for disclosure: SettingsItem) {
    if isOpen {
      openDisclosures.insert(disclosure.id)
    } else {
      openDisclosures.remove(disclosure.id)
    }
  }

  // MARK: Editing

  /// The key a setting's change is tracked under, for `controller.isBusy`.
  static func actionKey(_ setting: String) -> String {
    PanelActionCoordinator.key("setting", detail: setting)
  }

  /// The value to show for a setting: what its control just sent while that change is on its way,
  /// otherwise `saved`.
  func value<Value: Hashable>(_ key: String, saved: Value) -> Value {
    (drafts[key]?.value.base as? Value) ?? saved
  }

  /// No settings snapshot has arrived yet, so the renderer-backed controls have nothing true to
  /// show. Appearance and language live in the app and stay usable.
  var isUnavailable: Bool { controller.store.snapshotRevision == 0 }

  /// Whether a control that changes the renderer or a store has to wait.
  ///
  /// It waits while there is no snapshot, and while a wallpaper is changing or another change is
  /// running, so a second change is never submitted behind the first. The control whose own change
  /// is the one running stays enabled (its repeat is dropped), so a keyboard user's focus is not
  /// taken away by pressing it. `whileRunning` disables the control for its own change too, for a
  /// button that must not be pressed twice, such as Retry.
  func isLocked(_ key: String? = nil, whileRunning: Bool = false) -> Bool {
    if isUnavailable { return true }
    let own = key.map { controller.isBusy(Self.actionKey($0)) } ?? false
    if own { return whileRunning }
    return controller.isStoreBusy
  }

  /// Sends `value` for the setting `key`: the control shows it at once, `perform` runs queued, and the
  /// control shows what the stores say once it has (so a refusal puts the old value back).
  ///
  /// With `.dropDuplicates` a change that arrives while the setting's own is still running is
  /// ignored and nil is returned: one at a time, as the web page did. A slider or a field sends
  /// every value it settles on with `.latestWins` so the newest lands last.
  @discardableResult
  func commit<Value: Hashable>(
    _ key: String, to value: Value,
    policy: PanelActionCoordinator.Policy = .dropDuplicates,
    perform: @escaping @MainActor (Value) async throws -> Void
  ) -> Task<Void, Never>? {
    let actionKey = Self.actionKey(key)
    if policy == .dropDuplicates, controller.isBusy(actionKey) { return nil }
    nextDraftToken &+= 1
    let token = nextDraftToken
    drafts[key] = Draft(value: AnyHashable(value), token: token)
    return controller.launch(actionKey, policy: policy) { [weak self] in
      defer { self?.settle(key, token: token) }
      try await perform(value)
    }
  }

  /// Starts what a button of a Settings row does (Retry, Open Login Items, Add app), tracked under
  /// `name` so the button can disable itself with `isLocked(name, whileRunning: true)` and a second
  /// press is dropped.
  @discardableResult
  func perform(
    _ name: String, operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Never> {
    controller.launch(Self.actionKey(name), operation: operation)
  }

  /// Applies an appearance choice, which the app does at once: `change` runs now, and a value the
  /// store refuses (a control never offers one) goes to the error banner. Appearance has no draft
  /// and never waits for the Mac, so it stays usable whatever the renderer is doing.
  func applyTheme(_ change: () throws -> Void) {
    do {
      try change()
    } catch {
      controller.errors.report(error)
    }
  }

  private func settle(_ key: String, token: UInt64) {
    if drafts[key]?.token == token { drafts[key] = nil }
  }
}
