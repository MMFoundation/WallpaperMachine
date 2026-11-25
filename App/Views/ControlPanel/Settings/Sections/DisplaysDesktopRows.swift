import SwiftUI

/// A display's Different wallpaper for each desktop: the switch, and while it is on, a tile per
/// desktop with the wallpaper that desktop shows. A tile opens a searchable chooser for its
/// desktop; a choice saved for a desktop that is gone can be forgotten. A mirrored or disabled
/// display shows the rows but cannot change them.
struct DisplaysDesktopRows: View {
  let display: DisplayRow
  let forced: Bool

  @Environment(PanelController.self) private var controller
  @FocusState private var focus: DisplaysSettingsModel.AutomationFocus?

  var body: some View {
    let settings = controller.settings
    let model = controller.displaysSettings
    let state = controller.automationState(for: display.id)
    let item = DisplaysSettingsSection.desktops
    let locked = controller.isStoreBusy || !display.enabled || display.isMirror
    let isOn = state.usesSpaces
    Group {
      DisplaysRow(
        item: item, note: note(state, isOn: isOn), forced: forced, identity: display.id,
        controlLabel: L("\(settings.text(item.title)) for \(display.title)")
      ) {
        Toggle(
          noLabel,
          isOn: model.binding(PanelActionCoordinator.key("desktopWallpapers", id: display.id), current: isOn) {
            on in try await controller.setDesktopWallpapers(on, display: display.id)
          }
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .focused($focus, equals: .desktopsToggle(display: display.id))
        .disabled(locked || (!isOn && !state.spacesAvailable))
      }
      if isOn, forced || settings.search.shows(item) {
        if !state.desktops.isEmpty {
          DisplaysDesktopStrip(display: display, state: state, locked: locked || !state.spacesAvailable)
        }
        ForEach(state.missingDesktops) { missing in
          missingRow(missing, locked: locked)
        }
        if let reason = state.spacesUnavailableReason {
          DisplaysNote(text: Self.unavailableText(reason), tone: .warning)
          if reason == .noInformation {
            Button("Refresh Spaces") {
              controller.launch(PanelActionCoordinator.key("automationRefreshSpaces")) {
                try await controller.refreshSpaces()
              }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
          }
        }
      }
    }
    .onChange(of: model.automationFocus, initial: true) { _, target in
      switch target {
      case .desktopsToggle(display: display.id), .forget(display: display.id, desktop: _):
        focus = target
        model.consumeAutomationFocus()
      default:
        break
      }
    }
  }

  /// What the switch does, and while it is off, why it cannot be turned on or how it stacks with
  /// an existing schedule or appearance rule.
  private func note(_ state: AutomationState, isOn: Bool) -> String {
    let base = controller.settings.text(DisplaysSettingsSection.desktops.note ?? "")
    if isOn {
      guard state.ruleMode != .off else { return base }
      return "\(base) \(L("Desktops without a chosen wallpaper follow this display’s automatic wallpaper selection."))"
    }
    if let reason = state.spacesUnavailableReason { return "\(base) \(Self.unavailableText(reason))" }
    switch state.ruleMode {
    case .schedule, .appearance:
      return "\(base) \(L("Desktops without a chosen wallpaper will keep following your automatic wallpaper selection."))"
    case .off:
      return base
    }
  }

  static func unavailableText(_ reason: AutomationState.SpacesUnavailableReason) -> String {
    switch reason {
    case .lockScreenOwnsDesktop: L("Turn off animated lock-screen wallpaper to use desktop Space choices.")
    case .noInformation: L("Desktop information is unavailable. Refresh Spaces or choose another automatic mode.")
    }
  }

  private func missingRow(_ missing: AutomationState.MissingDesktop, locked: Bool) -> some View {
    let name = controller.automationTargets.title(of: missing.target) ?? L("Unavailable")
    return DisplaysRow(
      item: DisplaysSettingsSection.desktops, title: L("Unavailable desktop"), note: "",
      details: [name], forced: forced, identity: "\(display.id).missing.\(missing.id)", labelsControl: false
    ) {
      Button("Forget choice for \(name)") {
        controller.launch(PanelActionCoordinator.key("automationSpace", id: display.id, detail: missing.id)) {
          try await controller.displaysSettings.forgetDesktop(missing.id, display: display.id)
        }
      }
      .focused($focus, equals: .forget(display: display.id, desktop: missing.id))
      .disabled(locked)
    }
  }
}

/// One tile per desktop of the display, in their order, with the picture of what each shows.
private struct DisplaysDesktopStrip: View {
  let display: DisplayRow
  let state: AutomationState
  let locked: Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 10) {
        ForEach(state.desktops) { desktop in
          DisplaysDesktopTile(
            display: display, desktop: desktop, ruleMode: state.ruleMode,
            isCurrent: desktop.id == state.currentDesktop, locked: locked)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: L("Desktops of \(display.title)")))
  }
}

/// A desktop's tile: the cover of its wallpaper (or a saved playlist's symbol), its number and what
/// it shows. Clicking it opens the chooser.
private struct DisplaysDesktopTile: View {
  let display: DisplayRow
  let desktop: AutomationState.Desktop
  let ruleMode: DisplayWallpaperAutomation.RuleMode
  let isCurrent: Bool
  let locked: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var choosing = false

