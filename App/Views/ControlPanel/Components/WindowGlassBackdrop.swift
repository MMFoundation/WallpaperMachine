import AppKit
import SwiftUI

/// The window's backdrop behind every page: opaque in Solid mode (or when macOS Reduce
/// Transparency is on), and a behind-window frosted blur tinted by the active theme's background
/// colour when Liquid Glass is active. The tint's opacity follows the user's transparency slider
/// (`PanelTheme.windowBackgroundOpacity(reduceTransparency:)`).
struct WindowGlassBackdrop: View {
  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if theme.isLiquidGlass && !reduceTransparency {
      ZStack {
        BehindWindowVisualEffect()
        theme.backgroundFill(reduceTransparency: false)
      }
    } else {
      theme.surface.background.color
    }
  }
}

/// An `NSVisualEffectView` that blurs what lies behind the window (desktop, wallpaper, other
/// windows) without touching the window's title bar constraints.
private struct BehindWindowVisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .hudWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    if view.blendingMode != .behindWindow { view.blendingMode = .behindWindow }
    if view.material != .hudWindow { view.material = .hudWindow }
    if view.state != .followsWindowActiveState { view.state = .followsWindowActiveState }
  }
}
