#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Utils/Logging.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#include <algorithm>
#include <cctype>
#include <mutex>
#include <sstream>
#include <unordered_map>

namespace wallpaper::video
{
namespace
{

struct PlaneStats {
    uint8_t min_value { 255 };
    uint8_t max_value { 0 };
    double  average { 0.0 };
    size_t  samples { 0 };
};

std::string FormatPixelFormat(OSType pixel_format)
{
    char chars[5] {
        static_cast<char>((pixel_format >> 24) & 0xff),
        static_cast<char>((pixel_format >> 16) & 0xff),
        static_cast<char>((pixel_format >> 8) & 0xff),
        static_cast<char>(pixel_format & 0xff),
        0,
    };
    bool printable = true;
    for (int i = 0; i < 4; ++i) {
        if (std::isprint(static_cast<unsigned char>(chars[i])) == 0) {
            printable = false;
            break;
        }
    }

    std::ostringstream stream;
    stream << static_cast<uint32_t>(pixel_format);
    if (printable) stream << "('" << chars << "')";
    return stream.str();
}

PlaneStats SamplePlane(
    const uint8_t* base,
    size_t width,
    size_t height,
    size_t stride,
    size_t bytes_per_pixel = 1,
    size_t channel_offset = 0)
{
    PlaneStats stats {};
    if (base == nullptr || width == 0 || height == 0 || bytes_per_pixel == 0) return stats;

    const size_t step_x = std::max<size_t>(1, width / 16);
    const size_t step_y = std::max<size_t>(1, height / 16);
    double sum = 0.0;
    for (size_t y = 0; y < height; y += step_y) {
        const uint8_t* row = base + y * stride;
        for (size_t x = 0; x < width; x += step_x) {
            const uint8_t value = row[x * bytes_per_pixel + channel_offset];
            stats.min_value = std::min(stats.min_value, value);
            stats.max_value = std::max(stats.max_value, value);
            sum += static_cast<double>(value);
            stats.samples++;
        }
    }
    if (stats.samples > 0) {
        stats.average = sum / static_cast<double>(stats.samples);
    } else {
        stats.min_value = 0;
    }
    return stats;
}

void AppendPlaneStats(std::ostringstream& stream, const char* name, const PlaneStats& stats)
{
    stream << ' ' << name << "{min=" << static_cast<int>(stats.min_value)
           << " max=" << static_cast<int>(stats.max_value)
           << " avg=" << stats.average
           << " samples=" << stats.samples
           << '}';
}

/// Colorimetry of a Core Video pixel buffer, which is what the hardware
/// decoder hands over. The pixel format decides the range; the attachment, when
/// present, decides the matrix.
YuvColorDescription ColorDescriptionForPixelBuffer(CVPixelBufferRef pixel_buffer,
                                                   OSType pixel_format,
                                                   uint32_t width,
                                                   uint32_t height)
{
    YuvColorDescription description {};
    description.range = pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ? YuvRange::Full
        : YuvRange::Limited;

    CFTypeRef matrix_attachment =
        CVBufferCopyAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey, nullptr);
    if (matrix_attachment == nullptr) {
        description.matrix = InferYuvMatrix(width, height);
        description.matrix_inferred = true;
        return description;
    }
    if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        description.matrix = YuvMatrix::Bt709;
    } else if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
    } else if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ||
               CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) {
        description.matrix = YuvMatrix::Bt601;
    } else {
        description.matrix = InferYuvMatrix(width, height);
        description.matrix_inferred = true;
    }
    CFRelease(matrix_attachment);
    return description;
}
} // namespace

/// One line per distinct colorimetry so an inferred matrix is visible in the
/// log without printing anything per frame.
void ReportInferredColor(const YuvColorDescription& description)
{
    if (!description.matrix_inferred) return;
    static std::mutex mutex;
    static std::unordered_map<uint32_t, bool> reported;
    const uint32_t key = (static_cast<uint32_t>(description.matrix) << 8) |
        static_cast<uint32_t>(description.range);
    std::lock_guard lock(mutex);
    if (!reported.try_emplace(key, true).second) return;
    LOG_INFO("video color metadata missing or unsupported; using %s %s range",
             YuvMatrixName(description.matrix),
             YuvRangeName(description.range));
}

