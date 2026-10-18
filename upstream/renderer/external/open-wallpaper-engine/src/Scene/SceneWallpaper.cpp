#include "SceneWallpaper.hpp"
#include "SceneRendererHandle.hpp"
#include "SceneBackendFaults.hpp"
#include "Surface/StillPreview.hpp"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "Shader/SceneMetalVariants.hpp"
#include "SceneWallpaperSurface.hpp"
#include "SceneSourceResolver.hpp"
#include "Project/ProjectProperties.hpp"

#include "Image.hpp"
#include "Utils/Logging.h"
#include "Looper/Looper.hpp"

#include "Timer/FrameTimer.hpp"
#include "WPSceneParser.hpp"
#include "WPShaderParser.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneShader.h"
#include "Scene/SceneVertexArray.h"
#include "Particle/ParticleSystem.h"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"

#include <nlohmann/json.hpp>

#include "Fs/VFS.h"
#include "Fs/PhysicalFs.h"

#include "Audio/SoundManager.h"
#include "Audio/SoundStreamFactory.hpp"
#include "Video/VideoMedia.hpp"
#include "Video/VideoFramePacing.hpp"

#include "RenderGraph/RenderGraph.hpp"

#include "SpecTexs.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include <algorithm>
#include <atomic>
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

using namespace wallpaper;

#define CASE_CMD(cmd) \
    case CMD::CMD_##cmd: handle_##cmd(msg); break;
#define MHANDLER_CMD(cmd) void handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define MHANDLER_CMD_IMPL(cl, cmd) \
    void impl_##cl::handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define CALL_MHANDLER_CMD(cmd, msg) handle_##cmd(msg)

namespace
{
// CLEANROOM SH1
template<typename T>
std::shared_ptr<looper::Message> CreateMsgWithCmd(const std::shared_ptr<looper::Handler>&, T) {
    return nullptr;
}

} // namespace

namespace wallpaper
{
class RenderHandler;

class MainHandler : public looper::Handler {
public:
    /// Fixed width for the same reason as the render handler's: the looper
    /// carries the command as an `int32_t` and the cast back has to be defined.
    enum class CMD : int32_t
    {
        CMD_LOAD_SCENE,
        CMD_APPLY_CONFIG,
        CMD_SET_PROPERTY,
        CMD_STOP,
        CMD_FIRST_FRAME,
        CMD_POINTER_INPUT_CHANGED,
        CMD_USER_SHORTCUT,
        CMD_AUDIO_REQUIREMENT_CHANGED,
        CMD_RENDER_FAILED,
        CMD_NO
    };

public:
    MainHandler();
    virtual ~MainHandler() {};

    bool init();
    void shutdown();
    /// Before `init()`: the loopers adopt the scope when their threads start.
    void setLogScope(uint64_t scope) {
        m_main_loop->setLogScope(scope);
        m_render_loop->setLogScope(scope);
    }
    auto renderHandler() const { return m_render_handler; }
    bool inited() const { return m_inited; }

public:
    void onMessageReceived(const std::shared_ptr<looper::Message>& msg) override {
        int32_t cmd_int = (int32_t)CMD::CMD_NO;
        if (msg->findInt32("cmd", &cmd_int)) {
            CMD cmd = static_cast<CMD>(cmd_int);
            switch (cmd) {
                CASE_CMD(APPLY_CONFIG);
                CASE_CMD(SET_PROPERTY);
                CASE_CMD(LOAD_SCENE);
                CASE_CMD(STOP);
                CASE_CMD(FIRST_FRAME);
                CASE_CMD(POINTER_INPUT_CHANGED);
                CASE_CMD(USER_SHORTCUT);
                CASE_CMD(AUDIO_REQUIREMENT_CHANGED);
                CASE_CMD(RENDER_FAILED);
            case CMD::CMD_NO: break;
                // No `default`, for the same reason the render handler has
                // none: a command that is posted and never dispatched is
                // silent, and the compiler is the only thing that reliably
                // notices.
            }
        }
    }

    void sendCmdLoadScene();
    void sendFirstFrameOk();
    void sendPointerInputCapability(bool accepts_pointer_input);
    void sendUserShortcut(std::string_view property_name, std::string_view property_value);
    /// Reports scene `generation`'s audio requirement. Generations increase
    /// with every scene commit on the render thread.
    void sendAudioRequirement(uint64_t generation, bool requires_audio);
    /// Tells the host's render-failure callback that a scene which had drawn
    /// stopped after a failed frame. Posts only: it runs on the render thread.
    void sendRenderFailure();
    /// The listener a committed scene's runtime runs when it first marks
    /// itself as reading audio, on whatever thread that happens. It only posts.
    std::function<void()> audioRequirementReporter(uint64_t generation);

private:
    bool applyConfig(SceneWallpaperConfig config);
    void setPaused(bool paused);
    bool setProjectPropertyOverrideJson(std::string json);
    bool resetProjectPropertyOverride();
    /// Hands a property document to the render thread to show on the running
    /// scene (`PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON`). Touches no state that a
    /// later load reads, so the saved look is what the next load shows.
    void previewProjectProperties(const std::string& json);
    void loadScene();
    bool loadNonSceneProject(const ProjectManifest& manifest);

    MHANDLER_CMD(LOAD_SCENE);
    MHANDLER_CMD(APPLY_CONFIG);
    MHANDLER_CMD(SET_PROPERTY);
    MHANDLER_CMD(STOP);
    MHANDLER_CMD(FIRST_FRAME);
    MHANDLER_CMD(POINTER_INPUT_CHANGED);
    MHANDLER_CMD(USER_SHORTCUT);
    MHANDLER_CMD(AUDIO_REQUIREMENT_CHANGED);
    MHANDLER_CMD(RENDER_FAILED);

private:
    bool m_inited { false };

