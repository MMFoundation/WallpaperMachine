#pragma once

#include "Video/VideoMetadata.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>

namespace wallpaper
{
struct Image;

namespace video
{

/// Builds the texture image for a pure-video wallpaper project.
///
/// `file_name` is the project manifest's media entry, resolved against
/// `project_directory`. The media file is not read: the returned image only
/// records where it lives, and the decoder opens it in place. Symlinks are
/// resolved before the containment test, so an entry that leaves the project
/// directory is rejected instead of followed. Returns nullptr and fills
/// `error` when the entry is empty, missing, empty on disk, outside the
/// project, or not decodable.
std::shared_ptr<Image> CreateVideoProjectImage(const std::filesystem::path& project_directory,
                                               std::string_view             file_name,
                                               std::string*                 error);

/// A private copy of what a video source reads from `image`: its key, its
/// video mark, the file it names and the bytes of its first mip.
///
/// For a caller that holds an image by reference and has no ownership to
/// share (the Vulkan texture cache), so a source opened on the copy does not
/// depend on the caller's image staying alive. Anything that owns its image
/// through a `shared_ptr` passes that instead, which copies nothing.
std::shared_ptr<const Image> SnapshotVideoImage(const Image& image);

/// Reads the picture size of a media file's video stream without decoding it.
bool ProbeVideoFileDimensions(std::string_view media_path,
                              uint32_t*        width,
                              uint32_t*        height,
                              std::string*     error);

/// Reads the picture size and the length of a media file's video stream
/// without decoding it.
bool ProbeVideoFileMetadata(std::string_view media_path,
                            VideoMetadata*   out,
                            std::string*     error);

} // namespace video
} // namespace wallpaper
