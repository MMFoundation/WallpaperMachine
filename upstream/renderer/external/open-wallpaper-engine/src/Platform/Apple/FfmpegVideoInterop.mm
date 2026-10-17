#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Video/VideoColorConversion.hpp"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#include <algorithm>
#include <cstring>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>
}

namespace wallpaper::video
{
namespace
{

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

void CopyPlaneRows(const uint8_t* src,
                   int            src_stride,
                   uint8_t*       dst,
                   int            dst_stride,
                   size_t         row_bytes,
                   size_t         rows)
{
    for (size_t row = 0; row < rows; ++row) {
        memcpy(dst + row * static_cast<size_t>(dst_stride),
               src + row * static_cast<size_t>(src_stride),
               row_bytes);
    }
}

CFStringRef CvMatrixAttachmentForFrame(const AVFrame* frame)
{
    if (frame == nullptr) return nullptr;

    switch (frame->colorspace) {
    case AVCOL_SPC_BT709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    case AVCOL_SPC_BT2020_CL:
    case AVCOL_SPC_BT2020_NCL: return kCVImageBufferYCbCrMatrix_ITU_R_2020;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_SMPTE240M: return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    default: return nullptr;
    }
}

OSType CvPixelFormatForSoftwareFrame(const AVFrame* frame)
{
    if (frame == nullptr) return 0;

    switch (frame->format) {
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P:
    case AV_PIX_FMT_NV12:
    case AV_PIX_FMT_BGRA:
        return kCVPixelFormatType_32BGRA;
    default:
        return 0;
    }
}

/// Reads the colorimetry a decoded frame declares. Unknown metadata is
/// inferred from the resolution and reported, rather than silently treated as
/// BT.601 for everything.
YuvColorDescription ColorDescriptionForFrame(const AVFrame* frame)
{
    YuvColorDescription description {};
    if (frame == nullptr) return description;

    description.range =
        frame->color_range == AVCOL_RANGE_JPEG ? YuvRange::Full : YuvRange::Limited;
    switch (frame->colorspace) {
    case AVCOL_SPC_BT709:
        description.matrix = YuvMatrix::Bt709;
        break;
    case AVCOL_SPC_BT2020_NCL:
        description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
        break;
    case AVCOL_SPC_BT2020_CL:
        // Constant-luminance BT.2020 needs a different transform. Report the
        // substitution instead of claiming support for it.
        description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
        description.matrix_inferred = true;
        break;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_SMPTE240M:
        description.matrix = YuvMatrix::Bt601;
        break;
    default:
        description.matrix = InferYuvMatrix(static_cast<uint32_t>(std::max(0, frame->width)),
                                            static_cast<uint32_t>(std::max(0, frame->height)));
        description.matrix_inferred = true;
        break;
    }
    return description;
}

bool CopySoftwareFrameToPixelBuffer(const AVFrame* frame,
                                    CVPixelBufferRef pixel_buffer,
                                    std::string* error)
{
    if (frame == nullptr || pixel_buffer == nullptr) {
        return SetError(error, "software video copy received a null frame or pixel buffer");
    }

    const CVReturn lock_result = CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (lock_result != kCVReturnSuccess) {
        return SetError(error, "failed to lock software video pixel buffer");
    }

    const auto unlock = [&]() {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    };

    const int width = frame->width;
    const int height = frame->height;
    if (width <= 0 || height <= 0) {
        unlock();
        return SetError(error, "software video frame returned an invalid size");
    }

    switch (frame->format) {
    case AV_PIX_FMT_BGRA: {
        auto* destination =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        if (destination == nullptr) {
            unlock();
            return SetError(error, "BGRA video pixel buffer has no base address");
        }
        const int destination_stride =
            static_cast<int>(CVPixelBufferGetBytesPerRow(pixel_buffer));
        CopyPlaneRows(frame->data[0],
                      frame->linesize[0],
                      destination,
                      destination_stride,
                      static_cast<size_t>(width) * 4u,
                      static_cast<size_t>(height));
        unlock();
        return true;
    }
    case AV_PIX_FMT_NV12: {
        auto* destination =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        if (destination == nullptr) {
            unlock();
            return SetError(error, "BGRA video pixel buffer has no base address");
        }
        const int destination_stride =
            static_cast<int>(CVPixelBufferGetBytesPerRow(pixel_buffer));
        const auto description = ColorDescriptionForFrame(frame);
        ReportInferredColor(description);
        const auto params = MakeYuvColorParams(description);
        for (int y = 0; y < height; ++y) {
            const uint8_t* src_y = frame->data[0] + y * frame->linesize[0];
            const uint8_t* src_uv = frame->data[1] + (y / 2) * frame->linesize[1];
            uint8_t* dst = destination + y * destination_stride;
            for (int x = 0; x < width; ++x) {
                const Rgb8 rgb = ConvertYuvCodeToRgb8(
                    params, src_y[x], src_uv[(x / 2) * 2], src_uv[(x / 2) * 2 + 1]);
                dst[x * 4] = rgb.blue;
                dst[x * 4 + 1] = rgb.green;
                dst[x * 4 + 2] = rgb.red;
                dst[x * 4 + 3] = 255;
            }
        }
        unlock();
        return true;
    }
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P: {
        auto* destination =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        if (destination == nullptr) {
            unlock();
            return SetError(error, "BGRA video pixel buffer has no base address");
        }
        const int destination_stride =
            static_cast<int>(CVPixelBufferGetBytesPerRow(pixel_buffer));
        const auto description = ColorDescriptionForFrame(frame);
        ReportInferredColor(description);
        const auto params = MakeYuvColorParams(description);
        for (int y = 0; y < height; ++y) {
            const uint8_t* src_y = frame->data[0] + y * frame->linesize[0];
            const uint8_t* src_u = frame->data[1] + (y / 2) * frame->linesize[1];
            const uint8_t* src_v = frame->data[2] + (y / 2) * frame->linesize[2];
            uint8_t* dst = destination + y * destination_stride;
            for (int x = 0; x < width; ++x) {
                const Rgb8 rgb =
                    ConvertYuvCodeToRgb8(params, src_y[x], src_u[x / 2], src_v[x / 2]);
                dst[x * 4] = rgb.blue;
                dst[x * 4 + 1] = rgb.green;
                dst[x * 4 + 2] = rgb.red;
                dst[x * 4 + 3] = 255;
            }
        }
        unlock();
        return true;
    }
    default:
        unlock();
        return SetError(error, "software video frame format is not supported");
    }
}

bool ExtractSoftwareVideoFrame(const AVFrame* frame,
                               VideoTextureFrame* out,
                               std::string* error)
{
    if (frame == nullptr) return SetError(error, "decoded software FFmpeg frame must not be null");
    if (out == nullptr) return SetError(error, "software video texture frame output must not be null");

    const OSType pixel_format = CvPixelFormatForSoftwareFrame(frame);
    if (pixel_format == 0) {
        return SetError(error, "software FFmpeg frame format is not supported on Apple video path");
    }

    CVPixelBufferRef pixel_buffer = nullptr;
    CVReturn create_result;
    @autoreleasepool {
        // Software output is sampled by the same GPU paths as VideoToolbox
        // output. Allocate its backing here, rather than copying it again at
        // import time: an ordinary CPU-only CVPixelBuffer cannot become a
        // Metal texture.
        NSDictionary* attributes = @{
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
        };
        create_result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            static_cast<size_t>(frame->width),
            static_cast<size_t>(frame->height),
            pixel_format,
            (__bridge CFDictionaryRef)attributes,
            &pixel_buffer);
    }
    if (create_result != kCVReturnSuccess || pixel_buffer == nullptr) {
        return SetError(
            error,
            "failed to create software video pixel buffer: " + std::to_string(create_result));
    }