void ReleaseAppleVideoFrame(VideoTextureFrame* frame)
{
    if (frame == nullptr) return;
    if (frame->io_surface != nullptr) {
        CFRelease(reinterpret_cast<IOSurfaceRef>(frame->io_surface));
        frame->io_surface = nullptr;
    }
    if (frame->pixel_buffer != nullptr) {
        CFRelease(reinterpret_cast<CVPixelBufferRef>(frame->pixel_buffer));
        frame->pixel_buffer = nullptr;
    }
    frame->pixel_format = 0;
    frame->plane_count = 0;
}

void RetainAppleVideoFrame(const VideoTextureFrame& frame, VideoTextureFrame* out)
{
    if (out == nullptr) return;
    ReleaseAppleVideoFrame(out);
    *out = frame;
    if (out->io_surface != nullptr) {
        CFRetain(reinterpret_cast<IOSurfaceRef>(out->io_surface));
    }
    if (out->pixel_buffer != nullptr) {
        CFRetain(reinterpret_cast<CVPixelBufferRef>(out->pixel_buffer));
    }
}

YuvColorParams AppleVideoFrameColorParams(const VideoTextureFrame& frame)
{
    auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer);
    if (pixel_buffer == nullptr) return MakeYuvColorParams(YuvColorDescription {});
    const YuvColorDescription description =
        ColorDescriptionForPixelBuffer(pixel_buffer,
                                       static_cast<OSType>(frame.pixel_format),
                                       frame.width,
                                       frame.height);
    ReportInferredColor(description);
    return MakeYuvColorParams(description);
}

std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame)
{
    std::ostringstream stream;
    const auto pixel_format = static_cast<OSType>(frame.pixel_format);
    stream << "fmt=" << FormatPixelFormat(pixel_format)
           << " size=" << frame.width << 'x' << frame.height
           << " planes=" << frame.plane_count;

    if (frame.pixel_buffer == nullptr) {
        stream << " pixel_buffer=null io_surface=" << (frame.io_surface != nullptr ? "yes" : "no");
        return stream.str();
    }

    auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer);
    const CVReturn lock_result = CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    if (lock_result != kCVReturnSuccess) {
        stream << " lock_failed=" << lock_result;
        return stream.str();
    }

    const auto unlock = [&]() {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    };

    if (CVPixelBufferIsPlanar(pixel_buffer)) {
        const size_t plane_count = CVPixelBufferGetPlaneCount(pixel_buffer);
        const size_t reported_planes = std::min<size_t>(plane_count, 3);
        for (size_t plane = 0; plane < reported_planes; ++plane) {
            const auto* base = static_cast<const uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
            const size_t width = CVPixelBufferGetWidthOfPlane(pixel_buffer, plane);
            const size_t height = CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
            const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);
            const auto stats = SamplePlane(base, width, height, stride);
            std::ostringstream name;
            name << 'p' << plane;
            AppendPlaneStats(stream, name.str().c_str(), stats);
        }
    } else {
        const auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        const size_t width = CVPixelBufferGetWidth(pixel_buffer);
        const size_t height = CVPixelBufferGetHeight(pixel_buffer);
        const size_t stride = CVPixelBufferGetBytesPerRow(pixel_buffer);
        if (pixel_format == kCVPixelFormatType_32BGRA) {
            AppendPlaneStats(stream, "b", SamplePlane(base, width, height, stride, 4, 0));
            AppendPlaneStats(stream, "g", SamplePlane(base, width, height, stride, 4, 1));
            AppendPlaneStats(stream, "r", SamplePlane(base, width, height, stride, 4, 2));
        } else {
            AppendPlaneStats(stream, "packed", SamplePlane(base, width, height, stride));
        }
    }

    unlock();
    return stream.str();
}

} // namespace wallpaper::video
