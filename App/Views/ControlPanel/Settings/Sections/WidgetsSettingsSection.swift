import AppKit
import SwiftUI

/// Settings › Desktop Widgets: clocks, dates, notes, countdowns and the other widgets the app draws on
/// the desktop over any wallpaper. A widget
/// belongs to no wallpaper, so changing the wallpaper keeps it, and none of its controls waits for
/// the renderer. The list is the layers, front first: a click picks the widget the groups below
/// edit, its own buttons show, hide or remove it, its handle drags it to another layer, and its
/// context menu duplicates it or moves it a layer. The preview arranges the widget by drag,
/// snapping it to guides; the position sliders and the Center buttons do the same from the
/// keyboard and VoiceOver.
struct WidgetsSettingsSection: View {
  private static let list = SettingsItem.Group("widgets")
  private static let arrange = SettingsItem.Group("arrange", title: "Position")
  private static let look = SettingsItem.Group("look", title: "Look")
  private static let colors = SettingsItem.Group("colors", title: "Colors")
  private static let effects = SettingsItem.Group("effects", title: "Effects")
  private static let format = SettingsItem.Group("format", title: "Format")

  static let add = SettingsItem(
    id: "widgets.add", section: .widgets, group: list, title: "Add a widget",
    note:
      "Widgets stay on the desktop when you change the wallpaper. They sit above the wallpaper and below your desktop icons, on every desktop.",
    keywords: [
      "Add Widget", "Clock", "Date", "Text", "Countdown", "Greeting", "Battery", "Sunrise and sunset",
      "Analog clock", "Month calendar",
    ])

  static let shown = SettingsItem(
    id: "widgets.shown", section: .widgets, group: arrange, title: "Show on the desktop")
  static let display = SettingsItem(
    id: "widgets.display", section: .widgets, group: arrange, title: "Display",
    keywords: ["Main display", "All displays"])
  static let preview = SettingsItem(
    id: "widgets.preview", section: .widgets, group: arrange, title: "Arrange",
    note: "Drag a widget to move it. It snaps to the center and to other widgets; hold Command to place it freely.",
    keywords: ["Snap", "Guides"])
  static let center = SettingsItem(
    id: "widgets.center", section: .widgets, group: arrange, title: "Center on the display",
    keywords: ["Horizontally", "Vertically", "Middle"])
  static let horizontal = SettingsItem(
    id: "widgets.horizontal", section: .widgets, group: arrange, title: "Horizontal position")
  static let vertical = SettingsItem(
    id: "widgets.vertical", section: .widgets, group: arrange, title: "Vertical position")
  static let alignment = SettingsItem(
    id: "widgets.alignment", section: .widgets, group: arrange, title: "Alignment",
    note: "The edge of the text that stays in place when the text gets longer or shorter.",
    keywords: ["Left", "Center", "Right"])

  static let rotation = SettingsItem(
    id: "widgets.rotation", section: .widgets, group: arrange, title: "Rotation")

  static let style = SettingsItem(
    id: "widgets.style", section: .widgets, group: look, title: "Style",
    note: "Applies a finished look in one go: colors and effects, never the font or the place.",
    keywords: ["Neon", "Outlined", "Glass", "Sunset", "Long shadow"])
  static let size = SettingsItem(id: "widgets.size", section: .widgets, group: look, title: "Size")
  static let typeface = SettingsItem(
    id: "widgets.typeface", section: .widgets, group: look, title: "Typeface",
    note: "The system font in one of its designs, or any font installed on this Mac.",
    keywords: ["Font", "Standard", "Rounded", "Serif", "Monospaced"])
  static let weight = SettingsItem(
    id: "widgets.weight", section: .widgets, group: look, title: "Weight",
    note: "From 100, the thinnest, through 400, regular, to 900, the boldest.")
  static let italic = SettingsItem(
    id: "widgets.italic", section: .widgets, group: look, title: "Italic",
    note: "A font without an italic is slanted instead.")
  static let letterSpacing = SettingsItem(
    id: "widgets.letter-spacing", section: .widgets, group: look, title: "Letter spacing",
    keywords: ["Tracking"])
  static let lineHeight = SettingsItem(
    id: "widgets.line-height", section: .widgets, group: look, title: "Line height")
  static let textCase = SettingsItem(
    id: "widgets.case", section: .widgets, group: look, title: "Letter case",
    keywords: ["Uppercase", "Lowercase"])

  static let color = SettingsItem(id: "widgets.color", section: .widgets, group: colors, title: "Color")
  static let accent = SettingsItem(
    id: "widgets.accent", section: .widgets, group: colors, title: "Accent color",
    note: "The second hand of a clock face, and today in a month calendar.")
  static let gradient = SettingsItem(
    id: "widgets.gradient", section: .widgets, group: colors, title: "Gradient",
    note: "Fades the color into a second one across the widget.")
  static let gradientColor = SettingsItem(
    id: "widgets.gradient-color", section: .widgets, group: colors, title: "Second color")
  static let gradientAngle = SettingsItem(
    id: "widgets.gradient-angle", section: .widgets, group: colors, title: "Gradient direction",
    note: "At 180° the gradient runs from the top down.")
  static let opacity = SettingsItem(
    id: "widgets.opacity", section: .widgets, group: colors, title: "Opacity")

