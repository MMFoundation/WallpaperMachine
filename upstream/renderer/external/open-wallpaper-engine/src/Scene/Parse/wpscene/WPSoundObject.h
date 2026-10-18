#pragma once
#include <cstdint>
#include <unordered_map>
#include <cstdint>
#include "WPJson.hpp"
#include "WPObjectSchema.hpp"
#include <nlohmann/json.hpp>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

struct WPSoundObject {
    std::string              playbackmode { "loop" };
    float                    maxtime { 10.0f };
    float                    mintime { 0.0f };
    float                    volume { 1.0f };
    bool                     muted { false };
    bool                     startsilent { false };
    bool                     visible { true };
    std::string              name;
    /// Project property this sound's volume follows, when the user bound one.
    std::string              volume_user;
    std::vector<std::string> sound;
    std::vector<int32_t>     dependencies;
    nlohmann::json           field_bindings;

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        // CLEANROOM LS52
        return {};
    }
};
} // namespace wpscene
} // namespace wallpaper
