// See synthetic_video.hpp. Encoding is VTCompressionSession (H.264), once per
// group of pictures; writing is AVAssetWriter in passthrough, so "write N
// repeats" re-times the already compressed samples and never encodes again.

#include "synthetic_video.hpp"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace wallpaper::video
{
namespace testing_media
{
namespace
{

/// Ticks per second of every time this file hands to Core Media and to the
/// writer. One frame lasts 20 of them.
constexpr int32_t kTimescale  = 600;
constexpr int32_t kFrameTicks = kTimescale / 30;

/// One encoded group of pictures, kept as the compressed samples the encoder
/// produced so that writing a file never has to encode again.
struct EncodedGop {
    std::vector<CMSampleBufferRef> samples;
    CMFormatDescriptionRef         format { nullptr };
    int                            frames { 0 };
    /// Samples the encoder did not mark as dependent on an earlier one: a clip
    /// is seeked from the nearest one before the frame asked for.
    int                            keyframes { 0 };
    /// Whether any sample is decoded before one that is shown earlier.
    bool                           has_reordering { false };

    EncodedGop() = default;
    EncodedGop(const EncodedGop&) = delete;
    EncodedGop& operator=(const EncodedGop&) = delete;
    ~EncodedGop() {
        for (CMSampleBufferRef sample : samples) CFRelease(sample);
        if (format != nullptr) CFRelease(format);
    }

    [[nodiscard]] bool empty() const { return samples.empty(); }
};

bool IsSyncSample(CMSampleBufferRef sample) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments == nullptr || CFArrayGetCount(attachments) == 0) return true;
    auto* dictionary = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    CFTypeRef not_sync = CFDictionaryGetValue(dictionary, kCMSampleAttachmentKey_NotSync);
    return not_sync == nullptr || CFBooleanGetValue(static_cast<CFBooleanRef>(not_sync)) == false;
}

/// A neutral-chroma picture whose luma plane is `luma(x, y)`, in the planar
/// 4:2:0 layout the encoder takes. The codes are the encoder's input as they
/// stand: nothing converts them, so a test that knows the luma it asked for
/// knows the code the decoder should return.
template <typename Luma>
CVPixelBufferRef MakePicture(Luma&& luma) {
    NSDictionary* attributes = @{
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, kFrameWidth, kFrameHeight,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess) {
        return nullptr;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    auto*        plane  = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    for (int y = 0; y < kFrameHeight; ++y) {
        uint8_t* row = plane + static_cast<size_t>(y) * stride;
        for (int x = 0; x < kFrameWidth; ++x) row[x] = luma(x, y);
    }
    auto*        chroma        = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
    const size_t chroma_stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    for (int y = 0; y < kFrameHeight / 2; ++y) {
        std::memset(chroma + static_cast<size_t>(y) * chroma_stride, 128, kFrameWidth);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

void SetProperty(VTCompressionSessionRef session, CFStringRef key, CFTypeRef value) {
    // A property this encoder does not know is not a failure: the group is
    // checked afterwards for what the tests rely on (frame count, keyframes).
    (void)VTSessionSetProperty(session, key, value);
}

/// Encodes `frames` frames of 640x360 at 30 per second, with a keyframe every
/// `gop_size` of them at most and, unless `reordering` asks for B-frames, no
/// frame reordering, so that decode order is display order. `luma(index, x, y)` is the plane the encoder is given. Empty
/// when no encoder is available or it did not return every frame.
template <typename Luma>
std::unique_ptr<EncodedGop> EncodeFrames(int frames, int gop_size, int64_t bit_rate, Luma&& luma,
                                         bool reordering = false) {
    auto gop = std::make_unique<EncodedGop>();

    VTCompressionSessionRef session = nullptr;
    @autoreleasepool {
        NSDictionary* specification = @{
            (__bridge NSString*)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES,
        };
        if (VTCompressionSessionCreate(kCFAllocatorDefault, kFrameWidth, kFrameHeight,
                                       kCMVideoCodecType_H264,
                                       (__bridge CFDictionaryRef)specification, nullptr,
                                       kCFAllocatorDefault, nullptr, nullptr,
                                       &session) != noErr ||
            session == nullptr) {
            return gop;
        }
    }
    SetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    SetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering,
                reordering ? kCFBooleanTrue : kCFBooleanFalse);
    SetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                kVTProfileLevel_H264_Main_AutoLevel);
    @autoreleasepool {
        SetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(gop_size));
        SetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(30));
        SetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(bit_rate));
    }
    if (VTCompressionSessionPrepareToEncodeFrames(session) != noErr) {
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
        return gop;
    }

    // The output handler runs on the encoder's thread and a block captures
    // C++ locals by const copy, so the shared state is reached through a
    // pointer.
    struct Collected {
        std::mutex                     mutex;
        bool                           failed { false };
        std::vector<CMSampleBufferRef> samples;
    } collected;
    Collected* const shared = &collected;
    bool             failed = false;
    for (int index = 0; index < frames && !failed; ++index) {
        @autoreleasepool {
            CVPixelBufferRef picture = MakePicture([&](int x, int y) { return luma(index, x, y); });
            if (picture == nullptr) {
                failed = true;
                break;
            }
            const OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(
                session, picture, CMTimeMake(static_cast<int64_t>(index) * kFrameTicks, kTimescale),
                CMTimeMake(kFrameTicks, kTimescale), nullptr, nullptr,
                ^(OSStatus result, VTEncodeInfoFlags, CMSampleBufferRef sample) {
                    std::lock_guard lock(shared->mutex);
                    if (result != noErr || sample == nullptr) {
                        shared->failed = true;
                        return;
                    }
                    CFRetain(sample);
                    shared->samples.push_back(sample);
                });
            CFRelease(picture);
            if (status != noErr) failed = true;
        }
    }
    if (!failed) {
        if (VTCompressionSessionCompleteFrames(session, kCMTimeInvalid) != noErr) failed = true;
    }
    VTCompressionSessionInvalidate(session);
    CFRelease(session);

    std::lock_guard lock(collected.mutex);
    std::vector<CMSampleBufferRef> samples = std::move(collected.samples);
    if (failed || collected.failed || static_cast<int>(samples.size()) != frames) {
        for (CMSampleBufferRef sample : samples) CFRelease(sample);
        return gop;
    }
    gop->samples = std::move(samples);
    gop->frames  = frames;
    gop->format  = CMSampleBufferGetFormatDescription(gop->samples.front());
    if (gop->format == nullptr) {
        gop->samples.clear();
        return gop;
    }
    CFRetain(gop->format);
    CMTime last_pts = kCMTimeNegativeInfinity;
    for (CMSampleBufferRef sample : gop->samples) {
        if (IsSyncSample(sample)) ++gop->keyframes;
        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        if (CMTimeCompare(pts, last_pts) < 0) gop->has_reordering = true;
        last_pts = pts;
    }
    return gop;
}

