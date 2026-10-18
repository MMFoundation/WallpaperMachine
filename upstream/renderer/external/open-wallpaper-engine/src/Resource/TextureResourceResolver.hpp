#pragma once

#include "Resource/TextureResourceKind.hpp"
#include "SpecTexs.hpp"

#include <string_view>

namespace wallpaper
{

inline TextureResourceKind ClassifyTextureResource(std::string_view)
{
    // CLEANROOM U44: implement from specs/engine/e7-small-units.md
    return TextureResourceKind::AssetTexture;
}

} // namespace wallpaper
