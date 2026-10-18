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
inline std::optional<usize> CustomShaderTextureSlot(std::string_view) {
    // CLEANROOM RG14
    return std::nullopt;
}

inline std::optional<usize> CustomShaderSamplerSlot(std::string_view) {
    // CLEANROOM RG15
    return std::nullopt;
}

} // namespace render
} // namespace wallpaper
