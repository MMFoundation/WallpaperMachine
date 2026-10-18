#pragma once

#include "WPJson.hpp"
#include "WPImageObject.h"
#include "WPObjectSchema.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <nlohmann/json.hpp>
#include <sstream>
#include <string>
#include <vector>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

inline const nlohmann::json& UnwrapMiscSettingValue(const nlohmann::json& value) {
    // CLEANROOM LS49
    static const nlohmann::json neutral {};
    return neutral;
}

// CLEANROOM LS49: the file-local helpers of this group were removed; the rewrite designs its own.

// A setting Wallpaper Engine registers as an enumeration, read as the word it
// is written as. A key that is missing leaves `word` as it was. A key that is
// there and is not a string (a number, `null`, an object) names no entry, and
// takes the registry's first one, `first_entry`; a typed string reader would
// leave the default there instead. Whether a string matches an entry is for the
// reader of the word to decide.
inline void ReadMiscEnumWord(const nlohmann::json& json, const char* key, const char* first_entry,
                             std::string& word) {
    if (! json.contains(key)) return;
    const auto& source = json.at(key);
    word               = source.is_string() ? source.get<std::string>() : std::string(first_entry);
}

struct WPMiscObjectBase {
    int32_t              id { 0 };
    int32_t              parent_id { -1 };
    std::string          name;
    std::array<float, 3> origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> angles { 0.0f, 0.0f, 0.0f };
    // Wallpaper Engine's default for an object that leaves the key out.
    std::array<float, 2> parallaxDepth { 1.0f, 1.0f };
    bool                 visible { true };
    bool                 locktransforms { false };
    bool                 muteineditor { false };
    bool                 nointerpolation { false };
    bool                 dynamic_origin { false };
    bool                 dynamic_visible { false };
    std::vector<int32_t> dependencies;
    nlohmann::json       instance;
    nlohmann::json       origin_setting;
    nlohmann::json       scale_setting;
    nlohmann::json       angles_setting;
    nlohmann::json       visible_setting;
    nlohmann::json       field_bindings;

    void FromCommonJson(const nlohmann::json& json) {
        // CLEANROOM LS49
    }
};

struct WPTextObject : WPMiscObjectBase {
    nlohmann::json       text;
    // Wallpaper Engine's default for a text object that leaves the key out: Arial.
    nlohmann::json       font = "systemfont_arial";
    // Wallpaper Engine's defaults for a text object that leaves these keys out.
    float                pointsize { 32.0f };
    // Wallpaper Engine's defaults for the key being absent: a 32 pixel margin
    // on each axis and no extra glyph or line spacing. Whether the margin
    // applies is the parser's decision; see `TextCardIsPadded`.
    std::array<float, 2> padding { 32.0f, 32.0f };
    std::array<float, 2> spacing { 0.0f, 0.0f };
    // Wallpaper Engine registers both as enumerations: a key that is missing
    // leaves the layer centred. `TextLayer` reads the word; see
    // `ParseTextHorizontalAlign` and `ParseTextVerticalAlign`. There is no
    // `alignment` key on a text object, and this one is not read.
    std::string          horizontalalign { "center" };
    std::string          verticalalign { "center" };
    // The screen edge the layer follows, which is not a point of the layer.
    std::string          anchor;
    uint32_t             maxrows { 1 };
    float                maxwidth { 500.0f };
    bool                 limitrows { false };
    bool                 limitwidth { false };
    bool                 limituseellipsis { false };
    bool                 blockalign { false };
    std::array<float, 3> color { 1.0f, 1.0f, 1.0f };
    float                alpha { 1.0f };
    float                brightness { 1.0f };
    int32_t              colorBlendMode { 0 };
    std::array<float, 2> size { 0.0f, 0.0f };
    // How the layer's texture (`_rt_imageLayerComposite_<id>`) is addressed
    // outside 0..1, as for an image layer.
    bool                 clampuvs { true };
    bool                 perspective { false };
    bool                 copybackground { false };
    // `solid` layers are hit-tested for the cursor, and Wallpaper Engine's
    // default is on; a layer with `disablepropagation` hides the layers behind it
    // from the cursor where it is under it.
    bool                 solid { true };
    bool                 disablepropagation { false };
    bool                 opaquebackground { false };
    bool                 ledsource { false };
    std::array<float, 3> backgroundcolor { 0.0f, 0.0f, 0.0f };
    float                backgroundbrightness { 1.0f };
    // The signed-distance font shader's looks, with Wallpaper Engine's defaults
    // for the keys being absent. `msdf` only picks how the glyph edges are
    // rebuilt, so it is read and nothing more.
    bool                 msdf { false };
    bool                 outline { false };
    float                outlinethickness { 4.0f };
    std::array<float, 3> outlinecolor { 0.0f, 0.0f, 0.0f };
    bool                 blur { false };
    float                blursize { 6.0f };
    bool                 dropshadow { false };
    float                dropshadowsize { 6.0f };
    float                dropshadowopacity { 1.0f };
    std::array<float, 2> dropshadowoffset { 4.0f, 4.0f };
    std::array<float, 3> dropshadowcolor { 0.0f, 0.0f, 0.0f };
    std::vector<WPImageEffect> effects;

    bool FromJson(const nlohmann::json& json, fs::VFS& vfs) {
        // CLEANROOM LS50
        return false;
    }
};

struct WPModelObject : WPMiscObjectBase {
    std::string model;
    std::string attachment;
    bool        perspective { false };
    bool        solid { true };
    bool        disablepropagation { false };
    std::vector<WPPuppetLayer::AnimationLayer> puppet_layers;
    std::vector<nlohmann::json> puppet_layer_settings;

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        // CLEANROOM LS51
        return false;
    }
};

/// A `shape` object (`"shape": "quad"`): a quad as tall as the canvas on both axes
/// that Wallpaper Engine draws through its effects, light shafts being the one the
/// editor ships. It has no texture; the last of its effects is drawn straight onto
/// the scene.
struct WPShapeObject : WPMiscObjectBase {
    std::string                shape;
    std::vector<WPImageEffect> effects;

    bool FromJson(const nlohmann::json& json, fs::VFS& vfs) {
        // CLEANROOM LS51
        return false;
    }
};

struct WPCameraObject : WPMiscObjectBase {
    std::string camera;
    std::string path;
    std::string queuemode;
    float       fov { 0.0f }; // absent/nonpositive inherits the scene's resolved perspective FOV
    float       zoom { 1.0f };
    /// `zoom` as written. The unwrapped float above is the authored default;
    /// a slider the user drags arrives as `{"user": "<property>", "value": n}`
    /// and only this form still names the property.
    nlohmann::json zoom_setting;
    bool        solid { false };
    bool        disablepropagation { false };

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        // CLEANROOM LS51
        return false;
    }
};

} // namespace wpscene
} // namespace wallpaper
