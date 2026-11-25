import AppKit
import SwiftUI

/// Position on screen: where a still image this app packaged (saved from pixiv, or imported from
/// disk) sits on the target display. The picture is shown in a frame with the display's proportions,
/// laid out the way the wallpaper page lays it out, and can be dragged there or moved with the
/// sliders and the arrow keys. Each display keeps its own position, and a change applies at once.
struct PlacementCard: View {
  let state: ImagePlacementState
  let row: LibraryRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    InspectorSection("Position on screen") {
      if !state.isSupported {
        InspectorCardRow {
          InspectorNote(
            verbatim: state.reason ?? L("This picture cannot be positioned on the target display right now."))
        }
      } else {
        supported
      }
    }
  }

  @ViewBuilder
  private var supported: some View {
    let drafts = controller.inspector.placement
    let values = drafts.values(for: state)
    InspectorCardRow {
      VStack(alignment: .leading, spacing: 10) {
        InspectorNote(
          verbatim: L(
            "On \(state.displayTitle). Drag the picture in the frame, or use the sliders. Each display keeps its own position."
          ))
        PlacementFrame(state: state, source: row.previewSource)
      }
    }
    slider(
      "Horizontal position", label: L("Horizontal position"), value: values.x * 100, range: 0...100,
      format: { InspectorWording.percent($0 / 100) },
      change: { drafts.update(x: $0 / 100) })
    slider(
      "Vertical position", label: L("Vertical position"), value: values.y * 100, range: 0...100,
      format: { InspectorWording.percent($0 / 100) },
      change: { drafts.update(y: $0 / 100) })
    slider(
      "Zoom", label: L("Zoom"), value: values.zoom * 100, range: 100...300,
      format: { InspectorWording.zoom($0 / 100) },
      change: { drafts.update(zoom: $0 / 100) })
    InspectorCardRow {
      VStack(alignment: .leading, spacing: 6) {
        Button {
          drafts.reset(state)
        } label: {
          Label("Reset to Image fit", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.panelCardLink)
        .disabled(!drafts.canReset(state))
        .help(L("Puts the picture back where Image fit alone places it"))
        if state.fit == .blur {
          InspectorNote(
            "The wallpaper also fills the edges with a blurred copy of the picture; the frame shows the picture alone."
          )
        } else if state.fit == .center, state.imagePixelSize == nil || state.displayViewportSize == nil {
          InspectorNote(
            "Original size cannot be previewed exactly here; the frame shows the picture fitted.")
        }
      }
    }
  }

  /// A slider that moves the picture as it is dragged and saves when it settles; a key press moves
  /// it and saves at once.
  private func slider(
    _ title: LocalizedStringKey, label: String, value: Double, range: ClosedRange<Double>,
    format: @escaping (Double) -> String, change: @escaping (Double) -> Void
  ) -> some View {
    let drafts = controller.inspector.placement
    return InspectorSliderRow(
      title: title, value: value, range: range, step: 1, accessibilityLabel: label,
      format: format,
      onDrag: { change($0) },
      onRelease: { new in
        change(new)
        return drafts.commit(from: state)
      },
      onStep: { new in
        change(new)
        return drafts.commit(from: state)
      }
    )
    .disabled(drafts.isResetting)
  }
}

