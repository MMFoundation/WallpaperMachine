import SwiftUI

/// A display's Automatic wallpaper selection disclosure: off, a time schedule, the system
/// appearance or a wallpaper for each desktop chooses its wallpaper. A mirrored or disabled display shows it
/// but cannot change it.
struct DisplaysAutomationDisclosure: View {
  let display: DisplayRow
  let card: DisplaysCardSearch

  var body: some View {
    DisplaysDisclosure(
      item: DisplaysSettingsSection.automation, display: display.id, card: card
    ) {
      DisplaysAutomationRows(display: display, forced: card.forced)
    }
  }
}

/// The rows inside the disclosure. Built only while it is open, so a closed one reads nothing.
private struct DisplaysAutomationRows: View {
  let display: DisplayRow
  let forced: Bool

  @Environment(PanelController.self) private var controller
  @FocusState private var focus: DisplaysSettingsModel.AutomationFocus?

  var body: some View {
    let model = controller.displaysSettings
    let state = controller.automationState(for: display.id)
    let targets = controller.automationTargets
    let locked = controller.isStoreBusy || !display.enabled || display.isMirror
    let title = { (item: SettingsItem) in
      L("\(controller.settings.text(item.title)) for \(display.title)")
    }
    Group {
      DisplaysRow(
        item: DisplaysSettingsSection.automationMode, note: modeNote(state), forced: forced,
        identity: display.id, controlLabel: L("Automatic changes for \(display.title)")
      ) {
        let ruleMode = model.binding(
          PanelActionCoordinator.key("automationMode", id: display.id), current: state.ruleMode
        ) { mode in try await controller.setAutomationRuleMode(mode, display: display.id) }
        DisplaysTitleMenu(
          selection: ruleMode,
          title: {
            switch ruleMode.wrappedValue {
            case .off: L("Off")
            case .schedule: L("Time schedule")
            case .appearance: L("Follow system appearance")
            }
          }(), width: 210
        ) {
          Text("Off").tag(DisplayWallpaperAutomation.RuleMode.off)
          Text("Time schedule").tag(DisplayWallpaperAutomation.RuleMode.schedule)
          Text("Follow system appearance").tag(DisplayWallpaperAutomation.RuleMode.appearance)
        }
        .focused($focus, equals: .modePicker(display: display.id))
        .disabled(locked)
      }

      switch state.ruleMode {
      case .off:
        if state.usesSpaces {
          DisplaysNote(
            text: L(
              "Each desktop’s wallpaper is chosen above, under Different wallpaper for each desktop. You can also add a time schedule or system appearance rule for desktops without a choice."
            ))
        }
      case .appearance:
        if state.usesSpaces {
          DisplaysNote(
            text: L(
              "Desktops with a chosen wallpaper keep it; desktops without a choice follow system appearance."
            ))
        }
        DisplaysRow(
          item: DisplaysSettingsSection.automationLight, forced: forced, identity: display.id,
          controlLabel: title(DisplaysSettingsSection.automationLight)
        ) {
          DisplaysTargetPicker(
            selection: state.light, targets: targets, isRequired: false,
            popoverTitle: L("In light appearance"),
            key: PanelActionCoordinator.key("automationAppearance", id: display.id, detail: "light"),
            commit: { try await controller.setAutomationAppearance(.light, to: $0, display: display.id) }
          )
          .disabled(locked)
        }
        DisplaysRow(
          item: DisplaysSettingsSection.automationDark, forced: forced, identity: display.id,
          controlLabel: title(DisplaysSettingsSection.automationDark)
        ) {
          DisplaysTargetPicker(
            selection: state.dark, targets: targets, isRequired: false,
            popoverTitle: L("In dark appearance"),
            key: PanelActionCoordinator.key("automationAppearance", id: display.id, detail: "dark"),
            commit: { try await controller.setAutomationAppearance(.dark, to: $0, display: display.id) }
          )
          .disabled(locked)
        }
      case .schedule:
        if state.usesSpaces {
          DisplaysNote(
            text: L(
              "Desktops with a chosen wallpaper keep it; desktops without a choice follow this time schedule."
            ))
        }
        DisplaysScheduleRows(
          display: display, state: state, targets: targets, locked: locked, forced: forced,
          focus: $focus)
      }

      DisplaysRow(
        item: DisplaysSettingsSection.automationBattery, note: batteryNote(state), forced: forced,
        identity: display.id, controlLabel: title(DisplaysSettingsSection.automationBattery)
      ) {
        DisplaysTargetPicker(
          selection: state.batteryTarget, targets: targets, isRequired: false,
          popoverTitle: L("On battery"),
          emptyTitle: state.globalBatteryTarget != nil ? L("Follow all-displays setting") : nil,
          key: PanelActionCoordinator.key("automationBattery", id: display.id),
          commit: { try await controller.setAutomationBatteryTarget($0, display: display.id) }
        )
        .disabled(locked)
      }

      DisplaysAutomationFooter(display: display, state: state, locked: locked, forced: forced)
    }
    .onChange(of: model.automationFocus, initial: true) { _, target in
      switch target {
      case nil, .desktopsToggle, .forget:
        // The desktop rows take their own focus.
        break
      case let target?:
        focus = target
        model.consumeAutomationFocus()
      }
    }
  }

