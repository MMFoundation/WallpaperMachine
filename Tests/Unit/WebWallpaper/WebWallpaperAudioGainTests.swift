import WebKit
import XCTest

@testable import WallpaperMachine

/// Verifies the document-start WebAudio master `GainNode` injection, `OfflineAudioContext`
/// exclusion, `createMediaElementSource()` anti-`v^2` double-attenuation bypass, and
/// zero-polling live volume/mute/ducking updates in `WebWallpaperAudioOutput`.
@MainActor
final class WebWallpaperAudioGainTests: XCTestCase {
    private var views: [WKWebView] = []

    override func tearDown() async throws {
        WebWallpaperAudioOutput.webAudioGainEvaluator = nil
        WebWallpaperAudioOutput.mediaVolumeSupportOverride = nil
        for view in views {
            WebWallpaperAudioOutput.resetWebAudioGainCache(for: view)
        }
        views.removeAll()
    }

    private func makeWebView(initialGain: Double = 1.0, mediaScaledByHost: Bool = true) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperAudioGain.script(
                    initialGain: initialGain,
                    mediaScaledByHost: mediaScaledByHost),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        views.append(webView)
        webView.loadHTMLString(
            "<!doctype html><html><body><audio id=\"a\"></audio></body></html>",
            baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(webView.isLoading, "the synthetic test document did not finish loading")
        return webView
    }

