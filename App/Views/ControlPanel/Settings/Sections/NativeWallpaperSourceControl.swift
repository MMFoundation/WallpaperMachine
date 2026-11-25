import SwiftUI

struct NativeWallpaperSourceControl: View {
  let kind: LockScreenState.Kind
  var displayUUID: String? = nil
  var displayTitle: String? = nil

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var showsChoices = false

  var body: some View {
    let source = controller.nativeWallpaperSource(kind, displayUUID: displayUUID)
    Button {
      showsChoices = true
    } label: {
      HStack(spacing: 6) {
        if source.playlistID != nil {
          Image(systemName: "rectangle.stack")
            .font(.panel(.caption))
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityHidden(true)
        }
        Text(verbatim: source.title)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.up.chevron.down")
      }
      .font(.panel(.body))
    }
    .buttonStyle(.panelSecondary)
    .frame(maxWidth: 220, alignment: .trailing)
    .accessibilityValue(Text(verbatim: source.title))
    .help(source.title)
    .disabled(!source.isEnabled || controller.settings.isLocked())
    .popover(isPresented: $showsChoices, arrowEdge: .bottom) {
      NativeWallpaperSourcePicker(kind: kind, displayUUID: displayUUID, displayTitle: displayTitle) {
        showsChoices = false
      }
      .panelPresentationLocale()
    }
  }
}

struct NativeWallpaperSourcePicker: View {
  let kind: LockScreenState.Kind
  var displayUUID: String? = nil
  var displayTitle: String? = nil
  let dismiss: () -> Void

  @Environment(PanelController.self) private var controller

  var body: some View {
    let source = controller.nativeWallpaperSource(kind, displayUUID: displayUUID)
    let isDisabled = !source.isEnabled || controller.settings.isLocked()
    let targets = controller.automationTargets
    let baseTitle = kind == .lockScreen ? L("Lock screen wallpaper") : L("Screen saver wallpaper")
    let title = displayTitle.map { "\(baseTitle) — \($0)" } ?? baseTitle
    WallpaperThumbnailChooser(
      title: title,
      wallpapers: targets.wallpapers,
      playlists: targets.playlists,
      selected: source.selectedTarget,
      unavailableNote: source.isUnavailable ? source.title : nil,
      clearOption: .init(
        title: L("Same as desktop"), isSelected: source.choice == .sameAsDesktop, isDisabled: false,
        action: { choose(.sameAsDesktop) }),
      isActionDisabled: isDisabled,
      onSelect: { target in
        switch target.kind {
        case .wallpaper: choose(.wallpaper(target.id))
        case .playlist: choose(.playlist(target.id))
        }
      },
      onDismiss: dismiss)
  }

  private func choose(_ choice: LockScreenSourceChoice) {
    let base = kind == .lockScreen ? "lockScreen" : "screenSaver"
    let detail = displayUUID.map { "\(base):\($0)" } ?? base
    let key = PanelActionCoordinator.key("nativeWallpaperSource", detail: detail)
    controller.launch(key) {
      try await controller.setNativeWallpaperSource(choice, for: kind, displayUUID: displayUUID)
    }
  }
}
