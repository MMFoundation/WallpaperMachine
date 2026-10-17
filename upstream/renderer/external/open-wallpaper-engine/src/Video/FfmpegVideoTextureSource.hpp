#pragma once

#include "Video/ClockedVideoSource.hpp"

#include <memory>
#include <string>

namespace wallpaper
{
struct Image;

namespace video
{

/// The clocked video source over the FFmpeg backend: libavformat and libavcodec
/// with VideoToolbox decoding.
class FfmpegVideoTextureSource final : public ClockedVideoSource {
public:
    /// Shares `image` (see `CreateVideoTextureSource`); a payload is staged to
    /// a file for FFmpeg on the first `prime` and released afterwards.
    explicit FfmpegVideoTextureSource(std::shared_ptr<const Image> image);
    /// Opens a decoder directly on a media file, without an `Image`.
    ///
    /// Needed when a consumer is split off a shared session: the split opens a
    /// second decoder on the same file, and by then the `Image` that started
    /// the first one is gone.
    explicit FfmpegVideoTextureSource(std::string media_path);
    ~FfmpegVideoTextureSource() override;
};

} // namespace video
} // namespace wallpaper