  static let outline = SettingsItem(
    id: "widgets.outline", section: .widgets, group: effects, title: "Outline",
    keywords: ["Stroke", "Border"])
  static let outlineColor = SettingsItem(
    id: "widgets.outline-color", section: .widgets, group: effects, title: "Outline color")
  static let glow = SettingsItem(
    id: "widgets.glow", section: .widgets, group: effects, title: "Glow", keywords: ["Neon"])
  static let glowColor = SettingsItem(
    id: "widgets.glow-color", section: .widgets, group: effects, title: "Glow color")
  static let shadow = SettingsItem(
    id: "widgets.shadow", section: .widgets, group: effects, title: "Shadow",
    note: "Keeps light text readable on a light wallpaper.")
  static let shadowColor = SettingsItem(
    id: "widgets.shadow-color", section: .widgets, group: effects, title: "Shadow color")
  static let shadowOpacity = SettingsItem(
    id: "widgets.shadow-opacity", section: .widgets, group: effects, title: "Shadow opacity")
  static let shadowBlur = SettingsItem(
    id: "widgets.shadow-blur", section: .widgets, group: effects, title: "Shadow blur")
  static let shadowDistance = SettingsItem(
    id: "widgets.shadow-distance", section: .widgets, group: effects, title: "Shadow distance")
  static let shadowAngle = SettingsItem(
    id: "widgets.shadow-angle", section: .widgets, group: effects, title: "Shadow direction",
    note: "At 180° the shadow falls straight down.")
  static let background = SettingsItem(
    id: "widgets.background", section: .widgets, group: effects, title: "Background",
    note: "A plate behind the widget that keeps it readable on a busy wallpaper.",
    keywords: ["Rectangle", "Capsule"])
  static let backgroundColor = SettingsItem(
    id: "widgets.background-color", section: .widgets, group: effects, title: "Background color")
  static let backgroundOpacity = SettingsItem(
    id: "widgets.background-opacity", section: .widgets, group: effects, title: "Background opacity")
  static let backgroundPadding = SettingsItem(
    id: "widgets.background-padding", section: .widgets, group: effects, title: "Background padding")
  static let resetEffects = SettingsItem(
    id: "widgets.reset-effects", section: .widgets, group: effects, title: "Reset effects",
    note: "Puts the gradient, outline, glow, shadow and background back as a new widget has them.")

  static let timeFormat = SettingsItem(
    id: "widgets.time-format", section: .widgets, group: format, title: "Time format",
    keywords: ["Follow system", "12-hour", "24-hour"])
  static let seconds = SettingsItem(
    id: "widgets.seconds", section: .widgets, group: format, title: "Show seconds",
    note: "The clock is redrawn every second instead of every minute.")
  static let dateFormat = SettingsItem(
    id: "widgets.date-format", section: .widgets, group: format, title: "Date format")
  static let calendarSystem = SettingsItem(
    id: "widgets.calendar", section: .widgets, group: format, title: "Calendar",
    note: "Writes the date in another calendar, such as the Chinese lunar calendar.")
  static let clockLayout = SettingsItem(
    id: "widgets.clock-layout", section: .widgets, group: format, title: "Layout",
    note: "Stacked puts the hour above the minutes.", keywords: ["One line", "Stacked"])
  static let padsHour = SettingsItem(
    id: "widgets.leading-zero", section: .widgets, group: format, title: "Leading zero",
    note: "Writes 9:41 as 09:41.")
  static let showsPeriod = SettingsItem(
    id: "widgets.period", section: .widgets, group: format, title: "Show AM/PM",
    note: "Only a 12-hour time has AM or PM.")
  static let dialMarks = SettingsItem(
    id: "widgets.dial", section: .widgets, group: format, title: "Dial",
    keywords: ["Hour marks", "Minute ticks", "Numbers"])
  static let dialRing = SettingsItem(
    id: "widgets.dial-ring", section: .widgets, group: format, title: "Show ring")
  static let timeZone = SettingsItem(
    id: "widgets.time-zone", section: .widgets, group: format, title: "Time zone",
    note: "Shows the time in another city instead of this Mac’s time zone.")
  static let label = SettingsItem(
    id: "widgets.label", section: .widgets, group: format, title: "Label",
    note: "Words shown before the time or date, such as a city’s name.")
  static let content = SettingsItem(
    id: "widgets.text", section: .widgets, group: format, title: "Text",
    note: "Press Option-Return for a new line.")
  static let event = SettingsItem(
    id: "widgets.event", section: .widgets, group: format, title: "Event",
    note: "Leave it empty to name the day instead.")
  static let targetDay = SettingsItem(
    id: "widgets.target-day", section: .widgets, group: format, title: "Count down to")
  static let name = SettingsItem(
    id: "widgets.name", section: .widgets, group: format, title: "Your name",
    note: "Added to the greeting when you give one.")
  static let sunStyle = SettingsItem(
    id: "widgets.sun", section: .widgets, group: format, title: "Sun times",
    note: "Uses the location set in Settings › Displays › Sunrise and sunset.",
    keywords: ["Next sunrise or sunset", "Today’s sunrise and sunset"])

  /// The rows that edit the selected widget.
  static let editorItems = [
    shown, display, preview, center, horizontal, vertical, alignment, rotation, style, size, typeface, weight,
    italic, letterSpacing, lineHeight, textCase, color, accent, gradient, gradientColor, gradientAngle, opacity,
    outline, outlineColor, glow, glowColor, shadow, shadowColor, shadowOpacity, shadowBlur, shadowDistance,
    shadowAngle, background, backgroundColor, backgroundOpacity, backgroundPadding, resetEffects, timeFormat,
    clockLayout, padsHour, showsPeriod, seconds, dialMarks, dialRing, dateFormat, calendarSystem, timeZone, label,
    content, event, targetDay, name, sunStyle,
  ]
  static let items = [add] + editorItems

  /// The rows only some kinds of widget have, and those kinds.
  static let kindRows: [String: Set<DesktopWidget.Kind>] = [
    letterSpacing.id: Set(DesktopWidget.Kind.allCases).subtracting([.analog]),
    textCase.id: Set(DesktopWidget.Kind.allCases).subtracting([.analog]),
    lineHeight.id: [.text, .time], accent.id: [.analog, .calendar],
    timeFormat.id: [.time, .sun], seconds.id: [.time, .analog], dateFormat.id: [.date],
    clockLayout.id: [.time], padsHour.id: [.time], showsPeriod.id: [.time],
    dialMarks.id: [.analog], dialRing.id: [.analog],
    calendarSystem.id: [.date], timeZone.id: [.time, .date, .analog], label.id: [.time, .date],
    content.id: [.text], event.id: [.countdown], targetDay.id: [.countdown], name.id: [.greeting],
    sunStyle.id: [.sun],
  ]

