#pragma once

#include <cstdint>
#include <string>

namespace wallpaper
{

/// Which renderer the user asked for.
///
/// A preference, never an outcome. Asking for the native backend does not make
/// a scene use it: the scene is checked against what that backend can actually
/// draw. Under `NativeMetalPreferred` one it cannot draw runs on the
/// compatibility backend and says why. Under `NativeMetalOnly` there is no
/// compatibility backend to run on: the scene is not drawn, the surface keeps
/// its last picture (or shows the project's still preview when it has drawn
/// nothing), and the failure and its reason are reported.
enum class SceneRendererPreference : uint8_t
{
    Compatibility = 0,
    NativeMetalPreferred = 1,
    NativeMetalOnly = 2,
};

/// Whether a scene the native backend cannot draw may be handed to the
/// compatibility backend. The one place that answers it, so no failure path can
/// decide differently from another.
[[nodiscard]] constexpr bool SceneRendererAllowsCompatibility(SceneRendererPreference preference)
{
    return preference != SceneRendererPreference::NativeMetalOnly;
}

/// Whether the native backend is asked for at all.
[[nodiscard]] constexpr bool SceneRendererWantsNative(SceneRendererPreference preference)
{
    return preference != SceneRendererPreference::Compatibility;
}

/// What stopped a scene from being drawn natively, when nothing else may draw it.
///
/// A category, never the whole explanation: the host words each one for the
/// user in their language and shows the engine's own `failure_reason` beside it.
enum class SceneFailureStage : uint8_t
{
    None = 0,
    /// The scene uses something the native backend does not support, found
    /// before any renderer was created: a refused admission.
    Unsupported = 1,
    /// The native renderer could not be created on the surface.
    Prepare = 2,
    /// The scene's shaders or pipelines did not compile for Metal.
    Compile = 3,
    /// A frame failed after the scene had been set up.
    Frame = 4,
    /// The surface could not be re-established after a display change.
    Surface = 5,
};

/// Stable lowercase name for logs and the bridge.
[[nodiscard]] constexpr const char* ToString(SceneFailureStage stage)
{
    switch (stage) {
    case SceneFailureStage::None: return "";
    case SceneFailureStage::Unsupported: return "unsupported";
    case SceneFailureStage::Prepare: return "prepare";
    case SceneFailureStage::Compile: return "compile";
    case SceneFailureStage::Frame: return "frame";
    case SceneFailureStage::Surface: return "surface";
    }
    return "";
}

/// Which renderer actually drew a scene.
enum class SceneBackend : uint8_t
{
    LegacyVulkan = 0,
    NativeMetal = 1,
};

void SetSceneRendererPreference(SceneRendererPreference preference);
SceneRendererPreference CurrentSceneRendererPreference();

/// Why a scene is not on the preferred backend.
///
/// Empty means it is. Every rejection carries a specific, user-readable reason:
/// "unsupported" with no reason is indistinguishable from a bug, and this is
/// the string a user will quote when asking why their wallpaper did not switch.
struct SceneBackendSelection
{
    SceneBackend backend { SceneBackend::LegacyVulkan };
    std::string  fallback_reason;

    /// False while this is still only a decision, true once a renderer has
    /// actually been created for it. A surface whose scene has not been parsed
    /// yet has no backend at all, and reporting the default as if it were the
    /// answer would name a renderer that is not drawing.
    bool created { false };

    /// Set only when the scene is not being drawn natively and no other backend
    /// may draw it (`SceneRendererPreference::NativeMetalOnly`). Mutually
    /// exclusive with `fell_back()`: a scene either runs somewhere else with a
    /// reason, or does not run, with one.
    SceneFailureStage failure_stage { SceneFailureStage::None };
    std::string       failure_reason;

    [[nodiscard]] bool fell_back() const { return ! fallback_reason.empty(); }
    [[nodiscard]] bool failed() const { return failure_stage != SceneFailureStage::None; }
};

} // namespace wallpaper
