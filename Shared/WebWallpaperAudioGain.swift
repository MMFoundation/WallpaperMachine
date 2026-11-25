import Foundation

/// Document-start WebAudio master `GainNode` controller for web wallpapers.
///
/// WebKit's native `WKPageSetMediaVolume` scales HTML `<audio>` and `<video>` elements,
/// but leaves Web Audio (`AudioContext`) nodes untouched. This script wraps realtime
/// `window.AudioContext` and `window.webkitAudioContext` so any node connecting to
/// `ctx.destination` routes transparently through an internal master `GainNode` whose
/// gain tracks WallpaperMachine's effective volume (`muted ? 0 : volume * duckingGain`).
///
/// Two critical invariants are enforced:
/// 1. `OfflineAudioContext` / `webkitOfflineAudioContext` are NEVER wrapped or attenuated,
///    so offline waveform synthesis and audio decoding remain completely unmodified.
/// 2. `createMediaElementSource()` (and `new MediaElementAudioSourceNode(...)`) prevents
///    `v^2` double-attenuation: because `WKPageSetMediaVolume` already scales the HTML
///    media element by `v`, nodes fed purely by a `MediaElementAudioSourceNode` route
///    through an internal `mediaBypassGain` whose gain is `1` while `v > 0` (yielding
///    `v * 1 = v`, e.g. `0.5` instead of `0.25`) and `0` when `v == 0` (hard silence on
///    mute or zero volume). If `WKPageSetMediaVolume` is unavailable (`mediaScaledByHost
///    == false`), `mediaBypassGain` scales by `v` directly so volume still applies.
///
/// Zero polling and zero timers: gain updates happen only when the host evaluates
/// `setGainScript(gain:mediaScaledByHost:)` on an actual volume, mute, or ducking change.
/// Graph bookkeeping uses `WeakMap` and `WeakRef` so finished one-shot source nodes and
/// abandoned contexts are reclaimed normally by WebKit's garbage collector.
enum WebWallpaperAudioGain {
    /// Non-enumerable frozen controller exposed on `window` for host updates and tests.
    static let controllerObject = "window.__mweAudioGain"