    std::unique_ptr<audio::SoundManager> m_sound_manager;
    PointerInputCallback                 m_pointer_input_callback;
    UserShortcutCallback                 m_user_shortcut_callback;
    bool                                 m_accepts_pointer_input { true };
    AudioRequirementCallback             m_audio_requirement_callback;
    RenderFailureCallback                m_render_failure_callback;
    /// Latest committed scene generation seen here, and whether that scene
    /// reads audio. Only the main looper touches these.
    uint64_t                             m_audio_requirement_generation { 0 };
    bool                                 m_requires_audio { false };

private:
    std::shared_ptr<looper::Looper> m_main_loop;
    std::shared_ptr<looper::Looper> m_render_loop;
    std::shared_ptr<RenderHandler>  m_render_handler;
};
using impl_MainHandler = MainHandler;

class RenderHandler : public looper::Handler {
public:
    /// Fixed width because commands cross the looper as an `int32_t`, so the
    /// cast back has to be defined for every value that can arrive.
    enum class CMD : int32_t
    {
        CMD_INIT_SURFACE,
        CMD_SET_SCENE,
        CMD_SET_FILLMODE,
        CMD_SET_SCALINGMODE,
        CMD_SET_SCALINGFACTOR,
        CMD_SET_FRAMING,
        CMD_SET_RENDER_SCALE,
        CMD_SET_HORIZONTAL_FLIP,
        CMD_SET_AUDIO_RESPONSE_ENABLED,
        CMD_SET_MEDIA_INTEGRATION_ENABLED,
        CMD_MEDIA_EVENT_JSON,
        CMD_SYSTEM_MEDIA_ARTWORK,
        CMD_APPLY_PROJECT_PROPERTIES,
        CMD_SET_SPEED,
        CMD_STOP,
        CMD_DRAW,
        CMD_BEGIN_SURFACE_RECONFIGURE,
        CMD_FINISH_SURFACE_RECONFIGURE,
        CMD_POSTER_REQUEST,
#ifdef WESCENE_BUILD_TESTS
        CMD_INJECT_FRAME_FAILURE,
#endif
        CMD_NO
    };
    MainHandler& main_handler;
    RenderHandler(MainHandler& m)
        : main_handler(m), m_render(std::make_unique<SceneRendererHandle>()) {
        // Installed before anything can tick: the frame clock only ever reads
        // this pointer, and the counters outlive it. The renderer is given the
        // same pointer when it is created, which is not here: no backend exists
        // until a scene has said which one it needs.
        frame_timer.SetCounters(&counters);
        {
            std::scoped_lock lock(m_content_wake->mutex);
            m_content_wake->timer = &frame_timer;
        }
        publishPauseReasons();
    }
    virtual ~RenderHandler() {
        // Before anything else: the host's poster hook can post to this
        // handler from a notification thread, and it must stop being able to
        // while the members it would reach are still alive. A scene's text
        // worker is the same kind of caller and is detached the same way; the
        // scene may still hold the target, but it no longer reaches a timer.
        unbindPosterWake();
        {
            std::scoped_lock lock(m_content_wake->mutex);
            m_content_wake->timer = nullptr;
        }
        // CLEANROOM SH2
        m_render->release();
    }

    void onMessageReceived(const std::shared_ptr<looper::Message>& msg) override {
        int32_t cmd_int = (int32_t)CMD::CMD_NO;
        if (msg->findInt32("cmd", &cmd_int)) {
            CMD cmd = static_cast<CMD>(cmd_int);
            switch (cmd) {
                CASE_CMD(DRAW);
                CASE_CMD(STOP);
                CASE_CMD(SET_FILLMODE);
                CASE_CMD(SET_SCALINGMODE);
                CASE_CMD(SET_SCALINGFACTOR);
                CASE_CMD(SET_FRAMING);
                CASE_CMD(SET_HORIZONTAL_FLIP);
                CASE_CMD(SET_AUDIO_RESPONSE_ENABLED);
                CASE_CMD(SET_MEDIA_INTEGRATION_ENABLED);
                CASE_CMD(MEDIA_EVENT_JSON);
                CASE_CMD(SYSTEM_MEDIA_ARTWORK);
                CASE_CMD(APPLY_PROJECT_PROPERTIES);
                CASE_CMD(SET_SCENE);
                CASE_CMD(SET_SPEED);
                CASE_CMD(INIT_SURFACE);
                CASE_CMD(BEGIN_SURFACE_RECONFIGURE);
                CASE_CMD(FINISH_SURFACE_RECONFIGURE);
                CASE_CMD(POSTER_REQUEST);
                CASE_CMD(SET_RENDER_SCALE);
#ifdef WESCENE_BUILD_TESTS
                CASE_CMD(INJECT_FRAME_FAILURE);
#endif
            case CMD::CMD_NO: break;
                // No `default`. Every command is named, so the compiler
                // reports the next one that is added and not dispatched —
                // which is how `SET_RENDER_SCALE` came to be posted, handled
                // and silently dropped: the handler existed, the case did not.
            }
            // Every command except the draw itself is an event that may have
            // changed what the next frame should show, so an idle scene takes
            // one. Doing this once here rather than at each call site is
            // deliberate: a command added later wakes the scene by default,
            // and the failure mode of forgetting is a redundant frame rather
            // than a wallpaper that stops responding.
            //
            // The request is dropped when the clock is stopped, so this cannot
            // resume a paused wallpaper, and it coalesces with any frame
            // already pending.
            //
            // A cover is the one exception, because it is the one command that
            // routinely carries no change at all: every new scene handle is
            // replayed the current cover, and a replay that wakes the scene
            // would make the blanket rule cost a frame per display added, per
            // wallpaper switched, per reconcile. Its handler requests a frame
            // when — and only when — the pixels actually moved.
            if (cmd != CMD::CMD_DRAW && cmd != CMD::CMD_SYSTEM_MEDIA_ARTWORK) requestFrame();
        }
    }

    bool renderInited() const { return m_render->inited(); }

    /// Whether a surface has been handed over, whether or not a backend has
    /// been created on it yet.
    ///
    /// Scene loading is gated on this rather than on `renderInited()`: which
    /// backend a scene needs is read off the parsed scene, so waiting for a
    /// renderer before parsing would wait for something parsing has to produce.
    [[nodiscard]] bool renderSurfaceReady() const {
        return m_render_init_info != nullptr || m_render->inited();
    }

    /// Tells the frame clock whether this scene's content is still changing: it
    /// keeps its configured cadence while it is, and waits for an event or a
    /// deadline once the scene proves it is still.
    ///
    /// Runs on the render thread; the frame clock only reads the value it
    /// stores.
    void refreshFrameDemand() {
        FrameTimer::FrameDemand demand {};

        const SceneUpdateDemand update = evaluateSceneUpdateDemand();
        m_scene_demand_reasons.store(update.reasons, std::memory_order_relaxed);
        // Recorded even while the scene is continuous, so the flag is already
        // correct the instant it becomes idle rather than one frame late.
        m_scene_wants_pointer.store(
            renderInited() &&
                SceneShaderInputsUsePointer(m_render->ShaderUpdateDemandReasons()),
            std::memory_order_relaxed);
        switch (update.kind) {
        case SceneUpdateDemand::Kind::WaitingForEvent:
            demand.kind = FrameTimer::FrameDemand::Kind::Idle;
            break;
        case SceneUpdateDemand::Kind::WaitingForDeadline:
            demand.kind     = FrameTimer::FrameDemand::Kind::Timed;
            demand.deadline = update.deadline;
            break;
        case SceneUpdateDemand::Kind::Continuous:
            demand.kind = FrameTimer::FrameDemand::Kind::Continuous;
            break;
        }
        m_scene_update_kind.store(update.kind, std::memory_order_relaxed);
        frame_timer.SetFrameDemand(demand);
    }

    /// Whether this scene still needs the clock, and why.
    ///
    /// Runs on the render thread after a frame, when the runtime's registries
    /// and the renderer's compiled graph both describe the state the next frame
    /// would start from. Every path that cannot prove stillness returns
    /// `Continuous`, including every early return: the switch being off, no
    /// scene, no renderer, and a scene that has not yet presented a frame.
    [[nodiscard]] SceneUpdateDemand evaluateSceneUpdateDemand() const {
        // CLEANROOM SH57
        SceneUpdateDemand demand {};
        demand.kind    = SceneUpdateDemand::Kind::Continuous;
        demand.reasons = static_cast<uint32_t>(SceneDemandReason::UnknownInput);
        return demand;
    }

