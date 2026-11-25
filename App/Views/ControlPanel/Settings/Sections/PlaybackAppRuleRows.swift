import AppKit
import SwiftUI

/// What the App rules disclosure holds: a line when there are no rules, one row for each rule and a
/// row to add an app. They are rows of the disclosure itself, one after another, so each gets its
/// hairline.
///
/// A rule pauses, mutes, stops or temporarily switches wallpapers while its app is running or in
/// front. Its menus follow the settings model's editing rules like every other control (a draft
/// until the change has run, waiting while the Mac is busy), each under its own key.
struct PlaybackAppRulesEmptyRow: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(
      "No app rules yet. Add an app to pause, mute, stop or switch wallpapers while it is running or in front."
    )
    .font(.system(size: 12))
    .foregroundStyle(theme.surface.muted.color)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

/// The last row of the disclosure: choose an app to add a rule for.
struct PlaybackAddAppRuleRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(PlaybackSettingsSection.addAppRule) {
      HStack {
        Button {
          settings.perform("appRuleAdd") { try await controller.addAppRule() }
        } label: {
          Label("Add app…", systemImage: "plus")
            .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.accent.accent.color)
        .disabled(settings.isLocked("appRuleAdd", whileRunning: true))
        .accessibilityIdentifier(PlaybackSettingsSection.addAppRule.id)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
    }
  }
}

/// One app rule: the app, when it counts, what it does, and a way to remove it.
struct PlaybackAppRuleRow: View {
  let rule: AppRule

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  /// The minus was clicked and waits for its answer.
  @State private var confirmsRemoval = false

  var body: some View {
    let settings = controller.settings
    let name = rule.name.isEmpty ? rule.bundleIdentifier : rule.name
    let displayName = name.isEmpty ? L("App") : name
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        PlaybackAppIcon(bundleIdentifier: rule.bundleIdentifier)
        Text(verbatim: displayName)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        SettingsMenuControl(
          key: "rule-\(rule.id)-condition", saved: rule.condition,
          options: AppRuleCondition.allCases.map { SettingsMenuOption(value: $0, title: $0.title) }
        ) { try await controller.updateAppRule(rule.id, condition: $0) }
        .accessibilityLabel(Text(verbatim: L("Condition for \(displayName)")))
        SettingsMenuControl(
          key: "rule-\(rule.id)-action", saved: rule.action,
          options: AppRuleAction.allCases.map { SettingsMenuOption(value: $0, title: $0.title) }
        ) { try await controller.updateAppRule(rule.id, action: $0) }
        .accessibilityLabel(Text(verbatim: L("Action for \(displayName)")))
        if confirmsRemoval {
          // A rule is removed for good, so the second click is the one that removes it.
          Button("Cancel") { confirmsRemoval = false }
            .buttonStyle(.borderless)
          Button("Remove") {
            confirmsRemoval = false
            settings.perform("rule-\(rule.id)-remove") { try await controller.removeAppRule(rule.id) }
          }
          .buttonStyle(.borderless)
          .foregroundStyle(theme.surface.danger.color)
          .disabled(settings.isLocked("rule-\(rule.id)-remove", whileRunning: true))
          .accessibilityLabel(Text(verbatim: L("Remove the rule for \(displayName)")))
        } else {
          Button {
            confirmsRemoval = true
          } label: {
            Image(systemName: "minus.circle")
              .font(.system(size: 14))
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(settings.isLocked("rule-\(rule.id)-remove", whileRunning: true))
          .help(L("Remove"))
          .accessibilityLabel(Text(verbatim: L("Remove the rule for \(displayName)")))
        }
      }
      if rule.action == .switchWallpaper {
        HStack(spacing: 8) {
          DisplaysTargetPicker(
            selection: rule.wallpaperTarget, targets: controller.automationTargets, isRequired: false,
            popoverTitle: L("Switch to"), emptyTitle: L("Choose a wallpaper or saved playlist"),
            clearTitle: L("Leave as it is"),
            key: PanelActionCoordinator.key("appRuleWallpaper", id: rule.id.uuidString),
            commit: { try await controller.updateAppRule(rule.id, wallpaperTarget: $0) },
            width: 190, alignment: .leading
          )
          .disabled(controller.isStoreBusy)
          .accessibilityLabel(Text(verbatim: L("Wallpaper for \(displayName)")))
          SettingsMenuControl(
            key: "rule-\(rule.id)-display", saved: rule.displayID ?? "",
            options: displayOptions
          ) { selected in
            try await controller.updateAppRule(rule.id, displayID: selected.isEmpty ? nil : selected)
          }
          .accessibilityLabel(Text(verbatim: L("Display for \(displayName)")))
          Spacer(minLength: 0)
        }
        .padding(.leading, 30)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(minHeight: 40)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("playback.app-rule.\(rule.id.uuidString)")
  }

  private var displayOptions: [SettingsMenuOption<String>] {
    var options = [SettingsMenuOption(value: "", title: L("All displays"))]
    let standalone = controller.displayRows.filter { $0.enabled && !$0.isMirror }
    options.append(contentsOf: standalone.map { SettingsMenuOption(value: $0.id, title: $0.title) })
    if let saved = rule.displayID, !saved.isEmpty, !standalone.contains(where: { $0.id == saved }) {
      options.append(SettingsMenuOption(value: saved, title: L("Unavailable display")))
    }
    return options
  }
}

/// The icon of an app by its bundle identifier, found when the row appears (`AppIconCache`), or a
/// plain stand-in for an app that is not installed any more.
private struct PlaybackAppIcon: View {
  let bundleIdentifier: String

  @Environment(PanelController.self) private var controller

  var body: some View {
    let icons = controller.settings.appIcons
    Group {
      if let icon = icons.icon(for: bundleIdentifier) {
        Image(nsImage: icon).resizable().interpolation(.high)
      } else {
        Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary)
          .padding(2)
      }
    }
    .frame(width: 22, height: 22)
    .accessibilityHidden(true)
    .task(id: bundleIdentifier) { icons.load(bundleIdentifier) }
  }
}
