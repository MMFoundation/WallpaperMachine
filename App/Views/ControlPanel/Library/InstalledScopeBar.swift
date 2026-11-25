import SwiftUI

/// The row of views above the Library grid: All wallpapers, Favorites, and a Collections dropdown
/// capsule (showing the active collection name and count while one is on show). One is lit: the
/// view the grid shows.
///
/// The Collections dropdown switches directly between local collections or opens new-collection
/// creation even when the Filters sidebar is closed. All wallpapers carries an accent dot while
/// Workshop wallpapers have an update, with how many as its tooltip and for VoiceOver.
///
/// Play at the end, with its order menu, turns the view on show into the target display's rotation,
/// so a collection plays from where it is chosen rather than only from Settings › Displays.
///
/// In a narrow page column the row gives up words in the header row's tiers (`HeaderTier`): first
/// Play and its order become their symbols, then All wallpapers, Favorites and an inactive
/// Collections menu keep only their symbols (and counts), their names staying as tooltip and
/// VoiceOver name. An active collection keeps its name in every tier, since it is the only place
/// that says which collection is on show; a name too long for the capsule shows in full as its
/// tooltip.
struct InstalledScopeBar: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    // The counts say nothing while the library loads, when they would say there is nothing. Read
    // once here, along with collections and Play's state: every tier is built to be measured, and
    // each read would otherwise repeat across all three tiers.
    let counts = controller.isLibraryLoading ? nil : controller.sidebarCounts
    let collections = controller.collectionRows
    let play = ScopePlayButtons.Reading(controller: controller, scope: controller.library.scope)
    // One `ViewThatFits` around the whole row, as the header row has: one inside the row would be
    // offered the room its neighbours leave, which changes as they lay out.
    ViewThatFits(in: .horizontal) {
      row(.regular, counts: counts, collections: collections, play: play).padding(.horizontal, 20)
      row(.compact, counts: counts, collections: collections, play: play).padding(.horizontal, 20)
      row(.tight, counts: counts, collections: collections, play: play).padding(.horizontal, 12)
    }
    .frame(height: 34)
    .padding(.top, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Library"))
  }

  /// The row in `tier`. The tight one is the last resort and must still shrink: an active
  /// collection's name truncates, and only the Play capsule, by then two symbols, keeps its size.
  private func row(
    _ tier: HeaderTier, counts: SidebarCounts?, collections: [CollectionRow],
    play: ScopePlayButtons.Reading
  ) -> some View {
    let model = controller.library
    let scope = model.scope
    return HStack(spacing: tier == .tight ? 4 : 6) {
      ScopeChip(
        title: L("All wallpapers"), systemImage: "square.grid.2x2", count: counts?.all,
        isOn: scope == .all, showsTitle: tier != .tight, note: counts?.updateTooltip,
        identifier: "scope-all"
      ) { model.show(.all) }
      ScopeChip(
        title: L("Favorites"), systemImage: "heart", count: counts?.favorites,
        isOn: scope == .favorites, showsTitle: tier != .tight, identifier: "scope-favorites"
      ) { model.show(.favorites) }
      ScopeCollectionsMenu(
        tier: tier, collections: collections, shown: model.shownCollection, counts: counts)
      Spacer(minLength: 0)
      ScopePlayButtons(scope: scope, reading: play, showsWords: tier.showsLabels)
    }
  }
}

