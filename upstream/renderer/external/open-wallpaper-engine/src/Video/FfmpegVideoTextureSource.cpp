#include "Video/FfmpegVideoTextureSource.hpp"

#include "Image.hpp"
#include "Video/FfmpegAbi.hpp"
#include "Video/VideoDecodePump.hpp"
#include "Video/VideoFramePacing.hpp"
#include "Video/VideoMedia.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <optional>
#include <exception>
#include <filesystem>
#include <fstream>
#include <span>
#include <string>
#include <vector>

#include <unistd.h>

namespace wallpaper::video
{
namespace
{

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

std::string AvErrorString(int error_code)
{
    std::array<char, AV_ERROR_MAX_STRING_SIZE> buffer {};
    av_strerror(error_code, buffer.data(), buffer.size());
    return std::string(buffer.data());
}

std::filesystem::path VideoCacheDirectory(std::string* error)
{
    std::filesystem::path temp_dir = std::filesystem::temp_directory_path() / "wallpaper-engine-video";
    std::error_code       ec;
    std::filesystem::create_directories(temp_dir, ec);
    if (ec) {
        SetError(error, "failed to create temporary video cache directory");
        return {};
    }
    return temp_dir;
}

/// Extracts an inline video payload into the shared cache so FFmpeg can open
/// it by path.
///
/// The bytes are staged under a name unique to this attempt and only then
/// renamed onto the content-addressed name, so a concurrent opener either sees
/// nothing or sees the finished file - never a half-written one. Losing the
/// rename race is success: the winner's file holds the same bytes.
std::filesystem::path WriteVideoPayloadToTemp(std::string_view debug_label,
                                              std::span<const char> payload,
                                              std::string* error)
{
    if (payload.empty()) {
        SetError(error, "video texture payload is empty");
        return {};
    }

    const std::filesystem::path temp_dir = VideoCacheDirectory(error);
    if (temp_dir.empty()) return {};

    std::error_code ec;
    const std::string digest = utils::genSha1(payload);
    const std::filesystem::path media_path = temp_dir / (digest + ".mp4");
    const auto payload_size = static_cast<uintmax_t>(payload.size());
    if (std::filesystem::exists(media_path, ec) &&
        !ec &&
        std::filesystem::file_size(media_path, ec) == payload_size) {
        return media_path;
    }

    static std::atomic<uint64_t> staging_serial { 0 };
    const std::filesystem::path staging_path =
        temp_dir / (digest + "." + std::to_string(static_cast<long long>(getpid())) + "." +
                    std::to_string(staging_serial.fetch_add(1, std::memory_order_relaxed)) + ".part");
    std::ofstream output(staging_path, std::ios::binary | std::ios::trunc);
    if (!output.good()) {
        SetError(error, "failed to open temporary video cache file");
        return {};
    }

    output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    output.close();
    // The size on disk is the completion check: a short write is discarded
    // instead of reaching the published name.
    if (!output.good() || std::filesystem::file_size(staging_path, ec) != payload_size || ec) {
        std::filesystem::remove(staging_path, ec);
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    std::filesystem::rename(staging_path, media_path, ec);
    if (ec) {
        std::error_code remove_ec;
        std::filesystem::remove(staging_path, remove_ec);
        if (std::filesystem::file_size(media_path, ec) == payload_size && !ec) return media_path;
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    LOG_INFO("prepared FFmpeg video payload cache for \"%s\": %s",
             std::string(debug_label).c_str(),
             media_path.string().c_str());
    return media_path;
}

double ProbeDurationSeconds(AVFormatContext* format_context, AVStream* stream)
{
    if (stream != nullptr && stream->duration > 0) {
        const double stream_duration = stream->duration * av_q2d(stream->time_base);
        if (std::isfinite(stream_duration) && stream_duration > 0.0) return stream_duration;
    }
    if (format_context != nullptr && format_context->duration > 0) {
        const double format_duration =
            static_cast<double>(format_context->duration) / static_cast<double>(AV_TIME_BASE);
        if (std::isfinite(format_duration) && format_duration > 0.0) return format_duration;
    }
    return 0.0;
}

/// Shortest period the container's declared rates imply.
///
/// `avg_frame_rate` is an average and `r_frame_rate` is libavformat's estimate,
/// so neither proves how far apart two particular frames are. This value is
/// only ever combined with observed presentation timestamps, never trusted on
/// its own to decide that a frame can be skipped.
double ProbeShortestFrameDurationSeconds(AVStream* stream)
{
    if (stream == nullptr) return 0.0;
    const std::array<video::FrameRateRatio, 2> rates {
        video::FrameRateRatio { stream->avg_frame_rate.num, stream->avg_frame_rate.den },
        video::FrameRateRatio { stream->r_frame_rate.num, stream->r_frame_rate.den },
    };
    return video::ShortestMetadataPeriodSeconds(rates.data(), rates.size());
}

double ProbeFrameDurationSeconds(AVStream* stream)
{
    if (stream == nullptr) return 1.0 / 60.0;
    const AVRational frame_rate = stream->avg_frame_rate.num != 0 && stream->avg_frame_rate.den != 0
        ? stream->avg_frame_rate
        : stream->r_frame_rate;
    if (frame_rate.num > 0 && frame_rate.den > 0) {
        const double fps = av_q2d(frame_rate);
        if (std::isfinite(fps) && fps > 0.0) return 1.0 / fps;
    }
    return 1.0 / 60.0;
}

std::optional<std::array<int32_t, 9>> StreamDisplayMatrix(const AVStream* stream) {
    if (stream == nullptr || stream->codecpar == nullptr) return std::nullopt;
    const auto* side = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (side == nullptr || side->data == nullptr || side->size < 9 * sizeof(int32_t)) return std::nullopt;
    std::array<int32_t, 9> matrix;
    std::memcpy(matrix.data(), side->data, sizeof(matrix));
    return matrix;
}

bool ProbeStreamDimensions(AVStream* stream, uint32_t* width, uint32_t* height, std::string* error)
{
    if (stream == nullptr) return SetError(error, "FFmpeg video stream must not be null");
    if (width == nullptr) return SetError(error, "video width output must not be null");
    if (height == nullptr) return SetError(error, "video height output must not be null");
    if (stream->codecpar == nullptr) return SetError(error, "FFmpeg video stream has no codec parameters");

    uint32_t resolved_width = static_cast<uint32_t>(std::max(0, stream->codecpar->width));
    uint32_t resolved_height = static_cast<uint32_t>(std::max(0, stream->codecpar->height));
    if (resolved_width == 0 || resolved_height == 0) {
        return SetError(error, "FFmpeg video stream returned an invalid size");
    }

    if (const auto matrix = StreamDisplayMatrix(stream)) {
        const auto transform = ResolveVideoDisplayTransform(*matrix, resolved_width, resolved_height);
        if (! transform) return SetError(error, "video display transform is not a valid affine transform");
        resolved_width = transform->width;
        resolved_height = transform->height;
    }

    *width = resolved_width;
    *height = resolved_height;
    return true;
}

#if defined(__APPLE__)
AVPixelFormat AppleHardwarePixelFormat(const AVCodec* codec)
{
    for (int index = 0;; ++index) {
        const AVCodecHWConfig* config = avcodec_get_hw_config(codec, index);
        if (config == nullptr) return AV_PIX_FMT_NONE;
        if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 &&
            config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
            return config->pix_fmt;
        }
    }
}

const AVCodec* SelectAppleHardwareDecoder(const AVCodec* preferred, AVPixelFormat* pixel_format)
{
    *pixel_format = AppleHardwarePixelFormat(preferred);
    if (*pixel_format != AV_PIX_FMT_NONE) return preferred;

    // FFmpeg's default can be software-only even when another decoder for the
    // same codec supports VideoToolbox (libdav1d versus native AV1, for example).
    // Search only at open, and keep the same hardware capability requirement.
    void* iterator = nullptr;
    while (const AVCodec* candidate = av_codec_iterate(&iterator)) {
        if (candidate->id != preferred->id || !av_codec_is_decoder(candidate)) continue;
        const auto format = AppleHardwarePixelFormat(candidate);
        if (format == AV_PIX_FMT_NONE) continue;
        *pixel_format = format;
        return candidate;
    }
    return nullptr;
}

AVPixelFormat SelectAppleHardwareFormat(AVCodecContext* context, const AVPixelFormat* formats)
{
    if (context == nullptr || formats == nullptr) return AV_PIX_FMT_NONE;

    const AVPixelFormat desired_format =
        context->opaque != nullptr
        ? *reinterpret_cast<const AVPixelFormat*>(context->opaque)
        : AV_PIX_FMT_NONE;
    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == desired_format) {
            return *format;
        }
    }

    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        const auto* descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor != nullptr &&
            (descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL) == 0) {
            return *format;
        }
    }

    return formats[0];
}
#endif

