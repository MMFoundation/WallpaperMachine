#pragma once

#include "Video/VideoTextureSource.hpp"

#include <memory>
#include <string>

namespace wallpaper
{
struct Image;

namespace video
{

class FfmpegVideoTextureSource final : public VideoTextureSource {
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

    bool prime(std::string* error) override;
    bool syncPlayback(const VideoPlaybackState& state, std::string* error) override;
    bool refreshFrame(std::string* error) override;
    [[nodiscard]] VideoTextureFrame currentFrame() const override;
    [[nodiscard]] bool retainCurrentFrame(VideoTextureFrame* out) const override;
    [[nodiscard]] double durationSeconds() const override;
    [[nodiscard]] double playbackSeconds() const override;
    [[nodiscard]] uint64_t loopCount() const override;
    [[nodiscard]] double frameDurationSeconds() const override;
    [[nodiscard]] VideoSourceStats sourceStats() const override;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace video
} // namespace wallpaper