  static let size = CGSize(width: 132, height: 80)

  var body: some View {
    let name = desktopName
    let shows = showsText
    Button {
      choosing = true
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        artwork
          .frame(width: Self.size.width, height: Self.size.height)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(
                isCurrent ? theme.accent.accent.color : theme.surface.line.color,
                lineWidth: isCurrent ? 2 : 1)
          }
        Text(verbatim: name)
          .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
          .lineLimit(1)
        Text(verbatim: shows)
          .font(.system(size: 11))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(width: Self.size.width, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(locked)
    .help(L("Choose the wallpaper for \(name)"))
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(Text(verbatim: shows))
    .accessibilityHint(Text(verbatim: L("Choose the wallpaper for \(name)")))
    .accessibilityIdentifier("displays.desktop.\(display.id).\(desktop.number)")
    .popover(isPresented: $choosing, arrowEdge: .bottom) {
      DesktopWallpaperChooser(
        display: display, desktop: desktop, desktopName: name, ruleMode: ruleMode
      ) { choosing = false }
        .panelPresentationLocale()
    }
  }

  private var desktopName: String {
    isCurrent ? L("Desktop \(desktop.number) (current)") : L("Desktop \(desktop.number)")
  }

  /// What the desktop shows: its wallpaper or playlist, the stacked schedule/appearance rule,
  /// Desktop 1's choice, or whatever plays.
  private var showsText: String {
    guard let target = desktop.target else {
      switch ruleMode {
      case .schedule: return L("Follows time schedule")
      case .appearance: return L("Follows system appearance")
      case .off:
        return desktop.firstDesktopTarget == nil ? L("Keeps the current wallpaper") : L("Same as Desktop 1")
      }
    }
    return controller.automationTargets.title(of: target) ?? L("Unavailable")
  }

  /// A desktop that follows Desktop 1 shows its cover, dimmed; one following a stacked schedule or
  /// appearance rule shows that rule's symbol.
  @ViewBuilder
  private var artwork: some View {
    let shown = desktop.target ?? (ruleMode == .off ? desktop.firstDesktopTarget : nil)
    ZStack {
      theme.surface.well.color
      if desktop.target == nil, ruleMode != .off {
        symbol(ruleMode == .schedule ? "clock" : "circle.lefthalf.filled")
      } else {
        switch shown?.kind {
        case .wallpaper:
          if let row = shown.flatMap({ controller.libraryRow(id: $0.id) }) {
            PanelImage(source: row.coverSource, pointSize: Self.size.width)
              .opacity(desktop.target == nil ? 0.55 : 1)
          } else {
            symbol("questionmark.square.dashed")
          }
        case .playlist:
          symbol("rectangle.stack")
        case nil:
          symbol("plus")
        }
      }
    }
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 20, weight: .regular))
      .foregroundStyle(theme.surface.muted.color)
      .accessibilityHidden(true)
  }
}

/// The wallpapers and saved playlists a desktop can show, with a search field, as covers: the
/// installed library does not fit a menu. Choosing one saves it for the desktop and closes.
struct DesktopWallpaperChooser: View {
  let display: DisplayRow
  let desktop: AutomationState.Desktop
  let desktopName: String
  var ruleMode: DisplayWallpaperAutomation.RuleMode = .off
  let dismiss: () -> Void

  @Environment(PanelController.self) private var controller

  var body: some View {
    let targets = controller.automationTargets
    let clearOption: WallpaperThumbnailChooser.ClearOption = {
      switch ruleMode {
      case .schedule:
        return .init(
          title: L("Follow time schedule"),
          help: L("This desktop follows this display’s time schedule."),
          isSelected: desktop.target == nil, isDisabled: desktop.target == nil,
          action: { choose(nil) })
      case .appearance:
        return .init(
          title: L("Follow system appearance"),
          help: L("This desktop follows the system light or dark appearance."),
          isSelected: desktop.target == nil, isDisabled: desktop.target == nil,
          action: { choose(nil) })
      case .off:
        return desktop.number == 1
          ? .init(
            title: L("Keep the current wallpaper"),
            help: L("This desktop shows whatever the display plays when you switch to it."),
            isSelected: desktop.target == nil, isDisabled: desktop.target == nil,
            action: { choose(nil) })
          : .init(
            title: L("Same as Desktop 1"),
            help: L("This desktop shows Desktop 1’s wallpaper, like every desktop you add."),
            isSelected: desktop.target == nil, isDisabled: desktop.target == nil,
            action: { choose(nil) })
      }
    }()
    let unavailable =
      desktop.target.flatMap { target in
        targets.title(of: target) == nil ? L("The saved choice is no longer available.") : nil
      }
    WallpaperThumbnailChooser(
      title: L("Wallpaper for \(desktopName)"), wallpapers: targets.wallpapers,
      playlists: targets.playlists, selected: desktop.target, unavailableNote: unavailable,
      clearOption: clearOption, onSelect: { choose($0) }, onDismiss: dismiss)
  }

  private func choose(_ target: WallpaperAutomationTarget?) {
    let key = PanelActionCoordinator.key("automationSpace", id: display.id, detail: desktop.id)
    controller.launch(key) {
      try await controller.setAutomationDesktop(desktop.id, to: target, display: display.id)
    }
  }
}