/// The Collections dropdown capsule: switches directly between local collections, returns to All
/// wallpapers, or starts creating a new collection even while the Filters sidebar is closed.
/// When a collection is on show, it lights up with that collection's name and count.
private struct ScopeCollectionsMenu: View {
  let tier: HeaderTier
  let collections: [CollectionRow]
  let shown: CollectionRow?
  let counts: SidebarCounts?

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.library
    let shownCount = shown.flatMap { active in
      counts?.collections.first { $0.id == active.id }?.count ?? active.count
    }
    Menu {
      if shown != nil {
        Button("Show all wallpapers") { model.show(.all) }
        Divider()
      }
      if collections.isEmpty {
        Text("No collections yet")
      } else {
        ForEach(collections) { item in
          let isSelected = item.id == shown?.id
          let formattedCount = item.count.formatted(.number.locale(PanelLocale.shared.locale))
          Toggle(
            isOn: Binding(
              get: { isSelected },
              set: { _ in model.show(isSelected ? .all : .collection(item.id)) })
          ) {
            Text(verbatim: "\(item.name) (\(formattedCount))")
          }
        }
      }
      Divider()
      Button {
        model.beginCreatingCollectionInSidebar()
      } label: {
        Label("New collection…", systemImage: "plus")
      }
      .disabled(controller.shell.collectionEditor.isChanging)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: shown == nil ? "folder" : "folder.fill")
          .font(.system(size: 11, weight: .semibold))
          .fixedSize()
          .accessibilityHidden(true)
        if let shown {
          Text(verbatim: shown.name)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(-1)
          if let shownCount {
            Text(shownCount, format: .number)
              .monospacedDigit()
              .foregroundStyle(theme.accent.accent.color)
              .fixedSize()
          }
        } else if tier != .tight {
          Text("Collections").lineLimit(1)
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 8.5, weight: .bold))
          .fixedSize()
          .accessibilityHidden(true)
      }
      .accessibilityElement(children: .combine)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.panelCapsule(isActive: shown != nil, horizontalPadding: tier.capsulePadding))
    .help(tooltip)
    .accessibilityLabel(Text(verbatim: shown?.name ?? L("Collections")))
    .accessibilityValue(accessibilityValue(count: shownCount))
    .accessibilityAddTraits(shown != nil ? .isSelected : [])
    .accessibilityIdentifier(shown != nil ? "scope-collection" : "scope-collections")
    .frame(maxWidth: shown != nil ? 260 : nil, alignment: .leading)
    .fixedSize(horizontal: shown == nil, vertical: true)
  }

  private var tooltip: String {
    guard let shown else { return L("Collections") }
    return [shown.name, L("Switch collection")].joined(separator: " · ")
  }

  private func accessibilityValue(count: Int?) -> Text {
    guard let count else { return Text(verbatim: "") }
    return Text(verbatim: count.formatted(.number.locale(PanelLocale.shared.locale)))
  }
}

/// Play and its order menu, the two halves of one capsule: the target display rotates through the view on show and changes to it
/// at once. Play keeps the order that display already uses; the menu beside it shows that order and
/// plays in the one chosen. Unavailable while the view has no wallpaper that can play or the target
/// display has no playlist of its own (off, or a mirror). Without words, Play is its symbol and the
/// menu shows the order's symbol; the names stay as tooltips (the order's after "Order") and as
/// VoiceOver names and values.
private struct ScopePlayButtons: View {
  /// What the capsule shows of the controller, read by the row once for all of its tiers: whether
  /// Play is available, which walks the library, and the target display's order.
  struct Reading {
    let isEnabled: Bool
    let order: PlaylistOrder

    @MainActor init(controller: PanelController, scope: LibraryScope) {
      isEnabled =
        controller.targetDisplay?.isSelectable == true && !controller.isBusy(ScopePlayButtons.key)
        && controller.canPlay(scope.playlistSource)
      order = controller.playlistState(for: controller.targetDisplayID).playlist.order
    }
  }

  static let key = PanelActionCoordinator.key("playlistPlay")

