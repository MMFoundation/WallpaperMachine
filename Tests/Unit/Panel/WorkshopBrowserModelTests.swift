import XCTest

@testable import WallpaperMachine

/// What the Workshop page's controls do: when typing becomes a search, what a filter, a sort or a tab
/// sends, how the pager clamps, what a double-click means, and what the grid remembers.
@MainActor
final class WorkshopBrowserModelTests: MediaPanelTestCase {
  private func rows(_ count: Int = 3, creator: String = "76561198000000001")
    -> [WorkshopBrowseProtocol.Row]
  {
    (0..<count).map {
      WorkshopBrowseProtocol.Row(id: String(1_000 + $0), title: "Wallpaper \($0)", creator: creator)
    }
  }

  private func makePanel(
    rows: [WorkshopBrowseProtocol.Row]? = nil, pages: Int = 1, count: Int? = nil
  ) throws -> DiscoverPanel {
    let panel = try makeDiscoverPanel()
    WorkshopBrowseProtocol.serve(rows ?? self.rows(), pages: pages, count: count)
    return panel
  }

  /// Waits for the Workshop store to finish what it is loading.
  private func loaded(_ panel: DiscoverPanel) async throws {
    try await waitFor { panel.workshop.hasLoaded && !panel.workshop.isLoading }
  }

  /// Starts the first search and waits for its tiles.
  private func open(_ panel: DiscoverPanel) async throws {
    try await panel.controller.navigate(.workshop)
    try await loaded(panel)
  }

  private func searchTexts() -> [String] {
    WorkshopBrowseProtocol.requests.compactMap { WorkshopBrowseProtocol.values("searchtext", in: $0) }
  }

  // MARK: Typing, pasting and Return

  func testTypingSearchesAfterThePauseAndTheNewestEditWins() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure

    model.edit(text: "n")
    await sleeper.waitUntilPending(1)
    model.edit(text: "na")
    await sleeper.waitUntilPending(1)
    XCTAssertEqual(sleeper.requested, [.milliseconds(450), .milliseconds(450)])
    XCTAssertEqual(sleeper.cancelledCount, 1, "the second edit restarted the pause")
    XCTAssertEqual(panel.workshop.searchText, "", "typing alone searches nothing")
    XCTAssertTrue(model.hasPendingSearch)

