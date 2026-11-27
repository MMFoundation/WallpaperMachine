import SwiftUI

/// A season's papercut horizon: rolling hills cut from one ink, the season's silhouettes standing on
/// them, a low moon and bats in the sky. `ground` is the band over the Now Playing bar, the bar
/// being the ground the hills rise from; `night` is the same horizon under a night sky, the picture
/// at the top of Settings › Appearance.
///
/// It draws once per size: the silhouettes are still images, the hills a path, nothing moves.
struct SeasonHorizon: View {
  enum Style {
    /// Over the window's own background, lit from the horizon.
    case ground
    /// Under its own night sky, whatever the appearance.
    case night
  }

  /// The band's height over the Now Playing bar.
  static let groundHeight: CGFloat = 60

  /// The paper every silhouette of `season` is cut from; the Now Playing bar takes this colour
  /// while the season is on.
  static func ink(for season: Season) -> PanelColor {
    switch season {
    case .halloween: PanelColor(rgb: 0x120e19)
    case .christmas: PanelColor(rgb: 0x0c1512)
    }
  }

  /// The moon at night in `season`.
  static func moon(for season: Season) -> PanelColor {
    switch season {
    case .halloween: PanelColor(rgb: 0xf6ead0)
    case .christmas: PanelColor(rgb: 0xeef6fa)
    }
  }

  /// The moon over a light window: harvest orange for Halloween, warm winter gold for Christmas.
  static func dayMoon(for season: Season) -> PanelColor {
    switch season {
    case .halloween: PanelColor(rgb: 0xf09a4c)
    case .christmas: PanelColor(rgb: 0xf2be5c)
    }
  }

  /// One silhouette on the horizon: where it stands as a share of the width, its height as a share
  /// of the band's, and the narrowest band that has room for it.
  struct Piece {
    let name: String
    let position: CGFloat
    let height: CGFloat
    var minimumWidth: CGFloat = 0
  }

  /// The silhouettes standing on the season's hills, left to right.
  static func pieces(_ season: Season) -> [Piece] {
    switch season {
    case .halloween:
      [
        Piece(name: "HalloweenTreeTall", position: 0.07, height: 0.96),
        Piece(name: "HalloweenGraves", position: 0.22, height: 0.38),
        Piece(name: "HalloweenCat", position: 0.33, height: 0.4, minimumWidth: 1100),
        Piece(name: "HalloweenTreeLeaning", position: 0.46, height: 0.72, minimumWidth: 760),
        Piece(name: "HalloweenCrow", position: 0.595, height: 0.44, minimumWidth: 980),
        Piece(name: "HalloweenHouse", position: 0.8, height: 0.84),
        Piece(name: "HalloweenPumpkins", position: 0.905, height: 0.28),
      ]
    case .christmas:
      [
        Piece(name: "ChristmasTreeTall", position: 0.07, height: 0.96),
        Piece(name: "ChristmasGifts", position: 0.21, height: 0.36),
        Piece(name: "ChristmasSnowman", position: 0.33, height: 0.46, minimumWidth: 1100),
        Piece(name: "ChristmasPine", position: 0.46, height: 0.78, minimumWidth: 760),
        Piece(name: "ChristmasReindeer", position: 0.595, height: 0.50, minimumWidth: 980),
        Piece(name: "ChristmasCabin", position: 0.8, height: 0.84),
        Piece(name: "ChristmasLamp", position: 0.915, height: 0.52),
      ]
    }
  }

  /// What flies in the season's sky.
  static func flock(_ season: Season) -> String {
    switch season {
    case .halloween: "HalloweenBats"
    case .christmas: "ChristmasSleigh"
    }
  }

