import SwiftUI

/// A reusable searchable popover that chooses a wallpaper (as cover thumbnails) or, optionally, a
/// saved playlist. Used by desktop Space tiles, automatic wallpaper rules, day/night playlists and
/// native lock-screen / screen-saver wallpaper pickers.
struct WallpaperThumbnailChooser: View {
  /// Optional action in the footer that clears or resets the selection (such as "Leave as it is",
  /// "Same as desktop", or "Same as Desktop 1").
  struct ClearOption {
    let title: String
    var help: String? = nil
    var isSelected = false
    var isDisabled = false
    let action: () -> Void
  }

  let title: String
  let wallpapers: [AutomationTargets.Choice]
  var playlists: [AutomationTargets.Choice] = []
  let selected: WallpaperAutomationTarget?
  /// Shown above the search field when the saved choice no longer resolves, without overwriting it.
  var unavailableNote: String? = nil
  var clearOption: ClearOption? = nil
  var isActionDisabled = false
  let onSelect: (WallpaperAutomationTarget) -> Void
  let onDismiss: () -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  private static let columns = [GridItem(.adaptive(minimum: 124, maximum: 160), spacing: 10)]

  var body: some View {
    let filteredWallpapers = Self.filter(wallpapers, query: query)
    let filteredPlaylists = Self.filter(playlists, query: query)
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: title)
        .font(.panel(.sectionHeader))
        .foregroundStyle(theme.surface.text.color)
      if let unavailableNote {
        Text(verbatim: unavailableNote)
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.muted.color)
      }
      TextField(L("Search wallpapers"), text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($searchFocused)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if filteredWallpapers.isEmpty && filteredPlaylists.isEmpty {
            Text("No wallpapers match.")
              .font(.panel(.callout))
              .foregroundStyle(theme.surface.muted.color)
              .frame(maxWidth: .infinity, minHeight: 80)
          }
          if !filteredWallpapers.isEmpty {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
              ForEach(filteredWallpapers) { choice in
                wallpaperButton(choice)
              }
            }
          }
          if !filteredPlaylists.isEmpty {
            Text("Saved playlists")
              .font(.panel(.calloutStrong))
              .foregroundStyle(theme.surface.muted.color)
            ForEach(filteredPlaylists) { choice in
              playlistButton(choice)
            }
          }
        }
        .padding(.vertical, 2)
      }
      HStack {
        if let clearOption {
          Button {
            clearOption.action()
            onDismiss()
          } label: {
            Text(verbatim: clearOption.title)
          }
          .buttonStyle(.panelSecondary)
          .disabled(isActionDisabled || clearOption.isDisabled)
          .help(clearOption.help ?? "")
          .accessibilityLabel(Text(verbatim: clearOption.title))
          .accessibilityAddTraits(clearOption.isSelected ? .isSelected : [])
        }
        Spacer()
        Button("Cancel", role: .cancel, action: onDismiss)
          .buttonStyle(.panelSecondary)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(14)
    .frame(width: 560, height: 460)
    .onAppear { searchFocused = true }
  }

  private func wallpaperButton(_ choice: AutomationTargets.Choice) -> some View {
    let row = controller.libraryRow(id: choice.target.id)
    let isChosen = selected == choice.target
    return Button {
      onSelect(choice.target)
      onDismiss()
    } label: {
      WallpaperTile(
        title: choice.title, subtitle: row?.kind.label, kind: row?.kind.label ?? "",
        isSelected: isChosen
      ) {
        PanelImage(source: row?.coverSource, pointSize: 160)
      }
    }
    .buttonStyle(.plain)
    .disabled(isActionDisabled)
    .accessibilityLabel(Text(verbatim: choice.title))
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }

  private func playlistButton(_ choice: AutomationTargets.Choice) -> some View {
    let isChosen = selected == choice.target
    return Button {
      onSelect(choice.target)
      onDismiss()
    } label: {
      Label {
        Text(verbatim: choice.title)
          .font(.panel(.body))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
          .truncationMode(.tail)
      } icon: {
        Image(systemName: isChosen ? "checkmark" : "rectangle.stack")
          .foregroundStyle(isChosen ? theme.accent.accent.color : theme.surface.muted.color)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isActionDisabled)
    .accessibilityLabel(Text(verbatim: choice.title))
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }

  /// Filters choices so every whitespace-separated word of `query` matches `choice.title`.
  static func filter(_ choices: [AutomationTargets.Choice], query: String) -> [AutomationTargets.Choice] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return choices }
    return choices.filter { choice in words.allSatisfy { choice.title.localizedStandardContains($0) } }
  }
}

/// A compact settings button showing the currently selected wallpaper (with a miniature cover) or
/// saved playlist, opening `WallpaperThumbnailChooser` in a popover. Its width stays bounded like
/// `DisplaysTitleMenu`, so long wallpaper names never widen narrow settings columns.
struct WallpaperChooserTrigger: View {
  let title: String
  let popoverTitle: String
  let wallpapers: [AutomationTargets.Choice]
  var playlists: [AutomationTargets.Choice] = []
  let selected: WallpaperAutomationTarget?
  var unavailableNote: String? = nil
  var clearOption: WallpaperThumbnailChooser.ClearOption? = nil
  var width: CGFloat = 200
  var alignment: Alignment = .trailing
  let onSelect: (WallpaperAutomationTarget) -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var showsChooser = false

  var body: some View {
    Button {
      showsChooser = true
    } label: {
      HStack(spacing: 6) {
        previewBadge
        Text(verbatim: title)
          .font(.panel(.body))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.up.chevron.down")
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.muted.color)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(.panelSecondary)
    .frame(minWidth: min(120, width), idealWidth: width, maxWidth: width, alignment: alignment)
    .accessibilityValue(Text(verbatim: title))
    .help(title)
    .popover(isPresented: $showsChooser, arrowEdge: .bottom) {
      WallpaperThumbnailChooser(
        title: popoverTitle, wallpapers: wallpapers, playlists: playlists, selected: selected,
        unavailableNote: unavailableNote, clearOption: clearOption,
        onSelect: onSelect, onDismiss: { showsChooser = false }
      )
      .panelPresentationLocale()
    }
  }

  @ViewBuilder
  private var previewBadge: some View {
    if let selected {
      switch selected.kind {
      case .wallpaper:
        if let row = controller.libraryRow(id: selected.id) {
          PanelImage(source: row.coverSource, pointSize: 36)
            .frame(width: 20, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
        }
      case .playlist:
        if playlists.contains(where: { $0.target == selected }) {
          Image(systemName: "rectangle.stack")
            .font(.panel(.caption))
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityHidden(true)
        }
      }
    }
  }
}
