import AppKit
import SwiftUI

/// One tile of the Workshop grid: the picture, its marks, its title and kind, and the download ring.
///
/// The tile asks the controller for everything it wears (`workshopTile(for:)`), so a progress tick
/// re-renders only the tile whose download moved and never the grid. A click selects, a double-click
/// does what the state of the item calls for (`WorkshopBrowserModel.doubleClick`), and the ring has
/// a click of its own.
struct WorkshopTileCell: View {
  let item: WorkshopItem

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The tile never draws its picture larger than this, in points; the stills are decoded to it.
  static let pointSize: CGFloat = 192

  var body: some View {
    let model = controller.workshopBrowser
    let tile = controller.workshopTile(for: item)
    let isSelected = controller.workshop.selectedItem?.id == item.id
    let marks = Self.marks(of: tile)
    WallpaperTile(
      title: item.title, subtitle: subtitle, kind: item.kindLabel, isSelected: isSelected
    ) {
      artwork(tile: tile, model: model)
    }
    .topLeadingBadge { MarkStack(marks: marks) }
    .contentShape(Rectangle())
    // One tap handler tells a click from a double-click by the event itself, so a click selects at
    // once and the second click of a double-click does not wait for a timer. A button on top (the
    // ring) takes its own click first.
    .onTapGesture {
      if NSApp.currentEvent?.clickCount == 2 { model.doubleClick(item) } else { model.select(item) }
    }
    // Built lazily when the menu opens so tiles scrolling through the grid pay nothing.
    .contextMenu {
      WorkshopTileContextMenu(item: item)
        .environment(controller)
        .environment(\.locale, locale)
    }
    .accessibilityLabel(Text(verbatim: accessibilityLabel(marks: marks)))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityActionIfNamed(Self.doubleClickName(controller.workshopDoubleClick(for: item))) {
      model.doubleClick(item)
    }
    .onScrollVisibilityChange(threshold: 0.25) { model.previews.setOnScreen(item.id, $0) }
    .onDisappear { model.previews.setOnScreen(item.id, false) }
  }

  // MARK: Parts

  /// The kind, and how many people subscribe to it: "Scene · 48K".
  private var subtitle: String {
    guard !item.isCollection, item.subscriptions > 0 else { return item.kindLabel }
    let count = item.subscriptions.formatted(
      .number.notation(.compactName).locale(locale))
    return "\(item.kindLabel) · \(count)"
  }

  @ViewBuilder
  private func artwork(tile: WorkshopTile, model: WorkshopBrowserModel) -> some View {
    let previews = model.previews
    let playing = !tile.isInstalled && previews.isPlaying(item.id)
    ZStack {
      PanelImage(source: still(tile), pointSize: Self.pointSize)
      if playing, let data = previews.animation(for: item.id) {
        // The animation lies over the still; the still stays under it for when it is released.
        AnimatedPreview(data: data, isPlaying: true)
          .transition(.opacity)
      }
      if let ring = tile.download {
        // The picture dims under a ring, so the ring reads on any wallpaper.
        theme.surface.scrim.color
        GeometryReader { proxy in
          let diameter = min(WorkshopTileRing.largestDiameter, proxy.size.width * 0.52)
          WorkshopTileRing(state: ring, diameter: diameter) {
            controller.downloads.perform(ring.action, forItem: item.id)
          }
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: playing)
  }

  /// A wallpaper that is installed shows the library's own cover, the picture the Installed page
  /// shows, until that is ready; every other tile shows Steam's still.
  private func still(_ tile: WorkshopTile) -> PanelImageSource? {
    if tile.isInstalled, let cover = controller.workshopInstalledStill(for: item.id) {
      return cover
    }
    return item.thumbnail
  }

  /// The name VoiceOver's actions menu gives what the double-click does, by the same rule the
  /// double-click follows (`PanelController.workshopDoubleClick`), so the name never promises what
  /// the click will not do. Only selecting has no action of its own: a download under way, or a
  /// wallpaper in the library that the target display cannot show (disabled or mirroring) or whose
  /// type it cannot name.
  static func doubleClickName(_ doubleClick: WorkshopTileDoubleClick) -> String? {
    switch doubleClick {
    case .openCollection: L("Open collection")
    case .apply: L("Apply wallpaper")
    case .continueSetup: L("Continue setup")
    case .requestDownload: L("Download")
    case .select: nil
    }
  }

  // MARK: Marks

  /// The marks in the tile's top corner, in the order they stack.
  static func marks(of tile: WorkshopTile) -> [TileMark] {
    var marks: [TileMark] = []
    if tile.isInstalled { marks.append(.inLibrary) }
    if tile.item.isApproved { marks.append(.approved) }
    if tile.isFavorite { marks.append(.favorite) }
    if tile.isSubscribed { marks.append(.subscribed) }
    if tile.item.isPreset { marks.append(.preset) }
    return marks
  }

  /// "Title, Scene, In your library, Favorite": what VoiceOver reads for the tile.
  private func accessibilityLabel(marks: [TileMark]) -> String {
    ([item.title, item.kindLabel] + marks.map(\.label)).joined(separator: ", ")
  }
}

/// The marks of a tile, stacked in its top leading corner as small round chips.
private struct MarkStack: View {
  let marks: [TileMark]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(marks, id: \.self) { mark in
        TileMarkChip(mark)
      }
    }
  }
}