    /// Creates the renderer that draws this scene, and is the only place that
    /// does so for a scene.
    ///
    /// Runs once per scene, after the scene is parsed and before its graph is
    /// built, because whether the scene can be drawn depends on what it
    /// contains -- which is also why nothing is created before this point. The
    /// selection is published only once the renderer exists, so the host never
    /// names a renderer that is not drawing.
    void selectSceneBackend() {
        if (m_scene == nullptr || m_render_init_info == nullptr) return;

        auto selection = metal::SelectSceneBackend(*m_scene);
#ifdef WESCENE_BUILD_TESTS
        if (auto forced = testing::SceneBackendFaults::Instance().Consume(
                testing::SceneBackendFault::Admission)) {
            selection = metal::NativeRefusal(*forced);
        }
#endif

        // Refused, and nothing else may draw it instead. No renderer is
        // created: not another one, and not a native one that would only have
        // been torn down again.
        if (selection.failed()) {
            holdFailedScene(selection.failure_stage, selection.failure_reason);
            return;
        }

        // A renderer already driving this surface is reused: a wallpaper switch
        // invalidates the scene, not the device or the drawable loop, and
        // rebuilding one that works costs a visible gap for nothing.
        if (m_render->hasBackend() && m_render->inited()) {
            setSceneBackendSelection(selection);
            return;
        }
        std::string error;
        if (m_render->createMetal(*m_render_init_info, error)) {
            setSceneBackendSelection(selection);
            reapplySurfaceState();
            return;
        }
        // Prepare failed, and the handle is empty. Nothing else may draw the
        // scene, so the failure is held and reported with its reason.
        if (error.empty()) error = "the native renderer could not be prepared";
        holdFailedScene(SceneFailureStage::Prepare, error);
    }

    /// A scene that cannot be drawn with the native backend: nothing else may
    /// draw it, so the surface keeps what it shows, the failure is said once,
    /// and rendering stops. The picture on a layer that has already drawn is its
    /// last frame, which the layer holds on its own; a layer that has drawn
    /// nothing gets the project's preview picture instead of staying black.
    ///
    /// The host is told a first picture exists even then: it waits for one, and
    /// without it the activation would sit out the host's whole first-frame
    /// deadline and then put the previous wallpaper back, which is a rollback
    /// the user never asked for and a failure nobody can read.
    void holdFailedScene(SceneFailureStage stage, std::string reason) {
        // A refused scene must not be drawn by a renderer that is still alive
        // from the scene it replaced: the next surface rebuild would compile
        // the refused scene on it and draw it natively, which is the silent
        // drawing this policy exists to stop. The layer keeps the last picture
        // on its own, so releasing the renderer costs the held picture
        // nothing. (A failed prepare has already released it.)
        if (stage == SceneFailureStage::Unsupported) {
            m_render->release();
            m_rg.reset();
        }
        reportFailure(stage, std::move(reason));
        suspendAfterGraphFailure();
        settleFailedScene();
    }

    /// Latches the failure, publishes it to the host and logs it. Once per
    /// failure: the first reason is the root cause, and a retry that fails
    /// again is a new failure only after `clearFailure`.
    void reportFailure(SceneFailureStage stage, std::string reason) {
        if (m_failure_stage != SceneFailureStage::None) return;
        if (reason.empty()) reason = "the native renderer could not draw this wallpaper";
        m_failure_stage = stage;
        SceneBackendSelection selection;
        selection.failure_stage  = stage;
        selection.failure_reason = std::move(reason);
        setSceneBackendSelection(std::move(selection));
    }

    /// What a held failure leaves on the surface, and what the host is told.
    /// Safe to call again for the same failure.
    void settleFailedScene() {
        if (m_failure_stage == SceneFailureStage::None || m_scene == nullptr) return;
        showStillIfNothingDrawn();
        if (! m_failure_first_frame_sent && ! m_scene->first_frame_ok) {
            m_failure_first_frame_sent = true;
            main_handler.sendFirstFrameOk();
        }
    }

    /// The project's preview picture on a layer that has drawn nothing. A layer
    /// that has drawn keeps its last frame, so it is left exactly as it is.
    void showStillIfNothingDrawn() {
        if (m_layer_has_picture || m_scene == nullptr) return;
        if (m_render_init_info == nullptr || m_render_init_info->metal_layer == nullptr) return;
        const auto image = surface::FindPreviewImage(m_scene->project_path);
        if (image.empty()) {
            LOG_INFO("no preview picture to show for the wallpaper that cannot be drawn: %s",
                     m_scene->project_path.c_str());
            return;
        }
        std::string error;
        if (! m_still.Show(m_render_init_info->metal_layer, image, error)) {
            LOG_INFO("preview picture not shown: %s", error.c_str());
        }
    }

    /// The failure is over: a renderer is about to draw this scene again. The
    /// preview picture stays until a real frame replaces it, so a recovery
    /// never opens a black gap.
    void clearFailure() {
        if (m_failure_stage == SceneFailureStage::None) return;
        m_failure_stage = SceneFailureStage::None;
        std::scoped_lock lock(m_backend_selection_mutex);
        if (! m_backend_selection.failed()) return;
        m_backend_selection = SceneBackendSelection {};
        if (m_render->hasBackend()) m_backend_selection.created = true;
    }

    /// Re-applies the surface state a newly created renderer does not inherit.
    ///
    /// Creating a renderer produces an object that holds none of the scaling,
    /// flip, playback rate, pause or counter state the settings commands have
    /// already recorded, so every one of them has to be pushed again. Pause in
    /// particular: a wallpaper the user paused must not start playing because
    /// its renderer was created after the pause.
    void reapplySurfaceState() {
        m_render->SetCounters(&counters);
        // CLEANROOM SH3
        m_render->SetWallpaperFraming(m_framing);
        m_render->SetVideoPlaybackPaused(! frame_timer.Running() || m_render_blocked);
        // Seeds the scale the next compile allocates its render targets at, so
        // a backend created after a render-scale change does not start at full
        // size. The rest of the compiled-graph state — the fill mode, and the
        // scale applied to targets that already exist — belongs to
        // `rebuildRenderGraph`, which every creation path runs straight after
        // this.
        if (m_scene != nullptr) {
            m_scene->render_scale = m_render_scale;
            m_scene->resolution   = CurrentSceneResolution();
        }
    }

    /// Asks for one frame because something outside the clock changed.
    ///
    /// Coalescing is inherent: the clock holds at most one pending request and
    /// at most one draw in flight, so a burst of property writes produces one
    /// frame, not one frame each. Whether the clock keeps running afterwards is
    /// decided by that frame's own demand, not here.
    void requestFrame() { frame_timer.RequestFrame(); }

    /// Lets a scene's own background work ask for a frame without knowing
    /// anything about this handler's lifetime.
    ///
    /// A worker thread can be inside the handler while this handler is being
    /// torn down, so the indirection is a shared target rather than a captured
    /// `this`: the destructor clears the timer under the same mutex the handler
    /// takes, and after that no wake reaches anything. The scene may still hold
    /// the target, which is exactly why the target outlives the handler.
    ///
    /// A scene being replaced can leave one wake in flight for a wallpaper that
    /// is already gone. The cost is a single redundant frame of the new one,
    /// which is the same trade the per-command request makes.
    struct ContentWakeTarget {
        std::mutex   mutex;
        FrameTimer*  timer { nullptr };
    };