/// The frame itself: the picture at its box inside a frame of the display's shape. Dragging moves
/// the picture the other way (right shows more of its left side) with gentle 50% center guides,
/// double-clicking recenters it to (50%, 50%), pinching or Option-scrolling zooms it, an arrow key
/// moves it a hundredth and Shift five hundredths, and a click that does not move it changes
/// nothing. The pointer is a hand while there is something to drag.
private struct PlacementFrame: View {
  let state: ImagePlacementState
  let source: PanelImageSource?

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.panelImages) private var images
  @State private var loaded: DecodedPanelImage?
  @State private var drag: DragSession?
  @State private var pinchStartZoom: Double?

  private struct DragSession {
    var x: Double
    var y: Double
    var overflow: CGSize
    var moved = false
    var snappedX = false
    var snappedY = false
  }

  var body: some View {
    let drafts = controller.inspector.placement
    let values = drafts.values(for: state)
    let aspect = PlacementGeometry.stageAspect(
      displayAspect: state.displayAspectRatio, viewport: state.displayViewportSize)
    GeometryReader { proxy in
      let box = geometry(stage: proxy.size, values: values)
      ZStack(alignment: .topLeading) {
        theme.surface.mediaWell.color
        if let loaded, let box {
          Image(decorative: loaded.cgImage, scale: 1)
            .resizable()
            .frame(width: box.size.width, height: box.size.height)
            .offset(x: box.origin.x, y: box.origin.y)
        }
        if let session = drag, session.moved, let box {
          centerGuides(size: proxy.size, overflow: box.overflow, session: session)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .clipped()
      .contentShape(Rectangle())
      // The page's `pannable`: a picture larger than the frame on either axis can be dragged.
      .pointerStyle(box?.isPannable == true ? (drag == nil ? .grabIdle : .grabActive) : nil)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard !drafts.isResetting, let box else { return }
            if drag == nil {
              drag = DragSession(x: box.x, y: box.y, overflow: box.overflow)
            }
            guard var session = drag else { return }
            if !session.moved {
              guard PlacementGeometry.isDrag(value.translation) else { return }
              session.moved = true
            }
            let moved = PlacementGeometry.draggedWithCenterSnap(
              from: (session.x, session.y), overflow: session.overflow,
              translation: value.translation)
            session.snappedX = moved.snappedX
            session.snappedY = moved.snappedY
            drag = session
            drafts.update(x: moved.x, y: moved.y)
          }
          .onEnded { _ in
            guard let session = drag else { return }
            drag = nil
            if session.moved {
              drafts.commit(from: state)
            }
          })
      .simultaneousGesture(
        TapGesture(count: 2).onEnded {
          guard !drafts.isResetting else { return }
          drafts.recenter(state: state)
        })
      .simultaneousGesture(
        MagnifyGesture()
          .onChanged { value in
            guard !drafts.isResetting else { return }
            let start = pinchStartZoom ?? drafts.values(for: state).zoom
            if pinchStartZoom == nil { pinchStartZoom = start }
            drafts.update(
              zoom: PlacementGeometry.magnified(from: start, scale: Double(value.magnification)))
          }
          .onEnded { _ in
            guard pinchStartZoom != nil else { return }
            pinchStartZoom = nil
            drafts.commit(from: state)
          })
      .overlay {
        OptionScrollZoomMonitor(isEnabled: !drafts.isResetting) { deltaY, precise in
          drafts.scrollZoom(deltaY: deltaY, hasPreciseDeltas: precise, state: state)
        }
      }
    }
    .aspectRatio(aspect, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
    }
    .focusable()
    .onKeyPress(phases: [.down, .repeat]) { press in
      guard !drafts.isResetting else { return .ignored }
      let large = press.modifiers.contains(.shift)
      switch press.key {
      case .leftArrow: drafts.nudge(dx: -1, dy: 0, large: large, state: state)
      case .rightArrow: drafts.nudge(dx: 1, dy: 0, large: large, state: state)
      case .upArrow: drafts.nudge(dx: 0, dy: -1, large: large, state: state)
      case .downArrow: drafts.nudge(dx: 0, dy: 1, large: large, state: state)
      default: return .ignored
      }
      return .handled
    }
    // VoiceOver meets the frame through the element laid over it, which can call itself a
    // draggable picture; the pointer and the keys stay with the frame.
    .accessibilityHidden(true)
    .overlay {
      PlacementAccessibilityElement(
        label: L(
          "Picture position on \(state.displayTitle): \(InspectorWording.percent(values.x)) across, \(InspectorWording.percent(values.y)) down, \(InspectorWording.zoom(values.zoom)) zoom. Drag, or use the arrow keys to move it."
        ),
        roleDescription: L("draggable picture"),
        adjust: { step in drafts.nudge(dx: step, dy: 0, large: false, state: state) })
    }
    .task(id: source) { await load() }
  }

  /// Subtle 50% center guides shown while dragging pannable axes; brighten in the accent colour
  /// while snapped to center.
  @ViewBuilder
  private func centerGuides(size: CGSize, overflow: CGSize, session: DragSession) -> some View {
    ZStack {
      if overflow.width > PlacementGeometry.overflowThreshold {
        Rectangle()
          .fill(
            session.snappedX
              ? theme.accent.accent.color.opacity(0.85) : theme.surface.markGlyph.color.opacity(0.28)
          )
          .frame(width: session.snappedX ? 1 : 0.5, height: size.height)
          .position(x: size.width / 2, y: size.height / 2)
      }
      if overflow.height > PlacementGeometry.overflowThreshold {
        Rectangle()
          .fill(
            session.snappedY
              ? theme.accent.accent.color.opacity(0.85) : theme.surface.markGlyph.color.opacity(0.28)
          )
          .frame(width: size.width, height: session.snappedY ? 1 : 0.5)
          .position(x: size.width / 2, y: size.height / 2)
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func geometry(stage: CGSize, values: PlacementDrafts.Values) -> PlacementGeometry.Box? {
    var aspect = state.imageAspectRatio
    if aspect == nil || aspect! <= 0, let loaded, loaded.pixelSize.height > 0 {
      aspect = loaded.pixelSize.width / loaded.pixelSize.height
    }
    return PlacementGeometry.box(
      stage: stage, imageAspect: aspect, fit: state.fit, imagePixelSize: state.imagePixelSize,
      viewportSize: state.displayViewportSize, x: values.x, y: values.y, zoom: values.zoom)
  }

  private func load() async {
    guard let source, let images else { return }
    if let cached = images.cachedImage(for: source, maxPixelSize: 1200) {
      loaded = cached
      return
    }
    loaded = try? await images.image(for: source, maxPixelSize: 1200)
  }
}

/// Captures Option-scroll wheel events over the placement frame for zooming while leaving bare
/// scroll wheel events completely untouched so the enclosing inspector `ScrollView` still scrolls.
struct OptionScrollZoomMonitor: NSViewRepresentable {
  let isEnabled: Bool
  let onOptionScroll: @MainActor (Double, Bool) -> Void

  /// Pure guardrail: only Option-modified scroll events inside the visible frame bounds are
  /// captured; bare scroll wheel and other modifier combinations always pass through.
  nonisolated static func shouldHandleScrollEvent(
    modifiers: NSEvent.ModifierFlags, windowMatches: Bool, isHidden: Bool,
    pointInVisibleBounds: Bool, isEnabled: Bool
  ) -> Bool {
    guard modifiers.intersection([.option, .command, .control]) == .option else { return false }
    return isEnabled && windowMatches && !isHidden && pointInVisibleBounds
  }

  func makeNSView(context: Context) -> MonitorView { MonitorView() }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.isEnabled = isEnabled
    view.onOptionScroll = onOptionScroll
  }

  static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
    view.removeMonitor()
  }

  final class MonitorView: NSView {
    var isEnabled = true
    var onOptionScroll: (@MainActor (Double, Bool) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        MainActor.assumeIsolated {
          guard let self else { return event }
          let point = self.convert(event.locationInWindow, from: nil)
          guard
            OptionScrollZoomMonitor.shouldHandleScrollEvent(
              modifiers: event.modifierFlags,
              windowMatches: event.window === self.window,
              isHidden: self.isHiddenOrHasHiddenAncestor,
              pointInVisibleBounds: self.visibleRect.contains(point),
              isEnabled: self.isEnabled)
          else { return event }
          self.onOptionScroll?(Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas)
          return nil
        }
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }
  }
}

/// The Position on screen frame as assistive apps meet it: a picture element that calls itself a
/// "draggable picture" (the page's `aria-roledescription`), says where the picture sits, and
/// moves it a step for VoiceOver's increment and decrement. SwiftUI cannot give an element a role
/// description of its own, so this AppKit view stands over the frame for assistive apps alone; it
/// takes no clicks, so the pointer and keyboard focus stay with the frame beneath it.
struct PlacementAccessibilityElement: NSViewRepresentable {
  let label: String
  let roleDescription: String
  let adjust: @MainActor (Int) -> Void

  func makeNSView(context: Context) -> ElementView { ElementView() }

  func updateNSView(_ view: ElementView, context: Context) {
    view.label = label
    view.roleDescription = roleDescription
    view.adjust = adjust
  }

  final class ElementView: NSView {
    var label = ""
    var roleDescription = ""
    var adjust: (@MainActor (Int) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityRoleDescription() -> String? { roleDescription }
    override func accessibilityLabel() -> String? { label }

    override func accessibilityPerformIncrement() -> Bool {
      adjust?(1)
      return adjust != nil
    }

    override func accessibilityPerformDecrement() -> Bool {
      adjust?(-1)
      return adjust != nil
    }
  }
}
