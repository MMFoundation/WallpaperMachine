import AppKit
import Foundation
import Observation

/// One pane of the Desktop Widgets inspector, which shows the selected widget's controls a pane at a
/// time beside the canvas, so none of them is a long scroll away from the picture they change.
enum DesktopWidgetPane: String, CaseIterable, Identifiable, Sendable {
  /// What the widget says: its format, words, time zone, day.
  case content
  /// The letters: size, font, weight, spacing, case.
  case text
  /// The finished looks, the colours and the effects.
  case style
  /// Where it is: display, place, alignment and turn.
  case position

  var id: String { rawValue }

  /// The panes a widget of `kind` has: a battery and a month calendar say nothing of their own,
  /// and an image sticker has no typography pane.
  static func panes(for kind: DesktopWidget.Kind) -> [DesktopWidgetPane] {
    switch kind {
    case .battery, .calendar: [.text, .style, .position]
    case .image: [.content, .style, .position]
    default: allCases
    }
  }
}

/// Page state of Settings › Desktop Widgets that must outlive the page being rebuilt: which widget the
/// editor shows, which pane of the inspector is open, and where a widget being dragged, resized or
/// turned on the canvas is before it is let go. It reads the widgets from
/// `controller.desktopWidgets` and acts through the controller's typed actions.
@MainActor
@Observable
final class DesktopWidgetsSettingsModel {
  typealias Screen = DesktopWidgetController.Screen

  /// A snapshot of the Desktop Widgets list and selection, stored by the workspace's scoped
  /// Undo/Redo stack (`DesktopWidgetStore.limit` caps each snapshot at 24 lightweight structs).
  struct HistorySnapshot: Equatable, Sendable {
    var widgets: [DesktopWidget]
    var selectedID: String?
  }

  /// An in-flight inspector slider drag preview applied to `shown(_:)` on the canvas without
  /// writing to preferences on every tick.
  struct SliderPreview: Equatable, Sendable {
    var id: String
    var change: DesktopWidgetChange
  }

  /// Maximum number of undo steps kept in memory for the Desktop Widgets workspace.
  static let historyLimit = 40
  /// Consecutive updates on the same continuous control within this interval coalesce into one
  /// undo step (color wheel dragging, text typing, arrow-key nudges, and slider key stepping).
  static let coalesceWindow: TimeInterval = 0.8

  private struct CoalesceState {
    var key: String
    var lastEdit: Date
  }

  /// A widget being dragged on the preview, where the pointer has taken it so far, and the guides
  /// it snapped to there; or one being resized or turned by its handles, with its size or turn so
  /// far.
  struct Drag: Equatable {
    var id: String
    var x: Double
    var y: Double
    var size: Int? = nil
    var rotation: Int? = nil
    var guides: [DesktopWidgetSnapping.Guide] = []
  }

  /// What a drag keeps from its start: where the widget was, its size and turn, and the frames of
  /// the widgets it can line up with, in the display's points.
  private struct DragStart {
    var id: String
    var x: Double
    var y: Double
    var size: Int
    var rotation: Int
    var others: [CGRect]
  }

  /// The inspector's pane the person chose last; a widget without it shows its first pane.
  var pane = DesktopWidgetPane.content

  /// The pane the inspector shows for `widget`.
  func pane(for widget: DesktopWidget) -> DesktopWidgetPane {
    let panes = DesktopWidgetPane.panes(for: widget.kind)
    return panes.contains(pane) ? pane : panes.first ?? .text
  }

  unowned let controller: PanelController
  private var chosenID: String?
  /// The display chosen in the workspace's preview-display switcher; nil while the canvas follows
  /// the selected widget's pinned display (or the main display).
  private(set) var previewDisplayID: UInt32?
  /// Visual styling copied with Copy Style, ready to paste onto another widget.
  private(set) var copiedStyle: DesktopWidget.Style?
  /// Scoped Undo/Redo snapshots; never registered in the window-wide `UndoManager`.
  private(set) var undoStack: [HistorySnapshot] = []
  private(set) var redoStack: [HistorySnapshot] = []
  /// Live preview of a slider being dragged in the inspector; nil when none is dragging.
  private(set) var sliderPreview: SliderPreview?
  /// Which kind of visibility scope a widget uses.
  enum ScopeMode: String, CaseIterable, Hashable, Sendable {
    case everywhere
    case wallpapers
    case spaces
  }

