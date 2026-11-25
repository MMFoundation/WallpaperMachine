import Foundation

/// The two looks Follow system appearance chooses a wallpaper for.
enum AutomationAppearance: Sendable {
  case light, dark
}

extension PanelController {
  // MARK: Derived state

  /// `display`'s automatic selection: the saved rules and the state beside them. A display the
  /// renderer does not list reads as one nobody configured, with no desktops.
  func automationState(for display: String) -> AutomationState {
    _ = revisions.automationSettings
    _ = revisions.automationStatus
    _ = revisions.spaces
    let configuration = automations.configuration(for: display)
    let row = store.settingsSnapshot.displays.first { $0.displayId == display }
    let desktops = row.flatMap { spaces.physicalDisplay(display, title: $0.title) }.flatMap { spaces.displays[$0] }
    let blocked = isSpaceSelectionBlocked
    return AutomationState(
      mode: configuration.mode, usesSpaces: configuration.usesSpaces, ruleMode: configuration.ruleMode,
      light: configuration.light, dark: configuration.dark,
      batteryTarget: configuration.batteryTarget, globalBatteryTarget: automations.globalBatteryTarget,
      rules: configuration.rules, next: automations.next[display]?.date,
      nextTarget: automations.next[display]?.target,
      isFocused: automations.focusedDisplays.contains(display),
      activeOverride: automations.activeOverrides[display],
      error: automations.errors[display],
      spacesAvailable: spaces.available && desktops != nil && !blocked, spacesBlocked: blocked,
      desktops: (desktops?.spaces ?? []).enumerated().map { index, desktop in
        AutomationState.Desktop(
          id: desktop.id, number: desktop.number, target: configuration.spaces[desktop.id],
          firstDesktopTarget: index == 0 ? nil : desktops?.spaces.first.flatMap { configuration.spaces[$0.id] })
      },
      currentDesktop: desktops?.current,
      missingDesktops: desktops.map { info in
        configuration.spaces.keys.filter { id in !info.spaces.contains { $0.id == id } }.sorted().compactMap { id in
          configuration.spaces[id].map { AutomationState.MissingDesktop(id: id, target: $0) }
        }
      } ?? [])
  }

  /// Optional wallpaper or saved playlist applied across all displays while on battery power.
  var globalBatteryTarget: WallpaperAutomationTarget? {
    _ = revisions.automationSettings
    return automations.globalBatteryTarget
  }

  /// The coordinates the sunrise and sunset rules use; nil until the user saves them.
  var solarLocation: WallpaperSolarLocation? {
    _ = revisions.automationSettings
    return automations.location
  }

  /// Where the sun rules take their times from, and the fixed times when that is the source.
  var solarSettings: WallpaperSolarSettings {
    _ = revisions.automationSettings
    return automations.solar
  }

  /// Why the saved automatic rules could not all be read, when they could not.
  var automationLoadError: String? {
    _ = revisions.automationSettings
    return automations.loadError
  }

  /// What a rule, an appearance or a desktop can switch to: the wallpapers that can play, in library
  /// order, and the saved playlists, in the order they were saved.
  var automationTargets: AutomationTargets {
    _ = revisions.playlists
    return AutomationTargets(
      wallpapers: store.librarySnapshot.wallpapers.filter(\.supported).map {
        .init(target: WallpaperAutomationTarget(kind: .wallpaper, id: $0.id), title: $0.title)
      },
      playlists: playlists.plans.map {
        .init(target: WallpaperAutomationTarget(kind: .playlist, id: $0.id), title: $0.name)
      })
  }

  // MARK: Actions

