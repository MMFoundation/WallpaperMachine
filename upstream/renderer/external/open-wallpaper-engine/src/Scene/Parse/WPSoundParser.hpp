#pragma once

#include "Audio/SoundManager.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

namespace fs
{
class VFS;
}
namespace wpscene
{
class WPSoundObject;
}

class SceneRuntimeContext;

enum class PlaybackMode
{
    OneShot,
    Random,
    Loop
};

[[nodiscard]] PlaybackMode ParseSoundPlaybackMode(std::string_view value);

class WPSoundStream : public audio::SoundStream {
public:
    using StreamFactory =
        std::function<std::shared_ptr<audio::SoundStream>(const audio::SoundStream::Desc&)>;

    struct Config {
        float        maxtime { 10.0f };
        float        mintime { 0.0f };
        float        volume { 1.0f };
        bool         muted { false };
        bool         startsilent { false };
        PlaybackMode mode { PlaybackMode::OneShot };
        std::optional<uint32_t> random_seed;
    };

    WPSoundStream(const std::vector<std::string>& paths, fs::VFS& vfs, Config config);
    WPSoundStream(std::vector<StreamFactory> factories, Config config);
    ~WPSoundStream() override;

    uint64_t NextPcmData(void* data, uint32_t frame_count) override;
    void     PassDesc(const Desc& desc) override;

    void Play();
    void Pause();
    void Stop();
    bool IsPlaying() const;

    void  SetVolume(float volume);
    float Volume() const;
    void  SetMuted(bool muted);
    bool  Muted() const;

private:
    void        Switch();
    std::size_t LoopIndex();
    uint64_t    DelayFrames();

    // One piece of a request: how many frames it produced (silence counts) and whether the
    // layer can offer nothing more for this request.
    struct Piece {
        std::size_t frames { 0 };
        bool        starved { false };
    };
    void  DropActiveFile();
    Piece NextPiece(float* out, std::size_t room, std::size_t& dead_files);
    void  ApplyLayerGain(float* out, std::size_t samples) const;

    Config                              m_config;
    Desc                                m_desc {};
    // R1-S8: to be written from spec
};

class WPSoundParser {
public:
    /// `layer_name` is the name the runtime knows the sound's layer by (the object's own name
    /// when empty); sounds that share a name are layers of different names.
    static void Parse(const wpscene::WPSoundObject&, fs::VFS&, audio::SoundManager&,
                      SceneRuntimeContext* runtime = nullptr, const std::string& layer_name = {});

    // Makes `stream`'s volume follow the project property `property` for as long
    // as the scene runs, so a slider moved on a running scene is heard without
    // loading it again. `authored_volume` is the volume the layer carries when
    // the project does not declare the property. A property that is not a number
    // leaves the volume alone, and a change to any other property does too, so a
    // volume a script set stays until its own slider moves. It costs nothing per
    // frame: the stream reads an atomic the property writes only when it changes,
    // and a stream that is gone is not touched.
    static void BindVolumeProperty(SceneRuntimeContext& runtime, std::weak_ptr<WPSoundStream> stream,
                                   std::string_view property, float authored_volume);
};

} // namespace wallpaper
