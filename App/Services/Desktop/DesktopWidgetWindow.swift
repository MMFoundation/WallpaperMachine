import AppKit

/// What `DesktopWidgetController` puts a widget on: a window in production, a recorder in tests.
@MainActor
protocol DesktopWidgetSurface: AnyObject {
    /// Shows `drawing` with `look` and `padding` around it, in `frame` (global screen coordinates).
    func show(
        _ drawing: DesktopWidgetRendering.Drawing, look: DesktopWidgetRendering.Look, padding: CGFloat, frame: NSRect)
    /// Applies Space pinning for this widget window: `nil` joins every Space (`.canJoinAllSpaces`);
    /// a non-empty list pins the window to those managed Space IDs via `mover`, falling back to
    /// `.canJoinAllSpaces` when private Space APIs are unavailable.
    func applySpacePinning(_ managedSpaceIDs: [UInt64]?, using mover: (any WallpaperSpaceWindowMoving)?)
    /// Whether any of it can be seen now: false while windows cover it, the display sleeps or the
    /// screen is locked.
    var isOnScreen: Bool { get }
    /// Puts it in front of the other widgets' surfaces, still behind Finder's icons.
    func raise()
    func remove()
}

extension DesktopWidgetSurface {
    func applySpacePinning(_ managedSpaceIDs: [UInt64]?, using mover: (any WallpaperSpaceWindowMoving)?) {}
}

/// One desktop widget's window: transparent, the size of its text or clock face, just above the wallpaper windows
/// and below Finder's desktop icons, on every Space, ignoring the mouse. Its Objective-C name is not
/// one of `WallpaperPresentationPolicy.wallpaperWindowClassNames`, so occlusion tracking, the
/// window audit and the desktop-picture posters never take it for a wallpaper.
@objc(MWEDesktopWidgetWindow)
final class DesktopWidgetWindow: NSWindow, DesktopWidgetSurface {
    private let widgetView = DesktopWidgetView()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A widget may sit under the menu bar, out of which AppKit would otherwise move a window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// A widget window that is not yet on screen.
    static func make() -> DesktopWidgetWindow {
        let window = DesktopWidgetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
            backing: .buffered, defer: false)
        // Just above the wallpaper windows, as the coverage probes and the notch strip are, and below
        // Finder's icons. Being transparent and smaller than a display's working area, it never
        // makes a display count as covered.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Hiding the app hides the panel, never the desktop.
        window.canHide = false
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.contentView = window.widgetView
        return window
    }

    /// A widget window, put on screen.
    static func present() -> any DesktopWidgetSurface {
        let window = make()
        window.orderFrontRegardless()
        return window
    }

    func show(
        _ drawing: DesktopWidgetRendering.Drawing, look: DesktopWidgetRendering.Look, padding: CGFloat, frame: NSRect
    ) {
        if self.frame != frame { setFrame(frame, display: false) }
        widgetView.update(drawing: drawing, look: look, padding: padding)
    }

    func applySpacePinning(_ managedSpaceIDs: [UInt64]?, using mover: (any WallpaperSpaceWindowMoving)?) {
        guard let spaces = managedSpaceIDs, !spaces.isEmpty, let mover else {
            if !collectionBehavior.contains(.canJoinAllSpaces) {
                collectionBehavior.insert(.canJoinAllSpaces)
            }
            return
        }
        if collectionBehavior.contains(.canJoinAllSpaces) {
            collectionBehavior.remove(.canJoinAllSpaces)
        }
        if mover.spaces(ofWindow: windowNumber) == spaces { return }
        if !mover.place(window: windowNumber, onSpaces: spaces) {
            // Private Space placement API unavailable: fall back cleanly to joining every Space.
            collectionBehavior.insert(.canJoinAllSpaces)
        }
    }

    var isOnScreen: Bool { occlusionState.contains(.visible) }

    func raise() { orderFrontRegardless() }

    func remove() {
        orderOut(nil)
        close()
    }

    /// The words the window shows; empty for a clock face or image sticker.
    var shownText: String {
        switch widgetView.drawing {
        case .text(let text):
            return text.string
        case .nowPlaying(let card):
            return [card.title.string, card.subtitle?.string]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
        case .empty, .analog, .image:
            return ""
        }
    }
}

