#include "Image.hpp"
#include "Utils/Logging.h"
#include "Video/ClockedVideoSource.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "Video/NativeVideoBackend.hpp"
#include "Video/VideoBackendSelection.hpp"
#include "Video/VideoTextureSource.hpp"

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <utility>

namespace wallpaper::video
{
namespace
{

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

/// Plays with the native backend, and with another one when the native one says
/// it is the only reason the media does not play: a container its readers do not
/// read, an MP4 feature they refuse, a decoder session VideoToolbox would not
/// make. A format nobody here plays (VP8, 4:2:2, AV1 without hardware decode)
/// and media that is damaged or missing fail with the native backend's own
/// reason, which names the format.
class FallbackBackend final : public VideoFrameBackend {
public:
    FallbackBackend(std::unique_ptr<NativeVideoBackend> native,
                    std::function<std::unique_ptr<VideoFrameBackend>()> make_fallback, std::string label)
        : m_native(std::move(native)), m_make_fallback(std::move(make_fallback)), m_label(std::move(label))
    {
    }

    bool open(std::string* error) override
    {
        std::string native_error;
        if (m_native->open(&native_error)) {
            m_active.store(m_native.get());
            return true;
        }
        if (!m_native->anotherBackendMayPlay() || m_cancelled.load()) return SetError(error, std::move(native_error));

        LOG_INFO("native video \"%s\" is handed to FFmpeg: %s", m_label.c_str(), native_error.c_str());
        // The fallback takes hold of the payload before the native backend lets go of
        // it: when the source was made from a temporary image, the native backend is the
        // image's only owner and closing it first would destroy the bytes.
        m_fallback = m_make_fallback();
        m_native->close();
        if (m_fallback == nullptr) return SetError(error, std::move(native_error));
        if (m_cancelled.load()) m_fallback->cancel();
        std::string fallback_error;
        if (m_fallback->open(&fallback_error)) {
            m_active.store(m_fallback.get());
            return true;
        }
        // Both could not play it: the native reason is the one worth reading.
        LOG_INFO("FFmpeg could not play \"%s\" either: %s", m_label.c_str(), fallback_error.c_str());
        return SetError(error, std::move(native_error));
    }

    [[nodiscard]] StreamInfo streamInfo() const override { return m_active.load()->streamInfo(); }
    Decode decodeNext(double fallback_pts_seconds, DecodedPosition* position, std::string* error) override
    {
        return m_active.load()->decodeNext(fallback_pts_seconds, position, error);
    }
    bool takeFrame(VideoTextureFrame* out, std::string* error) override { return m_active.load()->takeFrame(out, error); }
    void discardFrame() override { m_active.load()->discardFrame(); }
    bool seek(double wrapped_seconds, uint64_t loop_index, std::string* error) override
    {
        return m_active.load()->seek(wrapped_seconds, loop_index, error);
    }
    [[nodiscard]] uint64_t loopIndex() const override { return m_active.load()->loopIndex(); }

    void cancel() override
    {
        m_cancelled.store(true);
        m_native->cancel();
        // The fallback exists only after `open` handed over to it; once it is the
        // active backend it is cancelled here, and before that `open` checks the
        // flag as it starts it.
        if (auto* active = m_active.load()) active->cancel();
    }

    void close() override
    {
        m_native->close();
        if (m_fallback != nullptr) m_fallback->close();
    }

private:
    std::unique_ptr<NativeVideoBackend>                  m_native;
    std::function<std::unique_ptr<VideoFrameBackend>()> m_make_fallback;
    std::string                                          m_label;
    std::unique_ptr<VideoFrameBackend>                   m_fallback;
    std::atomic<VideoFrameBackend*>                      m_active { nullptr };
    std::atomic<bool>                                    m_cancelled { false };
};

std::shared_ptr<VideoTextureSource> MakeSource(VideoBackendPreference preference,
                                               std::shared_ptr<const Image> image, std::string media_path)
{
    const std::string label = image != nullptr ? image->key : media_path;
    switch (preference) {
    case VideoBackendPreference::Ffmpeg:
        if (image != nullptr) return std::make_shared<FfmpegVideoTextureSource>(std::move(image));
        return std::make_shared<FfmpegVideoTextureSource>(std::move(media_path));
    case VideoBackendPreference::Native:
        if (image != nullptr) {
            return std::make_shared<ClockedVideoSource>(std::make_unique<NativeVideoBackend>(std::move(image)), label);
        }
        return std::make_shared<ClockedVideoSource>(std::make_unique<NativeVideoBackend>(std::move(media_path)), label);
    case VideoBackendPreference::Auto:
        break;
    }
    // The fallback may need the image's bytes, and only until the native backend has
    // taken what it needs, so it must not keep the image alive itself.
    std::unique_ptr<NativeVideoBackend> native;
    std::function<std::unique_ptr<VideoFrameBackend>()> fallback;
    if (image != nullptr) {
        native   = std::make_unique<NativeVideoBackend>(image);
        fallback = [weak = std::weak_ptr<const Image>(image)]() -> std::unique_ptr<VideoFrameBackend> {
            auto locked = weak.lock();
            return locked != nullptr ? MakeFfmpegVideoBackend(std::move(locked)) : nullptr;
        };
    } else {
        native   = std::make_unique<NativeVideoBackend>(media_path);
        fallback = [media_path] { return MakeFfmpegVideoBackend(media_path); };
    }
    return std::make_shared<ClockedVideoSource>(
        std::make_unique<FallbackBackend>(std::move(native), std::move(fallback), label), label);
}

} // namespace

std::shared_ptr<VideoTextureSource> CreateVideoTextureSource(std::shared_ptr<const Image> image,
                                                             std::string* error)
{
    if (image == nullptr) {
        SetError(error, "video texture has no image");
        return nullptr;
    }
    if (!image->header.isVideo) {
        SetError(error, "image is not marked as a video texture");
        return nullptr;
    }
    return MakeSource(CurrentVideoBackendPreference(), std::move(image), {});
}

std::shared_ptr<VideoTextureSource> CreateVideoTextureSourceForFile(std::string media_path, std::string* error)
{
    if (media_path.empty()) {
        SetError(error, "video media path must not be empty");
        return nullptr;
    }
    return MakeSource(CurrentVideoBackendPreference(), nullptr, std::move(media_path));
}

} // namespace wallpaper::video
