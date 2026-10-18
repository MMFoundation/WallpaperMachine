#include <type_traits>
#include "WPScene.h"

#include <sstream>

// CLEANROOM: the stubs below leave their parameters and helpers unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-function"

using namespace wallpaper::wpscene;

bool Orthogonalprojection::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS46
    return {};
}

bool WPSceneCamera::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS46
    return {};
}

bool WPSceneGeneral::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS46
    return {};
}

namespace
{
// CLEANROOM LS46: the file-local helpers of this group were removed; the rewrite designs its own.

const nlohmann::json& UnwrapSettingValue(const nlohmann::json& value) {
    // CLEANROOM LS46
    static const nlohmann::json neutral {};
    return neutral;
}

template <typename T>
void ReadScalarSetting(const nlohmann::json& json, const char* key, T& destination,
                       nlohmann::json& setting) {
    if (! json.contains(key)) return;
    setting = json.at(key);
    const auto& value = UnwrapSettingValue(setting);
    if constexpr (std::is_same_v<T, bool>) {
        if (value.is_boolean()) destination = value.get<bool>();
        else if (value.is_number()) destination = value.get<double>() != 0.0;
    } else if (value.is_number()) {
        destination = value.get<T>();
    }
}

}

bool WPSceneGeneral::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    // CLEANROOM LS47
    return {};
}

bool WPScene::FromJson(const nlohmann::json& json) {
    // CLEANROOM LS48
    return {};
}

bool WPScene::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    // CLEANROOM LS48
    return {};
}
