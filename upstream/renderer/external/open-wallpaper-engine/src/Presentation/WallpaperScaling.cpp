#include "Presentation/WallpaperScaling.hpp"

#include <algorithm>
#include <cmath>

namespace wallpaper
{

WallpaperScalingLayout ComputeWallpaperScalingLayout(
    WallpaperScalingMode mode,
    uint32_t scene_width,
    uint32_t scene_height,
    uint32_t display_logical_width,
    uint32_t display_logical_height,
    double display_scale_factor,
    double wallpaper_scale_factor,
    double pan_x,
    double pan_y)
{
    // CLEANROOM PH11
    (void)mode;
    (void)scene_width;
    (void)scene_height;
    (void)display_logical_width;
    (void)display_logical_height;
    (void)display_scale_factor;
    (void)wallpaper_scale_factor;
    (void)pan_x;
    (void)pan_y;
    return {};
}

WallpaperCursorMapping ComputeWallpaperCursorMapping(const WallpaperScalingLayout& layout,
                                                     double camera_center_x, double camera_center_y,
                                                     double camera_width, double camera_height) {
    const double viewport_width  = layout.viewport_px.width;
    const double viewport_height = layout.viewport_px.height;
    const double window_width    = layout.scissor_px.width;
    const double window_height   = layout.scissor_px.height;
    if (viewport_width <= 0.0 || viewport_height <= 0.0 || window_width <= 0.0 ||
        window_height <= 0.0 || ! std::isfinite(camera_width) || ! std::isfinite(camera_height) ||
        camera_width <= 0.0 || camera_height <= 0.0 || ! std::isfinite(camera_center_x) ||
        ! std::isfinite(camera_center_y)) {
        return {};
    }

    // Window pixel -> presented-image fraction -> camera world coordinate.
    const auto world_x = [&](double pixel) {
        return camera_center_x +
               ((pixel - layout.viewport_px.x) / viewport_width - 0.5) * camera_width;
    };
    const auto world_y = [&](double pixel) {
        return camera_center_y +
               (0.5 - (pixel - layout.viewport_px.y) / viewport_height) * camera_height;
    };

    const double left   = world_x(0.0);
    const double bottom = world_y(window_height);
    return WallpaperCursorMapping {
        .origin_x = left,
        .origin_y = bottom,
        .size_x   = world_x(window_width) - left,
        .size_y   = world_y(0.0) - bottom,
        // The drawn image is exactly the camera rectangle, however the viewport
        // is cropped or letterboxed against the window.
        .content_origin_x = camera_center_x - 0.5 * camera_width,
        .content_origin_y = camera_center_y - 0.5 * camera_height,
        .content_size_x   = camera_width,
        .content_size_y   = camera_height,
        .valid            = true,
    };
}

} // namespace wallpaper
