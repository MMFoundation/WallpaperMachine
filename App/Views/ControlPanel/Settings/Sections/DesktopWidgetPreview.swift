import AppKit
import SwiftUI

/// Settings › Desktop Widgets' Arrange row: a small picture of a display, with the frame its
/// wallpaper draws (its first at once, then one past any intro or fade-in once it has played a
/// moment) and the widgets shown on it drawn as the desktop draws them, scaled down and stacked in
/// the layers' order. Without a frame the picture shows the wallpaper's still, and a note under it
/// says why when one is to come.
///
/// Dragging a widget moves it; the position is saved when it is let go. While it moves, the
/// display's centre lines show faintly, and the widget snaps to them, to the thirds, to a margin
/// from the edges and to the other widgets' edges and centres, drawing a guide along each line it
/// lies on (`DesktopWidgetSnapping`); holding Command places it freely. The selected widget is
/// outlined above every layer, so it can be found even under another one, and a hidden one is
/// drawn faded. The words are those of when the page was drawn: the preview runs no clock of its
/// own and the frame does not move. The position sliders and the Center buttons are the keyboard's
/// and VoiceOver's way to the same thing, so the picture itself is hidden from VoiceOver.
struct DesktopWidgetPreview: View {
  let screen: DesktopWidgetController.Screen

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.widgetsSettings
    let display = screen.frame.size
    let aspect = display.height > 0 ? display.width / display.height : 16 / 10
    VStack(spacing: 6) {
      GeometryReader { proxy in
        let size = proxy.size
        let scale = display.width > 0 ? size.width / display.width : 1
        let widgets = model.widgets(on: screen)
        ZStack(alignment: .topLeading) {
          backdrop(
            frame: model.wallpaperFrame(on: screen.displayID), still: model.wallpaperStill(on: screen.displayID),
            size: size)
          ForEach(widgets) { widget in
            item(model.shown(widget), saved: widget, in: size, scale: scale)
          }
          guides(in: size)
          if let selected = widgets.first(where: { $0.id == model.selectedID }) {
            outline(model.frame(of: model.shown(selected), in: size, scale: scale))
          }
        }
        .coordinateSpace(.named(Self.space))
      }
      .aspectRatio(aspect, contentMode: .fit)
      .frame(maxWidth: 480, maxHeight: 270)
      if model.waitsForWallpaperToSettle(on: screen.displayID) {
        Text("Showing the wallpaper’s preview image until it has played for a moment.")
          .font(.panel(.footnote))
          .foregroundStyle(theme.surface.muted.color)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .task(id: model.frameRequest(on: screen.displayID)) {
      guard let request = model.frameRequest(on: screen.displayID) else { return }
      await model.loadWallpaperFrame(request)
    }
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }

  private static let space = "desktop-widget-preview"

  /// The frame the display's wallpaper drew, which has the display's shape and the wallpaper's
  /// placement; else its still, or a quiet well while it has none or it loads: no glyph, which the
  /// widgets would sit on.
  private func backdrop(frame: CGImage?, still: PanelImageSource?, size: CGSize) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return ZStack {
      theme.surface.mediaWell.color
      if let frame {
        Image(decorative: frame, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
      } else {
        PanelImage(source: still, pointSize: max(size.width, size.height), contentMode: .fill)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .overlay { shape.strokeBorder(theme.surface.divider.color, lineWidth: 0.5) }
  }

  private func item(_ widget: DesktopWidget, saved: DesktopWidget, in size: CGSize, scale: CGFloat) -> some View {
    let model = controller.widgetsSettings
    let content = model.content(for: widget, scale: scale)
    let frame = model.frame(of: widget, in: size, scale: scale)
    return WidgetDrawing(drawing: content.drawing, padding: content.padding)
      .frame(width: frame.width, height: frame.height)
      .opacity(widget.isShown ? 1 : 0.35)
      .contentShape(Rectangle())
      .position(x: frame.midX, y: frame.midY)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
          .onChanged { drag in
            model.drag(
              saved, by: drag.translation, in: size, scale: scale, on: screen,
              snaps: !NSEvent.modifierFlags.contains(.command))
          }
          .onEnded { _ in model.endDrag() }
      )
      .onTapGesture { model.select(widget.id) }
  }

  /// The selected widget's outline, above every layer: a dark hairline under the accent one keeps
  /// it on a light wallpaper as on a dark one.
  private func outline(_ frame: CGRect) -> some View {
    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
    return ZStack {
      shape.strokeBorder(theme.surface.markFill.color, lineWidth: 2.5)
      shape.strokeBorder(theme.accent.accent.color, lineWidth: 1.25)
    }
    .frame(width: frame.width + 2, height: frame.height + 2)
    .position(x: frame.midX, y: frame.midY)
    .allowsHitTesting(false)
  }

  /// While a widget is dragged: the display's centre lines, faint and dashed until the widget lies
  /// on one, and a solid guide along every line it snapped to.
  private func guides(in size: CGSize) -> some View {
    let model = controller.widgetsSettings
    let snapped = model.drag?.guides ?? []
    let faint = model.drag == nil
      ? []
      : DesktopWidgetSnapping.displayGuides(in: size).filter { line in
        !snapped.contains { $0.axis == line.axis && abs($0.position - line.position) < 1.5 }
      }
    return ZStack(alignment: .topLeading) {
      ForEach(Array(faint.enumerated()), id: \.offset) { _, guide in
        path(guide).stroke(theme.surface.controlRim.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
      ForEach(Array(snapped.enumerated()), id: \.offset) { _, guide in
        path(guide).stroke(theme.surface.markFill.color, lineWidth: 2.5)
        path(guide).stroke(
          theme.accent.accent.color,
          style: StrokeStyle(lineWidth: 1, dash: guide.kind == .third || guide.kind == .margin ? [4, 2] : []))
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
  }

  private func path(_ guide: DesktopWidgetSnapping.Guide) -> Path {
    Path { path in
      // On the half point, so a one-point line is crisp.
      let position = guide.position.rounded(.down) + 0.5
      switch guide.axis {
      case .vertical:
        path.move(to: CGPoint(x: position, y: guide.start))
        path.addLine(to: CGPoint(x: position, y: guide.end))
      case .horizontal:
        path.move(to: CGPoint(x: guide.start, y: position))
        path.addLine(to: CGPoint(x: guide.end, y: position))
      }
    }
  }
}

/// A widget drawn by the same view the desktop's widget window uses.
private struct WidgetDrawing: NSViewRepresentable {
  let drawing: DesktopWidgetRendering.Drawing
  let padding: CGFloat

  func makeNSView(context: Context) -> DesktopWidgetView { DesktopWidgetView() }

  func updateNSView(_ view: DesktopWidgetView, context: Context) {
    view.update(drawing: drawing, padding: padding)
  }
}
