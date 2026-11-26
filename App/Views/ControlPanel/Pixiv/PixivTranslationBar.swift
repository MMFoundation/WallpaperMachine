import SwiftUI

/// Shows when a non-Japanese pixiv tag search was translated into Japanese on this Mac, with a
/// one-click **Search as typed** override and a toggle to enable or disable Japanese-tag
/// translation. All user-typed and translated queries are shown via `Text(verbatim:)`.
struct PixivTranslationBar: View {
  let translation: PixivSearchTranslation?

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.pixivBrowser
    HStack(spacing: 8) {
      Image(systemName: "translate")
        .font(.panel(.callout))
        .foregroundStyle(theme.surface.muted.color)
        .accessibilityHidden(true)

      if let translation {
        let searched = L("Searching Pixiv in Japanese for “\(translation.japanese)”")
        Text(verbatim: searched)
          .font(.panel(.callout))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(-1)
          .help(searched)
        Button("Search as typed") {
          model.searchAsTyped(translation)
        }
        .buttonStyle(.panelLink)
        .font(.panel(.callout))
        .lineLimit(1)
        .fixedSize()
        .help(L("Search “\(translation.original)” instead"))
        .accessibilityIdentifier("pixiv-search-as-typed")
      } else {
        Text("Japanese tag translation is off")
          .font(.panel(.callout))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(-1)
      }

      Spacer(minLength: 4)

      Toggle(
        isOn: Binding(
          get: { model.translatesSearches },
          set: { model.setTranslatesSearches($0) }
        )
      ) {
        Text("Japanese tags")
          .font(.panel(.caption))
          .foregroundStyle(theme.surface.muted.color)
      }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .fixedSize()
      .help(L("Translate non-Japanese searches into Japanese tags for pixiv"))
      .accessibilityIdentifier("pixiv-translate-toggle")
    }
    .padding(.horizontal, 20)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pixiv-search-translation")
  }
}