const EncodedGop& SharedGop() {
    static const std::unique_ptr<EncodedGop> gop = EncodeFrames(
        kGopFrames, kGopFrames,
        // Noise at a high bitrate is what makes a repeatable gop big enough to
        // tell "read the file" apart from "opened the file" in memory terms.
        200000000, [](int index, int x, int y) { return FrameLuma(index, x, y); });
    return *gop;
}

/// A bright bar over a dark ground, in a place of its own for every frame, which
/// stays legible after the encoder and the draw have done what they do to noise.
/// The group of pictures is encoded once per test binary.
const EncodedGop& SharedLongGop() {
    static const std::unique_ptr<EncodedGop> gop = EncodeFrames(
        kLongGopFrames, kLongGopFrames, 6000000, [](int index, int x, int) {
            const int left = LongGopBarColumn(index);
            return static_cast<uint8_t>(x >= left && x < left + kBarWidth ? 235 : 70);
        });
    return *gop;
}

/// Two groups of pictures with B-frames, so decode order differs from display
/// order. Noise like the shared group, at a rate that leaves the frames apart.
const EncodedGop& SharedReorderedGop() {
    static const std::unique_ptr<EncodedGop> gop = EncodeFrames(
        kReorderedFrames, kReorderedFrames / 2, 30000000,
        [](int index, int x, int y) { return FrameLuma(index, x, y); }, true);
    return *gop;
}