  /// The rows that only matter once another choice is made, each with that choice.
  static let dependentRows: [String: @Sendable (DesktopWidget) -> Bool] = [
    gradientColor.id: { $0.fill == .gradient }, gradientAngle.id: { $0.fill == .gradient },
    outlineColor.id: { $0.outlineWidth > 0 }, glowColor.id: { $0.glowSize > 0 },
    shadowColor.id: { $0.hasShadow }, shadowOpacity.id: { $0.hasShadow }, shadowBlur.id: { $0.hasShadow },
    shadowDistance.id: { $0.hasShadow }, shadowAngle.id: { $0.hasShadow },
    backgroundColor.id: { $0.background != .off }, backgroundOpacity.id: { $0.background != .off },
    backgroundPadding.id: { $0.background != .off },
  ]

  /// The editor's rows while there is no widget to edit, the rows the selected kind has not, and
  /// those waiting on a choice not made.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    guard let widget = controller.widgetsSettings.selected else { return Set(editorItems.map(\.id)) }
    return Set(kindRows.filter { !$0.value.contains(widget.kind) }.keys)
      .union(dependentRows.filter { !$0.value(widget) }.keys)
  }

  /// Whether the editor shows a row for `widget`.
  static func offers(_ item: SettingsItem, for widget: DesktopWidget) -> Bool {
    (kindRows[item.id]?.contains(widget.kind) ?? true) && (dependentRows[item.id]?(widget) ?? true)
  }

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.widgetsSettings
    let widgets = model.widgets
    let screens = model.screens()
    SettingsPage(.widgets) {
      SettingsGroup(Self.list, in: .widgets) {
        SettingsRow(
          Self.add,
          note: widgets.count > 1
            ? L("Widgets higher in the list are in front. Drag a widget by its handle to change the order.") : nil
        ) {
          addMenu
        }
        if !controller.settings.search.isActive {
          let order = widgets.map(\.id)
          ForEach(widgets) { widget in
            WidgetLayerRow(widget: widget, screens: screens, order: order)
          }
        }
      }
      if let widget = model.selected {
        editor(widget, screens: screens)
      }
    }
  }

  /// The Add Widget menu: every kind, by name and symbol.
  private var addMenu: some View {
    let key = PanelActionCoordinator.key("addDesktopWidget")
    return Menu {
      ForEach(DesktopWidget.Kind.allCases, id: \.self) { kind in
        Button {
          controller.launch(key) { try await controller.addDesktopWidget(kind) }
        } label: {
          Label {
            Text(verbatim: Self.title(of: kind))
          } icon: {
            Image(systemName: Self.symbol(of: kind))
          }
        }
        .accessibilityIdentifier("widgets.add.\(kind.rawValue)")
      }
    } label: {
      Text("Add Widget")
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize()
    .disabled(controller.widgetsSettings.widgets.count >= DesktopWidgetStore.limit || controller.isBusy(key))
  }

  // MARK: The editor

  @ViewBuilder
  private func editor(_ widget: DesktopWidget, screens: [DesktopWidgetController.Screen]) -> some View {
    let model = controller.widgetsSettings
    let id = widget.id
    let screen = model.previewScreen(for: widget, among: screens)
    SettingsGroup(Self.arrange, in: .widgets) {
      SettingsRow(Self.shown) {
        WidgetSwitch(id: id, control: "shown", saved: widget.isShown) { .shown($0) }
      }
      SettingsRow(Self.display) {
        SettingsMenuControl(
          key: DesktopWidgetsSettingsModel.key(id, "placement"),
          saved: model.placementValue(for: widget, among: screens),
          options: model.placementOptions(for: widget, among: screens), waitsForMac: false,
          policy: .latestWins
        ) { try await controller.changeDesktopWidget(id, .placement($0)) }
      }
      if let screen {
        SettingsRow(Self.preview, stacked: true) {
          DesktopWidgetPreview(screen: screen)
        }
        SettingsRow(Self.center) {
          centerButtons(widget, on: screen)
        }
      }
      SettingsRow(Self.horizontal) {
        percentSlider(id, "x", saved: widget.x) { .x($0) }
      }
      SettingsRow(Self.vertical) {
        percentSlider(id, "y", saved: widget.y) { .y($0) }
      }
      SettingsRow(Self.alignment) {
        SettingsSegmentedControl(
          segments: DesktopWidget.Alignment.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
          selection: model.value(id, "alignment", saved: widget.alignment), fillsWidth: false
        ) { value in
          model.commit(id, "alignment", to: value) { .alignment($0) }
        }
      }
      SettingsRow(Self.rotation) {
        slider(id, "rotation", saved: widget.rotation, range: DesktopWidget.rotationRange,
               readout: { L("\($0)°") }) { .rotation($0) }
      }
    } accessory: {
      editing(widget)
    }
    SettingsGroup(Self.look, in: .widgets) {
      SettingsRow(Self.style) {
        styleMenu(id)
      }
      SettingsRow(Self.size) {
        SettingsSliderControl(
          key: DesktopWidgetsSettingsModel.key(id, "size"), saved: widget.size, range: DesktopWidget.sizeRange,
          waitsForMac: false, readout: { L("\($0) pt") }
        ) { try await controller.changeDesktopWidget(id, .size($0)) }
      }
      SettingsRow(Self.typeface) {
        WidgetFontMenu(widget: widget)
      }
      SettingsRow(Self.weight) {
        SettingsSliderControl(
          key: DesktopWidgetsSettingsModel.key(id, "weight"), saved: widget.weight / 100,
          range: (DesktopWidget.weightRange.lowerBound / 100)...(DesktopWidget.weightRange.upperBound / 100),
          waitsForMac: false, readout: { String($0 * 100) }
        ) { try await controller.changeDesktopWidget(id, .weight($0 * 100)) }
      }
      SettingsRow(Self.italic) {
        WidgetSwitch(id: id, control: "italic", saved: widget.isItalic) { .italic($0) }
      }
      if Self.offers(Self.letterSpacing, for: widget) {
        SettingsRow(Self.letterSpacing) {
          slider(id, "letterSpacing", saved: widget.letterSpacing, range: DesktopWidget.letterSpacingRange,
                 readout: { L("\($0)%") }) { .letterSpacing($0) }
        }
      }
      if Self.offers(Self.lineHeight, for: widget) {
        SettingsRow(Self.lineHeight) {
          slider(id, "lineHeight", saved: widget.lineHeight, range: DesktopWidget.lineHeightRange,
                 readout: { L("\($0)%") }) { .lineHeight($0) }
        }
      }
      if Self.offers(Self.textCase, for: widget) {
        SettingsRow(Self.textCase) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "textCase"), saved: widget.textCase,
            options: DesktopWidget.TextCase.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .textCase($0)) }
        }
      }
    }
    SettingsGroup(Self.colors, in: .widgets) {
      SettingsRow(Self.color) {
        WidgetColorControl(id: id, control: "color", saved: widget.color) { .color($0) }
      }
      if Self.offers(Self.accent, for: widget) {
        SettingsRow(Self.accent) {
          HStack(spacing: 8) {
            WidgetColorControl(id: id, control: "accent", saved: widget.accentColor ?? widget.color) {
              .accentColor($0)
            }
            if widget.accentColor != nil {
              let key = PanelActionCoordinator.key("resetDesktopWidgetAccent", id: id)
              SettingsActionButton("Use Text Color", isDisabled: controller.isBusy(key)) {
                controller.launch(key) { try await controller.changeDesktopWidget(id, .accentColor(nil)) }
              }
            }
          }
        }
      }
      SettingsRow(Self.gradient) {
        WidgetSwitch(id: id, control: "gradient", saved: widget.fill == .gradient) {
          .fill($0 ? .gradient : .solid)
        }
      }
      if Self.offers(Self.gradientColor, for: widget) {
        SettingsRow(Self.gradientColor) {
          WidgetColorControl(id: id, control: "gradientColor", saved: widget.gradientColor) { .gradientColor($0) }
        }
        SettingsRow(Self.gradientAngle) {
          slider(id, "gradientAngle", saved: widget.gradientAngle, range: DesktopWidget.angleRange,
                 readout: { L("\($0)°") }) { .gradientAngle($0) }
        }
      }
      SettingsRow(Self.opacity) {
        slider(id, "opacity", saved: widget.opacity, range: DesktopWidget.opacityRange,
               readout: { L("\($0)%") }) { .opacity($0) }
      }
    }
    SettingsGroup(Self.effects, in: .widgets) {
      SettingsRow(Self.outline) {
        slider(id, "outline", saved: widget.outlineWidth, range: DesktopWidget.outlineRange,
               readout: Self.offOrPercent) { .outlineWidth($0) }
      }
      if Self.offers(Self.outlineColor, for: widget) {
        SettingsRow(Self.outlineColor) {
          WidgetColorControl(id: id, control: "outlineColor", saved: widget.outlineColor) { .outlineColor($0) }
        }
      }
      SettingsRow(Self.glow) {
        slider(id, "glow", saved: widget.glowSize, range: DesktopWidget.glowRange,
               readout: Self.offOrPercent) { .glowSize($0) }
      }
      if Self.offers(Self.glowColor, for: widget) {
        SettingsRow(Self.glowColor) {
          WidgetColorControl(id: id, control: "glowColor", saved: widget.glowColor) { .glowColor($0) }
        }
      }
      SettingsRow(Self.shadow) {
        WidgetSwitch(id: id, control: "shadow", saved: widget.hasShadow) { .shadow($0) }
      }
      if Self.offers(Self.shadowColor, for: widget) {
        SettingsRow(Self.shadowColor) {
          WidgetColorControl(id: id, control: "shadowColor", saved: widget.shadowColor) { .shadowColor($0) }
        }
        SettingsRow(Self.shadowOpacity) {
          slider(id, "shadowOpacity", saved: widget.shadowOpacity, range: DesktopWidget.opacityRange,
                 readout: { L("\($0)%") }) { .shadowOpacity($0) }
        }
        SettingsRow(Self.shadowBlur) {
          slider(id, "shadowBlur", saved: widget.shadowBlur, range: DesktopWidget.shadowBlurRange,
                 readout: { L("\($0)%") }) { .shadowBlur($0) }
        }
        SettingsRow(Self.shadowDistance) {
          slider(id, "shadowDistance", saved: widget.shadowDistance, range: DesktopWidget.shadowDistanceRange,
                 readout: { L("\($0)%") }) { .shadowDistance($0) }
        }
        SettingsRow(Self.shadowAngle) {
          slider(id, "shadowAngle", saved: widget.shadowAngle, range: DesktopWidget.angleRange,
                 readout: { L("\($0)°") }) { .shadowAngle($0) }
        }
      }
      SettingsRow(Self.background) {
        SettingsMenuControl(
          key: DesktopWidgetsSettingsModel.key(id, "background"), saved: widget.background,
          options: DesktopWidget.Background.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
          waitsForMac: false, policy: .latestWins
        ) { try await controller.changeDesktopWidget(id, .background($0)) }
      }
      if Self.offers(Self.backgroundColor, for: widget) {
        SettingsRow(Self.backgroundColor) {
          WidgetColorControl(id: id, control: "backgroundColor", saved: widget.backgroundColor) {
            .backgroundColor($0)
          }
        }
        SettingsRow(Self.backgroundOpacity) {
          slider(id, "backgroundOpacity", saved: widget.backgroundOpacity, range: DesktopWidget.opacityRange,
                 readout: { L("\($0)%") }) { .backgroundOpacity($0) }
        }
        SettingsRow(Self.backgroundPadding) {
          slider(id, "backgroundPadding", saved: widget.backgroundPadding,
                 range: DesktopWidget.backgroundPaddingRange, readout: { L("\($0)%") }) { .backgroundPadding($0) }
        }
      }
      SettingsRow(Self.resetEffects) {
        let key = PanelActionCoordinator.key("resetDesktopWidgetEffects", id: id)
        SettingsActionButton("Reset", isDisabled: controller.isBusy(key)) {
          controller.launch(key) { try await controller.changeDesktopWidget(id, .resetEffects) }
        }
      }
    }
    SettingsGroup(Self.format, in: .widgets) {
      switch widget.kind {
      case .time:
        SettingsRow(Self.timeFormat) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "timeFormat"), saved: widget.timeFormat,
            options: DesktopWidget.TimeFormat.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .timeFormat($0)) }
        }
        SettingsRow(Self.clockLayout) {
          SettingsSegmentedControl(
            segments: DesktopWidget.ClockLayout.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            selection: model.value(id, "clockLayout", saved: widget.clockLayout), fillsWidth: false
          ) { value in
            model.commit(id, "clockLayout", to: value) { .clockLayout($0) }
          }
        }
        SettingsRow(Self.padsHour) {
          WidgetSwitch(id: id, control: "padsHour", saved: widget.padsHour) { .padsHour($0) }
        }
        SettingsRow(Self.showsPeriod) {
          WidgetSwitch(id: id, control: "showsPeriod", saved: widget.showsPeriod) { .showsPeriod($0) }
        }
        SettingsRow(Self.seconds) {
          WidgetSwitch(id: id, control: "seconds", saved: widget.showsSeconds) { .showsSeconds($0) }
        }
        timeZoneRow(widget)
        labelRow(widget)
      case .date:
        SettingsRow(Self.dateFormat) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "dateStyle"), saved: widget.dateStyle,
            options: model.dateStyleOptions(for: widget), waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .dateStyle($0)) }
        }
        SettingsRow(Self.calendarSystem) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "calendarSystem"), saved: widget.calendarSystem,
            options: model.calendarOptions(), waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .calendarSystem($0)) }
        }
        timeZoneRow(widget)
        labelRow(widget)
      case .analog:
        SettingsRow(Self.dialMarks) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "dialMarks"), saved: widget.dialMarks,
            options: DesktopWidget.DialMarks.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .dialMarks($0)) }
        }
        SettingsRow(Self.dialRing) {
          WidgetSwitch(id: id, control: "dialRing", saved: widget.showsDialRing) { .showsDialRing($0) }
        }
        SettingsRow(Self.seconds) {
          WidgetSwitch(id: id, control: "seconds", saved: widget.showsSeconds) { .showsSeconds($0) }
        }
        timeZoneRow(widget)
      case .text:
        SettingsRow(Self.content) {
          WidgetTextField(id: id, saved: widget.text, multiline: true)
        }
      case .countdown:
        SettingsRow(Self.event) {
          WidgetTextField(id: id, saved: widget.text, multiline: false)
        }
        SettingsRow(Self.targetDay) {
          DatePicker(
            noLabel,
            selection: Binding(
              get: { model.targetDate(model.value(id, "targetDay", saved: widget.targetDay)) },
              set: { date in
                model.commit(id, "targetDay", to: DesktopWidget.day(of: date, in: .autoupdatingCurrent)) {
                  .targetDay($0)
                }
              }),
            displayedComponents: .date
          )
          .datePickerStyle(.stepperField)
          .labelsHidden()
          .fixedSize()
        }
      case .greeting:
        SettingsRow(Self.name) {
          WidgetTextField(id: id, saved: widget.text, multiline: false)
        }
      case .sun:
        SettingsRow(Self.sunStyle) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "sunStyle"), saved: widget.sunStyle,
            options: DesktopWidget.SunStyle.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .sunStyle($0)) }
        }
        SettingsRow(Self.timeFormat) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "timeFormat"), saved: widget.timeFormat,
            options: DesktopWidget.TimeFormat.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .timeFormat($0)) }
        }
      case .battery, .calendar:
        EmptyView()
      }
    }
  }

  /// Which widget the groups below edit, on the first group's title line, so it stays clear once
  /// the list has scrolled away.
  private func editing(_ widget: DesktopWidget) -> some View {
    let text = controller.widgetsSettings.text(for: widget)
    return Label {
      Text(verbatim: text)
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      Image(systemName: Self.symbol(of: widget.kind))
    }
    .font(.panel(.callout))
    .foregroundStyle(theme.surface.muted.color)
    .padding(.trailing, 12)
    .frame(minWidth: 0, maxWidth: 240, alignment: .trailing)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: L("Editing \(text)")))
  }

  /// Center horizontally and vertically: the middle of what the widget shows goes on the display's
  /// centre line, whichever edge its alignment holds. A button whose centring is done is disabled.
  private func centerButtons(_ widget: DesktopWidget, on screen: DesktopWidgetController.Screen) -> some View {
    let model = controller.widgetsSettings
    let id = widget.id
    let shown = model.shown(widget)
    return HStack(spacing: 6) {
      ForEach([true, false], id: \.self) { horizontally in
        let key = PanelActionCoordinator.key("centerDesktopWidget", id: id, detail: horizontally ? "x" : "y")
        Button {
          let value = model.centered(shown, on: screen, horizontally: horizontally)
          controller.launch(key, policy: .latestWins) {
            try await controller.changeDesktopWidget(id, horizontally ? .x(value) : .y(value))
          }
        } label: {
          Label {
            Text(verbatim: horizontally ? L("Horizontally") : L("Vertically"))
          } icon: {
            Image(systemName: horizontally ? "align.horizontal.center" : "align.vertical.center")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isCentered(shown, on: screen, horizontally: horizontally))
        .help(horizontally ? L("Center from left to right") : L("Center from top to bottom"))
        .accessibilityIdentifier("widgets.center.\(horizontally ? "horizontal" : "vertical")")
      }
    }
    .fixedSize()
    .accessibilityElement(children: .contain)
  }

  /// The Time zone menu. Choosing a city for a widget without a label labels it with the city.
  private func timeZoneRow(_ widget: DesktopWidget) -> some View {
    let model = controller.widgetsSettings
    let id = widget.id
    return SettingsRow(Self.timeZone) {
      SettingsMenuControl(
        key: DesktopWidgetsSettingsModel.key(id, "timeZone"), saved: widget.timeZone,
        options: model.timeZoneOptions(for: widget), waitsForMac: false, policy: .latestWins
      ) { value in
        try await controller.setDesktopWidgetTimeZone(id, value, label: value.map(model.city))
      }
    }
  }

  private func labelRow(_ widget: DesktopWidget) -> some View {
    SettingsRow(Self.label) {
      WidgetTextField(id: widget.id, saved: widget.text, multiline: false)
    }
  }

  /// The Style menu: each finished look by name.
  private func styleMenu(_ id: String) -> some View {
    let key = PanelActionCoordinator.key("styleDesktopWidget", id: id)
    return Menu {
      ForEach(DesktopWidget.StylePreset.allCases, id: \.self) { preset in
        Button {
          controller.launch(key) { try await controller.changeDesktopWidget(id, .style(preset)) }
        } label: {
          Text(verbatim: Self.title(of: preset))
        }
        .accessibilityIdentifier("widgets.style.\(preset.rawValue)")
      }
    } label: {
      Text("Apply Style")
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize()
    .disabled(controller.isBusy(key))
  }

  /// A slider for one of a widget's numbers.
  private func slider(
    _ id: String, _ control: String, saved: Int, range: ClosedRange<Int>, readout: @escaping (Int) -> String,
    change: @escaping (Int) -> DesktopWidgetChange
  ) -> some View {
    SettingsSliderControl(
      key: DesktopWidgetsSettingsModel.key(id, control), saved: saved, range: range, waitsForMac: false,
      readout: readout
    ) { try await controller.changeDesktopWidget(id, change($0)) }
  }

  /// "Off" at 0, else the percent.
  private static func offOrPercent(_ value: Int) -> String { value == 0 ? L("Off") : L("\(value)%") }

  /// A position slider in whole percent of the display, 0 at the left or top edge.
  private func percentSlider(
    _ id: String, _ control: String, saved: Double, change: @escaping (Double) -> DesktopWidgetChange
  ) -> some View {
    SettingsSliderControl(
      key: DesktopWidgetsSettingsModel.key(id, control), saved: Int((saved * 100).rounded()), range: 0...100,
      waitsForMac: false, readout: { L("\($0)%") }
    ) { try await controller.changeDesktopWidget(id, change(Double($0) / 100)) }
  }

  // MARK: Words

  static func title(of kind: DesktopWidget.Kind) -> String {
    switch kind {
    case .time: L("Clock")
    case .date: L("Date")
    case .text: L("Text")
    case .countdown: L("Countdown")
    case .greeting: L("Greeting")
    case .battery: L("Battery")
    case .sun: L("Sunrise and sunset")
    case .analog: L("Analog clock")
    case .calendar: L("Month calendar")
    }
  }

  static func symbol(of kind: DesktopWidget.Kind) -> String {
    switch kind {
    case .time: "clock"
    case .date: "calendar"
    case .text: "textformat"
    case .countdown: "hourglass"
    case .greeting: "hand.wave"
    case .battery: "battery.75percent"
    case .sun: "sunrise"
    case .analog: "clock.circle"
    case .calendar: "calendar.day.timeline.left"
    }
  }

  static func title(of style: DesktopWidget.SunStyle) -> String {
    switch style {
    case .next: L("Next sunrise or sunset")
    case .both: L("Today’s sunrise and sunset")
    }
  }

  static func title(of alignment: DesktopWidget.Alignment) -> String {
    switch alignment {
    case .leading: L("Left")
    case .center: L("Center")
    case .trailing: L("Right")
    }
  }

  static func title(of typeface: DesktopWidget.Typeface) -> String {
    switch typeface {
    case .standard: L("Standard")
    case .rounded: L("Rounded")
    case .serif: L("Serif")
    case .monospaced: L("Monospaced")
    }
  }

  static func title(of preset: DesktopWidget.StylePreset) -> String {
    switch preset {
    case .soft: L("Soft shadow")
    case .plain: L("Plain")
    case .neon: L("Neon")
    case .outlined: L("Outlined")
    case .badge: L("Badge")
    case .glass: L("Glass")
    case .sunset: L("Sunset")
    case .longShadow: L("Long shadow")
    }
  }

  static func title(of textCase: DesktopWidget.TextCase) -> String {
    switch textCase {
    case .asWritten: L("As written")
    case .uppercase: L("Uppercase")
    case .lowercase: L("Lowercase")
    }
  }

  static func title(of background: DesktopWidget.Background) -> String {
    switch background {
    case .off: L("Off")
    case .rectangle: L("Rectangle")
    case .rounded: L("Rounded rectangle")
    case .capsule: L("Capsule")
    }
  }

  static func title(of layout: DesktopWidget.ClockLayout) -> String {
    switch layout {
    case .line: L("One line")
    case .stacked: L("Stacked")
    }
  }

  static func title(of marks: DesktopWidget.DialMarks) -> String {
    switch marks {
    case .bare: L("Hands only")
    case .hours: L("Hour marks")
    case .minutes: L("Minute ticks")
    case .numbers: L("Numbers")
    case .quarters: L("12, 3, 6 and 9")
    }
  }

  static func title(of format: DesktopWidget.TimeFormat) -> String {
    switch format {
    case .system: L("Follow system")
    case .twelveHour: L("12-hour")
    case .twentyFourHour: L("24-hour")
    }
  }
}

/// What a drag of a widget's handle carries: the widget, and the layers' order when its row was
/// drawn, so a drop on a list that changed meanwhile changes nothing. It travels as private JSON.
struct WidgetLayerDrag: Codable, Transferable {
  let widget: String
  let expected: [String]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .data, encoder: JSONEncoder(), decoder: JSONDecoder())
  }
}

