import SwiftUI

/// Now Playing's playlist button: lit while the target display has an active playlist (with the
/// order's symbol for rotation, or a sunrise for Day and night), and named after what it plays. It
/// opens the playlist's state above the bar.
struct NowPlayingPlaylistButton: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shell = controller.shell
    let rotation = NowPlayingRotation(controller: controller)
    let hasSleepTimer = controller.sleepTimerEnd != nil
    let isLit = rotation != nil || hasSleepTimer
    let symbol = rotation?.systemImage ?? (hasSleepTimer ? "moon.zzz" : "repeat")
    let label = rotation.map { L("Playlist: \($0.title)") } ?? (hasSleepTimer ? L("Sleep timer") : L("Playlist"))
    NowPlayingControl(
      systemImage: symbol,
      label: label,
      isEnabled: controller.targetDisplay?.isSelectable == true,
      tint: isLit ? theme.accent.accent.color : nil,
      identifier: "now-playing-playlist"
    ) {
      let isOpen = shell.activePopover == .playlist
      shell.popover(.playlist).wrappedValue = !isOpen
    }
    .popover(isPresented: shell.popover(.playlist), arrowEdge: .top) {
      NowPlayingPlaylistDetails().panelPresentationLocale().panelWindowLook()
    }
  }
}

/// The target display's active playlist as Now Playing names it; nil while that display's playlist
/// is off or the display cannot have one.
struct NowPlayingRotation {
  let state: PlaylistState
  /// What it plays: All wallpapers, Favorites, the display's list, a collection's name, or
  /// Day and night.
  let title: String

  /// The symbol the playlist button shows while this playlist is active.
  var systemImage: String {
    switch state.playlist.mode {
    case .dayNight: "sunrise"
    case .rotate: state.playlist.order == .shuffle ? "shuffle" : "repeat"
    case .off: "repeat"
    }
  }

  @MainActor init?(controller: PanelController) {
    guard controller.targetDisplay?.isSelectable == true else { return nil }
    let state = controller.playlistState(for: controller.targetDisplayID)
    switch state.playlist.mode {
    case .rotate:
      self.state = state
      title = state.sourceTitle(collections: controller.collectionRows)
    case .dayNight:
      self.state = state
      title = L("Day and night")
    case .off:
      return nil
    }
  }
}