  /// "Manual choices stay until the next rule changes them." and, when a wallpaper for each desktop
  /// cannot be chosen, why.
  private func modeNote(_ state: AutomationState) -> String {
    let base = L("Manual choices stay until the next rule changes them.")
    guard !state.usesSpaces, let reason = state.spacesUnavailableReason else { return base }
    switch reason {
    case .lockScreenOwnsDesktop:
      return "\(base) \(L("Turn off animated lock-screen wallpaper to use desktop Space choices."))"
    case .noInformation:
      return
        "\(base) \(L("Desktop information is unavailable. Refresh Spaces or choose another automatic mode."))"
    }
  }

  private func batteryNote(_ state: AutomationState) -> String {
    if state.batteryTarget == nil, state.globalBatteryTarget != nil {
      return L(
        "Temporarily overrides this display’s wallpaper while on battery and restores it on power. Currently follows the all-displays battery wallpaper."
      )
    }
    return L(
      "Temporarily overrides this display’s wallpaper while on battery and restores it on power. Overrides the all-displays battery wallpaper."
    )
  }
}

// MARK: - Choosing a wallpaper or a saved playlist

/// A searchable thumbnail chooser of what an automatic choice can switch to: the wallpapers that
/// can play, then the saved playlists. A saved choice that no longer resolves stays displayed as
/// "Unavailable" without being overwritten until the user explicitly chooses another target.
struct DisplaysTargetPicker: View {
  let selection: WallpaperAutomationTarget?
  let targets: AutomationTargets
  /// A required choice has no "Leave as it is" entry and asks for a choice instead.
  let isRequired: Bool
  var popoverTitle: String? = nil
  var emptyTitle: String? = nil
  var clearTitle: String? = nil
  let key: String
  let commit: @MainActor (WallpaperAutomationTarget?) async throws -> Void
  /// Called with the chosen target instead of acting on it, for the editor's draft.
  var onSelect: ((WallpaperAutomationTarget?) -> Void)?
  /// How wide the trigger button is: its entries are the user's own titles and may be long.
  var width: CGFloat = 200
  /// Where the button sits in its width: at the trailing edge of a row, the leading edge of a
  /// form's column.
  var alignment = Alignment.trailing

  @Environment(PanelController.self) private var controller

  var body: some View {
    let activeID = controller.displaysSettings.drafts[key] as? String ?? Self.identifier(selection)
    let activeTarget = Self.target(activeID, in: targets, keeping: selection)
    let isUnavailable = !activeID.isEmpty && (activeTarget.map { targets.title(of: $0) == nil } ?? true)
    let clearLabel = clearTitle ?? emptyTitle ?? L("Leave as it is")
    let clearOption: WallpaperThumbnailChooser.ClearOption? =
      isRequired
      ? nil
      : .init(
        title: clearLabel, isSelected: activeID.isEmpty, isDisabled: activeID.isEmpty,
        action: { choose(nil) })
    WallpaperChooserTrigger(
      title: title(for: activeID),
      popoverTitle: popoverTitle ?? L("Choose a wallpaper or saved playlist"),
      wallpapers: targets.wallpapers,
      playlists: targets.playlists,
      selected: activeTarget,
      unavailableNote: isUnavailable ? L("The saved choice is no longer available.") : nil,
      clearOption: clearOption,
      width: width,
      alignment: alignment,
      onSelect: { choose($0) })
  }

