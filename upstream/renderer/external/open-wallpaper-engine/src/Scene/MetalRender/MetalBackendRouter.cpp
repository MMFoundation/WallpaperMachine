#include "MetalRender/MetalBackendRouter.hpp"

#include "MetalRender/MetalCapability.hpp"
#include "Scene/Scene.h"

#include <mutex>
#include <string>
#include <unordered_map>

namespace wallpaper::metal
{
namespace
{

struct FailureMemory
{
    std::mutex                                   guard;
    std::unordered_map<std::string, std::string> reasons;
    SceneRendererPreference                      recorded_under {
        SceneRendererPreference::Compatibility
    };
};

FailureMemory& Memory()
{
    static FailureMemory memory;
    return memory;
}

} // namespace

SceneBackendSelection SelectSceneBackend(const Scene& scene)
{
    const auto preference = CurrentSceneRendererPreference();

    if (! SceneRendererAllowsCompatibility(preference)) {
        // Nothing to remember and no flip-flop to prevent: the only outcomes
        // are native and not drawn. A retry therefore evaluates the scene
        // afresh instead of being refused from a note made last time.
        auto selection = EvaluateMetalSupport(scene);
        if (selection.fell_back()) return NativeRefusal(preference, std::move(selection.fallback_reason));
        return selection;
    }

    // Checked before the preference is acted on, not after, so switching to
    // the compatibility renderer and back is enough to make the native one be
    // tried again. Deciding this only on the native path would mean the
    // preference could change without anything ever noticing.
    {
        auto&                       memory = Memory();
        std::lock_guard<std::mutex> lock(memory.guard);
        if (memory.recorded_under != preference) {
            memory.reasons.clear();
            memory.recorded_under = preference;
        }
        if (SceneRendererWantsNative(preference)) {
            if (const auto found = memory.reasons.find(scene.scene_id);
                found != memory.reasons.end()) {
                return SceneBackendSelection { SceneBackend::LegacyVulkan, found->second };
            }
        }
    }

    if (! SceneRendererWantsNative(preference)) {
        // The user asked for the compatibility renderer, so this is what they
        // chose rather than something they were denied.
        return SceneBackendSelection { SceneBackend::LegacyVulkan, {} };
    }

    return EvaluateMetalSupport(scene);
}

SceneBackendSelection NativeRefusal(SceneRendererPreference preference, std::string reason)
{
    if (reason.empty()) reason = "the native renderer does not support this wallpaper";
    if (SceneRendererAllowsCompatibility(preference)) {
        return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
    }
    SceneBackendSelection refused;
    refused.backend        = SceneBackend::NativeMetal;
    refused.failure_stage  = SceneFailureStage::Unsupported;
    refused.failure_reason = std::move(reason);
    return refused;
}

void RecordMetalPrepareFailure(const Scene& scene, std::string_view reason)
{
    auto&                       memory = Memory();
    std::lock_guard<std::mutex> lock(memory.guard);
    memory.recorded_under = CurrentSceneRendererPreference();
    memory.reasons[scene.scene_id] =
        reason.empty() ? std::string("the native renderer could not start this wallpaper")
                       : std::string(reason);
}

void ForgetMetalPrepareFailures()
{
    auto&                       memory = Memory();
    std::lock_guard<std::mutex> lock(memory.guard);
    memory.reasons.clear();
    memory.recorded_under = CurrentSceneRendererPreference();
}

} // namespace wallpaper::metal
