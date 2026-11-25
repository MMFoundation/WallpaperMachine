import SwiftUI

/// Filter rows for a display's Smart Dynamic Playlist (`PlaylistSource.smart`).
/// Every change updates the display's `SmartPlaylistQuery` through `PanelController.editPlaylist`,
/// with live candidate counts evaluated strictly in memory.
struct DisplaysSmartPlaylistRows: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let forced: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var requiredTagInput = ""
  @State private var excludedTagInput = ""

  private var query: SmartPlaylistQuery { state.playlist.effectiveSmartQuery }

  var body: some View {
    let name = { (title: LocalizedStringResource) in
      L("\(controller.settings.text(title)) for \(display.title)")
    }

    // Wallpaper types
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartTypes, forced: forced, identity: display.id,
      labelsControl: false, stacked: true
    ) {
      TagFlow(spacing: 6) {
        ForEach(SmartWallpaperType.allCases, id: \.self) { type in
          let selected = query.types.contains(type)
          Button {
            updateQuery(detail: "smartTypes") { updated in
              if let index = updated.types.firstIndex(of: type) {
                updated.types.remove(at: index)
              } else {
                updated.types.append(type)
              }
            }
          } label: {
            Text(verbatim: SmartPlaylistFormatting.typeTitle(type))
              .font(.panel(.controlSmall))
              .foregroundStyle(selected ? theme.accent.onPrimary.color : theme.surface.tagInk.color)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(
                selected ? theme.accent.primary.color : theme.surface.badge.color,
                in: Capsule()
              )
          }
          .buttonStyle(.plain)
          .disabled(off)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    // Required tags
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartRequiredTags, forced: forced, identity: display.id,
      labelsControl: false, stacked: true
    ) {
      tagEditor(
        tags: query.requiredTags,
        input: $requiredTagInput,
        placeholder: L("Add tag…"),
        detail: "smartRequiredTags",
        excludedStyle: false
      ) { tag, updated in
        updated.requiredTags.append(tag)
      } onRemove: { tag, updated in
        updated.requiredTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
      }
    }

    // Excluded tags
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartExcludedTags, forced: forced, identity: display.id,
      labelsControl: false, stacked: true
    ) {
      tagEditor(
        tags: query.excludedTags,
        input: $excludedTagInput,
        placeholder: L("Exclude tag…"),
        detail: "smartExcludedTags",
        excludedStyle: true
      ) { tag, updated in
        updated.excludedTags.append(tag)
      } onRemove: { tag, updated in
        updated.excludedTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
      }
    }

    // Minimum star rating
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartRating, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistSmartRating.title)
    ) {
      let selection = Binding<Int>(
        get: { query.minimumRating ?? 0 },
        set: { value in
          let rating: Int? = value == 0 ? nil : value
          updateQuery(detail: "smartRating") { $0.minimumRating = rating }
        })
      DisplaysTitleMenu(
        selection: selection,
        title: SmartPlaylistFormatting.minimumRatingTitle(query.minimumRating),
        width: 160
      ) {
        Text("Any").tag(0)
        ForEach(1...5, id: \.self) { stars in
          Text(verbatim: SmartPlaylistFormatting.minimumRatingTitle(stars)).tag(stars)
        }
      }
      .disabled(off)
    }

    // Maximum energy level
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartEnergy, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistSmartEnergy.title)
    ) {
      let selection = Binding<String>(
        get: { query.maximumEnergy?.rawValue ?? "" },
        set: { raw in
          let level = raw.isEmpty ? nil : EnergyLevel(rawValue: raw)
          updateQuery(detail: "smartEnergy") { $0.maximumEnergy = level }
        })
      DisplaysTitleMenu(
        selection: selection,
        title: SmartPlaylistFormatting.maximumEnergyTitle(query.maximumEnergy),
        width: 160
      ) {
        Text("Any").tag("")
        Text("Low only").tag(EnergyLevel.low.rawValue)
        Text("Low & Medium").tag(EnergyLevel.medium.rawValue)
      }
      .disabled(off)
    }

    // Favorites only
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartFavorites, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistSmartFavorites.title)
    ) {
      Toggle(
        noLabel,
        isOn: Binding(
          get: { query.favoritesOnly },
          set: { value in updateQuery(detail: "smartFavorites") { $0.favoritesOnly = value } })
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(off)
    }

    // Exclude mature
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSmartExcludeMature, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistSmartExcludeMature.title)
    ) {
      Toggle(
        noLabel,
        isOn: Binding(
          get: { query.excludeMature },
          set: { value in updateQuery(detail: "smartExcludeMature") { $0.excludeMature = value } })
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(off)
    }
  }

  private func tagEditor(
    tags: [String],
    input: Binding<String>,
    placeholder: String,
    detail: String,
    excludedStyle: Bool,
    onAdd: @escaping (String, inout SmartPlaylistQuery) -> Void,
    onRemove: @escaping (String, inout SmartPlaylistQuery) -> Void
  ) -> some View {
    let trimmed = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let submit = {
      let value = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return }
      input.wrappedValue = ""
      updateQuery(detail: detail) { updated in onAdd(value, &updated) }
    }
    return VStack(alignment: .leading, spacing: 8) {
      if !tags.isEmpty {
        TagFlow(spacing: 6) {
          ForEach(tags, id: \.self) { tag in
            HStack(spacing: 4) {
              Text(verbatim: tag)
                .font(.panel(.controlSmall))
                .foregroundStyle(excludedStyle ? theme.surface.danger.color : theme.surface.tagInk.color)
                .strikethrough(excludedStyle)
                .lineLimit(1)
              Button {
                updateQuery(detail: detail) { updated in onRemove(tag, &updated) }
              } label: {
                Image(systemName: "xmark")
                  .font(.panel(.mark))
                  .foregroundStyle(theme.surface.muted.color)
              }
              .buttonStyle(.plain)
              .disabled(off)
              .accessibilityLabel(Text(verbatim: L("Remove tag \(tag)")))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              excludedStyle ? theme.surface.danger.color.opacity(0.14) : theme.surface.badge.color,
              in: Capsule()
            )
          }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 6) {
        TextField(placeholder, text: input, prompt: Text(verbatim: placeholder))
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .frame(minWidth: 0, maxWidth: .infinity)
          .disabled(off)
          .onSubmit(submit)
          .accessibilityLabel(Text(verbatim: placeholder))
        Button("Add", action: submit)
          .buttonStyle(.panelSecondary(size: .compact))
          .disabled(off || trimmed.isEmpty)
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
  }

  private func updateQuery(detail: String, _ change: @escaping (inout SmartPlaylistQuery) -> Void) {
    var updated = query
    change(&updated)
    let normalized = SmartPlaylistQuery(
      requiredTags: updated.requiredTags,
      excludedTags: updated.excludedTags,
      types: updated.types,
      minimumRating: updated.minimumRating,
      maximumEnergy: updated.maximumEnergy,
      favoritesOnly: updated.favoritesOnly,
      excludeMature: updated.excludeMature)
    controller.launch(
      PanelActionCoordinator.key("playlistSetting", id: display.id, detail: detail),
      policy: .latestWins
    ) { [controller, displayID = display.id] in
      try await controller.editPlaylist(.smartQuery(normalized), display: displayID)
    }
  }
}