  private func choose(_ target: WallpaperAutomationTarget?) {
    if let onSelect {
      onSelect(target)
    } else {
      controller.displaysSettings.setDraft(key, to: Self.identifier(target))
      controller.launch(key) {
        defer { controller.displaysSettings.setDraft(key, to: nil) }
        try await commit(target)
      }
    }
  }

  /// The title of the choice shown: what it is, "Unavailable" when it no longer resolves, or what
  /// asks for a choice.
  private func title(for identifier: String) -> String {
    if identifier.isEmpty {
      return isRequired ? L("Choose a wallpaper or saved playlist") : (emptyTitle ?? L("Leave as it is"))
    }
    if let found = (targets.wallpapers + targets.playlists).first(where: { $0.id == identifier }) { return found.title }
    return L("Unavailable")
  }

  /// The kind and the id as one tag; "" for no choice.
  static func identifier(_ target: WallpaperAutomationTarget?) -> String {
    target.map { "\($0.kind.rawValue):\($0.id)" } ?? ""
  }

  /// The target a tag stands for. A saved choice that no longer resolves keeps its own target.
  static func target(
    _ identifier: String, in targets: AutomationTargets, keeping saved: WallpaperAutomationTarget?
  ) -> WallpaperAutomationTarget? {
    guard !identifier.isEmpty else { return nil }
    if let saved, Self.identifier(saved) == identifier { return saved }
    return (targets.wallpapers + targets.playlists).first { $0.id == identifier }?.target
  }
}

// MARK: - Time schedule

/// Private drag payload for reordering a display's time rules.
struct AutomationRuleDrag: Codable, Transferable {
  let display: String
  let id: String
  let expected: [String]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .data, encoder: JSONEncoder(), decoder: JSONDecoder())
  }
}

private struct DisplaysScheduleRows: View {
  let display: DisplayRow
  let state: AutomationState
  let targets: AutomationTargets
  let locked: Bool
  let forced: Bool
  var focus: FocusState<DisplaysSettingsModel.AutomationFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  /// The rule whose Remove was clicked and waits for its answer.
  @State private var removalArmed: String?

  /// A display keeps at most this many rules.
  private static let ruleLimit = 64

  var body: some View {
    let model = controller.displaysSettings
    let editing = model.ruleEditing.flatMap { $0.display == display.id ? $0.draft : nil }
    let order = state.rules.map(\.id)
    Group {
      if state.rules.isEmpty && editing == nil {
        DisplaysNote(text: L("No time rules yet. Add one to choose when this display changes."))
      }
      ForEach(Array(state.rules.enumerated()), id: \.element.id) { index, rule in
        if let editing, editing.id == rule.id {
          DisplaysRuleEditor(display: display, targets: targets, focus: focus)
        } else {
          DisplaysScheduleRuleRow(
            display: display, rule: rule, index: index, count: state.rules.count, order: order,
            targets: targets, locked: locked, removalArmed: $removalArmed, focus: focus)
        }
      }
      if let editing, editing.id == nil {
        DisplaysRuleEditor(display: display, targets: targets, focus: focus)
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Button("Add time rule") { model.beginRule(display: display.id) }
            .focused(focus, equals: .addRule(display: display.id))
            .disabled(locked || state.rules.count >= Self.ruleLimit || editing != nil)
          Spacer(minLength: 0)
          if let next = state.next {
            Text(verbatim: nextLine(next))
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
              .lineLimit(1)
          }
        }
        DisplaysCaption(item: DisplaysSettingsSection.automationSchedule, forced: forced)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .announcesChanges(of: model.ruleAnnouncement)
  }

  /// "Next: Evening at Fri 18:30".
  private func nextLine(_ date: Date) -> String {
    let locale = PanelLocale.shared.locale
    let time = date.formatted(
      Date.FormatStyle(locale: locale).weekday(.abbreviated).hour(.twoDigits(amPM: .abbreviated))
        .minute(.twoDigits))
    let name = state.nextTarget.flatMap { targets.title(of: $0) } ?? L("Unavailable")
    return L("Next: \(name) at \(time)")
  }
}

/// One scheduled time rule: its enable switch, target title, schedule summary, and controls to
/// reorder, edit or remove it. Dragging a row onto another reorders rules in place.
private struct DisplaysScheduleRuleRow: View {
  let display: DisplayRow
  let rule: WallpaperAutomationRule
  let index: Int
  let count: Int
  let order: [String]
  let targets: AutomationTargets
  let locked: Bool
  @Binding var removalArmed: String?
  var focus: FocusState<DisplaysSettingsModel.AutomationFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isTargeted = false

