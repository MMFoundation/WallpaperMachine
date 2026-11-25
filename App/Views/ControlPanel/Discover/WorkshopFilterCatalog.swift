import SwiftUI

/// The boxes of the Workshop's Filters sidebar, tag for tag as Wallpaper Engine's own Workshop
/// sidebar lists them.
///
/// "Show only" boxes start unticked, and ticking one sends its tag to Steam as a required tag.
/// Chips start out filtering nothing (`FilterTagChip`): a selected one is required too and a
/// hidden one excluded. An unticked checkbox sends its tag as an excluded one, so a group with
/// everything ticked filters nothing. Tags travel to Steam in English; only their labels are
/// translated. The boxes left unticked by default (`isOffByDefault`) make up the default excluded
/// list, which must equal `WorkshopStore.defaultExcludedTags`; a test holds the two together.
enum WorkshopFilterCatalog {
  /// How a box's name is written: fixed wording the catalog translates, or a value that is shown
  /// as it is (a resolution).
  enum Name: Equatable {
    case localized(LocalizedStringKey)
    case verbatim(String)

    var text: Text {
      switch self {
      case .localized(let key): Text(key)
      case .verbatim(let value): Text(verbatim: value)
      }
    }
  }

  struct Entry: Identifiable, Equatable {
    /// The tag Steam knows the box by.
    let tag: String
    let name: Name
    /// The box starts unticked until the user ticks it.
    let isOffByDefault: Bool

    var id: String { tag }

    /// A box named by catalog wording. The label is a literal, so the strings are extracted.
    init(_ tag: String, _ label: LocalizedStringKey, off: Bool = false) {
      self.tag = tag
      name = .localized(label)
      isOffByDefault = off
    }

    /// A box named by a value that is shown as it is.
    init(_ tag: String, verbatim label: String) {
      self.tag = tag
      name = .verbatim(label)
      isOffByDefault = false
    }
  }

  struct Section: Identifiable, Equatable {
    enum Style: Equatable {
      /// One checkbox to a line.
      case checkboxes
      /// Tags as chips, for a long list.
      case chips
    }

    let id: String
    let title: LocalizedStringKey?
    let entries: [Entry]
    /// The section offers **All** and **None**.
    let hasQuickLinks: Bool
    let style: Style

    var tags: [String] { entries.map(\.tag) }

    static func == (lhs: Section, rhs: Section) -> Bool { lhs.id == rhs.id && lhs.entries == rhs.entries }
  }

  struct Group: Identifiable, Equatable {
    let id: String
    let title: LocalizedStringKey
    let sections: [Section]

    var tags: [String] { sections.flatMap(\.tags) }

    static func == (lhs: Group, rhs: Group) -> Bool { lhs.id == rhs.id && lhs.sections == rhs.sections }
  }

  /// A "Show only" box: a tag the item must carry.
  struct RequiredEntry: Identifiable, Equatable {
    let tag: String
    let name: LocalizedStringKey
    /// The SF Symbol drawn before the name.
    let systemImage: String

    var id: String { tag }
  }

  // MARK: The catalog

  /// "Show only": ticking one requires its tag.
  static let showOnly: [RequiredEntry] = [
    RequiredEntry(tag: "Approved", name: "Approved", systemImage: "trophy.fill"),
    RequiredEntry(tag: "Audio responsive", name: "Audio responsive", systemImage: "waveform"),
    RequiredEntry(tag: "Customizable", name: "Customizable", systemImage: "slider.horizontal.3"),
  ]

  /// Steam's resolution tags: `Standard Definition` then each size, with the family as a prefix.
  private static func resolution(
    _ id: String, _ title: LocalizedStringKey, standard: LocalizedStringKey, prefix: String,
    sizes: [String]
  ) -> Section {
    Section(
      id: id, title: title,
      entries: [Entry("\(prefix)Standard Definition", standard)]
        + sizes.map { Entry("\(prefix)\($0)", verbatim: $0) },
      hasQuickLinks: true, style: .checkboxes)
  }

