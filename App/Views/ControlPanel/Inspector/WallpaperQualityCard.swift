import SwiftUI

/// Per-wallpaper quality overrides (Phase 1): internal render scale (for scenes and web pages)
/// and scene quality (MSAA, shadows, volumetrics, reflections and post-processing for scenes).
///
/// Every choice takes effect immediately without waiting behind Apply changes. Battery and thermal
/// throttling still apply via `.min(...)` on top of any per-wallpaper override.
struct WallpaperQualityCard: View {
  let options: InspectorOptions

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    if options.offersQualityOverrides {
      let id = options.wallpaperID
      let scaleKey = InspectorAction.wallpaperSetting(id, "renderScale")
      let qualityKey = InspectorAction.wallpaperSetting(id, "sceneQuality")
      let resetKey = InspectorAction.wallpaperSetting(id, "resetQuality")
      InspectorSection(
        "Quality", isOpen: options.hasQualityOverride,
        accessory: {
          if options.hasQualityOverride {
            Text("Custom")
              .font(.panel(.caption))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
      ) {
        if options.offersRenderScaleOverride {
          renderScaleRow(id: id, key: scaleKey)
        }
        if options.offersSceneQualityOverride {
          sceneQualityRows(id: id, key: qualityKey)
        }
        if options.hasQualityOverride {
          InspectorCardRow {
            Button {
              controller.launch(resetKey, policy: .latestWins) {
                try await controller.resetWallpaperQuality(for: id)
              }
            } label: {
              Label("Reset to global settings", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.panelCardLink)
            .disabled(controller.isInspectorControlDisabled(options, key: resetKey))
            .accessibilityIdentifier("inspector.quality.reset")
          }
        }
        InspectorCardRow {
          InspectorNote(
            "Battery and heat limits still apply on top of per-wallpaper quality settings.")
        }
      }
    }
  }

  private func renderScaleRow(id: String, key: String) -> some View {
    let choices = RenderScaleChoices.options(saved: options.renderScaleOverride ?? 1.0)
    return InspectorRow("Internal render scale") {
      Picker(
        "",
        selection: Binding<Float?>(
          get: { options.renderScaleOverride },
          set: { chosen in
            controller.launch(key, policy: .latestWins) {
              try await controller.setWallpaperRenderScale(chosen, for: id)
            }
          })
      ) {
        Text("Use global setting").tag(Optional<Float>.none)
        ForEach(choices) { choice in
          Text(verbatim: choice.title).tag(Optional<Float>.some(choice.scale))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(minWidth: 110, maxWidth: 170)
      .accessibilityLabel(L("Internal render scale"))
      .accessibilityIdentifier("inspector.quality.renderScale")
    }
    .disabled(controller.isInspectorControlDisabled(options, key: key))
  }

  @ViewBuilder
  private func sceneQualityRows(id: String, key: String) -> some View {
    let isOverridden = options.sceneQualityOverride != nil
    InspectorToggleRow(
      title: "Override scene quality", isOn: isOverridden,
      isDisabled: controller.isInspectorControlDisabled(options, key: key)
    ) { enabled in
      let next: BridgeSceneQuality? = enabled ? options.globalSceneQuality : nil
      controller.launch(key, policy: .latestWins) {
        try await controller.setWallpaperSceneQuality(next, for: id)
      }
    }
    .accessibilityIdentifier("inspector.quality.sceneOverride")
    if let quality = options.sceneQualityOverride {
      let disabled = controller.isInspectorControlDisabled(options, key: key)
      InspectorRow("Antialiasing (MSAA)") {
        Picker(
          "",
          selection: Binding(
            get: { quality.msaa },
            set: { value in
              var updated = quality
              updated.msaa = value
              updateSceneQuality(updated, id: id, key: key)
            })
        ) {
          ForEach(BridgeMsaa.allCases, id: \.self) { choice in
            Text(verbatim: choice.title).tag(choice)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 110, maxWidth: 170)
        .accessibilityLabel(L("Antialiasing (MSAA)"))
      }
      .disabled(disabled)

      InspectorRow("Shadows") {
        Picker(
          "",
          selection: Binding(
            get: { quality.shadows },
            set: { value in
              var updated = quality
              updated.shadows = value
              updateSceneQuality(updated, id: id, key: key)
            })
        ) {
          ForEach(BridgeQualityLevel.allCases, id: \.self) { choice in
            Text(verbatim: choice.title).tag(choice)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 110, maxWidth: 170)
        .accessibilityLabel(L("Shadows"))
      }
      .disabled(disabled)

      InspectorRow("Volumetrics") {
        Picker(
          "",
          selection: Binding(
            get: { quality.volumetrics },
            set: { value in
              var updated = quality
              updated.volumetrics = value
              updateSceneQuality(updated, id: id, key: key)
            })
        ) {
          ForEach(BridgeQualityLevel.allCases, id: \.self) { choice in
            Text(verbatim: choice.title).tag(choice)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 110, maxWidth: 170)
        .accessibilityLabel(L("Volumetrics"))
      }
      .disabled(disabled)

      InspectorToggleRow(
        title: "Reflections", isOn: quality.reflections, isDisabled: disabled
      ) { value in
        var updated = quality
        updated.reflections = value
        updateSceneQuality(updated, id: id, key: key)
      }

      InspectorRow("Post-processing") {
        Picker(
          "",
          selection: Binding(
            get: { quality.postProcessing },
            set: { value in
              var updated = quality
              updated.postProcessing = value
              updateSceneQuality(updated, id: id, key: key)
            })
        ) {
          ForEach(BridgePostProcessing.allCases, id: \.self) { choice in
            Text(verbatim: choice.title).tag(choice)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 110, maxWidth: 170)
        .accessibilityLabel(L("Post-processing"))
      }
      .disabled(disabled)
    }
  }

  private func updateSceneQuality(_ quality: BridgeSceneQuality, id: String, key: String) {
    controller.launch(key, policy: .latestWins) {
      try await controller.setWallpaperSceneQuality(quality, for: id)
    }
  }
}
