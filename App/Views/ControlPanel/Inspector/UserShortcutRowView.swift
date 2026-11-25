import SwiftUI

/// Menu control for a `usershortcut` wallpaper property: built-in media transport actions plus
/// user-approved macOS application and Apple Shortcut bindings.
struct UserShortcutActionMenu: View {
  let rowName: String
  let state: InspectorOptions.PropertyRow.UserShortcutState
  let isDisabled: Bool
  let onSelectBuiltIn: (String) -> Void
  let onOpenApplication: () -> Void
  let onRunShortcut: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Menu {
      Button {
        onSelectBuiltIn("")
      } label: {
        menuItemLabel("No action", selected: state.selection == .none)
      }
      Button {
        onSelectBuiltIn(SystemMediaCommand.togglePlayPause.rawValue)
      } label: {
        menuItemLabel("Play / Pause", selected: state.selection == .mediaPlayPause)
      }
      Button {
        onSelectBuiltIn(SystemMediaCommand.nextTrack.rawValue)
      } label: {
        menuItemLabel("Next Track", selected: state.selection == .mediaNext)
      }
      Button {
        onSelectBuiltIn(SystemMediaCommand.previousTrack.rawValue)
      } label: {
        menuItemLabel("Previous Track", selected: state.selection == .mediaPrevious)
      }
      Divider()
      Button("Open Application…", action: onOpenApplication)
      Button("Run Shortcut…", action: onRunShortcut)
    } label: {
      currentLabel
        .font(.panel(.callout))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(minWidth: 110, maxWidth: 170, alignment: .leading)
    }
    .menuStyle(.borderlessButton)
    .padding(.horizontal, 8)
    .frame(minWidth: 110, maxWidth: 170, minHeight: 22, alignment: .leading)
    .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
    }
    .accessibilityLabel(Text(verbatim: rowName))
    .disabled(isDisabled)
  }

  @ViewBuilder
  private var currentLabel: some View {
    switch state.selection {
    case .none:
      Text("No action")
    case .mediaPlayPause:
      Text("Play / Pause")
    case .mediaNext:
      Text("Next Track")
    case .mediaPrevious:
      Text("Previous Track")
    case .application(_, let displayName):
      Text(verbatim: displayName)
    case .shortcut(let name):
      Text(verbatim: name)
    }
  }

  @ViewBuilder
  private func menuItemLabel(_ title: LocalizedStringKey, selected: Bool) -> some View {
    if selected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }
}