double FramePtsSeconds(const AVFrame* frame, AVRational time_base, double fallback_seconds)
{
    if (frame == nullptr) return fallback_seconds;
    if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        const double seconds = frame->best_effort_timestamp * av_q2d(time_base);
        if (std::isfinite(seconds) && seconds >= 0.0) return seconds;
    }
    if (frame->pts != AV_NOPTS_VALUE) {
        const double seconds = frame->pts * av_q2d(time_base);
        if (std::isfinite(seconds) && seconds >= 0.0) return seconds;
    }
    return fallback_seconds;
}

/// The libav side of a clocked video source: libavformat demuxes the media,
/// libavcodec decodes it with VideoToolbox, and `VideoDecodePump` drives the
/// send/receive protocol. The clock, the queues and the seek policy are the
/// `ClockedVideoSource`'s.
class FfmpegBackend final : public VideoFrameBackend {
public:
    /// Opens the decoder on a media file directly. The path has already been
    /// resolved and validated by whoever opened the first decoder on it.
    explicit FfmpegBackend(std::string media_path)
        : m_debug_label(media_path), m_media_path(std::move(media_path))
    {
        if (m_media_path.empty()) {
            m_initial_error = "video media path must not be empty";
        }
    }

    explicit FfmpegBackend(std::shared_ptr<const Image> image)
        : m_debug_label(image != nullptr ? image->key : std::string())
    {
        if (image == nullptr) {
            m_initial_error = "video texture has no image";
            return;
        }
        if (!image->header.isVideo) {
            m_initial_error = "image is not marked as a video texture";
            return;
        }
        if (!image->videoFilePath.empty()) {
            // The media already is a file: the decoder opens it where it lies,
            // so this source never holds the video's bytes at all.
            m_media_path = image->videoFilePath;
            return;
        }
        if (image->slots.empty() || image->slots.front().mipmaps.empty()) {
            m_initial_error = "video texture has no mip payload";
            return;
        }

        const auto& mip = image->slots.front().mipmaps.front();
        if (mip.data == nullptr || mip.size <= 0) {
            m_initial_error = "video texture payload is empty";
            return;
        }

        // The bytes stay where the parser put them; this source shares the
        // image they are in. That is what lets a source outlive the scene's own
        // reference, which a source held across a rebuild of the render graph
        // does before anything has opened it.
        m_payload = std::move(image);
    }

