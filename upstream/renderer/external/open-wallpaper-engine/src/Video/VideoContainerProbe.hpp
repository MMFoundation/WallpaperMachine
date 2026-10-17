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
/// container readers understand (MP4 and QuickTime, WebM and Matroska); returns
/// nullopt for any other payload, and for one a reader refuses (fragmented MP4, an
/// unsupported edit list, a VP8 track), so the caller can ask another probe. It
/// never throws and never crashes on junk. The duration is the track's own: for
/// MP4 the edit list's length when it has one, else the media header's; for
/// Matroska the length the file states.
std::optional<VideoMetadata> ProbeVideoMetadataFromMemory(std::span<const char> payload,
                                                          std::string*          why_not = nullptr);

} // namespace wallpaper::video
