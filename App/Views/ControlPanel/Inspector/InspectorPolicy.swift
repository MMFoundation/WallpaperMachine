import Foundation

/// The rules that decide which controls the Installed inspector offers and when they are enabled,
/// as pure functions of the wallpaper, the target display and the downloads, so each one is tested
/// without a view. They are the page's (`panel.js:794-853`), unchanged.
@MainActor
enum InspectorPolicy {
  // MARK: Running

  /// Whether the wallpaper's type is one this app runs. The renderer names every type it cannot run
  /// `unknown`, Wallpaper Engine's Application wallpapers among them (the page told those apart as
  /// `Application`, which an installed row cannot), so for an installed wallpaper an unknown type
  /// is the page's "cannot run on macOS".
  static func canRun(_ kind: LibraryRow.Kind) -> Bool { kind != .unknown }

  // MARK: Apply

  /// Apply (or Reapply) is offered to a wallpaper whose type is known, on a target display that is
  /// enabled and not a mirror. Whether the Mac can render it is not part of the rule: the
  /// wallpaper's own notice says so, and the button stays.
  static func canActivate(kind: LibraryRow.Kind, target: TargetDisplayOption?) -> Bool {
    canRun(kind) && target?.isSelectable == true
  }

  /// One step for every display, offered only where there is more than one to put it on. A mirror
  /// follows its source and a disabled display shows nothing, so neither counts.
  static func offersApplyToAll(_ row: LibraryRow, sharedDisplayCount: Int) -> Bool {
    row.isSupported && canRun(row.kind) && sharedDisplayCount >= 2
  }

  /// Direct apply to a chosen display submenu, offered when two or more displays are connected and
  /// the wallpaper's type can run on macOS.
  static func offersApplyToDisplay(_ row: LibraryRow, displayCount: Int) -> Bool {
    canRun(row.kind) && displayCount >= 2
  }

  /// Apply to all displays has nothing to do when every shared display already shows the wallpaper.
  static func appliesEverywhereAlready(_ wallpaperID: String, sharedDisplayWallpapers: [String?])
    -> Bool
  {
    !sharedDisplayWallpapers.isEmpty && sharedDisplayWallpapers.allSatisfy { $0 == wallpaperID }
  }

  /// The live preview needs the preview window and a wallpaper of a known type.
  static func offersPreview(kind: LibraryRow.Kind, previewAvailable: Bool) -> Bool {
    previewAvailable && canRun(kind)
  }

  // MARK: Playlist

  enum PlaylistToggle: Equatable {
    case hidden
    /// The wallpaper can be listed, but the target display has no playlist of its own to edit.
    case disabled(isListed: Bool)
    case enabled(isListed: Bool)
  }

  /// The list button adds the wallpaper to or removes it from the target display's own list, for a
  /// wallpaper the Mac can render; a mirror or a disabled target has no list to change.
  static func playlistToggle(_ row: LibraryRow, target: TargetDisplayOption?, listedIDs: [String])
    -> PlaylistToggle
  {
    guard row.isSupported else { return .hidden }
    let listed = listedIDs.contains(row.id)
    return target?.isSelectable == true ? .enabled(isListed: listed) : .disabled(isListed: listed)
  }

  // MARK: Reinstall

  /// An installed Workshop wallpaper (its id is the Workshop's number) that can run on macOS can be
  /// downloaded again to repair or refresh it, unless a download for it is under way or a request
  /// for it waits for setup (the page's `canReinstall`).
  static func canReinstall(_ row: LibraryRow, hasPendingDownload: Bool, hasRequest: Bool) -> Bool {
    isWorkshopID(row.id) && canRun(row.kind) && !hasPendingDownload && !hasRequest
  }

