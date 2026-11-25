import SwiftUI

/// Settings › Desktop & Lock Screen: how wallpapers meet the macOS desktop picture, Mission
/// Control, the lock screen and the screen saver.
struct DesktopSettingsSection: View {
  private static let desktop = SettingsItem.Group("desktop", title: "Desktop")
  private static let lockScreen = SettingsItem.Group("lock-screen", title: "Lock screen")
  private static let screenSaver = SettingsItem.Group("screen-saver", title: "Screen saver")

  static let desktopWallpapers = SettingsItem(
    id: "desktop.desktop-wallpapers", section: .desktop, group: desktop,
    title: "Different wallpaper for each desktop",
    note: "Each desktop keeps the wallpaper you apply while you are on it, and only the desktop you are on plays, so Mission Control shows the other desktops as still pictures. A desktop you have visited waits paused where you left it; one you have not visited yet shows a still picture until its first visit. Kept wallpapers use memory and are let go when the Mac runs short of it.",
    keywords: ["Spaces", "Choose…"])
  static let writeDesktopPicture = SettingsItem(
    id: "desktop.write-desktop-picture", section: .desktop, group: desktop,
    title: "Use the wallpaper as the macOS desktop picture",
    note:
      "Mission Control and the moment before a wallpaper loads show a still frame of the wallpaper. Turn this off to leave macOS’s own wallpaper settings alone; your own picture comes back at once.",
    keywords: [
      "Animate lock screen sets the desktop picture itself, so this cannot be changed while it is on."
    ])
  static let refreshMissionControl = SettingsItem(
    id: "desktop.refresh-mission-control", section: .desktop, group: desktop,
    title: "Update the Mission Control picture every 5 minutes",
    note:
      "Mission Control shows a still picture of the wallpaper, retaken when it starts, changes or resumes. This also retakes it while it plays. Not used while the lock screen is animated."
  )
  static let keepWindowsOnClick = SettingsItem(
    id: "desktop.keep-windows-on-click", section: .desktop, group: desktop,
    title: "Keep windows in place when clicking the wallpaper",
    note:
      "Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers."
  )
  static let hideDesktopIcons = SettingsItem(
    id: "desktop.hide-desktop-icons", section: .desktop, group: desktop,
    title: "Hide desktop icons",
    note:
      "Finder stops showing files, folders and disks on the desktop, so they no longer cover the wallpaper. They stay in your Desktop folder. Finder restarts to apply the change.",
    keywords: ["Restart Finder"])
  static let hideNotch = SettingsItem(
    id: "desktop.hide-notch", section: .desktop, group: desktop,
    title: "Hide the notch",
    note:
      "On displays with a camera notch, the menu bar turns black so the notch disappears into it. The rest of the screen still shows the wallpaper.",
    keywords: ["Menu bar"])
  static let livePropertyEdits = SettingsItem(
    id: "desktop.live-property-edits", section: .desktop, group: desktop,
    title: "Show property edits on the desktop as I make them",
    note:
      "While you edit a wallpaper’s properties, your displays follow each change before you press Apply changes, and Revert puts the saved look back. Pictures, options that switch an effect on or off, and a video’s Wallpaper Engine options still wait for Apply changes. The lock screen and the Mission Control picture keep the saved look until you apply."
  )
  static let switchTransitionStyle = SettingsItem(
    id: "desktop.switch-transition-style", section: .desktop, group: desktop,
    title: "Wallpaper transition",
    note: "How the previous wallpaper leaves once the next one is ready. Reduce Motion always switches immediately.",
    keywords: ["Fade", "Slide", "Zoom fade", "Wipe"])
  static let switchTransitionDuration = SettingsItem(
    id: "desktop.switch-transition-duration", section: .desktop, group: desktop,
    title: "Transition duration")

