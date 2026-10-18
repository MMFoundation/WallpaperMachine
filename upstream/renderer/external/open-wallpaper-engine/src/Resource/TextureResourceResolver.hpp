// This project's own code, written from the clean-room specification
// (specs/engine/e7-small-units.md).
#pragma once

#include "Resource/TextureResourceKind.hpp"
#include "SpecTexs.hpp"

#include <string_view>

namespace wallpaper
{

// Which kind of thing a texture name refers to, tested in this order: an alias of
// another render target, the composite target of another layer (which also starts
// like any other special name, so it is tested first), any other special name (a
// built-in render target), and otherwise a file.
inline TextureResourceKind ClassifyTextureResource(std::string_view name)
{
    if (sstart_with(name, WE_ALIAS_PREFIX)) return TextureResourceKind::AliasRenderTarget;
    if (sstart_with(name, WE_IMAGE_LAYER_COMPOSITE_PREFIX))
        return TextureResourceKind::LinkedRenderTarget;
    if (IsSpecTex(name)) return TextureResourceKind::BuiltInRenderTarget;
    return TextureResourceKind::AssetTexture;
}

} // namespace wallpaper
