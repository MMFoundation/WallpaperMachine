#pragma once

#include "Presentation/WallpaperScaling.hpp"

#ifndef VK_NO_PROTOTYPES
#    define VK_NO_PROTOTYPES
#endif
#include <vulkan/vulkan.h>

namespace wallpaper
{

// The Vulkan form of a presentation layout. The layout itself is plain
// arithmetic that both render backends share, so only these two conversions
// carry Vulkan's viewport types.
VkViewport MakeWallpaperViewport(const WallpaperScalingLayout& layout);
VkRect2D   MakeWallpaperScissor(const WallpaperScalingLayout& layout);

} // namespace wallpaper
