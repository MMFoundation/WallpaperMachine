import Foundation

/// The listing's name and its matching result count.
struct PixivListSummary: Equatable {
  let text: String

  /// Search, author, bookmarks and following counts stay lower bounds until every accessible
  /// source page has been scanned.
  @MainActor
  static func make(_ browse: PixivBrowseState) -> PixivListSummary {
    if browse.requiresSignIn, !browse.isSignedIn {
      return PixivListSummary(text: browse.scope.tab?.title ?? "pixiv")
    }
    if browse.isLoading { return PixivListSummary(text: L("Loading pixiv…")) }
    guard browse.hasLoaded else { return PixivListSummary(text: "pixiv") }
    let count = browse.hasExactTotal
      ? L("\(browse.totalCount) results")
      : L("At least \(browse.totalCount) results")
    switch browse.scope {
    case .explore:
      if browse.isSearching || browse.isDirectLookup { return PixivListSummary(text: count) }
      return PixivListSummary(text: "\(browse.query.ranking.title) · \(count)")
    case .author(_, let name):
      return PixivListSummary(text: name.isEmpty ? count : "\(name) · \(count)")
    case .bookmarks(let visibility):
      return PixivListSummary(text: "\(visibility.title) · \(count)")
    case .following:
      return PixivListSummary(text: "\(L("Following")) · \(count)")
    }
  }
}

/// Signed-in feeds that require a pixiv account before any request is sent.
enum PixivSignedInFeed: Equatable {
  case bookmarks
  case following
}

/// Empty states specific to non-ranking feeds (author page, bookmarks, following).
enum PixivEmptyFeed: Equatable {
  case author(name: String)
  case bookmarks(PixivBookmarkVisibility)
  case following
}

/// What the page shows in place of the grid while there are no works to show. The first rule that
/// applies wins: sign-in required for personal feeds, loading, an error, filters that hide the
/// listing, then nothing found.
enum PixivEmptyState: Equatable {
  case loading
  case signInRequired(PixivSignedInFeed)
  case error(String)
  case filtersHideAll
  case nothing(searching: Bool)
  case emptyFeed(PixivEmptyFeed)

  /// Nil while there are works on show. A page that has not loaded, is not loading and has no
  /// error is loading: the first visit asks for its list a moment after the page appears.
  static func make(_ browse: PixivBrowseState) -> PixivEmptyState? {
    if browse.requiresSignIn, !browse.isSignedIn {
      switch browse.scope {
      case .bookmarks: return .signInRequired(.bookmarks)
      case .following: return .signInRequired(.following)
      case .explore, .author: break
      }
    }
    guard browse.works.isEmpty else { return nil }
    if browse.isLoading || (!browse.hasLoaded && browse.errorMessage == nil) { return .loading }
    if let message = browse.errorMessage { return .error(message) }
    if browse.hiddenCount > 0 || (!browse.isDirectLookup && browse.query.ratings.isEmpty) {
      return .filtersHideAll
    }
    switch browse.scope {
    case .explore:
      return .nothing(searching: browse.isSearching || browse.isDirectLookup)
    case .author(_, let name):
      return .emptyFeed(.author(name: name))
    case .bookmarks(let visibility):
      return .emptyFeed(.bookmarks(visibility))
    case .following:
      return .emptyFeed(.following)
    }
  }
}