  static func isWorkshopID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.allSatisfy { (0x30...0x39).contains($0) }
  }

  // MARK: Problem report

  /// The problem report the inspector offers for an installed wallpaper.
  enum IssueReport: Equatable {
    /// None: nothing failed, and the wallpaper's type cannot run on macOS, which its own sentence
    /// already says; or it is a scene waiting for the shared resources, whose notice offers the
    /// fix instead.
    case none
    /// **Not working? Report on GitHub** under the type sentence, and the menu's report.
    case plain
    /// Applying it just failed: the failure notice carries the report, prefilled with the failure,
    /// and the plain link steps aside. The menu's report carries the failure too.
    case failure(String)
  }

  /// The page's `failureReport` and `report`: a failure always comes with its report; otherwise
  /// only a wallpaper that can run gets the plain one. A scene that cannot play because the shared
  /// scene resources are missing gets none, whatever failed: that is setup for the user to do, not
  /// a problem to report, and a report link beside it is read as the way out.
  static func issueReport(
    for row: LibraryRow, failure: String?, sceneResourcesMissing: Bool
  ) -> IssueReport {
    if sceneResourcesMissing, row.kind == .scene { return .none }
    if let failure { return .failure(failure) }
    return canRun(row.kind) ? .plain : .none
  }

  // MARK: Packaged stills

  /// A still image this app packaged: saved from pixiv or imported from disk.
  static func isPackagedStill(_ id: String) -> Bool {
    id.hasPrefix("pixiv-") || id.hasPrefix("image-")
  }

  /// The artwork id of a pixiv-packaged still (`pixiv-<artwork>-p<page>`).
  static func pixivArtworkID(of id: String) -> String? {
    guard id.hasPrefix("pixiv-") else { return nil }
    let parts = id.dropFirst("pixiv-".count).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      parts[1].hasPrefix("p"), parts[1].count > 1,
      parts[1].dropFirst().utf8.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return String(parts[0])
  }

  /// Which sentence describes the wallpaper under its header.
  enum KindNote: Equatable {
    case pixivStill, importedStill, scene, video, web, unsupported
  }

  static func kindNote(for row: LibraryRow) -> KindNote {
    if pixivArtworkID(of: row.id) != nil { return .pixivStill }
    if row.id.hasPrefix("image-") { return .importedStill }
    switch row.kind {
    case .scene: return .scene
    case .video: return .video
    case .web: return .web
    case .unknown: return .unsupported
    }
  }

  // MARK: Frame rate

  /// Whether a display's Frame rate row, and the note about the ceiling on it, are shown. The
  /// native video player plays a clip at the clip's own rate, so neither the display's frame rate
  /// nor a limit on it applies to what it draws; the row comes back for any other player, which
  /// the scene engine's own drawing of a clip is.
  static func offersFrameRate(for display: InspectorOptions.DisplayRow) -> Bool {
    !display.isDrawnByNativePlayer
  }

  // MARK: Scale percentage

  /// The Scale percentage slider is offered where the scale factor sizes a picture: scene and video
  /// wallpapers. A web page always fills its window, so a slider for shrinking it would do nothing.
  static func offersScalePercentage(_ options: InspectorOptions) -> Bool { options.offersPosition }

  // MARK: Blurred backdrop scaling modes

  /// Fit with blurred backdrop is offered where the scaling mode moves a picture: scene and video wallpapers. A
  /// web page always fills its window. A display already set to it keeps it in the menu.
  static func offersBlurredFit(_ options: InspectorOptions, display: InspectorOptions.DisplayRow)
    -> Bool
  {
    options.offersPosition || display.scalingMode == .matchBlurred
  }

  /// Fill with blurred backdrop is offered where the scaling mode moves a picture: scene and video wallpapers.
  /// A web page always fills its window. A display already set to it keeps it in the menu.
  static func offersBlurredFill(_ options: InspectorOptions, display: InspectorOptions.DisplayRow)
    -> Bool
  {
    options.offersPosition || display.scalingMode == .fillBlurred
  }

  /// What is said under a blurred backdrop scaling mode.
  enum BlurredFitNote: Equatable {
    /// The native video player draws this display and has no blurred fill: its bars stay black.
    case nativePlayer
    /// Nothing: the blurred fill is drawn, or the mode is another one.
    case none
  }

  static func blurredFitNote(for display: InspectorOptions.DisplayRow) -> BlurredFitNote {
    let blurred = display.scalingMode == .matchBlurred || display.scalingMode == .fillBlurred
    return blurred && display.isDrawnByNativePlayer ? .nativePlayer : .none
  }

  // MARK: Apply changes

  /// The footer with Revert and Apply changes is drawn only while something waits to be applied:
  /// an edit the bridge holds (a property, a Wallpaper Engine option, a display's scale factor or
  /// its Enabled switch), text typed but not sent, or a value on its way. Revert and Apply changes
  /// have nothing to act on otherwise, and nil (the options still loading) has no footer either.
  static func showsFooter(_ options: InspectorOptions?) -> Bool { options?.hasChanges == true }

  /// Which of Apply wallpaper and Apply changes is the Installed inspector's accent action.
  enum PrimaryAction: Equatable {
    /// **Apply wallpaper** (or **Reapply wallpaper**) in the header: nothing waits to be applied.
    case applyWallpaper
    /// **Apply changes** in the footer, while edits wait; Apply wallpaper is then drawn plain.
    case applyChanges
  }

  /// Apply changes takes the accent exactly while the footer is drawn, so the two are never the
  /// accent at once. A notice's call to action and an open form's submit button keep their own.
  static func primaryAction(_ options: InspectorOptions?) -> PrimaryAction {
    showsFooter(options) ? .applyChanges : .applyWallpaper
  }

  // MARK: Sections

  /// Displays opens by itself once the wallpaper is on a display. The state is the person's from the
  /// first draw on, so a later change of the rows never opens or closes it.
  static func displaysOpenByDefault(_ options: InspectorOptions) -> Bool { !options.displays.isEmpty }

  /// Beside another display, each display's card shows a one-line summary under its name
  /// (`InspectorWording.displaySummary`) and starts collapsed: two open cards of a dozen controls
  /// each push everything after them far down. One display has nothing to choose between.
  static func summarizesDisplays(_ options: InspectorOptions) -> Bool { options.displays.count >= 2 }

  /// A display's card starts open when it is the only one, or while one of its settings waits for
  /// Apply changes, so a staged value is never hidden when the inspector opens. As for the sections,
  /// the state is the person's from the first draw on, except that a value staged later (the Black
  /// bars card stages a scale factor) opens the card again (`InspectorSection`'s `opensWhen`).
  static func displayCardOpenByDefault(
    _ options: InspectorOptions, display: InspectorOptions.DisplayRow
  ) -> Bool {
    !summarizesDisplays(options) || display.hasStagedChanges
  }

  /// Wallpaper Engine options opens when one of them differs from its default.
  /// It opens too for one that waits for Apply changes, which an option restored to its default does.
  static func engineOptionsOpenByDefault(_ options: InspectorOptions) -> Bool {
    options.engineHiddenModified
      || (options.engineOptions ?? []).contains { $0.row.isModified || $0.row.isStaged }
  }

  /// Collections opens for a wallpaper that belongs to one.
  static func collectionsOpenByDefault(_ collections: [CollectionRow], wallpaperID: String) -> Bool {
    collections.contains { $0.wallpaperIDs.contains(wallpaperID) }
  }

  /// Rating & tags stays collapsed by default until the user adds metadata to this wallpaper.
  static func metadataOpenByDefault(_ metadata: WallpaperMetadata) -> Bool {
    !metadata.isEmpty
  }

  // MARK: Properties section

  /// Long wallpapers gain a search field and Modified filter chip once they carry more than this
  /// many editable author properties.
  static let propertyFilterThreshold = 10

  /// One group inside the Wallpaper properties card: either the leading rows that precede the
  /// first textual heading (`heading == nil`, always visible) or a heading followed by its rows.
  struct PropertyGroup: Equatable, Identifiable {
    static let leadingID = "__leading__"

    let id: String
    let heading: InspectorOptions.PropertyRow?
    let rows: [InspectorOptions.PropertyRow]

    /// A textual heading with rows under it folds away; leading rows and empty headings stay open.
    var isCollapsible: Bool { heading != nil && !rows.isEmpty }
  }

  /// Whether a property row has anything to draw: a control row always does (its name stands in for
  /// an empty label), a group or description only when its label has words, artwork or a rule.
  static func drawsRow(_ row: InspectorOptions.PropertyRow) -> Bool {
    switch row.control {
    case .heading, .description(detail: nil):
      return !labelDocument(for: row).isEmpty
    case .description:
      return true
    default:
      return true
    }
  }

  /// The rows the properties section shows, in the author's order.
  static func visibleProperties(_ options: InspectorOptions) -> [InspectorOptions.PropertyRow] {
    options.properties.filter(drawsRow)
  }

  /// Whether the properties section offers the search field and Modified filter chip.
  static func showsPropertyFilter(for rows: [InspectorOptions.PropertyRow]) -> Bool {
    rows.filter { $0.control.isControl }.count > propertyFilterThreshold
  }

  /// How many editable author properties differ from their default or hold a pending edit.
  static func modifiedPropertyCount(in rows: [InspectorOptions.PropertyRow]) -> Int {
    rows.filter { $0.control.isControl && $0.isModifiedOrStaged }.count
  }

  /// Whether the quick "Show edits on desktop" toggle applies to this wallpaper. Only supported
  /// scenes follow live property edits on the desktop; videos and web pages wait for Apply changes.
  static func offersLiveDesktopEdits(_ options: InspectorOptions) -> Bool {
    options.isSupported && options.kind == .projectScene
  }

  /// Whether a heading carries readable text and starts a collapsible subgroup. Decorative
  /// headings (rules or image-only banners with no words) stay inline with surrounding rows.
  static func isCollapsibleHeading(_ row: InspectorOptions.PropertyRow) -> Bool {
    row.control == .heading && !labelDocument(for: row).plainText.isEmpty
  }

  /// Partitions visible property rows into leading rows and heading subgroups, applying an
  /// optional case-insensitive search query and Modified-only filter.
  static func propertyGroups(
    in rows: [InspectorOptions.PropertyRow], query: String = "", modifiedOnly: Bool = false
  ) -> [PropertyGroup] {
    var raw: [(id: String, heading: InspectorOptions.PropertyRow?, rows: [InspectorOptions.PropertyRow])] = []
    for row in rows {
      if isCollapsibleHeading(row) {
        raw.append((id: row.id, heading: row, rows: []))
      } else if raw.isEmpty {
        raw.append((id: PropertyGroup.leadingID, heading: nil, rows: [row]))
      } else {
        raw[raw.count - 1].rows.append(row)
      }
    }

    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty || modifiedOnly else {
      return raw.map { PropertyGroup(id: $0.id, heading: $0.heading, rows: $0.rows) }
    }

    var filtered: [PropertyGroup] = []
    for group in raw {
      let headingMatches =
        !needle.isEmpty && group.heading.map { propertyRowMatches($0, query: needle) } == true
      let kept = group.rows.filter { row in
        if row.control == .heading { return false }
        if modifiedOnly {
          guard row.control.isControl, row.isModifiedOrStaged else { return false }
        }
        if needle.isEmpty { return true }
        return headingMatches || propertyRowMatches(row, query: needle)
      }
      if !kept.isEmpty {
        filtered.append(PropertyGroup(id: group.id, heading: group.heading, rows: kept))
      }
    }
    return filtered
  }

  /// The subgroup id that holds the authored property identified by `propertyKey`, or nil when the
  /// key belongs to another section or the always-visible leading group.
  static func collapsibleGroupID(
    containingPropertyKey propertyKey: String, wallpaperID: String, in groups: [PropertyGroup]
  ) -> String? {
    for group in groups where group.isCollapsible {
      if group.rows.contains(where: { InspectorAction.property(wallpaperID, $0.id) == propertyKey }) {
        return group.id
      }
    }
    return nil
  }

  private static func propertyRowMatches(_ row: InspectorOptions.PropertyRow, query: String) -> Bool {
    if row.name.localizedCaseInsensitiveContains(query) { return true }
    if labelDocument(for: row).plainText.localizedCaseInsensitiveContains(query) { return true }
    switch row.control {
    case .choice(_, let choices):
      return choices.contains { $0.label.localizedCaseInsensitiveContains(query) }
    case .userShortcut(let state):
      switch state.selection {
      case .application(let bundleID, let displayName):
        return displayName.localizedCaseInsensitiveContains(query)
          || bundleID.localizedCaseInsensitiveContains(query)
      case .shortcut(let name):
        return name.localizedCaseInsensitiveContains(query)
      default:
        return false
      }
    case .description(let detail):
      return detail?.localizedCaseInsensitiveContains(query) == true
    default:
      return false
    }
  }

  /// The parsed label of a row: the author's markup, or the app's words as one plain paragraph.
  @MainActor
  static func labelDocument(for row: InspectorOptions.PropertyRow) -> PropertyLabelDocument {
    labelDocument(row.label)
  }

  @MainActor
  static func labelDocument(_ label: PropertyLabels.Presentation) -> PropertyLabelDocument {
    guard let markup = label.markup else {
      guard !label.text.isEmpty else { return PropertyLabelDocument(blocks: []) }
      return PropertyLabelDocument(blocks: [
        .paragraph(
          .init(runs: [.init(text: label.text)], heading: nil, isCentered: false, marker: nil))
      ])
    }
    return PropertyLabelCache.document(markup: markup, images: label.images)
  }
}

/// Parsed labels, kept like the page kept its 256 rendered ones: the inspector reads its rows
/// whenever anything it shows changes, and a label's parse is the one costly step.
@MainActor
enum PropertyLabelCache {
  private struct Key: Hashable {
    let markup: String
    let images: [String: URL]
  }
  private static var documents: [Key: PropertyLabelDocument] = [:]
  private static let limit = 256

  static func document(markup: String, images: [String: URL]) -> PropertyLabelDocument {
    let key = Key(markup: markup, images: images)
    if let known = documents[key] { return known }
    let document = PropertyLabelDocument.parse(markup, images: images)
    if documents.count >= limit { documents.removeAll(keepingCapacity: true) }
    documents[key] = document
    return document
  }
}