    /// Clamps `gain` to `0...1`, treating non-finite values as unity (`1.0`).
    static func clampedGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 1 }
        return min(max(gain, 0), 1)
    }

    /// Document-start script seeded with the initial effective volume and host scaling mode.
    /// Only numeric and boolean literals are interpolated into the script source.
    static func script(initialGain: Double = 1.0, mediaScaledByHost: Bool = true) -> String {
        let gainLiteral = clampedGain(initialGain)
        let scaledLiteral = mediaScaledByHost ? "true" : "false"
        return """
        (\(scriptBody))(\(gainLiteral), \(scaledLiteral));
        """
    }

    /// Live host update evaluated ONLY when effective volume (or media scaling capability)
    /// changes. Never polls and interpolates only a finite number and boolean literal.
    static func setGainScript(gain: Float, mediaScaledByHost: Bool = true) -> String {
        let gainLiteral = clampedGain(Double(gain))
        let scaledLiteral = mediaScaledByHost ? "true" : "false"
        return "if (\(controllerObject)) { \(controllerObject).setGain(\(gainLiteral), \(scaledLiteral)); }"
    }

    private static let scriptBody = """
    (initialGain, initialMediaScaledByHost) => {
      if (\(controllerObject)) return;

      const clampGain = value =>
        typeof value === "number" && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 1;

      let effectiveGain = clampGain(initialGain);
      let mediaScaledByHost = initialMediaScaledByHost !== false;

      // Subframe coordination:
      // - Same-origin / srcdoc / about:blank child frames inherit the parent's LIVE gain and
      //   host-scaling flag immediately on document start so dynamically created or navigated
      //   subframes never stay stuck at a stale startup seed (such as initial muted: true).
      // - Cross-origin child frames cannot receive main-frame `evaluateJavaScript` pushes
      //   because `window.frames[i]` throws `SecurityError`. Leave them unwrapped so WebKit's
      //   native page mute and `WKPageSetMediaVolume` govern them without trapping them at 0.
      if (window !== window.top) {
        try {
          const parentGain = window.parent && window.parent.__mweAudioGain;
          if (parentGain && typeof parentGain.getGain === "function") {
            effectiveGain = clampGain(parentGain.getGain());
            if (typeof parentGain.isMediaScaledByHost === "function") {
              mediaScaledByHost = Boolean(parentGain.isMediaScaledByHost());
            }
          }
        } catch (_) {
          return;
        }
      }

      const desiredMasterGain = () => effectiveGain;
      // Anti-v^2 attenuation math:
      //   - When host WKPageSetMediaVolume scales HTML <audio>/<video> by v:
      //       v > 0  => mediaBypassGain = 1.0  => effective = v * 1.0 = v (not v^2)
      //       v == 0 => mediaBypassGain = 0.0  => effective = 0 * 0.0 = 0 (hard mute)
      //   - When WKPageSetMediaVolume is unavailable (mediaScaledByHost === false):
      //       mediaBypassGain = v              => effective = 1.0 * v = v
      const desiredMediaBypassGain = () =>
        mediaScaledByHost ? (effectiveGain > 0 ? 1 : 0) : effectiveGain;

      const NativeAudioContext = window.AudioContext;
      const NativeWebkitAudioContext = window.webkitAudioContext;
      const NativeOfflineAudioContext = window.OfflineAudioContext;
      const NativeWebkitOfflineAudioContext = window.webkitOfflineAudioContext;
      const NativeBaseAudioContext = window.BaseAudioContext;
      const NativeAudioNode = window.AudioNode;
      const NativeMediaElementSource = window.MediaElementAudioSourceNode;
      const NativeScriptProcessor = window.ScriptProcessorNode;
      const NativeAudioWorkletNode = window.AudioWorkletNode;

      // OfflineAudioContext / webkitOfflineAudioContext are strictly excluded and never wrapped.
      const isOfflineContext = ctx =>
        (typeof NativeOfflineAudioContext === "function" && ctx instanceof NativeOfflineAudioContext) ||
        (typeof NativeWebkitOfflineAudioContext === "function" && ctx instanceof NativeWebkitOfflineAudioContext);

      const hasWeakRef = typeof WeakRef === "function";
      const makeRef = value => (hasWeakRef ? new WeakRef(value) : { deref: () => value });

      const contextStates = new WeakMap();
      const liveContextRefs = new Set();

      const setGainValue = (gainNode, value) => {
        if (!gainNode || !gainNode.gain) return;
        try {
          const ctx = gainNode.context;
          if (ctx && ctx.state === "closed") return;
          if (typeof gainNode.gain.cancelScheduledValues === "function" && ctx) {
            gainNode.gain.cancelScheduledValues(ctx.currentTime || 0);
          }
          gainNode.gain.value = value;
        } catch (_) {}
      };

      const applyGainToAllContexts = () => {
        const master = desiredMasterGain();
        const mediaBypass = desiredMediaBypassGain();
        for (const ref of Array.from(liveContextRefs)) {
          const ctx = ref.deref();
          if (!ctx || ctx.state === "closed") {
            liveContextRefs.delete(ref);
            continue;
          }
          const state = contextStates.get(ctx);
          if (!state) {
            liveContextRefs.delete(ref);
            continue;
          }
          setGainValue(state.masterGain, master);
          setGainValue(state.mediaBypassGain, mediaBypass);
        }
      };

      const propagateToChildFrames = () => {
        const count = window.frames ? window.frames.length : 0;
        for (let i = 0; i < count; i++) {
          try {
            const child = window.frames[i];
            if (child && child.__mweAudioGain && typeof child.__mweAudioGain.setGain === "function") {
              child.__mweAudioGain.setGain(effectiveGain, mediaScaledByHost);
            }
          } catch (_) {}
        }
      };

      const nativeConnect = NativeAudioNode && NativeAudioNode.prototype && NativeAudioNode.prototype.connect;
      const nativeDisconnect = NativeAudioNode && NativeAudioNode.prototype && NativeAudioNode.prototype.disconnect;
      const nativeCreateGain =
        (NativeBaseAudioContext && NativeBaseAudioContext.prototype && NativeBaseAudioContext.prototype.createGain) ||
        (NativeAudioContext && NativeAudioContext.prototype && NativeAudioContext.prototype.createGain) ||
        (NativeWebkitAudioContext && NativeWebkitAudioContext.prototype && NativeWebkitAudioContext.prototype.createGain);

      const isMediaSource = (state, node) =>
        Boolean(
          node &&
          (state.mediaSources.has(node) ||
            (typeof NativeMediaElementSource === "function" && node instanceof NativeMediaElementSource))
        );

      const isPureWebAudioGenerator = node => {
        if (!node) return false;
        if (node.numberOfInputs === 0) return true;
        if (typeof NativeScriptProcessor === "function" && node instanceof NativeScriptProcessor) return true;
        if (typeof NativeAudioWorkletNode === "function" && node instanceof NativeAudioWorkletNode) return true;
        return false;
      };

      const liveIncomingSources = (state, node) => {
        const list = state.incoming.get(node);
        if (!list) return [];
        const sources = [];
        for (const entry of Array.from(list)) {
          const src = entry.sourceRef.deref();
          if (!src) {
            list.delete(entry);
            continue;
          }
          sources.push(src);
        }
        if (list.size === 0) state.incoming.delete(node);
        return sources;
      };

      // Walks upstream ancestors of `node` (cycle-safe) to decide whether it is fed purely by
      // MediaElementAudioSourceNode(s). Pure media-element paths route through `mediaBypassGain`
      // to avoid v^2 double-attenuation; pure WebAudio and mixed buses route through `masterGain`.
      const shouldUseMediaBypass = (state, node) => {
        let hasMedia = false;
        let hasPureWebAudio = false;
        const visited = new Set();
        const stack = [node];
        while (stack.length > 0) {
          const current = stack.pop();
          if (!current || visited.has(current)) continue;
          visited.add(current);
          if (isMediaSource(state, current)) {
            hasMedia = true;
            continue;
          }
          const parents = liveIncomingSources(state, current);
          if (parents.length === 0) {
            if (isPureWebAudioGenerator(current)) {
              hasPureWebAudio = true;
            }
          } else {
            for (const parent of parents) {
              if (!visited.has(parent)) stack.push(parent);
            }
          }
        }
        return hasMedia && !hasPureWebAudio;
      };

      const desiredDestinationTarget = (state, node) =>
        shouldUseMediaBypass(state, node) ? state.mediaBypassGain : state.masterGain;

      const destKey = (outputIndex, inputIndex) => `${outputIndex}:${inputIndex}`;

      const getNodeDestMap = (state, node, create) => {
        let map = state.nodeDestRoutes.get(node);
        if (!map && create) {
          map = new Map();
          state.nodeDestRoutes.set(node, map);
        }
        return map;
      };

      const registerReconcilableDestNode = (state, node) => {
        // 0-input non-media source nodes (e.g. one-shot AudioBufferSourceNode) can never gain
        // upstream media-element edges, so they stay in the WeakMap alone with zero retention.
        if (node.numberOfInputs === 0 && !isMediaSource(state, node)) return;
        if (state.reconcilableDestRefs.has(node)) return;
        const ref = makeRef(node);
        state.reconcilableDestRefs.set(node, ref);
        state.reconcilableDestSet.add(ref);
      };

      const unregisterReconcilableDestNode = (state, node) => {
        const ref = state.reconcilableDestRefs.get(node);
        if (ref) {
          state.reconcilableDestSet.delete(ref);
          state.reconcilableDestRefs.delete(node);
        }
      };

      const reconcileDestinations = state => {
        if (!state.hasMediaSource) return;
        for (const ref of Array.from(state.reconcilableDestSet)) {
          const node = ref.deref();
          if (!node) {
            state.reconcilableDestSet.delete(ref);
            continue;
          }
          const routes = state.nodeDestRoutes.get(node);
          if (!routes || routes.size === 0) {
            state.reconcilableDestSet.delete(ref);
            state.reconcilableDestRefs.delete(node);
            continue;
          }
          const desired = desiredDestinationTarget(state, node);
          for (const entry of routes.values()) {
            if (entry.target === desired) continue;
            try {
              nativeDisconnect.call(node, entry.target, entry.outputIndex, entry.inputIndex);
            } catch (_) {}
            try {
              nativeConnect.call(node, desired, entry.outputIndex, entry.inputIndex);
              entry.target = desired;
            } catch (_) {}
          }
        }
      };

      const addEdge = (state, source, target, outputIndex, inputIndex) => {
        if (isMediaSource(state, source) || isMediaSource(state, target)) {
          state.hasMediaSource = true;
        }
        let incomingSet = state.incoming.get(target);
        if (!incomingSet) {
          incomingSet = new Set();
          state.incoming.set(target, incomingSet);
        }
        // Prune GC'd one-shot source refs so long-lived buses never accumulate dead entries.
        for (const existing of Array.from(incomingSet)) {
          const existingSrc = existing.sourceRef.deref();
          if (!existingSrc) {
            incomingSet.delete(existing);
          } else if (
            existingSrc === source &&
            existing.outputIndex === outputIndex &&
            existing.inputIndex === inputIndex
          ) {
            return;
          }
        }
        const edge = {
          sourceRef: makeRef(source),
          targetRef: makeRef(target),
          outputIndex,
          inputIndex,
        };
        incomingSet.add(edge);
        let outgoingSet = state.outgoing.get(source);
        if (!outgoingSet) {
          outgoingSet = new Set();
          state.outgoing.set(source, outgoingSet);
        } else {
          // Prune GC'd targets so long-lived sources never accumulate dead outgoing edges.
          for (const existing of Array.from(outgoingSet)) {
            if (!existing.targetRef.deref()) {
              outgoingSet.delete(existing);
            }
          }
        }
        outgoingSet.add(edge);
      };

      const removeEdgesFrom = (state, source, predicate) => {
        const outgoingSet = state.outgoing.get(source);
        if (!outgoingSet) return false;
        let removed = false;
        for (const edge of Array.from(outgoingSet)) {
          const target = edge.targetRef.deref();
          if (!target || predicate(edge, target)) {
            outgoingSet.delete(edge);
            if (target) {
              const incomingSet = state.incoming.get(target);
              if (incomingSet) {
                incomingSet.delete(edge);
                if (incomingSet.size === 0) state.incoming.delete(target);
              }
            }
            removed = true;
          }
        }
        if (outgoingSet.size === 0) state.outgoing.delete(source);
        return removed;
      };

      const initContext = ctx => {
        if (!ctx || isOfflineContext(ctx) || contextStates.has(ctx)) return ctx;
        if (typeof nativeCreateGain !== "function" || typeof nativeConnect !== "function") return ctx;
        try {
          const realDestination = ctx.destination;
          const masterGain = nativeCreateGain.call(ctx);
          const mediaBypassGain = nativeCreateGain.call(ctx);
          setGainValue(masterGain, desiredMasterGain());
          setGainValue(mediaBypassGain, desiredMediaBypassGain());
          nativeConnect.call(masterGain, realDestination);
          nativeConnect.call(mediaBypassGain, realDestination);
          const ref = makeRef(ctx);
          const state = {
            realDestination,
            masterGain,
            mediaBypassGain,
            mediaSources: new WeakSet(),
            hasMediaSource: false,
            incoming: new WeakMap(),
            outgoing: new WeakMap(),
            nodeDestRoutes: new WeakMap(),
            reconcilableDestRefs: new WeakMap(),
            reconcilableDestSet: new Set(),
            ref,
          };
          contextStates.set(ctx, state);
          liveContextRefs.add(ref);
        } catch (_) {}
        return ctx;
      };

      if (typeof nativeConnect === "function" && typeof nativeDisconnect === "function") {
        NativeAudioNode.prototype.connect = function connect(destination, outputIndex, inputIndex) {
          const state = this && this.context ? contextStates.get(this.context) : undefined;
          if (!state) return nativeConnect.apply(this, arguments);

          const outIdx = arguments.length >= 2 && outputIndex !== undefined ? Number(outputIndex) : 0;
          const inIdx = arguments.length >= 3 && inputIndex !== undefined ? Number(inputIndex) : 0;

          if (destination === state.realDestination) {
            if (isMediaSource(state, this)) state.hasMediaSource = true;
            const targetGain = desiredDestinationTarget(state, this);
            const args = arguments.length >= 3
              ? [targetGain, outputIndex, inputIndex]
              : arguments.length >= 2
                ? [targetGain, outputIndex]
                : [targetGain];
            nativeConnect.apply(this, args);
            const routes = getNodeDestMap(state, this, true);
            routes.set(destKey(outIdx, inIdx), {
              outputIndex: outIdx,
              inputIndex: inIdx,
              target: targetGain,
            });
            registerReconcilableDestNode(state, this);
            // Spec: connect(AudioNode) returns the destination AudioNode passed by the caller.
            return destination;
          }

          const result = nativeConnect.apply(this, arguments);
          if (destination instanceof NativeAudioNode && destination.context === this.context) {
            addEdge(state, this, destination, outIdx, inIdx);
            reconcileDestinations(state);
          }
          return result;
        };

        NativeAudioNode.prototype.disconnect = function disconnect() {
          const state = this && this.context ? contextStates.get(this.context) : undefined;
          if (!state) return nativeDisconnect.apply(this, arguments);

          if (arguments.length === 0 || (arguments.length === 1 && arguments[0] === undefined)) {
            const routes = state.nodeDestRoutes.get(this);
            if (routes) routes.clear();
            state.nodeDestRoutes.delete(this);
            unregisterReconcilableDestNode(state, this);
            const removed = removeEdgesFrom(state, this, () => true);
            const result = nativeDisconnect.call(this);
            if (removed) reconcileDestinations(state);
            return result;
          }

          const first = arguments[0];
          if ((typeof first === "number" || typeof first === "string") && Number.isFinite(Number(first))) {
            const outIdx = Number(first);
            const routes = state.nodeDestRoutes.get(this);
            if (routes) {
              for (const [key, entry] of Array.from(routes.entries())) {
                if (entry.outputIndex === outIdx) routes.delete(key);
              }
              if (routes.size === 0) {
                state.nodeDestRoutes.delete(this);
                unregisterReconcilableDestNode(state, this);
              }
            }
            const removed = removeEdgesFrom(state, this, edge => edge.outputIndex === outIdx);
            const result = nativeDisconnect.apply(this, arguments);
            if (removed) reconcileDestinations(state);
            return result;
          }

          if (first === state.realDestination) {
            const routes = state.nodeDestRoutes.get(this);
            const hasOut = arguments.length >= 2 && arguments[1] !== undefined;
            const hasIn = arguments.length >= 3 && arguments[2] !== undefined;
            const outIdx = hasOut ? Number(arguments[1]) : 0;
            const inIdx = hasIn ? Number(arguments[2]) : 0;
            if (routes && routes.size > 0) {
              const matched = [];
              for (const [key, entry] of Array.from(routes.entries())) {
                if ((!hasOut || entry.outputIndex === outIdx) && (!hasIn || entry.inputIndex === inIdx)) {
                  matched.push([key, entry]);
                }
              }
              if (matched.length > 0) {
                const seenTargets = new Set();
                for (const [key, entry] of matched) {
                  routes.delete(key);
                  const targetKey = `${entry.target === state.masterGain ? "m" : "b"}:${hasOut ? outIdx : "*"}:${hasIn ? inIdx : "*"}`;
                  if (seenTargets.has(targetKey)) continue;
                  seenTargets.add(targetKey);
                  if (hasIn) {
                    nativeDisconnect.call(this, entry.target, outIdx, inIdx);
                  } else if (hasOut) {
                    nativeDisconnect.call(this, entry.target, outIdx);
                  } else {
                    nativeDisconnect.call(this, entry.target);
                  }
                }
                if (routes.size === 0) {
                  state.nodeDestRoutes.delete(this);
                  unregisterReconcilableDestNode(state, this);
                }
                return undefined;
              }
            }
            return nativeDisconnect.apply(this, arguments);
          }

          if (first instanceof NativeAudioNode) {
            const hasOut = arguments.length >= 2 && arguments[1] !== undefined;
            const hasIn = arguments.length >= 3 && arguments[2] !== undefined;
            const outIdx = hasOut ? Number(arguments[1]) : 0;
            const inIdx = hasIn ? Number(arguments[2]) : 0;
            const result = nativeDisconnect.apply(this, arguments);
            const removed = removeEdgesFrom(
              state,
              this,
              (edge, target) =>
                target === first &&
                (!hasOut || edge.outputIndex === outIdx) &&
                (!hasIn || edge.inputIndex === inIdx)
            );
            if (removed) reconcileDestinations(state);
            return result;
          }

          return nativeDisconnect.apply(this, arguments);
        };
      }

      const patchPrototype = proto => {
        if (!proto) return;
        if (typeof proto.createMediaElementSource === "function" && !proto.createMediaElementSource.__mweWrapped) {
          const nativeCreateMediaElementSource = proto.createMediaElementSource;
          const wrappedCreate = function createMediaElementSource(mediaElement) {
            const node = nativeCreateMediaElementSource.apply(this, arguments);
            const state = contextStates.get(this);
            if (state && node) {
              state.mediaSources.add(node);
              state.hasMediaSource = true;
            }
            return node;
          };
          Object.defineProperty(wrappedCreate, "__mweWrapped", { value: true });
          proto.createMediaElementSource = wrappedCreate;
        }
        if (typeof proto.close === "function" && !proto.close.__mweWrapped) {
          const nativeClose = proto.close;
          const wrappedClose = function close() {
            const state = contextStates.get(this);
            if (state) {
              liveContextRefs.delete(state.ref);
              state.reconcilableDestSet.clear();
            }
            return nativeClose.apply(this, arguments);
          };
          Object.defineProperty(wrappedClose, "__mweWrapped", { value: true });
          proto.close = wrappedClose;
        }
      };

      const wrapConstructor = NativeCtor => {
        if (typeof NativeCtor !== "function") return NativeCtor;
        if (NativeCtor === NativeOfflineAudioContext || NativeCtor === NativeWebkitOfflineAudioContext) {
          return NativeCtor;
        }
        patchPrototype(NativeCtor.prototype);
        let wrapped;
        wrapped = new Proxy(NativeCtor, {
          construct(target, args, newTarget) {
            const effectiveNewTarget = newTarget === wrapped ? target : newTarget;
            const ctx = Reflect.construct(target, args, effectiveNewTarget);
            return initContext(ctx);
          },
        });
        return wrapped;
      };

      const wrappedAudioContext = wrapConstructor(NativeAudioContext);
      if (typeof wrappedAudioContext === "function") {
        window.AudioContext = wrappedAudioContext;
      }
      if (typeof NativeWebkitAudioContext === "function") {
        window.webkitAudioContext =
          NativeWebkitAudioContext === NativeAudioContext
            ? wrappedAudioContext
            : wrapConstructor(NativeWebkitAudioContext);
      }

      const controller = Object.freeze({
        setGain(gain, scaledByHost) {
          const nextGain = clampGain(gain);
          const nextScaled = scaledByHost === undefined ? mediaScaledByHost : Boolean(scaledByHost);
          if (nextGain === effectiveGain && nextScaled === mediaScaledByHost) return;
          effectiveGain = nextGain;
          mediaScaledByHost = nextScaled;
          applyGainToAllContexts();
          propagateToChildFrames();
        },
        getGain() {
          return effectiveGain;
        },
        isMediaScaledByHost() {
          return mediaScaledByHost;
        },
        contextCount() {
          let count = 0;
          for (const ref of Array.from(liveContextRefs)) {
            const ctx = ref.deref();
            if (!ctx || ctx.state === "closed") {
              liveContextRefs.delete(ref);
            } else {
              count += 1;
            }
          }
          return count;
        },
        inspectContext(ctx) {
          const state = ctx ? contextStates.get(ctx) : undefined;
          if (!state) return null;
          return {
            tracked: true,
            masterGain: state.masterGain.gain.value,
            mediaBypassGain: state.mediaBypassGain.gain.value,
            effectiveGain,
            mediaScaledByHost,
          };
        },
        inspectNodeRoute(node) {
          const state = node && node.context ? contextStates.get(node.context) : undefined;
          if (!state) return null;
          const routes = state.nodeDestRoutes.get(node);
          if (!routes || routes.size === 0) return null;
          const first = routes.values().next().value;
          return {
            route: first.target === state.mediaBypassGain ? "mediaBypass" : "master",
            gain: first.target.gain.value,
          };
        },
      });

      Object.defineProperty(window, "__mweAudioGain", {
        value: controller,
        configurable: false,
        enumerable: false,
        writable: false,
      });
    }
    """
}
