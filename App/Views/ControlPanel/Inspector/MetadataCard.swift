import SwiftUI

/// User metadata for the selected wallpaper: 1–5 star rating, custom tags, optional short note,
/// and an exclusion switch for automatic playlists and Random Wallpaper. Collapsed by default
/// until the wallpaper has metadata, and placed alongside Collections so it never pushes
/// Wallpaper properties down.
struct MetadataCard: View {
  let wallpaperID: String
  private let initialOpenOverride: Bool?

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var newTag = ""
  @State private var noteDraft = ""
  @State private var loadedNote: String? = nil
  @FocusState private var noteFocused: Bool

  init(wallpaperID: String, isOpen: Bool? = nil) {
    self.wallpaperID = wallpaperID
    initialOpenOverride = isOpen
  }

  private var ratingKey: String {
    PanelActionCoordinator.key("metadataRating", id: wallpaperID)
  }

  private var tagKey: String {
    PanelActionCoordinator.key("metadataTag", id: wallpaperID)
  }

  private var noteKey: String {
    PanelActionCoordinator.key("metadataNote", id: wallpaperID)
  }

  private var excludeKey: String {
    PanelActionCoordinator.key("metadataExclude", id: wallpaperID)
  }

  var body: some View {
    let metadata = controller.wallpaperMetadata(for: wallpaperID)
    let isOpen = initialOpenOverride ?? InspectorPolicy.metadataOpenByDefault(metadata)
    InspectorSection("Rating & tags", isOpen: isOpen) {
      ratingRow(metadata)
      customTagsRow(metadata)
      noteRow(metadata)
      excludeRow(metadata)
    }
    .onAppear { syncNoteDraft(from: metadata.note) }
    .onChange(of: metadata.note) { _, updated in
      if !noteFocused { syncNoteDraft(from: updated) }
    }
  }

  private func ratingRow(_ metadata: WallpaperMetadata) -> some View {
    let busy = controller.isBusy(ratingKey)
    return InspectorRow("Rating") {
      HStack(spacing: 2) {
        ForEach(1...5, id: \.self) { star in
          let filled = (metadata.rating ?? 0) >= star
          let isCurrent = metadata.rating == star
          Button {
            let next: Int? = isCurrent ? nil : star
            controller.launch(ratingKey, policy: .latestWins) { [controller, wallpaperID] in
              try await controller.setWallpaperRating(next, for: wallpaperID)
            }
          } label: {
            Image(systemName: filled ? "star.fill" : "star")
              .font(.panel(.callout))
              .foregroundStyle(filled ? theme.surface.warning.color : theme.surface.faint.color)
              .frame(width: 20, height: 20)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(busy)
          .help(isCurrent ? L("Clear rating") : starLabel(star))
          .accessibilityLabel(Text(verbatim: starLabel(star)))
          .accessibilityAddTraits(isCurrent ? .isSelected : [])
          .accessibilityIdentifier("inspector.metadata.star.\(star)")
        }
      }
      .accessibilityElement(children: .contain)
    }
  }

  private func customTagsRow(_ metadata: WallpaperMetadata) -> some View {
    let busy = controller.isBusy(tagKey)
    let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    return InspectorCardRow {
      VStack(alignment: .leading, spacing: 8) {
        Text("Custom tags")
          .font(.panel(.body))
          .foregroundStyle(theme.surface.text.color)
        if !metadata.customTags.isEmpty {
          TagFlow(spacing: 6) {
            ForEach(metadata.customTags, id: \.self) { tag in
              HStack(spacing: 4) {
                Text(verbatim: tag)
                  .font(.panel(.controlSmall))
                  .foregroundStyle(theme.surface.tagInk.color)
                  .lineLimit(1)
                Button {
                  controller.launch(tagKey) { [controller, wallpaperID] in
                    try await controller.removeWallpaperTag(tag, from: wallpaperID)
                  }
                } label: {
                  Image(systemName: "xmark")
                    .font(.panel(.mark))
                    .foregroundStyle(theme.surface.muted.color)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(Text(verbatim: L("Remove tag \(tag)")))
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(theme.surface.badge.color, in: Capsule())
            }
          }
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 6) {
          TextField("Add tag…", text: $newTag, prompt: Text("Add tag…"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(minWidth: 0, maxWidth: .infinity)
            .onSubmit(addTag)
            .accessibilityLabel(L("Add tag…"))
            .accessibilityIdentifier("inspector.metadata.tagField")
          Button("Add") { addTag() }
            .buttonStyle(.panelSecondary(size: .compact))
            .disabled(trimmed.isEmpty || busy)
            .accessibilityIdentifier("inspector.metadata.addTag")
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
  }

  private func noteRow(_ metadata: WallpaperMetadata) -> some View {
    InspectorCardRow {
      VStack(alignment: .leading, spacing: 6) {
        Text("Note")
          .font(.panel(.body))
          .foregroundStyle(theme.surface.text.color)
        TextField("Add a note…", text: $noteDraft, prompt: Text("Add a note…"), axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .lineLimit(1...3)
          .frame(minWidth: 0, maxWidth: .infinity)
          .focused($noteFocused)
          .onSubmit(commitNote)
          .onChange(of: noteFocused) { _, focused in
            if !focused { commitNote() }
          }
          .accessibilityLabel(L("Note"))
          .accessibilityIdentifier("inspector.metadata.noteField")
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
  }

  private func excludeRow(_ metadata: WallpaperMetadata) -> some View {
    let busy = controller.isBusy(excludeKey)
    return VStack(alignment: .leading, spacing: 0) {
      InspectorRow("Exclude from playlists & random") {
        Toggle(
          "",
          isOn: Binding(
            get: { metadata.excludedFromRotation },
            set: { excluded in
              controller.launch(excludeKey, policy: .latestWins) { [controller, wallpaperID] in
                try await controller.setWallpaperExcludedFromRotation(excluded, for: wallpaperID)
              }
            })
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(busy)
        .accessibilityLabel(L("Exclude from playlists & random"))
        .accessibilityIdentifier("inspector.metadata.excludeToggle")
      }
      if metadata.excludedFromRotation {
        InspectorCardRow {
          InspectorNote(
            "Skipped by All wallpapers, Favorites, Smart playlists and Random Wallpaper. Explicit display lists and collections still play it."
          )
        }
      }
    }
  }

  private func starLabel(_ count: Int) -> String {
    count == 1 ? L("1 star") : L("\(count) stars")
  }

  private func addTag() {
    let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let id = wallpaperID
    let outcome = Outcome<Void>()
    let task = controller.launch(tagKey) { [controller] in
      outcome.ran = true
      do { try await controller.addWallpaperTag(value, to: id) } catch {
        outcome.failed = true
        throw error
      }
    }
    Task { @MainActor in
      await task.value
      if outcome.ran, !outcome.failed { newTag = "" }
    }
  }

  private func commitNote() {
    let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized: String? = trimmed.isEmpty ? nil : trimmed
    guard normalized != loadedNote else { return }
    let id = wallpaperID
    controller.launch(noteKey, policy: .latestWins) { [controller] in
      try await controller.setWallpaperNote(normalized, for: id)
    }
    loadedNote = normalized
  }

  private func syncNoteDraft(from stored: String?) {
    loadedNote = stored
    noteDraft = stored ?? ""
  }
}
