#include "Platform/Apple/SceneWallpaperBindings.h"

#include "Audio/AudioResponseService.h"
#include "Core/RendererCounters.hpp"
#include "SceneWallpaper.hpp"
#include "Runtime/MediaArtwork.hpp"
#include "SceneWallpaperSurface.hpp"
#include "Utils/Logging.h"
#include "MetalRender/MetalVideoSupport.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Video/VideoFramePacing.hpp"

#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <cstring>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>

namespace
{
void clear_last_error()
{
    // CLEANROOM PH22
}

const char* property_name(std::string_view value)
{
    // CLEANROOM PH23
    (void)value;
    return "";
}
} // namespace

struct owe_scene_wallpaper {
    wallpaper::SceneWallpaper scene;
};

#ifdef WESCENE_BUILD_TESTS
wallpaper::SceneWallpaper&
wallpaper::SceneWallpaperInputTestAccess::FromNative(owe_scene_wallpaper& scene) {
    return scene.scene;
}
#endif

extern "C" void owe_set_log_callback(owe_log_callback callback)
{
    // CLEANROOM PH24
    (void)callback;
}

extern "C" uint64_t owe_current_log_scope(void) { return WallpaperLogScope(); }

extern "C" int owe_scene_wallpaper_new(owe_scene_wallpaper** out_scene)
{
    // CLEANROOM PH25
    (void)out_scene;
    return 1;
}

