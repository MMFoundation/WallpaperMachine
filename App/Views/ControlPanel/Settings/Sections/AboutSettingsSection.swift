import AppKit
import SwiftUI

/// Settings › About: the product, its version and updates, the bundled release notes, and its credits.
struct AboutSettingsSection: View {
  private static let versions = SettingsItem.Group("versions")
  private static let updates = SettingsItem.Group("updates", title: "Updates")
  static let releaseNotes = SettingsItem.Group("release-notes", title: "Release notes")
  private static let share = SettingsItem.Group("share", title: "Spread the word")
  private static let moreApps = SettingsItem.Group("more-apps", title: "More from MMFoundation")
  private static let credits = SettingsItem.Group("credits")

  static let appVersion = SettingsItem(
    id: "about.app-version", section: .about, group: versions, title: "App version")
  static let gitRevision = SettingsItem(
    id: "about.git-revision", section: .about, group: versions, title: "Git revision")

  static let updateActions = SettingsItem(
    id: "about.update-actions", section: .about, group: updates, title: "Check for Updates",
    keywords: ["Check Now", "Show Update…", "Updates not yet checked", "Last check"])
  static let updateAutomatic = SettingsItem(
    id: "about.update-automatic", section: .about, group: updates,
    title: "Check for updates automatically",
    note: "Updates are checked in the background. You choose when to download and restart.")
  static let updateNotes = SettingsItem(
    id: "about.update-notes", section: .about, group: releaseNotes, title: "Release notes",
    keywords: ["What’s new"])
  static let earlierReleases = SettingsItem(
    id: "about.earlier-releases", section: .about, group: releaseNotes, title: "Earlier versions",
    note: "Release notes include up to 20 recent versions. Older changes are available on GitHub.")
  static let shareApp = SettingsItem(
    id: "about.share", section: .about, group: share, title: "Share WallpaperMachine…",
    keywords: ["Star on GitHub"])
  static let ohmyshot = SettingsItem(
    id: "about.ohmyshot", section: .about, group: moreApps, title: "Get OhMyShot",
    note:
      "Screenshots, recordings, annotation and on-device text recognition for your Mac, from the people who make WallpaperMachine. Free and open source."
  )

  static let creditsItem = SettingsItem(
    id: "about.credits", section: .about, group: credits, title: "GNU General Public License v3",
    note:
      "Not affiliated with Wallpaper Engine or Valve. WallpaperMachine itself is open source under GPL-3.0-only. Workshop browsing is independently implemented. No warranty is provided.",
    keywords: ["MMFoundation", "Join Discord"]
  )

  static let items = [
    appVersion, gitRevision, updateAutomatic, updateActions, updateNotes,
    earlierReleases,
    shareApp,
    ohmyshot,
    creditsItem,
  ]

  /// Only rows offered by this build and its bundled release history appear in search.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    let count = controller.updater.notesReleases.count
    var unoffered: Set<String> =
      count == 0 ? [updateNotes.id, earlierReleases.id] : count == 1 ? [earlierReleases.id] : []
    if !controller.updater.isAvailable { unoffered.formUnion([updateAutomatic.id, updateActions.id]) }
    if !ExternalLink.offersOhMyShot() { unoffered.insert(ohmyshot.id) }
    return unoffered
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    SettingsPage(.about) {
      // The product header is the page's face, not a setting: a search shows only what it finds.
      if !controller.settings.search.isActive { AboutProductHeader() }
      SettingsGroup(Self.versions, in: .about) { AboutVersionRows() }
      if controller.updater.isAvailable {
        SettingsGroup(Self.updates, in: .about) { AboutUpdatesRows() }
      }
      AboutReleaseNotesGroup()
      SettingsGroup(Self.share, in: .about) { AboutShareRow() }
      if ExternalLink.offersOhMyShot() {
        SettingsGroup(Self.moreApps, in: .about) { AboutOhMyShotRow() }
      }
      SettingsGroup(Self.credits, in: .about) { AboutCreditsRow() }
    }
    // Row buttons share one size across Settings.
    .controlSize(.small)
  }
}

// MARK: - Product header