    void installContentWake(Scene& scene) {
        if (scene.runtime == nullptr) return;
        auto target = m_content_wake;
        scene.runtime->SetContentWakeHandler([target] {
            std::scoped_lock lock(target->mutex);
            if (target->timer != nullptr) target->timer->RequestFrame();
        });
    }

    /// Why this surface is not presenting, as independent bits. Recomputed on
    /// every transition that can change one of them, so a stopped surface can
    /// be told apart from a surface whose renderer was taken away.
    void publishPauseReasons() {
        uint64_t reasons = OWE_RC_PAUSE_NONE;
        if (! frame_timer.Running()) reasons |= OWE_RC_PAUSE_CLOCK_STOPPED;
        if (m_render_blocked || ! renderInited()) reasons |= OWE_RC_PAUSE_RENDER_BLOCKED;
        if (m_scene == nullptr) reasons |= OWE_RC_PAUSE_NO_SCENE;
        counters.Set(OWE_RC_PAUSE_REASONS, reasons);
    }

    struct MouseButtonSnapshot {
        uint32_t down { 0 };
        uint32_t pressed { 0 };
        uint32_t released { 0 };
    };

    void setMousePos(double x, double y) {
        // CLEANROOM SH4
        (void)x;
        (void)y;
        wakeForPointer();
    }

    /// Pointer movement is the one event that never passes through the looper,
    /// so an idle scene has to be woken here explicitly.
    ///
    /// Gated on the scene actually consuming the pointer. Waking on every
    /// mouse move regardless would give a still wallpaper a frame rate equal
    /// to the pointer sample rate, which is worse than not idling at all.
    /// Scenes whose scripts read the cursor are never idle in the first place,
    /// because a script is itself a reason to keep ticking.
    void wakeForPointer() {
        if (! m_scene_wants_pointer.load(std::memory_order_relaxed)) return;
        requestFrame();
    }
    void setMouseButton(int button, bool pressed) {
        // CLEANROOM SH5
        (void)button;
        (void)pressed;
        wakeForPointer();
    }
    void setMouseButtonBaseline(uint32_t down) {
        // CLEANROOM SH6
        m_mouse_buttons.down = down;
    }
    void setMouseInWindow(bool entered) {
        m_cursor_in_window.store(entered);
        wakeForPointer();
    }

    /// Stages the newest property document to show on the running scene
    /// (`PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON`). Latest wins: a document
    /// staged before the render thread has taken the previous one replaces it,
    /// so a burst of edits costs one update on this thread instead of one each.
    /// Returns whether the slot was empty; only then is no
    /// `CMD_APPLY_PROJECT_PROPERTIES` already on its way to take the document,
    /// and the caller posts one. Callable from any thread.
    [[nodiscard]] bool stageProjectPropertyPreview(ProjectProperties document) {
        std::scoped_lock lock(m_property_preview_mutex);
        const bool       was_empty = ! m_property_preview.has_value();
        m_property_preview         = std::move(document);
        return was_empty;
    }

private:
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif
    MouseButtonSnapshot consumeMouseButtonSnapshot() {
        // CLEANROOM SH7
        return {};
    }

    void suspendRendering() {
        m_render_blocked = true;
        frame_timer.Stop();
        publishPauseReasons();
    }

    /// Stops rendering because the graph or the backend under it failed, which
    /// nobody asked for. The host sees the difference from a pause: a stop the
    /// host started itself (a surface being reconfigured) goes through
    /// `suspendRendering` alone and is never reported as a failure.
    void suspendAfterGraphFailure() {
        m_health.NoteGraphFailed();
        suspendRendering();
    }

    /// The surface may draw again. The only place `m_render_blocked` is
    /// lowered, so the failure latch the host reads can never outlive the
    /// block it describes.
    void clearRenderBlock() {
        m_render_blocked = false;
        m_health.ClearStop();
        clearFailure();
    }

    /// A frame failed and nobody asked for the stop. Counts it, latches the
    /// reason the host reads, stops rendering and, for a scene that had drawn
    /// before, tells the host so it can rebuild the surface.
    ///
    /// `reached_draw` is whether the failure came from the draw itself rather
    /// than from building the graph, which has already reported its own.
    /// A scene that never presented a frame does not call back: the host is
    /// still waiting for that first frame and has its own timeout and rollback
    /// for it, and a recovery of its own would race that wait. The call is a
    /// post, so it never runs host code on this thread, and it is made after
    /// rendering has stopped so the host cannot observe a still-running
    /// surface.
    void failFrame(bool reached_draw) {
        counters.Add(OWE_RC_RENDER_FAILURES);
        if (reached_draw) {
            m_health.NoteFrameFailed();
        } else {
            m_health.NoteGraphFailed();
        }
        suspendRendering();
        if (reached_draw && m_scene != nullptr && m_scene->first_frame_ok)
            main_handler.sendRenderFailure();
    }

    /// Runs the frame clock exactly when there is something for it to drive:
    /// a loaded scene, rendering not blocked, and no pause asked for. Before
    /// a scene lands, and after a load that never delivered one, there is
    /// nothing to draw, so the clock thread does not exist. The looper keeps
    /// running either way, so control messages and the first-frame draw that
    /// follows a scene still arrive.
    void syncFrameClock() {
        if (m_clock_requested && ! m_render_blocked && m_scene != nullptr)
            frame_timer.Run();
        else
            frame_timer.Stop();
    }

    /// Retains a surface description and moves the host's poster wake hook onto
    /// it.
    ///
    /// The previous info's hook is dropped first, so a notification raised
    /// against a layer that is gone cannot post work about the new one. The
    /// host holds its own lock across both halves, which is what keeps an
    /// in-flight notification from poking a handler that has unbound.
    void adoptRenderInitInfo(std::shared_ptr<RenderInitInfo> info) {
        unbindPosterWake();
        // A layer the display replaced carries nothing the old one drew, and
        // the preview picture went with the old one.
        if (m_render_init_info == nullptr || info == nullptr ||
            m_render_init_info->metal_layer != info->metal_layer) {
            m_layer_has_picture = false;
            m_still.Hide();
        }
        m_render_init_info = std::move(info);
        if (! m_render_init_info->bind_poster_wake) return;
        std::weak_ptr<looper::Handler> weak_self = weak_from_this();
        m_render_init_info->bind_poster_wake([weak_self] {
            auto self = weak_self.lock();
            if (self == nullptr) return;
            CreateMsgWithCmd(self, CMD::CMD_POSTER_REQUEST)->post();
        });
    }
    void unbindPosterWake() {
        if (m_render_init_info == nullptr || ! m_render_init_info->bind_poster_wake) return;
        m_render_init_info->bind_poster_wake({});
    }

    bool rebuildRenderGraph() {
        // CLEANROOM SH8
        return true;
    }

