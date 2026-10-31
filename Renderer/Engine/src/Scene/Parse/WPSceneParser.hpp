#pragma once
#include "Interface/ISceneParser.h"

#include <cmath>
#include <string>
#include <string_view>
#include <random>
#include <vector>

namespace wallpaper
{
/// The alpha a translucent draw of alpha `src` leaves over a target of alpha `dst`: Wallpaper
/// Engine's translucent blend is `SRC_ALPHA / INV_SRC_ALPHA` on colour and on alpha alike
/// (`sub_140099F60`; `MetalBlend`'s `AlphaBlendRule::Material`).
inline float TranslucentBlendAlpha(float src, float dst) {
    return src * src + dst * (1.0f - src);
}

/// How far from the scene behind it towards its own colour text of alpha `alpha` stands when it
/// goes through a composite: the glyphs blend translucent into a seed of alpha 0, so the colour
/// carries one factor of `alpha` and the composite's alpha is `TranslucentBlendAlpha(alpha, 0)`,
/// by which the composite goes onto the scene: `alpha` cubed, what Wallpaper Engine's frames
/// show (black text at 0.65 and 0.5 over white stands at 0.275 and 0.125, docs/testing/renderer.md).
inline float TextCompositeReach(float alpha) {
    return alpha * TranslucentBlendAlpha(alpha, 0.0f);
}

struct SceneMaterial;
struct WPShaderInfo;
class RuntimeImageSource;

namespace wpscene
{
class WPMaterial;
struct WPUserTexture;
}

/// Substitutes the texture slots a material delegates. Two kinds arrive in the
/// same `usertextures` list: the cover slots the runtime supplies itself, and a
/// slot that names one of the wallpaper's own `scenetexture` properties. The
/// second kind needs the property table to resolve, so a parse without one
/// leaves those slots on their authored texture.
///
/// A cover slot whose position also has an authored texture keeps that texture
/// until the runtime has a cover to show, as Wallpaper Engine does, when
/// `covers` is given: the slot is then bound through `BindCoverSlot` and holds
/// the name that shows the authored picture until a cover arrives. Without
/// `covers` it names the cover itself.
void ApplySystemUserTextures(std::vector<std::string>& textures,
                             const std::vector<wpscene::WPUserTexture>& usertextures,
                             const ProjectProperties* properties = nullptr,
                             RuntimeImageSource* covers = nullptr);
/// The property a `usertextures` slot names (the bare-string form), or empty for
/// a slot the runtime supplies or one that names nothing. The scene reads such a
/// property once, while it loads.
std::string_view UserTexturePropertyName(const wpscene::WPUserTexture& user_texture);
void LoadMaterialConstantShaderValues(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                      const WPShaderInfo& info);

class WPSceneParser : public ISceneParser {
public:
    WPSceneParser()  = default;
    ~WPSceneParser() = default;
    std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) override;
    std::shared_ptr<Scene> Parse(std::string_view scene_id, const std::string&, fs::VFS&, audio::SoundManager&);
};
} // namespace wallpaper
