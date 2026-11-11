import SwiftUI

/// Rows one under another with a hairline between each pair. The lines are drawn between the rows
/// that are actually there, so a row that is hidden leaves no stray line behind.
struct DividedRows<Content: View>: View {
  /// How far the hairlines are inset from the leading edge, matching the rows' own padding.
  var separatorInset: CGFloat = 12
  @ViewBuilder var content: Content

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(rows) { row in
          row
          if row.id != rows.last?.id {
            Rectangle()
              .fill(theme.surface.divider.color)
              .frame(height: 0.5)
              .padding(.leading, separatorInset)
          }
        }
      }
    }
  }
}

/// A label as wide as the widest label of its form, so the controls beside the labels line up in
/// every language without a fixed width that a long translation would wrap in. The form's other
/// labels are laid out hidden underneath and never read, so a row VoiceOver combines says only its
/// own label. Font and colour come from the environment: set them on the `ColumnLabel`, so the
/// hidden labels measure in the same font.
struct ColumnLabel: View {
  let text: Text
  /// Every label of the form, this one included or not.
  let column: [Text]

  var body: some View {
    ZStack(alignment: .leading) {
      ForEach(column.indices, id: \.self) { index in
        column[index].hidden().accessibilityHidden(true)
      }
      text
    }
  }
}

/// The rounded card of an inset grouped list: one surface, rows separated by hairlines.
/// Inspector cards and Settings groups share it.
struct PanelCard<Content: View>: View {
  var separatorInset: CGFloat = 12
  @ViewBuilder var content: Content

  @Environment(\.panelTheme) private var theme

  var body: some View {
    DividedRows(separatorInset: separatorInset) { content }
      .background(
        theme.surface.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
  }
}