/// One layer of the list: a handle to drag it to another place, what it says now, its kind and
/// display, and buttons that show or hide it and remove it. A click picks it for the editor below;
/// the selected layer is highlighted. Removing asks once more in place, since it cannot be undone.
private struct WidgetLayerRow: View {
  let widget: DesktopWidget
  let screens: [DesktopWidgetController.Screen]
  /// The layers' order as the list shows it, front first.
  let order: [String]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false
  @State private var isTargeted = false
  @State private var confirmsRemoval = false

  var body: some View {
    let model = controller.widgetsSettings
    let isSelected = model.selectedID == widget.id
    let title = model.text(for: widget)
    HStack(spacing: 6) {
      handle(title: title)
      Button {
        model.select(widget.id)
      } label: {
        label(title: title, isSelected: isSelected)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityIdentifier("widgets.list.\(widget.id)")
      if confirmsRemoval {
        removalQuestion(title: title)
      } else {
        visibilityButton(title: title)
        iconButton("trash", help: L("Remove"), label: L("Remove \(title)")) { confirmsRemoval = true }
          .accessibilityIdentifier("widgets.list.\(widget.id).remove")
      }
    }
    .padding(.leading, 6)
    .padding(.trailing, 10)
    .padding(.vertical, 6)
    .frame(minHeight: 48)
    .background(background(isSelected: isSelected))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .dropDestination(for: WidgetLayerDrag.self) { drops, _ in
      guard let drop = drops.first, drop.widget != widget.id, drop.expected == order,
        let index = order.firstIndex(of: widget.id)
      else { return false }
      move(drop.widget, to: index, expected: drop.expected)
      return true
    } isTargeted: { isTargeted = $0 }
    .contextMenu { menu }
    .onChange(of: model.selectedID) { confirmsRemoval = false }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: Text("Bring Forward")) { moveBy(-1) }
    .accessibilityAction(named: Text("Send Backward")) { moveBy(1) }
  }