  let scope: LibraryScope
  let reading: Reading
  let showsWords: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let key = Self.key
    let isEnabled = reading.isEnabled
    let order = reading.order
    let orderName = order == .shuffle ? L("Shuffle") : L("In order")
    HStack(spacing: 0) {
      Button {
        play(order: order, key: key)
      } label: {
        if showsWords {
          Label("Play", systemImage: "play.fill")
        } else {
          Label("Play", systemImage: "play.fill").labelStyle(.iconOnly)
        }
      }
      .buttonStyle(PlaySegmentStyle(leading: 10, trailing: 8))
      .help(
        order == .shuffle
          ? L("Plays these wallpapers in a random order on this display")
          : L("Plays these wallpapers in order on this display")
      )
      .accessibilityValue(Text(verbatim: orderName))
      .accessibilityIdentifier("scope-play")
      Rectangle()
        .fill(theme.surface.divider.color)
        .frame(width: 1, height: 14)
        .accessibilityHidden(true)
      Menu {
        // Toggles rather than a picker, so choosing the order already ticked still plays.
        ForEach([PlaylistOrder.sequential, .shuffle], id: \.self) { choice in
          Toggle(
            isOn: Binding(get: { order == choice }, set: { _ in play(order: choice, key: key) })
          ) {
            if choice == .shuffle {
              Label("Shuffle", systemImage: "shuffle")
            } else {
              Label("In order", systemImage: "repeat")
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          if !showsWords {
            Image(systemName: order == .shuffle ? "shuffle" : "repeat")
          } else if order == .shuffle {
            Text("Shuffle")
          } else {
            Text("In order")
          }
          Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(PlaySegmentStyle(leading: 8, trailing: 10))
      // Without words the menu is only the order's symbol (`repeat` alone reads as "loop"), so the
      // tooltip names the order, as a chip without its name puts it first in its tooltip.
      .help(showsWords ? L("Order") : [L("Order"), orderName].joined(separator: " · "))
      .accessibilityLabel(Text("Order"))
      .accessibilityValue(Text(verbatim: orderName))
      .accessibilityIdentifier("scope-play-order")
    }
    .background(theme.surface.hover.color, in: Capsule())
    .clipShape(Capsule())
    .panelDisabledOpacity(isEnabled)
    .fixedSize()
    .disabled(!isEnabled)
  }

  private func play(order: PlaylistOrder, key: String) {
    let source = scope.playlistSource
    controller.launch(key) { [controller] in try await controller.playPlaylist(source, order: order) }
  }
}

/// One half of the Play capsule: the capsule's type and height, lit on its own on hover and press
/// by a pill inset within the half.
/// The capsule's resting fill and its dimming while unavailable belong to the whole.
private struct PlaySegmentStyle: ButtonStyle {
  let leading: CGFloat
  let trailing: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    PlaySegmentBody(configuration: configuration, leading: leading, trailing: trailing)
  }
}

private struct PlaySegmentBody: View {
  let configuration: ButtonStyleConfiguration
  let leading: CGFloat
  let trailing: CGFloat

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(theme.surface.text.color)
      .lineLimit(1)
      .padding(.leading, leading)
      .padding(.trailing, trailing)
      .frame(minHeight: 26)
      // An inset pill, so the light stops short of the divider and the capsule's edge.
      .background(Capsule().fill(background).padding(2))
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    guard isEnabled else { return .clear }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.selected.color : .clear
  }
}

/// One view of the library as a capsule: its symbol, its name and its count, tinted while it is the
/// one on show. A collection's chip ends in a cross, since pressing it puts the collection away.
/// Without room for its name it shows its symbol and count, and the name leads its tooltip, as it
/// does for a name the chip may cut short (`namesInTooltip`); VoiceOver reads the name either way.
private struct ScopeChip: View {
  /// The view's name: a phrase already in the panel's language, or a collection's own name, which
  /// is never looked up.
  let title: String
  let systemImage: String
  let count: Int?
  let isOn: Bool
  var showsTitle = true
  var note: String?
  var closes = false
  /// Whether the name leads the tooltip even while the chip shows it: a collection's own name can be
  /// too long for the chip, which then cuts it short.
  var namesInTooltip = false
  /// The tooltip, when the note does not give one.
  var help: String?
  let identifier: String
  let action: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
        if showsTitle {
          Text(verbatim: title).truncationMode(.tail)
        }
        if let count {
          Text(count, format: .number)
            .monospacedDigit()
            .foregroundStyle(isOn ? theme.accent.accent.color : theme.surface.muted.color)
        }
        if note != nil {
          Circle().fill(.tint).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        if closes {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.panelCapsule(isActive: isOn))
    .help(tooltip)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityValue(value)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }

  /// The note or the help; led by the name when the chip does not show it, or may cut it short.
  private var tooltip: String {
    let detail = note ?? help
    guard !showsTitle || namesInTooltip else { return detail ?? "" }
    return [title, detail].compactMap { $0 }.joined(separator: " · ")
  }

  /// The count first, then the update note.
  private var value: Text {
    let parts = [count.map { $0.formatted(.number.locale(PanelLocale.shared.locale)) }, note]
    return Text(verbatim: parts.compactMap { $0 }.joined(separator: ", "))
  }
}
