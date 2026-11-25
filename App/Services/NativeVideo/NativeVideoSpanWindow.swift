import AVFoundation
import AppKit

/// Per-display desktop window that renders one display's sliced viewport of a multi-display spanned
/// native video by attaching a secondary `AVPlayerLayer` to the leader display's single
/// `AVQueuePlayer` (zero extra video decoder, while keeping one `NSWindow` per display so macOS
/// "Displays have separate Spaces" stays intact).
@objc(MWENativeVideoSpanDesktopWindow)
final class NativeVideoSpanFollowerWindow: NSWindow {
    let displayID: UInt32
    private weak var leader: NativeVideoPlayer?
    private var spanLayer: AVPlayerLayer?
    private var stopped = false

    var onReadyForDisplay: (@MainActor () -> Void)? {
        didSet {
            guard !stopped else { return }
            leader?.setSpanLayerReadyHandler(displayID: displayID, onReadyForDisplay)
        }
    }
    var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)?
    var onAudioDropped: (@MainActor (String) -> Void)?
    var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)?

    init(frame: NSRect, displayID: UInt32, leader: NativeVideoPlayer) {
        self.displayID = displayID
        self.leader = leader
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        configureAsDesktopVideoWindow()
        let container = NativeVideoContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        container.autoresizesSubviews = true
        container.onLayout = { [weak self] _, scale in
            self?.relayout(backingScale: scale)
        }
        contentView = container
        spanLayer = leader.attachSpanLayer(displayID: displayID, to: container)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var leaderPlayerForTest: NativeVideoPlayer? { leader }
    var spanLayerForTest: AVPlayerLayer? { spanLayer }

    private func relayout(backingScale: CGFloat) {
        guard !stopped else { return }
        leader?.relayoutSpanLayer(displayID: displayID, backingScale: backingScale)
    }
}

extension NativeVideoSpanFollowerWindow: NativeVideoSurface {
    var posterLayer: CALayer? { contentView?.layer }

    func setScreenFrame(_ frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: false) }
        relayout(backingScale: backingScaleFactor)
    }

    // Playback, audio, color options, trim range, and span geometry are owned by the leader's
    // single `AVQueuePlayer` and coordinated at the group level by `NativeVideoWallpaperHost`.
    func setVolume(_ volume: Float, muted: Bool) {}
    func setScaling(_ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {}
    func setEngineOptions(_ options: WallpaperEngineOptions, lut: VideoLut?, borderColor: CGColor?) {}
    func setTrimRange(_ range: VideoTrimRange?) {}
    func setSpanDisplays(_ displays: [DisplayConfiguration.Display], displayID: UInt32) {
        relayout(backingScale: backingScaleFactor)
    }
    func clearSpanLayout() {}
    func setUserPaused(_ paused: Bool) {}
    func setPresentationSuspended(_ suspended: Bool) {}

    var isPlaying: Bool { !stopped && (leader?.isPlaying ?? false) }
    var isReadyForDisplay: Bool { !stopped && (spanLayer?.isReadyForDisplay ?? false) }

    func posterImage() async -> CGImage? {
        guard !stopped, let leader, let slice = leader.spanSlice(for: displayID),
              let image = await leader.unflippedPosterImage()
        else { return nil }
        return DisplaySpanGeometry.composePoster(
            from: image, slice: slice, flipHorizontal: leader.isFlippedHorizontally)
    }

    var stateSummary: String {
        guard !stopped, let leader else { return "span follower detached" }
        return "span follower of \(leader.stateSummary)"
    }

    func restartPlayback(reason: String) -> Bool { false }
    func verifyPlayback(reason: String) {}
    func watchNextLoop(_ handler: @escaping @MainActor () -> Void) -> Bool {
        guard !stopped, let leader else { return false }
        return leader.watchNextLoop(forFollower: displayID, handler)
    }
    func cancelLoopWatch() {
        leader?.cancelLoopWatch(forFollower: displayID)
    }

    func present() {
        guard !stopped else { return }
        orderFrontRegardless()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onReadyForDisplay = nil
        onPreparationFailure = nil
        onAudioDropped = nil
        onHealthEvent = nil
        leader?.detachSpanLayer(displayID: displayID)
        leader = nil
        spanLayer = nil
        orderOut(nil)
        close()
    }
}