/// The playlist above the bar: what the target display rotates through (or Day and night), inline
/// order and interval controls for rotation, when it changes next, and Play / Change now, Stop and
/// Settings….
struct NowPlayingPlaylistDetails: View {
  static let width: CGFloat = 300

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.panelIsVisible) private var isVisible
  /// Updated every 30 seconds only while this popover is visible and a sleep timer is running.
  @State private var sleepTimerNow = Date()

  /// The source starting rotation from the popover plays: the display's saved source when it still
  /// has a playable wallpaper, otherwise All wallpapers.
  @MainActor
  static func startSource(for state: PlaylistState, controller: PanelController)
    -> PlaylistSourceChoice
  {
    if state.source != .missingCollection, controller.canPlay(state.source) {
      return state.source
    }
    return .all
  }

  var body: some View {
    let display = controller.targetDisplayID
    let state = controller.playlistState(for: display)
    let isDisabled = controller.isStoreBusy || controller.targetDisplay?.isSelectable != true
    let startSource = Self.startSource(for: state, controller: controller)
    let canStart =
      !isDisabled && !controller.isBusy(PanelActionCoordinator.key("playlistPlay"))
      && controller.canPlay(startSource)
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Playlist")
          .panelFont(.eyebrow)
          .foregroundStyle(theme.surface.muted.color)
        Text(verbatim: title(state))
          .font(.panel(.headline))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      if state.playlist.mode != .dayNight {
        rotationControls(display: display, state: state, isDisabled: isDisabled)
      }
      Text(verbatim: note(state))
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      sleepTimerRow(isDisabled: isDisabled)
      HStack(spacing: 8) {
        if state.playlist.mode == .off {
          Button {
            controller.launch(PanelActionCoordinator.key("playlistPlay")) { [controller] in
              try await controller.playPlaylist(
                startSource, order: state.playlist.order, display: display)
            }
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(.panelPrimary)
          .disabled(!canStart)
          .help(L("Start rotation"))
          .accessibilityIdentifier("now-playing-playlist-start")
        } else if state.showsResume {
          Button("Resume playlist") {
            controller.launch(PanelActionCoordinator.key("playlistResume", id: display)) {
              try await controller.resumePlaylist(display: display)
            }
          }
          .buttonStyle(.panelSecondary)
          .disabled(isDisabled)
          .accessibilityIdentifier("now-playing-playlist-resume")
        } else if state.playlist.mode == .rotate {
          Button("Change now") {
            controller.launch(PanelActionCoordinator.key("playlistSkip", id: display)) {
              try await controller.skipPlaylist(display: display)
            }
          }
          .buttonStyle(.panelSecondary)
          .disabled(isDisabled)
          .accessibilityIdentifier("now-playing-playlist-skip")
        }
        if state.playlist.mode != .off {
          Button("Stop") {
            controller.launch(PanelActionCoordinator.key("playlistStop", id: display)) {
              try await controller.editPlaylist(.mode(.off), display: display)
            }
          }
          .buttonStyle(.panelSecondary)
          .disabled(isDisabled)
          .help(L("The wallpaper on screen stays until you change it."))
          .accessibilityIdentifier("now-playing-playlist-stop")
        }
        Spacer(minLength: 0)
        Button("Settings…") {
          controller.shell.popover(.playlist).wrappedValue = false
          controller.launch(PanelActionCoordinator.key("openSettings")) {
            try await controller.openSettings(.displays)
          }
        }
        .buttonStyle(.panelSecondary)
        .accessibilityIdentifier("now-playing-playlist-settings")
      }
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("now-playing-playlist-popover")
    .task(id: sleepTimerTaskKey) {
      guard isVisible, controller.sleepTimerEnd != nil else { return }
      sleepTimerNow = Date()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { break }
        guard !Task.isCancelled else { break }
        sleepTimerNow = Date()
      }
    }
  }

  private struct SleepTimerTaskKey: Equatable {
    let visible: Bool
    let end: Date?
  }

  private var sleepTimerTaskKey: SleepTimerTaskKey {
    SleepTimerTaskKey(visible: isVisible, end: controller.sleepTimerEnd)
  }

  private func sleepTimerRow(isDisabled: Bool) -> some View {
    let sleepKey = PanelActionCoordinator.key("sleepTimer")
    let end = controller.sleepTimerEnd
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Label("Sleep timer", systemImage: "moon.zzz")
          .font(.panel(.callout))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
        Spacer(minLength: 8)
        if end != nil {
          Button("Cancel") {
            controller.launch(sleepKey, policy: .latestWins) { [controller] in
              try await controller.setSleepTimer(minutes: nil)
            }
          }
          .buttonStyle(.panelSecondary(size: .compact))
          .disabled(isDisabled || controller.isBusy(sleepKey))
          .accessibilityIdentifier("now-playing-playlist-sleep-timer-cancel")
        } else {
          Menu {
            Toggle(isOn: .constant(true)) {
              Text("Off")
            }
            .disabled(true)
            Divider()
            ForEach(SleepTimerChoice.presets, id: \.self) { minutes in
              Button {
                sleepTimerNow = Date()
                controller.launch(sleepKey, policy: .latestWins) { [controller] in
                  try await controller.setSleepTimer(minutes: minutes)
                }
              } label: {
                Text(verbatim: SleepTimerChoice.title(minutes: minutes))
              }
            }
          } label: {
            HStack(spacing: 4) {
              Text("Off")
                .lineLimit(1)
              Image(systemName: "chevron.down")
                .font(.panel(.mark))
                .accessibilityHidden(true)
            }
          }
          .menuStyle(.button)
          .menuIndicator(.hidden)
          .buttonStyle(.panelCapsule)
          .disabled(isDisabled || controller.isBusy(sleepKey))
          .accessibilityLabel(Text("Sleep timer"))
          .accessibilityValue(Text("Off"))
          .accessibilityIdentifier("now-playing-playlist-sleep-timer")
        }
      }
      if let end {
        Text(verbatim: SleepTimerChoice.remainingText(until: end, now: sleepTimerNow))
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(2)
          .accessibilityIdentifier("now-playing-playlist-sleep-timer-remaining")
      }
    }
  }

  /// Inline Order (In order / Shuffle) and How often interval controls for rotation.
  private func rotationControls(
    display: String, state: PlaylistState, isDisabled: Bool
  ) -> some View {
    let orderKey = PanelActionCoordinator.key("playlistSetting", id: display, detail: "order")
    let intervalKey = PanelActionCoordinator.key("playlistSetting", id: display, detail: "interval")
    return VStack(alignment: .leading, spacing: 8) {
      SettingsSegmentedControl(
        segments: [
          .init(value: PlaylistOrder.sequential, title: L("In order")),
          .init(value: PlaylistOrder.shuffle, title: L("Shuffle")),
        ],
        selection: state.playlist.order,
        isEnabled: !isDisabled && !controller.isBusy(orderKey),
        fillsWidth: true
      ) { order in
        guard order != state.playlist.order else { return }
        controller.launch(orderKey) { [controller] in
          try await controller.editPlaylist(.order(order), display: display)
        }
      }
      .accessibilityLabel(Text("Order"))
      .accessibilityIdentifier("now-playing-playlist-order")

      HStack(spacing: 8) {
        Text("How often")
          .font(.panel(.callout))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
        Spacer(minLength: 8)
        Menu {
          ForEach(IntervalChoice.presets, id: \.self) { minutes in
            Toggle(
              isOn: Binding(
                get: { state.interval == .preset(minutes) },
                set: { _ in
                  controller.launch(intervalKey) { [controller] in
                    try await controller.editPlaylist(.interval(.preset(minutes)), display: display)
                  }
                })
            ) {
              Text(verbatim: IntervalChoice.title(minutes: minutes))
            }
          }
          Toggle(
            isOn: Binding(
              get: { state.interval == .unlock },
              set: { _ in
                controller.launch(intervalKey) { [controller] in
                  try await controller.editPlaylist(.interval(.unlock), display: display)
                }
              })
          ) {
            Text("Each time the Mac is unlocked")
          }
          if case .custom(let minutes) = state.interval {
            Divider()
            Toggle(isOn: .constant(true)) {
              Text(verbatim: IntervalChoice.title(minutes: minutes))
            }
            .disabled(true)
          }
        } label: {
          HStack(spacing: 4) {
            Text(verbatim: state.interval.title)
              .lineLimit(1)
              .truncationMode(.tail)
            Image(systemName: "chevron.down")
              .font(.panel(.mark))
              .accessibilityHidden(true)
          }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.panelCapsule)
        .disabled(isDisabled || controller.isBusy(intervalKey))
        .help(state.interval.title)
        .accessibilityLabel(Text("How often"))
        .accessibilityValue(Text(verbatim: state.interval.title))
        .accessibilityIdentifier("now-playing-playlist-interval")
      }
    }
  }

  private func title(_ state: PlaylistState) -> String {
    switch state.playlist.mode {
    case .rotate: state.sourceTitle(collections: controller.collectionRows)
    case .dayNight: L("Day and night")
    case .off: L("Off")
    }
  }

  private func note(_ state: PlaylistState) -> String {
    switch state.playlist.mode {
    case .rotate: state.showsResume ? L("Playlist paused") : state.nextNote
    case .dayNight: state.showsResume ? L("Playlist paused") : L("Changes between the day and night wallpapers.")
    case .off:
      L("To rotate wallpapers, press Play above All wallpapers, Favorites or a collection in Installed.")
    }
  }
}