  static let lockScreenSwitch = SettingsItem(
    id: "desktop.lock-screen", section: .desktop, group: lockScreen, title: "Animate lock screen",
    note: "Experimental")
  static let lockScreenSource = SettingsItem(
    id: "desktop.lock-screen-source", section: .desktop, group: lockScreen,
    title: "Lock screen wallpaper",
    note: "Choose a library wallpaper or saved playlist for the lock screen, or follow the desktop; each display needs an applied desktop wallpaper. Bound playlists rotate at low priority after unlock.",
    keywords: ["Same as desktop", "Saved playlists"])
  static let lockScreenPerDisplay = SettingsItem(
    id: "desktop.lock-screen-per-display", section: .desktop, group: lockScreen,
    title: "Different lock screen per display",
    note: "Pick an independent wallpaper or saved playlist for each connected display instead of sharing one choice across all displays.")
  static let lockScreenStatus = SettingsItem(
    id: "desktop.lock-screen-status", section: .desktop, group: lockScreen,
    title: "Lock screen status", keywords: ["Retry"])
  static let lockScreenContext = SettingsItem(
    id: "desktop.lock-screen-context", section: .desktop, group: lockScreen,
    title: "Compatibility & permissions")

  static let screenSaverSwitch = SettingsItem(
    id: "desktop.screen-saver", section: .desktop, group: screenSaver,
    title: "Use wallpaper as screen saver", note: "Experimental")
  static let screenSaverSource = SettingsItem(
    id: "desktop.screen-saver-source", section: .desktop, group: screenSaver,
    title: "Screen saver wallpaper",
    note: "Choose a library wallpaper or saved playlist for the screen saver, independently of the lock screen and desktop. Bound playlists rotate at low priority after the screen saver stops.",
    keywords: ["Same as desktop", "Saved playlists"])
  static let screenSaverPerDisplay = SettingsItem(
    id: "desktop.screen-saver-per-display", section: .desktop, group: screenSaver,
    title: "Different screen saver per display",
    note: "Pick an independent wallpaper or saved playlist for each connected display instead of sharing one choice across all displays.")
  static let screenSaverStatus = SettingsItem(
    id: "desktop.screen-saver-status", section: .desktop, group: screenSaver,
    title: "Screen saver status", keywords: ["Retry"])
  static let screenSaverContext = SettingsItem(
    id: "desktop.screen-saver-context", section: .desktop, group: screenSaver,
    title: "Compatibility & permissions")

  static let items = [
    desktopWallpapers, writeDesktopPicture, refreshMissionControl, keepWindowsOnClick, hideDesktopIcons,
    hideNotch, livePropertyEdits, switchTransitionStyle, switchTransitionDuration,
    lockScreenSwitch, lockScreenSource, lockScreenPerDisplay, lockScreenStatus, lockScreenContext,
    screenSaverSwitch, screenSaverSource, screenSaverPerDisplay, screenSaverStatus,
    screenSaverContext,
  ]

