#pragma once

#include "Video/VideoMetadata.hpp"

#include <cstdint>
#include <optional>
#include <span>
#include <string>

namespace wallpaper::media
{
struct VideoStreamInfo;
}

namespace wallpaper::video
{

/// The picture size a viewer sees for a stream: the coded size run through the
/// track's display matrix, so a quarter turn swaps the axes. This is the size
/// the FFmpeg probe reports. False when the matrix is not a valid affine
/// transform or the coded size is empty.
bool DisplaySizeOf(const media::VideoStreamInfo& info, uint32_t* width, uint32_t* height);

/// Reads the picture size and length of a video held in memory, without
/// decoding it and without writing a file. Understands what the project's own
/// container readers understand (MP4 and QuickTime); returns nullopt for any
/// other payload, and for one the reader refuses (fragmented MP4, an
/// unsupported edit list), so the caller can ask another probe. It never throws
/// and never crashes on junk. The duration is the track's own: the edit list's
/// length when it has one, else the media header's.
std::optional<VideoMetadata> ProbeVideoMetadataFromMemory(std::span<const char> payload,
                                                          std::string*          why_not = nullptr);

} // namespace wallpaper::video
