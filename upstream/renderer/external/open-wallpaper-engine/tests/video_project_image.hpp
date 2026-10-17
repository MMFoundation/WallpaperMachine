#pragma once
// A plain video file as the image a video texture source opens it from.
//
// The scene engine no longer plays a plain video wallpaper -- the host does, with its own
// players -- so nothing in production builds an image that names a media file on disk. The
// decoders still open one (`Image::videoFilePath`), and the tests that drive them over media
// they encode for themselves build that image here, the way the engine once did for a video
// project: the file is resolved against the project directory, must stay inside it, and is only
// probed, never read.

#include "Image.hpp"
#include "Video/VideoMedia.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

namespace wallpaper::video
{

inline void SetProjectImageError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
}

inline std::shared_ptr<Image> CreateVideoProjectImage(const std::filesystem::path& project_directory,
                                               std::string_view             file_name,
                                               std::string*                 error)
{
    if (file_name.empty()) {
        SetProjectImageError(error, "video project file entry must not be empty");
        return nullptr;
    }

    std::filesystem::path media_path(file_name);
    if (media_path.is_relative()) media_path = project_directory / media_path;

    // Both sides are canonicalised before they are compared, so a symlink is
    // followed first and a link that leaves the project is rejected rather
    // than read.
    std::error_code ec;
    const std::filesystem::path resolved_media = std::filesystem::canonical(media_path, ec);
    if (ec) {
        SetProjectImageError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }
    const std::filesystem::path resolved_project = std::filesystem::canonical(project_directory, ec);
    if (ec) {
        SetProjectImageError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }

    const std::filesystem::path relative = resolved_media.lexically_relative(resolved_project);
    if (relative.empty() || relative.begin()->native() == "..") {
        SetProjectImageError(error,
                 std::string("video project media file escapes the project directory: ") +
                     resolved_media.string());
        return nullptr;
    }

    if (!std::filesystem::is_regular_file(resolved_media, ec) || ec) {
        SetProjectImageError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }
    if (std::filesystem::file_size(resolved_media, ec) == 0 || ec) {
        SetProjectImageError(error,
                 std::string("video project media file is empty: ") + media_path.string());
        return nullptr;
    }

    uint32_t source_width  = 0;
    uint32_t source_height = 0;
    if (!ProbeVideoFileDimensions(resolved_media.string(), &source_width, &source_height, error)) {
        return nullptr;
    }

    auto image = std::make_shared<Image>();
    image->key = std::string(file_name);
    // The wallpaper's own file is the decode input. Nothing reads it into this
    // process and nothing writes a second copy of it, which is why the image
    // carries no slots.
    image->videoFilePath            = resolved_media.string();
    image->header.isVideo           = true;
    image->header.videoAudioEnabled = true;
    image->header.count             = 1;
    image->header.sample.wrapS      = TextureWrap::CLAMP_TO_EDGE;
    image->header.sample.wrapT      = TextureWrap::CLAMP_TO_EDGE;
    image->header.sample.minFilter  = TextureFilter::LINEAR;
    image->header.sample.magFilter  = TextureFilter::LINEAR;
    image->header.width             = static_cast<i32>(source_width);
    image->header.height            = static_cast<i32>(source_height);
    image->header.mapWidth          = static_cast<i32>(source_width);
    image->header.mapHeight         = static_cast<i32>(source_height);
    return image;
}

} // namespace wallpaper::video
