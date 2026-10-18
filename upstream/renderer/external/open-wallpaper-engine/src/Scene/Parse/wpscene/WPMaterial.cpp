#include "WPMaterial.h"

#include <cstddef>

// CLEANROOM: the stubs below leave their parameters and helpers unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-function"

using namespace wallpaper::wpscene;

// CLEANROOM LS43: the file-local helpers of this file were removed; the rewrite designs its own.

bool wallpaper::wpscene::IsSystemUserTexture(const WPUserTexture& user_texture) {
    // The two cover slots a wallpaper may bind. Anything else named `system` is
    // a slot this renderer does not supply.
    return user_texture.type == "system" &&
           (user_texture.name == "$mediaThumbnail" ||
            user_texture.name == "$mediaPreviousThumbnail");
}

bool WPMaterialPassBindItem::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS44
    return {};
}

void WPMaterialPass::Update(const WPMaterialPass& p) {
    // CLEANROOM LS44
}

void WPMaterial::MergePass(const WPMaterialPass& p) {
    // CLEANROOM LS44
}

bool WPMaterialPass::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS45
    return {};
}

bool WPMaterial::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS45
    return {};
}
