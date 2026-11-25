import Foundation
import QuartzCore

/// The held picture: one still of what a display showed, carried as a plain sublayer of
/// whichever wallpaper window shows the next wallpaper.
///
/// A sublayer of the window's content layer and not a window of its own, so occlusion
/// tracking, hit testing, the poster sync (which reads renderer textures, never the screen)
/// and web snapshots (which render the page view) all see the window as before. It sits
/// above everything the window adds later through `zPosition`.
///
/// Every switch transition runs purely as GPU-composited Core Animation on this single
/// `CGImage` layer with zero extra image allocations and zero per-frame CPU work; the parent
/// container layer clips to its bounds (`masksToBounds = true`) so slide and zoom transitions
/// never bleed onto adjacent displays.
@MainActor
final class SwitchHoldVeil {
    static let layerName = "MWEHandoffVeil"
    static let fadeAnimationKey = "MWEHandoffVeilFade"
    /// Key under which the active switch transition animation is installed on `layer`.
    static let transitionAnimationKey = fadeAnimationKey

    let layer = CALayer()

    init(image: CGImage) {
        layer.name = Self.layerName
        layer.contents = image
        layer.contentsGravity = .resize
        layer.isOpaque = true
        layer.zPosition = 1_000
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // The veil is only ever moved, shown, hidden and animated explicitly: an implicit
        // animation of any of these would show the held picture sliding, cross-fading or
        // popping instead of staying put.
        layer.actions = ["opacity": NSNull(), "contents": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "hidden": NSNull(), "transform": NSNull(),
                         "contentsRect": NSNull(), "anchorPoint": NSNull(), "mask": NSNull()]
    }

    /// The layer the veil sits on, if any.
    var parent: CALayer? { layer.superlayer }

    /// Whether the veil is on a layer at all.
    var isAttached: Bool { layer.superlayer != nil }

    /// Whether a dismissal transition has started.
    var isTransitioning: Bool { layer.animation(forKey: Self.transitionAnimationKey) != nil }

    /// Whether a fade-out (or other switch transition) has started.
    var isFading: Bool { isTransitioning }

    /// Puts the veil over `parent`, taking it off any layer it was on. `flush` commits the
    /// change to the render server at once, for a host window that is about to be ordered in:
    /// without it the window can reach the screen a frame before its veil. The renderer's
    /// layer announcement must not flush: it runs inside the renderer's own window operation.
    ///
    /// Clips `parent` to its bounds so slide and zoom transitions stay within this display.
    func attach(to parent: CALayer, flush: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        layer.opacity = 1
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.transform = CATransform3DIdentity
        layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.mask = nil
        layer.frame = parent.bounds
        layer.contentsScale = parent.contentsScale
        parent.masksToBounds = true
        parent.addSublayer(layer)
        CATransaction.commit()
        if flush { CATransaction.flush() }
    }

    /// Starts dismissing the veil with `style` over `duration` seconds. The model values reach
    /// their dismissed state immediately so a transition that never completes (such as on an
    /// offscreen layer) cannot leave the veil covering the wallpaper; the caller detaches the
    /// veil with `detach()` after the duration.
    func beginTransition(_ style: SwitchTransitionStyle, duration: TimeInterval) {
        switch style {
        case .none:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = 0
            CATransaction.commit()

        case .fade:
            let from = layer.presentation()?.opacity ?? layer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: Self.transitionAnimationKey)

        case .slide:
            let fromX = layer.presentation()?.transform.m41 ?? layer.transform.m41
            let toX = -layer.bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeTranslation(toX, 0, 0)
            CATransaction.commit()
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = fromX
            slide.toValue = toX
            slide.duration = duration
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(slide, forKey: Self.transitionAnimationKey)

        case .zoomFade:
            let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
            let fromScale = layer.presentation()?.transform.m11 ?? layer.transform.m11
            let targetScale: CGFloat = 1.08
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            layer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = 0
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = fromScale
            scale.toValue = targetScale
            let group = CAAnimationGroup()
            group.animations = [fade, scale]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: Self.transitionAnimationKey)

        case .wipe:
            // Anchor on the trailing edge and shrink `bounds` alongside `contentsRect` with the
            // same timing curve so every visible pixel stays stationary without a mask render pass.
            let currentFrame = layer.frame
            let fromBounds = layer.presentation()?.bounds ?? layer.bounds
            let fromContentsRect = layer.presentation()?.contentsRect ?? layer.contentsRect
            let toBounds = CGRect(x: fromBounds.origin.x, y: fromBounds.origin.y, width: 0, height: fromBounds.height)
            let toContentsRect = CGRect(x: 1, y: 0, width: 0, height: 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.anchorPoint = CGPoint(x: 1, y: 0.5)
            layer.position = CGPoint(x: currentFrame.maxX, y: currentFrame.midY)
            layer.bounds = toBounds
            layer.contentsRect = toContentsRect
            CATransaction.commit()
            let boundsAnim = CABasicAnimation(keyPath: "bounds")
            boundsAnim.fromValue = NSValue(rect: fromBounds)
            boundsAnim.toValue = NSValue(rect: toBounds)
            let contentsRectAnim = CABasicAnimation(keyPath: "contentsRect")
            contentsRectAnim.fromValue = NSValue(rect: fromContentsRect)
            contentsRectAnim.toValue = NSValue(rect: toContentsRect)
            let group = CAAnimationGroup()
            group.animations = [boundsAnim, contentsRectAnim]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: Self.transitionAnimationKey)
        }
    }

    /// Starts fading the veil out; convenience wrapper for `.fade`.
    func beginFade(duration: TimeInterval) {
        beginTransition(.fade, duration: duration)
    }

    /// Takes the veil off its layer for good.
    func detach() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.mask = nil
        layer.removeFromSuperlayer()
        CATransaction.commit()
    }
}
