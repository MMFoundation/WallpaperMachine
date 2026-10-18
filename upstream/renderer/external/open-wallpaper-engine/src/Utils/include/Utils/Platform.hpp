#pragma once
#include <cstdlib>
#include <string_view>
#include <filesystem>
#include "Core/StringHelper.hpp"

namespace wallpaper
{
namespace platform
{

// The folder `name` under the user's cache root: $XDG_CACHE_HOME when set, else
// ~/.cache. Nothing is created; with neither variable set the result is empty.
inline std::filesystem::path GetCachePath(std::string_view name) {
    std::filesystem::path root;
    if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg != nullptr && *xdg != '\0')
        root = xdg;
    else if (const char* home = std::getenv("HOME"); home != nullptr && *home != '\0')
        root = std::filesystem::path(home) / ".cache";
    else
        return {};
    return root / name;
}

} // namespace platform
} // namespace wallpaper
