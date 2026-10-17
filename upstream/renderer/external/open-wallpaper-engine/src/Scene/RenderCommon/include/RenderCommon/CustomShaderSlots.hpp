#pragma once

#include "SpecTexs.hpp"
#include "Type.hpp"
#include "Utils/Algorism.h"

#include <charconv>
#include <optional>
#include <string_view>
#include <system_error>

namespace wallpaper
{
namespace render
{

// Which `g_TextureN` slot a shader binding name stands for. Everything
// reads the shader's own reflected names this way, so the slot a
// sampler or texture binds to has one definition.
inline std::optional<usize> CustomShaderTextureSlot(std::string_view name) {
    constexpr std::string_view prefix { "g_Texture" };
    if (! wallpaper::sstart_with(name, prefix)) return std::nullopt;
    name.remove_prefix(prefix.size());
    if (name.empty()) return std::nullopt;
    usize slot = 0;
    const auto result = std::from_chars(name.data(), name.data() + name.size(), slot);
    if (result.ec != std::errc {} || result.ptr != name.data() + name.size()) {
        return std::nullopt;
    }
    if (slot >= WE_GLTEX_NAMES.size() || (name.size() > 1u && name.front() == '0')) {
        return std::nullopt;
    }
    return slot;
}

inline std::optional<usize> CustomShaderSamplerSlot(std::string_view name) {
    constexpr std::string_view prefix { "_we_Sampler_" };
    if (! wallpaper::sstart_with(name, prefix)) return std::nullopt;
    return CustomShaderTextureSlot(name.substr(prefix.size()));
}

} // namespace render
} // namespace wallpaper
