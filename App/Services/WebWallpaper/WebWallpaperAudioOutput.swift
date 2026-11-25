import Darwin
import WebKit

/// WebKit output controls leave media timelines and system-audio analysis running.
@MainActor
enum WebWallpaperAudioOutput {
    struct Capabilities: Equatable, Sendable {
        var mediaVolume: Bool
        var pageMute: Bool
        var webAudioGain: Bool

        init(mediaVolume: Bool = false, pageMute: Bool = false, webAudioGain: Bool = false) {
            self.mediaVolume = mediaVolume
            self.pageMute = pageMute
            self.webAudioGain = webAudioGain
        }
    }

    private struct WebAudioGainState: Equatable {
        let effectiveVolume: Float
        let mediaScaledByHost: Bool
    }

    private final class StateBox {
        var state: WebAudioGainState
        init(_ state: WebAudioGainState) { self.state = state }
    }

    private static let pageReference = NSSelectorFromString("_pageForTesting")
    private static let muteSetter = NSSelectorFromString("_setPageMuted:")
    private static let muteGetter = NSSelectorFromString("_mediaMutedState")
    private static let audioMutedBit: UInt = 1
    private typealias PageReference = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
    private typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    private typealias GetMuted = @convention(c) (AnyObject, Selector) -> UInt
    private typealias SetMediaVolume = @convention(c) (UnsafeRawPointer, Float) -> Void
    private static let setMediaVolume: SetMediaVolume? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "WKPageSetMediaVolume") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetMediaVolume.self)
    }()

    /// Last WebAudio master gain pushed to each `WKWebView`, held weakly so retired views are never
    /// retained. Updates execute JavaScript ONLY when effective volume (or media scaling mode)
    /// actually changes — zero polling.
    private static let pushedWebAudioGain = NSMapTable<WKWebView, StateBox>.weakToStrongObjects()

    /// Test seam overriding how the live WebAudio gain script is evaluated on a `WKWebView`.
    /// Nil uses `webView.evaluateJavaScript(script, completionHandler: nil)`.
    static var webAudioGainEvaluator: (@MainActor (_ webView: WKWebView, _ script: String) -> Void)?

    /// Test seam overriding whether native `WKPageSetMediaVolume` is reported as available.
    static var mediaVolumeSupportOverride: Bool?

    /// Returns whether WebKit's native `WKPageSetMediaVolume` is available for `webView`.
    static func supportsMediaVolume(for webView: WKWebView) -> Bool {
        if let override = mediaVolumeSupportOverride { return override }
        guard setMediaVolume != nil, webView.responds(to: pageReference),
              let implementation = webView.method(for: pageReference)
        else { return false }
        let reference = unsafeBitCast(implementation, to: PageReference.self)
        return reference(webView, pageReference) != nil
    }

    /// Computes live effective output gain: `muted ? 0 : clamped(volume) * clamped(duckingGain)`.
    nonisolated static func effectiveVolume(volume: Float, muted: Bool, duckingGain: Float = 1) -> Float {
        guard !muted, volume.isFinite, duckingGain.isFinite else { return 0 }
        let clampedVolume = min(max(volume, 0), 1)
        let clampedDucking = min(max(duckingGain, 0), 1)
        return min(max(clampedVolume * clampedDucking, 0), 1)
    }

    /// Native media volume scales HTML `<audio>` / `<video>` elements, page mute covers whole-page
    /// silence, and the injected WebAudio master `GainNode` scales realtime `AudioContext` output
    /// (excluding `OfflineAudioContext` and avoiding `v^2` double-attenuation on
    /// `createMediaElementSource()`).
    static func apply(
        volume: Float,
        muted: Bool,
        duckingGain: Float = 1,
        to webView: WKWebView,
        forceWebAudioSync: Bool = false
    ) -> Capabilities {
        var capabilities = Capabilities()
        let effective = effectiveVolume(volume: volume, muted: muted, duckingGain: duckingGain)
        let effectiveMuted = muted || effective == 0
        if mediaVolumeSupportOverride != false,
           volume.isFinite, (0...1).contains(volume),
           duckingGain.isFinite, (0...1).contains(duckingGain),
           let setMediaVolume, webView.responds(to: pageReference),
           let implementation = webView.method(for: pageReference) {
            let reference = unsafeBitCast(implementation, to: PageReference.self)
            if let page = reference(webView, pageReference) {
                setMediaVolume(page, effective)
                capabilities.mediaVolume = true
            }
        }
        if webView.responds(to: muteSetter), webView.responds(to: muteGetter),
           let setterImplementation = webView.method(for: muteSetter),
           let getterImplementation = webView.method(for: muteGetter) {
            let get = unsafeBitCast(getterImplementation, to: GetMuted.self)
            let set = unsafeBitCast(setterImplementation, to: SetMuted.self)
            let before = get(webView, muteGetter)
            // Preserve capture-device flags: wallpaper output is not microphone/camera capture.
            let after = effectiveMuted ? before | audioMutedBit : before & ~audioMutedBit
            if after != before { set(webView, muteSetter, after) }
            capabilities.pageMute = (get(webView, muteGetter) & audioMutedBit != 0) == effectiveMuted
        }
        let nextState = WebAudioGainState(
            effectiveVolume: effective,
            mediaScaledByHost: capabilities.mediaVolume)
        let previous = pushedWebAudioGain.object(forKey: webView)?.state
        if forceWebAudioSync || previous != nextState {
            pushedWebAudioGain.setObject(StateBox(nextState), forKey: webView)
            let script = WebWallpaperAudioGain.setGainScript(
                gain: effective,
                mediaScaledByHost: capabilities.mediaVolume)
            if let evaluator = webAudioGainEvaluator {
                evaluator(webView, script)
            } else {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
        capabilities.webAudioGain = true
        return capabilities
    }

    /// Records the WebAudio gain state baked into a freshly loaded document's user script so
    /// unchanged loads do not trigger redundant JavaScript evaluations while any divergence forces sync.
    static func seedWebAudioGainCache(volume: Float, mediaScaledByHost: Bool, for webView: WKWebView) {
        let clamped = volume.isFinite ? min(max(volume, 0), 1) : 0
        pushedWebAudioGain.setObject(
            StateBox(WebAudioGainState(effectiveVolume: clamped, mediaScaledByHost: mediaScaledByHost)),
            forKey: webView)
    }

    /// Clears the cached WebAudio gain state for `webView` (for example on page teardown or tests).
    static func resetWebAudioGainCache(for webView: WKWebView) {
        pushedWebAudioGain.removeObject(forKey: webView)
    }

    static func isMuted(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: muteGetter), let implementation = webView.method(for: muteGetter) else {
            return nil
        }
        let get = unsafeBitCast(implementation, to: GetMuted.self)
        return get(webView, muteGetter) & audioMutedBit != 0
    }
}