  /// One desktop Space shown in the widget's Scope inspector.
  struct ScopeDesktop: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let isCurrent: Bool
  }

  /// True while the Ready-made widgets popover is presented; included in `ShellModel.isPopoverOpen`
  /// so workspace shortcuts and canvas Delete do not fire behind it.
  var isReadyMadePopoverOpen = false
  /// True while a widget scope popover (wallpaper chooser) is presented.
  var isScopePopoverOpen = false
  var hasOpenPopover: Bool { isReadyMadePopoverOpen || isScopePopoverOpen }
  /// The drag in progress on the preview; nil when none is.
  var drag: Drag?
  @ObservationIgnored private var dragStart: DragStart?
  @ObservationIgnored private var activeTransaction: HistorySnapshot?
  @ObservationIgnored private var lastCoalesce: CoalesceState?
  @ObservationIgnored private var isRestoringHistory = false
  /// Clock seam so unit tests verify coalescing windows deterministically.
  @ObservationIgnored var now: () -> Date = Date.init
  /// Managed image store for `.image` stickers (resolves `ClientPaths.userAssetsURL` dynamically).
  @ObservationIgnored var imageStore = DesktopWidgetImageStore()
  @ObservationIgnored private let formatters = DesktopWidgetRendering.Formatters()

  init(controller: PanelController) { self.controller = controller }

  var widgets: [DesktopWidget] { controller.desktopWidgets.widgets }

  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }
  var canPasteStyle: Bool { copiedStyle != nil }

  /// True while Settings › Desktop Widgets is the active foreground workspace, with no Settings
  /// search, welcome guide, or popover covering it.
  var isWorkspaceActiveForShortcuts: Bool {
    controller.navigation.selection == .settings
      && controller.settings.selectedSection == .widgets
      && !controller.settings.search.isActive
      && !controller.shell.isWelcomeOpen
      && !controller.shell.isPopoverOpen
  }

  /// Opens Settings › Displays where the Sunrise and sunset location is configured.
  @discardableResult
  func openSunLocationSettings() -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("openSettings")) { [controller] in
      try await controller.openSettings(.displays)
    }
  }

  /// The selected widget's id when `⌘D` in the workspace should duplicate it: under the store
  /// limit and visible on the currently previewed display.
  func duplicableSelectedID() -> String? {
    guard widgets.count < DesktopWidgetStore.limit,
      let selectedID,
      let screen = previewScreen(among: screens()),
      widgets(on: screen).contains(where: { $0.id == selectedID })
    else { return nil }
    return selectedID
  }

  // MARK: Scoped Undo / Redo

  /// Captures the current widgets and selection for Undo/Redo.
  func currentSnapshot() -> HistorySnapshot {
    HistorySnapshot(widgets: widgets, selectedID: selectedID)
  }

  /// Begins a coalesced gesture transaction (canvas drag, handle resize/rotate, or slider drag),
  /// capturing one pre-gesture snapshot if none is open yet.
  func beginTransaction() {
    guard activeTransaction == nil else { return }
    activeTransaction = currentSnapshot()
  }

  /// Finishes an open gesture transaction, pushing one undo step (and clearing redo) only if the
  /// stored widgets actually changed from the pre-gesture snapshot.
  func endTransaction() {
    guard let before = activeTransaction else { return }
    activeTransaction = nil
    guard widgets != before.widgets else { return }
    pushUndo(before)
    let droppedRedo = !redoStack.isEmpty
    redoStack.removeAll()
    lastCoalesce = nil
    if droppedRedo { pruneUnusedImages() }
  }

  /// Discards an open gesture transaction without recording an undo step.
  func cancelTransaction() {
    activeTransaction = nil
  }

  /// Pops and returns any open gesture transaction's pre-gesture snapshot so an async commit can
  /// record it atomically without leaving `activeTransaction` open across suspension points.
  func takeActiveTransaction() -> HistorySnapshot? {
    defer { activeTransaction = nil }
    return activeTransaction
  }

  /// Runs a Desktop Widgets store mutation and records it in the scoped Undo stack.
  ///
  /// - When a gesture transaction is open (`activeTransaction != nil`), intermediate writes are
  ///   suppressed until `endTransaction()` commits the single pre-gesture snapshot.
  /// - When `coalesceKey` matches the previous edit within `coalesceWindow`, the top undo entry is
  ///   kept instead of pushing another snapshot (or popped if the edit returned to that snapshot).
  /// - A mutation that throws or leaves `widgets` unchanged records nothing and leaves `redoStack`
  ///   intact.
  func recordMutation(
    coalesceKey: String? = nil,
    preSnapshot: HistorySnapshot? = nil,
    _ mutate: () throws -> Void
  ) throws {
    if isRestoringHistory || activeTransaction != nil {
      try mutate()
      return
    }
    let before = preSnapshot ?? currentSnapshot()
    try mutate()
    guard widgets != before.widgets else { return }
    let timestamp = now()
    if let coalesceKey, let previous = lastCoalesce, previous.key == coalesceKey,
      timestamp.timeIntervalSince(previous.lastEdit) <= Self.coalesceWindow,
      let top = undoStack.last
    {
      let droppedRedo = !redoStack.isEmpty
      redoStack.removeAll()
      if top.widgets == widgets {
        undoStack.removeLast()
        lastCoalesce = nil
      } else {
        lastCoalesce = CoalesceState(key: coalesceKey, lastEdit: timestamp)
      }
      if droppedRedo { pruneUnusedImages() }
      return
    }
    pushUndo(before)
    let droppedRedo = !redoStack.isEmpty
    redoStack.removeAll()
    lastCoalesce = coalesceKey.map { CoalesceState(key: $0, lastEdit: timestamp) }
    if droppedRedo { pruneUnusedImages() }
  }

  /// Restores the most recent undo snapshot and pushes the current state onto the redo stack.
  func undo() throws {
    cancelPendingInteraction()
    guard let target = undoStack.popLast() else { return }
    let current = currentSnapshot()
    isRestoringHistory = true
    defer { isRestoringHistory = false }
    do {
      try controller.desktopWidgets.restore(target.widgets)
    } catch {
      undoStack.append(target)
      throw error
    }
    pushRedo(current)
    lastCoalesce = nil
    restoreSelection(target.selectedID)
  }

  /// Reapplies the most recently undone snapshot and pushes the current state onto the undo stack.
  func redo() throws {
    cancelPendingInteraction()
    guard let target = redoStack.popLast() else { return }
    let current = currentSnapshot()
    isRestoringHistory = true
    defer { isRestoringHistory = false }
    do {
      try controller.desktopWidgets.restore(target.widgets)
    } catch {
      redoStack.append(target)
      throw error
    }
    pushUndo(current)
    lastCoalesce = nil
    restoreSelection(target.selectedID)
  }

  /// Updates the live in-memory canvas preview for a slider being dragged in the inspector.
  func setSliderPreview(id: String, change: DesktopWidgetChange) {
    sliderPreview = SliderPreview(id: id, change: change)
  }

  /// Clears any active inspector slider preview.
  func clearSliderPreview() {
    sliderPreview = nil
  }

  private func cancelPendingInteraction() {
    drag = nil
    dragStart = nil
    sliderPreview = nil
    activeTransaction = nil
  }

  private func pushUndo(_ snapshot: HistorySnapshot) {
    undoStack.append(snapshot)
    if undoStack.count > Self.historyLimit {
      undoStack.removeFirst(undoStack.count - Self.historyLimit)
    }
  }

  private func pushRedo(_ snapshot: HistorySnapshot) {
    redoStack.append(snapshot)
    if redoStack.count > Self.historyLimit {
      redoStack.removeFirst(redoStack.count - Self.historyLimit)
    }
  }

  private func restoreSelection(_ id: String?) {
    if let id, widgets.contains(where: { $0.id == id }) {
      select(id)
    } else if widgets.isEmpty {
      chosenID = nil
      isSelectionCleared = false
    } else {
      isSelectionCleared = true
    }
  }

  /// Copies the visual styling of `widget` without its kind, content, geometry or display placement.
  func copyStyle(of widget: DesktopWidget) {
    copiedStyle = DesktopWidget.Style(from: widget)
  }

  /// Applies the copied visual style to `id`; nil when nothing has been copied yet.
  @discardableResult
  func pasteStyle(to id: String) -> Task<Void, Never>? {
    guard let copiedStyle else { return nil }
    return controller.launch(PanelActionCoordinator.key("pasteDesktopWidgetStyle", id: id)) { [controller] in
      try await controller.changeDesktopWidget(id, .applyStyle(copiedStyle))
    }
  }

  /// Whether a click on the canvas's backdrop has put the selection away, so the canvas shows the
  /// widgets as the desktop will, with no outline or handles over them. Picking a widget ends it.
  private(set) var isSelectionCleared = false

  /// The widget the editor shows: the one chosen, else the first; none while the selection is
  /// cleared.
  var selected: DesktopWidget? { isSelectionCleared ? nil : lastChosen }

  /// The one chosen, else the first, also while the selection is cleared: the canvas stays on its
  /// display, and the search results keep editing it.
  var lastChosen: DesktopWidget? {
    let widgets = widgets
    return widgets.first { $0.id == chosenID } ?? widgets.first
  }

  var selectedID: String? { selected?.id }

  /// Selects `id` for the inspector and canvas. Picking a widget pinned to a specific other
  /// connected display switches the preview to that display; picking an `.all`, `.main`, or
  /// disconnected widget keeps any manually chosen preview display intact.
  func select(_ id: String?) {
    chosenID = id
    isSelectionCleared = false
    if let id, let widget = widgets.first(where: { $0.id == id }) {
      followPinnedPlacementIfOtherDisplay(widget.placement)
    }
  }

  /// Selects nothing, to see the widgets without the selection drawn over them.
  func clearSelection() { isSelectionCleared = true }

  /// Follows the selected widget when its placement is explicitly changed to another connected
  /// display in the inspector.
  func didChangeSelectedPlacement(_ placement: DesktopWidget.Placement) {
    followPinnedPlacementIfOtherDisplay(placement)
  }

  private func followPinnedPlacementIfOtherDisplay(_ placement: DesktopWidget.Placement) {
    guard case .display(let uuid, _) = placement,
      let own = screens().first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }),
      previewDisplayID != own.displayID
    else { return }
    previewDisplayID = nil
  }

  /// `widget` where the preview draws it: where a drag has it, at the size and turn its handles
  /// have it, with any in-flight inspector slider preview, or as it was let go while that is being
  /// saved.
  func shown(_ widget: DesktopWidget) -> DesktopWidget {
    var moved = widget
    moved.size = value(widget.id, "size", saved: widget.size)
    moved.rotation = value(widget.id, "rotation", saved: widget.rotation)
    if let drag, drag.id == widget.id {
      moved.x = drag.x
      moved.y = drag.y
      if let size = drag.size { moved.size = size }
      if let rotation = drag.rotation { moved.rotation = rotation }
    } else {
      let position = value(widget.id, "position", saved: [widget.x, widget.y])
      moved.x = position[0]
      moved.y = position[1]
    }
    if let sliderPreview, sliderPreview.id == widget.id {
      sliderPreview.change.apply(to: &moved)
      moved = moved.clamped()
    }
    return moved
  }

  // MARK: Displays

  /// The connected displays, the main one first.
  func screens() -> [Screen] {
    controller.desktopWidgetScreens().sorted { $0.isMain && !$1.isMain }
  }

  /// Manually picks the display the workspace's canvas previews. Persists across selection changes
  /// until another display is picked or a widget pinned to a different connected display is selected.
  func selectPreviewScreen(_ displayID: UInt32) {
    previewDisplayID = displayID
  }

  /// The display the workspace's canvas shows: the user's manually chosen preview display when
  /// still connected, else the last chosen widget's pinned display, else the main display.
  func previewScreen(among screens: [Screen]) -> Screen? {
    if let previewDisplayID,
      let chosen = screens.first(where: { $0.displayID == previewDisplayID }) {
      return chosen
    }
    if let widget = lastChosen {
      return previewScreen(for: widget, among: screens)
    }
    return screens.first(where: \.isMain) ?? screens.first
  }

  /// The display's name in the preview switcher, disambiguated with a number when two displays
  /// share a name.
  func previewScreenTitle(_ screen: Screen, among screens: [Screen]) -> String {
    let matching = screens.filter { $0.name == screen.name }
    guard matching.count > 1,
      let index = matching.firstIndex(where: { $0.displayID == screen.displayID })
    else { return screen.name }
    return "\(screen.name) \(index + 1)"
  }

  /// The placement a newly added widget or preset defaults to: the currently previewed display
  /// when it is a non-main display with a UUID, else `.main`.
  func defaultPlacement(among screens: [Screen]? = nil) -> DesktopWidget.Placement {
    let list = screens ?? self.screens()
    guard let screen = previewScreen(among: list), !screen.isMain, let uuid = screen.uuid else {
      return .main
    }
    return .display(uuid: uuid, name: screen.name)
  }

  /// The display the preview shows for `widget`: its own when it has one and it is connected, else
  /// the main one.
  func previewScreen(for widget: DesktopWidget, among screens: [Screen]) -> Screen? {
    if case .display(let uuid, _) = widget.placement,
      let own = screens.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
      return own
    }
    return screens.first(where: \.isMain) ?? screens.first
  }

  /// The widgets the preview of `screen` draws, back to front as the desktop stacks them. The
  /// selected one is drawn while it is hidden too, so it can still be arranged; the picture fades
  /// it.
  func widgets(on screen: Screen) -> [DesktopWidget] {
    let selectedID = selectedID
    return widgets.reversed()
      .filter {
        ($0.isShown || $0.id == selectedID) && $0.isPlaced(onDisplayUUID: screen.uuid, isMain: screen.isMain)
      }
  }

  /// The Display menu: the main display, every display, each connected one by name, and the
  /// widget's own display when it is not connected.
  func placementOptions(for widget: DesktopWidget, among screens: [Screen]) -> [SettingsMenuOption<DesktopWidget.Placement>] {
    var options: [SettingsMenuOption<DesktopWidget.Placement>] = [
      .init(value: .main, title: L("Main display")),
      .init(value: .all, title: L("All displays")),
    ]
    for screen in screens {
      guard let uuid = screen.uuid else { continue }
      options.append(.init(value: .display(uuid: uuid, name: screen.name), title: screen.name))
    }
    if case .display(let uuid, let name) = widget.placement,
      !screens.contains(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
      options.append(.init(value: widget.placement, title: L("\(name) (not connected)")))
    }
    return options
  }

  /// The menu's value for the widget's display: a display chosen under an earlier name still
  /// selects its entry.
  func placementValue(for widget: DesktopWidget, among screens: [Screen]) -> DesktopWidget.Placement {
    guard case .display(let uuid, _) = widget.placement,
      let screen = screens.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }),
      let own = screen.uuid
    else { return widget.placement }
    return .display(uuid: own, name: screen.name)
  }

  /// Where the widget is shown, for its line in the list.
  func placementTitle(for widget: DesktopWidget, among screens: [Screen]) -> String {
    let value = placementValue(for: widget, among: screens)
    return placementOptions(for: widget, among: screens).first { $0.value == value }?.title ?? ""
  }

  // MARK: Words

  /// What the widgets are drawn from now: this Mac's clock, language and region, the battery
  /// level the panel last read, the sunrise and sunset settings, sample media and managed stickers.
  func inputs(at date: Date = Date()) -> DesktopWidgetRendering.Inputs {
    let store = imageStore
    return .init(
      date: date, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent,
      battery: controller.batteryPercent.map { BatteryReading(percent: $0, isDischarging: true) },
      solar: controller.automations.solar,
      isPreview: true,
      resolveImage: { store.loadImage(for: $0) })
  }

  // MARK: Scope & images

  func scopeMode(for widget: DesktopWidget) -> ScopeMode {
    switch widget.scope {
    case .everywhere: .everywhere
    case .wallpapers: .wallpapers
    case .spaces: .spaces
    }
  }

  /// Active wallpaper ID shown on `displayID`, or nil when none is active.
  func activeWallpaperID(on displayID: UInt32) -> String? {
    frameRequest(on: displayID)?.wallpaperID
  }

  /// Default `DesktopWidget.Scope` when switching visibility mode in the inspector: seeds the
  /// previewed display's current wallpaper or current Space when known so binding is one click.
  func defaultScope(for mode: ScopeMode, widget: DesktopWidget, among screens: [Screen]) -> DesktopWidget.Scope {
    let screen = previewScreen(for: widget, among: screens) ?? previewScreen(among: screens)
    switch mode {
    case .everywhere:
      return .everywhere
    case .wallpapers:
      if case .wallpapers(let existing) = widget.scope { return .wallpapers(existing) }
      if let displayID = screen?.displayID, let active = activeWallpaperID(on: displayID) {
        return .wallpapers([active])
      }
      return .wallpapers([])
    case .spaces:
      if case .spaces(let existing) = widget.scope { return .spaces(existing) }
      let info = scopeDesktops(for: widget, among: screens)
      if let current = info.currentID { return .spaces([current]) }
      return .spaces([])
    }
  }

  /// Available macOS desktop Spaces for `widget`'s display, observing Space topology changes.
  func scopeDesktops(
    for widget: DesktopWidget, among screens: [Screen]
  ) -> (available: Bool, desktops: [ScopeDesktop], currentID: String?) {
    _ = controller.revisions.spaces
    guard controller.spaces.available else { return (false, [], nil) }
    let screen = previewScreen(for: widget, among: screens) ?? previewScreen(among: screens)
    let displaySpaces: WallpaperDisplaySpaces? =
      screen.flatMap { controller.spaces.displays[String($0.displayID)] }
      ?? controller.spaces.displays.values.first
    guard let displaySpaces else { return (false, [], nil) }
    let desktops = displaySpaces.spaces.map { space in
      ScopeDesktop(id: space.id, number: space.number, isCurrent: space.id == displaySpaces.current)
    }
    return (true, desktops, displaySpaces.current)
  }

  /// Short scope label for the Layers list and inspector header; nil for `.everywhere`.
  func scopeSummary(for widget: DesktopWidget, among screens: [Screen]) -> String? {
    switch widget.scope {
    case .everywhere:
      return nil
    case .wallpapers(let ids):
      if ids.isEmpty { return L("No wallpapers") }
      if ids.count == 1 { return L("1 wallpaper") }
      return L("\(ids.count) wallpapers")
    case .spaces(let ids):
      if ids.isEmpty { return L("No desktops") }
      if ids.count == 1, let id = ids.first {
        let info = scopeDesktops(for: widget, among: screens)
        if let desktop = info.desktops.first(where: { $0.id == id }) {
          return L("Desktop \(desktop.number)")
        }
        return L("1 desktop")
      }
      return L("\(ids.count) desktops")
    }
  }

  func wallpaperTitle(for wallpaperID: String) -> String {
    if let title = controller.automationTargets.wallpapers.first(where: { $0.target.id == wallpaperID })?.title {
      return title
    }
    if let row = controller.libraryRow(id: wallpaperID) { return row.title }
    return L("Unavailable wallpaper")
  }

  /// Asset IDs referenced by any live widget or Undo/Redo snapshot so undo never loses a sticker.
  func referencedImageAssetIDs() -> Set<String> {
    var ids = Set(widgets.compactMap { $0.imageAsset?.assetID })
    for snapshot in undoStack {
      ids.formUnion(snapshot.widgets.compactMap { $0.imageAsset?.assetID })
    }
    for snapshot in redoStack {
      ids.formUnion(snapshot.widgets.compactMap { $0.imageAsset?.assetID })
    }
    return ids
  }

  /// Reclaims stored sticker images no longer referenced by any live widget or Undo/Redo snapshot.
  func pruneUnusedImages() {
    imageStore.pruneUnused(keeping: referencedImageAssetIDs())
  }

  /// What the widget shows at `date`, as the desktop draws it, at `scale` times its size.
  func content(for widget: DesktopWidget, at date: Date = Date(), scale: CGFloat = 1)
    -> DesktopWidgetRendering.Content
  {
    DesktopWidgetRendering.content(for: widget, inputs: inputs(at: date), formatters: formatters, scale: scale)
  }

  /// What the widget says at `date`, on one line: the first line of a text widget, the month of
  /// a calendar, the time a clock face shows.
  func text(for widget: DesktopWidget, at date: Date = Date()) -> String {
    let text = DesktopWidgetRendering.text(for: widget, inputs: inputs(at: date), formatters: formatters)
    return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }

  /// The Date format menu, each style written out for today.
  func dateStyleOptions(for widget: DesktopWidget, at date: Date = Date()) -> [SettingsMenuOption<DesktopWidget.DateStyle>] {
    DesktopWidget.DateStyle.allCases.map { style in
      var sample = widget
      sample.dateStyle = style
      sample.text = ""
      return .init(value: style, title: text(for: sample, at: date))
    }
  }

  /// The Calendar menu: the region's own calendar, then the others by their names in the panel's
  /// language.
  func calendarOptions() -> [SettingsMenuOption<DesktopWidget.CalendarSystem>] {
    let locale = PanelLocale.shared.locale
    return DesktopWidget.CalendarSystem.allCases.map { system in
      guard let identifier = system.identifier else { return .init(value: system, title: L("Follow system")) }
      return .init(value: system, title: locale.localizedString(for: identifier) ?? "\(identifier)")
    }
  }

  /// The time zones the Time zone menu offers: one for each offset people live at, by a city in it.
  static let timeZones = [
    "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Chicago",
    "America/Mexico_City", "America/New_York", "America/Toronto", "America/Bogota", "America/Halifax",
    "America/Sao_Paulo", "America/Argentina/Buenos_Aires", "Atlantic/Reykjavik", "UTC", "Europe/London",
    "Europe/Lisbon", "Africa/Lagos", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome",
    "Europe/Amsterdam", "Europe/Stockholm", "Europe/Athens", "Africa/Cairo", "Africa/Johannesburg",
    "Europe/Istanbul", "Europe/Moscow", "Africa/Nairobi", "Asia/Tehran", "Asia/Dubai", "Asia/Karachi",
    "Asia/Kolkata", "Asia/Kathmandu", "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Ho_Chi_Minh",
    "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Singapore", "Asia/Manila", "Asia/Seoul",
    "Asia/Tokyo", "Australia/Perth", "Australia/Adelaide", "Australia/Brisbane", "Australia/Sydney",
    "Pacific/Auckland",
  ]

  /// The Time zone menu: this Mac's own, then each city by its offset from GMT now, and the
  /// widget's own zone when the list does not have it.
  func timeZoneOptions(for widget: DesktopWidget, at date: Date = Date()) -> [SettingsMenuOption<String?>] {
    var identifiers = Self.timeZones
    if let own = widget.timeZone, !identifiers.contains(own), DesktopWidget.validTimeZone(own) {
      identifiers.append(own)
    }
    let zones = identifiers.compactMap(TimeZone.init(identifier:))
      .sorted { ($0.secondsFromGMT(for: date), city($0.identifier)) < ($1.secondsFromGMT(for: date), city($1.identifier)) }
    return [.init(value: nil, title: L("Follow system"))]
      + zones.map { zone in
        .init(value: zone.identifier, title: "\(city(zone.identifier)) (\(offset(zone, at: date)))")
      }
  }

  /// A time zone's city in the panel's language, such as Tokyo for Asia/Tokyo.
  func city(_ identifier: String) -> String {
    guard identifier != "UTC", let zone = TimeZone(identifier: identifier) else { return identifier }
    let formatter = zoneFormatter
    formatter.locale = PanelLocale.shared.locale
    formatter.timeZone = zone
    formatter.dateFormat = "VVV"
    let name = formatter.string(from: Date())
    return name.isEmpty ? identifier : name
  }

  private func offset(_ zone: TimeZone, at date: Date) -> String {
    let formatter = zoneFormatter
    formatter.locale = PanelLocale.shared.locale
    formatter.timeZone = zone
    formatter.dateFormat = "O"
    return formatter.string(from: date)
  }

  @ObservationIgnored private let zoneFormatter = DateFormatter()

  /// The font families installed on this Mac, by name, without the system's hidden ones. The
  /// font manager is asked the first time the menu is drawn, not on every redraw; a font installed
  /// after that is offered once the app is opened again.
  func fontFamilies() -> [String] {
    if let families { return families }
    let found = NSFontManager.shared.availableFontFamilies
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    families = found
    return found
  }

  @ObservationIgnored private var families: [String]?

  /// A countdown's day as a date for the date picker: its start in this Mac's time zone, or
  /// today's for an unreadable day.
  func targetDate(_ day: String) -> Date {
    DesktopWidget.start(ofDay: day, in: .autoupdatingCurrent) ?? Calendar.autoupdatingCurrent.startOfDay(for: Date())
  }

  /// The still of the wallpaper on a display, for the preview's background; nil when it shows none.
  func wallpaperStill(on displayID: UInt32) -> PanelImageSource? {
    let row = controller.store.monitorInformationSnapshot.rows.first {
      $0.mirrorTargetDisplayId == nil
        && ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == displayID
    }
    guard let id = row?.wallpaperId, !id.isEmpty else { return nil }
    return controller.libraryRow(id: id)?.still
  }

  /// What the preview asks of a display's wallpaper for its frame. A new wallpaper or new files
  /// make a new request.
  struct FrameRequest: Hashable {
    var displayID: UInt32
    var wallpaperID: String
    var contentRevision: UInt64
  }

  /// What the preview has from a display's wallpaper for the request it answers: a frame or none,
  /// and whether it waits for the wallpaper to play past its intro for a settled one.
  struct WallpaperFrame {
    var request: FrameRequest
    var image: CGImage?
    var waitsToSettle = false
  }

  /// The longest edge, in pixels, of a frame the preview keeps: the canvas grows with the window, and
  /// this keeps it sharp on a Retina display up to about 1,000 points wide.
  static let framePixels = 2048

  /// What each display's wallpaper last gave the preview.
  private(set) var wallpaperFrames: [UInt32: WallpaperFrame] = [:]
  /// Waits before the wallpaper is asked again; tests pass one that does not wait.
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  /// The request for the frame of the wallpaper on a display; nil while it shows none.
  func frameRequest(on displayID: UInt32) -> FrameRequest? {
    let rows = controller.store.monitorInformationSnapshot.rows.filter {
      ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == displayID
    }
    let row = rows.first { $0.mirrorTargetDisplayId == nil } ?? rows.first
    guard let id = row?.wallpaperId, !id.isEmpty else { return nil }
    return FrameRequest(
      displayID: displayID, wallpaperID: id, contentRevision: controller.store.wallpaperContentRevision)
  }

  /// What the preview of a display has from the wallpaper it shows now; nil before it answered,
  /// or when its answer was for the wallpaper before.
  private func currentFrame(on displayID: UInt32) -> WallpaperFrame? {
    guard let frame = wallpaperFrames[displayID],
      frame.request.wallpaperID == frameRequest(on: displayID)?.wallpaperID
    else { return nil }
    return frame
  }

  /// The frame the preview of a display draws behind its widgets: one of the wallpaper it shows
  /// now, its first until a settled one comes; nil otherwise, and the still stands in.
  func wallpaperFrame(on displayID: UInt32) -> CGImage? { currentFrame(on: displayID)?.image }

  /// Whether the preview of a display shows the still because its wallpaper has not played long
  /// enough for a frame past its intro or fade-in, and gave no first frame (or a blank one).
  func waitsForWallpaperToSettle(on displayID: UInt32) -> Bool {
    currentFrame(on: displayID).map { $0.image == nil && $0.waitsToSettle } ?? false
  }

  /// Asks the display's wallpaper for a frame: the preview's background is the desktop as it is,
  /// not the author's preview image. A wallpaper still in its intro shows its first frame at once
  /// and is asked again when it can have settled: after the rest of the settle window while it
  /// plays, else when it next starts playing where it can be seen (a wallpaper paused because the
  /// panel covers the desktop does not move on). The caller's task ends with the row, and the wait
  /// with it.
  func loadWallpaperFrame(_ request: FrameRequest) async {
    guard let read = controller.store.wallpaperFrame else { return }
    while !Task.isCancelled {
      let answer = await read(request.displayID, Self.framePixels)
      guard !Task.isCancelled else { return }
      switch answer {
      case .frame(let image):
        wallpaperFrames[request.displayID] = WallpaperFrame(request: request, image: image)
        return
      case .unavailable:
        wallpaperFrames[request.displayID] = WallpaperFrame(request: request, image: nil)
        return
      case .unsettled(let first, let retryAfter):
        // A later first frame replaces an earlier one; none keeps it.
        let shown = wallpaperFrames[request.displayID].flatMap { $0.request == request ? $0.image : nil }
        wallpaperFrames[request.displayID] = WallpaperFrame(
          request: request, image: first ?? shown, waitsToSettle: true)
        if let retryAfter {
          // A moment past the window, so the wallpaper has settled when it is asked.
          do { try await sleep(retryAfter + .milliseconds(250)) } catch { return }
        } else if let change = controller.store.wallpaperSettleChange {
          await change(request.displayID)
        } else {
          return
        }
      }
    }
  }

  // MARK: Editing

  /// The key a widget's control tracks its change under, for its draft and `isBusy`.
  static func key(_ id: String, _ control: String) -> String { "widget.\(id).\(control)" }

  /// Sends the change a control made, showing `value` until it has run. Returns the change's task,
  /// nil when a repeat was dropped.
  @discardableResult
  func commit<Value: Hashable>(
    _ id: String, _ control: String, to value: Value, policy: PanelActionCoordinator.Policy = .latestWins,
    coalesceKey: String? = nil,
    preSnapshot: HistorySnapshot? = nil,
    _ change: @escaping (Value) -> DesktopWidgetChange
  ) -> Task<Void, Never>? {
    controller.settings.commit(Self.key(id, control), to: value, policy: policy) { [controller] value in
      try await controller.changeDesktopWidget(
        id, change(value), coalesceKey: coalesceKey, preSnapshot: preSnapshot)
    }
  }

  /// The value a control shows: what it just sent while that is on its way, otherwise `saved`.
  func value<Value: Hashable>(_ id: String, _ control: String, saved: Value) -> Value {
    controller.settings.value(Self.key(id, control), saved: saved)
  }

  /// Ends a drag on the preview where it was let go, and saves that position, or the size or turn
  /// a handle gave it, as a single undoable step. The draft shows it until it is saved, so the
  /// widget does not jump back meanwhile.
  @discardableResult
  func endDrag() -> Task<Void, Never>? {
    dragStart = nil
    guard let drag else {
      cancelTransaction()
      return nil
    }
    self.drag = nil
    let preSnapshot = takeActiveTransaction()
    if let size = drag.size {
      return commit(drag.id, "size", to: size, preSnapshot: preSnapshot) { .size($0) }
    }
    if let rotation = drag.rotation {
      return commit(drag.id, "rotation", to: rotation, preSnapshot: preSnapshot) { .rotation($0) }
    }
    return commit(drag.id, "position", to: [drag.x, drag.y], preSnapshot: preSnapshot) {
      .position(x: $0[0], y: $0[1])
    }
  }

  // MARK: Resizing and turning

  /// Keeps what a handle's drag starts from, selects the widget, and opens one undo transaction.
  private func beginTransform(_ widget: DesktopWidget) -> DragStart {
    if let start = dragStart, start.id == widget.id, drag?.id == widget.id { return start }
    let shown = shown(widget)
    let start = DragStart(
      id: widget.id, x: shown.x, y: shown.y, size: shown.size, rotation: shown.rotation, others: [])
    dragStart = start
    if selectedID != widget.id { select(widget.id) }
    beginTransaction()
    return start
  }

  /// Resizes a widget by a corner handle: its size at the start of the drag times `factor`, the
  /// pointer's distance from the widget's middle over its distance there at the start.
  func resize(_ widget: DesktopWidget, by factor: CGFloat) {
    let start = beginTransform(widget)
    drag = Drag(id: widget.id, x: start.x, y: start.y, size: Self.size(start.size, scaledBy: factor))
  }

  /// Turns a widget by its turn handle: its turn at the start of the drag plus `degrees`. With
  /// `snaps` the turn settles on a multiple of 15° within a few degrees of one.
  func rotate(_ widget: DesktopWidget, by degrees: CGFloat, snaps: Bool) {
    let start = beginTransform(widget)
    drag = Drag(
      id: widget.id, x: start.x, y: start.y,
      rotation: Self.rotation(CGFloat(start.rotation) + degrees, snaps: snaps))
  }

  /// Moves a widget by `points` of its display, as an arrow key on the canvas does, and saves it.
  /// Consecutive arrow nudges on the same widget coalesce into one undo step.
  @discardableResult
  func nudge(_ widget: DesktopWidget, by points: CGSize, on screen: Screen) -> Task<Void, Never>? {
    let display = screen.frame.size
    guard display.width > 0, display.height > 0 else { return nil }
    let shown = shown(widget)
    let x = min(max(shown.x + points.width / display.width, 0), 1)
    let y = min(max(shown.y + points.height / display.height, 0), 1)
    if selectedID != widget.id { select(widget.id) }
    return commit(widget.id, "position", to: [x, y], coalesceKey: "nudge.\(widget.id)") {
      .position(x: $0[0], y: $0[1])
    }
  }

  /// A size `factor` times `start`, in whole points inside the size's range.
  static func size(_ start: Int, scaledBy factor: CGFloat) -> Int {
    let range = DesktopWidget.sizeRange
    guard factor.isFinite, factor > 0 else { return start }
    return min(max(Int((CGFloat(start) * factor).rounded()), range.lowerBound), range.upperBound)
  }

  /// The snap of a turn: within this many degrees of a multiple of 15°, it goes there.
  static let rotationSnap: CGFloat = 4

  /// A turn of `degrees`, brought into −180° to 180° and whole degrees; with `snaps` it settles on
  /// a multiple of 15° within `rotationSnap` of one.
  static func rotation(_ degrees: CGFloat, snaps: Bool) -> Int {
    guard degrees.isFinite else { return 0 }
    var turn = degrees.truncatingRemainder(dividingBy: 360)
    if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
    if snaps {
      let nearest = (turn / 15).rounded() * 15
      if abs(nearest - turn) <= rotationSnap { turn = nearest }
    }
    let range = DesktopWidget.rotationRange
    return min(max(Int(turn.rounded()), range.lowerBound), range.upperBound)
  }

  /// The direction of `point` from `center` in a picture whose y grows downwards, in degrees
  /// clockwise from straight up, as a widget's turn is measured.
  static func angle(of point: CGPoint, around center: CGPoint) -> CGFloat {
    atan2(point.x - center.x, center.y - point.y) * 180 / .pi
  }

  // MARK: Ready-made widgets

  /// The display a ready-made widget is laid out for: the currently previewed one, else the main
  /// one, or a common laptop's when none is known.
  func presetDisplay() -> CGSize {
    let screens = screens()
    let size = previewScreen(among: screens)?.frame.size ?? .zero
    return size.width > 0 && size.height > 0 ? size : CGSize(width: 1512, height: 982)
  }

  /// A ready-made preset's widgets, laid out for the currently previewed display as the desktop
  /// will draw them.
  func widgets(of preset: DesktopWidgetPreset, at date: Date = Date()) -> [DesktopWidget] {
    let display = presetDisplay()
    return preset.widgets(
      on: display, measure: { self.frame(of: $0, in: display, scale: 1).size }, city: { self.city($0) },
      today: date)
  }

  // MARK: Arranging

  /// Where `widget` lies in a picture of `size` drawn at `scale` times the display: its frame in
  /// the picture's points, top-left origin.
  func frame(of widget: DesktopWidget, in size: CGSize, scale: CGFloat) -> CGRect {
    let content = content(for: widget, scale: scale)
    let frame = DesktopWidgetRendering.frame(
      for: content, widget: widget, display: NSRect(origin: .zero, size: size))
    return CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
  }

  /// Moves a widget being dragged on the preview of `screen` (a picture of `size`, at `scale`
  /// times the display) by `translation` from where the drag started, and selects it. With `snaps`
  /// it lines up with the display's centre, thirds and margins and with the other widgets there
  /// when it comes within a few of the picture's points of one (`DesktopWidgetSnapping`). The lines
  /// are worked out on the display itself, where text is laid out at its own size, so a widget
  /// snapped to the centre is centred on the desktop to the point; the guides are scaled to the
  /// picture.
  func drag(
    _ widget: DesktopWidget, by translation: CGSize, in size: CGSize, scale: CGFloat, on screen: Screen,
    snaps: Bool
  ) {
    let display = screen.frame.size
    guard size.width > 0, size.height > 0, display.width > 0, display.height > 0, scale > 0 else { return }
    if dragStart?.id != widget.id || drag?.id != widget.id {
      let start = shown(widget)
      let others = widgets(on: screen).filter { $0.id != widget.id && $0.isShown }
        .map { frame(of: shown($0), in: display, scale: 1) }
      dragStart = DragStart(
        id: widget.id, x: start.x, y: start.y, size: start.size, rotation: start.rotation, others: others)
      if selectedID != widget.id { select(widget.id) }
      beginTransaction()
    }
    guard let start = dragStart else { return }
    var moved = widget
    moved.size = start.size
    moved.rotation = start.rotation
    moved.x = min(max(start.x + translation.width / size.width, 0), 1)
    moved.y = min(max(start.y + translation.height / size.height, 0), 1)
    var guides: [DesktopWidgetSnapping.Guide] = []
    if snaps {
      let snapped = DesktopWidgetSnapping.snap(
        frame(of: moved, in: display, scale: 1), in: display, others: start.others,
        threshold: DesktopWidgetSnapping.threshold / scale)
      moved.x = min(max(moved.x + snapped.offset.width / display.width, 0), 1)
      moved.y = min(max(moved.y + snapped.offset.height / display.height, 0), 1)
      guides = snapped.guides.map { guide in
        var scaled = guide
        scaled.position *= scale
        scaled.start *= scale
        scaled.end *= scale
        return scaled
      }
    }
    drag = Drag(id: widget.id, x: moved.x, y: moved.y, guides: guides)
  }

  /// The position that centres `widget` on `screen` across (`horizontally`) or down: the middle of
  /// what it shows on the display's centre line, whichever edge its alignment holds.
  func centered(_ widget: DesktopWidget, on screen: Screen, horizontally: Bool) -> Double {
    guard horizontally else { return 0.5 }
    let display = screen.frame.size
    guard display.width > 0 else { return widget.x }
    let content = content(for: widget)
    let width = DesktopWidgetRendering.frame(
      for: content, widget: widget, display: NSRect(origin: .zero, size: display)
    ).width
    // A turned widget's frame is its turned box, which the position places without padding.
    let padding = content.look.rotation == 0 ? content.padding : 0
    let anchor: CGFloat =
      switch widget.alignment {
      case .leading: (display.width - width) / 2 + padding
      case .center: display.width / 2
      case .trailing: (display.width + width) / 2 - padding
      }
    return min(max(Double(anchor / display.width), 0), 1)
  }

  /// Whether `widget` is centred on `screen` across or down, to the display's point.
  func isCentered(_ widget: DesktopWidget, on screen: Screen, horizontally: Bool) -> Bool {
    let extent = horizontally ? screen.frame.width : screen.frame.height
    let position = horizontally ? widget.x : widget.y
    return abs(position - centered(widget, on: screen, horizontally: horizontally)) * extent < 1
  }
}

