#pragma once

#include "Presentation/WallpaperScaling.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneRenderTarget.h"
#include "SpecTexs.hpp"
#include "Type.hpp"
#include "Utils/Algorism.h"

#include "Utils/Linalg.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <string>

// Scene-side raster arithmetic: how large each render target is for a given
// output, render scale and display, and how the authored canvas is framed in
// it. Nothing here touches a GPU API, so every caller shares these one
// definitions; two copies would drift, and the drift would show as the same
// wallpaper sized or framed differently.
namespace wallpaper
{

/// A width and height in pixels. Plain pixels, so code that only sizes
/// things carries no GPU header.
struct Extent2D {
    uint32_t width { 0 };
    uint32_t height { 0 };
};

namespace render
{

inline constexpr i32 kMinRenderTargetDimension = 4;

inline i32 ResolveScreenBoundRenderTargetDimension(double, double) {
    // CLEANROOM RG16
    return kMinRenderTargetDimension;
}

inline void ResolveScreenBoundRenderTargetSize(SceneRenderTarget&, const Extent2D&) {
    // CLEANROOM RG17
}

/// The smallest internal render scale that still leaves a usable image. Below
/// this the raster is coarse enough that the upscale at present dominates
/// whatever is saved, and the min-dimension clamp starts distorting small
/// targets rather than scaling them.
inline constexpr double kMinRenderScale = 0.25;

/// Scene-wide internal render scale, clamped to (0, 1].
///
inline double ResolveSceneRenderScale(const wallpaper::Scene& scene) {
    const double scale = scene.render_scale;
    if (! std::isfinite(scale) || scale >= 1.0) return 1.0;
    return std::max(kMinRenderScale, scale);
}

/// Latches the authored size of a target the first time it is resolved, then
/// derives the physical size from that latched value. Deriving from the
/// authored size rather than the current one is what keeps 100% -> 50% -> 100%
/// exact instead of drifting by a rounding step each way.
inline void ResolveRenderScaledSize(SceneRenderTarget& target, double render_scale) {
    if (target.authored_width <= 0 || target.authored_height <= 0) {
        target.authored_width  = target.width;
        target.authored_height = target.height;
    }
    target.width =
        ResolveScreenBoundRenderTargetDimension(target.authored_width, render_scale);
    target.height =
        ResolveScreenBoundRenderTargetDimension(target.authored_height, render_scale);
}

/// The author's canvas, in scene units. Never scaled: presentation layout and
/// cursor mapping are computed against this, so the internal raster size
/// cannot move the letterbox or offset the hit test.
inline Extent2D ResolveSceneSourceExtent(const wallpaper::Scene&, const Extent2D&) {
    // CLEANROOM RG18
    return {};
}

/// The authored canvas and the internal raster it is drawn at. Equal at render
/// scale 1.0 with the canvas resolution; the display resolution makes the raster
/// the size the canvas is presented at instead.
struct SceneRasterExtents {
    Extent2D source {};
    Extent2D raster {};
};

/// What the output a scene is presented on means for its raster.
struct SceneRasterSurface {
    /// Output pixels per layout point, the display's backing scale.
    double   display_scale_factor { 1.0 };
    /// The longest side a render target may have on this device. Zero when the
    /// device's limit is not known, which caps nothing.
    uint32_t max_dimension { 0 };
};

/// Whether `Scene::resolution` decides anything for this scene.
///
/// A perspective scene already rasterizes at the output size, so for it there is
/// no canvas whose raster could be sized one way or the other.
inline bool SceneResolutionAffectsRaster(const wallpaper::Scene& scene) {
    return ! scene.display_sized;
}

/// The output pixels the authored canvas covers once it is presented: the FILL
/// layout the renderers lay it out with, scaled by the display's backing factor.
/// A canvas whose aspect differs from the output's is filled, so this extent
/// keeps the canvas aspect and exceeds the output along one axis; the
/// presentation crops the excess, and that crop is not this function's concern.
///
/// The user's zoom is left out on purpose: it changes with a slider and must
/// not rebuild the graph every time it moves, so the raster is sized for the
/// placement every display starts from.
inline Extent2D ResolveSceneDisplayExtent(const Extent2D& source, const Extent2D& output,
                                            double display_scale_factor) {
    const double factor =
        std::isfinite(display_scale_factor) && display_scale_factor > 0.0 ? display_scale_factor
                                                                          : 1.0;
    // Rounded to the same whole points the renderers lay the canvas out in, so
    // the raster matches the viewport they present it into.
    const auto logical = [factor](uint32_t pixels) {
        return static_cast<uint32_t>(
            std::max(1L, std::lround(static_cast<double>(pixels) / factor)));
    };
    const auto layout = wallpaper::ComputeWallpaperScalingLayout(
        wallpaper::WallpaperScalingMode::FILL, source.width, source.height,
        logical(output.width), logical(output.height), factor, 1.0);
    return {
        static_cast<uint32_t>(std::max(1, layout.viewport_px.width)),
        static_cast<uint32_t>(std::max(1, layout.viewport_px.height)),
    };
}

/// Shrinks `extent` so its longest side fits `max_dimension`, keeping the
/// aspect. Zero means the limit is unknown, and nothing is shrunk.
inline Extent2D CapRasterExtent(const Extent2D& extent, uint32_t max_dimension) {
    const uint32_t longest = std::max(extent.width, extent.height);
    if (max_dimension == 0 || longest <= max_dimension) return extent;
    const double shrink = static_cast<double>(max_dimension) / static_cast<double>(longest);
    return {
        static_cast<uint32_t>(ResolveScreenBoundRenderTargetDimension(extent.width, shrink)),
        static_cast<uint32_t>(ResolveScreenBoundRenderTargetDimension(extent.height, shrink)),
    };
}

/// Re-bakes `g_TextureNResolution` for every material slot that samples a
/// screen-bound render target.
///
/// Those constants are folded in while the scene is parsed, when a target that
/// follows the screen still has placeholder dimensions because the output size
/// is not known yet. Nothing refreshes them afterwards, so a shader that
/// divides by the resolution -- a separable blur steps by
/// `1 / g_Texture0Resolution.zw` -- was dividing by two. Every one of its taps
/// landed outside the texture and clamped to the edge, which turns a gentle
/// blur into a flat wash and is why an effect chain's background lost its
/// shape entirely.
inline void RefreshScreenBoundTextureResolutions(Scene& scene) {
    const auto refresh = [&scene](SceneNode* node) {
        if (node == nullptr || node->Mesh() == nullptr) return;
        auto* mesh = node->Mesh();
        for (uint32_t slot = 0; slot < mesh->MaterialSlots().size(); ++slot) {
            auto* material = mesh->MaterialForSlot(slot);
            if (material == nullptr) continue;
            for (std::size_t index = 0; index < material->textures.size(); ++index) {
                if (index >= wallpaper::WE_GLTEX_RESOLUTION_NAMES.size()) break;
                const auto& texture = material->textures[index];
                if (texture.empty()) continue;
                // The material keeps the authored name; the scene keys targets
                // by the resolved one.
                const auto* target =
                    scene.FindRenderTarget(scene.ResolveRenderTargetName(texture));
                if (target == nullptr) continue;
                if (! (target->bind.enable && target->bind.screen)) continue;
                const std::array<i32, 4> resolution { target->width, target->height,
                                                      target->width, target->height };
                material->customShader.constValues[std::string(
                    wallpaper::WE_GLTEX_RESOLUTION_NAMES[index])] = array_cast<float>(resolution);
            }
        }
    };
    const auto walk = [&refresh](auto&& self, SceneNode* node) -> void {
        if (node == nullptr) return;
        refresh(node);
        for (const auto& child : node->GetChildren()) self(self, child.get());
    };
    walk(walk, scene.sceneGraph.get());
    // An effect chain's nodes are not children of the layer they belong to, so
    // a plain graph walk misses exactly the passes this matters most for.
    for (auto& [name, camera] : scene.cameras) {
        (void)name;
        if (camera == nullptr || ! camera->HasImgEffect()) continue;
        auto& layer = *camera->GetImgEffect();
        for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
            const auto& effect = layer.GetEffect(i);
            if (effect == nullptr) continue;
            for (const auto& effect_node : effect->nodes) refresh(effect_node.sceneNode.get());
        }
    }
    for (const auto& post : scene.post_processes) {
        if (post == nullptr) continue;
        for (const auto& step : post->steps) {
            const auto* pass = std::get_if<ScenePostProcessPass>(&step);
            if (pass == nullptr || pass->node == nullptr) continue;
            refresh(pass->node.get());
            auto* mesh = pass->node->Mesh();
            if (mesh == nullptr || pass->source_texel_radius <= 0.0f) continue;
            for (const auto& material : mesh->MaterialSlots()) {
                if (material == nullptr || material->textures.empty()) continue;
                const auto* source = scene.FindRenderTarget(material->textures.front());
                if (source == nullptr || source->width <= 0 || source->height <= 0) continue;
                const float x = pass->source_texel_radius / source->width;
                const float y = pass->source_texel_radius / source->height;
                material->customShader.constValues["g_RenderVar0"] =
                    std::array<float, 4>{x, y, -x, -y};
            }
        }
    }
}

inline SceneRasterExtents ResolveScreenBoundRenderTargetSizes(Scene&,
                                                              const Extent2D&,
                                                              const SceneRasterSurface& = {}) {
    // CLEANROOM RG19
    return {};
}

/// Fits the scene's authored canvas into an output of `width` x `height`.
///
/// Purely scene-side camera arithmetic with nothing GPU-specific in it, so
/// every caller shares this one definition. Two copies of it would drift, and
/// the drift would show as the same wallpaper framed differently.
inline void ApplyCameraFillMode(wallpaper::Scene&, wallpaper::FillMode, uint32_t, uint32_t) {
    // CLEANROOM RG20
}

/// Folds into a static-reuse sample the cameras a pass depends on: the one it
/// draws through -- `camera_override` when the graph set one, else its node's --
/// and the scene's active camera, which a compose layer samples the screen with.
/// Neither is covered by the node transform, and both move without a graph
/// rebuild: a fill-mode change, a camera layer's zoom or pan, a script. The
/// view-projection matrix carries the camera's position and visible extent
/// alike. Every caller shares this one definition, so caches invalidate on
/// the same camera changes.
inline uint64_t FoldPassCameras(uint64_t hash, const wallpaper::Scene& scene,
                                const std::string& camera_override,
                                const wallpaper::SceneNode* node) {
    const auto fold = [&hash](const wallpaper::SceneCamera* camera) {
        if (camera == nullptr) return;
        const linalg::Matrix4d matrix = camera->GetViewProjectionMatrix();
        hash = StaticHashBytes(hash, matrix.data(), sizeof(double) * 16);
    };
    const std::string& camera_name =
        ! camera_override.empty() ? camera_override
                                  : (node != nullptr ? node->Camera() : std::string {});
    if (! camera_name.empty()) {
        const auto found = scene.cameras.find(camera_name);
        fold(found != scene.cameras.end() ? found->second.get() : nullptr);
    }
    fold(scene.activeCamera);
    return hash;
}

} // namespace render
} // namespace wallpaper
