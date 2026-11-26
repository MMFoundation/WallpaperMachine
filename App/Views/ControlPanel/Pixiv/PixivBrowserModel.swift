import AppKit
import Observation

/// The groups of the Filters sidebar, which can each be folded.
enum PixivFilterGroup: CaseIterable, Hashable {
  case account, orientation, minimumSize, ageRating, ai
}

/// The pixiv page: the query being edited, the rules that turn edits into searches, the paging bar
/// and the popover's state.
///
/// The page edits a **draft** query that starts as the store's and is committed whole with every
/// change, so ticking a filter right after typing commits the typed text too. Typing waits 450 ms
/// for a pause; Return and Refresh ask for the first page afresh; a filter, the menu and Clear
/// commit at once. What the account does not allow is dropped from what is shown and committed
/// (signed out, nothing R-18), and from the draft itself when the sign-in changes, so signing in
/// again does not bring a ticked Mature box back on its own.
///
/// The grid's scroll offset is kept for the next window (`PanelViewState.scroll["pixiv"]`): stored
/// at most every 400 ms while it moves and once more when the page goes, and handed back once.
///
/// The model reads and acts through `controller`, which owns every store.
@MainActor
@Observable
final class PixivBrowserModel {
  unowned let controller: PanelController

  /// How long typing waits before the search is sent.
  nonisolated static let searchDelay: Duration = .milliseconds(450)
  /// The longest search text the store accepts.
  nonisolated static let textLimit = 256

  /// What the page edits. Read `query` for what is shown and sent.
  private(set) var draft: PixivQuery
  /// Dedicated Japanese-tag search translator for pixiv (independent of Workshop's English translator).
  var searchTranslator: PixivSearchTranslator
  /// The folded groups of the Filters sidebar: kept while the page lives, all open at first.
  var collapsedGroups: Set<PixivFilterGroup> = []
  /// What the page field holds: the page on show until the person types another.
  var pageText = "1"
  /// Remembers the bookmark visibility choice when switching away from Bookmarks and back.
  private(set) var preferredBookmarkVisibility: PixivBookmarkVisibility = .public

