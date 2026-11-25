import SwiftUI

/// The popover's root: the panel in the app's theme and the panel's live language, over the
/// controller of this opening and its image pipeline.
struct StatusPanelRoot: View {
  let controller: StatusPanelController
  /// Optional height cap computed from the anchor screen's `visibleFrame`; nil lets the panel draw
  /// at its natural height without scrolling.
  var maxHeight: CGFloat? = nil

  var body: some View {
    StatusPanelView(maxHeight: maxHeight)
      .environment(controller)
      .environment(\.panelImages, controller.images)
      .panelTheme(theme: .shared, locale: .shared)
  }
}

/// The panel a click on the menu bar icon opens: the chosen display's wallpaper with its state,
/// favorite heart and transport, its own volume, a quick switcher of eight wallpapers, the ones
/// used there recently, what the app draws now, and the way to the control panel, Settings and Quit.
///
/// It only draws and starts `StatusPanelController`'s typed actions. Covers come from the image
/// pipeline once their stamps are read, never a full-size preview or a live render, and nothing in
/// it moves on its own.
struct StatusPanelView: View {
  static let width: CGFloat = 320

  var maxHeight: CGFloat? = nil

  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    StatusPanelContainerLayout(width: Self.width, maxHeight: maxHeight) {
      bodyArea
      footerArea
    }
    .frame(width: Self.width, alignment: .leading)
    .announcesChanges(of: controller.failure)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("status-panel")
  }

  /// Fits naturally when the body fits above the footer, and scrolls inside `ScrollView` when the
  /// anchor screen's `maxHeight` caps the popover so `preferredContentSize` never collapses.
  @ViewBuilder
  private var bodyArea: some View {
    if maxHeight != nil {
      ViewThatFits(in: .vertical) {
        scrollableContent
        ScrollView(.vertical) {
          scrollableContent
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    } else {
      scrollableContent
    }
  }

  private var scrollableContent: some View {
    let panel = controller.panel
    return VStack(alignment: .leading, spacing: 14) {
      if panel.showsDisplayPicker {
        StatusPanelDisplayPicker()
      }
      if panel.state == .unavailable {
        Text("WallpaperMachine is still starting, or its renderer could not start. Try again in a moment.")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.onGlass.color)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        StatusPanelNowPlaying()
        StatusPanelTransport()
        if panel.wallpaper != nil || panel.wallpapersMuted || panel.canTogglePlayback {
          StatusPanelSound()
        }
        StatusPanelSwitcher()
        if !panel.recent.isEmpty { StatusPanelRecent() }
        if controller.hasEnergy { StatusPanelEnergy() }
      }
      if let update = panel.update {
        Button { controller.openUpdates() } label: {
          Label {
            Text(verbatim: update.title)
              .font(.system(size: 12, weight: .medium))
              .fixedSize(horizontal: false, vertical: true)
          } icon: { Image(systemName: "arrow.down.circle") }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent.accent.color)
        .accessibilityIdentifier("status-panel-update")
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 14)
    .frame(width: Self.width, alignment: .leading)
  }

  private var footerArea: some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider()
      StatusPanelFooter()
      if let failure = controller.failure {
        Text(verbatim: failure)
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.danger.color)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
    .frame(width: Self.width, alignment: .leading)
  }
}

/// Lays out the scrollable body above a pinned footer: shrinks to their natural height when they
/// fit within `maxHeight`, and caps at `maxHeight` while keeping the footer pinned otherwise.
private struct StatusPanelContainerLayout: Layout {
  let width: CGFloat
  let maxHeight: CGFloat?

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let width = proposal.width ?? self.width
    let footer = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
    let naturalBody = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    let naturalTotal = ceil(naturalBody.height + footer.height)
    let cap = min(proposal.height ?? .infinity, maxHeight ?? .infinity)
    return CGSize(width: width, height: min(naturalTotal, cap))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let footer = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
    let bodyHeight = max(0, bounds.height - footer.height)
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bodyHeight))
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + bodyHeight),
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: footer.height))
  }
}