    /// Records `json` as the latest event of its type, keeping the order the
    /// types first arrived so a replay reaches a script in the same sequence a
    /// live session would.
    void retainMediaEvent(const std::string& json) {
        const auto parsed = nlohmann::json::parse(json, nullptr, false);
        if (parsed.is_discarded() || ! parsed.is_object()) return;
        const auto type = parsed.find("type");
        if (type == parsed.end() || ! type->is_string()) return;
        const auto name = type->get<std::string>();
        for (auto& retained : m_pending_media_events) {
            if (retained.first == name) {
                retained.second = json;
                return;
            }
        }
        // An unbounded set of types would be a leak; the protocol has five and
        // a wallpaper that invents more does not get to grow this forever.
        if (m_pending_media_events.size() >= 16) return;
        m_pending_media_events.emplace_back(name, json);
    }

    /// Replays what is playing to a scene that has just been attached.
    void replayMediaEvents() {
        // CLEANROOM SH10
    }
    /// Publishes the display's pixel resolution to the scene's scripts.
    ///
    /// `RenderInitInfo::width`/`height` are already physical pixels -- the host
    /// fills them from `DisplayDesc`, and the renderer divides by
    /// `display_scale_factor` when they want logical points -- so they are
    /// published as they are. Not the render size: internal quality may halve
    /// that, and a quality setting must not move a script's layout.
    void publishScreenResolution() {
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        if (m_render_init_info == nullptr) return;
        m_scene->runtime->SetScreenResolution(
            linalg::Vector2f(static_cast<float>(m_render_init_info->width),
                            static_cast<float>(m_render_init_info->height)));
    }

    MHANDLER_CMD(STOP) {
        // CLEANROOM SH11
    }
    MHANDLER_CMD(DRAW) {
        // CLEANROOM SH12
    }
    MHANDLER_CMD(SET_FILLMODE) {
        // CLEANROOM SH13
    }
    MHANDLER_CMD(SET_SCALINGMODE) {
        // CLEANROOM SH14
    }
    MHANDLER_CMD(SET_SCALINGFACTOR) {
        // CLEANROOM SH15
    }
    MHANDLER_CMD(SET_FRAMING) {
        std::shared_ptr<WallpaperFraming> value;
        if (msg->findObject("value", &value) && value != nullptr) {
            m_framing = NormalizeWallpaperFraming(*value);
            if (renderInited()) {
                m_render->SetWallpaperFraming(m_framing);
            }
        }
    }
    MHANDLER_CMD(SET_RENDER_SCALE) {
        // CLEANROOM SH16
    }
    MHANDLER_CMD(SET_HORIZONTAL_FLIP) {
        // CLEANROOM SH17
    }
    MHANDLER_CMD(SET_AUDIO_RESPONSE_ENABLED) {
        // CLEANROOM SH18
    }
    MHANDLER_CMD(SET_MEDIA_INTEGRATION_ENABLED) {
        // CLEANROOM SH19
    }
    MHANDLER_CMD(MEDIA_EVENT_JSON) {
        // CLEANROOM SH20
    }
    MHANDLER_CMD(SYSTEM_MEDIA_ARTWORK) {
        // CLEANROOM SH9
    }
    MHANDLER_CMD(SET_SCENE) {
        // CLEANROOM SH21
    }
    MHANDLER_CMD(SET_SPEED) {
        // CLEANROOM SH22
    }
    /// Shows the newest staged property document on the scene that is running,
    /// without loading it again. Runs here because this thread is the only one
    /// that ticks the runtime, so the runtime needs no lock for it.
    ///
    /// Nothing is remembered for a later scene: a scene committed afterwards
    /// shows its own loaded values until the host sends the next document, so a
    /// document for one wallpaper can never reach another by sharing a property
    /// name. A document that finds no scene, or a scene without a runtime (a
    /// plain video), is dropped.
    ///
    /// What a changed property shows needs nothing more from here. The command
    /// asks for a frame like every command but the draw, so an idle scene
    /// takes one and a paused one shows it when it resumes; that frame's tick
    /// applies the bindings, and a layer the document reveals that the graph
    /// left out asks for one new graph there (`RequestGraphForShownLayers`).
    MHANDLER_CMD(APPLY_PROJECT_PROPERTIES) {
#ifdef WESCENE_BUILD_TESTS
        m_property_preview_commands.fetch_add(1, std::memory_order_relaxed);
#endif
        std::optional<ProjectProperties> document;
        {
            std::scoped_lock lock(m_property_preview_mutex);
            document = std::move(m_property_preview);
            m_property_preview.reset();
        }
        if (! document.has_value()) return;
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        const auto preview = m_scene->runtime->PreviewProjectPropertyOverride(*document);
        // Said when the set of properties the scene could not apply changes, not
        // on every edit: a drag sends many documents that all defer the same few.
        if (preview.deferred != m_logged_deferred_properties) {
            m_logged_deferred_properties = preview.deferred;
            if (! preview.deferred.empty()) {
                std::string names;
                for (const auto& name : preview.deferred) {
                    names += (names.empty() ? "" : ", ") + name;
                }
                LOG_INFO("property preview: held at the loaded value until the scene loads "
                         "again: %s",
                         names.c_str());
            }
        }
    }
    /// Takes over a surface description. No GPU renderer is created here.
    ///
    /// Whether the scene can be drawn is decided from the parsed scene, so
    /// building a renderer now would mean tearing it down again the moment the
    /// scene turns out to be refused.
    MHANDLER_CMD(INIT_SURFACE) {
        // CLEANROOM SH23
    }
    /// Completes a desktop poster request that arrived from outside the clock.
    ///
    /// Deliberately does not touch the clock or scene time: a wallpaper the
    /// user paused stays paused, and an idle one is sampled rather than
    /// re-simulated. The single frame this may need is the one the generic
    /// post-command `requestFrame()` already asks for, and that request is
    /// dropped while the clock is stopped.
    MHANDLER_CMD(POSTER_REQUEST) {
        // Nothing to service yet, or nothing valid to read back: the request
        // stays pending in the host's mailbox and the first drawn frame polls
        // it. `m_render_blocked` covers a surface mid-reconfigure; a wallpaper
        // the user merely paused is not blocked and is still sampled.
        if (! m_render->hasBackend() || m_scene == nullptr || m_render_blocked) return;
        switch (m_render->ServicePosterRequest(*m_scene)) {
        case metal::PosterServiceResult::Failed:
            // The scene still draws, only this export failed, and the mailbox's
            // own backoff decides when to try again.
            LOG_ERROR("desktop poster export failed: %s", m_render->lastError().c_str());
            break;
        case metal::PosterServiceResult::NoFrameYet:
        case metal::PosterServiceResult::NotRequested:
        case metal::PosterServiceResult::Submitted:
        case metal::PosterServiceResult::Busy:
            break;
        }
    }
#ifdef WESCENE_BUILD_TESTS
    /// What a draw that fails after the scene has drawn does, without needing
    /// the GPU to fail.
    MHANDLER_CMD(INJECT_FRAME_FAILURE) {
        failFrame(true);
        refreshFrameDemand();
    }
#endif
    MHANDLER_CMD(BEGIN_SURFACE_RECONFIGURE) {
        // CLEANROOM SH24
    }
    MHANDLER_CMD(FINISH_SURFACE_RECONFIGURE) {
        // CLEANROOM SH25
    }

public:
    FrameTimer       frame_timer;
    /// Whether the host wants this surface playing. The clock runs only while
    /// this holds and a scene is loaded; see `syncFrameClock`. Render thread.
    bool             m_clock_requested { true };
    /// Handed to every scene's runtime so its text worker can ask for the frame
    /// that shows what it produced. Declared here, after `frame_timer`, so it
    /// is destroyed before the timer it points at.
    std::shared_ptr<ContentWakeTarget> m_content_wake { std::make_shared<ContentWakeTarget>() };
    /// The regenerable shader cache the current scene was loaded against.
    /// Delivered with the scene and read only on this thread.
    std::string m_shader_cache_path;
    /// Written by the frame clock, the render thread and the decode thread;
    /// read by whoever asks for a snapshot. The destructor stops the frame
    /// clock and destroys the renderer before any member is destroyed, so no
    /// writer outlives it.
    RendererCounters counters;

