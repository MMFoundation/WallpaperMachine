#pragma once

#include "Video/VideoColorConversion.hpp"
#include "Video/VideoTextureSource.hpp"

#include <string>

namespace wallpaper::video
{

void ReleaseAppleVideoFrame(VideoTextureFrame* frame);
/// Copies `frame` into `out`, taking an independent reference on the platform
/// objects it points at. The copy stays valid after the producer releases its
/// own, which is what lets one decoder's frame be read by several surfaces;
/// the caller releases it with `ReleaseAppleVideoFrame`.
void RetainAppleVideoFrame(const VideoTextureFrame& frame, VideoTextureFrame* out);
std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame);
/// Conversion constants for one decoded biplanar frame, read from the
/// colorimetry the decoder attached to it.
///
/// Exposed so a second GPU conversion path cannot choose a different range or
/// matrix from the one the lease's own NV12 import already uses. It decodes
/// nothing, allocates nothing and converts nothing; a frame that is not
/// biplanar YCbCr has no meaningful answer and gets the defaults.
[[nodiscard]] YuvColorParams AppleVideoFrameColorParams(const VideoTextureFrame& frame);
/// Logs, once per distinct colorimetry, that a matrix had to be inferred from
/// the picture size because the stream declared none. Silent for a declared
/// matrix. Shared by every path that turns a frame's colorimetry into
/// conversion constants so the log reads the same whichever one ran.
void ReportInferredColor(const YuvColorDescription& description);

} // namespace wallpaper::video
