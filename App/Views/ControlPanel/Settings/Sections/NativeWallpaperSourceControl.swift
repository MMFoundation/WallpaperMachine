import SwiftUI

struct NativeWallpaperSourceControl: View {
  let kind: LockScreenState.Kind

  @Environment(PanelController.self) private var controller
  @State private var showsChoices = false

  var body: some View {
    let source = controller.nativeWallpaperSource(kind)
    Button {
      showsChoices = true
    } label: {
      HStack(spacing: 6) {
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
      NativeWallpaperSourcePicker(kind: kind) { showsChoices = false }
        .panelPresentationLocale()
    }
  }
}

struct NativeWallpaperSourcePicker: View {
  let kind: LockScreenState.Kind
  let dismiss: () -> Void

  @Environment(PanelController.self) private var controller

  var body: some View {
    let source = controller.nativeWallpaperSource(kind)
    let isDisabled = !source.isEnabled || controller.settings.isLocked()
    WallpaperThumbnailChooser(
      title: kind == .lockScreen ? L("Lock screen wallpaper") : L("Screen saver wallpaper"),
      wallpapers: controller.automationTargets.wallpapers,
      selected: source.wallpaperID.map { WallpaperAutomationTarget(kind: .wallpaper, id: $0) },
      unavailableNote: source.isUnavailable ? source.title : nil,
      clearOption: .init(
        title: L("Same as desktop"), isSelected: source.wallpaperID == nil, isDisabled: false,
        action: { choose(nil) }),
      isActionDisabled: isDisabled,
      onSelect: { choose($0.id) },
      onDismiss: dismiss)
  }

  private func choose(_ id: String?) {
    let key = PanelActionCoordinator.key(
      "nativeWallpaperSource", detail: kind == .lockScreen ? "lockScreen" : "screenSaver")
    controller.launch(key) { try await controller.setNativeWallpaperSource(id, for: kind) }
  }
}