/// Writes a decodable MP4 holding `repeats` copies of `gop`.
bool WriteMuxedVideo(const EncodedGop& gop, const std::filesystem::path& path, int repeats,
                     const std::string& salt,
                     std::optional<std::array<int32_t, 9>> display_matrix) {
    if (gop.empty() || repeats < 1) return false;

    @autoreleasepool {
        std::error_code ec;
        std::filesystem::remove(path, ec);
        NSURL*   url   = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        NSError* error = nil;
        AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:url
                                                          fileType:AVFileTypeMPEG4
                                                             error:&error];
        if (writer == nil) return false;

        // Passthrough: no output settings, so the writer takes the compressed
        // samples as they are and only times them.
        AVAssetWriterInput* input = [[AVAssetWriterInput alloc]
            initWithMediaType:AVMediaTypeVideo
               outputSettings:nil
             sourceFormatHint:gop.format];
        input.expectsMediaDataInRealTime = NO;
        input.mediaTimeScale             = kTimescale;
        if (display_matrix) {
            const auto& m = *display_matrix;
            const auto  to_double = [](int32_t fixed) { return static_cast<double>(fixed) / 65536.0; };
            input.transform = CGAffineTransformMake(to_double(m[0]), to_double(m[1]),
                                                    to_double(m[3]), to_double(m[4]), 0, 0);
        }
        if (![writer canAddInput:input]) return false;
        [writer addInput:input];

        AVMutableMetadataItem* comment = [[AVMutableMetadataItem alloc] init];
        comment.identifier = AVMetadataIdentifieriTunesMetadataUserComment;
        comment.dataType   = (__bridge NSString*)kCMMetadataBaseDataType_UTF8;
        comment.value      = [NSString stringWithUTF8String:salt.c_str()];
        writer.metadata    = @[ comment ];

        if (![writer startWriting]) return false;
        [writer startSessionAtSourceTime:kCMTimeZero];

        bool ok = true;
        for (int repeat = 0; ok && repeat < repeats; ++repeat) {
            const CMTime base = CMTimeMake(
                static_cast<int64_t>(gop.frames) * kFrameTicks * repeat, kTimescale);
            for (CMSampleBufferRef source : gop.samples) {
                if (!ok) break;
                @autoreleasepool {
                    CMSampleTimingInfo timing {};
                    if (CMSampleBufferGetSampleTimingInfo(source, 0, &timing) != noErr) {
                        ok = false;
                        break;
                    }
                    timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, base);
                    if (CMTIME_IS_VALID(timing.decodeTimeStamp)) {
                        timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, base);
                    }
                    CMSampleBufferRef retimed = nullptr;
                    if (CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, source, 1,
                                                              &timing, &retimed) != noErr ||
                        retimed == nullptr) {
                        ok = false;
                        break;
                    }
                    // The writer takes samples at the pace it can write them;
                    // a clip that is many megabytes is paced here.
                    const auto deadline =
                        std::chrono::steady_clock::now() + std::chrono::seconds(30);
                    while (!input.isReadyForMoreMediaData &&
                           writer.status == AVAssetWriterStatusWriting &&
                           std::chrono::steady_clock::now() < deadline) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                    ok = writer.status == AVAssetWriterStatusWriting &&
                         input.isReadyForMoreMediaData && [input appendSampleBuffer:retimed];
                    CFRelease(retimed);
                }
            }
        }
        if (ok) {
            [input markAsFinished];
        } else {
            [writer cancelWriting];
            return false;
        }
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(finished);
        }];
        if (dispatch_semaphore_wait(finished,
                                    dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) != 0) {
            return false;
        }
        return writer.status == AVAssetWriterStatusCompleted;
    }
}

} // namespace

bool EncoderAvailable() { return !SharedGop().empty(); }

int LongGopKeyframes() { return SharedLongGop().keyframes; }

bool WriteSyntheticVideo(const std::filesystem::path& path, int repeats, const std::string& salt,
                         std::optional<std::array<int32_t, 9>> display_matrix) {
    return WriteMuxedVideo(SharedGop(), path, repeats, salt, display_matrix);
}

bool WriteReorderedVideo(const std::filesystem::path& path, const std::string& salt) {
    const EncodedGop& gop = SharedReorderedGop();
    if (gop.empty() || !gop.has_reordering) return false;
    return WriteMuxedVideo(gop, path, 1, salt, std::nullopt);
}

bool WriteLongGopVideo(const std::filesystem::path& path, const std::string& salt) {
    const EncodedGop& gop = SharedLongGop();
    if (gop.keyframes != 1) return false;
    return WriteMuxedVideo(gop, path, 1, salt, std::nullopt);
}

} // namespace testing_media
} // namespace wallpaper::video
