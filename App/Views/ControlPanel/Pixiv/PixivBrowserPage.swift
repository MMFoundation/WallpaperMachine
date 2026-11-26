import SwiftUI

/// The pixiv page: rankings and tag search, the filters, a grid of works, and the paging bar.
///
/// The search bar above it is the detail column's (`PageSearchBar`): Return asks for the first
/// page afresh, typing waits for a pause. Under it a slim row holds Filter, the
/// ranking or search-order menu and Refresh, with a way to sign in while signed out. The inspector
/// shows the selected work. The paging bar is there while it has something to page or to say
/// about the works on show (`PixivPagerBar.isShown(for:)`).
struct PixivBrowserPage: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let browse = controller.pixivBrowse
    let activeChips = controller.shell.areFiltersShown ? [] : model.activeFilterChips
    let showsTranslationBar = Self.showsTranslationBar(
      browse: browse, translatesSearches: model.translatesSearches,
      appLanguage: controller.appLanguage.effective)
    VStack(spacing: 0) {
      PixivBar(height: 48) { PixivHeaderRow(browse: browse) }
      if case .author(let authorID, let authorName) = browse.scope {
        PixivBar(height: 36) {
          PixivAuthorBar(
            authorID: authorID, authorName: authorName,
            totalCount: browse.totalCount, hasExactTotal: browse.hasExactTotal,
            hasLoaded: browse.hasLoaded)
        }
      }
      if showsTranslationBar {
        PixivBar(height: 32) { PixivTranslationBar(translation: browse.translation) }
      }
      if !activeChips.isEmpty {
        // ActiveFilterChipsBar lays its content over a zero-min-width Color.clear filler,
        // matching PixivBar so narrow columns beside an open inspector never loop constraints.
        ActiveFilterChipsBar(
          chips: activeChips, identifierPrefix: "pixiv-active-filters",
          onClear: { _ = model.clearFilters() })
      }
      content(browse)
      if PixivPagerBar.isShown(for: browse) {
        PixivPagerBar(browse: browse)
      }
    }
    .onChange(of: model.isSignedIn, initial: true) { model.reconcileAccount() }
    .task { model.loadIfNeeded() }
    .onDisappear {
      // A search that was waiting for its pause still goes out, and the grid's place is stored at
      // once rather than at the end of its 400 ms wait.
      model.flushScrollReport()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pixiv-page")
  }

  /// Shows the translation bar whenever a search was translated into Japanese, or while searching
  /// a translatable non-Japanese query with translation switched off so the user can turn it back on.
  static func showsTranslationBar(
    browse: PixivBrowseState, translatesSearches: Bool, appLanguage: AppLanguage
  ) -> Bool {
    guard browse.scope == .explore, !browse.isDirectLookup else { return false }
    if browse.translation != nil { return true }
    return browse.isSearching && !translatesSearches
      && PixivSearchTranslator.isTranslatable(browse.query.text, app: appLanguage)
  }

  @ViewBuilder
  private func content(_ browse: PixivBrowseState) -> some View {
    if let empty = PixivEmptyState.make(browse) {
      PixivEmptyView(state: empty)
    } else {
      // The grid is laid over a flexible filler instead of being the page's own content. Its
      // lazy rows would otherwise feed the split view's hosting view an ideal height that keeps
      // changing as rows are built, and at the smallest window, beside an open inspector, AppKit
      // never finishes its constraint pass. A new listing or another page is a new grid, which
      // starts at the top.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          PixivGrid(works: browse.works, selectedID: browse.selectedID)
            .id(
              PixivScrollKey(
                listing: controller.pixiv.committedQuery?.listing, page: browse.pager.page))
        }
    }
  }
}

/// The tiles in a lazy grid that keeps its place across a closed window: the offset is reported
/// to the model as it changes, and the first grid of the next window scrolls back to it, once.
///
/// Restoring waits for a settled grid, as Installed's does: while a window lays out, the scroll
/// view reports a viewport of a few points and a content height that is only an estimate, so the
/// target is asserted again with each report until the grid is there (a few reports at most),
/// clamped to what the grid holds. Nothing is reported while it waits, so the grid's first look at
/// its top does not overwrite the place it is going back to.
///
/// Once nothing waits to be restored, only the offset is watched. A lazy grid's content height is
/// an estimate that moves while rows are built, and each scroll action asks the hosting view for
/// another update from inside AppKit's layout pass: at the smallest window beside an open
/// inspector, watching the height made that pass never end ("needing another Update Constraints
/// in Window pass").
private struct PixivGrid: View {
  let works: [PixivWork]
  let selectedID: String?

