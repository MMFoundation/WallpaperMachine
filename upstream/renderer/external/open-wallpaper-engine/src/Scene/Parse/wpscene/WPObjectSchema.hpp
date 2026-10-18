#pragma once

#include <cstdint>
#include <nlohmann/json.hpp>
#include <vector>

namespace wallpaper::wpscene
{

inline void ParseDependencies(const nlohmann::json& json, std::vector<int32_t>& out) {
    // CLEANROOM LS53
}

inline void AbsorbFieldBindings(const nlohmann::json& json, nlohmann::json& out) {
    // CLEANROOM LS53
}

} // namespace wallpaper::wpscene