/// The app's icon as the Dock shows it, its name and version. The icon follows the Dock icon choice
/// of Settings › Appearance, or the season's while one is on.
private struct AboutProductHeader: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let version = controller.aboutInfo.version
    HStack(spacing: 16) {
      Image(nsImage: AboutIcons.image(named: controller.dockIconName))
        .resizable()
        .interpolation(.high)
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: "WallpaperMachine")
          .font(.system(size: 22, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text("Independent macOS client")
          .font(.system(size: 13))
          .foregroundStyle(theme.surface.muted.color)
        if !version.isEmpty {
          Text("Version \(version)")
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }
}

/// The Dock icons, decoded once: they are 1024-pixel artwork that the header only shows small.
@MainActor
private enum AboutIcons {
  private static var cache: [String: NSImage] = [:]

  static func image(named name: String) -> NSImage {
    if let cached = cache[name] { return cached }
    let image =
      (try? AppThemePreferences.dockImage(named: name)) ?? NSApp.applicationIconImage ?? NSImage()
    cache[name] = image
    return image
  }
}

// MARK: - Versions

private struct AboutVersionRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let info = controller.aboutInfo
    // The value is what VoiceOver reads after the row's title, so the row does not rename it.
    DisplaysRow(item: AboutSettingsSection.appVersion, labelsControl: false) {
      value(info.version, monospaced: false)
    }
    DisplaysRow(item: AboutSettingsSection.gitRevision, labelsControl: false) {
      value(info.gitRevision, monospaced: true)
    }
  }

  /// A version, or "Unavailable" in the regular type: a placeholder does not take the monospaced
  /// type of a revision, so it does not read as one.
  private func value(_ text: String, monospaced: Bool) -> some View {
    Text(verbatim: text.isEmpty ? L("Unavailable") : text)
      .font(.system(size: 12, design: monospaced && !text.isEmpty ? .monospaced : .default))
      .foregroundStyle(theme.surface.muted.color)
  }
}

// MARK: - Updates

private struct AboutUpdatesRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale

  var body: some View {
    let updater = controller.updater
    let presentation = UpdatePresentation(status: updater, locale: locale)
    let key = PanelActionCoordinator.key("checkForUpdates")
    DisplaysRow(item: AboutSettingsSection.updateAutomatic) {
      AutomaticUpdateChecksToggle()
    }
    DisplaysRow(item: AboutSettingsSection.updateActions, title: presentation.statusText, labelsControl: false) {
      Button(presentation.actionLabel) {
        controller.launch(key) { try await controller.checkForUpdates() }
      }
      .disabled(!updater.canCheck || controller.isBusy(key))
    }
  }
}

// MARK: - Credits

/// **Share WallpaperMachine…** opens the system share menu with the website; **Star on GitHub**
/// opens the repository and counts as the star the star prompt would ask for.
private struct AboutShareRow: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let item = AboutSettingsSection.shareApp
    if controller.settings.search.shows(item) {
      let share = controller.appShare
      HStack(spacing: 8) {
        ShareLink(
          item: share.url, subject: Text(verbatim: share.subject),
          message: Text(verbatim: share.message)
        ) {
          Text("Share WallpaperMachine…")
        }
        Button("Star on GitHub") {
          controller.launch(PanelActionCoordinator.key("starRepository")) {
            try await controller.starRepository()
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }
}

/// OhMyShot, the capture app MMFoundation also makes: its icon, what it does and its website, in
/// the panel's language. The page shows it only on a Mac that can run it.
private struct AboutOhMyShotRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let item = AboutSettingsSection.ohmyshot
    if settings.search.shows(item) {
      let website = ExternalLink.ohmyshot(languageTag: controller.appLanguage.effective.tag)
      HStack(spacing: 12) {
        Image("OhMyShotIcon")
          .resizable()
          .interpolation(.high)
          .frame(width: 40, height: 40)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: "OhMyShot")
            .font(.panel(.sectionHeader))
          if let note = item.note {
            Text(verbatim: settings.text(note))
              .font(.panel(.callout))
              .foregroundStyle(theme.surface.muted.color)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        Button("Get OhMyShot") { ExternalLink.open(website) }
          .help(website.absoluteString)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }
}

private struct AboutCreditsRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let item = AboutSettingsSection.creditsItem
    if settings.search.shows(item) {
      VStack(alignment: .leading, spacing: 8) {
        if let note = item.note {
          Text(verbatim: settings.text(note))
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
        HStack(spacing: 8) {
          Button("GNU General Public License v3") { ExternalLink.open(ExternalLink.gnuGPL3) }
          // MMFoundation makes the app; its website is where its other projects and its sponsors are.
          Button { ExternalLink.open(ExternalLink.mmfoundation) } label: {
            Text(verbatim: "MMFoundation")
          }
          .help(ExternalLink.mmfoundation.absoluteString)
          // Its Discord server, which also answers the one-time Discord invitation.
          Button("Join Discord") {
            controller.launch(PanelActionCoordinator.key("joinDiscord")) {
              try await controller.joinDiscord()
            }
          }
          .help(ExternalLink.discord.absoluteString)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }
}
