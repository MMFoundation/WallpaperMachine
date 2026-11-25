import AppKit
import Carbon

/// A global keyboard shortcut as the Keyboard shortcuts page lists it.
struct HotKeyRow: Identifiable, Equatable, Sendable {
  let action: HotKeyAction
  /// What the shortcut does, in the panel's language.
  let title: String
  /// The recorded combination as `⌃⌥⌘P`; nil until the user records one, because the app takes no
  /// combination another app might expect.
  let shortcut: String?
  /// Why macOS refused the shortcut when the app registered it, which is not saved: registering
  /// again at the next launch may succeed.
  let error: String?

  var id: String { action.rawValue }
}

/// A global keyboard shortcut bound to a saved display layout, as Keyboard shortcuts lists it.
struct DisplayLayoutHotKeyRow: Identifiable, Equatable, Sendable {
  let layoutID: String
  let name: String
  let shortcut: String?
  let error: String?

  var id: String { layoutID }
}

/// What a key press means while a shortcut row is recording.
enum HotKeyRecording: Equatable, Sendable {
  /// A modifier key on its own: keep waiting for the key it modifies.
  case ignored
  /// Escape without ⌘, ⌥ or ⌃ (Shift does not count): stop recording and change nothing.
  case cancelled
  /// A key to record with the modifiers held; `PanelController.setHotKey` decides whether it is one a
  /// shortcut can use.
  case recorded

  /// Reads a key-down in the recording row. The view calls `setHotKey` for `.recorded`.
  static func press(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> HotKeyRecording {
    let modifierKeys: Set<Int> = [
      kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
      kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]
    if modifierKeys.contains(Int(keyCode)) { return .ignored }
    if keyCode == UInt16(kVK_Escape), modifierFlags.isDisjoint(with: [.command, .control, .option]) {
      return .cancelled
    }
    return .recorded
  }
}

extension PanelController {
  // MARK: Derived state

  /// One row per shortcut action, in the order the page lists them, with what is recorded for it.
  var hotKeyRows: [HotKeyRow] {
    _ = revisions.hotKeys
    return HotKeyAction.allCases.map { action in
      HotKeyRow(
        action: action, title: title(of: action), shortcut: hotKeys.bindings[action]?.label,
        error: hotKeys.failures[action])
    }
  }

  /// One row per saved display layout, in the order Display layouts lists them, with its recorded shortcut.
  var displayLayoutHotKeyRows: [DisplayLayoutHotKeyRow] {
    _ = revisions.hotKeys
    _ = revisions.displayLayouts
    return displayLayouts.layouts.map { layout in
      DisplayLayoutHotKeyRow(
        layoutID: layout.id,
        name: layout.name,
        shortcut: hotKeys.layoutBindings[layout.id]?.label,
        error: hotKeys.layoutFailures[layout.id])
    }
  }

  /// Whether Presentation Mode also hides Finder's desktop icons (which restarts Finder).
  /// Strictly off by default.
  var presentationHidesDesktopIcons: Bool {
    _ = revisions.hotKeys
    return PresentationModeController.hidesDesktopIcons(in: defaults)
  }

  /// What `action` does, in the panel's language.
  private func title(of action: HotKeyAction) -> String {
    switch action {
    case .togglePlayback: L("Play or pause wallpapers")
    case .toggleMute: L("Mute or unmute wallpapers")
    case .previousWallpaper: L("Previous wallpaper")
    case .nextWallpaper: L("Next wallpaper")
    case .randomWallpaper: L("Random wallpaper")
    case .openControlPanel: L("Open the control panel")
    case .toggleDesktopWidgets: L("Toggle desktop widgets")
    case .toggleDesktopIcons: L("Toggle desktop icons")
    case .togglePresentationMode: L("Presentation mode")
    }
  }

  // MARK: Actions

  /// `hotkeySet`: records the key a recording row received for `action`. `keyCode` and
  /// `modifierFlags` are the key-down event's: the key's position, which does not change with the
  /// keyboard layout, and the modifiers held.
  ///
  /// A key that cannot be a shortcut (a letter, a number, a function key, Space, Return, an arrow, or
  /// Home, End, Page Up or Down can) is refused with the reason, as is a key with none of ⌘, ⌥ and ⌃
  /// unless it is one of F13 to F20, and a combination another action already uses. Nothing is
  /// changed by a refusal. macOS may still refuse the registration later, which the row then shows.
  func setHotKey(_ action: HotKeyAction, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) async throws {
    let hotKey = try GlobalHotKeys.hotKey(keyCode: keyCode, modifierFlags: modifierFlags)
    let layoutTitles = Dictionary(uniqueKeysWithValues: displayLayouts.layouts.map { ($0.id, $0.name) })
    try await run(.immediate) { try hotKeys.set(hotKey, for: action, layoutTitles: layoutTitles) }
  }

  /// `hotkeyClear`: the action has no shortcut again.
  func clearHotKey(_ action: HotKeyAction) async throws {
    try await run(.immediate) { try hotKeys.set(nil, for: action) }
  }

  /// `layoutHotkeySet`: records a global keyboard shortcut for a saved display layout.
  func setLayoutHotKey(_ layoutID: String, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) async throws {
    _ = try displayLayouts.layout(layoutID)
    let hotKey = try GlobalHotKeys.hotKey(keyCode: keyCode, modifierFlags: modifierFlags)
    let layoutTitles = Dictionary(uniqueKeysWithValues: displayLayouts.layouts.map { ($0.id, $0.name) })
    try await run(.immediate) { try hotKeys.set(hotKey, forLayout: layoutID, layoutTitles: layoutTitles) }
  }

  /// `layoutHotkeyClear`: clears the global keyboard shortcut for a saved display layout.
  func clearLayoutHotKey(_ layoutID: String) async throws {
    try await run(.immediate) { try hotKeys.set(nil, forLayout: layoutID) }
  }

  /// `presentationHideIcons`: opt-in toggle controlling whether Presentation Mode also hides
  /// Finder's desktop icons (which restarts Finder).
  func setPresentationHidesDesktopIcons(_ hide: Bool) async throws {
    try await run(.immediate) {
      PresentationModeController.setHidesDesktopIcons(hide, in: defaults)
      revisions.bump(.hotKeys)
    }
  }
}