/// Inspector row editor for a `usershortcut` wallpaper property.
///
/// Offers the four built-in media transport choices alongside `Open Application…` (via an app
/// picker extracting `CFBundleIdentifier` + display name) and `Run Shortcut…` (inline name entry
/// with explicit Save confirmation), plus Change / Edit and Clear controls. Every app name,
/// bundle identifier, and Shortcut name is rendered with `Text(verbatim:)`.
struct UserShortcutRowView<Header: View>: View {
  let options: InspectorOptions
  let row: InspectorOptions.PropertyRow
  let state: InspectorOptions.PropertyRow.UserShortcutState
  let isDisabled: Bool
  @ViewBuilder let header: (UserShortcutActionMenu) -> Header

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.inspectorEditedRow) private var editedRow

  @State private var isEditingShortcut = false
  @State private var shortcutDraft = ""
  @State private var shortcutError: String?
  @FocusState private var shortcutFieldFocused: Bool

  private var id: String { options.wallpaperID }
  private var propertyKey: String { InspectorAction.property(id, row.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header(actionMenu)
      if isEditingShortcut {
        shortcutEditor
      } else {
        customBindingSummary
      }
    }
    .onChange(of: id) { _, _ in
      isEditingShortcut = false
      shortcutDraft = ""
      shortcutError = nil
    }
    .onChange(of: row.id) { _, _ in
      isEditingShortcut = false
      shortcutDraft = ""
      shortcutError = nil
    }
  }

  private var actionMenu: UserShortcutActionMenu {
    UserShortcutActionMenu(
      rowName: row.name,
      state: state,
      isDisabled: isDisabled,
      onSelectBuiltIn: { value in
        isEditingShortcut = false
        shortcutError = nil
        editedRow?.note(propertyKey)
        controller.launch(propertyKey, policy: .latestWins) {
          try await controller.setUserShortcutAction(id, property: row.id, builtInValue: value)
        }
      },
      onOpenApplication: {
        isEditingShortcut = false
        shortcutError = nil
        editedRow?.note(propertyKey)
        controller.launch(propertyKey) {
          try await controller.chooseShortcutApplication(id, property: row.id)
        }
      },
      onRunShortcut: {
        if case .shortcut(let existing) = state.selection {
          shortcutDraft = existing
        } else {
          shortcutDraft = ""
        }
        shortcutError = nil
        isEditingShortcut = true
        shortcutFieldFocused = true
      })
  }

  @ViewBuilder
  private var customBindingSummary: some View {
    switch state.selection {
    case .application(let bundleID, let displayName):
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "macwindow")
            .font(.panel(.caption))
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: displayName)
              .font(.panel(.callout))
              .foregroundStyle(theme.surface.text.color)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(verbatim: bundleID)
              .font(.panel(.caption))
              .foregroundStyle(theme.surface.muted.color)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
        }
        HStack(spacing: 8) {
          Button("Change…") {
            editedRow?.note(propertyKey)
            controller.launch(propertyKey) {
              try await controller.chooseShortcutApplication(id, property: row.id)
            }
          }
          .buttonStyle(.panelSecondary(size: .compact))
          Button("Clear") {
            clearBinding()
          }
          .buttonStyle(.panelSecondary(size: .compact))
        }
        .disabled(isDisabled)
      }
    case .shortcut(let name):
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "bolt.horizontal.circle")
            .font(.panel(.caption))
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityHidden(true)
          Text(verbatim: name)
            .font(.panel(.callout))
            .foregroundStyle(theme.surface.text.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
        }
        HStack(spacing: 8) {
          Button("Edit…") {
            shortcutDraft = name
            shortcutError = nil
            isEditingShortcut = true
            shortcutFieldFocused = true
          }
          .buttonStyle(.panelSecondary(size: .compact))
          Button("Clear") {
            clearBinding()
          }
          .buttonStyle(.panelSecondary(size: .compact))
        }
        .disabled(isDisabled)
      }
    case .none, .mediaPlayPause, .mediaNext, .mediaPrevious:
      EmptyView()
    }
  }

  private var shortcutEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(
        "Shortcut name",
        text: $shortcutDraft,
        prompt: Text("Shortcut name")
      )
      .textFieldStyle(.roundedBorder)
      .controlSize(.small)
      .focused($shortcutFieldFocused)
      .onSubmit(saveShortcut)
      .onExitCommand { cancelShortcutEdit() }
      .accessibilityLabel(L("Shortcut name"))
      .disabled(isDisabled)
      InspectorNote("Runs through macOS Shortcuts only after you save this binding.")
      if let shortcutError {
        Text(verbatim: shortcutError)
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.danger.color)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 8) {
        Button("Save", action: saveShortcut)
          .buttonStyle(.panelPrimary(size: .compact))
          .disabled(isDisabled || shortcutDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", action: cancelShortcutEdit)
          .buttonStyle(.panelSecondary(size: .compact))
      }
    }
    .padding(8)
    .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
    }
  }

  private func saveShortcut() {
    let trimmed = shortcutDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard UserShortcutTarget.isValidShortcutName(trimmed) else {
      shortcutError = L("Enter a valid Shortcut name. Names cannot be empty or start with a hyphen.")
      return
    }
    shortcutError = nil
    editedRow?.note(propertyKey)
    let targetName = trimmed
    controller.launch(propertyKey) {
      try await controller.bindUserShortcut(id, property: row.id, shortcutName: targetName)
      isEditingShortcut = false
    }
  }

  private func cancelShortcutEdit() {
    isEditingShortcut = false
    shortcutError = nil
  }

  private func clearBinding() {
    isEditingShortcut = false
    shortcutError = nil
    editedRow?.note(propertyKey)
    controller.launch(propertyKey, policy: .latestWins) {
      try await controller.setUserShortcutAction(id, property: row.id, builtInValue: "")
    }
  }
}
