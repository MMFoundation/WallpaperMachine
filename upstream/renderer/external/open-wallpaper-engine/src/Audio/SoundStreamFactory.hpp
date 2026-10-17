// The two ways the engine turns an encoded file into a SoundStream. Callers
// name no decoder: which one serves a file is decided here, and a decoder can be
// replaced without touching them.
#pragma once

#include "Audio/SoundManager.h"

#include <filesystem>
#include <memory>
#include <string>

namespace wallpaper::fs
{
class IBinaryStream;
}

namespace wallpaper::audio
{

/// A scene's sound: the whole file, read from the scene's package. Returns null
/// and fills `error` when the file is not audio the engine can decode, so the
/// layer stays silent. The stream still needs `PassDesc` before it is read.
std::unique_ptr<SoundStream> CreateSceneSoundStream(std::shared_ptr<fs::IBinaryStream> stream,
                                                    std::string*                       error,
                                                    SoundStream::Options               options = {});

/// The audio track of a video file on disk. With `audio_optional`, a file that
/// has no audio track returns null with `error` left empty (a silent video is
/// not an error); any other failure fills `error`.
std::unique_ptr<SoundStream> CreateMediaSoundStream(const std::filesystem::path& media_path,
                                                    std::string*                 error,
                                                    SoundStream::Options         options        = {},
                                                    bool                         audio_optional = false);

} // namespace wallpaper::audio