    sleeper.fireNext()
    try await waitFor { panel.workshop.searchText == "na" }
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["na"], "one search, for the newest text")
    XCTAssertFalse(model.hasPendingSearch)
  }

  func testALinkPastedWholeSearchesAtOnceAndTypedOneWaits() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108"

    model.edit(text: link)
    try await waitFor { panel.workshop.searchText == link }
    XCTAssertTrue(sleeper.requested.isEmpty, "a pasted link starts no pause")

    model.edit(text: "")
    await sleeper.waitUntilPending(1)
    for letter in "https://a.b/c" {
      model.edit(text: model.text + String(letter))
      await sleeper.waitUntilPending(1)
    }
    XCTAssertEqual(
      panel.workshop.searchText, link, "typed letter by letter, the link is only searched after its pause")
    sleeper.fireAll()
  }

  func testABareItemIdWaitsForReturnEvenWhenPasted() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure

    model.edit(text: "3632513108")
    XCTAssertTrue(sleeper.requested.isEmpty, "no pause: typing an id must not look up its prefixes")
    XCTAssertFalse(model.hasPendingSearch)
    XCTAssertEqual(panel.workshop.searchText, "")

    try await model.search().value
    XCTAssertEqual(panel.workshop.searchText, "3632513108", "Return sends the id")
  }

  func testAShortNumberAndPastedWordsGetThePause() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    model.edit(text: "2024")
    await sleeper.waitUntilPending(1)
    model.edit(text: "see these words pasted whole")
    await sleeper.waitUntilPending(1)
    XCTAssertEqual(sleeper.requested.count, 2)
    XCTAssertEqual(panel.workshop.searchText, "")
    sleeper.fireAll()
  }

  func testClearingTheFieldSearchesAfterThePause() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    model.edit(text: "aurora")
    await sleeper.waitUntilPending(1)
    model.edit(text: "")
    await sleeper.waitUntilPending(1)
    sleeper.fireAll()
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), [""], "the empty search replaced the pending one")
  }

  // MARK: Sort, filters, refresh

  func testASortAFilterAndRefreshEachSearchAtOnceWithTheDraft() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    model.choose(sort: .newest)
    try await waitFor { panel.workshop.sort == .newest }
    try await loaded(panel)
    let first = try XCTUnwrap(WorkshopBrowseProtocol.requests.last)
    XCTAssertEqual(WorkshopBrowseProtocol.values("browsesort", in: first), "mostrecent")

    model.setRequired("Approved", true)
    model.setIncluded("Anime", false)
    try await waitFor { panel.workshop.tags == ["Approved"] && panel.workshop.excludedTags.contains("Anime") }
    XCTAssertEqual(
      Set(panel.workshop.excludedTags), Set(WorkshopStore.defaultExcludedTags + ["Anime"]),
      "the unticked box hides its tag and the defaults stay")
    XCTAssertEqual(model.filterCount, 2)

    let before = WorkshopBrowseProtocol.requests.count
    model.refresh()
    try await waitFor { WorkshopBrowseProtocol.requests.count > before }
    try await loaded(panel)

    model.clearFilters()
    try await waitFor { panel.workshop.tags.isEmpty }
    XCTAssertEqual(panel.workshop.excludedTags, WorkshopStore.defaultExcludedTags)
    XCTAssertEqual(model.filterCount, 0)
  }

  func testEverySortTheMenuOffersIsOneTheStoreKnowsAndChoosingSendsIt() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    XCTAssertEqual(WorkshopSort.allCases.count, 9)
    for sort in WorkshopSort.allCases {
      model.choose(sort: sort)
      try await waitFor { panel.workshop.sort == sort }
      try await loaded(panel)
      XCTAssertEqual(model.sort, sort)
    }
    let sent = WorkshopBrowseProtocol.requests.compactMap { WorkshopBrowseProtocol.values("browsesort", in: $0) }
    XCTAssertEqual(
      Set(sent), Set(WorkshopSort.allCases.map(\.browseSort)), "each sort reached Steam in its own key")
  }

  func testApplicationAndAssetCanBeIncludedIndependentlyAndClearRestoresTheirExclusions() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let type = try XCTUnwrap(WorkshopFilterCatalog.groups.first { $0.id == "type" })
    let application = try XCTUnwrap(type.sections.first { $0.id == "type" }?.entries.first { $0.tag == "Application" })
    let asset = try XCTUnwrap(type.sections.first { $0.id == "category" }?.entries.first { $0.tag == "Asset" })
    try await open(panel)

    func exclusions() throws -> Set<String> {
      let request = try XCTUnwrap(WorkshopBrowseProtocol.requests.last)
      let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
      XCTAssertFalse(items.contains { $0.name == "requiredtags[]" }, "including a type does not require it")
      return Set(items.filter { $0.name == "excludedtags[]" }.compactMap(\.value))
    }

    XCTAssertEqual(try exclusions(), Set(WorkshopStore.defaultExcludedTags))
    for entry in [application, asset] {
      model.setIncluded(entry.tag, true)
      try await waitFor { !panel.workshop.excludedTags.contains(entry.tag) }
      try await loaded(panel)
      XCTAssertFalse(try exclusions().contains(entry.tag))
      XCTAssertEqual(model.filters.count(in: type), 1)
      XCTAssertEqual(model.filterCount, 1)

      model.clearFilters()
      try await waitFor { panel.workshop.excludedTags == WorkshopStore.defaultExcludedTags }
      try await loaded(panel)
      XCTAssertEqual(try exclusions(), Set(WorkshopStore.defaultExcludedTags))
      XCTAssertEqual(model.filters.count(in: type), 0)
      XCTAssertEqual(model.filterCount, 0)
    }

    model.setIncluded(application.tag, true)
    model.setIncluded(asset.tag, true)
    try await waitFor {
      !panel.workshop.excludedTags.contains(application.tag) && !panel.workshop.excludedTags.contains(asset.tag)
    }
    try await loaded(panel)
    XCTAssertEqual(try exclusions(), ["Questionable", "Mature", "Unspecified"])
    XCTAssertEqual(model.filters.count(in: type), 2)
    XCTAssertEqual(model.filterCount, 2)
  }

  func testClearSearchAndFiltersEmptiesTheFieldAndRestoresTheDefaults() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    model.edit(text: "3632513108")
    model.setIncluded("Mature", true)
    try await waitFor { panel.workshop.excludedTags.contains("Mature") == false }
    model.clearSearchAndFilters()
    try await waitFor { panel.workshop.searchText == "" && panel.workshop.excludedTags.contains("Mature") }
    XCTAssertEqual(model.text, "")
    XCTAssertEqual(model.filters, .cleared)
  }

  func testTheDraftIsSeededFromTheStoreOnceAndNeverAgain() throws {
    let panel = try makePanel()
    panel.workshop.searchText = "seeded"
    panel.workshop.sort = .popular
    panel.workshop.tags = ["Approved"]
    panel.workshop.excludedTags = ["Mature"]
    let model = panel.controller.workshopBrowser
    XCTAssertEqual(model.text, "seeded")
    XCTAssertEqual(model.sort, .popular)
    XCTAssertEqual(model.filters, WorkshopFilterDraft(tags: ["Approved"], excludedTags: ["Mature"]))
    panel.workshop.searchText = "changed meanwhile"
    XCTAssertEqual(model.text, "seeded", "a result arriving must not overwrite what is typed")
  }

  // MARK: Lists, authors, pages

  func testChoosingAListSearchesItAgainEvenTheOneOnShow() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let epoch = model.scrollEpoch

    model.open(.collections)
    try await waitFor { panel.workshop.source == .collections }
    try await loaded(panel)
    XCTAssertGreaterThan(model.scrollEpoch, epoch, "a new list starts at the top")
    let count = WorkshopBrowseProtocol.requests.count
    model.open(.collections)
    try await waitFor { WorkshopBrowseProtocol.requests.count > count }
    try await loaded(panel)
    XCTAssertEqual(panel.controller.workshopBrowse.source.list, .collections)
  }

  func testAnAuthorOpensFromAnItemAndBackReturnsToTheList() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.first)
    XCTAssertEqual(item.authorProfileID, "76561198000000001")

    model.openAuthor(of: item)
    try await waitFor { panel.workshop.source.key == "creator" }
    var source = panel.controller.workshopBrowse.source
    XCTAssertNil(source.list, "an opened author is none of the tabs")
    XCTAssertFalse(source.isSearchable, "its list has no search field and no sort menu")
    XCTAssertTrue(source.canGoBack)

    model.goBack()
    try await waitFor { panel.workshop.source == .browse }
    source = panel.controller.workshopBrowse.source
    XCTAssertEqual(source.list, .browse)
    XCTAssertFalse(source.canGoBack)
  }

  /// Issue #226: Back shows the list as it was left, at once and without asking Steam again: its
  /// tiles, the selected one and the grid's place. The draft takes back the filters the list was
  /// shown with, whatever was chosen on the author's list.
  func testBackShowsTheListAsItWasLeft() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    try await open(panel)
    let tiles = panel.controller.workshopBrowse.items
    let item = try XCTUnwrap(tiles.last)
    try await panel.controller.selectWorkshopItem(id: item.id)
    model.scrolled(to: 640)
    let filters = model.filters

    model.openAuthor(of: item)
    try await waitFor { panel.workshop.source.key == "creator" && !panel.workshop.isLoading }
    model.setRequired("Anime", true)
    try await waitFor { panel.workshop.tags == ["Anime"] && !panel.workshop.isLoading }
    let requests = WorkshopBrowseProtocol.requests.count
    let epoch = model.scrollEpoch

    await model.goBack().value
    XCTAssertEqual(panel.controller.workshopBrowse.source.list, .browse)
    XCTAssertEqual(panel.controller.workshopBrowse.items, tiles)
    XCTAssertEqual(panel.controller.workshopSelectedItem?.id, item.id)
    XCTAssertEqual(model.filters, filters)
    XCTAssertEqual(panel.workshop.tags, [])
    XCTAssertGreaterThan(model.scrollEpoch, epoch)
    XCTAssertEqual(model.takeScrollTarget(), 640, "the grid goes back to where it was")
    XCTAssertEqual(WorkshopBrowseProtocol.requests.count, requests, "Steam was not asked again")
    sleeper.fireAll()
  }

  /// Installed's **More by this author** leaves Discover's list with its grid where it was, so
  /// Back from the author returns there and not to the top.
  func testBackFromAnAuthorOpenedInInstalledReturnsWhereTheGridWas() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.last)
    model.scrolled(to: 640)

    try await panel.controller.openInstalledWorkshopAuthor(id: item.id)
    try await waitFor { panel.workshop.source.key == "creator" && !panel.workshop.isLoading }
    await model.goBack().value
    XCTAssertEqual(panel.controller.workshopBrowse.source.list, .browse)
    XCTAssertEqual(model.takeScrollTarget(), 640, "the grid goes back to where it was")
    sleeper.fireAll()
  }

  func testAnItemWithNoKnownAuthorOpensNothing() async throws {
    let panel = try makePanel(rows: rows(1, creator: "not a steam id"))
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.first)
    XCTAssertNil(item.authorProfileID)
    model.openAuthor(of: item)
    XCTAssertEqual(panel.workshop.source, .browse)
  }

  func testNextPageRequestsThatPageAndNeverNavigates() async throws {
    let panel = try makePanel(pages: 614, count: 18_420)
    let model = panel.controller.workshopBrowser
    try await open(panel)
    XCTAssertEqual(panel.controller.navigation.selection, .workshop)

    let pager = panel.controller.workshopBrowse.pager
    XCTAssertEqual(pager.nextPage, 2)
    model.showPage(pager.nextPage)
    try await waitFor { panel.workshop.page == 2 }
    try await loaded(panel)
    XCTAssertEqual(WorkshopBrowseProtocol.requests.compactMap { WorkshopBrowseProtocol.values("p", in: $0) }.last, "2")
    XCTAssertEqual(
      panel.controller.navigation.selection, .workshop,
      "a page number is a page of the list, never a page of the app")
    model.syncPageText()
    XCTAssertEqual(model.pageText, "2")
  }

  func testTheJumpFieldClampsToTheLastPageAndAsksForNothingForThePageOnShow() async throws {
    let panel = try makePanel(pages: 614, count: 18_420)
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let requests = WorkshopBrowseProtocol.requests.count

    model.pageText = "1"
    model.jump()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(WorkshopBrowseProtocol.requests.count, requests, "the page on show is not asked for again")

    model.pageText = "5000"
    model.jump()
    XCTAssertEqual(model.pageText, "614", "the field is rewritten with the page it named")
    try await waitFor { panel.workshop.page == 614 }
    try await loaded(panel)
    XCTAssertEqual(WorkshopBrowseProtocol.requests.compactMap { WorkshopBrowseProtocol.values("p", in: $0) }.last, "614")

    model.pageText = "abc"
    model.jump()
    XCTAssertEqual(model.pageText, "1", "text that is not a number asks for the first page")
    try await waitFor { panel.workshop.page == 1 }
  }

  func testAListOfOnePageHasNowhereToJumpTo() async throws {
    let panel = try makePanel()
    try await open(panel)
    let pager = panel.controller.workshopBrowse.pager
    XCTAssertEqual(pager.pages, 1)
    XCTAssertFalse(pager.canJump, "the field and Go are disabled")
    XCTAssertFalse(pager.canGoBack)
    XCTAssertFalse(pager.canGoForward)
    XCTAssertEqual(WorkshopBrowseState.pageSize, 30, "a page is Steam's own 30 tiles")
    XCTAssertEqual(WorkshopBrowseState.maxPages, 1000)
  }

  func testTheFirstVisitLoadsTheWorkshopWhicheverWayThePageWasReached() async throws {
    let panel = try makePanel()
    XCTAssertFalse(panel.workshop.hasLoaded)
    panel.controller.workshopBrowser.pageAppeared()
    try await loaded(panel)
    XCTAssertEqual(panel.controller.workshopBrowse.items.count, 3)
    let requests = WorkshopBrowseProtocol.requests.count
    panel.controller.workshopBrowser.pageAppeared()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(WorkshopBrowseProtocol.requests.count, requests, "a loaded page is not loaded again")
  }

  // MARK: Tiles

  func testSelectingATileSelectsItInTheStore() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = panel.controller.workshopBrowse.items[1]
    model.select(item)
    try await waitFor { panel.workshop.selectedItem?.id == item.id }
    XCTAssertEqual(panel.controller.workshopSelectedItem?.id, item.id)
    XCTAssertEqual(panel.controller.workshopBrowse.selectedID, item.id)
  }

  func testDoubleClickingACollectionOpensItAndAPlainItemStartsItsDownload() async throws {
    var collection = WorkshopBrowseProtocol.Row(id: "900", title: "Night skies")
    collection.collectionChildren = ["1", "2"]
    let panel = try makePanel(rows: rows(2) + [collection])
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let items = panel.controller.workshopBrowse.items

    model.doubleClick(items[0])
    try await waitFor { panel.workshop.downloadRequests.contains { $0.id == items[0].id } }
    XCTAssertEqual(
      panel.controller.downloads.target, items[0].id,
      "SteamCMD is not set up, so the request waits and the dialog opens on it")
    XCTAssertEqual(panel.controller.downloads.resolution?.stage, .setup)
    panel.controller.downloads.closeDialog()

    let opened = try XCTUnwrap(items.first { $0.isCollection })
    model.doubleClick(opened)
    try await waitFor { panel.workshop.source.key == "collection" }
    XCTAssertEqual(panel.controller.workshopBrowse.source.name, "Night skies")
    XCTAssertTrue(panel.workshop.downloadRequests.allSatisfy { $0.id != "900" }, "a collection is never downloaded")
  }

  func testDoubleClickingATileWhoseRequestIsWaitingReopensTheDialog() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = panel.controller.workshopBrowse.items[0]
    model.doubleClick(item)
    try await waitFor { panel.controller.downloads.isDialogOpen }
    panel.controller.downloads.closeDialog()
    XCTAssertFalse(panel.controller.downloads.isDialogOpen)
    XCTAssertEqual(panel.workshop.downloadRequests.count, 1, "closing never removes the request")

    model.doubleClick(item)
    XCTAssertTrue(panel.controller.downloads.isDialogOpen, "a retained request reopens its dialog")
    XCTAssertEqual(panel.workshop.downloadRequests.count, 1)
  }

  // MARK: Popovers, focus and the grid's place

  func testTheDownloadsPopoverLeavesTheFiltersSidebarOpen() throws {
    let panel = try makePanel()
    let controller = panel.controller
    controller.shell.setFiltersShown(true)
    XCTAssertFalse(controller.shell.isPopoverOpen, "the sidebar is not a popover")
    controller.downloads.isQueuePopoverOpen = true
    XCTAssertTrue(controller.shell.isPopoverOpen, "the Downloads popover is open")
    XCTAssertTrue(controller.shell.areFiltersShown, "beside the sidebar")
    controller.downloads.isQueuePopoverOpen = false
    XCTAssertFalse(controller.shell.isPopoverOpen)
  }

  func testTheGridsPlaceIsStoredAtMostEvery400msMergedWithTheLibrarysStateAndRestoredOnce() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    controller.navigation.viewState = PanelViewState(
      installed: .init(text: "nat", sort: "size", descending: true, tags: ["Video"], excludedTags: []),
      scroll: ["installed": 80, "discover": 250])
    let model = controller.workshopBrowser
    XCTAssertEqual(model.takeRestoredScroll(), 250, "the last window left this place")
    XCTAssertNil(model.takeRestoredScroll(), "and it is taken once")

    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    model.scrolled(to: 100)
    model.scrolled(to: 300)
    await sleeper.waitUntilPending(1)
    XCTAssertEqual(sleeper.requested, [.milliseconds(400)], "a flick is one write, not one for each frame")
    XCTAssertEqual(controller.navigation.viewState?.scroll["discover"], 250, "nothing stored yet")
    sleeper.fireNext()
    try await waitFor { controller.navigation.viewState?.scroll["discover"] == 300 }
    let state = try XCTUnwrap(controller.navigation.viewState)
    XCTAssertEqual(state.scroll["installed"], 80, "Installed's place is kept")
    XCTAssertEqual(state.installed.text, "nat", "and so are its filters")
    XCTAssertEqual(state.installed.sort, "size")

    model.scrolled(to: 410)
    model.flushScrollReport()
    XCTAssertEqual(controller.navigation.viewState?.scroll["discover"], 410, "leaving the page stores it at once")
    model.scrolled(to: -5)
    model.scrolled(to: .nan)
    model.flushScrollReport()
    XCTAssertEqual(controller.navigation.viewState?.scroll["discover"], 410, "an offset that is not a place is ignored")
  }

  func testLeavingThePageReleasesTheAnimations() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    model.pageDisappeared()
    XCTAssertTrue(model.previews.animations.isEmpty)
  }

  // MARK: Comments retry and pagination

  /// Pure fixture builder: called from `serveComments` closures, which run off the main actor.
  nonisolated private static func commentsPayload(
    total: Int, entries: [(id: String?, author: String, timestamp: Int, text: String)]
  ) -> Data {
    let html = entries.map { entry in
      let idAttr = entry.id.map { #" id="comment_\#($0)""# } ?? ""
      let bodyIDAttr = entry.id.map { #" id="comment_content_\#($0)""# } ?? ""
      return """
        <div class="commentthread_comment responsive_body_text"\(idAttr)>
          <a class="hoverunderline commentthread_author_link" href="x"><bdi>\(entry.author)</bdi></a>
          <span class="commentthread_comment_timestamp" data-timestamp="\(entry.timestamp)">now</span>
          <div class="commentthread_comment_text"\(bodyIDAttr)>\(entry.text)</div>
        </div>
        """
    }.joined()
    return (try? JSONSerialization.data(withJSONObject: [
      "success": true, "total_count": total, "comments_html": html,
    ])) ?? Data()
  }

  func testCommentsRetryRecoversFromInitialFailure() async throws {
    addTeardownBlock { WorkshopBrowseProtocol.serveComments(nil) }
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.first)

    WorkshopBrowseProtocol.serveComments { _ in .success(Data("not json".utf8)) }
    await model.loadComments(for: item)
    guard case .failed(item.id, let message) = model.comments else {
      return XCTFail("expected failed comments state, got \(model.comments)")
    }
    XCTAssertFalse(message.isEmpty)

    WorkshopBrowseProtocol.serveComments { _ in
      .success(Self.commentsPayload(total: 1, entries: [("101", "Alice", 1_759_312_800, "Great!")]))
    }
    await model.retryComments(for: item).value
    guard case .loaded(item.id, let thread, let nextStart, let hasMore, false, nil) = model.comments else {
      return XCTFail("expected loaded comments after retry, got \(model.comments)")
    }
    XCTAssertEqual(thread.total, 1)
    XCTAssertEqual(thread.comments.map(\.text), ["Great!"])
    XCTAssertEqual(nextStart, 1)
    XCTAssertFalse(hasMore)
  }

  func testCommentsPaginationAppendsPagesDeduplicatesAndStopsCleanly() async throws {
    addTeardownBlock { WorkshopBrowseProtocol.serveComments(nil) }
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.first)

    WorkshopBrowseProtocol.serveComments { url in
      let start = Int(WorkshopBrowseProtocol.values("start", in: url) ?? "0") ?? 0
      switch start {
      case 0:
        return .success(Self.commentsPayload(total: 4, entries: [
          ("1", "A", 1000, "First"),
          ("2", "B", 900, "Second"),
        ]))
      case 2:
        // Comment #2 overlaps from a newly posted comment shifting offsets; #3 and #4 are new.
        return .success(Self.commentsPayload(total: 5, entries: [
          ("2", "B", 900, "Second"),
          ("3", "C", 800, "Third"),
          ("4", "D", 700, "Fourth"),
        ]))
      default:
        return .success(Self.commentsPayload(total: 5, entries: []))
      }
    }

    await model.loadComments(for: item)
    guard case .loaded(item.id, let page1, let start1, let more1, false, nil) = model.comments else {
      return XCTFail("expected page 1 loaded, got \(model.comments)")
    }
    XCTAssertEqual(page1.comments.map(\.id), ["1", "2"])
    XCTAssertEqual(start1, 2)
    XCTAssertTrue(more1)

    await model.requestMoreComments(for: item).value
    guard case .loaded(item.id, let page2, let start2, let more2, false, nil) = model.comments else {
      return XCTFail("expected page 2 loaded, got \(model.comments)")
    }
    XCTAssertEqual(page2.comments.map(\.id), ["1", "2", "3", "4"], "overlapping comment is deduplicated")
    XCTAssertEqual(page2.total, 5)
    XCTAssertEqual(start2, 5)
    XCTAssertFalse(more2, "stops cleanly once nextStart reaches total")
    XCTAssertEqual(
      WorkshopBrowseProtocol.commentRequests.compactMap { WorkshopBrowseProtocol.values("start", in: $0) },
      ["0", "2"])

    // Calling again once exhausted makes no further request.
    await model.loadMoreComments(for: item)
    XCTAssertEqual(WorkshopBrowseProtocol.commentRequests.count, 2)
  }

  func testCommentsLoadMoreFailureKeepsLoadedCommentsAndStopsOnEmptyOrDuplicatePage() async throws {
    addTeardownBlock { WorkshopBrowseProtocol.serveComments(nil) }
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.first)

    WorkshopBrowseProtocol.serveComments { url in
      let start = Int(WorkshopBrowseProtocol.values("start", in: url) ?? "0") ?? 0
      if start == 0 {
        return .success(Self.commentsPayload(total: 10, entries: [
          (nil, "A", 1000, "Only comment"),
        ]))
      }
      return .success(Data("broken".utf8))
    }

    await model.loadComments(for: item)
    await model.loadMoreComments(for: item)
    guard case .loaded(item.id, let kept, let startAfterFail, true, false, let error) = model.comments else {
      return XCTFail("expected existing comments kept with loadMoreError, got \(model.comments)")
    }
    XCTAssertEqual(kept.comments.map(\.text), ["Only comment"])
    XCTAssertEqual(startAfterFail, 1)
    XCTAssertNotNil(error)

    // Retrying with only a duplicate comment (no id) stops cleanly instead of looping forever.
    WorkshopBrowseProtocol.serveComments { _ in
      .success(Self.commentsPayload(total: 10, entries: [
        (nil, "A", 1000, "Only comment"),
      ]))
    }
    await model.requestMoreComments(for: item).value
    guard case .loaded(item.id, let final, _, let hasMore, false, nil) = model.comments else {
      return XCTFail("expected loaded state after duplicate page, got \(model.comments)")
    }
    XCTAssertEqual(final.comments.map(\.text), ["Only comment"])
    XCTAssertFalse(hasMore, "a page that yields no new comments stops pagination cleanly")
  }

  // MARK: Inspector tag toggle, active filter chips, and Hide installed

  func testToggleTagFromInspectorTogglesRequiredAndExcludedAndSearches() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)

    model.toggleTagFromInspector("anime", exclude: false)
    try await waitFor { panel.workshop.tags == ["Anime"] && !panel.workshop.isLoading }
    XCTAssertEqual(model.filters.chipSelection("Anime"), .required)

    model.toggleTagFromInspector("Anime", exclude: false)
    try await waitFor { panel.workshop.tags.isEmpty && !panel.workshop.isLoading }
    XCTAssertEqual(model.filters.chipSelection("Anime"), .plain)

    model.toggleTagFromInspector("Anime", exclude: true)
    try await waitFor { panel.workshop.excludedTags.contains("Anime") && !panel.workshop.isLoading }
    XCTAssertEqual(model.filters.chipSelection("Anime"), .excluded)

    model.toggleTagFromInspector("Anime", exclude: true)
    try await waitFor { !panel.workshop.excludedTags.contains("Anime") && !panel.workshop.isLoading }
    XCTAssertEqual(model.filters.chipSelection("Anime"), .plain)
  }

  func testHideInstalledFiltersClientSideWithoutRefetchingAndActiveFilterChipsMatchCount()
    async throws
  {
    var collection = WorkshopBrowseProtocol.Row(id: "900", title: "My Collection")
    collection.collectionChildren = ["1000", "1001"]
    let panel = try makePanel(rows: rows(2) + [collection], pages: 3, count: 90)
    let model = panel.controller.workshopBrowser
    try await open(panel)
    panel.store.librarySnapshot.wallpapers = [
      BridgeWallpaperEntry(
        id: "1000", title: "Installed 0", kind: .video, supported: true, active: false,
        selected: false, previewPath: nil),
      BridgeWallpaperEntry(
        id: "1001", title: "Installed 1", kind: .video, supported: true, active: false,
        selected: false, previewPath: nil),
    ]

    let requestsBefore = WorkshopBrowseProtocol.requests.count
    model.setHideInstalled(true)
    XCTAssertEqual(
      WorkshopBrowseProtocol.requests.count, requestsBefore,
      "Hide installed filters client-side without asking Steam again")
    let visible = model.visibleItems(in: panel.controller.workshopBrowse)
    XCTAssertEqual(
      visible.map(\.id), ["900"],
      "installed wallpapers are hidden while collections stay visible")
    XCTAssertEqual(model.filterCount, 1)
    XCTAssertEqual(model.activeFilterChips.map(\.id), ["hide-installed"])

    // Clearing when only Hide installed is active sends no unnecessary Steam request.
    model.clearFilters()
    XCTAssertFalse(model.filters.hideInstalled)
    XCTAssertEqual(WorkshopBrowseProtocol.requests.count, requestsBefore)

    // Combine Hide installed with required, included-against-default, and excluded filters.
    model.setHideInstalled(true)
    model.setRequired("Approved", true)
    model.setIncluded("Mature", true)
    model.setIncluded("Anime", false)
    try await waitFor { !panel.workshop.isLoading && panel.workshop.tags == ["Approved"] }
    let chips = model.activeFilterChips
    XCTAssertEqual(chips.count, model.filterCount)
    XCTAssertEqual(chips.map(\.id), ["hide-installed", "req-Approved", "inc-Mature", "exc-Anime"])
    XCTAssertEqual(chips.last?.tone, .excluded)
    chips.first?.onRemove()
    XCTAssertFalse(model.filters.hideInstalled)
  }

  /// Removing a required chip for a default-excluded Workshop tag restores the tag to its default
  /// excluded state in one click instead of leaving behind a duplicate included chip.
  func testRemovingRequiredDefaultExcludedTagChipRestoresDefaultExclusionInOneClick() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    try await open(panel)

    model.setChip("Mature", .required)
    try await waitFor { !panel.workshop.isLoading && panel.workshop.tags == ["Mature"] }
    XCTAssertEqual(model.filterCount, 1)
    XCTAssertEqual(model.activeFilterChips.map(\.id), ["req-Mature"])

    model.activeFilterChips[0].onRemove()
    try await waitFor { !panel.workshop.isLoading && panel.workshop.tags.isEmpty }
    XCTAssertTrue(model.filters.tags.isEmpty)
    XCTAssertTrue(model.filters.excludedTags.contains("Mature"))
    XCTAssertEqual(model.filterCount, 0)
    XCTAssertTrue(model.activeFilterChips.isEmpty)
  }

  func testCopyLinkValidatesThroughExternalLinkAndUsesCopySeam() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    var copied: [URL] = []
    model.copyURL = { copied.append($0) }
    try await open(panel)
    let item = try XCTUnwrap(panel.controller.workshopBrowse.items.first)

    model.copyLink(for: item)
    XCTAssertEqual(copied, [try XCTUnwrap(ExternalLink.workshopItem(id: item.id))])
  }
}