  static let groups: [Group] = [
    Group(
      id: "type", title: "Type",
      sections: [
        Section(
          id: "type", title: nil,
          entries: [
            Entry("Scene", "Scene"), Entry("Video", "Video"), Entry("Web", "Web"),
            Entry("Application", "Application · unsupported on macOS", off: true),
          ],
          hasQuickLinks: false, style: .checkboxes),
        Section(
          id: "category", title: "Category",
          entries: [Entry("Wallpaper", "Wallpaper"), Entry("Preset", "Preset"), Entry("Asset", "Asset", off: true)],
          hasQuickLinks: false, style: .checkboxes),
      ]),
    Group(
      id: "rating", title: "Age rating",
      sections: [
        Section(
          id: "rating", title: nil,
          entries: [
            Entry("Everyone", "Everyone (G)"),
            Entry("Questionable", "Questionable (PG-13)", off: true),
            Entry("Mature", "Mature (R-18)", off: true),
          ], hasQuickLinks: false, style: .checkboxes)
      ]),
    Group(
      id: "resolution", title: "Resolution",
      sections: [
        resolution(
          "widescreen", "Widescreen", standard: "Standard definition", prefix: "",
          sizes: ["1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160"]),
        resolution(
          "ultrawide", "Ultrawide", standard: "Ultrawide (standard)", prefix: "Ultrawide ",
          sizes: ["2560 x 1080", "3440 x 1440"]),
        resolution(
          "dual", "Dual monitor", standard: "Dual monitor (standard)", prefix: "Dual ",
          sizes: ["3840 x 1080", "5120 x 1440", "7680 x 2160"]),
        resolution(
          "triple", "Triple monitor", standard: "Triple monitor (standard)", prefix: "Triple ",
          sizes: ["4096 x 768", "5760 x 1080", "7680 x 1440", "11520 x 2160"]),
        resolution(
          "portrait", "Portrait monitor / phone", standard: "Portrait monitor / phone (standard)",
          prefix: "Portrait ", sizes: ["720 x 1280", "1080 x 1920", "1440 x 2560", "2160 x 3840"]),
        Section(
          id: "other-resolution", title: nil,
          entries: [
            Entry("Other resolution", "Other resolution"),
            Entry("Dynamic resolution", "Dynamic resolution"),
          ],
          hasQuickLinks: false, style: .checkboxes),
      ]),
    Group(
      id: "genre", title: "Tags",
      sections: [
        Section(
          id: "genre", title: nil,
          entries: [
            Entry("Abstract", "Abstract"), Entry("Animal", "Animal"), Entry("Anime", "Anime"),
            Entry("Cartoon", "Cartoon"), Entry("CGI", "CGI"), Entry("Cyberpunk", "Cyberpunk"),
            Entry("Fantasy", "Fantasy"), Entry("Game", "Game"), Entry("Girls", "Girls"),
            Entry("Guys", "Guys"), Entry("Landscape", "Landscape"), Entry("Medieval", "Medieval"),
            Entry("Memes", "Memes"), Entry("MMD", "MMD (Miku Miku Dance)"), Entry("Music", "Music"),
            Entry("Nature", "Nature"), Entry("Pixel art", "Pixel art"), Entry("Relaxing", "Relaxing"),
            Entry("Retro", "Retro"), Entry("Sci-Fi", "Sci-Fi"), Entry("Sports", "Sports"),
            Entry("Technology", "Technology"), Entry("Television", "Television"),
            Entry("Vehicle", "Vehicle"),
            Entry("Unspecified", "Unspecified genre", off: true),
          ], hasQuickLinks: true, style: .chips)
      ]),
  ]

  static var sections: [Section] { groups.flatMap(\.sections) }
  /// The tags offered as chips, whose required ones the chips show rather than "Show only".
  static let chipTags: Set<String> = Set(
    groups.flatMap(\.sections).filter { $0.style == .chips }.flatMap(\.tags))
  static var entries: [Entry] { sections.flatMap(\.entries) }