/// Two displays share a segmented control; three or more switch to a compact menu so display names
/// are never squeezed down to unreadable fragments.
private struct StatusPanelDisplayPicker: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let panel = controller.panel
    if panel.usesCompactDisplayPicker {
      let current = panel.displays.first { $0.id == panel.displayID }
      let selection = Binding<String>(
        get: { panel.displayID ?? "" },
        set: { controller.chooseDisplay($0) })
      Menu {
        Picker(selection: selection) {
          ForEach(panel.displays) { display in
            Text(verbatim: display.shortTitle).tag(display.id)
          }
        } label: {
          Text("Display")
        }
        .pickerStyle(.inline)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "display")
            .foregroundStyle(theme.surface.onGlass.color)
          Text(verbatim: current?.shortTitle ?? panel.displayTitle)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 4)
          Image(systemName: "chevron.up.chevron.down")
            .font(.panel(.mark))
            .foregroundStyle(theme.surface.onGlass.color)
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.panelSecondary(size: .regular, expands: true))
      .help(current?.title ?? panel.displayTitle)
      .accessibilityLabel(Text("Display"))
      .accessibilityValue(Text(verbatim: current?.title ?? panel.displayTitle))
      .accessibilityIdentifier("status-panel-displays")
    } else {
      SettingsSegmentedControl(
        segments: panel.displays.map {
          .init(value: $0.id, title: $0.shortTitle, help: $0.title)
        },
        selection: panel.displayID
      ) { controller.chooseDisplay($0) }
      .accessibilityLabel(Text("Display"))
      .accessibilityIdentifier("status-panel-displays")
    }
  }
}

/// A section's caption, as the Now Playing details caption theirs.
private struct StatusPanelCaption: View {
  let text: Text

  @Environment(\.panelTheme) private var theme

  var body: some View {
    text
      .panelFont(.eyebrow)
      .foregroundStyle(theme.surface.onGlass.color)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The wallpaper at 16:9, its title, state and active playlist badge, and the heart. Clicking the
/// artwork or title opens the Control Panel with this wallpaper selected in the inspector.
private struct StatusPanelNowPlaying: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHoveringCover = false
  @State private var isHoveringTitle = false

  var body: some View {
    let panel = controller.panel
    let width = StatusPanelView.width - 32
    let coverHeight = (width * 9 / 16).rounded()
    let coverShape = RoundedRectangle(cornerRadius: TileGridLayout.pictureCornerRadius, style: .continuous)
    let cover = NowPlayingCover(
      source: panel.wallpaper.flatMap(controller.cover(for:)), width: width,
      height: coverHeight, cornerRadius: TileGridLayout.pictureCornerRadius)
      // Clipping an aspect-filled image leaves its inner hit area outside the visible cover; keep
      // hit testing off the image itself and confine clicks to the clipped 16:9 frame below.
      .allowsHitTesting(false)
    VStack(alignment: .leading, spacing: 10) {
      if let wallpaper = panel.wallpaper {
        Button {
          controller.openWallpaperInInspector()
        } label: {
          cover
            .overlay {
              coverShape.strokeBorder(
                isHoveringCover ? theme.accent.accent.color : .clear,
                lineWidth: 1.5)
            }
            .frame(width: width, height: coverHeight)
            .clipped()
            .contentShape(coverShape)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringCover = $0 }
        .help(L("Open in Control Panel"))
        .accessibilityLabel(Text(verbatim: wallpaper.title))
        .accessibilityHint(Text("Open in Control Panel"))
        .accessibilityIdentifier("status-panel-artwork")
      } else {
        cover
          .frame(width: width, height: coverHeight)
          .clipped()
      }
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          if let wallpaper = panel.wallpaper {
            Button {
              controller.openWallpaperInInspector()
            } label: {
              Text(verbatim: wallpaper.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHoveringTitle ? theme.accent.accent.color : theme.surface.text.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTitle = $0 }
            .help(L("Open in Control Panel"))
            .accessibilityLabel(Text(verbatim: wallpaper.title))
            .accessibilityHint(Text("Open in Control Panel"))
            .accessibilityIdentifier("status-panel-title")
          } else {
            Text("Nothing on this display")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(theme.surface.text.color)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text(verbatim: panel.stateLine)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.onGlass.color)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
          if let playlist = panel.playlist {
            StatusPanelPlaylistBadge(badge: playlist)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if panel.wallpaper != nil {
          NowPlayingControl(
            systemImage: panel.isFavorite ? "heart.fill" : "heart",
            label: panel.isFavorite ? L("Remove from favorites") : L("Add to favorites"),
            isEnabled: !controller.isBusy(controller.key("favorite")),
            tint: panel.isFavorite ? theme.surface.heart.color : nil, identifier: "status-panel-favorite"
          ) {
            controller.launch(controller.key("favorite")) { try await controller.toggleFavorite() }
          }
          .frame(width: 32)
          .accessibilityAddTraits(panel.isFavorite ? .isSelected : [])
        }
      }
    }
  }
}

/// Compact badge naming the display's active playlist rotation or Day and night schedule.
private struct StatusPanelPlaylistBadge: View {
  let badge: StatusPanelModel.PlaylistBadge

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: badge.systemImage)
        .font(.panel(.mark))
      Text(verbatim: badge.isPaused ? "\(badge.title) · \(L("Playlist paused"))" : badge.title)
        .font(.panel(.badge))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .foregroundStyle(badge.isPaused ? theme.surface.onGlass.color : theme.accent.accent.color)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(
      badge.isPaused ? theme.surface.hover.color : theme.accent.accent.color.opacity(0.14),
      in: Capsule()
    )
    .help(badge.accessibilityText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: badge.accessibilityText))
    .accessibilityIdentifier("status-panel-playlist")
  }
}