    if (!CopySoftwareFrameToPixelBuffer(frame, pixel_buffer, error)) {
        CFRelease(pixel_buffer);
        return false;
    }

    if (const auto matrix = CvMatrixAttachmentForFrame(frame); matrix != nullptr) {
        CVBufferSetAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    }

    IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
    CFRetain(pixel_buffer);
    if (io_surface != nullptr) {
        CFRetain(io_surface);
    }
    out->width = static_cast<uint32_t>(CVPixelBufferGetWidth(pixel_buffer));
    out->height = static_cast<uint32_t>(CVPixelBufferGetHeight(pixel_buffer));
    out->pixel_buffer = pixel_buffer;
    out->io_surface = io_surface;
    out->pixel_format = static_cast<uint32_t>(CVPixelBufferGetPixelFormatType(pixel_buffer));
    out->plane_count = CVPixelBufferIsPlanar(pixel_buffer)
        ? static_cast<uint32_t>(CVPixelBufferGetPlaneCount(pixel_buffer))
        : 1u;
    CFRelease(pixel_buffer);
    return true;
}
} // namespace

bool CreateVideoToolboxDeviceContext(AVBufferRef** hw_device_ctx, std::string* error)
{
    if (hw_device_ctx == nullptr) {
        return SetError(error, "VideoToolbox hardware device output must not be null");
    }

    AVBufferRef* device_ctx = nullptr;
    const int result = av_hwdevice_ctx_create(
        &device_ctx,
        AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
        nullptr,
        nullptr,
        0);
    if (result < 0 || device_ctx == nullptr) {
        return SetError(error, "failed to create FFmpeg VideoToolbox hardware device context");
    }

    *hw_device_ctx = device_ctx;
    return true;
}

bool ExtractVideoToolboxFrame(const AVFrame* frame,
                              VideoTextureFrame* out,
                              std::string* error)
{
    if (frame == nullptr) return SetError(error, "decoded FFmpeg frame must not be null");
    if (out == nullptr) return SetError(error, "video texture frame output must not be null");
    if (frame->format != AV_PIX_FMT_VIDEOTOOLBOX) {
        return SetError(error, "decoded FFmpeg frame is not backed by VideoToolbox");
    }

    CVPixelBufferRef pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
    if (pixel_buffer == nullptr) {
        return SetError(error, "VideoToolbox frame does not carry a pixel buffer");
    }

    CFRetain(pixel_buffer);
    IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
    if (io_surface != nullptr) {
        CFRetain(io_surface);
    }
    out->width = static_cast<uint32_t>(CVPixelBufferGetWidth(pixel_buffer));
    out->height = static_cast<uint32_t>(CVPixelBufferGetHeight(pixel_buffer));
    out->pixel_buffer = pixel_buffer;
    out->io_surface = io_surface;
    out->pixel_format = static_cast<uint32_t>(CVPixelBufferGetPixelFormatType(pixel_buffer));
    out->plane_count = CVPixelBufferIsPlanar(pixel_buffer)
        ? static_cast<uint32_t>(CVPixelBufferGetPlaneCount(pixel_buffer))
        : 1u;
    return true;
}

bool ExtractAppleVideoFrame(const AVFrame* frame,
                            VideoTextureFrame* out,
                            std::string* error)
{
    if (frame == nullptr) return SetError(error, "decoded FFmpeg frame must not be null");
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        return ExtractVideoToolboxFrame(frame, out, error);
    }
    return ExtractSoftwareVideoFrame(frame, out, error);
}

} // namespace wallpaper::video
