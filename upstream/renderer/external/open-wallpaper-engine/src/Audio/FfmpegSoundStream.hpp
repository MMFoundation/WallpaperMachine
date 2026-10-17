#pragma once

#include "Audio/SoundManager.h"

#include <filesystem>
#include <memory>
#include <string>

namespace wallpaper::audio
{

// The audio track of a video file on disk, decoded with FFmpeg. Only
// CreateMediaSoundStream calls it, for a plain video wallpaper's audio, until the
// WebM and MP4 audio of the own container readers replaces it. Scene sounds never
// reach FFmpeg: see SoundStreamFactory.
std::unique_ptr<SoundStream> CreateFfmpegSoundStream(const std::filesystem::path& media_path,
                                                     std::string* error,
                                                     SoundStream::Options options = {},
                                                     bool audio_optional = false);

} // namespace wallpaper::audio