  /// `automationMode`. Different wallpaper for each desktop needs Space information for the display
  /// and no animated lock screen. Choosing schedule or appearance preserves `spacesEnabled` so
  /// Spaces can stack with time schedules and appearance rules.
  func setAutomationMode(_ mode: DisplayWallpaperAutomation.Mode, display: String? = nil) async throws {
    if mode == .spaces {
      try await run(.immediate) {
        let display = try standaloneDisplayID(display)
        let info = try requireSpaceInformation(display)
        let shown = store.shownWallpaperID(on: display).flatMap { id in
          store.librarySnapshot.wallpapers.contains { $0.id == id && $0.supported } ? id : nil
        }
        try automations.update(display) { configuration in
          let wasSpaces = configuration.usesSpaces
          configuration.mode = .spaces
          configuration.spacesEnabled = true
          guard !wasSpaces, let shown else { return }
          for desktop in [info.current, info.spaces.first?.id].compactMap({ $0 })
          where configuration.spaces[desktop] == nil {
            configuration.spaces[desktop] = WallpaperAutomationTarget(kind: .wallpaper, id: shown)
          }
        }
      }
      return
    }
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      try automations.update(display) { configuration in
        if mode == .off {
          configuration.mode = .off
          configuration.spacesEnabled = false
        } else {
          if configuration.mode == .spaces { configuration.spacesEnabled = true }
          configuration.mode = mode
        }
      }
    }
  }

  /// `automationRuleMode`: changes the schedule or appearance rule without toggling per-desktop
  /// Space choices, allowing Spaces to stack with Time schedule or Follow system appearance.
  func setAutomationRuleMode(
    _ ruleMode: DisplayWallpaperAutomation.RuleMode, display: String? = nil
  ) async throws {
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      try automations.update(display) { configuration in
        let keepSpaces = configuration.usesSpaces
        configuration.spacesEnabled = keepSpaces
        switch ruleMode {
        case .off: configuration.mode = keepSpaces ? .spaces : .off
        case .schedule: configuration.mode = .schedule
        case .appearance: configuration.mode = .appearance
        }
      }
    }
  }

  /// `desktopWallpapers`: whether the display keeps a wallpaper of its own for each desktop.
  /// Stacks cleanly with an active time schedule or appearance rule (unpinned desktops continue
  /// following the rule); when no rule is active, turning it on keeps the current wallpaper for
  /// the current desktop and Desktop 1. Turning it off preserves any stacked schedule/appearance.
  func setDesktopWallpapers(_ on: Bool, display: String? = nil) async throws {
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      guard on else {
        try automations.update(display) { configuration in
          configuration.spacesEnabled = false
          if configuration.mode == .spaces { configuration.mode = .off }
        }
        return
      }
      let info = try requireSpaceInformation(display)
      let shown = store.shownWallpaperID(on: display).flatMap { id in
        store.librarySnapshot.wallpapers.contains { $0.id == id && $0.supported } ? id : nil
      }
      try automations.update(display) { configuration in
        configuration.spacesEnabled = true
        guard configuration.mode == .off else { return }
        configuration.mode = .spaces
        guard let shown else { return }
        for desktop in [info.current, info.spaces.first?.id].compactMap({ $0 })
        where configuration.spaces[desktop] == nil {
          configuration.spaces[desktop] = WallpaperAutomationTarget(kind: .wallpaper, id: shown)
        }
      }
    }
  }

  /// `automationBattery`: optional per-display wallpaper or saved playlist override while running
  /// on battery power; nil falls back to the all-displays battery override (if any).
  func setAutomationBatteryTarget(
    _ target: WallpaperAutomationTarget?, display: String? = nil
  ) async throws {
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      let target = try target.map(validated)
      try automations.update(display) { $0.batteryTarget = target }
    }
  }

  /// `automationBatteryGlobal`: optional wallpaper or saved playlist override applied across all
  /// enabled independent displays while running on battery power (unless a display overrides it).
  func setGlobalBatteryTarget(_ target: WallpaperAutomationTarget?) async throws {
    try await run(.immediate) {
      let target = try target.map(validated)
      try automations.setGlobalBatteryTarget(target)
    }
  }

  /// `appRuleWallpaperTarget`: sets or clears the wallpaper/playlist target of an app rule.
  func updateAppRule(_ id: UUID, wallpaperTarget: WallpaperAutomationTarget?) async throws {
    try await run(.queued) {
      let target = try wallpaperTarget.map(validated)
      try playback.updateRule(id: id, wallpaperTarget: target)
    }
  }

  /// `appRuleDisplay`: sets the target display of a wallpaper-switching app rule; nil means all
  /// enabled independent displays.
  func updateAppRule(_ id: UUID, displayID: String?) async throws {
    try await run(.queued) {
      let validatedDisplay: String?
      if let displayID {
        validatedDisplay = try standaloneDisplayID(displayID)
      } else {
        validatedDisplay = nil
      }
      try playback.updateRule(id: id, displayID: validatedDisplay)
    }
  }

  /// `automationSpace`: the wallpaper or playlist a desktop switches to, or with nil forgets the
  /// choice. A choice needs Space information and a desktop the display really has; forgetting needs
  /// a saved choice, which may be for a desktop that is gone.
  func setAutomationDesktop(
    _ desktop: String, to target: WallpaperAutomationTarget?, display: String? = nil
  ) async throws {
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      let target = try target.map(validated)
      if target != nil {
        guard try requireSpaceInformation(display).spaces.contains(where: { $0.id == desktop }) else {
          throw InvalidControlValue()
        }
      } else if automations.configuration(for: display).spaces[desktop] == nil {
        throw InvalidControlValue()
      }
      try automations.update(display) { $0.spaces[desktop] = target }
    }
  }

  /// `automationRefreshSpaces`: reads the desktops again.
  func refreshSpaces() async throws {
    try await run(.immediate) { spaces.refresh() }
  }

  /// `automationAppearance`: the wallpaper or playlist for the light or the dark look; nil leaves it
  /// as it is.
  func setAutomationAppearance(
    _ appearance: AutomationAppearance, to target: WallpaperAutomationTarget?, display: String? = nil
  ) async throws {
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      let target = try target.map(validated)
      try automations.update(display) {
        switch appearance {
        case .light: $0.light = target
        case .dark: $0.dark = target
        }
      }
    }
  }

  /// `automationRuleSave`: adds the rule, or replaces the saved rule it names. The target must be a
  /// wallpaper that can play or a saved playlist, the weekdays 1 to 7 and the offset within three
  /// hours; the store refuses a rule with no weekday, and a display keeps at most 64 rules.
  func saveAutomationRule(_ edit: AutomationRuleEdit, display: String? = nil) async throws {
    guard edit.weekdays.isSubset(of: AutomationRuleEdit.everyDay), (-180...180).contains(edit.offset) else {
      throw InvalidControlValue()
    }
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      var rule = WallpaperAutomationRule(
        weekdays: edit.weekdays, event: edit.event, minute: edit.minute, offset: edit.offset,
        target: try validated(edit.target), isEnabled: edit.isEnabled)
      if let id = edit.id, !id.isEmpty {
        guard automations.configuration(for: display).rules.contains(where: { $0.id == id }) else {
          throw InvalidControlValue()
        }
        rule.id = id
      }
      try automations.saveRule(rule, on: display)
    }
  }

  /// `automationRuleRemove`.
  func removeAutomationRule(_ id: String, display: String? = nil) async throws {
    try await run(.immediate) {
      try automations.removeRule(id, from: try standaloneDisplayID(display))
    }
  }

  /// `automationRuleEnabled`: turns a saved time rule on or off without removing it.
  func setAutomationRuleEnabled(_ id: String, isEnabled: Bool, display: String? = nil) async throws {
    try await run(.immediate) {
      try automations.setRuleEnabled(id, isEnabled: isEnabled, on: try standaloneDisplayID(display))
    }
  }

  /// `automationRuleMove`: moves a saved time rule up (-1) or down (+1) to control precedence.
  func moveAutomationRule(_ id: String, by direction: Int, display: String? = nil) async throws {
    try await run(.immediate) {
      try automations.moveRule(id, by: direction, on: try standaloneDisplayID(display))
    }
  }

  /// `automationRuleReorder`: applies a full rule order after drag-and-drop.
  func reorderAutomationRules(
    _ ids: [String], expected: [String]? = nil, display: String? = nil
  ) async throws {
    try await run(.immediate) {
      try automations.reorderRules(ids, expected: expected, on: try standaloneDisplayID(display))
    }
  }

  /// `automationLocation`: the coordinates sunrise and sunset rules use, north and east positive. They
  /// are saved here and calculated locally; nothing is looked up.
  func setSolarLocation(latitude: Double, longitude: Double) async throws {
    guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw InvalidControlValue() }
    try await run(.immediate) {
      try automations.setLocation(WallpaperSolarLocation(latitude: latitude, longitude: longitude))
    }
  }

  /// `automationClearLocation`.
  func clearSolarLocation() async throws {
    try await run(.immediate) { try automations.setLocation(nil) }
  }

  /// `automationSolarSource`: a deliberate source choice may ask for location access. Restoring
  /// saved settings does not use this action and therefore never prompts.
  func setSolarSource(_ source: WallpaperSolarSource) async throws {
    var value = automations.solar
    value.source = source
    try await run(.immediate) {
      try automations.setSolar(value)
      if source == .automatic { solarLocationTracker.requestAuthorization() }
    }
  }

  /// `automationSolarLocate`: retries an undecided location request from the automatic source.
  func requestSolarLocation() async throws {
    try await run(.immediate) { solarLocationTracker.requestAuthorization() }
  }

  /// `automationSolarSettings`: opens the system pane after the user denied access.
  func showSolarLocationSettings() async throws {
    try await run(.immediate) { solarLocationTracker.openSettings() }
  }

  /// `automationSolarFixedTimes`: the clock times the fixed source switches at.
  func setSolarFixedTimes(sunriseMinute: Int, sunsetMinute: Int) async throws {
    guard (0..<1440).contains(sunriseMinute), (0..<1440).contains(sunsetMinute) else {
      throw InvalidControlValue()
    }
    var value = automations.solar
    value.fixedSunriseMinute = sunriseMinute
    value.fixedSunsetMinute = sunsetMinute
    try await run(.immediate) { try automations.setSolar(value) }
  }

  /// `automationRetry`: tries again the change that failed.
  func retryAutomation(display: String? = nil) async throws {
    try await run(.immediate) { automations.retry(try standaloneDisplayID(display)) }
  }

  // MARK: Helpers

  /// `target` itself when it can be chosen: a wallpaper that is installed and can play, or a saved
  /// playlist. A wallpaper that cannot be chosen is an invalid value, a missing plan says so.
  private func validated(_ target: WallpaperAutomationTarget) throws -> WallpaperAutomationTarget {
    switch target.kind {
    case .wallpaper:
      guard store.librarySnapshot.wallpapers.contains(where: { $0.id == target.id && $0.supported }) else {
        throw InvalidControlValue()
      }
    case .playlist:
      guard playlists.plan(id: target.id) != nil else { throw LibraryOrganizationError.missingPlan }
    }
    return target
  }

  /// The animated lock screen owns the desktop picture across Spaces, which Space choices conflict
  /// with in both directions.
  private var isSpaceSelectionBlocked: Bool {
    store.lockScreenWallpaper?.isRequested == true || store.lockScreenWallpaper?.ownsDesktopProvider == true
  }

  /// The desktops macOS reports for `display`, or the reason there are none to choose from.
  private func requireSpaceInformation(_ display: String) throws -> WallpaperDisplaySpaces {
    guard !isSpaceSelectionBlocked else {
      throw WallpaperActionError(
        message: L("Turn off animated lock-screen wallpaper before using Space-based wallpaper choices."))
    }
    guard let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
      let physical = spaces.physicalDisplay(display, title: row.title), spaces.available,
      let info = spaces.displays[physical]
    else {
      throw WallpaperActionError(
        message: L("Desktop Space information is unavailable. Refresh Spaces or choose another automatic mode."))
    }
    return info
  }
}