/// Previous, play or pause, next and a random wallpaper: the menu's commands for the display.
private struct StatusPanelTransport: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    let panel = controller.panel
    HStack(spacing: 4) {
      NowPlayingControl(
        systemImage: "backward.fill", label: L("Previous wallpaper"),
        isEnabled: panel.canPrevious && !busy("previous"), identifier: "status-panel-previous"
      ) {
        controller.launch(controller.key("previous")) { try await controller.previous() }
      }
      NowPlayingControl(
        systemImage: panel.isPaused || !panel.canTogglePlayback ? "play.fill" : "pause.fill",
        label: !panel.canTogglePlayback
          ? L("No wallpaper playing")
          : panel.isPaused ? L("Resume wallpaper playback") : L("Pause wallpaper playback"),
        isEnabled: panel.canTogglePlayback && !busy("playback"), isProminent: true,
        identifier: "status-panel-toggle"
      ) {
        controller.launch(controller.key("playback")) { try await controller.togglePlayback() }
      }
      NowPlayingControl(
        systemImage: "forward.fill", label: L("Next wallpaper"),
        isEnabled: panel.canNext && !busy("next"), identifier: "status-panel-next"
      ) {
        controller.launch(controller.key("next")) { try await controller.next() }
      }
      NowPlayingControl(
        systemImage: "dice", label: L("Random wallpaper"),
        isEnabled: panel.canRandom && !busy("random"), identifier: "status-panel-random"
      ) {
        controller.launch(controller.key("random")) { try await controller.randomWallpaper() }
      }
    }
  }

  private func busy(_ action: String) -> Bool { controller.isBusy(controller.key(action)) }
}

/// The wallpaper's own mute and volume, as the inspector sets them, and the global Mute All toggle.
/// While Mute All is on, the wallpaper's own controls are locked and the note says why.
private struct StatusPanelSound: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let panel = controller.panel
    let volume = controller.volume
    let ownMute = volume?.muted ?? false
    let silent = panel.wallpapersMuted || ownMute
    VStack(alignment: .leading, spacing: 8) {
      if panel.wallpaper != nil {
        HStack(alignment: .bottom, spacing: 8) {
          NowPlayingControl(
            systemImage: silent ? "speaker.slash.fill" : "speaker.wave.2.fill",
            label: ownMute ? L("Unmute") : L("Mute this wallpaper"),
            isEnabled: volume != nil && !panel.wallpapersMuted && !busy("mute"),
            identifier: "status-panel-mute"
          ) {
            controller.launch(controller.key("mute"), policy: .latestWins) {
              try await controller.setMuted(!ownMute)
            }
          }
          .frame(width: 32)
          DraggableSlider(
            value: (volume?.volume ?? 0) * 100, range: 0...100, step: 1,
            format: { InspectorWording.percent($0 / 100) }, accessibilityLabel: L("Volume"),
            onRelease: { setVolume($0 / 100) }, onStep: { setVolume($0 / 100) }
          ) { output in
            HStack(spacing: 8) {
              Text("Volume")
                .font(.system(size: 12))
                .foregroundStyle(theme.surface.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(verbatim: volume == nil ? "" : output)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.surface.onGlass.color)
                .accessibilityHidden(true)
            }
          }
          .disabled(volume == nil || silent)
        }
        .help(L("Default sound settings for this wallpaper. Settings → Displays can set volume and mute separately for each display."))
      }
      HStack(alignment: .center, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Mute All")
            .font(.panel(.callout))
            .foregroundStyle(theme.surface.text.color)
          if panel.wallpapersMuted {
            Text("Mute All is on, so every wallpaper is silent.")
              .font(.panel(.footnote))
              .foregroundStyle(theme.surface.onGlass.color)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Toggle(isOn: Binding(
          get: { panel.wallpapersMuted },
          set: { muted in
            controller.launch(controller.key("muteAll"), policy: .latestWins) {
              try await controller.setWallpapersMuted(muted)
            }
          }
        )) {
          Text("Mute All")
        }
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
        .disabled(busy("muteAll"))
        .accessibilityLabel(Text("Mute All"))
        .accessibilityIdentifier("status-panel-mute-all")
      }
    }
  }

  private func busy(_ action: String) -> Bool { controller.isBusy(controller.key(action)) }

  private func setVolume(_ fraction: Double) -> Task<Void, Never> {
    controller.launch(controller.key("volume"), policy: .latestWins) {
      try await controller.setVolume(fraction)
    }
  }
}

