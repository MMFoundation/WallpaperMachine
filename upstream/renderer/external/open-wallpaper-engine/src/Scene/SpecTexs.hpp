// Clean-room implementation from the WallpaperMachine spec e1a-scene-host.md; written without access to the original source.
#pragma once
#include <array>
#include <string>
#include <string_view>
#include <cstdint>
#include "Core/Literals.hpp"
#include "Core/StringHelper.hpp"
#include "Utils/String.h"

namespace wallpaper
{

// R1-S4a: to be written from spec
/// Wallpaper Engine's per-texture step: (1 / width, 1 / height, width, height)
/// of the texture a slot samples.
constexpr std::array WE_GLTEX_TEXEL_NAMES { BASE_GLTEX_NAMES(Texel) };
#undef BASE_GLTEX_NAMES

// R1-S4b: to be written from spec
constexpr std::string_view WE_IN_NORMAL { "a_Normal" };
/// The signed tangent of a model (xyz, and the bitangent's handedness in w).
/// Wallpaper Engine's model shaders declare it `attribute vec4 a_Tangent4`, and
/// a renderer hands a shader input the mesh attribute of the same name, so the
/// mesh has to use that spelling: under any other the input is left unbound.
constexpr std::string_view WE_IN_TANGENT { "a_Tangent4" };
// R1-S4c: to be written from spec
/// Set on a mesh the sprite-particle generator owns: its vertex stream is
/// rewritten every frame from the simulation, in the billboard-quad layout
/// `GenParticleData` writes. A renderer needs a positive statement of that,
/// because "the mesh is dynamic" is shared with every other per-frame
/// geometry in the engine and says nothing about the layout.
constexpr std::string_view WE_PRENDER_SPRITE { "PRENDER_SPRITE" };
constexpr std::string_view WE_PRENDER_ROPE { "PRENDER_ROPE" };
/// Set on a particle mesh drawn by a trail renderer, next to the marker of the
/// generator that fills it: with `WE_PRENDER_SPRITE` it is a sprite trail, whose
/// stretch the author's vertex shader derives from the velocity the thick
/// sprite record already carries; with `WE_PRENDER_ROPE` it is a rope trail.
constexpr std::string_view WE_PRENDER_TRAIL { "PRENDER_TRAIL" };
/// Set on a rope trail's mesh, together with the two above. Its segments follow
/// one particle's own recorded path rather than joining neighbouring particles,
/// so a renderer can name the case without re-reading the project file.
constexpr std::string_view WE_PRENDER_ROPETRAIL { "PRENDER_ROPETRAIL" };

// R1-S4d: to be written from spec
constexpr std::string_view G_EYEPOSITION { "g_EyePosition" };
constexpr std::string_view G_VIEWFORWARD { "g_ViewForward" };
constexpr std::string_view G_VIEWUP { "g_ViewUp" };
constexpr std::string_view G_VIEWRIGHT { "g_ViewRight" };

constexpr std::string_view G_TIME { "g_Time" };
constexpr std::string_view G_DAYTIME { "g_DayTime" };
constexpr std::string_view G_POINTERPOSITION { "g_PointerPosition" };
constexpr std::string_view G_POINTERPOSITIONLAST { "g_PointerPositionLast" };
constexpr std::string_view G_POINTERSTATE { "g_PointerState" };
constexpr std::string_view G_FRAMETIME { "g_Frametime" };
constexpr std::string_view G_TEXTUREREDUCTIONSCALE { "g_TextureReductionScale" };
constexpr std::string_view G_EFFECTMODEL { "g_EffectModelMatrix" };
constexpr std::string_view G_EFFECTMVP { "g_EffectModelViewProjectionMatrix" };
constexpr std::string_view G_EFFECTMVPI { "g_EffectModelViewProjectionMatrixInverse" };
constexpr std::string_view G_TEXELSIZE { "g_TexelSize" };
constexpr std::string_view G_TEXELSIZEHALF { "g_TexelSizeHalf" };
constexpr std::string_view G_BONES { "g_Bones" };
constexpr std::string_view G_SCREEN { "g_Screen" };
constexpr std::string_view G_PARALLAXPOSITION { "g_ParallaxPosition" };
constexpr std::string_view G_ORIENTATIONUP { "g_OrientationUp" };
constexpr std::string_view G_ORIENTATIONRIGHT { "g_OrientationRight" };
constexpr std::string_view G_ORIENTATIONFORWARD { "g_OrientationForward" };

constexpr std::string_view SpecTex_Default { "_rt_default" };
constexpr std::string_view SpecTex_Link { "_rt_link_" };

inline bool StartsWithText(const std::string_view text, const std::string_view prefix) {
    return text.size() >= prefix.size() && text.substr(0, prefix.size()) == prefix;
}
/// A name that starts with an underscore and names no file: no directory separator and no
/// extension dot.
inline bool IsImplicitSpecTex(const std::string_view name) {
    return ! name.empty() && name.front() == '_' && name.find_first_of("/.") == std::string_view::npos;
}
inline bool IsSpecTex(const std::string_view name) {
    return StartsWithText(name, WE_SPEC_PREFIX) || StartsWithText(name, WE_ALIAS_PREFIX) ||
           IsImplicitSpecTex(name);
}
inline std::string EnsureSpecTexName(const std::string_view name) {
    if (name.empty() || IsSpecTex(name)) return std::string(name);
    return std::string(WE_SPEC_PREFIX) + std::string(name);
}
inline bool IsSpecLinkTex(const std::string_view name) { return StartsWithText(name, SpecTex_Link); }
/// The layer id after the link prefix; zero for anything that is not a run of digits that fits
/// 32 bits right behind the prefix.
inline uint32_t ParseLinkTex(const std::string_view name) {
    if (name.size() <= SpecTex_Link.size()) return 0;
    uint64_t value = 0;
    bool     any   = false;
    for (const char c : name.substr(SpecTex_Link.size())) {
        if (c < '0' || c > '9') break;
        any   = true;
        value = value * 10 + static_cast<uint64_t>(c - '0');
        if (value > 0xFFFFFFFFull) return 0;
    }
    return any ? static_cast<uint32_t>(value) : 0;
}
inline std::string GenLinkTex(idx id) { return std::string(SpecTex_Link) + std::to_string(id); }
inline std::string LayerCompositeTargetKey(idx id) {
    return std::string(WE_IMAGE_LAYER_COMPOSITE_PREFIX) + std::to_string(id);
}
/// The layer-local camera layer `id` is drawn through into its composite target.
inline std::string LayerCompositeCameraKey(idx id) {
    return "layer_composite_camera_" + std::to_string(id);
}
/// The camera a fullscreen layer's result is drawn through: the whole canvas,
/// whatever a camera layer does to the view of the scene.
constexpr std::string_view FullscreenLayerCamera { "fullscreen" };

} // namespace wallpaper