    /// Live update mode and the reasons behind it.
    ///
    /// Pull-only and always available: this is state a settings pane shows, so
    /// it must not depend on diagnostic counting being switched on. Reports
    /// `Continuous` with no reasons while on-demand updating is off, because
    /// that is then the literal truth rather than a placeholder.
    [[nodiscard]] SceneUpdateDemand::Kind sceneUpdateKind() const {
        return m_scene_update_kind.load(std::memory_order_relaxed);
    }
    [[nodiscard]] uint32_t sceneDemandReasons() const {
        return m_scene_demand_reasons.load(std::memory_order_relaxed);
    }

    /// Always-on frame-loop health; see `SurfaceHealth`. Written by the render
    /// thread, read by the host without one.
    [[nodiscard]] SurfaceHealthSnapshot surfaceHealth() const {
        return m_health.Snapshot();
    }

    /// Published by the render thread after each drawn frame, read by the host
    /// without one.
    [[nodiscard]] SceneVideoPath videoPath() const {
        return static_cast<SceneVideoPath>(m_video_path.load(std::memory_order_relaxed));
    }

    /// Whether this wallpaper's compiled graph is running under the current
    /// scene optimisation setting, as opposed to still carrying the plan the
    /// previous value produced.
    [[nodiscard]] bool sceneOptimizationApplied() const {
        return m_scene_optimization_applied.load(std::memory_order_relaxed) ==
               render::SceneOptimizationEnabled();
    }

    /// Which renderer drew this scene. Published when the renderer is created,
    /// never before: until then `created` is false and the host reports that it
    /// is still preparing rather than naming a backend.
    [[nodiscard]] SceneBackendSelection sceneBackendSelection() const {
        std::scoped_lock lock(m_backend_selection_mutex);
        return m_backend_selection;
    }
    void setSceneBackendSelection(SceneBackendSelection selection) {
        // Every caller publishes a backend that exists, so the flag is set here
        // rather than at each site, where forgetting it would silently report
        // "preparing" for the rest of the wallpaper's life.
        selection.created = true;
        if (selection.failed()) {
            // Once per failure, at error level: this is the line a user quotes
            // when a wallpaper shows a still picture, or stops on its last
            // frame, instead of playing.
            LOG_ERROR("scene cannot be drawn with native Metal (%s): %s; holding the %s",
                      ToString(selection.failure_stage),
                      selection.failure_reason.c_str(),
                      m_layer_has_picture ? "last frame" : "preview picture");
        } else {
            // Once per scene: the first thing to know about a wallpaper that looks
            // wrong is whether a renderer is drawing it.
            LOG_INFO("scene backend: native_metal");
        }
        std::scoped_lock lock(m_backend_selection_mutex);
        m_backend_selection = std::move(selection);
    }

    /// Starts the just-committed scene's audio-requirement generation: the
    /// host hears `false` for a scene that has not (yet) marked itself, and
    /// then one `true` when it does -- at parse, at shader init or from a
    /// script, whichever comes first. The listener is installed before the
    /// flag is read so a mark racing the commit is reported by one or both.
    /// Scenes without a runtime (plain video projects) never mark.
    void commitAudioRequirement() {
        // CLEANROOM SH26
    }

private:
    std::shared_ptr<Scene> m_scene { nullptr };
    /// Bumped on every scene commit; the main looper drops audio-requirement
    /// reports carrying an older one.
    uint64_t               m_audio_requirement_generation { 0 };

    std::unique_ptr<SceneRendererHandle> m_render;
    /// Why this scene is held without a renderer drawing it, or `None`. Render
    /// thread only; the host reads the published copy in `m_backend_selection`.
    SceneFailureStage                    m_failure_stage { SceneFailureStage::None };
    /// Whether the host has been told a first picture exists for the scene
    /// whose failure is being held, so it is told once.
    bool                                 m_failure_first_frame_sent { false };
    /// Whether the surface's current layer has had a real frame presented on it
    /// (or is about to keep one). A layer that has is held on that frame; one
    /// that has not shows the preview picture.
    bool                                 m_layer_has_picture { false };
    /// The preview picture shown instead of a frame nothing could draw.
    surface::StillPreview                m_still;
    /// Retained from `INIT_SURFACE` so the renderer can be created, or
    /// re-created, on the same surface once the scene is known to be drawable.
    std::shared_ptr<RenderInitInfo>      m_render_init_info;
    std::unique_ptr<rg::RenderGraph>      m_rg { nullptr };
    bool                                m_render_blocked { false };
    /// Whether the frame loop is alive and why it stopped. Unlike the
    /// counters, never gated: a stop nobody can see cannot be told apart from
    /// a pause.
    SurfaceHealth                       m_health;

    /// Where the presented image sits in the slack around it. Held here, not
    /// in a backend, so it outlives a backend change, a surface rebuild and a
    /// graph rebuild like the scaling mode and factor beside it.
    WallpaperFraming                         m_framing {};
    /// Internal rasterization scale, independent of `m_scalingfactor`: that one
    /// scales the presented image on the output, this one only changes how many
    /// pixels the scene is drawn with.
    float                                    m_render_scale { 1.0f };
    /// The path the last drawn frame's video textures took, as the enumerator's
    /// underlying value so it can live in an atomic.
    std::atomic<uint8_t>                     m_video_path { 0 };
    /// The scene optimisation setting the compiled graph was last applied for.
    /// Starts matching the default so a wallpaper that never sees the setting
    /// change never rebuilds anything. Atomic because the render thread writes
    /// it and the host reads it to tell a saved preference apart from one that
    /// is actually in force.
    std::atomic<bool>                        m_scene_optimization_applied {
        render::SceneOptimizationEnabled()
    };
    /// The latest media event of each type, in the order the types first
    /// arrived.
    ///
    /// A scene being rebuilt has no runtime for a moment, and that is exactly
    /// when the host replays what it knows: it replays because the handle is
    /// new. The artwork already survives that window by being parked here; the
    /// events describing what is playing did not, so a wallpaper whose cover
    /// group is revealed by `mediaPlaybackChanged` stayed blank until the user
    /// pressed pause and play again. Latest-per-type, because a burst of
    /// timeline updates is one fact repeated, not a queue to drain.
    std::vector<std::pair<std::string, std::string>> m_pending_media_events {};
    /// The newest property document waiting to be shown (see
    /// `stageProjectPropertyPreview`). Not part of the scene: it is taken by the
    /// command that was posted for it and never replayed.
    std::mutex                       m_property_preview_mutex;
    std::optional<ProjectProperties> m_property_preview {};
    /// The deferred names the last preview reported, to log a change of them
    /// once. Render thread only.
    std::vector<std::string>         m_logged_deferred_properties {};
#ifdef WESCENE_BUILD_TESTS
    /// How many property-preview commands this thread has handled, so a test
    /// can show that a burst of documents queues one command and not one each.
    std::atomic<uint64_t>            m_property_preview_commands { 0 };
#endif