/// Eight wallpapers to change to in one click, from the favorites or the whole library, and a
/// button that draws eight others.
private struct StatusPanelSwitcher: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

  var body: some View {
    let panel = controller.panel
    if panel.isLibraryEmpty {
      Text("Your wallpaper library is empty")
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.onGlass.color)
    } else if !panel.strip.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          if panel.stripSource == .favorites {
            StatusPanelCaption(text: Text("Favorites"))
          } else {
            StatusPanelCaption(text: Text("All wallpapers"))
          }
          Spacer(minLength: 4)
          Button {
            controller.showOtherWallpapers()
          } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(theme.surface.onGlass.color)
          }
          .buttonStyle(.plain)
          .disabled(!panel.canShowOthers)
          .help(L("Show other wallpapers"))
          .accessibilityLabel(Text("Show other wallpapers"))
          .accessibilityIdentifier("status-panel-shuffle")
        }
        LazyVGrid(columns: columns, spacing: 6) {
          ForEach(panel.strip) { wallpaper in
            StatusPanelThumbnail(wallpaper: wallpaper, isShown: wallpaper.id == panel.wallpaper?.id)
          }
        }
      }
    }
  }
}

/// One wallpaper of the quick switcher: its cover, lit on hover and ringed while the display shows
/// it. A click applies it to the display.
private struct StatusPanelThumbnail: View {
  let wallpaper: StatusPanelModel.Wallpaper
  let isShown: Bool

  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let key = controller.key("apply", id: wallpaper.id)
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Button {
      controller.launch(key) { try await controller.apply(wallpaper.id) }
    } label: {
      ZStack {
        theme.surface.mediaWell.color
        PanelImage(source: controller.cover(for: wallpaper), pointSize: 72, contentMode: .fill)
      }
      .aspectRatio(16 / 10, contentMode: .fit)
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(
          isShown ? theme.accent.accent.color : isHovering ? theme.surface.line.color : theme.surface.divider.color,
          lineWidth: isShown ? 2 : isHovering ? 1 : 0.5)
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(controller.isBusy(key))
    .onHover { isHovering = $0 }
    .help(wallpaper.title)
    .accessibilityLabel(Text(verbatim: wallpaper.title))
    .accessibilityAddTraits(isShown ? .isSelected : [])
  }
}

/// Wallpapers used on the display before, newest first; a click applies one again.
private struct StatusPanelRecent: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusPanelCaption(text: Text("Recently used"))
      ForEach(controller.panel.recent) { wallpaper in
        StatusPanelRecentRow(wallpaper: wallpaper)
      }
    }
  }
}

private struct StatusPanelRecentRow: View {
  let wallpaper: StatusPanelModel.Wallpaper

  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let key = controller.key("apply", id: wallpaper.id)
    Button {
      controller.launch(key) { try await controller.apply(wallpaper.id) }
    } label: {
      HStack(spacing: 8) {
        NowPlayingCover(source: controller.cover(for: wallpaper), width: 34, height: 22, cornerRadius: 4)
        Text(verbatim: wallpaper.title)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        isHovering ? theme.surface.selected.color : .clear,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(controller.isBusy(key))
    .onHover { isHovering = $0 }
    .accessibilityLabel(Text(verbatim: wallpaper.title))
  }
}

/// What this app draws now, as Settings › Performance › Energy use measures it, while the panel is
/// open. Its own view, so a reading every two seconds redraws only this row.
private struct StatusPanelEnergy: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    if let energy = controller.energy { StatusPanelEnergyReading(reading: energy) }
  }
}

