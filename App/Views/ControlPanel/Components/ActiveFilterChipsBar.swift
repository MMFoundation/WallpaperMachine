import SwiftUI

/// One removable active filter shown in `ActiveFilterChipsBar` while the Filters sidebar is
/// collapsed.
struct ActiveFilterChip: Identifiable {
  enum Tone: Equatable, Sendable {
    /// A positive filter (required tag, Hide installed, orientation, minimum size, AI filter, or
    /// an option enabled against its default).
    case included
    /// A negative filter (an excluded tag or unticked box).
    case excluded
  }

  let id: String
  /// Display label (already localized when it comes from app wording, or verbatim for user/manifest
  /// tags). Always drawn with `Text(verbatim:)`.
  let title: String
  var tone: Tone = .included
  let onRemove: @MainActor () -> Void
}

/// A single-line, horizontally scrollable strip of removable active filter chips with a pinned
/// **Clear** action, shown above a page's grid while the Filters sidebar is collapsed and narrowing
/// filters apply.
///
/// Laid over a zero-min-width `Color.clear` filler of fixed height (matching `PixivBar`), so the
/// strip never feeds the split view a minimum width in narrow columns beside an open inspector.
struct ActiveFilterChipsBar: View {
  static let height: CGFloat = 32

  let chips: [ActiveFilterChip]
  var horizontalPadding: CGFloat = 20
  var identifierPrefix = "active-filters"
  let onClear: @MainActor () -> Void

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity)
      .frame(height: Self.height)
      .overlay {
        HStack(spacing: 8) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(chips) { chip in
                ActiveFilterChipButton(chip: chip)
              }
            }
            .padding(.vertical, 2)
          }
          .frame(minWidth: 0, maxWidth: .infinity)

          Button("Clear") { onClear() }
            .buttonStyle(.panelLink)
            .font(.panel(.callout))
            .fixedSize()
            .accessibilityIdentifier("\(identifierPrefix)-clear")
        }
        .padding(.horizontal, horizontalPadding)
      }
      .clipped()
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("Active filters"))
      .accessibilityIdentifier(identifierPrefix)
  }
}

/// One removable chip in `ActiveFilterChipsBar`: its label and a trailing dismiss cross.
private struct ActiveFilterChipButton: View {
  let chip: ActiveFilterChip

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    Button {
      chip.onRemove()
    } label: {
      HStack(spacing: 4) {
        Text(verbatim: chip.title)
          .font(.panel(.controlSmall))
          .strikethrough(chip.tone == .excluded)
          .lineLimit(1)
        Image(systemName: "xmark")
          .font(.panel(.mark))
          .accessibilityHidden(true)
      }
      .foregroundStyle(foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(L("Remove filter"))
    .accessibilityLabel(Text(verbatim: L("Remove \(chip.title) filter")))
    .accessibilityValue(chip.tone == .excluded ? Text("Hidden") : Text(verbatim: ""))
    .accessibilityIdentifier("active-filter-chip-\(chip.id)")
  }

  private var foreground: Color {
    switch chip.tone {
    case .included: theme.accent.accent.color
    case .excluded: theme.surface.danger.color
    }
  }

  private var background: Color {
    switch chip.tone {
    case .included: theme.accent.accent.color.opacity(isHovering ? 0.24 : 0.16)
    case .excluded: theme.surface.danger.color.opacity(isHovering ? 0.22 : 0.14)
    }
  }
}