    MouseButtonSnapshot               m_mouse_buttons {};
    std::atomic<bool>                 m_cursor_in_window { false };
    /// Published for the host without enabling diagnostic counting: these are
    /// live state a settings pane reads, not instrumentation. Written on the
    /// render thread, read from whichever thread asks.
    std::atomic<SceneUpdateDemand::Kind> m_scene_update_kind {
        SceneUpdateDemand::Kind::Continuous
    };
    std::atomic<uint32_t> m_scene_demand_reasons { 0 };
    /// Whether any pass samples the pointer. Starts true so a scene whose
    /// graph has not been analysed still receives pointer events.
    std::atomic<bool>     m_scene_wants_pointer { true };
    /// Guards the backend selection, which holds a string and so cannot be an
    /// atomic. Written once at renderer creation, read by whoever asks.
    mutable std::mutex    m_backend_selection_mutex;
    SceneBackendSelection m_backend_selection {};
};
} // namespace wallpaper

SceneWallpaper::SceneWallpaper(): m_main_handler(std::make_shared<MainHandler>()) {}

SceneWallpaper::~SceneWallpaper() { shutdown(); }

bool SceneWallpaper::inited() const { return m_main_handler->inited(); }

bool SceneWallpaper::init() { return m_main_handler->init(); }

void SceneWallpaper::setLogScope(uint64_t scope) { m_main_handler->setLogScope(scope); }

void SceneWallpaper::shutdown() {
    // CLEANROOM SH27
    // After the handlers, and before this process starts tearing down what the
    // background compile uses: a compile still running is waited for, because
    // it is writing into memory this process owns.
    ShutdownSceneMetalVariants();
}

#ifdef WESCENE_BUILD_TESTS
void SceneWallpaperInputTestAccess::PostScene(SceneWallpaper& wallpaper,
                                             std::shared_ptr<Scene> scene) {
    auto msg = CreateMsgWithCmd(wallpaper.m_main_handler->renderHandler(),
                               RenderHandler::CMD::CMD_SET_SCENE);
    msg->setObject("scene", std::move(scene));
    msg->post();
}

SceneWallpaperInputTestAccess::MouseButtonSnapshot
SceneWallpaperInputTestAccess::ConsumeMouseButtons(SceneWallpaper& wallpaper) {
    const auto snapshot =
        wallpaper.m_main_handler->renderHandler()->consumeMouseButtonSnapshot();
    return { snapshot.down, snapshot.pressed, snapshot.released };
}

uint64_t SceneWallpaperInputTestAccess::PropertyPreviewCommandsHandled(SceneWallpaper& wallpaper) {
    return wallpaper.m_main_handler->renderHandler()->m_property_preview_commands.load(
        std::memory_order_relaxed);
}

void SceneWallpaperInputTestAccess::InjectFrameFailure(SceneWallpaper& wallpaper) {
    CreateMsgWithCmd(wallpaper.m_main_handler->renderHandler(),
                     RenderHandler::CMD::CMD_INJECT_FRAME_FAILURE)
        ->post();
}

#endif

void SceneWallpaper::initSurface(const RenderInitInfo& info) {
    // CLEANROOM SH28
    (void)info;
}

bool SceneWallpaper::beginSurfaceReconfigure() {
    // CLEANROOM SH29
    return false;
}

bool SceneWallpaper::finishSurfaceReconfigure(const RenderInitInfo& info) {
    // CLEANROOM SH30
    (void)info;
    return false;
}

void SceneWallpaper::applyConfig(const SceneWallpaperConfig& config) {
    // CLEANROOM SH31
    (void)config;
}

void SceneWallpaper::play() {
    // CLEANROOM SH32
}
void SceneWallpaper::pause() {
    // CLEANROOM SH32
}

void SceneWallpaper::setPaused(bool paused) {
    // CLEANROOM SH32
    (void)paused;
}

void SceneWallpaper::setSceneSource(std::string source) {
    setPropertyString(PROPERTY_SOURCE, std::move(source));
}

void SceneWallpaper::setAssetsPath(std::string assets) {
    setPropertyString(PROPERTY_ASSETS, std::move(assets));
}

void SceneWallpaper::setCachePath(std::string cache_path) {
    setPropertyString(PROPERTY_CACHE_PATH, std::move(cache_path));
}

void SceneWallpaper::setTargetFps(uint32_t fps) {
    setPropertyInt32(PROPERTY_FPS, static_cast<int32_t>(fps));
}

void SceneWallpaper::mouseInput(double x, double y) {
    m_main_handler->renderHandler()->setMousePos(x, y);
}

void SceneWallpaper::mouseButton(int button, bool pressed) {
    m_main_handler->renderHandler()->setMouseButton(button, pressed);
}

void SceneWallpaper::mouseButtonBaseline(uint32_t down) {
    m_main_handler->renderHandler()->setMouseButtonBaseline(down);
}

void SceneWallpaper::mouseEnter(bool entered) {
    m_main_handler->renderHandler()->setMouseInWindow(entered);
}

SceneUpdateDemand::Kind SceneWallpaper::sceneUpdateKind() const {
    if (m_main_handler == nullptr) return SceneUpdateDemand::Kind::Continuous;
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SceneUpdateDemand::Kind::Continuous;
    return handler->sceneUpdateKind();
}

SurfaceHealthSnapshot SceneWallpaper::surfaceHealth() const {
    if (m_main_handler == nullptr) return SurfaceHealthSnapshot {};
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SurfaceHealthSnapshot {};
    return handler->surfaceHealth();
}

SceneBackendSelection SceneWallpaper::sceneBackendSelection() const {
    if (m_main_handler == nullptr) return SceneBackendSelection {};
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SceneBackendSelection {};
    return handler->sceneBackendSelection();
}

bool SceneWallpaper::sceneOptimizationApplied() const {
    if (m_main_handler == nullptr) return false;
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return false;
    return handler->sceneOptimizationApplied();
}

SceneVideoPath SceneWallpaper::sceneVideoPath() const {
    if (m_main_handler == nullptr) return SceneVideoPath::None;
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SceneVideoPath::None;
    return handler->videoPath();
}

uint32_t SceneWallpaper::sceneDemandReasons() const {
    if (m_main_handler == nullptr) return static_cast<uint32_t>(SceneDemandReason::UnknownInput);
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return static_cast<uint32_t>(SceneDemandReason::UnknownInput);
    return handler->sceneDemandReasons();
}

void SceneWallpaper::applySystemMediaArtwork(uint32_t width, uint32_t height, const uint8_t* rgba,
                                             std::size_t rgba_len) {
    // CLEANROOM SH33
    (void)width;
    (void)height;
    (void)rgba;
    (void)rgba_len;
}