private extension View {
  /// An accessibility action under `name`, or none when there is no name.
  @ViewBuilder
  func accessibilityActionIfNamed(_ name: String?, _ action: @escaping () -> Void) -> some View {
    if let name {
      accessibilityAction(named: Text(verbatim: name), action)
    } else {
      self
    }
  }
}

/// Right-click actions for a Steam Workshop tile, evaluated lazily only when opened.
struct WorkshopTileContextMenu: View {
  let item: WorkshopItem

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.workshopBrowser
    let download = controller.workshopItemDownload(for: item)
    if item.isCollection {
      Button {
        model.openCollection(item)
      } label: {
        Label("Open collection", systemImage: "square.stack")
      }
    } else if download.isInstalled {
      Button {
        let id = item.id
        controller.launch(PanelActionCoordinator.key("activate", id: id)) { [controller] in
          try await controller.activate(id)
        }
      } label: {
        Label("Apply wallpaper", systemImage: ApplyOffer.symbol)
      }
      .disabled(!controller.mediaApplyTarget.canShowWallpaper || !item.canRunOnMac)
      Button {
        let id = item.id
        controller.launch(PanelActionCoordinator.key("showInstalled", id: id)) { [controller] in
          try await controller.showInstalled(id)
        }
      } label: {
        Label("Show in library", systemImage: "photo")
      }
    } else {
      downloadItems(download)
    }

    if controller.workshop.steamWebSession != nil, !item.isCollection {
      subscriptionButton
    }

    if let authorID = item.authorProfileID, !isShowingAuthor(authorID) {
      Button {
        model.openAuthor(of: item)
      } label: {
        if !item.creator.isEmpty,
          item.creator != L("Workshop creator"),
          item.creator != String(localized: "Workshop creator"),
          item.creator != "Workshop creator"
        {
          Label {
            Text(verbatim: item.creator)
          } icon: {
            Image(systemName: "person.crop.rectangle.stack")
          }
        } else {
          Label("More by this author", systemImage: "person.crop.rectangle.stack")
        }
      }
    }

    if ExternalLink.workshopItem(id: item.id) != nil {
      Divider()
      Button {
        model.viewOnSteam(item)
      } label: {
        Label("View on Steam Workshop", systemImage: "arrow.up.right.square")
      }
      Button {
        model.copyLink(for: item)
      } label: {
        Label("Copy link", systemImage: "link")
      }
    }
  }

  @ViewBuilder
  private func downloadItems(_ download: WorkshopItemDownload) -> some View {
    let downloads = controller.downloads
    let key = PanelActionCoordinator.key("requestDownload", id: item.id)
    switch download.action {
    case .openCollection:
      EmptyView()
    case .resume:
      Button {
        downloads.perform(.resume, forItem: item.id)
      } label: {
        Label("Resume download", systemImage: DownloadRowAction.resume.systemImage)
      }
      .disabled(controller.isBusy(DownloadRowAction.resume.key(.steam, id: item.id)))
    case .continueSetup:
      Button {
        downloads.openDialog(for: item.id)
      } label: {
        Label("Continue setup", systemImage: "checkmark.shield")
      }
    case .finishSignIn:
      Button {
        downloads.openDialog(for: item.id)
      } label: {
        Label("Finish sign-in", systemImage: "checkmark.shield")
      }
    case .inProgress:
      Button {
        downloads.showDownloads()
      } label: {
        Label("Show in downloads", systemImage: "arrow.down.circle")
      }
    case .download(let again, _):
      Button {
        downloads.requestDownload(item)
      } label: {
        if again {
          Label("Download again", systemImage: "arrow.down.circle")
        } else {
          Label("Download", systemImage: "arrow.down.circle")
        }
      }
      .disabled(controller.isBusy(key))
      if download.offersDownloadAndApply {
        Button {
          downloads.requestDownload(item, apply: true)
        } label: {
          Label("Download and apply", systemImage: ApplyOffer.symbol)
        }
        .disabled(controller.isBusy(key))
      }
    }
  }

  private var subscriptionButton: some View {
    let subscribed = controller.workshop.subscribedIDs.contains(item.id)
    let key = PanelActionCoordinator.key("workshopSubscription", id: item.id)
    return Button {
      let item = item
      controller.launch(key) { [controller] in
        try await controller.setWorkshopSubscribed(!subscribed, item: item)
      }
    } label: {
      if subscribed {
        Label("Unsubscribe on Steam", systemImage: "bookmark.slash")
      } else {
        Label("Subscribe on Steam", systemImage: "bookmark")
      }
    }
    .disabled(controller.isBusy(key) || !controller.workshop.subscriptionsKnown)
  }

  private func isShowingAuthor(_ authorID: String) -> Bool {
    if case .creator(let shown, _) = controller.workshop.source { return shown == authorID }
    return false
  }
}