    ~FfmpegBackend() override { close(); }

    bool open(std::string* error) override
    {
        if (!m_initial_error.empty()) return SetError(error, m_initial_error);
        return openDecoder(error);
    }

    [[nodiscard]] StreamInfo streamInfo() const override { return m_stream_info; }

    Decode decodeNext(double fallback_pts_seconds, DecodedPosition* position, std::string* error) override
    {
        switch (m_pump.NextFrame(error)) {
        case VideoDecodePump::Outcome::Cancelled:
            return Decode::Cancelled;
        case VideoDecodePump::Outcome::Failed:
            return Decode::Failed;
        case VideoDecodePump::Outcome::Frame:
            break;
        }
        position->loop_index = m_pump.loopIndex();
        position->pts_seconds =
            FramePtsSeconds(m_frame, m_video_stream->time_base, fallback_pts_seconds);
        return Decode::Frame;
    }

    bool takeFrame(VideoTextureFrame* out, std::string* error) override
    {
        VideoTextureFrame frame {};
        if (!ExtractAppleVideoFrame(m_frame, &frame, error)) {
            av_frame_unref(m_frame);
            return false;
        }

        if (m_display_matrix) {
            const auto transform = ResolveVideoDisplayTransform(*m_display_matrix, frame.width, frame.height);
            if (! transform) {
                ReleaseAppleVideoFrame(&frame);
                av_frame_unref(m_frame);
                return SetError(error, "video display transform is not a valid affine transform");
            }
            frame.display_transform = *transform;
        }
        *out = frame;
        av_frame_unref(m_frame);
        return true;
    }