#define BASIC_TYPE(NAME, TYPENAME)                                                       \
    void SceneWallpaper::setProperty##NAME(std::string_view, TYPENAME) {                 \
        /* CLEANROOM SH34 */                                                             \
    }

BASIC_TYPE(Bool, bool);
BASIC_TYPE(Int32, int32_t);
BASIC_TYPE(Float, float);
BASIC_TYPE(String, std::string);
void SceneWallpaper::setPropertyObject(std::string_view name, std::shared_ptr<void> value) {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_SET_PROPERTY);
    if (! msg->setString("property", std::string(name)) || ! msg->setObject("value", value)) {
        throw std::runtime_error("failed to prepare object property message");
    }
    if (msg->post() != looper::status_t::OK) {
        throw std::runtime_error("failed to enqueue object property message");
    }
}

void SceneWallpaper::setFraming(const WallpaperFraming& framing) {
    // One object, so a reader of the render thread sees both axes change
    // together; normalised here so what travels is already in range.
    setPropertyObject(PROPERTY_FRAMING,
                      std::make_shared<WallpaperFraming>(NormalizeWallpaperFraming(framing)));
}

std::size_t SceneWallpaper::counters(uint64_t* out, std::size_t len) const {
    if (m_main_handler == nullptr) return 0;
    const auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return 0;
    return handler->counters.Snapshot(out, len);
}

MHANDLER_CMD_IMPL(MainHandler, LOAD_SCENE) {
    // CLEANROOM SH35
}

MHANDLER_CMD_IMPL(MainHandler, APPLY_CONFIG) {
    // CLEANROOM SH36
}

MHANDLER_CMD_IMPL(MainHandler, SET_PROPERTY) {
    // CLEANROOM SH37
}

MHANDLER_CMD_IMPL(MainHandler, STOP) {
    // CLEANROOM SH38
}

MHANDLER_CMD_IMPL(MainHandler, FIRST_FRAME) {
    // CLEANROOM SH39
}

MHANDLER_CMD_IMPL(MainHandler, USER_SHORTCUT) {
    std::string name;
    std::string value;
    // Both, or neither: a request with no property is not a request, and a
    // host told only the name would have to guess what its user chose.
    const bool has_request =
        msg->findString("property_name", &name) && msg->findString("property_value", &value);
    LOG_INFO("user shortcut reported: request=%d callback=%d name=%s value=\"%s\"",
             static_cast<int>(has_request), static_cast<int>(m_user_shortcut_callback != nullptr),
             name.c_str(), value.c_str());
    if (has_request && m_user_shortcut_callback) {
        m_user_shortcut_callback(name, value);
    }
}

MHANDLER_CMD_IMPL(MainHandler, POINTER_INPUT_CHANGED) {
    if (msg->findBool("accepts_pointer_input", &m_accepts_pointer_input) &&
        m_pointer_input_callback) {
        m_pointer_input_callback(m_accepts_pointer_input);
    }
}

MHANDLER_CMD_IMPL(MainHandler, AUDIO_REQUIREMENT_CHANGED) {
    std::shared_ptr<uint64_t> generation;
    bool                      requires_audio { false };
    if (! msg->findObject("generation", &generation) || generation == nullptr ||
        ! msg->findBool("requires_audio", &requires_audio)) {
        return;
    }
    // A report from a scene that has since been replaced says nothing about
    // the one now showing.
    if (*generation < m_audio_requirement_generation) return;
    // A newer generation is a new scene and starts from its own report; within
    // one scene the requirement only ever rises. A mark posted from another
    // thread may overtake its scene's commit message, so `true` can arrive
    // first and the commit's `false` must not lower it.
    const bool next = *generation > m_audio_requirement_generation
                          ? requires_audio
                          : (m_requires_audio || requires_audio);
    m_audio_requirement_generation = *generation;
    if (next == m_requires_audio) return;
    m_requires_audio = next;
    if (m_audio_requirement_callback) m_audio_requirement_callback(next);
}

MHANDLER_CMD_IMPL(MainHandler, RENDER_FAILED) {
    if (m_render_failure_callback) m_render_failure_callback();
}

bool MainHandler::applyConfig(SceneWallpaperConfig config) {
    // CLEANROOM SH40
    (void)config;
    return false;
}

void MainHandler::setPaused(bool paused) {
    // CLEANROOM SH41
    (void)paused;
}

bool MainHandler::setProjectPropertyOverrideJson(std::string json) {
    // CLEANROOM SH42
    (void)json;
    return false;
}

bool MainHandler::resetProjectPropertyOverride() {
    // CLEANROOM SH42
    return false;
}

void MainHandler::previewProjectProperties(const std::string& json) {
    ProjectProperties document;
    std::string       error;
    if (! ParseFlatProjectPropertyOverrideJson(json, &document, &error)) {
        LOG_ERROR("property preview ignored: %s", error.c_str());
        return;
    }
    // The saved override above is deliberately left alone: a preview is not a
    // choice, so a scene loaded again shows the saved look.
    if (! m_render_handler->stageProjectPropertyPreview(std::move(document))) return;
    // The slot was empty, so no command is on its way to take it; one is posted
    // now, and the documents that follow before it runs only replace the slot.
    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_APPLY_PROJECT_PROPERTIES)->post();
}

void MainHandler::loadScene() {
    // CLEANROOM SH43
}

bool MainHandler::loadNonSceneProject(const ProjectManifest& manifest) {
    // CLEANROOM SH44
    (void)manifest;
    return false;
}

void MainHandler::sendCmdLoadScene() {
    // CLEANROOM SH45
}
void MainHandler::sendFirstFrameOk() {
    // CLEANROOM SH45
}

void MainHandler::sendPointerInputCapability(bool accepts_pointer_input) {
    // CLEANROOM SH46
    (void)accepts_pointer_input;
}

void MainHandler::sendAudioRequirement(uint64_t generation, bool requires_audio) {
    // CLEANROOM SH46
    (void)generation;
    (void)requires_audio;
}

void MainHandler::sendRenderFailure() {
    // CLEANROOM SH46
}

std::function<void()> MainHandler::audioRequirementReporter(uint64_t generation) {
    return [weak = weak_from_this(), generation] {
        auto self = std::static_pointer_cast<MainHandler>(weak.lock());
        if (self != nullptr) self->sendAudioRequirement(generation, true);
    };
}

void MainHandler::sendUserShortcut(std::string_view property_name,
                                   std::string_view property_value) {
    // CLEANROOM SH46
    (void)property_name;
    (void)property_value;
}

bool MainHandler::init() {
    // CLEANROOM SH47
    return false;
}

void MainHandler::shutdown() {
    // CLEANROOM SH48
}

MainHandler::MainHandler()
    : m_sound_manager(std::make_unique<audio::SoundManager>()),
      m_main_loop(std::make_shared<looper::Looper>()),
      m_render_loop(std::make_shared<looper::Looper>()),
      m_render_handler(std::make_shared<RenderHandler>(*this)) {
    // Playback runs until the host pauses it. Nothing starts here: the output
    // device opens on the first mounted channel and runs only while playing
    // and unmuted, so running is only the state a mount will see.
    m_sound_manager->Play();
}