  /// Opens an address outside the app instead of `DesktopActions.current`, which `ExternalLink`
  /// uses while this is nil; a test that checks the address sets it.
  @ObservationIgnored var openURL: (@MainActor (URL) -> Bool)?
  /// Copies a link to the clipboard; tests replace it so they never touch the system pasteboard.
  @ObservationIgnored var copyURL: @MainActor (URL) -> Void = { url in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }
  /// Test seam: the clock of the search debounce and of the scroll report.
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }
  @ObservationIgnored private var debounce: Task<Void, Never>?
  /// Monotonic token incremented on every search/navigation mutation so superseded translations
  /// never commit or clobber a newer page or draft.
  @ObservationIgnored private(set) var browseGeneration: UInt64 = 0
  /// Active search-translation task, cancelled immediately when superseded by another action.
  @ObservationIgnored private var activeTranslationTask: Task<PixivSearchTranslation?, Never>?
  /// Where the grid was last seen, in points from its top.
  @ObservationIgnored private(set) var scrollOffset: Double = 0
  /// Scroll offset to restore once after popping the Back stack.
  @ObservationIgnored private var pendingBackScrollOffset: Double?
  @ObservationIgnored private var scrollReport: Task<Void, Never>?
  @ObservationIgnored private var hasUnreportedScroll = false
  /// The grid's offset was handed back from the last window, once.
  @ObservationIgnored private var restoredScroll = false
  /// The ring that last acted, and when: what tells the second click of a double-click on a ring
  /// from a press of its own.
  @ObservationIgnored private var lastRingPress: (jobID: String, at: ContinuousClock.Instant)?
  /// Test seam: the clock that times presses of a ring.
  @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
  /// Two presses of one ring closer than this are a double-click: the system's interval.
  @ObservationIgnored var doubleClickInterval: Duration = .seconds(NSEvent.doubleClickInterval)

  init(controller: PanelController, searchTranslator: PixivSearchTranslator? = nil) {
    self.controller = controller
    draft = controller.pixiv.query
    self.searchTranslator =
      searchTranslator
      ?? PixivSearchTranslator(
        defaults: controller.defaults,
        backend: controller.searchTranslation.backend,
        appLanguage: { [weak controller] in controller?.appLanguage.effective ?? .english })
  }

  // MARK: Reading

  /// Whether a pixiv session is held, which unlocks Bookmarks, Following, Mature and R-18 rankings.
  var isSignedIn: Bool { controller.pixiv.isSignedIn }

  /// Whether automatic Japanese-tag search translation is enabled.
  var translatesSearches: Bool { searchTranslator.isEnabled }

  /// The draft as the account allows it: what the controls show and what is sent.
  var query: PixivQuery { draft.sanitized(signedIn: isSignedIn) }

  /// The draft counts as a search once its text has a visible character in Explore scope, which is
  /// when the menu swaps rankings for search orders.
  var isSearching: Bool { query.isSearchDraft }

  /// Whether the draft holds a direct pixiv artwork URL or bare illustration id.
  var isDirectLookup: Bool { query.isDirectLookupDraft }

  /// The active top-level tab, or nil when viewing an author page.
  var activeTab: PixivScopeTab? { query.scope.tab }

  /// The rankings the menu offers while the box is empty.
  var rankingChoices: [PixivRanking] {
    let query = query
    return PixivRanking.offered(signedIn: isSignedIn, ratings: query.ratings)
  }

  /// How many filters differ from a fresh page: the badge of the Filter button.
  var filterCount: Int { query.activeFilterCount }

  /// Whether the current pixiv search text matches `tag`.
  func isSearchingTag(_ tag: String) -> Bool {
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return query.text.trimmingCharacters(in: .whitespacesAndNewlines)
      .caseInsensitiveCompare(trimmed) == .orderedSame
  }

  /// Removable active filter chips for `ActiveFilterChipsBar`, matching every active filter
  /// counted by `filterCount`.
  var activeFilterChips: [ActiveFilterChip] {
    let current = query
    var chips: [ActiveFilterChip] = []
    if current.orientation != .any {
      chips.append(
        ActiveFilterChip(id: "orientation", title: current.orientation.title, tone: .included) {
          [weak self] in _ = self?.choose(orientation: .any)
        })
    }
    if current.minimumSize != .any {
      chips.append(
        ActiveFilterChip(id: "size", title: current.minimumSize.title, tone: .included) {
          [weak self] in _ = self?.choose(minimumSize: .any)
        })
    }
    for rating in PixivQuery.offeredRatings
    where current.ratings.contains(rating) != PixivQuery.defaultRatings.contains(rating) {
      let isIncluded = current.ratings.contains(rating)
      chips.append(
        ActiveFilterChip(
          id: "rating-\(rating.rawValue.lowercased())", title: rating.title,
          tone: isIncluded ? .included : .excluded
        ) { [weak self] in _ = self?.set(rating, isOn: !isIncluded) })
    }
    if current.hidesAIGenerated {
      chips.append(
        ActiveFilterChip(id: "hide-ai", title: L("Hide AI-generated works"), tone: .included) {
          [weak self] in _ = self?.set(hidesAIGenerated: false)
        })
    }
    return chips
  }

  func count(in group: PixivFilterGroup) -> Int {
    let query = query
    switch group {
    case .account: return 0
    case .orientation: return query.orientationFilterCount
    case .minimumSize: return query.minimumSizeFilterCount
    case .ageRating: return query.ratingFilterCount
    case .ai: return query.aiFilterCount
    }
  }

  func isExpanded(_ group: PixivFilterGroup) -> Bool { !collapsedGroups.contains(group) }

  func setExpanded(_ group: PixivFilterGroup, _ expanded: Bool) {
    if expanded { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
  }

  // MARK: Editing

  /// Cancels any pending debounce timer and in-flight search translation, advancing the monotonic
  /// generation token so stale completions are dropped cleanly.
  @discardableResult
  func beginBrowseAction() -> UInt64 {
    debounce?.cancel()
    debounce = nil
    activeTranslationTask?.cancel()
    activeTranslationTask = nil
    browseGeneration &+= 1
    return browseGeneration
  }

  /// Runs on-device Japanese tag translation in a tracked, cancellable task bound to `generation`.
  /// Returns `nil` immediately when cancelled or superseded by a newer browse action.
  func translateSearch(_ text: String, generation: UInt64) async -> PixivSearchTranslation? {
    guard generation == browseGeneration else { return nil }
    activeTranslationTask?.cancel()
    let translator = searchTranslator
    let task = Task { @MainActor in
      await translator.translation(for: text)
    }
    activeTranslationTask = task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if activeTranslationTask == task {
      activeTranslationTask = nil
    }
    guard !Task.isCancelled, generation == browseGeneration else { return nil }
    return result
  }

  /// The search field's text, cut to the length pixiv takes. Pasting a pixiv artwork link jumps
  /// immediately; typing tags or a bare id follows after a pause (or immediately on Return).
  func setText(_ text: String) {
    let previous = draft.text
    let normalized: String
    if text.count > Self.textLimit, let linkedID = PixivLink.illustID(inLink: text) {
      normalized = "https://www.pixiv.net/artworks/\(linkedID)"
    } else {
      normalized = String(text.prefix(Self.textLimit))
    }
    let isPaste = WorkshopSearchTrigger.isPasteOrDrop(from: previous, to: normalized)
    draft.text = normalized
    draft.translation = nil
    if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.scope != .explore {
      draft.scope = .explore
    }
    beginBrowseAction()
    if isPaste, PixivLink.illustID(inLink: normalized) != nil {
      commit()
      return
    }
    let sleep = self.sleep
    debounce = Task { [weak self] in
      do { try await sleep(Self.searchDelay) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.debounce = nil
      self.commit()
    }
  }

  /// Return or the Search button: the first page of the listing, asked for afresh.
  @discardableResult
  func submit() -> Task<Void, Never> {
    if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.scope != .explore {
      draft.scope = .explore
    }
    return commit(refresh: true)
  }

  /// The Refresh button.
  @discardableResult
  func refresh() -> Task<Void, Never> { commit(refresh: true) }

  /// Switches to one of the top-level pixiv scopes (Explore, Bookmarks, Following).
  @discardableResult
  func open(tab: PixivScopeTab) -> Task<Void, Never> {
    choose(scope: tab.scope(bookmarkVisibility: preferredBookmarkVisibility))
  }

  /// Switches to a top-level scope, clearing the Back stack and syncing the draft.
  @discardableResult
  func choose(scope: PixivBrowseScope) -> Task<Void, Never> {
    let generation = beginBrowseAction()
    if case .bookmarks(let visibility) = scope {
      preferredBookmarkVisibility = visibility
    }
    draft.scope = scope
    if scope != .explore {
      draft.text = ""
      draft.translation = nil
    }
    let controller = controller
    return controller.launch("pixivScope", policy: .latestWins) { [weak self] in
      try await controller.pixivOpenScope(scope, generation: generation)
      guard let self, generation == self.browseGeneration else { return }
      self.draft = controller.pixiv.query
    }
  }

  /// Switches between Public and Private bookmarks while in Bookmarks scope.
  @discardableResult
  func choose(bookmarkVisibility: PixivBookmarkVisibility) -> Task<Void, Never> {
    preferredBookmarkVisibility = bookmarkVisibility
    draft.scope = .bookmarks(bookmarkVisibility)
    return commit()
  }

  /// Opens an artist's works page in-app, pushing the current view onto the Back stack.
  @discardableResult
  func openAuthor(of work: PixivWork) -> Task<Void, Never>? {
    guard PixivWork.isValidID(work.authorID) else { return nil }
    return openAuthor(id: work.authorID, name: work.authorName)
  }

  /// Opens an artist's works page by validated author id and display name.
  @discardableResult
  func openAuthor(id: String, name: String) -> Task<Void, Never>? {
    guard PixivWork.isValidID(id) else { return nil }
    let generation = beginBrowseAction()
    let offset = scrollOffset
    let controller = controller
    return controller.launch("pixivOpenAuthor", policy: .latestWins) { [weak self] in
      try await controller.pixivOpenAuthor(id: id, name: name, leavingAt: offset, generation: generation)
      guard let self, generation == self.browseGeneration else { return }
      self.draft = controller.pixiv.query
    }
  }

  /// Pops the previous browse snapshot from the Back stack, restoring its mode, query, filters,
  /// page, selection, and scroll offset.
  @discardableResult
  func goBack() -> Task<Void, Never> {
    let generation = beginBrowseAction()
    let controller = controller
    return controller.launch("pixivBack", policy: .latestWins) { [weak self] in
      let offset = try await controller.pixivGoBack(generation: generation)
      guard let self, generation == self.browseGeneration else { return }
      self.draft = controller.pixiv.query
      self.pendingBackScrollOffset = offset
    }
  }

  /// **Search as typed**: runs the current tag search without Japanese translation.
  @discardableResult
  func searchAsTyped(_ translation: PixivSearchTranslation) -> Task<Void, Never> {
    let generation = beginBrowseAction()
    let original = translation.original
    let controller = controller
    return controller.launch("pixivSearch", policy: .latestWins) { [weak self] in
      try await controller.pixivSearchAsTyped(original, generation: generation)
      guard let self, generation == self.browseGeneration else { return }
      self.draft.translation = nil
    }
  }

  /// Enables or disables automatic Japanese-tag search translation.
  @discardableResult
  func setTranslatesSearches(_ on: Bool) -> Task<Void, Never> {
    let generation = beginBrowseAction()
    let controller = controller
    return controller.launch("pixivTranslateToggle", policy: .latestWins) { [weak self] in
      try await controller.pixivSetTranslatesSearches(on, generation: generation)
      guard let self, generation == self.browseGeneration else { return }
      self.draft = controller.pixiv.query
    }
  }

  /// The menu's choice while the box is empty.
  @discardableResult
  func choose(ranking: PixivRanking) -> Task<Void, Never> {
    draft.ranking = ranking
    return commit()
  }

  /// The menu's choice while the box has text.
  @discardableResult
  func choose(order: PixivSearchOrder) -> Task<Void, Never> {
    draft.order = order
    return commit()
  }

  @discardableResult
  func choose(orientation: PixivOrientation) -> Task<Void, Never> {
    draft.orientation = orientation
    return commit()
  }

  @discardableResult
  func choose(minimumSize: PixivMinimumSize) -> Task<Void, Never> {
    draft.minimumSize = minimumSize
    return commit()
  }

  /// Ticks or unticks an age rating. Every box can be unticked; Mature needs a sign-in.
  @discardableResult
  func set(_ rating: PixivRating, isOn: Bool) -> Task<Void, Never> {
    var ratings = query.ratings
    if isOn { ratings.insert(rating) } else { ratings.remove(rating) }
    draft.ratings = ratings
    return commit()
  }

  @discardableResult
  func set(hidesAIGenerated: Bool) -> Task<Void, Never> {
    draft.hidesAIGenerated = hidesAIGenerated
    return commit()
  }

  /// Clear: orientation, size, AI and the ratings go back to their defaults; the text, the ranking
  /// and the search order stay.
  @discardableResult
  func clearFilters() -> Task<Void, Never> {
    draft = query.clearingFilters()
    return commit()
  }

  /// Clear search: back to the ranking.
  @discardableResult
  func clearSearch() -> Task<Void, Never> {
    draft.scope = .explore
    draft.text = ""
    draft.translation = nil
    return commit()
  }

  /// Searches pixiv immediately for a tag clicked in the pixiv inspector.
  @discardableResult
  func searchTag(_ tag: String) -> Task<Void, Never> {
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Task {} }
    draft.scope = .explore
    draft.text = String(trimmed.prefix(Self.textLimit))
    draft.translation = nil
    return commit()
  }

  /// Takes what the account no longer allows out of the draft itself. The page calls it whenever
  /// the sign-in changes, and when it appears.
  func reconcileAccount() {
    let allowed = query
    if draft != allowed { draft = allowed }
  }

  /// Commits the draft, whole, and drops a pause that was waiting to. The newest query lands last.
  @discardableResult
  func commit(refresh: Bool = false) -> Task<Void, Never> {
    let generation = beginBrowseAction()
    draft = query
    let query = draft
    let controller = controller
    return controller.launch("pixivSearch", policy: .latestWins) {
      try await controller.pixivSearch(query, refresh: refresh, generation: generation)
    }
  }

  /// The first visit's load, for a page that appears before anything asked for its list. The
  /// shell's navigation does the same; this one never repeats a load that is under way or failed.
  @discardableResult
  func loadIfNeeded() -> Task<Void, Never>? {
    let pixiv = controller.pixiv
    guard !pixiv.hasLoaded, !pixiv.isLoading, pixiv.errorMessage == nil,
      !controller.isBusy("pixivSearch")
    else { return nil }
    // A listing the closed panel left comes back at its page, as the shell's navigation brings it.
    if pixiv.canResume {
      return controller.launch(PanelActionCoordinator.key("navigate"), policy: .latestWins) {
        [controller] in
        try await controller.navigate(.pixiv)
      }
    }
    return commit()
  }

  // MARK: Paging

  /// Shows a page of the listing; the grid starts at its top.
  @discardableResult
  func showPage(_ page: Int) -> Task<Void, Never> {
    let controller = controller
    let page = controller.pixivBrowse.pager.clamped(page)
    return controller.launch("pixivPage", policy: .dropDuplicates) {
      try await controller.pixivLoadPage(page)
    }
  }

  /// The number typed in the page field: rounded and held to the pages there are, the first page
  /// for anything that is not a number. Asks for the page unless it is the one on show or a page
  /// is loading. Returns the number the field should say.
  @discardableResult
  func jump(typed text: String) -> Int {
    let pager = controller.pixivBrowse.pager
    if let target = pager.jumpTarget(typed: text) { showPage(target) }
    return Self.shownNumber(typed: text, in: pager)
  }

  /// The page field's Return or **Go**: asks for the page `pageText` names and rewrites the field
  /// with it (`jump(typed:)`).
  func jump() {
    pageText = String(jump(typed: pageText))
  }

  /// Puts the page on show into the page field, after a page arrived or the listing changed.
  func syncPageText() {
    pageText = String(controller.pixivBrowse.pager.page)
  }

  /// What a typed page number comes to once rounded and held to the pager's pages.
  static func shownNumber(typed text: String, in pager: ResultPager) -> Int {
    let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let rounded = (value ?? 0).rounded(.toNearestOrAwayFromZero)
    let number = rounded.isNaN || rounded == 0 ? 1 : rounded
    return Int(min(Double(pager.pages), max(1, number)))
  }

  // MARK: Remembering where the grid was

  /// The offset captured before opening an author page, handed back once when Back restores the grid.
  func takePendingBackScrollOffset() -> Double? {
    defer { pendingBackScrollOffset = nil }
    return pendingBackScrollOffset
  }

  /// The offset the last window left, taken once by the first grid this window shows.
  func takeRestoredScroll() -> Double? {
    guard !restoredScroll else { return nil }
    restoredScroll = true
    return controller.restoredViewState?.scroll["pixiv"]
  }

  /// The grid scrolled. The place is stored at most every 400 ms, so a flick is one write, not
  /// one for each frame; an offset that is not a place is ignored.
  func scrolled(to offset: Double) {
    guard offset.isFinite, offset >= 0, offset != scrollOffset else { return }
    scrollOffset = offset
    hasUnreportedScroll = true
    guard scrollReport == nil else { return }
    scrollReport = Task { @MainActor [weak self, sleep] in
      do { try await sleep(.milliseconds(400)) } catch { return }
      guard let self else { return }
      self.scrollReport = nil
      self.flushScrollReport()
    }
  }

  /// Stores the grid's place now, if it moved since it was last stored. Installed's filters and
  /// the other pages' offsets are kept: only this page's offset changes.
  func flushScrollReport() {
    scrollReport?.cancel()
    scrollReport = nil
    guard hasUnreportedScroll else { return }
    hasUnreportedScroll = false
    var state = controller.navigation.viewState ?? PanelViewState()
    state.scroll["pixiv"] = scrollOffset.rounded()
    controller.storeViewState(state)
  }

  // MARK: Works

  /// A click on a tile's ring: cancel, resume or retry the save it names, unless it is the second
  /// click of a double-click on the same ring. The first click already acted, and the ring it left
  /// may offer the opposite (a cancelled save offers to try again), so a second press would undo
  /// it. A key press or VoiceOver press comes one at a time and is never that close.
  @discardableResult
  func pressRing(_ ring: PixivTile.Ring) -> Task<Void, Never>? {
    let instant = now()
    if let last = lastRingPress, last.jobID == ring.jobID, instant - last.at < doubleClickInterval {
      return nil
    }
    lastRingPress = (ring.jobID, instant)
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("pixivRing", id: ring.jobID)) {
      try await PixivTileCell.perform(ring, in: controller)
    }
  }

  func select(_ work: PixivWork) {
    let controller = controller
    controller.launch(PanelActionCoordinator.key("pixivSelect", id: work.id)) {
      try await controller.pixivSelect(workID: work.id)
    }
  }

  /// A double-click: saves the page the inspector shows, applies a saved one, waits while it
  /// downloads, and does nothing when no display could show the wallpaper.
  @discardableResult
  func doubleClick(_ work: PixivWork) -> Task<Void, Never>? {
    let controller = controller
    switch controller.pixivDoubleClick(for: work) {
    case .nothing:
      return nil
    case .apply(let libraryID):
      return controller.launch(PanelActionCoordinator.key("activate", id: libraryID)) {
        try await controller.activate(libraryID)
      }
    case .download(let workID, let page):
      return controller.launch(PanelActionCoordinator.key("pixivDownload", id: workID)) {
        try await controller.pixivDownload(workID: workID, page: page)
      }
    }
  }

  /// **Download all pages** / **Download missing pages**: queues every page of `work` not yet in
  /// the library or downloading, asking first when more than 10 pages are missing.
  @discardableResult
  func downloadAllPages(of work: PixivWork) -> Task<Void, Never> {
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("pixivDownloadAll", id: work.id)) {
      _ = try await controller.pixivDownloadMissingPages(workID: work.id)
    }
  }

  /// **View on pixiv**: opens the work's own page through `ExternalLink`.
  func viewOnPixiv(_ work: PixivWork) {
    if let url = ExternalLink.pixivArtwork(id: work.id) { ExternalLink.open(url, using: openURL) }
  }

  /// **Copy link**: copies the validated pixiv artwork URL to the clipboard.
  func copyLink(for work: PixivWork) {
    if let url = ExternalLink.pixivArtwork(id: work.id), ExternalLink.isAllowed(url) { copyURL(url) }
  }
}