  // MARK: Parts

  private func handle(title: String) -> some View {
    Image(systemName: "line.3.horizontal")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(theme.surface.faint.color)
      .frame(width: 18, height: 28)
      .contentShape(Rectangle())
      .draggable(WidgetLayerDrag(widget: widget.id, expected: order)) {
        Label {
          Text(verbatim: title).lineLimit(1)
        } icon: {
          Image(systemName: WidgetsSettingsSection.symbol(of: widget.kind))
        }
        .font(.panel(.body))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
      }
      .help(L("Drag to reorder"))
      .accessibilityHidden(true)
  }

  private func label(title: String, isSelected: Bool) -> some View {
    let model = controller.widgetsSettings
    let kind = WidgetsSettingsSection.title(of: widget.kind)
    let place = model.placementTitle(for: widget, among: screens)
    return HStack(spacing: 10) {
      Image(systemName: WidgetsSettingsSection.symbol(of: widget.kind))
        .font(.system(size: 14))
        .foregroundStyle(isSelected ? theme.accent.accent.color : theme.surface.muted.color)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .font(.panel(.body))
          .foregroundStyle(widget.isShown ? theme.surface.text.color : theme.surface.muted.color)
          .lineLimit(1)
        Text(verbatim: widget.isShown ? "\(kind) · \(place)" : "\(kind) · \(place) · \(L("Hidden"))")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private func visibilityButton(title: String) -> some View {
    let shown = controller.widgetsSettings.value(widget.id, "shown", saved: widget.isShown)
    return iconButton(
      shown ? "eye" : "eye.slash", help: shown ? L("Hide on the desktop") : L("Show on the desktop"),
      label: shown ? L("Hide \(title)") : L("Show \(title)")
    ) {
      controller.widgetsSettings.commit(widget.id, "shown", to: !shown, policy: .dropDuplicates) { .shown($0) }
    }
    .accessibilityIdentifier("widgets.list.\(widget.id).visibility")
  }

  /// Remove asked in place: Cancel keeps the widget, Remove takes it away.
  private func removalQuestion(title: String) -> some View {
    let key = PanelActionCoordinator.key("removeDesktopWidget", id: widget.id)
    return HStack(spacing: 6) {
      Button("Cancel") { confirmsRemoval = false }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("widgets.list.\(widget.id).remove-cancel")
      Button(role: .destructive) {
        let id = widget.id
        controller.launch(key) { try await controller.removeDesktopWidget(id) }
      } label: {
        Text("Remove")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(controller.isBusy(key))
      .accessibilityLabel(Text(verbatim: L("Remove \(title)")))
      .accessibilityIdentifier("widgets.list.\(widget.id).remove-confirm")
    }
    .fixedSize()
  }

  @ViewBuilder
  private var menu: some View {
    let index = order.firstIndex(of: widget.id) ?? 0
    let last = order.count - 1
    let shown = widget.isShown
    Button(shown ? L("Hide on the desktop") : L("Show on the desktop")) {
      controller.widgetsSettings.commit(widget.id, "shown", to: !shown, policy: .dropDuplicates) { .shown($0) }
    }
    Button("Duplicate") {
      let id = widget.id
      controller.launch(PanelActionCoordinator.key("duplicateDesktopWidget", id: id)) {
        try await controller.duplicateDesktopWidget(id)
      }
    }
    .disabled(order.count >= DesktopWidgetStore.limit)
    Divider()
    Button("Bring to Front") { move(widget.id, to: 0) }.disabled(index == 0)
    Button("Bring Forward") { moveBy(-1) }.disabled(index == 0)
    Button("Send Backward") { moveBy(1) }.disabled(index >= last)
    Button("Send to Back") { move(widget.id, to: last) }.disabled(index >= last)
    Divider()
    Button("Remove", role: .destructive) { confirmsRemoval = true }
  }

  /// The highlight sits the same distance inside the row on every side, with corners concentric
  /// to the card's, so on the card's last row it follows the card's own rounded edge.
  private func background(isSelected: Bool) -> some View {
    let inset: CGFloat = 4
    let shape = RoundedRectangle(cornerRadius: PanelCardSurface.cornerRadius - inset, style: .continuous)
    let fill: Color =
      isTargeted
      ? theme.accent.accent.color.opacity(0.14)
      : isSelected ? theme.surface.selected.color : isHovering ? theme.surface.hover.color : .clear
    return shape.fill(fill).padding(inset)
  }

  private func iconButton(
    _ symbol: String, help: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(DisplaysIconButtonStyle())
    .help(help)
    .accessibilityLabel(Text(verbatim: label))
  }

  // MARK: Moving

  private func moveBy(_ offset: Int) {
    guard let index = order.firstIndex(of: widget.id) else { return }
    let target = index + offset
    guard order.indices.contains(target) else { return }
    move(widget.id, to: target)
  }

  private func move(_ id: String, to index: Int, expected: [String]? = nil) {
    controller.launch(PanelActionCoordinator.key("moveDesktopWidget")) {
      try await controller.moveDesktopWidget(id, to: index, expected: expected)
    }
  }
}

/// The field for a widget's words: a text widget's text, a label, a countdown's event or a name.
/// The desktop follows each keystroke; the field shows what was typed until it is saved.
private struct WidgetTextField: View {
  let id: String
  let saved: String
  let multiline: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let model = controller.widgetsSettings
    let text = Binding(
      get: { model.value(id, "text", saved: saved) },
      set: { model.commit(id, "text", to: String($0.prefix(DesktopWidget.textLimit))) { .text($0) } })
    Group {
      if multiline {
        TextField(noLabel, text: text, axis: .vertical).lineLimit(1...6)
      } else {
        TextField(noLabel, text: text)
      }
    }
    .textFieldStyle(.roundedBorder)
    .font(.system(size: 12.5))
    .frame(maxWidth: 240)
    .settingsRowAccessibility(row)
    .controlSize(.small)
  }
}

/// A switch for one of a widget's choices, showing what it just sent until the change has run.
private struct WidgetSwitch: View {
  let id: String
  let control: String
  let saved: Bool
  let change: (Bool) -> DesktopWidgetChange

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let model = controller.widgetsSettings
    Toggle(
      isOn: Binding(
        get: { model.value(id, control, saved: saved) },
        set: { model.commit(id, control, to: $0, policy: .dropDuplicates, change) })
    ) {
      Text(verbatim: row?.title ?? "")
    }
    .toggleStyle(.switch)
    .labelsHidden()
    .settingsAccessibilityHint(row?.hint)
    .controlSize(.small)
  }
}

/// A colour well of a widget. The colour panel sends every colour the person passes over, and the
/// desktop follows each one.
private struct WidgetColorControl: View {
  let id: String
  let control: String
  let saved: String
  let change: (String) -> DesktopWidgetChange

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.widgetsSettings
    ColorPicker(
      selection: Binding(
        get: { Self.color(model.value(id, control, saved: saved)) },
        set: { color in
          guard let hex = DesktopWidget.hex(NSColor(color)) else { return }
          model.commit(id, control, to: hex, change)
        }),
      supportsOpacity: false
    ) {
      EmptyView()
    }
    .labelsHidden()
  }

