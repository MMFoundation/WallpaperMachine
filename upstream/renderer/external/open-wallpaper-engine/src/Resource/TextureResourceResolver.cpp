#include "Resource/TextureResourceResolver.hpp"

namespace wallpaper
{

TextureResourceKind ClassifyTextureResource(std::string_view)
{
    // CLEANROOM U45: implement from specs/engine/e7-small-units.md
    return TextureResourceKind::AssetTexture;
}

} // namespace wallpaper