  var body: some View {
    let model = controller.displaysSettings
    let targetTitle = targets.title(of: rule.target) ?? L("Unavailable")
    let canDrag = !locked && count > 1 && removalArmed != rule.id
    DisplaysRowLayout {
      HStack(spacing: 8) {
        Toggle(
          noLabel,
          isOn: model.binding(
            PanelActionCoordinator.key("automationRuleEnabled", id: display.id, detail: rule.id),
            current: rule.isEnabled
          ) { enabled in
            try await controller.setAutomationRuleEnabled(rule.id, isEnabled: enabled, display: display.id)
          }
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(locked)
        .accessibilityLabel(Text(verbatim: L("Enable rule for \(targetTitle)")))
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: targetTitle)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Text(verbatim: DisplaysRuleSummary.text(of: rule))
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(2)
        }
        .panelDisabledOpacity(rule.isEnabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 6) {
        if removalArmed == rule.id {
          // A rule is removed for good, so it asks first, in the row, as deleting a layout or a
          // saved playlist does.
          Text("Remove this rule?")
            .font(.system(size: 12))
          Button("Cancel") { removalArmed = nil }
          Button("Remove") {
            removalArmed = nil
            controller.launch(
              PanelActionCoordinator.key("automationRuleRemove", id: display.id, detail: rule.id)
            ) { try await model.removeRule(rule.id, display: display.id) }
          }
          .foregroundStyle(theme.surface.danger.color)
          .disabled(locked)
        } else {
          if count > 1 {
            moveButton(
              "chevron.up", help: L("Move up"), label: L("Move \(targetTitle) up"),
              targetFocus: .moveRuleUp(display: display.id, id: rule.id), disabled: locked || index == 0
            ) { move(-1) }
            moveButton(
              "chevron.down", help: L("Move down"), label: L("Move \(targetTitle) down"),
              targetFocus: .moveRuleDown(display: display.id, id: rule.id), disabled: locked || index == count - 1
            ) { move(1) }
          }
          Button("Edit…") { model.beginRule(display: display.id, editing: rule) }
            .focused(focus, equals: .editRule(display: display.id, id: rule.id))
            .disabled(locked)
          Button("Remove") { removalArmed = rule.id }
            .disabled(locked)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(isTargeted ? theme.accent.accent.color.opacity(0.14) : Color.clear)
    .contentShape(Rectangle())
    .modifier(
      DisplaysRuleDragging(
        isEnabled: canDrag, drag: AutomationRuleDrag(display: display.id, id: rule.id, expected: order))
    )
    .dropDestination(for: AutomationRuleDrag.self) { drops, _ in
      guard canDrag, let drop = drops.first, drop.display == display.id, drop.id != rule.id else {
        return false
      }
      controller.launch(PanelActionCoordinator.key("automationRuleReorder", id: display.id)) {
        try await model.dropRule(drop.id, onto: rule.id, expected: drop.expected, display: display.id)
      }
      return true
    } isTargeted: { isTargeted = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.automation-rule.\(display.id).\(rule.id)")
  }

  private func move(_ direction: Int) {
    controller.launch(PanelActionCoordinator.key("automationRuleReorder", id: display.id)) {
      try await controller.displaysSettings.moveRule(rule.id, by: direction, display: display.id)
    }
  }

  private func moveButton(
    _ symbol: String, help: String, label: String,
    targetFocus: DisplaysSettingsModel.AutomationFocus, disabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(DisplaysIconButtonStyle())
    .focused(focus, equals: targetFocus)
    .disabled(disabled)
    .help(help)
    .accessibilityLabel(Text(verbatim: label))
  }
}

private struct DisplaysRuleDragging: ViewModifier {
  let isEnabled: Bool
  let drag: AutomationRuleDrag

  func body(content: Content) -> some View {
    if isEnabled {
      content.draggable(drag)
    } else {
      content
    }
  }
}

/// What a time rule says on one line: when, which days and the offset from the sun.
enum DisplaysRuleSummary {
  /// The Gregorian weekday numbers, Sunday first, and their short names.
  @MainActor static func shortName(of weekday: Int) -> String {
    switch weekday {
    case 1: L("Sun")
    case 2: L("Mon")
    case 3: L("Tue")
    case 4: L("Wed")
    case 5: L("Thu")
    case 6: L("Fri")
    default: L("Sat")
    }
  }

  @MainActor static func fullName(of weekday: Int) -> String {
    switch weekday {
    case 1: L("Sunday")
    case 2: L("Monday")
    case 3: L("Tuesday")
    case 4: L("Wednesday")
    case 5: L("Thursday")
    case 6: L("Friday")
    default: L("Saturday")
    }
  }

  /// "Every day · 08:00", "Mon, Tue · Sunrise · 20 min before".
  @MainActor
  static func text(of rule: WallpaperAutomationRule) -> String {
    let days =
      rule.weekdays.count == 7
      ? L("Every day") : rule.weekdays.sorted().map(shortName(of:)).joined(separator: ", ")
    let when: String
    switch rule.event {
    case .time: when = ClockMinute(minutes: rule.minute)?.text ?? ""
    case .sunrise: when = L("Sunrise")
    case .sunset: when = L("Sunset")
    }
    var parts = [days, when]
    if rule.event != .time, rule.offset != 0 {
      parts.append(
        rule.offset < 0 ? L("\(abs(rule.offset)) min before") : L("\(rule.offset) min after"))
    }
    if !rule.isEnabled {
      parts.append(L("Disabled"))
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - The rule editor

/// The inline form that adds a time rule or edits one: when, the time or the offset from the sun,
/// the days, and what to switch to. A rule needs a target and at least one day; the form says so
/// instead of saving.
private struct DisplaysRuleEditor: View {
  let display: DisplayRow
  let targets: AutomationTargets
  var focus: FocusState<DisplaysSettingsModel.AutomationFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  var body: some View {
    let model = controller.displaysSettings
    let draft = Binding(
      get: { model.ruleEditing?.draft ?? DisplaysRuleDraft() }, set: { model.ruleEditing?.draft = $0 })
    let value = draft.wrappedValue
    VStack(alignment: .leading, spacing: 10) {
      formRow(L("When")) {
        DisplaysTitleMenu(
          selection: draft.event,
          title: {
            switch value.event {
            case .time: L("At a time")
            case .sunrise: L("Sunrise")
            case .sunset: L("Sunset")
            }
          }(), width: 150, alignment: .leading
        ) {
          Text("At a time").tag(WallpaperAutomationRule.Event.time)
          Text("Sunrise").tag(WallpaperAutomationRule.Event.sunrise)
          Text("Sunset").tag(WallpaperAutomationRule.Event.sunset)
        }
        // The editor opens with the keyboard on its first control.
        .focused(focus, equals: .ruleEvent(display: display.id))
      }
      if value.event == .time {
        formRow(L("Time")) {
          DisplaysClockField(
            binding: Binding(
              get: { draft.wrappedValue.time.minutes },
              set: { draft.wrappedValue.time = ClockMinute(minutes: $0) ?? draft.wrappedValue.time }))
        }
      } else {
        formRow(L("Offset in minutes")) {
          TextField(noLabel, text: draft.offsetText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .accessibilityLabel(Text(verbatim: L("Offset in minutes")))
        }
        if let solarLine = DisplaysSolarReadout.ruleEventSummary(
          event: value.event, offset: value.offset(locale: locale),
          solar: controller.solarSettings, locale: locale)
        {
          Text(verbatim: solarLine)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityIdentifier("displays.rule-solar-today.\(display.id)")
        }
        Text("Negative offsets run before the sun event; positive offsets run after it. Set your location below.")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
      }
      formRow(L("Repeat on")) {
        VStack(alignment: .leading, spacing: 6) {
          // The days and the quick sets wrap at the width the form has: seven buttons in one line
          // are wider than the narrowest window's page.
          TagFlow(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
              if day == 1 {
                dayToggle(day, draft: draft).focused(focus, equals: .firstDay)
              } else {
                dayToggle(day, draft: draft)
              }
            }
          }
          TagFlow(spacing: 6) {
            Button("Weekdays") { draft.wrappedValue.choose(AutomationRuleEdit.weekdaysOnly) }
            Button("Weekends") { draft.wrappedValue.choose(AutomationRuleEdit.weekends) }
            Button("Every day") { draft.wrappedValue.choose(AutomationRuleEdit.everyDay) }
          }
          if value.showsDaysError {
            Text("Choose at least one weekday.")
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.danger.color)
          }
        }
      }
      formRow(L("Switch to")) {
        DisplaysTargetPicker(
          selection: value.target, targets: targets, isRequired: true, popoverTitle: L("Switch to"),
          key: PanelActionCoordinator.key("automationRuleDraft", id: display.id),
          commit: { _ in }, onSelect: { draft.wrappedValue.target = $0 }, width: 300,
          alignment: .leading)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Cancel") { model.cancelRule() }
        Button("Save rule") {
          controller.launch(PanelActionCoordinator.key("automationRuleSave", id: display.id)) {
            try await model.saveRule()
          }
        }
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(!value.canSave(locale: locale))
      }
    }
    .announcesChanges(of: value.showsDaysError ? L("Choose at least one weekday.") : nil)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(theme.surface.hover.color)
    .onExitCommand { model.cancelRule() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.automation-editor.\(display.id)")
  }

  private func dayToggle(_ day: Int, draft: Binding<DisplaysRuleDraft>) -> some View {
    Toggle(
      isOn: Binding(
        get: { draft.wrappedValue.weekdays.contains(day) },
        set: { _ in draft.wrappedValue.toggle(day) })
    ) {
      Text(verbatim: DisplaysRuleSummary.shortName(of: day)).frame(minWidth: 28)
    }
    .toggleStyle(.button)
    .accessibilityLabel(Text(verbatim: DisplaysRuleSummary.fullName(of: day)))
  }

  /// A label and what it labels: side by side while there is room, the label above otherwise. The
  /// labels share the width of the longest in the language on show, so the controls line up and no
  /// label wraps. That column is `formLabels`: a new row's title goes there too, or its control
  /// stands out of line in the languages whose label is the longest.
  private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    DisplaysRowLayout(spacing: 12, fillsControl: true, keepsTextWidth: true) {
      ColumnLabel(text: Text(verbatim: title), column: formLabels.map { Text(verbatim: $0) })
        .font(.system(size: 13))
      VStack(alignment: .leading, spacing: 0) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Every label `formRow` is given, whichever rows the rule shows.
  private var formLabels: [String] {
    [L("When"), L("Time"), L("Offset in minutes"), L("Repeat on"), L("Switch to")]
  }
}

// MARK: - Footer

private struct DisplaysAutomationFooter: View {
  let display: DisplayRow
  let state: AutomationState
  let locked: Bool
  let forced: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    if let overrideNote = overrideNotice {
      DisplaysNote(text: overrideNote)
    }
    if let error = state.error {
      DisplaysMessageRow(text: error, isError: true)
      HStack {
        Button("Retry automatic change") {
          controller.launch(PanelActionCoordinator.key("automationRetry", id: display.id)) {
            try await controller.retryAutomation(display: display.id)
          }
        }
        .disabled(locked)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
    }
    VStack(alignment: .leading, spacing: 8) {
      DisplaysCaption(item: DisplaysSettingsSection.automationFooter, forced: forced)
      HStack(spacing: 8) {
        Button("Refresh Spaces") {
          controller.launch(PanelActionCoordinator.key("automationRefreshSpaces")) {
            try await controller.refreshSpaces()
          }
        }
        Button("Open Focus Settings…") {
          controller.launch(PanelActionCoordinator.key("openFocusSettings")) {
            try await controller.openFocusSettings()
          }
        }
        Spacer(minLength: 0)
      }
      .disabled(locked)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .announcesChanges(of: state.error)
  }

  private var overrideNotice: String? {
    switch state.activeOverride {
    case .focus:
      return L("A Focus filter is active for this display. Manual choices remain available.")
    case .app:
      return L("An app rule is temporarily overriding this display’s wallpaper. Manual choices remain available.")
    case .battery:
      return L("The battery wallpaper override is active for this display. Manual choices remain available.")
    case nil:
      return state.isFocused
        ? L("A Focus filter is active for this display. Manual choices remain available.")
        : nil
    }
  }
}