  private static func color(_ hex: String) -> Color {
    let rgb = DesktopWidget.rgb(hex) ?? (255, 255, 255)
    return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
  }
}

/// The Typeface menu: the system font's four designs, then every font family installed on this
/// Mac, and the widget's own family when it is no longer installed.
private struct WidgetFontMenu: View {
  let widget: DesktopWidget

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let model = controller.widgetsSettings
    let id = widget.id
    let families = model.fontFamilies()
    Picker(
      selection: Binding(
        get: { model.value(id, "font", saved: widget.font) },
        set: { model.commit(id, "font", to: $0) { .font($0) } })
    ) {
      Section(L("System")) {
        ForEach(DesktopWidget.Typeface.allCases, id: \.self) { design in
          Text(verbatim: WidgetsSettingsSection.title(of: design)).tag(DesktopWidget.FontChoice.system(design))
        }
      }
      Section(L("Installed fonts")) {
        if let own = widget.fontFamily, !families.contains(own) {
          Text(verbatim: L("\(own) (not installed)")).tag(DesktopWidget.FontChoice.family(own))
        }
        ForEach(families, id: \.self) { family in
          Text(verbatim: family).tag(DesktopWidget.FontChoice.family(family))
        }
      }
    } label: {
      EmptyView()
    }
    .pickerStyle(.menu)
    .labelsHidden()
    // A pop-up is as wide as its longest font name otherwise.
    .frame(maxWidth: 240)
    .settingsRowAccessibility(row)
    .controlSize(.small)
  }
}