  @Environment(PanelController.self) private var controller
  @State private var position = ScrollPosition(edge: .top)
  @State private var pendingOffset: Double?
  @State private var restoreAttempts = 0

  /// A scroll view reporting less than this is still being laid out.
  private static let settledViewport: Double = 100
  private static let restoreAttempts = 8

  /// What the scroll view reports about itself: the offset, and its sizes only while a restore
  /// needs them.
  private struct Metrics: Equatable {
    var offset: Double
    var contentHeight: Double = 0
    var viewportHeight: Double = 0

    init(_ geometry: ScrollGeometry, measuresContent: Bool) {
      offset = geometry.contentOffset.y + geometry.contentInsets.top
      if measuresContent {
        contentHeight = geometry.contentSize.height
        viewportHeight = geometry.containerSize.height
      }
    }
  }

  var body: some View {
    let model = controller.pixivBrowser
    // Return or Space selects a focused tile, as a click does; Command-Return is the double click.
    TileGrid(works, onActivate: { model.select($0) }, onOpen: { model.doubleClick($0) }) { work in
      PixivTileCell(work: work, isSelected: work.id == selectedID)
    }
    .scrollPosition($position)
    .onScrollGeometryChange(for: Metrics.self) { [isRestoring = pendingOffset != nil] geometry in
      Metrics(geometry, measuresContent: isRestoring)
    } action: { _, metrics in
      scrolled(metrics, model: model)
    }
    .onAppear {
      let backTarget = model.takePendingBackScrollOffset()
      let stored = backTarget ?? model.takeRestoredScroll()
      guard let stored, stored > 0 else {
        // A grid that starts at its top says so: the scroll view reports only changes, so
        // without this a new listing or page would keep the place the grid before it had.
        model.scrolled(to: 0)
        return
      }
      pendingOffset = stored
      position.scrollTo(y: stored)
    }
    .accessibilityIdentifier("pixiv-grid")
  }

  private func scrolled(_ metrics: Metrics, model: PixivBrowserModel) {
    if let target = pendingOffset {
      guard metrics.viewportHeight > Self.settledViewport else { return }
      let clamped = min(target, max(0, metrics.contentHeight - metrics.viewportHeight))
      restoreAttempts += 1
      if abs(metrics.offset - clamped) <= 1 || restoreAttempts > Self.restoreAttempts {
        pendingOffset = nil
      } else {
        position.scrollTo(y: clamped)
        return
      }
    }
    model.scrolled(to: metrics.offset)
  }
}

/// A bar of controls laid over a filler of a fixed height, so that nothing in it feeds the split
/// view an ideal or minimum size of its own. The page column has no minimum width (the inspector
/// beside it already asks for 260 points of a 760-point window), and a button in the page's own
/// layout made the split view's detail pane report a new minimum size on every pass, which AppKit
/// never finishes laying out. The bar's controls shrink or leave instead (`PixivHeaderRow`).
struct PixivBar<Content: View>: View {
  let height: CGFloat
  @ViewBuilder var content: Content

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .overlay { content }
  }
}

/// What a grid belongs to: its listing and page. A different one is a different grid.
struct PixivScrollKey: Hashable {
  let listing: PixivListing?
  let page: Int
}

/// The slim row under the toolbar: Filter, the menu, and on the trailing side the sign-in link and
/// Refresh. It never asks for more width than it is given: the menu's label shortens first, then
/// the sign-in link takes its short words ("Sign in") and then leaves (the Filters sidebar still
/// has it). Refresh turns into a spinner while a load replaces works on show; while the page's
/// centre says it is loading, that is the one indicator, and Refresh only waits.
struct PixivHeaderRow: View {
  let browse: PixivBrowseState

  @Environment(PanelController.self) private var controller
  @State private var width: CGFloat = 0