    private func evaluateDict(_ webView: WKWebView, _ body: String) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(raw as? [String: Any])
    }

    func testUserScriptsIncludeWebAudioGainAtDocumentStartInAllFrames() throws {
        let seed = WebWallpaperProtocol.Seed(audioGain: 0.45, mediaVolumeScaledByHost: true)
        let expected = WebWallpaperAudioGain.script(initialGain: 0.45, mediaScaledByHost: true)
        let script = try XCTUnwrap(
            WebWallpaperProtocol.userScripts(seed: seed).first { $0.source == expected },
            "WebWallpaperProtocol.userScripts must include WebWallpaperAudioGain")
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertFalse(script.isForMainFrameOnly)
    }

    func testEffectiveVolumeComposesMuteVolumeAndDuckingSafely() {
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: 0.8, muted: false, duckingGain: 0.5), 0.4, accuracy: 0.0001)
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: 0.8, muted: true, duckingGain: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: 0.5, muted: false, duckingGain: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: 1.5, muted: false, duckingGain: 2.0), 1, accuracy: 0.0001)
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: -0.2, muted: false, duckingGain: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: .nan, muted: false, duckingGain: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(WebWallpaperAudioOutput.effectiveVolume(volume: 0.5, muted: false, duckingGain: .infinity), 0, accuracy: 0.0001)
    }

    /// Critical invariant #1: `OfflineAudioContext` and `webkitOfflineAudioContext` must NEVER be
    /// wrapped, tracked, or attenuated, so offline synthesis renders at full unmodified amplitude.
    func testOfflineAudioContextIsCompletelyExcludedAndUnattenuated() async throws {
        let webView = try await makeWebView(initialGain: 0.2, mediaScaledByHost: true)
        let result = try await evaluateDict(
            webView,
            """
            const OfflineCtor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
            const offline = new OfflineCtor(1, 256, 44100);
            const src = offline.createConstantSource();
            src.offset.value = 0.8;
            src.connect(offline.destination);
            src.start(0);
            const rendered = await offline.startRendering();
            const sample = rendered.getChannelData(0)[64];

            // Even after muting live WebAudio gain to 0, a new OfflineAudioContext stays untouched.
            window.__mweAudioGain.setGain(0, true);
            const offlineMuted = new OfflineCtor(1, 256, 44100);
            const srcMuted = offlineMuted.createConstantSource();
            srcMuted.offset.value = 0.6;
            srcMuted.connect(offlineMuted.destination);
            srcMuted.start(0);
            const renderedMuted = await offlineMuted.startRendering();
            const sampleWhileMuted = renderedMuted.getChannelData(0)[64];

            return {
              isOfflineInstance: offline instanceof OfflineCtor,
              trackedState: window.__mweAudioGain.inspectContext(offline),
              contextCount: window.__mweAudioGain.contextCount(),
              sample,
              sampleWhileMuted,
            };
            """)
        XCTAssertEqual(result["isOfflineInstance"] as? Bool, true)
        XCTAssertTrue(result["trackedState"] is NSNull || result["trackedState"] == nil)
        XCTAssertEqual(result["contextCount"] as? Int, 0)
        XCTAssertEqual(try XCTUnwrap(result["sample"] as? Double), 0.8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(result["sampleWhileMuted"] as? Double), 0.6, accuracy: 0.01)
    }

    /// Realtime `AudioContext` routes standard WebAudio nodes through the internal master
    /// `GainNode`, responds live to gain/mute updates, preserves `instanceof` / `destination`
    /// identity, and supports `disconnect(ctx.destination)` cleanly.
    func testAudioContextMasterGainTracksVolumeMuteAndDisconnectCleanly() async throws {
        let webView = try await makeWebView(initialGain: 0.5, mediaScaledByHost: true)
        let result = try await evaluateDict(
            webView,
            """
            const ctx = new window.AudioContext();
            const osc = ctx.createOscillator();
            const returnedDest = osc.connect(ctx.destination);
            const initial = window.__mweAudioGain.inspectContext(ctx);
            const initialRoute = window.__mweAudioGain.inspectNodeRoute(osc);

            window.__mweAudioGain.setGain(0.25, true);
            const ducked = window.__mweAudioGain.inspectContext(ctx);

            window.__mweAudioGain.setGain(0, true);
            const muted = window.__mweAudioGain.inspectContext(ctx);

            let disconnectError = null;
            try { osc.disconnect(ctx.destination); } catch (e) { disconnectError = String(e); }
            const routeAfterDisconnect = window.__mweAudioGain.inspectNodeRoute(osc);

            const countBeforeClose = window.__mweAudioGain.contextCount();
            await ctx.close();
            const countAfterClose = window.__mweAudioGain.contextCount();

            return {
              isAudioContext: ctx instanceof window.AudioContext,
              isNotOffline: !(window.OfflineAudioContext && ctx instanceof window.OfflineAudioContext),
              destMatches: returnedDest === ctx.destination,
              destIsNative: ctx.destination instanceof AudioDestinationNode,
              initialMaster: initial.masterGain,
              initialRoute: initialRoute.route,
              duckedMaster: ducked.masterGain,
              mutedMaster: muted.masterGain,
              disconnectError,
              routeAfterDisconnect,
              countBeforeClose,
              countAfterClose,
            };
            """)
        XCTAssertEqual(result["isAudioContext"] as? Bool, true)
        XCTAssertEqual(result["isNotOffline"] as? Bool, true)
        XCTAssertEqual(result["destMatches"] as? Bool, true)
        XCTAssertEqual(result["destIsNative"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(result["initialMaster"] as? Double), 0.5, accuracy: 0.001)
        XCTAssertEqual(result["initialRoute"] as? String, "master")
        XCTAssertEqual(try XCTUnwrap(result["duckedMaster"] as? Double), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["mutedMaster"] as? Double), 0.0, accuracy: 0.001)
        XCTAssertTrue(result["disconnectError"] is NSNull || result["disconnectError"] == nil)
        XCTAssertTrue(result["routeAfterDisconnect"] is NSNull || result["routeAfterDisconnect"] == nil)
        XCTAssertEqual(result["countBeforeClose"] as? Int, 1)
        XCTAssertEqual(result["countAfterClose"] as? Int, 0)
    }

    /// Critical invariant #2: `createMediaElementSource()` must NOT suffer `v^2` double-attenuation
    /// when `WKPageSetMediaVolume` already scales the HTML media element by `v`.
    /// At `v = 0.5`, host scaling (`0.5`) × `mediaBypassGain` (`1.0`) = `0.5` (NOT `0.25`);
    /// at `v = 0`, `mediaBypassGain` drops to `0.0` so effective output is `0`.
    func testCreateMediaElementSourceAvoidsV2DoubleAttenuationAcrossDirectChainedAndReverseGraphs() async throws {
        let webView = try await makeWebView(initialGain: 0.5, mediaScaledByHost: true)
        let result = try await evaluateDict(
            webView,
            """
            const ctx = new window.AudioContext();
            const audioEl1 = document.createElement("audio");
            const audioEl2 = document.createElement("audio");
            const audioEl3 = document.createElement("audio");

            // 1. Direct connection: mediaSrc1 -> ctx.destination
            const mediaSrc1 = ctx.createMediaElementSource(audioEl1);
            mediaSrc1.connect(ctx.destination);
            const directRouteAtHalf = window.__mweAudioGain.inspectNodeRoute(mediaSrc1);

            // 2. Chained processing: mediaSrc2 -> analyser -> filter -> ctx.destination
            const mediaSrc2 = ctx.createMediaElementSource(audioEl2);
            const analyser = ctx.createAnalyser();
            const filter = ctx.createBiquadFilter();
            mediaSrc2.connect(analyser);
            analyser.connect(filter);
            filter.connect(ctx.destination);
            const chainedRouteAtHalf = window.__mweAudioGain.inspectNodeRoute(filter);

            // 3. Reverse connection order: outputGain -> ctx.destination BEFORE mediaSrc3 -> outputGain
            const outputGain = ctx.createGain();
            outputGain.connect(ctx.destination);
            const reverseRouteBefore = window.__mweAudioGain.inspectNodeRoute(outputGain);
            const mediaSrc3 = ctx.createMediaElementSource(audioEl3);
            mediaSrc3.connect(outputGain);
            const reverseRouteAfter = window.__mweAudioGain.inspectNodeRoute(outputGain);

            // 4. Independent pure WebAudio source in the SAME AudioContext still uses masterGain (v = 0.5)
            const osc = ctx.createOscillator();
            osc.connect(ctx.destination);
            const oscRouteAtHalf = window.__mweAudioGain.inspectNodeRoute(osc);

            const v = 0.5;
            // Effective gain = hostMediaVolume(v) * route.gain for media elements, 1.0 * route.gain for pure WebAudio.
            const effectiveMediaDirectHalf = v * directRouteAtHalf.gain;
            const effectiveMediaChainedHalf = v * chainedRouteAtHalf.gain;
            const effectiveMediaReverseHalf = v * reverseRouteAfter.gain;
            const effectiveWebAudioHalf = 1.0 * oscRouteAtHalf.gain;

            // Mute / zero volume: both masterGain and mediaBypassGain drop to 0.
            window.__mweAudioGain.setGain(0, true);
            const directRouteAtZero = window.__mweAudioGain.inspectNodeRoute(mediaSrc1);
            const oscRouteAtZero = window.__mweAudioGain.inspectNodeRoute(osc);

            // Fallback when host native media volume is unavailable: mediaBypassGain scales by v directly.
            window.__mweAudioGain.setGain(0.5, false);
            const directRouteWithoutHostScaling = window.__mweAudioGain.inspectNodeRoute(mediaSrc1);

            await ctx.close();
            return {
              directRouteKind: directRouteAtHalf.route,
              chainedRouteKind: chainedRouteAtHalf.route,
              reverseRouteBeforeKind: reverseRouteBefore.route,
              reverseRouteAfterKind: reverseRouteAfter.route,
              oscRouteKind: oscRouteAtHalf.route,
              effectiveMediaDirectHalf,
              effectiveMediaChainedHalf,
              effectiveMediaReverseHalf,
              effectiveWebAudioHalf,
              directGainAtZero: directRouteAtZero.gain,
              oscGainAtZero: oscRouteAtZero.gain,
              directGainWithoutHostScaling: directRouteWithoutHostScaling.gain,
            };
            """)

        XCTAssertEqual(result["directRouteKind"] as? String, "mediaBypass")
        XCTAssertEqual(result["chainedRouteKind"] as? String, "mediaBypass")
        XCTAssertEqual(result["reverseRouteBeforeKind"] as? String, "master")
        XCTAssertEqual(result["reverseRouteAfterKind"] as? String, "mediaBypass")
        XCTAssertEqual(result["oscRouteKind"] as? String, "master")

        // v = 0.5 yields 0.5 (NOT 0.25) for every media-element topology AND for pure WebAudio.
        XCTAssertEqual(try XCTUnwrap(result["effectiveMediaDirectHalf"] as? Double), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["effectiveMediaChainedHalf"] as? Double), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["effectiveMediaReverseHalf"] as? Double), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["effectiveWebAudioHalf"] as? Double), 0.5, accuracy: 0.001)

        // v = 0 yields 0 everywhere.
        XCTAssertEqual(try XCTUnwrap(result["directGainAtZero"] as? Double), 0.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["oscGainAtZero"] as? Double), 0.0, accuracy: 0.001)

        // Without host WKPageSetMediaVolume scaling, mediaBypassGain scales directly by 0.5.
        XCTAssertEqual(try XCTUnwrap(result["directGainWithoutHostScaling"] as? Double), 0.5, accuracy: 0.001)
    }

    /// Zero polling: `WebWallpaperAudioOutput.apply` pushes JS ONLY when effective volume changes.
    func testAudioOutputPushesJavaScriptOnlyWhenEffectiveVolumeChanges() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        views.append(webView)

        var scripts: [String] = []
        WebWallpaperAudioOutput.webAudioGainEvaluator = { _, script in
            scripts.append(script)
        }

        let first = WebWallpaperAudioOutput.apply(volume: 0.8, muted: false, duckingGain: 1.0, to: webView)
        XCTAssertTrue(first.webAudioGain)
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("0.8"))

        // Identical effective volume does not re-evaluate JavaScript.
        _ = WebWallpaperAudioOutput.apply(volume: 0.8, muted: false, duckingGain: 1.0, to: webView)
        XCTAssertEqual(scripts.count, 1, "unchanged effective volume must not re-evaluate JavaScript")

        // Ducking change (0.8 * 0.5 = 0.4) pushes once.
        _ = WebWallpaperAudioOutput.apply(volume: 0.8, muted: false, duckingGain: 0.5, to: webView)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[1].contains("0.4"))

        // Equivalent product (0.4 * 1.0 = 0.4) does not re-evaluate JavaScript.
        _ = WebWallpaperAudioOutput.apply(volume: 0.4, muted: false, duckingGain: 1.0, to: webView)
        XCTAssertEqual(scripts.count, 2, "equivalent effective volume must not trigger redundant JS calls")

        // Muting pushes 0 once; repeated muted calls push nothing.
        _ = WebWallpaperAudioOutput.apply(volume: 0.4, muted: true, duckingGain: 1.0, to: webView)
        XCTAssertEqual(scripts.count, 3)
        XCTAssertTrue(scripts[2].contains("setGain(0.0,") || scripts[2].contains("setGain(0,"))
        _ = WebWallpaperAudioOutput.apply(volume: 0.9, muted: true, duckingGain: 0.3, to: webView)
        XCTAssertEqual(scripts.count, 3, "volume changes while muted keep effective gain 0 and push nothing")
    }

    /// Dynamically created same-origin/`srcdoc` child iframes inherit the parent's LIVE gain and
    /// host-scaling state on init — even when the document-start script was seeded with `0.0`
    /// during startup mute — and track subsequent `setGain` updates cleanly.
    func testDynamicSameOriginIframeInheritsLiveParentGainAfterStartupMuteAndHandlesDisconnectEdgeCases() async throws {
        let webView = try await makeWebView(initialGain: 0.0, mediaScaledByHost: true)
        let result = try await evaluateDict(
            webView,
            """
            // Simulate host unmuting after startup mute baked initialGain = 0 into the user script.
            window.__mweAudioGain.setGain(0.65, false);

            // Dynamically append a same-origin srcdoc iframe AFTER unmuting.
            const iframe = document.createElement("iframe");
            iframe.srcdoc = "<!doctype html><html><body></body></html>";
            const loaded = new Promise(resolve => { iframe.onload = resolve; });
            document.body.appendChild(iframe);
            await loaded;

            const childGain = iframe.contentWindow.__mweAudioGain;
            const childCtx = new iframe.contentWindow.AudioContext();
            const childOsc = childCtx.createOscillator();
            childOsc.connect(childCtx.destination);
            const childInitial = childGain.inspectContext(childCtx);

            // Parent live update propagates to the child iframe as well.
            window.__mweAudioGain.setGain(0.3, true);
            const childUpdated = childGain.inspectContext(childCtx);

            // Also verify disconnect(undefined) and numeric-string disconnect("0") clear routes.
            const ctx = new window.AudioContext();
            const o1 = ctx.createOscillator();
            o1.connect(ctx.destination);
            o1.disconnect(undefined);
            const afterUndefined = window.__mweAudioGain.inspectNodeRoute(o1);

            const o2 = ctx.createOscillator();
            o2.connect(ctx.destination);
            o2.disconnect("0");
            const afterNumericString = window.__mweAudioGain.inspectNodeRoute(o2);

            await childCtx.close();
            await ctx.close();
            return {
              childInitialMaster: childInitial.masterGain,
              childInitialMediaBypass: childInitial.mediaBypassGain,
              childInitialScaledByHost: childInitial.mediaScaledByHost,
              childUpdatedMaster: childUpdated.masterGain,
              childUpdatedMediaBypass: childUpdated.mediaBypassGain,
              afterUndefined,
              afterNumericString,
            };
            """)

        XCTAssertEqual(try XCTUnwrap(result["childInitialMaster"] as? Double), 0.65, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["childInitialMediaBypass"] as? Double), 0.65, accuracy: 0.001)
        XCTAssertEqual(result["childInitialScaledByHost"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(result["childUpdatedMaster"] as? Double), 0.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result["childUpdatedMediaBypass"] as? Double), 1.0, accuracy: 0.001)
        XCTAssertTrue(result["afterUndefined"] is NSNull || result["afterUndefined"] == nil)
        XCTAssertTrue(result["afterNumericString"] is NSNull || result["afterNumericString"] == nil)
    }

    /// When `WKPageSetMediaVolume` is unavailable, `WebWallpaperPage` seeds `mediaVolumeScaledByHost = false`
    /// so `mediaBypassGain` scales by `v` (not `1.0`) immediately on load without drifting across reloads.
    func testWebWallpaperPageSeedsMediaVolumeScaledByHostFalseWhenNativeMediaVolumeUnavailable() async throws {
        WebWallpaperAudioOutput.mediaVolumeSupportOverride = false

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebAudioSeedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "<!doctype html><html><body><audio id=\"a\"></audio></body></html>".write(
            to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let page = WebWallpaperPage(
            projectURL: root, entryFile: "index.html",
            surface: RuntimeSurfaceKey(kind: .desktopWeb, displayID: 1, generation: 1))
        views.append(page.webView)
        var loaded = false
        page.onLoaded = { loaded = true }
        page.applyAudioOutput(volume: 0.5, muted: false)
        page.load()

        let deadline = Date().addingTimeInterval(10)
        while !loaded && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(loaded, "WebWallpaperPage did not finish loading")

        let result = try await evaluateDict(
            page.webView,
            """
            const ctx = new window.AudioContext();
            const src = ctx.createMediaElementSource(document.getElementById("a"));
            src.connect(ctx.destination);
            const route = window.__mweAudioGain.inspectNodeRoute(src);
            const state = window.__mweAudioGain.inspectContext(ctx);
            await ctx.close();
            return {
              route: route.route,
              routeGain: route.gain,
              mediaScaledByHost: state.mediaScaledByHost,
            };
            """)
        page.stop()

        XCTAssertEqual(result["route"] as? String, "mediaBypass")
        XCTAssertEqual(result["mediaScaledByHost"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(result["routeGain"] as? Double), 0.5, accuracy: 0.001)
    }
}