extern "C" int owe_scene_wallpaper_delete(owe_scene_wallpaper* scene)
{
    // CLEANROOM PH26
    (void)scene;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_log_scope(owe_scene_wallpaper* scene, uint64_t scope)
{
    // CLEANROOM PH27
    (void)scene, (void)scope;
    return 1;
}

extern "C" int owe_scene_wallpaper_init(owe_scene_wallpaper* scene)
{
    // CLEANROOM PH28
    (void)scene;
    return 1;
}

extern "C" int owe_scene_wallpaper_shutdown(owe_scene_wallpaper* scene)
{
    // CLEANROOM PH29
    (void)scene;
    return 1;
}

extern "C" int owe_scene_wallpaper_init_metal(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor)
{
    // CLEANROOM PH30
    (void)scene, (void)metal_layer, (void)width, (void)height, (void)render_width, (void)render_height, (void)display_scale_factor;
    return 1;
}

extern "C" int owe_scene_wallpaper_begin_surface_reconfigure(owe_scene_wallpaper* scene)
{
    // CLEANROOM PH31
    (void)scene;
    return 1;
}

extern "C" int owe_scene_wallpaper_finish_surface_reconfigure(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor)
{
    // CLEANROOM PH32
    (void)scene, (void)metal_layer, (void)width, (void)height, (void)render_width, (void)render_height, (void)display_scale_factor;
    return 1;
}

extern "C" int owe_scene_wallpaper_apply_config(
    owe_scene_wallpaper* scene,
    const char* source,
    const char* assets,
    const char* cache_path,
    uint32_t fps,
    bool paused,
    bool force_shader_refresh,
    const char* project_property_override_json)
{
    // CLEANROOM PH33
    (void)scene, (void)source, (void)assets, (void)cache_path, (void)fps, (void)paused, (void)force_shader_refresh, (void)project_property_override_json;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_target_fps(owe_scene_wallpaper* scene, uint32_t fps)
{
    // CLEANROOM PH34
    (void)scene, (void)fps;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_paused(owe_scene_wallpaper* scene, bool paused)
{
    // CLEANROOM PH35
    (void)scene, (void)paused;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_render_scale(owe_scene_wallpaper* scene, double scale)
{
    // CLEANROOM PH36
    (void)scene, (void)scale;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_framing(owe_scene_wallpaper* scene, double pan_x,
                                               double pan_y)
{
    // CLEANROOM PH37
    (void)scene, (void)pan_x, (void)pan_y;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_first_frame_callback(
    owe_scene_wallpaper* scene,
    owe_first_frame_callback callback,
    void* user_data,
    owe_first_frame_callback_drop drop_user_data)
{
    // CLEANROOM PH38
    (void)scene, (void)callback, (void)user_data, (void)drop_user_data;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_pointer_input_callback(
    owe_scene_wallpaper* scene,
    owe_pointer_input_callback callback,
    void* user_data,
    owe_pointer_input_callback_drop drop_user_data)
{
    // CLEANROOM PH39
    (void)scene, (void)callback, (void)user_data, (void)drop_user_data;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_user_shortcut_callback(
    owe_scene_wallpaper* scene,
    owe_user_shortcut_callback callback,
    void* user_data,
    owe_user_shortcut_callback_drop drop_user_data)
{
    // CLEANROOM PH40
    (void)scene, (void)callback, (void)user_data, (void)drop_user_data;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_audio_requirement_callback(
    owe_scene_wallpaper* scene,
    owe_audio_requirement_callback callback,
    void* user_data,
    owe_audio_requirement_callback_drop drop_user_data)
{
    // CLEANROOM PH41
    (void)scene, (void)callback, (void)user_data, (void)drop_user_data;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_render_failure_callback(
    owe_scene_wallpaper* scene,
    owe_render_failure_callback callback,
    void* user_data,
    owe_render_failure_callback_drop drop_user_data)
{
    // CLEANROOM PH42
    (void)scene, (void)callback, (void)user_data, (void)drop_user_data;
    return 1;
}

extern "C" int owe_scene_wallpaper_mouse_input(owe_scene_wallpaper* scene, double x, double y)
{
    // CLEANROOM PH43
    (void)scene, (void)x, (void)y;
    return 1;
}

extern "C" int owe_scene_wallpaper_mouse_button(owe_scene_wallpaper* scene, int button, bool pressed)
{
    // CLEANROOM PH44
    (void)scene, (void)button, (void)pressed;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_mouse_button_baseline(
    owe_scene_wallpaper* scene, uint32_t down)
{
    // CLEANROOM PH45
    (void)scene, (void)down;
    return 1;
}

extern "C" int owe_scene_wallpaper_mouse_enter(owe_scene_wallpaper* scene, bool entered)
{
    // CLEANROOM PH46
    (void)scene, (void)entered;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_property_bool(
    owe_scene_wallpaper* scene,
    const char* name,
    bool value)
{
    // CLEANROOM PH47
    (void)scene, (void)name, (void)value;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_property_int32(
    owe_scene_wallpaper* scene,
    const char* name,
    int32_t value)
{
    // CLEANROOM PH48
    (void)scene, (void)name, (void)value;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_property_float(
    owe_scene_wallpaper* scene,
    const char* name,
    float value)
{
    // CLEANROOM PH49
    (void)scene, (void)name, (void)value;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_property_string(
    owe_scene_wallpaper* scene,
    const char* name,
    const char* value)
{
    // CLEANROOM PH50
    (void)scene, (void)name, (void)value;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_audio_volume(owe_scene_wallpaper* scene, float volume)
{
    // CLEANROOM PH51
    (void)scene, (void)volume;
    return 1;
}

extern "C" int owe_scene_wallpaper_set_audio_muted(owe_scene_wallpaper* scene, bool muted)
{
    // CLEANROOM PH52
    (void)scene, (void)muted;
    return 1;
}

extern "C" int owe_scene_wallpaper_submit_media_event_json(
    owe_scene_wallpaper* scene,
    const char* event_json)
{
    // CLEANROOM PH53
    (void)scene, (void)event_json;
    return 1;
}

extern "C" int owe_scene_wallpaper_apply_system_media_artwork(
    owe_scene_wallpaper* scene,
    uint32_t width,
    uint32_t height,
    const uint8_t* rgba,
    uintptr_t rgba_len)
{
    // CLEANROOM PH54
    (void)scene, (void)width, (void)height, (void)rgba, (void)rgba_len;
    return 1;
}

extern "C" const char* owe_property_scaling_mode(void)
{
    // CLEANROOM PH55
    return "";
}

extern "C" const char* owe_property_scaling_factor(void)
{
    // CLEANROOM PH56
    return "";
}

extern "C" const char* owe_property_horizontal_flip(void)
{
    // CLEANROOM PH57
    return "";
}

extern "C" const char* owe_property_audio_response_enabled(void)
{
    // CLEANROOM PH58
    return "";
}

extern "C" const char* owe_property_media_integration_enabled(void)
{
    // CLEANROOM PH59
    return "";
}

extern "C" const char* owe_property_force_shader_refresh(void)
{
    // CLEANROOM PH60
    return "";
}

extern "C" const char* owe_property_project_property_override_json(void)
{
    // CLEANROOM PH61
    return "";
}

extern "C" const char* owe_property_project_property_reset(void)
{
    // CLEANROOM PH62
    return "";
}

extern "C" const char* owe_property_project_property_preview_json(void)
{
    return property_name(wallpaper::PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON);
}

extern "C" int owe_audio_spectrum_is_stereo(void)
{
    // CLEANROOM PH63
    return -1;
}

extern "C" void owe_set_scene_optimization_enabled(bool enabled)
{
    wallpaper::render::SetSceneOptimizationEnabled(enabled);
}

extern "C" bool owe_scene_optimization_enabled(void)
{
    return wallpaper::render::SceneOptimizationEnabled();
}

extern "C" void owe_scene_optimization_stats(
    uint64_t* out_executed_passes,
    uint64_t* out_skipped_passes,
    uint64_t* out_elided_copies,
    uint64_t* out_pinned_bytes)
{
    const auto totals = wallpaper::render::CurrentSceneOptimizationTotals();
    if (out_executed_passes != nullptr) *out_executed_passes = totals.executed_passes;
    if (out_skipped_passes != nullptr) *out_skipped_passes = totals.skipped_passes;
    if (out_elided_copies != nullptr) *out_elided_copies = totals.elided_copies;
    if (out_pinned_bytes != nullptr) *out_pinned_bytes = totals.pinned_bytes;
}

extern "C" void owe_set_scene_on_demand_enabled(bool enabled)
{
    wallpaper::SetSceneOnDemandEnabled(enabled);
}

extern "C" bool owe_scene_on_demand_enabled(void)
{
    return wallpaper::SceneOnDemandEnabled();
}

extern "C" void owe_set_scene_resolution(int resolution)
{
    // An unrecognised value keeps the canvas rather than being stored: it is
    // the size a scene has always been rasterized at, so a host built against a
    // newer enum degrades to the behaviour it had before the choice existed.
    wallpaper::SetSceneResolution(resolution == OWE_SCENE_RESOLUTION_DISPLAY
                                      ? wallpaper::SceneResolution::Display
                                      : wallpaper::SceneResolution::Canvas);
}

extern "C" int owe_current_scene_resolution(void)
{
    return wallpaper::CurrentSceneResolution() == wallpaper::SceneResolution::Display
               ? OWE_SCENE_RESOLUTION_DISPLAY
               : OWE_SCENE_RESOLUTION_CANVAS;
}

extern "C" int owe_scene_wallpaper_update_mode(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    // -1 rather than any enumerated mode: a caller with no scene has observed
    // nothing, which is different from observing a scene that is idle.
    if (wallpaper_scene == nullptr) return -1;
    switch (wallpaper_scene->sceneUpdateKind()) {
    case wallpaper::SceneUpdateDemand::Kind::WaitingForEvent:
        return OWE_SCENE_UPDATE_WAITING_FOR_EVENT;
    case wallpaper::SceneUpdateDemand::Kind::WaitingForDeadline:
        return OWE_SCENE_UPDATE_WAITING_FOR_DEADLINE;
    case wallpaper::SceneUpdateDemand::Kind::Continuous:
        return OWE_SCENE_UPDATE_CONTINUOUS;
    }
    return OWE_SCENE_UPDATE_UNKNOWN;
}

extern "C" int owe_scene_wallpaper_surface_health(void* scene, owe_surface_health* out)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    // Nothing observed is not a healthy surface: the caller is told it got no
    // reading instead of being handed zeroes that read as "running, no frames".
    if (wallpaper_scene == nullptr || out == nullptr) return 1;
    const auto health = wallpaper_scene->surfaceHealth();
    out->frames_completed = health.frames_completed;
    out->frames_presented = health.frames_presented;
    out->failed_frames = health.failed_frames;
    out->last_present_age_ms = health.last_present_age_ms;
    out->stop_reason = static_cast<uint32_t>(health.stop_reason);
    return 0;
}

extern "C" int owe_scene_wallpaper_backend(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return -1;
    const auto selection = wallpaper_scene->sceneBackendSelection();
    // Same -1 as "no scene": the host shows it as preparing. A renderer is only
    // created once the scene is parsed, and naming one before that would make
    // the panel claim a renderer that has not been created.
    // A scene held in a failure has no renderer drawing it right now, whatever
    // renderer it had before; the failure accessors say why.
    if (! selection.created || selection.failed()) return -1;
    return OWE_SCENE_BACKEND_NATIVE_METAL;
}

extern "C" void owe_set_scene_video_plane_sampling_enabled(bool enabled)
{
    wallpaper::metal::SetMetalVideoPlaneSamplingEnabled(enabled);
}

extern "C" bool owe_scene_video_plane_sampling_enabled(void)
{
    return wallpaper::metal::MetalVideoPlaneSamplingEnabled();
}

extern "C" int owe_scene_wallpaper_video_path(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return OWE_SCENE_VIDEO_PATH_NONE;
    switch (wallpaper_scene->sceneVideoPath()) {
    case wallpaper::SceneVideoPath::Bgra: return OWE_SCENE_VIDEO_PATH_BGRA;
    case wallpaper::SceneVideoPath::Nv12Direct: return OWE_SCENE_VIDEO_PATH_NV12_DIRECT;
    case wallpaper::SceneVideoPath::Nv12Converted: return OWE_SCENE_VIDEO_PATH_NV12_CONVERTED;
    case wallpaper::SceneVideoPath::Nv12Mixed: return OWE_SCENE_VIDEO_PATH_NV12_MIXED;
    // The host already decodes 5 as "converted, preparing"; only this end was
    // missing, so a scene between choosing that path and having it ready was
    // reported as having no video path at all.
    case wallpaper::SceneVideoPath::Nv12ConvertedPreparing:
        return OWE_SCENE_VIDEO_PATH_NV12_CONVERTED_PREPARING;
    case wallpaper::SceneVideoPath::Yuv10Converted: return OWE_SCENE_VIDEO_PATH_YUV10_CONVERTED;
    case wallpaper::SceneVideoPath::None: break;
    }
    return OWE_SCENE_VIDEO_PATH_NONE;
}

extern "C" int owe_scene_wallpaper_scene_optimization_applied(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return -1;
    return wallpaper_scene->sceneOptimizationApplied() ? 1 : 0;
}

extern "C" int owe_scene_wallpaper_backend_failure(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return OWE_SCENE_FAILURE_NONE;
    return static_cast<int>(wallpaper_scene->sceneBackendSelection().failure_stage);
}

extern "C" size_t owe_scene_wallpaper_backend_failure_reason(void* scene, char* out,
                                                             size_t out_len)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return 0;
    const auto reason = wallpaper_scene->sceneBackendSelection().failure_reason;
    if (reason.empty()) return 0;
    if (out == nullptr || out_len == 0) return reason.size();
    const size_t copied = std::min(reason.size(), out_len - 1);
    std::memcpy(out, reason.data(), copied);
    out[copied] = '\0';
    return reason.size();
}

extern "C" uint32_t owe_scene_wallpaper_demand_reasons(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return 0;
    return wallpaper_scene->sceneDemandReasons();
}

extern "C" int owe_audio_submit_mono_frames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames)
{
    // CLEANROOM PH64
    (void)sample_rate, (void)frame_count, (void)pcm_frames;
    return 1;
}

extern "C" int owe_audio_submit_frames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames)
{
    // CLEANROOM PH65
    (void)sample_rate, (void)frame_count, (void)pcm_frames;
    return 1;
}

extern "C" int owe_audio_current_spectrum_128(
    float* out_bins,
    uintptr_t out_len,
    uint64_t* out_generation)
{
    // CLEANROOM PH66
    (void)out_bins, (void)out_len, (void)out_generation;
    return 1;
}

extern "C" int owe_renderer_counters_set_enabled(bool enabled)
{
    clear_last_error();
    wallpaper::RendererCounters::SetEnabled(enabled);
    return 0;
}

extern "C" bool owe_renderer_counters_enabled(void)
{
    return wallpaper::RendererCounters::Enabled();
}

extern "C" int owe_scene_wallpaper_counters(
    owe_scene_wallpaper* scene,
    uint64_t* out_values,
    uintptr_t out_len,
    uintptr_t* out_written)
{
    // CLEANROOM PH67
    (void)scene, (void)out_values, (void)out_len, (void)out_written;
    return 1;
}

extern "C" int owe_renderer_shared_counters(
    uint64_t* out_values,
    uintptr_t out_len,
    uintptr_t* out_written)
{
    // CLEANROOM PH68
    (void)out_values, (void)out_len, (void)out_written;
    return 1;
}

extern "C" const char* owe_last_error(void)
{
    // CLEANROOM PH69
    return "";
}