  /// How much of the sign-in link a row of `width` points has room for.
  enum SignInStyle: Equatable { case text, short, hidden }

  static func signInStyle(forWidth width: CGFloat) -> SignInStyle {
    if width >= 560 { return .text }
    if width >= 380 { return .short }
    return .hidden
  }

  /// Whether Refresh shows a spinner: only while a load replaces works that are on show. A page
  /// with nothing on show has its loading said in the middle, once.
  static func refreshSpins(_ browse: PixivBrowseState) -> Bool {
    browse.isLoading && PixivEmptyState.make(browse) == nil
  }

  var body: some View {
    let model = controller.pixivBrowser
    HStack(spacing: 8) {
      if browse.canGoBack {
        Button {
          model.goBack()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chevron.left")
              .font(.panel(.controlSmall))
            if width >= 460 { Text("Back") }
          }
        }
        .buttonStyle(.panelCapsule)
        .keyboardShortcut("[", modifiers: .command)
        .help(L("Go back"))
        .accessibilityLabel(L("Go back"))
        .accessibilityIdentifier("pixiv-back")
      }
      PixivScopeSwitcher(current: browse.scope.tab) { model.open(tab: $0) }
      PixivFilterButton()
      PixivListingMenu(browse: browse)
      Spacer(minLength: 0)
      if !model.isSignedIn {
        signIn(Self.signInStyle(forWidth: width))
      }
      Button {
        model.refresh()
      } label: {
        Group {
          if Self.refreshSpins(browse) {
            ProgressRing(value: nil, lineWidth: 1.8).frame(width: 13, height: 13)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .frame(width: 14, height: 14)
      }
      .buttonStyle(.panelCapsule)
      .disabled(browse.isLoading || (browse.requiresSignIn && !browse.isSignedIn))
      .help(L("Refresh pixiv"))
      .accessibilityLabel(L("Refresh pixiv"))
      .accessibilityIdentifier("pixiv-refresh")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  @ViewBuilder
  private func signIn(_ style: SignInStyle) -> some View {
    let isSigningIn = controller.pixivAccount.isSigningIn
    switch style {
    case .text:
      PixivSignInButton(isSigningIn: isSigningIn).buttonStyle(.link).controlSize(.small)
    case .short:
      PixivSignInButton(isSigningIn: isSigningIn, isShort: true)
        .buttonStyle(.link)
        .controlSize(.small)
    case .hidden:
      EmptyView()
    }
  }
}

/// The Filter capsule: how many filters are on; it opens and closes the Filters sidebar.
private struct PixivFilterButton: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let shell = controller.shell
    let count = model.filterCount
    Button {
      shell.toggleFilters()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 11, weight: .semibold))
        Text("Filter")
        if count > 0 { CountBadge(count: count, style: .attention) }
      }
    }
    .buttonStyle(.panelCapsule(isActive: count > 0 || shell.areFiltersShown))
    .help(shell.areFiltersShown ? L("Hide filters") : L("Show filters"))
    .accessibilityValue(count > 0 ? L("\(count) active") : "")
    .accessibilityIdentifier("pixiv-filter-button")
  }
}