  /// Transition duration is offered only when an animated transition style is selected.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    controller.desktopSettings.showsSwitchTransitionDuration ? [] : [switchTransitionDuration.id]
  }

  /// 0.15 s to 2.00 s in 0.05 s steps (3…40).
  static let transitionDurationSteps = 3...40

  static func transitionDurationStep(for seconds: TimeInterval) -> Int {
    let raw = Int((seconds * 20).rounded())
    return min(max(raw, transitionDurationSteps.lowerBound), transitionDurationSteps.upperBound)
  }

  static func transitionDurationSeconds(for step: Int) -> TimeInterval {
    Double(step) / 20
  }

  @MainActor
  static func transitionDurationReadout(_ seconds: TimeInterval, locale: Locale? = nil) -> String {
    let locale = locale ?? PanelLocale.shared.locale
    let number = seconds.formatted(
      .number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(2)).grouping(.never).locale(locale))
    return L("\(number) s")
  }

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let desktop = controller.desktopSettings
    SettingsPage(.desktop) {
      SettingsUnavailableNotice()
      SettingsGroup(Self.desktop, in: .desktop) {
        desktopWallpapersRow
        SettingsRow(Self.writeDesktopPicture, note: desktop.lockedNote) {
          SettingsSwitchControl(key: .writeDesktopPicture)
        }
        SettingsRow(Self.refreshMissionControl) {
          SettingsSwitchControl(key: .refreshDesktopPicture)
        }
        SettingsRow(Self.keepWindowsOnClick) {
          SettingsSwitchControl(key: .keepWindowsOnWallpaperClick)
        }
        SettingsRow(Self.hideDesktopIcons) { SettingsSwitchControl(key: .hideDesktopIcons) }
        SettingsRow(Self.hideNotch) { SettingsSwitchControl(key: .hideNotch) }
        SettingsRow(Self.livePropertyEdits) { SettingsSwitchControl(key: .livePropertyEdits) }
        SettingsRow(Self.switchTransitionStyle) {
          SettingsMenuControl(
            key: "switchTransitionStyle", saved: desktop.switchTransitionStyle,
            options: SwitchTransitionStyle.allCases.map { SettingsMenuOption(value: $0, title: $0.title) }
          ) { try await controller.setSwitchTransitionStyle($0) }
        }
        if desktop.showsSwitchTransitionDuration {
          SettingsRow(Self.switchTransitionDuration) {
            SettingsSliderControl(
              key: "switchTransitionDuration",
              saved: Self.transitionDurationStep(for: desktop.switchTransitionDuration),
              range: Self.transitionDurationSteps,
              readout: { Self.transitionDurationReadout(Self.transitionDurationSeconds(for: $0)) }
            ) { try await controller.setSwitchTransitionDuration(Self.transitionDurationSeconds(for: $0)) }
          }
        }
      }
      SettingsGroup(Self.lockScreen, in: .desktop) {
        SettingsRow(Self.lockScreenSwitch) { SettingsSwitchControl(key: .lockScreenEnabled) }
        SettingsRow(Self.lockScreenSource) { NativeWallpaperSourceControl(kind: .lockScreen) }
        perDisplayToggleRow(Self.lockScreenPerDisplay, kind: .lockScreen, state: controller.lockScreenState)
        if controller.nativeWallpaperUsesPerDisplay(.lockScreen), search.shows(Self.lockScreenPerDisplay) {
          perDisplaySourceRows(kind: .lockScreen)
        }
        statusRow(Self.lockScreenStatus, controller.lockScreenState)
        if search.shows(Self.lockScreenStatus), let error = controller.lockScreenState.error {
          SettingsErrorLine(message: error)
        }
        SettingsDisclosure(Self.lockScreenContext) {
          SettingsProse {
            Text(
              "Lock screen animation uses the native Desktop wallpaper provider and private macOS APIs. While unlocked, it still shows each display’s desktop wallpaper; your lock screen choice does not replace it. Enabling this takes over the Desktop selection on displays with an applied wallpaper and reloads the macOS wallpaper service. Turning it off restores the previous Desktop choices. Quitting restores all choices the app changed and keeps other wallpaper changes. A macOS update may stop this experimental feature from working."
            )
            Text(
              "It keeps separate copies of wallpaper files, which uses extra disk space, and may not render on every macOS version. Pause and battery settings still apply."
            )
          }
        }
      }
      SettingsGroup(Self.screenSaver, in: .desktop) {
        SettingsRow(Self.screenSaverSwitch) { SettingsSwitchControl(key: .screenSaverEnabled) }
        SettingsRow(Self.screenSaverSource) { NativeWallpaperSourceControl(kind: .screenSaver) }
        perDisplayToggleRow(Self.screenSaverPerDisplay, kind: .screenSaver, state: controller.screenSaverState)
        if controller.nativeWallpaperUsesPerDisplay(.screenSaver), search.shows(Self.screenSaverPerDisplay) {
          perDisplaySourceRows(kind: .screenSaver)
        }
        statusRow(Self.screenSaverStatus, controller.screenSaverState)
        if search.shows(Self.screenSaverStatus), let error = controller.screenSaverState.error {
          SettingsErrorLine(message: error)
        }
        SettingsDisclosure(Self.screenSaverContext) {
          SettingsProse {
            Text(
              "Requires macOS 26 or later. Same as desktop follows each display’s applied wallpaper; a library choice uses that wallpaper for the screen saver instead. Scenes, videos, web wallpapers and still images are supported. This experimental feature uses private macOS APIs and may stop working after an update."
            )
            Text(
              "The screen saver choice is independent of lock screen animation. It changes only the Idle wallpaper selection and reloads the macOS wallpaper service. Turning it off restores the previous screen saver without changing the Desktop selection, and keeps screen saver changes made elsewhere. Pause and battery settings still apply."
            )
          }
        }
      }
    }
    .onAppear { controller.refreshSystemReadings() }
  }

  private var search: SettingsSearch { controller.settings.search }

  /// Different wallpaper for each desktop, for the display the Library applies wallpapers to, named
  /// when there are several. Choose… opens that display's card in Displays, where each desktop's
  /// wallpaper is picked.
  private var desktopWallpapersRow: some View {
    let settings = controller.settings
    let displays = controller.targetDisplays
    let target = controller.targetDisplay
    let several = displays.filter(\.isSelectable).count > 1
    return SettingsRow(Self.desktopWallpapers) {
      HStack(spacing: 8) {
        if several, let target {
          Text(verbatim: target.shortLabel(among: displays))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        SettingsActionButton("Choose…", isDisabled: target?.isSelectable != true) {
          settings.select(.displays)
          if let target { controller.displaysSettings.revealDesktops(display: target.id) }
        }
        .help(L("Open \(settings.text(SettingsSection.displays.title))"))
        SettingsSwitchControl(key: .desktopWallpapers)
      }
    }
  }

  private func perDisplayToggleRow(
    _ item: SettingsItem, kind: LockScreenState.Kind, state: LockScreenState
  ) -> some View {
    let detail = kind == .lockScreen ? "lockScreen" : "screenSaver"
    return SettingsRow(item) {
      Toggle(
        noLabel,
        isOn: Binding(
          get: { controller.nativeWallpaperUsesPerDisplay(kind) },
          set: { enabled in
            controller.launch(PanelActionCoordinator.key("nativeWallpaperPerDisplay", detail: detail)) {
              try await controller.setNativeWallpaperUsesPerDisplay(enabled, for: kind)
            }
          })
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(!state.isSwitchEnabled || controller.settings.isLocked())
    }
  }

  @ViewBuilder
  private func perDisplaySourceRows(kind: LockScreenState.Kind) -> some View {
    let displays = controller.nativeWallpaperDisplaySources(kind)
    if displays.isEmpty {
      Text("Connect a display to assign individual wallpapers.")
        .font(.panel(.footnote))
        .foregroundStyle(theme.surface.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    } else {
      ForEach(displays) { display in
        HStack(spacing: 12) {
          Text(verbatim: display.title)
            .font(.panel(.body))
            .foregroundStyle(theme.surface.text.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          NativeWallpaperSourceControl(
            kind: kind, displayUUID: display.id, displayTitle: display.title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
      }
    }
  }

  /// The status the service reports, with Retry beside it while it reports a failure. Retry waits
  /// for the service to finish, and for the Mac, so it is never pressed twice.
  private func statusRow(_ item: SettingsItem, _ state: LockScreenState) -> some View {
    let key = state.kind == .lockScreen ? "lockScreenRetry" : "screenSaverRetry"
    return SettingsRow(item) {
      SettingsStatusText(text: state.statusText) {
        if state.error != nil {
          SettingsActionButton(
            "Retry",
            isDisabled: !state.canRetry || controller.settings.isLocked(key, whileRunning: true)
          ) {
            controller.settings.perform(key) {
              if state.kind == .lockScreen {
                try await controller.retryLockScreen()
              } else {
                try await controller.retryScreenSaver()
              }
            }
          }
        }
      }
    }
  }

}
