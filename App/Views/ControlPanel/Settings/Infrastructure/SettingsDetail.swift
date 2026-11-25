import SwiftUI

/// The Settings page: the list of sections along its leading edge, and beside it the page of the
/// section chosen there, or, while a search is typed in the page's search bar, every section that
/// has a match, one under another with only the matching rows.
///
/// The page offers its parts the width it was given and asks for none of its own, as Installed and
/// Steam Workshop do. The detail column carries the inspector on every page (closed here), which
/// asks for 260 points; a page that also asked for width made the window's content wider than the
/// 760-point window, clipping the cards, and at some heights AppKit looped over the window's
/// constraints and threw. A GeometryReader has no minimum of its own. The pages still have to fit
/// what the list leaves of the narrowest window, which `SettingsSectionsRenderTests` measures on
/// `SettingsPages`.
struct SettingsDetail: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 0) {
        SettingsSectionList()
        Rectangle().fill(theme.surface.line.color).frame(width: 0.5)
        SettingsPages().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}

/// The scrolling pages of the Settings detail column. Desktop Widgets is the one page that does not
/// scroll as a whole: without a search it is a workspace (`WidgetsWorkspace`) whose canvas stays on
/// show while its inspector scrolls; its rows still join the search results as every page's do.
struct SettingsPages: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var position = ScrollPosition(edge: .top)

  var body: some View {
    let settings = controller.settings
    if !settings.search.isActive && settings.selectedSection == .widgets {
      WidgetsWorkspace()
        .id(PageIdentity(section: .widgets, searchSection: nil, epoch: settings.scrollEpoch, query: ""))
        .background(theme.surface.surface.color, ignoresSafeAreaEdges: [])
    } else {
      pages(settings)
    }
  }

  private func pages(_ settings: SettingsModel) -> some View {
    let search = settings.search
    let scopedSection = search.isActive ? settings.searchSection.flatMap { search.shows($0) ? $0 : nil } : nil
    let displayedSections =
      search.isActive ? (scopedSection.map { [$0] } ?? search.sections) : [settings.selectedSection]
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 30) {
        if let scopedSection {
          SettingsSearchScopeBar(section: scopedSection)
        }
        if search.hasNoResults {
          PanelEmptyState(
            verbatim: L("No settings match “\(search.query)”."), systemImage: "magnifyingglass"
          )
          .frame(maxWidth: .infinity, minHeight: 240)
        } else {
          ForEach(displayedSections, id: \.self) { section in
            page(of: section)
          }
        }
      }
      .frame(maxWidth: 620, alignment: .leading)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
    }
    .scrollPosition($position)
    // Reset the position without recreating every result and repeating each
    // section's onAppear work for every character typed.
    .onChange(of: PageIdentity(
      section: settings.selectedSection, searchSection: scopedSection,
      epoch: settings.scrollEpoch, query: search.query), initial: true
    ) { position.scrollTo(edge: .top) }
    // Not under the title bar, which keeps the page's colour across the window.
    .background(theme.surface.surface.color, ignoresSafeAreaEdges: [])
    // A single page and a list of results have different estimated heights.
    // Reset that layout only when entering/leaving search, never while typing.
    .id(search.isActive)
  }

  private struct PageIdentity: Hashable {
    let section: SettingsSection
    let searchSection: SettingsSection?
    let epoch: Int
    let query: String
  }

  /// The one place that names every section's view.
  @ViewBuilder
  private func page(of section: SettingsSection) -> some View {
    switch section {
    case .quick: QuickSettingsSection()
    case .general: GeneralSettingsSection()
    case .appearance: AppearanceSettingsSection()
    case .desktop: DesktopSettingsSection()
    case .widgets:
      VStack(alignment: .leading, spacing: 18) {
        WidgetsSettingsSection()
        if controller.settings.search.isActive {
          SettingsMatchingWidgetsCard()
        }
      }
    case .playback: PlaybackSettingsSection()
    case .performance: PerformanceSettingsSection()
    case .displays: DisplaysSettingsSection()
    case .shortcuts: ShortcutsSettingsSection()
    case .library: LibrarySettingsSection()
    case .storage: StorageSettingsSection()
    case .about: AboutSettingsSection()
    }
  }
}

/// Banner shown at the top of `SettingsPages` when a search is scoped to one section from the
/// section list, offering clear one-click exits back to all results or the full section.
private struct SettingsSearchScopeBar: View {
  let section: SettingsSection

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let sectionName = settings.text(section.title)
    PanelCard {
      DisplaysRowLayout {
        Text(verbatim: L("Showing matches in \(sectionName)"))
          .font(.panel(.callout))
          .foregroundStyle(theme.surface.muted.color)
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
          Button("All results") { settings.clearSearchScope() }
            .buttonStyle(.panelSecondary)
          Button("Clear search") { settings.exitSearch(to: section) }
            .buttonStyle(.panelSecondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .controlSize(.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.search-scope-bar")
  }
}

/// Live desktop widget matches shown during Settings search so searching a widget's name or label
/// shows the matching widget directly and jumps to it in the Desktop Widgets workspace.
private struct SettingsMatchingWidgetsCard: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let search = settings.search
    let matches = controller.desktopWidgets.widgets.filter {
      search.matches(SettingsModel.widgetSearchText($0, controller: controller))
    }
    if !matches.isEmpty {
      PanelCard {
        DividedRows {
          ForEach(matches) { widget in
            let name = SettingsModel.widgetDisplayName(widget, controller: controller)
            DisplaysRowLayout {
              HStack(spacing: 8) {
                Image(systemName: WidgetsSettingsSection.symbol(of: widget.kind))
                  .font(.panel(.callout))
                  .foregroundStyle(theme.surface.muted.color)
                  .accessibilityHidden(true)
                Text(verbatim: name)
                  .font(.panel(.body))
                  .foregroundStyle(theme.surface.text.color)
                  .lineLimit(1)
                  .truncationMode(.tail)
                  .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
              }
              Button("Edit…") {
                controller.widgetsSettings.select(widget.id)
                settings.select(.widgets)
              }
              .buttonStyle(.panelSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.widget-match.\(widget.id)")
          }
        }
      }
      .controlSize(.small)
    }
  }
}