/// Top-level pixiv scopes (Explore, Bookmarks, Following): segmented control when wide, collapsing
/// into a compact menu when narrow so the split view never asks for more width than it has.
private struct PixivScopeSwitcher: View {
  let current: PixivScopeTab?
  let onSelect: (PixivScopeTab) -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ViewThatFits(in: .horizontal) {
      segments
      menu(showsTitle: true)
      menu(showsTitle: false)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("pixiv feeds"))
    .accessibilityIdentifier("pixiv-scopes")
  }

  private var segments: some View {
    HStack(spacing: 0) {
      ForEach(PixivScopeTab.allCases, id: \.self) { tab in
        let isCurrent = tab == current
        Button {
          onSelect(tab)
        } label: {
          Text(verbatim: tab.title)
            .font(.panel(isCurrent ? .calloutStrong : .callout))
            .foregroundStyle(isCurrent ? theme.surface.text.color : theme.surface.muted.color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
              if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(theme.surface.segmentSelected.color)
                  .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 1, y: 0.5)
              }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("pixiv-scope-\(tab.rawValue)")
      }
    }
    .padding(2)
    .background(theme.surface.hover.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func menu(showsTitle: Bool) -> some View {
    Menu {
      ForEach(PixivScopeTab.allCases, id: \.self) { tab in
        Button {
          onSelect(tab)
        } label: {
          if tab == current {
            Label {
              Text(verbatim: tab.title)
            } icon: {
              Image(systemName: "checkmark")
            }
          } else {
            Text(verbatim: tab.title)
          }
        }
      }
    } label: {
      let symbol = Image(systemName: current?.systemImage ?? "person.crop.circle")
      if showsTitle {
        HStack(spacing: 5) {
          symbol.font(.panel(.controlSmall))
          Text(verbatim: current?.title ?? L("Author"))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      } else {
        symbol.font(.panel(.controlSmall))
      }
    }
    .menuStyle(.button)
    .buttonStyle(.panelCapsule)
    .menuIndicator(showsTitle ? .visible : .hidden)
    .help(current?.title ?? L("pixiv feeds"))
    .accessibilityLabel(Text("pixiv feeds"))
    .accessibilityValue(current.map { Text(verbatim: $0.title) } ?? Text(verbatim: ""))
  }
}

/// Banner shown while browsing a specific artist's works: artist name via `Text(verbatim:)`,
/// works count, and an external link to their pixiv profile.
private struct PixivAuthorBar: View {
  let authorID: String
  let authorName: String
  let totalCount: Int
  let hasExactTotal: Bool
  let hasLoaded: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let displayName = authorName.isEmpty ? authorID : authorName
    HStack(spacing: 8) {
      Image(systemName: "person.crop.circle")
        .font(.panel(.sectionHeader))
        .foregroundStyle(theme.surface.muted.color)
        .accessibilityHidden(true)
      Text(verbatim: displayName)
        .font(.panel(.sectionHeader))
        .foregroundStyle(theme.surface.text.color)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(displayName)
        .accessibilityAddTraits(.isHeader)
      if hasLoaded {
        let countText = hasExactTotal
          ? L("\(totalCount) works")
          : L("At least \(totalCount) works")
        Text(verbatim: countText)
          .font(.panel(.callout))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let profileURL = ExternalLink.pixivAuthor(id: authorID) {
        Button {
          ExternalLink.open(profileURL, using: controller.pixivBrowser.openURL)
        } label: {
          Label("View on pixiv", systemImage: "arrow.up.right.square")
            .font(.panel(.callout))
        }
        .buttonStyle(.panelLink)
        .fixedSize()
        .accessibilityIdentifier("pixiv-author-external")
      }
    }
    .padding(.horizontal, 20)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pixiv-author-bar")
  }
}

/// The menu beside Filter: rankings while browsing Explore with an empty search box, search orders
/// while searching tags, or Public/Private bookmarks while viewing Bookmarks.
private struct PixivListingMenu: View {
  let browse: PixivBrowseState

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let query = model.query
    switch browse.scope {
    case .explore where !model.isDirectLookup:
      let isSearching = model.isSearching
      let current = isSearching ? query.order.title : query.ranking.title
      let label = isSearching ? L("Search order") : L("Ranking")
      Menu {
        if isSearching {
          Picker(
            label,
            selection: Binding(get: { query.order }, set: { model.choose(order: $0) })
          ) {
            ForEach(PixivSearchOrder.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        } else {
          Picker(
            label,
            selection: Binding(get: { query.ranking }, set: { model.choose(ranking: $0) })
          ) {
            ForEach(model.rankingChoices, id: \.self) { Text(verbatim: $0.title).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
      } label: {
        HStack(spacing: 5) {
          Text(verbatim: current).lineLimit(1).truncationMode(.tail)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.secondary)
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.panelCapsule)
      .layoutPriority(-1)
      .accessibilityLabel(label)
      .accessibilityValue(current)
      .accessibilityIdentifier("pixiv-listing-menu")
    case .bookmarks(let visibility) where model.isSignedIn:
      let label = L("Bookmarks visibility")
      Menu {
        Picker(
          label,
          selection: Binding(
            get: { visibility }, set: { model.choose(bookmarkVisibility: $0) })
        ) {
          ForEach(PixivBookmarkVisibility.allCases, id: \.self) {
            Text(verbatim: $0.title).tag($0)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        HStack(spacing: 5) {
          Text(verbatim: visibility.title).lineLimit(1).truncationMode(.tail)
          Image(systemName: "chevron.up.chevron.down")
            .font(.panel(.mark))
            .foregroundStyle(.secondary)
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.panelCapsule)
      .layoutPriority(-1)
      .accessibilityLabel(label)
      .accessibilityValue(visibility.title)
      .accessibilityIdentifier("pixiv-bookmarks-visibility")
    default:
      EmptyView()
    }
  }
}

/// What the page shows in place of the grid: sign-in required, loading, an error, filters that hide
/// the whole page, or nothing found.
private struct PixivEmptyView: View {
  let state: PixivEmptyState

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let account = controller.pixivAccount
    switch state {
    case .loading:
      PanelEmptyState(
        "Loading pixiv", systemImage: "paintpalette",
        description: "Fetching illustrations from pixiv."
      ) {
        LoadingRing()
      }
    case .signInRequired(let feed):
      let title =
        feed == .bookmarks
        ? L("Sign in to see your bookmarks")
        : L("Sign in to see following works")
      let description =
        feed == .bookmarks
        ? L("Sign in to pixiv to browse your bookmarked illustrations.")
        : L("Sign in to pixiv to browse new illustrations from artists you follow.")
      let symbol = feed == .bookmarks ? "bookmark" : "person.2"
      PanelEmptyState(verbatim: title, systemImage: symbol, description: description) {
        Button {
          controller.launch("pixivSignIn") { try await controller.pixivSignIn() }
        } label: {
          if account.isSigningIn {
            Label("Show sign-in window", systemImage: "macwindow")
          } else {
            Label("Sign in to Pixiv", systemImage: "person.crop.circle")
          }
        }
        .buttonStyle(.panelPrimary)
        .accessibilityIdentifier("pixiv-empty-sign-in")
      }
    case .error(let message):
      PanelEmptyState(
        verbatim: L("pixiv unavailable"), systemImage: "exclamationmark.triangle",
        description: message
      ) {
        Button {
          controller.launch("pixivRetry") { try await controller.pixivRetry() }
        } label: {
          Label("Try again", systemImage: "arrow.clockwise")
        }
      }
    case .filtersHideAll:
      PanelEmptyState(
        verbatim: L("No matching illustrations"), systemImage: "line.3.horizontal.decrease",
        description: L("No illustrations in this listing match your filters.")
      ) {
        Button("Clear filters") { model.clearFilters() }
      }
    case .nothing(let searching):
      PanelEmptyState(
        verbatim: L("No illustrations found"), systemImage: "photo.on.rectangle",
        description: searching
          ? L("Try other tags. pixiv matches tags, not titles.")
          : L("pixiv returned an empty ranking.")
      ) {
        if searching { Button("Clear search") { model.clearSearch() } }
      }
    case .emptyFeed(let feed):
      switch feed {
      case .author:
        PanelEmptyState(
          verbatim: L("No illustrations found"), systemImage: "person.crop.circle",
          description: L("This artist has no illustrations to show.")
        ) {
          if controller.pixivBrowse.canGoBack {
            Button("Go back") { model.goBack() }
          }
        }
      case .bookmarks(let visibility):
        PanelEmptyState(
          verbatim: L("No bookmarks yet"), systemImage: "bookmark",
          description: visibility == .private
            ? L("Illustrations you bookmark privately on pixiv appear here.")
            : L("Illustrations you bookmark on pixiv appear here.")
        ) {
          Button("Explore pixiv") { model.open(tab: .explore) }
            .buttonStyle(.panelPrimary)
        }
      case .following:
        PanelEmptyState(
          verbatim: L("No illustrations from followed artists"), systemImage: "person.2",
          description: L("New illustrations from artists you follow on pixiv appear here.")
        ) {
          Button("Explore pixiv") { model.open(tab: .explore) }
            .buttonStyle(.panelPrimary)
        }
      }
    }
  }
}