  /// Every box that starts unticked, in the catalog's order.
  static let defaultExcludedTags: [String] = entries.filter(\.isOffByDefault).map(\.tag)

  /// SF Symbol for the client-side Hide installed filter in Discover's Filters sidebar.
  static let hideInstalledSystemImage = "eye.slash"

  /// Lower-cased catalog tag → canonical catalog spelling, so a tag clicked in the Workshop
  /// inspector matches its sidebar box or chip regardless of casing.
  private static let canonicalByLowercase: [String: String] = {
    var map: [String: String] = [:]
    for entry in showOnly { map[entry.tag.lowercased()] = entry.tag }
    for entry in entries { map[entry.tag.lowercased()] = entry.tag }
    return map
  }()

  /// Catalog tags whose localized display label differs from the English Steam tag spelling.
  private static let localizedKeyOverrides: [String: String] = [
    "everyone": "Everyone (G)",
    "questionable": "Questionable (PG-13)",
    "mature": "Mature (R-18)",
    "standard definition": "Standard definition",
    "ultrawide standard definition": "Ultrawide (standard)",
    "dual standard definition": "Dual monitor (standard)",
    "triple standard definition": "Triple monitor (standard)",
    "portrait standard definition": "Portrait monitor / phone (standard)",
    "mmd": "MMD (Miku Miku Dance)",
    "unspecified": "Unspecified genre",
  ]

  /// Returns the catalog's canonical spelling for `tag` when it is a known Workshop filter tag,
  /// otherwise the trimmed tag as-is.
  static func canonicalTag(_ tag: String) -> String {
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    return canonicalByLowercase[trimmed.lowercased()] ?? trimmed
  }

  /// Localized display label for a known Workshop filter tag (resolution numbers and unknown tags
  /// stay verbatim so untrusted Steam tags are never looked up as catalog keys).
  @MainActor
  static func displayName(for tag: String) -> String {
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if let override = localizedKeyOverrides[lower] {
      return PanelLocale.shared.catalogString(override)
    }
    if let entry = entries.first(where: { $0.tag.lowercased() == lower }) {
      if case .verbatim = entry.name { return entry.tag }
      return PanelLocale.shared.catalogString(entry.tag)
    }
    if let required = showOnly.first(where: { $0.tag.lowercased() == lower }) {
      return PanelLocale.shared.catalogString(required.tag)
    }
    return trimmed
  }
}

/// The Workshop filters as the page edits them before and after asking Steam: the tags an item
/// must carry, the tags that hide it, and the client-side Hide installed switch.
///
/// A tag is never both required and excluded: requiring one stops excluding it and the other way
/// round. The count the Filter button shows is every required tag plus every box or chip whose
/// state differs from its default plus Hide installed when enabled, so it reads zero right after
/// **Clear**.
struct WorkshopFilterDraft: Equatable {
  var tags: [String]
  var excludedTags: [String]
  /// Client-side filter: hides items on the current Steam page that are already in the local
  /// library. Never sent to Steam.
  var hideInstalled = false

  static let defaultExcludedTags = WorkshopFilterCatalog.defaultExcludedTags

  /// No required tag, the defaults excluded, and installed items shown: what **Clear** restores.
  static var cleared: WorkshopFilterDraft {
    WorkshopFilterDraft(tags: [], excludedTags: defaultExcludedTags, hideInstalled: false)
  }

  /// How many server-side Steam tag filters differ from their defaults (excluding client-side
  /// `hideInstalled`).
  var serverFilterCount: Int {
    let defaults = Self.defaultExcludedTags
    return tags.count + defaults.filter { !excludedTags.contains($0) && !tags.contains($0) }.count
      + excludedTags.filter { !defaults.contains($0) }.count
  }

