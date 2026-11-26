import Foundation

/// The rules of pixiv's page that decide what its controls show, kept on the query so the page and
/// the store use one definition: which filters are active, what Clear resets, and which rankings
/// the menu offers.
extension PixivQuery {
  /// A new query asks for all-ages works only.
  static let defaultRatings: Set<PixivRating> = [.everyone]

  /// The tag search or the ranking: the draft counts as a search as soon as its text has a
  /// non-blank character in Explore scope, which is when the toolbar swaps its ranking menu for
  /// search orders.
  var isSearchDraft: Bool {
    scope == .explore && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Whether the draft's search text names a direct pixiv artwork URL or bare illustration id.
  var isDirectLookupDraft: Bool {
    scope == .explore && PixivLink.illustID(in: text) != nil
  }

  // How many of the page's filters differ from their defaults, as the Filter button's badge and
  // each group's pill count them. The account has no count of its own.

  var orientationFilterCount: Int { orientation == .any ? 0 : 1 }
  var minimumSizeFilterCount: Int { minimumSize == .any ? 0 : 1 }
  /// Each age rating that is ticked against its default or unticked from it counts one, so
  /// unticking Everyone is one and ticking Questionable is another.
  var ratingFilterCount: Int {
    Self.offeredRatings.filter { ratings.contains($0) != Self.defaultRatings.contains($0) }.count
  }
  var aiFilterCount: Int { hidesAIGenerated ? 1 : 0 }
  var activeFilterCount: Int {
    orientationFilterCount + minimumSizeFilterCount + ratingFilterCount + aiFilterCount
  }

  /// Clear: orientation, size, AI and ratings go back to their defaults. The search text, the
  /// ranking and the search order are kept.
  func clearingFilters() -> PixivQuery {
    var query = self
    query.orientation = .any
    query.minimumSize = .any
    query.hidesAIGenerated = false
    query.ratings = Self.defaultRatings
    return query
  }
}

extension PixivRanking {
  /// The rankings the toolbar menu offers: the four all-ages ones, and the two R-18 ones only to a
  /// signed-in account that has the Mature box ticked.
  static func offered(signedIn: Bool, ratings: Set<PixivRating>) -> [PixivRanking] {
    let allAges: [PixivRanking] = [.daily, .weekly, .monthly, .rookie]
    return signedIn && ratings.contains(.mature) ? allAges + [.dailyR18, .weeklyR18] : allAges
  }

  @MainActor
  var title: String {
    switch self {
    case .daily: L("Daily ranking")
    case .weekly: L("Weekly ranking")
    case .monthly: L("Monthly ranking")
    case .rookie: L("Rookie ranking")
    case .dailyR18: L("Daily R-18 ranking")
    case .weeklyR18: L("Weekly R-18 ranking")
    }
  }
}

extension PixivSearchOrder {
  @MainActor
  var title: String {
    switch self {
    case .newest: L("Newest first")
    case .oldest: L("Oldest first")
    }
  }
}

extension PixivOrientation {
  @MainActor
  var title: String {
    switch self {
    case .any: L("Any orientation")
    case .landscape: L("Horizontal")
    case .portrait: L("Vertical")
    }
  }
}

extension PixivMinimumSize {
  @MainActor
  var title: String {
    switch self {
    case .any: L("Any size")
    case .fullHD: L("1920 × 1080 or larger")
    case .quadHD: L("2560 × 1440 or larger")
    case .ultraHD: L("3840 × 2160 or larger")
    }
  }
}

extension PixivRating {
  /// The age-rating box's label; R-18G is never offered.
  @MainActor
  var title: String {
    switch self {
    case .everyone: L("Everyone (G)")
    case .questionable: L("Questionable (PG-13)")
    case .mature: L("Mature (R-18)")
    case .grotesque: "R-18G"
    }
  }
}

/// Top-level pixiv browsing scopes offered in the header and Filters sidebar.
enum PixivScopeTab: String, CaseIterable, Hashable, Sendable {
  case explore, bookmarks, following

  @MainActor
  var title: String {
    switch self {
    case .explore: L("Explore")
    case .bookmarks: L("Bookmarks")
    case .following: L("Following")
    }
  }

  var systemImage: String {
    switch self {
    case .explore: "safari"
    case .bookmarks: "bookmark"
    case .following: "person.2"
    }
  }

  func scope(bookmarkVisibility: PixivBookmarkVisibility = .public) -> PixivBrowseScope {
    switch self {
    case .explore: .explore
    case .bookmarks: .bookmarks(bookmarkVisibility)
    case .following: .following
    }
  }
}

extension PixivBrowseScope {
  /// The top-level tab this scope belongs to, or nil while viewing an author page.
  var tab: PixivScopeTab? {
    switch self {
    case .explore: .explore
    case .bookmarks: .bookmarks
    case .following: .following
    case .author: nil
    }
  }

  var bookmarkVisibility: PixivBookmarkVisibility {
    if case .bookmarks(let visibility) = self { return visibility }
    return .public
  }
}

extension PixivBookmarkVisibility {
  @MainActor
  var title: String {
    switch self {
    case .public: L("Public bookmarks")
    case .private: L("Private bookmarks")
    }
  }
}