/// Draws a widget's text or clock face with its look, and redraws only when one of them changes:
/// on the desktop, and in the panel's preview, which so draws it the same way. It never takes the
/// mouse; the preview's drag is the panel's own.
///
/// The drawing is put together in transparency layers, so its parts never show through each other:
/// the letters (or the face) are filled, a gradient takes their place where they are, the outline
/// goes behind them, and that group casts the glow and then the shadow. The background plate sits
/// under it all, and the widget's opacity applies to the whole.
final class DesktopWidgetView: NSView {
    private(set) var drawing = DesktopWidgetRendering.Drawing.text(NSAttributedString())
    private(set) var look = DesktopWidgetRendering.Look()
    private var padding: CGFloat = 0

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(drawing: DesktopWidgetRendering.Drawing, look: DesktopWidgetRendering.Look, padding: CGFloat) {
        guard drawing != self.drawing || look != self.look || padding != self.padding else { return }
        self.drawing = drawing
        self.look = look
        self.padding = padding
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if case .empty = drawing { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        var content = bounds.insetBy(dx: padding, dy: padding)
        if look.rotation != 0 {
            // Turned about the middle; the frame is the turned drawing's box.
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.rotate(by: -look.rotation * .pi / 180)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
            content = NSRect(
                x: bounds.midX - look.size.width / 2, y: bounds.midY - look.size.height / 2,
                width: look.size.width, height: look.size.height)
        }
        context.setAlpha(look.opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        if let plate = look.background { Self.draw(plate, around: content) }

        if let shadow = look.shadow {
            let value = NSShadow()
            value.shadowBlurRadius = shadow.blur
            value.shadowOffset = shadow.offset
            value.shadowColor = shadow.color
            value.set()
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        switch drawing {
        case .empty:
            break
        case .nowPlaying(let card):
            drawNowPlaying(card, in: content, context: context)
        case .image(let sticker):
            drawSticker(sticker, in: content, context: context)
        case .text, .analog:
            drawForegroundWithGlow(in: content, context: context)
        }
        context.endTransparencyLayer()
    }

    private func drawForegroundWithGlow(in content: NSRect, context: CGContext) {
        if let glow = look.glow {
            // A shadow without offset is a glow; drawn twice, it reads as light, not as haze.
            for _ in 0..<2 {
                NSGraphicsContext.saveGraphicsState()
                let value = NSShadow()
                value.shadowBlurRadius = glow.radius
                value.shadowOffset = .zero
                value.shadowColor = glow.color
                value.set()
                drawInk(in: content, context: context)
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            drawInk(in: content, context: context)
        }
    }

    /// Draws the Now Playing card: full-color rounded album artwork beside styled track typography.
    private func drawNowPlaying(
        _ card: DesktopWidgetRendering.NowPlayingCard, in rect: NSRect, context: CGContext
    ) {
        let artOnRight = card.showsArtwork && card.alignment == .trailing
        let textX: CGFloat
        let textWidth: CGFloat
        if card.showsArtwork {
            let artX = artOnRight ? rect.maxX - card.artworkSide : rect.minX
            let artY = rect.midY - card.artworkSide / 2
            let artRect = NSRect(x: artX, y: artY, width: card.artworkSide, height: card.artworkSide)
            Self.drawArtwork(card, in: artRect, context: context)
            textX = artOnRight ? rect.minX : artRect.maxX + card.spacing
            textWidth = max(rect.width - card.artworkSide - card.spacing, 0)
        } else {
            textX = rect.minX
            textWidth = rect.width
        }
        let textRect = NSRect(x: textX, y: rect.minY, width: textWidth, height: rect.height)
        drawForegroundWithGlow(in: textRect, context: context)
    }

    /// Draws a static image sticker clipped to rounded corners, preserving full color.
    private func drawSticker(
        _ sticker: DesktopWidgetRendering.ImageSticker, in rect: NSRect, context: CGContext
    ) {
        func renderSticker() {
            if let rendered = sticker.image {
                context.saveGState()
                let clip = NSBezierPath(
                    roundedRect: rect, xRadius: sticker.cornerRadius, yRadius: sticker.cornerRadius)
                clip.addClip()
                let targetRect = Self.imageRect(
                    imageSize: NSSize(width: rendered.image.width, height: rendered.image.height),
                    in: rect, fit: sticker.fit)
                context.interpolationQuality = .high
                context.draw(rendered.image, in: targetRect)
                context.restoreGState()
                if let outline = look.outline {
                    context.saveGState()
                    let stroke = NSBezierPath(
                        roundedRect: rect, xRadius: sticker.cornerRadius, yRadius: sticker.cornerRadius)
                    stroke.lineWidth = outline.width * 2
                    outline.color.setStroke()
                    stroke.stroke()
                    context.restoreGState()
                }
            } else if sticker.isPlaceholder {
                Self.drawStickerPlaceholder(in: rect, cornerRadius: sticker.cornerRadius)
            }
        }
        if let glow = look.glow {
            for _ in 0..<2 {
                NSGraphicsContext.saveGraphicsState()
                let value = NSShadow()
                value.shadowBlurRadius = glow.radius
                value.shadowOffset = .zero
                value.shadowColor = glow.color
                value.set()
                renderSticker()
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            renderSticker()
        }
    }

    private static func drawArtwork(
        _ card: DesktopWidgetRendering.NowPlayingCard, in rect: NSRect, context: CGContext
    ) {
        context.saveGState()
        let clip = NSBezierPath(
            roundedRect: rect, xRadius: card.artworkCornerRadius, yRadius: card.artworkCornerRadius)
        clip.addClip()
        if let rendered = card.artwork {
            let target = imageRect(
                imageSize: NSSize(width: rendered.image.width, height: rendered.image.height),
                in: rect, fit: .fill)
            context.interpolationQuality = .high
            context.draw(rendered.image, in: target)
        } else {
            card.placeholderColor.setFill()
            clip.fill()
            if let glyph = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
                let side = min(rect.width, rect.height) * 0.44
                let config = NSImage.SymbolConfiguration(pointSize: max(side, 8), weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [card.placeholderGlyphColor]))
                let styled = glyph.withSymbolConfiguration(config) ?? glyph
                let glyphSize = styled.size
                let origin = NSPoint(
                    x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2)
                styled.draw(in: NSRect(origin: origin, size: glyphSize))
            }
        }
        context.restoreGState()
    }

    private static func drawStickerPlaceholder(in rect: NSRect, cornerRadius: CGFloat) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14).setFill()
        shape.fill()
        let inset = rect.insetBy(dx: 1, dy: 1)
        let border = NSBezierPath(
            roundedRect: inset, xRadius: max(cornerRadius - 1, 0), yRadius: max(cornerRadius - 1, 0))
        let dash: [CGFloat] = [5, 4]
        border.setLineDash(dash, count: dash.count, phase: 0)
        border.lineWidth = 1.5
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55).setStroke()
        border.stroke()
        if let glyph = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
            let side = min(rect.width, rect.height) * 0.34
            let config = NSImage.SymbolConfiguration(pointSize: max(side, 10), weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72)]))
            let styled = glyph.withSymbolConfiguration(config) ?? glyph
            let glyphSize = styled.size
            styled.draw(
                in: NSRect(
                    x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2,
                    width: glyphSize.width, height: glyphSize.height))
        }
    }

    private static func imageRect(
        imageSize: NSSize, in rect: NSRect, fit: DesktopWidget.ImageFit
    ) -> NSRect {
        guard fit == .fill, imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The letters or the face, filled with the colour or the gradient, with the outline behind.
    private func drawInk(in rect: NSRect, context: CGContext) {
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        drawShapes(in: rect, outline: nil)
        if let gradient = look.gradient {
            context.saveGState()
            context.setBlendMode(.sourceIn)
            Self.draw(gradient, over: rect.insetBy(dx: -padding, dy: -padding))
            context.restoreGState()
        }
        if let outline = look.outline {
            context.saveGState()
            context.setBlendMode(.destinationOver)
            context.setLineJoin(.round)
            drawShapes(in: rect, outline: outline)
            context.restoreGState()
        }
    }

    /// The drawing itself; with `outline`, its outline alone, in the outline's colour.
    private func drawShapes(in rect: NSRect, outline: DesktopWidgetRendering.Look.Outline?) {
        switch drawing {
        case .empty, .image:
            break
        case .text(let text):
            // Laid out from the top, so a widget cut to its display keeps its first lines.
            let shown = outline.map { Self.outlined(text, $0) } ?? text
            shown.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .analog(let face):
            Self.draw(face, in: rect, outline: outline)
        case .nowPlaying(let card):
            Self.draw(cardText: card, in: rect, outline: outline)
        }
    }

    private static func draw(
        cardText card: DesktopWidgetRendering.NowPlayingCard, in rect: NSRect,
        outline: DesktopWidgetRendering.Look.Outline?
    ) {
        let gap = card.subtitle != nil ? max(ceil(card.titleSize.height * 0.12), 2) : 0
        let totalHeight = card.titleSize.height + (card.subtitle != nil ? gap + card.subtitleSize.height : 0)
        // AppKit view coordinates have y increasing upwards: title sits above subtitle.
        let top = rect.midY + totalHeight / 2
        let titleRect = NSRect(
            x: rect.minX, y: top - card.titleSize.height, width: rect.width, height: card.titleSize.height)
        let titleShown = outline.map { outlined(card.title, $0) } ?? card.title
        titleShown.draw(with: titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        if let subtitle = card.subtitle {
            let subRect = NSRect(
                x: rect.minX, y: titleRect.minY - gap - card.subtitleSize.height,
                width: rect.width, height: card.subtitleSize.height)
            let subShown = outline.map { outlined(subtitle, $0) } ?? subtitle
            subShown.draw(with: subRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
    }

    /// `text` as its outline only: each run stroked as wide as the outline on both sides of the
    /// letters' edge, so as much shows outside them.
    private static func outlined(
        _ text: NSAttributedString, _ outline: DesktopWidgetRendering.Look.Outline
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            // Percent of the point size; positive strokes without filling.
            result.addAttribute(.strokeWidth, value: 200 * outline.width / max(size, 1), range: range)
        }
        result.addAttribute(.strokeColor, value: outline.color, range: whole)
        result.addAttribute(.foregroundColor, value: outline.color, range: whole)
        result.removeAttribute(.underlineStyle, range: whole)
        return result
    }

    private static func draw(_ gradient: DesktopWidgetRendering.Look.Gradient, over rect: NSRect) {
        guard let fill = NSGradient(starting: gradient.from, ending: gradient.to) else { return }
        let angle = gradient.angle * .pi / 180
        // The way from the first colour to the second, upwards positive, across the whole rect.
        let direction = CGVector(dx: sin(angle), dy: cos(angle))
        let reach = (abs(direction.dx) * rect.width + abs(direction.dy) * rect.height) / 2
        let start = NSPoint(x: rect.midX - direction.dx * reach, y: rect.midY - direction.dy * reach)
        let end = NSPoint(x: rect.midX + direction.dx * reach, y: rect.midY + direction.dy * reach)
        fill.draw(from: start, to: end, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    }

    private static func draw(_ plate: DesktopWidgetRendering.Look.Plate, around rect: NSRect) {
        let area = rect.insetBy(dx: -plate.inset, dy: -plate.inset)
        let short = min(area.width, area.height)
        let radius: CGFloat = switch plate.shape {
        case .off, .rectangle: 0
        case .rounded: short * 0.22
        case .capsule: short / 2
        }
        plate.color.setFill()
        NSBezierPath(roundedRect: area, xRadius: radius, yRadius: radius).fill()
    }

    /// The ring, the hour marks (or ticks, or numbers), the hands and a dot at the centre. With
    /// `outline`, every line is drawn that much wider on each side, in the outline's colour.
    private static func draw(
        _ face: DesktopWidgetRendering.AnalogFace, in rect: NSRect, outline: DesktopWidgetRendering.Look.Outline?
    ) {
        let extra = (outline?.width ?? 0) * 2
        let ink = outline?.color ?? face.color
        ink.set()
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let width = face.lineWidth
        func point(_ turn: Double, _ length: CGFloat) -> NSPoint {
            let angle = turn * 2 * .pi
            return NSPoint(x: center.x + CGFloat(sin(angle)) * length, y: center.y + CGFloat(cos(angle)) * length)
        }
        func line(from start: NSPoint, to end: NSPoint, width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = width + extra
            path.lineCapStyle = .round
            path.stroke()
        }
        let ringWidth = max(width * 0.5, 0.5)
        if face.showsRing {
            let ring = NSBezierPath(
                ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                    .insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
            ring.lineWidth = ringWidth + extra
            ring.stroke()
        }
        let outer = radius - ringWidth - radius * 0.04
        func mark(_ turn: Double, long: Bool) {
            let length = radius * (long ? 0.14 : 0.08)
            line(from: point(turn, outer), to: point(turn, outer - length), width: width * (long ? 0.9 : 0.6))
        }
        func numeral(_ hour: Int, at spot: NSPoint) {
            guard let font = face.numeralFont else { return }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            if face.slantsNumerals { attributes[.obliqueness] = DesktopWidgetRendering.slant }
            if let outline {
                attributes[.strokeWidth] = 200 * outline.width / max(font.pointSize, 1)
                attributes[.strokeColor] = outline.color
            }
            let text = NSAttributedString(string: String(hour), attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: spot.x - size.width / 2, y: spot.y - size.height / 2))
        }
        switch face.marks {
        case .bare:
            break
        case .hours:
            for hour in 0..<12 { mark(Double(hour) / 12, long: hour % 3 == 0) }
        case .minutes:
            for minute in 0..<60 {
                let turn = Double(minute) / 60
                if minute % 5 == 0 {
                    mark(turn, long: true)
                } else {
                    line(from: point(turn, outer), to: point(turn, outer - radius * 0.04), width: width * 0.35)
                }
            }
        case .numbers, .quarters:
            for hour in 1...12 {
                let turn = Double(hour % 12) / 12
                if face.marks == .numbers || hour % 3 == 0 {
                    numeral(hour, at: point(turn, outer - radius * 0.13))
                } else {
                    mark(turn, long: false)
                }
            }
        }
        line(from: center, to: point(face.hour, radius * 0.5), width: width * 1.6)
        line(from: center, to: point(face.minute, radius * 0.76), width: width)
        if let second = face.second {
            if outline == nil { face.accent.set() }
            line(from: point(second + 0.5, radius * 0.12), to: point(second, radius * 0.84), width: max(width * 0.35, 0.5))
            ink.set()
        }
        let dot = width * 1.3 + extra / 2
        NSBezierPath(ovalIn: NSRect(x: center.x - dot, y: center.y - dot, width: 2 * dot, height: 2 * dot)).fill()
    }
}