    void discardFrame() override { av_frame_unref(m_frame); }

    bool seek(double wrapped_seconds, uint64_t loop_index, std::string* error) override
    {
        if (!seekToSeconds(wrapped_seconds, error)) return false;

        // The packet the pump may still be holding belongs to the position we
        // just left, so the seek is what releases it.
        m_pump.ResetForSeek();
        m_pump.setLoopIndex(loop_index);
        return true;
    }

    [[nodiscard]] uint64_t loopIndex() const override { return m_pump.loopIndex(); }

    void cancel() override { m_cancel_requested.store(true, std::memory_order_relaxed); }

    void close() override
    {
        if (m_packet != nullptr) av_packet_free(&m_packet);
        if (m_frame != nullptr) av_frame_free(&m_frame);
        if (m_codec_context != nullptr) avcodec_free_context(&m_codec_context);
        if (m_format_context != nullptr) avformat_close_input(&m_format_context);
        if (m_hw_device_context != nullptr) av_buffer_unref(&m_hw_device_context);
        m_video_stream = nullptr;
        m_video_stream_index = -1;
    }

private:
    /// Packets of other streams consumed within one `ReadPacket` call before
    /// yielding, so a badly interleaved container cannot monopolize the step.
    static constexpr int kMaxForeignPacketsPerRead = 64;

    /// libavcodec-backed source for `VideoDecodePump`. It borrows the decoder
    /// objects owned by the backend and is only ever touched by the decode thread.
    class DecodeSource final : public VideoDecodeSource {
    public:
        explicit DecodeSource(FfmpegBackend& owner) : m_owner(owner) {}

        DecodeStatus ReadPacket(std::string* error) override
        {
            for (int skipped = 0; skipped <= kMaxForeignPacketsPerRead; ++skipped) {
                const int result = av_read_frame(m_owner.m_format_context, m_owner.m_packet);
                if (result == AVERROR_EOF) return DecodeStatus::EndOfStream;
                if (result == AVERROR(EAGAIN)) return DecodeStatus::Again;
                if (result < 0) {
                    // An interrupted read is cancellation, not a stream defect.
                    if (m_owner.m_cancel_requested.load(std::memory_order_relaxed)) {
                        return DecodeStatus::Again;
                    }
                    SetError(error, "failed to read FFmpeg packet: " + AvErrorString(result));
                    return DecodeStatus::Error;
                }
                if (m_owner.m_packet->stream_index == m_owner.m_video_stream_index) {
                    return DecodeStatus::Ok;
                }
                av_packet_unref(m_owner.m_packet);
            }
            return DecodeStatus::Again;
        }

