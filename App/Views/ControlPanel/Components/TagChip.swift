import AppKit
import SwiftUI

/// A tag as a small capsule. Without `onSelect` it only draws the tag (for callers such as a
/// filter that wrap it in their own `Button`); with `onSelect` it acts as an interactive filter or
/// search chip, passing `exclude: true` on Option-click when `supportsExclude` is true.
///
/// Tags come from wallpaper manifests or remote listings, so the text is never read as a
/// localization key.
struct TagChip: View {
  enum Selection {
    case plain
    /// A tag every shown wallpaper must carry.
    case required
    /// A tag no shown wallpaper may carry.
    case excluded
  }

  let text: String
  var selection: Selection = .plain
  /// Whether Option-click (and the context menu's Hide action) excludes this tag. False for pages
  /// whose tags trigger a search instead of an include/exclude filter (pixiv).
  var supportsExclude = true
  /// Optional tooltip override when `onSelect` is set. Nil uses the standard filter hint when
  /// `supportsExclude` is true.
  var helpText: String? = nil
  /// Optional tap handler. `exclude` is true when the user Option-clicked (or chose Hide this tag)
  /// and `supportsExclude` is true. Default `nil` keeps the chip non-interactive.
  var onSelect: ((_ exclude: Bool) -> Void)? = nil

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    if let onSelect {
      interactiveChip(onSelect: onSelect)
    } else {
      chipLabel(showsCheckmark: false)
    }
  }

  @ViewBuilder
  private func interactiveChip(onSelect: @escaping (_ exclude: Bool) -> Void) -> some View {
    let base = Button {
      onSelect(supportsExclude && NSEvent.modifierFlags.contains(.option))
    } label: {
      chipLabel(showsCheckmark: selection == .required)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(resolvedHelp)
    .accessibilityLabel(Text(verbatim: text))
    .accessibilityAddTraits(selection == .required ? .isSelected : [])
    .accessibilityValue(selection == .excluded ? Text("Hidden") : Text(verbatim: ""))

    if supportsExclude {
      base
        .contextMenu {
          Button("Show only this tag") {
            if selection != .required { onSelect(false) }
          }
          .disabled(selection == .required)
          Button("Hide this tag") {
            if selection != .excluded { onSelect(true) }
          }
          .disabled(selection == .excluded)
          Button("Don't filter by this tag") {
            if selection == .required {
              onSelect(false)
            } else if selection == .excluded {
              onSelect(true)
            }
          }
          .disabled(selection == .plain)
        }
        .accessibilityAction(named: Text("Hide this tag")) {
          if selection != .excluded { onSelect(true) }
        }
    } else {
      base
    }
  }

  private func chipLabel(showsCheckmark: Bool) -> some View {
    HStack(spacing: 3) {
      if showsCheckmark {
        Image(systemName: "checkmark")
          .font(.panel(.mark))
          .accessibilityHidden(true)
      }
      Text(verbatim: text)
        .font(.panel(.controlSmall))
        .strikethrough(selection == .excluded)
        .lineLimit(1)
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(background, in: Capsule())
  }

  private var resolvedHelp: String {
    if let helpText { return helpText }
    return supportsExclude
      ? L("Click to show only wallpapers with this tag. Option-click to hide them.")
      : ""
  }

  private var foreground: Color {
    switch selection {
    case .plain: theme.surface.tagInk.color
    case .required: theme.accent.onPrimary.color
    case .excluded: theme.surface.danger.color
    }
  }

  private var background: Color {
    let hovered = onSelect != nil && isHovering
    return switch selection {
    case .plain: hovered ? theme.surface.selected.color : theme.surface.badge.color
    case .required: theme.accent.primary.color.opacity(hovered ? 0.85 : 1)
    case .excluded: theme.surface.danger.color.opacity(hovered ? 0.2 : 0.14)
    }
  }
}

/// Lays its children out left to right and wraps them onto new lines at the width it is given.
struct TagFlow: Layout {
  var spacing: CGFloat = 6
  /// Sets each child on its row's centre line instead of its top, for a row of controls of
  /// different heights (the accent swatches, the colour well and the hex beside them).
  var centersRows = false

  /// Where each size lands in rows no wider than `width`, and the size the rows take together. A
  /// child wider than `width` sits alone on its row. A nil width means a single row.
  static func arrange(
    _ sizes: [CGSize], width: CGFloat?, spacing: CGFloat, centersRows: Bool = false
  ) -> (origins: [CGPoint], size: CGSize) {
    var origins: [CGPoint] = []
    /// The row each child is on, and each row's height.
    var rowOf: [Int] = []
    var rowHeights: [CGFloat] = [0]
    var x: CGFloat = 0
    var y: CGFloat = 0
    var widest: CGFloat = 0
    for size in sizes {
      if let width, x > 0, x + size.width > width {
        y += rowHeights[rowHeights.count - 1] + spacing
        x = 0
        rowHeights.append(0)
      }
      origins.append(CGPoint(x: x, y: y))
      rowOf.append(rowHeights.count - 1)
      x += size.width + spacing
      widest = max(widest, x - spacing)
      rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
    }
    if centersRows {
      for index in origins.indices {
        origins[index].y += (rowHeights[rowOf[index]] - sizes[index].height) / 2
      }
    }
    let height = sizes.isEmpty ? 0 : y + rowHeights[rowHeights.count - 1]
    return (origins, CGSize(width: widest, height: height))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    return Self.arrange(sizes, width: proposal.width, spacing: spacing).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let arranged = Self.arrange(
      sizes, width: bounds.width, spacing: spacing, centersRows: centersRows)
    for (subview, origin) in zip(subviews, arranged.origins) {
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }
}