/// The figure and its grade on one line, a caveat in place of the grade, and the battery share
/// below. CPU and GPU are in the tooltip and what VoiceOver reads; the row is not announced as it
/// changes, which would speak every two seconds.
struct StatusPanelEnergyReading: View {
  let reading: EnergyReadout

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusPanelCaption(text: Text("Energy use"))
      switch reading.status {
      case .unavailable:
        Text("Unavailable on this Mac").font(.system(size: 12)).foregroundStyle(theme.surface.onGlass.color)
      case .measuring:
        Text("Measuring…").font(.system(size: 12)).foregroundStyle(theme.surface.onGlass.color)
      case .ready:
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: EnergyReadout.milliwatts(reading.totalMilliwatts))
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(theme.surface.text.color)
            .lineLimit(1)
            .fixedSize()
          if let caveat = reading.caveats.first {
            Text(verbatim: caveat.title)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.onGlass.color)
              .lineLimit(1)
              .truncationMode(.tail)
          } else if let level = reading.level, let title = reading.levelTitle {
            HStack(spacing: 5) {
              Circle().fill(tint(for: level)).frame(width: 7, height: 7)
              Text(verbatim: title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(theme.surface.onGlass.color)
          }
          Spacer(minLength: 0)
        }
        if reading.caveats.isEmpty, let share = reading.batteryShareNote {
          Text(verbatim: share)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.onGlass.color)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(reading.summary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Energy use"))
    .accessibilityValue(Text(verbatim: reading.summary))
    .accessibilityIdentifier("status-panel-energy")
  }

  private func tint(for level: EnergyLevel) -> Color {
    switch level {
    case .low: theme.surface.approved.color
    case .medium: theme.surface.warning.color
    case .high: theme.surface.danger.color
    }
  }
}

/// The control panel, Settings and Quit. Each closes the panel before it acts.
private struct StatusPanelFooter: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    HStack(spacing: 6) {
      Button {
        controller.openControlPanel()
      } label: {
        Label("Control Panel", systemImage: "macwindow")
      }
      .accessibilityIdentifier("status-panel-control-panel")
      Button {
        controller.openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .accessibilityIdentifier("status-panel-settings")
      Spacer(minLength: 4)
      Button {
        controller.quit()
      } label: {
        Image(systemName: "power")
      }
      .help(L("Quit WallpaperMachine"))
      .accessibilityLabel(Text("Quit WallpaperMachine"))
      .accessibilityIdentifier("status-panel-quit")
    }
    .buttonStyle(ToolbarCapsuleButtonStyle())
  }
}

extension StatusPanelModel.Panel {
  /// The line under the title: the wallpaper's kind and what holds it, or what to do with an empty
  /// display: pick from the switcher below, or, with nothing in it to pick, find one in the
  /// Control Panel, which the footer opens.
  @MainActor var stateLine: String {
    let status: String =
      switch state {
      case .unavailable: L("Starting…")
      case .switching: L("Changing wallpaper…")
      case .empty:
        strip.isEmpty
          ? L("Open the Control Panel to find a wallpaper and apply it.")
          : L("Choose a wallpaper below to show it here.")
      case .paused: L("Playback paused")
      case .held(let hold): hold.text
      case .playing: L("Playback running")
      }
    guard let wallpaper, state != .empty else { return status }
    return "\(wallpaper.kind.label) · \(status)"
  }
}

extension StatusPanelModel.Hold {
  /// The rule's own words where it has them (Playback & Power's), and what holds wallpapers otherwise.
  @MainActor var text: String {
    switch self {
    case .libraryDrive: L("The wallpaper library’s drive is disconnected. Wallpapers are stopped.")
    case .condition(let condition): condition.statusText
    case .onBattery: L("On battery. Wallpapers are paused.")
    case .rule(stopped: false): L("A playback rule is in effect. Wallpapers are paused.")
    case .rule(stopped: true): L("A playback rule is in effect. Wallpapers are stopped.")
    }
  }
}

extension StatusPanelModel.PlaylistBadge {
  /// What the playlist plays, matching `NowPlayingRotation.title`.
  @MainActor var title: String {
    switch kind {
    case .dayNight: L("Day and night")
    case .rotate(let source, _):
      switch source {
      case .all: L("All wallpapers")
      case .favorites: L("Favorites")
      case .list(let count): L("This display’s list (\(count))")
      case .collection(let name): name
      case .missingCollection: L("A collection that no longer exists")
      }
    }
  }

  /// Full accessible description matching `NowPlayingPlaylistButton`.
  @MainActor var accessibilityText: String {
    isPaused ? "\(L("Playlist: \(title)")) · \(L("Playlist paused"))" : L("Playlist: \(title)")
  }
}
