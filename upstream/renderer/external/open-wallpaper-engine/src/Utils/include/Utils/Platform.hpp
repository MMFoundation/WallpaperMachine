#pragma once
#include <string_view>
#include <filesystem>
#include "Core/StringHelper.hpp"

namespace wallpaper
{
namespace platform
{

inline std::filesystem::path GetCachePath(std::string_view) {
    // CLEANROOM U20: implement from specs/engine/e7-small-units.md
    return {};
}

} // namespace platform
} // namespace wallpaper