        DecodeStatus SendPacket(std::string* error) override
        {
            const int result = avcodec_send_packet(m_owner.m_codec_context, m_owner.m_packet);
            if (result == 0) return DecodeStatus::Ok;
            if (result == AVERROR(EAGAIN)) return DecodeStatus::Again;
            if (result == AVERROR_EOF) return DecodeStatus::EndOfStream;
            SetError(error,
                     "failed to submit FFmpeg packet to decoder: " + AvErrorString(result));
            return DecodeStatus::Error;
        }

        void ReleasePacket() override { av_packet_unref(m_owner.m_packet); }

        DecodeStatus SendDrainRequest(std::string* error) override
        {
            const int result = avcodec_send_packet(m_owner.m_codec_context, nullptr);
            // A decoder that is already draining reports EOF for a second null
            // packet; both mean draining is under way.
            if (result == 0 || result == AVERROR_EOF) return DecodeStatus::Ok;
            SetError(error, "failed to start FFmpeg decoder drain: " + AvErrorString(result));
            return DecodeStatus::Error;
        }

        DecodeStatus ReceiveFrame(std::string* error) override
        {
            const int result = avcodec_receive_frame(m_owner.m_codec_context, m_owner.m_frame);
            if (result == 0) return DecodeStatus::Ok;
            if (result == AVERROR(EAGAIN)) return DecodeStatus::Again;
            if (result == AVERROR_EOF) return DecodeStatus::EndOfStream;
            SetError(error,
                     "failed to receive FFmpeg decoded frame: " + AvErrorString(result));
            return DecodeStatus::Error;
        }

        bool RestartAtStreamStart(std::string* error) override
        {
            return m_owner.seekToSeconds(0.0, error);
        }

        [[nodiscard]] bool IsCancelled() const override
        {
            return m_owner.m_cancel_requested.load(std::memory_order_relaxed);
        }

    private:
        FfmpegBackend& m_owner;
    };

    /// Aborts blocking libavformat I/O once cancellation is requested, so
    /// `stop()` does not wait on a stalled read before joining the thread.
    static int InterruptDecoder(void* opaque)
    {
        const auto* backend = static_cast<const FfmpegBackend*>(opaque);
        return backend != nullptr && backend->m_cancel_requested.load(std::memory_order_relaxed) ? 1 : 0;
    }

    /// Makes the media openable by path.
    ///
    /// A file-backed source already has its path and keeps it. An inline
    /// payload is extracted once and then let go, so the decoder does not go
    /// on holding the video's bytes, and keeping the image alive, for the rest
    /// of playback.
    bool resolveMediaPath(std::string* error)
    {
        if (!m_media_path.empty()) return true;
        if (m_payload == nullptr) {
            SetError(error, "video texture payload is empty");
            return false;
        }

        // The constructor checked that the first mip exists and is not empty.
        const auto& mip = m_payload->slots.front().mipmaps.front();
        m_media_path = WriteVideoPayloadToTemp(
            m_debug_label,
            std::span(reinterpret_cast<const char*>(mip.data.get()), static_cast<size_t>(mip.size)),
            error);
        if (m_media_path.empty()) return false;
        m_payload.reset();
        return true;
    }

    bool openDecoder(std::string* error)
    {
        if (auto mismatch = FfmpegAbiMismatch(); !mismatch.empty()) {
            return SetError(error, std::move(mismatch));
        }
        if (!resolveMediaPath(error)) return false;

        AVFormatContext* format_context = avformat_alloc_context();
        if (format_context == nullptr) {
            return SetError(error, "failed to allocate FFmpeg format context");
        }
        // Installed before opening so a stalled open is cancellable too.
        format_context->interrupt_callback.callback = &FfmpegBackend::InterruptDecoder;
        format_context->interrupt_callback.opaque = this;
        if (const int result = avformat_open_input(&format_context, m_media_path.c_str(), nullptr, nullptr);
            result < 0) {
            return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
        }

        if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
        }