  /// How many filters are in effect, including client-side `hideInstalled`.
  var count: Int { serverFilterCount + (hideInstalled ? 1 : 0) }

  /// Boxes and chips of `group` whose state differs from its default.
  func count(in group: WorkshopFilterCatalog.Group) -> Int {
    group.tags.filter { chipSelection($0) != Self.defaultSelection($0) }.count
  }

  /// "Show only" boxes that are ticked, the client-side Hide installed switch when on, plus any
  /// tags that are required without a box or chip.
  var requiredCount: Int {
    tags.filter { !WorkshopFilterCatalog.chipTags.contains($0) }.count + (hideInstalled ? 1 : 0)
  }

  /// Whether the box of `tag` is ticked: not excluded.
  func isIncluded(_ tag: String) -> Bool { !excludedTags.contains(tag) }

  func isRequired(_ tag: String) -> Bool { tags.contains(tag) }

  /// How the chip of `tag` stands: selected (required), hidden (excluded) or neither.
  func chipSelection(_ tag: String) -> TagChip.Selection {
    if isRequired(tag) { return .required }
    return excludedTags.contains(tag) ? .excluded : .plain
  }

  private static func defaultSelection(_ tag: String) -> TagChip.Selection {
    defaultExcludedTags.contains(tag) ? .excluded : .plain
  }

  mutating func setChip(_ tag: String, _ selection: TagChip.Selection) {
    setRequired(tag, selection == .required)
    setExcluded([tag], selection == .excluded)
  }

  /// **Reset** of a chip section: each chip back to how it starts.
  mutating func resetChips(in section: WorkshopFilterCatalog.Section) {
    for tag in section.tags { setChip(tag, Self.defaultSelection(tag)) }
  }

  /// Every chip of the section stands as it starts, so **Reset** has nothing to do.
  func chipsAreAtDefaults(in section: WorkshopFilterCatalog.Section) -> Bool {
    section.tags.allSatisfy { chipSelection($0) == Self.defaultSelection($0) }
  }

  /// Required tags the "Show only" boxes and the chips do not offer, which the popover lists as ticked boxes of
  /// their own so they can be unticked (a tag restored from an earlier session, say).
  var otherRequiredTags: [String] {
    let offered = Set(WorkshopFilterCatalog.showOnly.map(\.tag)).union(WorkshopFilterCatalog.chipTags)
    return tags.filter { !offered.contains($0) }
  }

  mutating func setRequired(_ tag: String, _ required: Bool) {
    if required {
      if !tags.contains(tag) { tags.append(tag) }
      excludedTags.removeAll { $0 == tag }
    } else {
      tags.removeAll { $0 == tag }
    }
  }

  /// Ticks or unticks the box of `tag`.
  mutating func setIncluded(_ tag: String, _ included: Bool) {
    setExcluded([tag], !included)
  }

  mutating func setExcluded(_ tagsToSet: [String], _ excluded: Bool) {
    var set = excludedTags
    for tag in tagsToSet {
      if excluded {
        if !set.contains(tag) { set.append(tag) }
        tags.removeAll { $0 == tag }
      } else {
        set.removeAll { $0 == tag }
      }
    }
    excludedTags = set
  }

  /// **All** of a section.
  mutating func includeAll(in section: WorkshopFilterCatalog.Section) {
    setExcluded(section.tags, false)
  }

  /// **None** of a section.
  mutating func excludeAll(in section: WorkshopFilterCatalog.Section) {
    setExcluded(section.tags, true)
  }

  /// Every box of the section is ticked, so **All** has nothing to do.
  func includesAll(in section: WorkshopFilterCatalog.Section) -> Bool {
    section.tags.allSatisfy(isIncluded)
  }

  /// No box of the section is ticked, so **None** has nothing to do.
  func includesNone(in section: WorkshopFilterCatalog.Section) -> Bool {
    !section.tags.contains(where: isIncluded)
  }

  mutating func clear() { self = .cleared }
}
