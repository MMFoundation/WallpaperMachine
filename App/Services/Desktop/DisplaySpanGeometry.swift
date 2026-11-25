import CoreGraphics
import Foundation

/// Pure coordinate math for spanning a single video or still image seamlessly across multiple
/// displays while keeping one `NSWindow` per display (preserving macOS "Displays have separate
/// Spaces").
///
/// All display coordinates follow AppKit's unified desktop space (`NSScreen.frame` in global
/// points, y growing upward, primary display at `(0, 0)`):
/// - Displays to the left or below the primary carry negative `minX` / `minY`.
/// - Mixed-DPI arrangements (for example a 2× Retina MacBook beside a 1× 1080p monitor) align
///   continuously in global points; each display's layer uses its own `backingScale` for crisp
///   native rendering without stretching across the bezel.
/// - `mediaGlobalRect` aspect-fills `unionBounds` and centers over it.
/// - Each `DisplaySlice` supplies:
///   - `unionFrameInDisplay` / `mediaFrameInDisplay` in the display window's local y-up `CALayer`
///     coordinates (for positioning a shared `AVPlayerLayer` or `AVSampleBufferDisplayLayer` inside
///     a `masksToBounds = true` container).
///   - `contentsRect` in macOS non-flipped `CALayer` unit coordinates (`[0, 1]`, y-up: `y = 0` is
///     the bottom of the image, `y = 1` is the top) for sharing one decoded `CGImage` across
///     per-display image layers.
///   - `normalizedTopDownRect` in top-down unit coordinates (`y = 0` is the top of the image) for
///     slicing `CGImage` posters for Mission Control / desktop pictures.
struct DisplaySpanGeometry: Equatable, Sendable {
    struct DisplaySlice: Equatable, Sendable {
        let displayID: UInt32
        /// The display's global AppKit frame in points (y-up).
        let displayFrame: CGRect
        /// Normalized backing scale (`>= 1`).
        let backingScale: CGFloat
        /// Where the full `unionBounds` sits inside this display window's local y-up layer bounds.
        let unionFrameInDisplay: CGRect
        /// Where the aspect-filled `mediaGlobalRect` sits inside this display window's local y-up
        /// layer bounds.
        let mediaFrameInDisplay: CGRect
        /// Unit `[0, 1]` slice of `mediaGlobalRect` in non-flipped macOS `CALayer.contentsRect`
        /// coordinates (y-up: `y = 0` is bottom of the image, `y = 1` is top).
        let contentsRect: CGRect
        /// Unit `[0, 1]` slice of `mediaGlobalRect` in top-down image coordinates (`y = 0` is top
        /// of the image, `y = 1` is bottom), for `CGImage` cropping / poster composition.
        let normalizedTopDownRect: CGRect

        /// This display's dimensions in device pixels.
        var pixelSize: CGSize {
            CGSize(
                width: max(1, (displayFrame.width * backingScale).rounded()),
                height: max(1, (displayFrame.height * backingScale).rounded()))
        }
    }

    /// Bounding box covering all spanned displays in AppKit global points (y-up).
    let unionBounds: CGRect
    /// Aspect-filled media rectangle centered over `unionBounds` in AppKit global points (y-up).
    /// Equals `unionBounds` when `mediaSize` was omitted.
    let mediaGlobalRect: CGRect
    /// Per-display slices in input display order.
    let slices: [DisplaySlice]
    /// Highest backing scale factor across the spanned displays.
    let maxBackingScale: CGFloat

    /// True when at least two displays participate in this span.
    var isMultiDisplay: Bool { slices.count >= 2 }

    /// The slice for `displayID`, or `nil` if that display is not part of this span.
    func slice(for displayID: UInt32) -> DisplaySlice? {
        slices.first { $0.displayID == displayID }
    }

    /// Computes span geometry from a `DisplayConfiguration`, optionally restricted to
    /// `includedDisplayIDs` and aspect-filled for `mediaSize`.
    ///
    /// Returns `nil` when no valid displays remain.
    static func compute(
        configuration: DisplayConfiguration,
        mediaSize: CGSize? = nil,
        includedDisplayIDs: Set<UInt32>? = nil
    ) -> DisplaySpanGeometry? {
        let filtered: [DisplayConfiguration.Display]
        if let includedDisplayIDs {
            filtered = configuration.displays.filter { includedDisplayIDs.contains($0.id) }
        } else {
            filtered = configuration.displays
        }
        return compute(displays: filtered, mediaSize: mediaSize)
    }