        const int video_stream_index =
            av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (video_stream_index < 0) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
        }
        // Audio (and every other stream) is not decoded here. Discarding it
        // stops the demuxer from reading those packets at all; the video
        // stream, its PTS and the loop seam are unchanged.
        for (unsigned index = 0; index < format_context->nb_streams; ++index) {
            if (static_cast<int>(index) == video_stream_index) continue;
            if (format_context->streams[index] != nullptr) {
                format_context->streams[index]->discard = AVDISCARD_ALL;
            }
        }

        AVStream* video_stream = format_context->streams[video_stream_index];
        if (video_stream == nullptr || video_stream->codecpar == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "FFmpeg video stream is missing codec parameters");
        }

        const AVCodec* codec = avcodec_find_decoder(video_stream->codecpar->codec_id);
        if (codec == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to find FFmpeg decoder for video stream");
        }
#if defined(__APPLE__)
        codec = SelectAppleHardwareDecoder(codec, &m_hw_pixel_format);
        if (codec == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "FFmpeg decoder does not advertise VideoToolbox hardware decode");
        }
#endif

        AVCodecContext* codec_context = avcodec_alloc_context3(codec);
        if (codec_context == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to allocate FFmpeg decoder context");
        }

        if (const int result = avcodec_parameters_to_context(codec_context, video_stream->codecpar);
            result < 0) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "failed to copy FFmpeg codec parameters: " + AvErrorString(result));
        }

#if defined(__APPLE__)
        codec_context->get_format = SelectAppleHardwareFormat;
        codec_context->opaque = &m_hw_pixel_format;
        if (!CreateVideoToolboxDeviceContext(&m_hw_device_context, error)) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return false;
        }
        codec_context->hw_device_ctx = av_buffer_ref(m_hw_device_context);
        if (codec_context->hw_device_ctx == nullptr) {
            av_buffer_unref(&m_hw_device_context);
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "failed to retain FFmpeg VideoToolbox device context");
        }
#endif

        if (const int result = avcodec_open2(codec_context, codec, nullptr); result < 0) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            av_buffer_unref(&m_hw_device_context);
            return SetError(error, "failed to open FFmpeg decoder: " + AvErrorString(result));
        }

        AVPacket* packet = av_packet_alloc();
        AVFrame*  frame = av_frame_alloc();
        if (packet == nullptr || frame == nullptr) {
            av_packet_free(&packet);
            av_frame_free(&frame);
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            av_buffer_unref(&m_hw_device_context);
            return SetError(error, "failed to allocate FFmpeg packet/frame buffers");
        }

        m_format_context = format_context;
        m_codec_context = codec_context;
        m_video_stream = video_stream;
        m_display_matrix = StreamDisplayMatrix(video_stream);
        m_video_stream_index = video_stream_index;
        m_packet = packet;
        m_frame = frame;
        m_stream_info.duration_seconds = ProbeDurationSeconds(format_context, video_stream);
        m_stream_info.frame_duration_seconds = ProbeFrameDurationSeconds(video_stream);
        m_stream_info.shortest_declared_period_seconds = ProbeShortestFrameDurationSeconds(video_stream);
        return true;
    }

    bool seekToSeconds(double seconds, std::string* error)
    {
        if (m_format_context == nullptr || m_codec_context == nullptr || m_video_stream == nullptr) {
            return SetError(error, "FFmpeg decoder is not initialized");
        }

        const int64_t target_timestamp = av_rescale_q(
            static_cast<int64_t>(seconds * static_cast<double>(AV_TIME_BASE)),
            AVRational { 1, AV_TIME_BASE },
            m_video_stream->time_base);
        if (const int result = av_seek_frame(
                m_format_context,
                m_video_stream_index,
                std::max<int64_t>(0, target_timestamp),
                AVSEEK_FLAG_BACKWARD);
            result < 0) {
            return SetError(error, "failed to seek FFmpeg video stream: " + AvErrorString(result));
        }

        avcodec_flush_buffers(m_codec_context);
        av_frame_unref(m_frame);
        av_packet_unref(m_packet);
        return true;
    }