  let season: Season
  var style: Style = .ground

  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let dark = theme.appearance == .dark
    // Moonlight behind the hills in the dark, a dusk glow over a light window: the silhouettes need
    // something lighter than their ink to stand against.
    let glow: PanelColor =
      switch (season, dark) {
      case (.halloween, true): PanelColor(rgb: 0x4a3a70)
      case (.halloween, false): PanelColor(rgb: 0xf0c690)
      case (.christmas, true): PanelColor(rgb: 0x265952)
      case (.christmas, false): PanelColor(rgb: 0xdfd4b8)
      }
    let night = style == .night
    let moon = night || dark ? Self.moon(for: season) : Self.dayMoon(for: season)
    let season = season
    Canvas { context, size in
      Self.draw(
        in: &context, size: size, season: season, night: night, dark: dark, glow: glow.color,
        moon: moon.color)
    }
    .background(
      night || (theme.isLiquidGlass && !reduceTransparency)
        ? Color.clear : theme.surface.background.color
    )
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }

  private static func draw(
    in context: inout GraphicsContext, size: CGSize, season: Season, night: Bool, dark: Bool,
    glow: Color, moon: Color
  ) {
    let width = size.width
    let height = size.height
    guard width > 0, height > 0 else { return }
    let inkColor = Self.ink(for: season).color
    // The hills keep their shape whatever the band's height: their waves are measured in units of a
    // ground band's height, not in points.
    let unit = height / groundHeight
    let base = night ? height * 0.1 : 8
    func ridge(_ x: CGFloat) -> CGFloat {
      let s = x / unit
      let swell = 0.55 + 0.28 * sin(s / 230 + 0.9) + 0.17 * sin(s / 71 + 2.3)
      return height - base - height * 0.32 * swell
    }

    // The sky: a night gradient, or the window's background warmed toward the horizon.
    let sky = Path(CGRect(origin: .zero, size: size))
    if night {
      let nightStops: [Color] =
        switch season {
        case .halloween: [PanelColor(rgb: 0x1a1430).color, PanelColor(rgb: 0x4a3a70).color]
        case .christmas: [PanelColor(rgb: 0x081716).color, PanelColor(rgb: 0x225249).color]
        }
      context.fill(
        sky,
        with: .linearGradient(
          Gradient(colors: nightStops),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
    } else {
      context.fill(
        sky,
        with: .linearGradient(
          Gradient(stops: [
            .init(color: glow.opacity(0), location: 0), .init(color: glow.opacity(0.55), location: 0.4),
            .init(color: glow, location: 0.85),
          ]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
    }

    // Still winter stars across the Christmas night sky (fixed geometry, no animation).
    if season == .christmas && (night || dark) {
      let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (0.05, 0.14, 1.3, 0.7), (0.14, 0.24, 1.0, 0.55), (0.24, 0.12, 1.4, 0.75),
        (0.35, 0.22, 1.1, 0.55), (0.44, 0.10, 1.2, 0.65), (0.56, 0.18, 1.3, 0.7),
        (0.63, 0.10, 1.0, 0.5), (0.76, 0.16, 1.2, 0.6), (0.92, 0.14, 1.4, 0.7),
        (0.96, 0.26, 1.0, 0.5),
      ]
      for (fx, fy, radius, opacity) in stars {
        let r = radius * (night ? 1.15 : 0.9)
        let cx = width * fx
        let cy = height * fy
        context.fill(
          Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
          with: .color(moon.opacity(opacity)))
      }
    }

    // The moon, rising behind the hills, with its halo.
    let moonX = width * 0.82
    let radius = height * (night ? 0.3 : 0.4)
    let moonY = ridge(moonX) - height * (night ? 0.3 : 0.06)
    context.fill(
      Path(ellipseIn: CGRect(x: moonX - radius * 2.6, y: moonY - radius * 2.6, width: radius * 5.2, height: radius * 5.2)),
      with: .radialGradient(
        Gradient(colors: [moon.opacity(night ? 0.3 : 0.45), moon.opacity(0)]),
        center: CGPoint(x: moonX, y: moonY), startRadius: radius * 0.9, endRadius: radius * 2.6))
    context.fill(
      Path(ellipseIn: CGRect(x: moonX - radius, y: moonY - radius, width: radius * 2, height: radius * 2)),
      with: .color(moon))

    // What crosses the sky toward the moon: bats for Halloween, Santa's sleigh for Christmas.
    let flyer = context.resolve(Image(flock(season)))
    let flyerHeight = height * (night ? 0.26 : 0.34)
    let flyerWidth = flyerHeight * flyer.size.width / max(flyer.size.height, 1)
    context.draw(
      flyer,
      in: CGRect(
        x: width * 0.69 - flyerWidth / 2, y: height * 0.04, width: flyerWidth, height: flyerHeight))

    // The hills, down to the bottom edge, where the Now Playing bar carries the same ink on.
    var hills = Path()
    hills.move(to: CGPoint(x: 0, y: height))
    hills.addLine(to: CGPoint(x: 0, y: ridge(0)))
    var x: CGFloat = 0
    while x < width {
      x = min(x + 4, width)
      hills.addLine(to: CGPoint(x: x, y: ridge(x)))
    }
    hills.addLine(to: CGPoint(x: width, y: height))
    hills.closeSubpath()
    context.fill(hills, with: .color(inkColor))

    // The silhouettes stand on the ridge, their feet a little sunk into it.
    let groundWidth = width / unit
    for piece in pieces(season) where groundWidth >= piece.minimumWidth {
      let image = context.resolve(Image(piece.name))
      let pieceHeight = (night ? height * 0.82 : height) * piece.height
      let pieceWidth = pieceHeight * image.size.width / max(image.size.height, 1)
      let centre = width * piece.position
      let foot = ridge(centre) + 2 * unit
      context.draw(
        image,
        in: CGRect(x: centre - pieceWidth / 2, y: foot - pieceHeight, width: pieceWidth, height: pieceHeight))
    }
  }
}
