#include "Audio/SoundStreamFactory.hpp"

#include "Audio/FfmpegSoundStream.hpp"

namespace wallpaper::audio
{

std::unique_ptr<SoundStream> CreateSceneSoundStream(std::shared_ptr<fs::IBinaryStream> stream,
                                                    std::string*                       error,
                                                    SoundStream::Options               options)
{
    return CreateFfmpegSoundStream(std::move(stream), error, options);
}

std::unique_ptr<SoundStream> CreateMediaSoundStream(const std::filesystem::path& media_path,
                                                    std::string*                 error,
                                                    SoundStream::Options         options,
                                                    bool                         audio_optional)
{
    return CreateFfmpegSoundStream(media_path, error, options, audio_optional);
}

} // namespace wallpaper::audio