private:
    std::string                      m_debug_label;
    /// The image whose first mip holds an inline payload, shared with whoever
    /// parsed it, until the payload has been staged for FFmpeg. Null for a
    /// file-backed source and once the file exists.
    std::shared_ptr<const Image>     m_payload;
    std::filesystem::path            m_media_path;
    std::string                      m_initial_error;
    StreamInfo                       m_stream_info;
    /// Read by the decode thread's inner loops and by the libavformat
    /// interrupt callback.
    std::atomic<bool>                m_cancel_requested { false };
    AVFormatContext*                 m_format_context { nullptr };
    AVCodecContext*                  m_codec_context { nullptr };
    AVBufferRef*                     m_hw_device_context { nullptr };
    AVStream*                        m_video_stream { nullptr };
    std::optional<std::array<int32_t, 9>> m_display_matrix;
    int                              m_video_stream_index { -1 };
    AVPacket*                        m_packet { nullptr };
    AVFrame*                         m_frame { nullptr };
    AVPixelFormat                    m_hw_pixel_format { AV_PIX_FMT_NONE };
    /// Declared last so the decoder handles above are initialized before the
    /// source that borrows them. Both are owned by the decode thread.
    DecodeSource                     m_decode_source { *this };
    VideoDecodePump                  m_pump { m_decode_source };
};

} // namespace

FfmpegVideoTextureSource::FfmpegVideoTextureSource(std::shared_ptr<const Image> image)
    : ClockedVideoSource(std::make_unique<FfmpegBackend>(image),
                         image != nullptr ? image->key : std::string())
{
}

FfmpegVideoTextureSource::FfmpegVideoTextureSource(std::string media_path)
    : ClockedVideoSource(std::make_unique<FfmpegBackend>(media_path), media_path)
{
}

FfmpegVideoTextureSource::~FfmpegVideoTextureSource() = default;

std::unique_ptr<VideoFrameBackend> MakeFfmpegVideoBackend(std::shared_ptr<const Image> image)
{
    return std::make_unique<FfmpegBackend>(std::move(image));
}

std::unique_ptr<VideoFrameBackend> MakeFfmpegVideoBackend(std::string media_path)
{
    return std::make_unique<FfmpegBackend>(std::move(media_path));
}

bool ProbeVideoFileDimensions(std::string_view media_path,
                              uint32_t*        width,
                              uint32_t*        height,
                              std::string*     error)
{
    if (media_path.empty()) return SetError(error, "video media path must not be empty");

    AVFormatContext* format_context = nullptr;
    if (const int result = avformat_open_input(&format_context,
                                               std::string(media_path).c_str(),
                                               nullptr,
                                               nullptr);
        result < 0) {
        return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
    }

    if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
    }

    const int video_stream_index =
        av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
    }

    AVStream* stream = format_context->streams[video_stream_index];
    const bool ok = ProbeStreamDimensions(stream, width, height, error);
    avformat_close_input(&format_context);
    return ok;
}

bool ProbeVideoFileMetadata(std::string_view media_path,
                            VideoMetadata*   out,
                            std::string*     error)
{
    if (out == nullptr) return SetError(error, "video metadata output must not be null");
    if (media_path.empty()) return SetError(error, "video media path must not be empty");
    if (auto mismatch = FfmpegAbiMismatch(); !mismatch.empty()) {
        return SetError(error, std::move(mismatch));
    }

    AVFormatContext* format_context = nullptr;
    if (const int result = avformat_open_input(&format_context,
                                               std::string(media_path).c_str(),
                                               nullptr,
                                               nullptr);
        result < 0) {
        return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
    }

    if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
    }

    const int video_stream_index =
        av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
    }

    AVStream* stream = format_context->streams[video_stream_index];
    const bool ok = ProbeStreamDimensions(stream, &out->width, &out->height, error);
    if (ok) {
        out->duration_seconds = ProbeDurationSeconds(format_context, stream);
    }
    avformat_close_input(&format_context);
    return ok;
}

} // namespace wallpaper::video