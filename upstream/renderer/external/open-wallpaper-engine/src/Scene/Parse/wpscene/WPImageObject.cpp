#include "WPImageObject.h"
#include "WPObjectSchema.hpp"
#include "Utils/Logging.h"
#include "Fs/VFS.h"

#include <algorithm>
#include <sstream>

// CLEANROOM: the stubs below leave their parameters and helpers unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-function"

using namespace wallpaper::wpscene;

void wallpaper::wpscene::ParsePuppetAnimationLayers(
    const nlohmann::json& json, std::vector<WPPuppetLayer::AnimationLayer>& layers,
    std::vector<nlohmann::json>& settings) {
    // CLEANROOM LS38
}

// CLEANROOM LS38: the file-local readers of this file were removed; the rewrite designs its own.


bool WPEffectCommand::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS39
    return {};
}

bool WPEffectFbo::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS39
    return {};
}

// CLEANROOM LS40: the effect blacklist (its table and lookup, once private to WPImageEffect) was removed; the rewrite designs its own.

bool WPImageEffect::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    // CLEANROOM LS40
    return {};
}

bool WPImageEffect::FromFileJson(const nlohmann::json& json, fs::VFS& vfs) {
    // CLEANROOM LS41
    return {};
}

bool WPImageObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    // CLEANROOM LS42
    return {};
}
