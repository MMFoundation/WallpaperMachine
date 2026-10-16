#include "VulkanRender/WallpaperViewport.hpp"

#include <algorithm>

namespace wallpaper
{

VkViewport MakeWallpaperViewport(const WallpaperScalingLayout& layout)
{
    const int32_t viewport_width = std::max(1, layout.viewport_px.width);
    const int32_t viewport_height = std::max(1, layout.viewport_px.height);

    return VkViewport {
        .x = static_cast<float>(layout.viewport_px.x),
        .y = static_cast<float>(layout.viewport_px.y + viewport_height),
        .width = static_cast<float>(viewport_width),
        .height = -static_cast<float>(viewport_height),
        .minDepth = 0.0f,
        .maxDepth = 1.0f,
    };
}

VkRect2D MakeWallpaperScissor(const WallpaperScalingLayout& layout)
{
    return VkRect2D {
        .offset = { layout.scissor_px.x, layout.scissor_px.y },
        .extent = {
            static_cast<uint32_t>(std::max(1, layout.scissor_px.width)),
            static_cast<uint32_t>(std::max(1, layout.scissor_px.height)),
        },
    };
}

} // namespace wallpaper
