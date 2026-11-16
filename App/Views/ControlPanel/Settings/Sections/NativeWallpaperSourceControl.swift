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
    }
  }
}

struct NativeWallpaperSourcePicker: View {
  let kind: LockScreenState.Kind
  let dismiss: () -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  var body: some View {
    let source = controller.nativeWallpaperSource(kind)
    let choices = controller.automationTargets.wallpapers.filter {
      query.isEmpty || $0.title.localizedStandardContains(query)
    }
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: kind == .lockScreen ? L("Lock screen wallpaper") : L("Screen saver wallpaper"))
        .font(.panel(.sectionHeader))
      choiceButton(nil, title: L("Same as desktop"), source: source)
      if source.isUnavailable {
        Text(verbatim: source.title)
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.muted.color)
      }
      TextField(L("Search wallpapers"), text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($searchFocused)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(choices) { choice in
            choiceButton(choice.target.id, title: choice.title, source: source)
          }
        }
      }
      .overlay {
        if choices.isEmpty {
          Text("No wallpapers match.")
            .font(.panel(.body))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: dismiss)
          .buttonStyle(.panelSecondary)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(14)
    .frame(width: 380, height: 380)
    .onAppear { searchFocused = true }
  }

  private func choiceButton(_ id: String?, title: String, source: NativeWallpaperSource) -> some View {
    Button {
      let key = PanelActionCoordinator.key(
        "nativeWallpaperSource", detail: kind == .lockScreen ? "lockScreen" : "screenSaver")
      controller.launch(key) { try await controller.setNativeWallpaperSource(id, for: kind) }
      dismiss()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: source.wallpaperID == id ? "checkmark.circle.fill" : "circle")
        Text(verbatim: title)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.panel(.body))
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!source.isEnabled || controller.settings.isLocked())
    .accessibilityAddTraits(source.wallpaperID == id ? .isSelected : [])
  }
}