/// Pure keyboard-scope rules for the Desktop Widgets workspace (`⌘Z`, `⇧⌘Z`, `⌘D`) so shortcuts
/// stay strictly inside the workspace (never in Library, Settings search, or text editors).
enum WidgetsWorkspaceShortcuts {
  enum Action: Equatable, Sendable {
    case undo
    case redo
    case duplicate
  }

  /// True while `responder` is a text editor or sits inside one, so typing shortcuts (`⌘Z`,
  /// `⇧⌘Z`, `Delete`, `Backspace`) stay with the field editor.
  @MainActor
  static func isTextResponder(_ responder: NSResponder?) -> Bool {
    if responder is NSText || responder is NSTextField || responder is NSSearchField {
      return true
    }
    var current = responder as? NSView
    while let view = current {
      if view is NSText || view is NSTextField || view is NSSearchField {
        return true
      }
      current = view.superview
    }
    return false
  }

  /// Resolves workspace-scoped command shortcuts (`⌘Z`, `⇧⌘Z`, `⌘D`). Never matches `Tab` or
  /// events while a text field has first responder or the workspace is inactive.
  @MainActor
  static func commandAction(
    charactersIgnoringModifiers: String?,
    modifiers: NSEvent.ModifierFlags,
    firstResponder: NSResponder?,
    isWorkspaceActive: Bool
  ) -> Action? {
    guard isWorkspaceActive, !isTextResponder(firstResponder) else { return nil }
    let flags = modifiers.intersection([.command, .shift, .option, .control])
    let key = charactersIgnoringModifiers?.lowercased() ?? ""
    if flags == .command, key == "z" { return .undo }
    if flags == [.command, .shift], key == "z" { return .redo }
    if flags == .command, key == "d" { return .duplicate }
    return nil
  }
}