    /// Computes span geometry from an ordered list of displays and an optional media pixel/point
    /// size. Deduplicates repeated display IDs (keeping first) and ignores degenerate frames.
    static func compute(
        displays: [DisplayConfiguration.Display],
        mediaSize: CGSize? = nil
    ) -> DisplaySpanGeometry? {
        var seen = Set<UInt32>()
        var valid: [DisplayConfiguration.Display] = []
        valid.reserveCapacity(displays.count)
        for display in displays {
            guard seen.insert(display.id).inserted else { continue }
            let f = display.frame
            guard f.origin.x.isFinite, f.origin.y.isFinite,
                  f.size.width.isFinite, f.size.height.isFinite,
                  f.size.width > 0, f.size.height > 0
            else { continue }
            valid.append(display)
        }
        guard !valid.isEmpty else { return nil }

        let unionBounds = valid.reduce(CGRect.null) { $0.union($1.frame) }
        guard unionBounds.width > 0, unionBounds.height > 0 else { return nil }

        let mediaGlobalRect: CGRect
        if let mediaSize,
           mediaSize.width.isFinite, mediaSize.height.isFinite,
           mediaSize.width > 0, mediaSize.height > 0
        {
            let fillScale = max(unionBounds.width / mediaSize.width, unionBounds.height / mediaSize.height)
            let mediaWidth = mediaSize.width * fillScale
            let mediaHeight = mediaSize.height * fillScale
            mediaGlobalRect = CGRect(
                x: unionBounds.midX - mediaWidth / 2,
                y: unionBounds.midY - mediaHeight / 2,
                width: mediaWidth,
                height: mediaHeight)
        } else {
            mediaGlobalRect = unionBounds
        }

        var maxScale: CGFloat = 1
        var slices: [DisplaySlice] = []
        slices.reserveCapacity(valid.count)
        for display in valid {
            let scale = CGFloat(display.scale.isFinite && display.scale > 0 ? display.scale : 1)
            maxScale = max(maxScale, scale)
            let frame = display.frame
            let unionLocal = CGRect(
                x: unionBounds.minX - frame.minX,
                y: unionBounds.minY - frame.minY,
                width: unionBounds.width,
                height: unionBounds.height)
            let mediaLocal = CGRect(
                x: mediaGlobalRect.minX - frame.minX,
                y: mediaGlobalRect.minY - frame.minY,
                width: mediaGlobalRect.width,
                height: mediaGlobalRect.height)
            let uX = (frame.minX - mediaGlobalRect.minX) / mediaGlobalRect.width
            let uW = frame.width / mediaGlobalRect.width
            let vBottomY = (frame.minY - mediaGlobalRect.minY) / mediaGlobalRect.height
            let vTopY = (mediaGlobalRect.maxY - frame.maxY) / mediaGlobalRect.height
            let vH = frame.height / mediaGlobalRect.height
            slices.append(DisplaySlice(
                displayID: display.id,
                displayFrame: frame,
                backingScale: scale,
                unionFrameInDisplay: unionLocal,
                mediaFrameInDisplay: mediaLocal,
                contentsRect: CGRect(x: uX, y: vBottomY, width: uW, height: vH),
                normalizedTopDownRect: CGRect(x: uX, y: vTopY, width: uW, height: vH)))
        }
        return DisplaySpanGeometry(
            unionBounds: unionBounds,
            mediaGlobalRect: mediaGlobalRect,
            slices: slices,
            maxBackingScale: maxScale)
    }

    /// Renders a display's exact spanned slice of `image` at the display's device-pixel dimensions,
    /// for Mission Control / static desktop posters.
    ///
    /// When `flipHorizontal` is true, mirrors across the whole spanned virtual union canvas so
    /// the left display shows the mirrored right half of the image.
    static func composePoster(
        from image: CGImage,
        slice: DisplaySlice,
        flipHorizontal: Bool = false
    ) -> CGImage? {
        let pixels = slice.pixelSize
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 0, pixels.height > 0,
              pixels.width <= 16_384, pixels.height <= 16_384
        else { return nil }
        let width = Int(pixels.width.rounded(.up))
        let height = Int(pixels.height.rounded(.up))
        guard width * height <= 32 * 1024 * 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        // Draw the full media rectangle positioned in this display's local device-pixel coordinates,
        // matching the live layer's exact clip.
        let scale = slice.backingScale
        let media = slice.mediaFrameInDisplay
        let drawRect = CGRect(
            x: media.minX * scale,
            y: media.minY * scale,
            width: media.width * scale,
            height: media.height * scale)

        if flipHorizontal {
            // Mirror about the center of the spanned media rectangle (matching the live layer's
            // horizontal flip around the virtual union canvas center).
            context.translateBy(x: drawRect.midX, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -drawRect.midX, y: 0)
        }
        context.draw(image, in: drawRect)
        return context.makeImage()
    }
}
