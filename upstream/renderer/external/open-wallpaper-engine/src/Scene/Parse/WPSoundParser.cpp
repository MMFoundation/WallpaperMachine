// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "WPSoundParser.hpp"

#include "Audio/SampleMath.h"
#include "Fs/VFS.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Utils/Logging.h"
#include "wpscene/WPSoundObject.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <utility>

using namespace wallpaper;

namespace
{

// One recipe per file of a layer: nothing is opened until the file becomes the active one. The
// layer loops and chooses itself, so the decoder is asked not to loop. A file that failed is
// not tried again for a few seconds, so a broken list costs neither CPU nor log volume.
std::vector<WPSoundStream::StreamFactory> MakePathFactories(const std::vector<std::string>& paths,
                                                            fs::VFS&                         vfs) {
    constexpr auto kRetryAfter = std::chrono::seconds(5);
    std::vector<WPSoundStream::StreamFactory> factories;
    factories.reserve(paths.size());
    for (const std::string& entry : paths) {
        auto failed_at = std::make_shared<std::optional<std::chrono::steady_clock::time_point>>();
        factories.emplace_back([path = "/assets/" + entry, vfs = &vfs, failed_at,
                                kRetryAfter](const audio::SoundStream::Desc& desc)
                                   -> std::shared_ptr<audio::SoundStream> {
            const auto now = std::chrono::steady_clock::now();
            if (failed_at->has_value() && now - **failed_at < kRetryAfter) return nullptr;
            std::shared_ptr<audio::SoundStream> stream;
            if (auto file = vfs->Open(path)) {
                stream = audio::CreateSoundStream(std::move(file), desc, { .loop = false });
            }
            if (stream == nullptr) {
                LOG_ERROR("can't play sound \"%s\"", path.c_str());
                *failed_at = now;
            } else {
                failed_at->reset();
            }
            return stream;
        });
    }
    return factories;
}

} // namespace

PlaybackMode wallpaper::ParseSoundPlaybackMode(std::string_view value) {
    if (value == "single") return PlaybackMode::OneShot;
    if (value == "random") return PlaybackMode::Random;
    return PlaybackMode::Loop;
}

WPSoundStream::WPSoundStream(const std::vector<std::string>& paths, fs::VFS& vfs, Config config)
    : WPSoundStream(MakePathFactories(paths, vfs), config) {}

WPSoundStream::WPSoundStream(std::vector<StreamFactory> factories, Config config) {
    m_config           = config;
    m_stream_factories = std::move(factories);
    m_volume.store(audio::ClampVolume(config.volume), std::memory_order_relaxed);
    m_muted.store(config.muted, std::memory_order_relaxed);
    m_playing.store(! config.startsilent, std::memory_order_relaxed);
    if (m_config.random_seed) m_random.seed(*m_config.random_seed);
}

WPSoundStream::~WPSoundStream() = default;

uint64_t WPSoundStream::NextPcmData(void* data, uint32_t frame_count) {
    if (data == nullptr || frame_count == 0 || m_desc.channels == 0 || m_desc.sampleRate == 0 ||
        m_stream_factories.empty())
        return 0;

    const std::size_t channels = m_desc.channels;
    auto*             out      = static_cast<float*>(data);
    audio::ClearInterleavedF32(out, static_cast<std::size_t>(frame_count) * channels);

    // stop(), or play() on a finished one-shot, rewinds at the next request, paused or not.
    if (m_rewind_requested.exchange(false, std::memory_order_acq_rel)) {
        m_cur_active.reset();
        m_cur_index    = 0;
        m_delay_frames = 0;
        m_finished.store(false, std::memory_order_relaxed);
    }
    if (! m_playing.load(std::memory_order_acquire)) return frame_count;

    uint32_t    filled         = 0;
    std::size_t empty_in_a_row = 0;
    while (filled < frame_count) {
        const uint32_t wanted = frame_count - filled;
        if (m_delay_frames > 0) {
            const uint32_t quiet = static_cast<uint32_t>(std::min<uint64_t>(m_delay_frames, wanted));
            m_delay_frames -= quiet;
            filled += quiet;
            continue;
        }
        if (! m_cur_active) {
            Switch();
            if (! m_cur_active) break; // unreadable file: silence now, the next one next time
        }
        const uint64_t got = m_cur_active->NextPcmData(out + static_cast<std::size_t>(filled) * channels, wanted);
        if (got > 0) {
            filled += static_cast<uint32_t>(std::min<uint64_t>(got, wanted));
            empty_in_a_row = 0;
            continue;
        }
        // The file is over (or empty, or failing).
        m_cur_active.reset();
        if (m_config.mode == PlaybackMode::OneShot) {
            m_finished.store(true, std::memory_order_relaxed);
            m_playing.store(false, std::memory_order_release);
            break;
        }
        if (m_config.mode == PlaybackMode::Random) m_delay_frames = DelayFrames();
        if (++empty_in_a_row > m_stream_factories.size()) break; // never spin on a dead list
    }

    const std::size_t samples = static_cast<std::size_t>(frame_count) * channels;
    if (m_muted.load(std::memory_order_relaxed)) {
        audio::ClearInterleavedF32(out, samples);
    } else {
        const float volume = m_volume.load(std::memory_order_relaxed);
        if (volume != 1.0f) audio::ApplyVolumeF32(out, samples, volume);
    }
    return frame_count;
}

uint64_t WPSoundStream::DelayFrames() {
    const double minimum = std::isfinite(m_config.mintime) ? std::max(0.0f, m_config.mintime) : 0.0;
    const double maximum = std::isfinite(m_config.maxtime) ? std::max(minimum, double(m_config.maxtime)) : minimum;
    const double seconds = std::uniform_real_distribution<double>(minimum, maximum)(m_random);
    return static_cast<uint64_t>(std::min(std::ceil(seconds * m_desc.sampleRate),
                                         double(std::numeric_limits<int64_t>::max())));
}

void WPSoundStream::PassDesc(const Desc& desc) {
    if (m_desc.sampleRate != 0 && m_desc.sampleRate != desc.sampleRate) {
        m_delay_frames = static_cast<uint64_t>(std::min(
            std::ceil(double(m_delay_frames) * desc.sampleRate / m_desc.sampleRate),
            double(std::numeric_limits<int64_t>::max())));
    }
    m_desc = desc;
    if (m_cur_active) m_cur_active->PassDesc(desc);
}

void WPSoundStream::Play() {
    if (m_finished.load(std::memory_order_acquire)) {
        m_rewind_requested.store(true, std::memory_order_release);
    }
    m_playing.store(true, std::memory_order_release);
}

void WPSoundStream::Pause() {
    m_playing.store(false, std::memory_order_release);
}

void WPSoundStream::Stop() {
    m_playing.store(false, std::memory_order_release);
    m_rewind_requested.store(true, std::memory_order_release);
}

bool WPSoundStream::IsPlaying() const {
    return m_playing.load(std::memory_order_acquire);
}

void WPSoundStream::SetVolume(float volume) {
    m_volume.store(audio::ClampVolume(volume), std::memory_order_relaxed);
}

float WPSoundStream::Volume() const {
    return m_volume.load(std::memory_order_relaxed);
}

void WPSoundStream::SetMuted(bool muted) {
    m_muted.store(muted, std::memory_order_relaxed);
}

bool WPSoundStream::Muted() const {
    return m_muted.load(std::memory_order_relaxed);
}

void WPSoundStream::Switch() {
    m_cur_active.reset();
    const auto& factory = m_stream_factories[LoopIndex()];
    if (! factory) return;
    m_cur_active = factory(m_desc);
    if (m_cur_active) m_cur_active->PassDesc(m_desc);
}

std::size_t WPSoundStream::LoopIndex() {
    const std::size_t count = m_stream_factories.size();
    if (count == 0) return 0;
    if (m_config.mode == PlaybackMode::Random) {
        return std::uniform_int_distribution<std::size_t>(0, count - 1)(m_random);
    }
    const std::size_t index = m_cur_index % count;
    m_cur_index             = (index + 1) % count;
    return index;
}

void WPSoundParser::Parse(const wpscene::WPSoundObject& obj, fs::VFS& vfs, audio::SoundManager& sm,
                          SceneRuntimeContext* runtime) {
    // The user's own slider wins over the author's default when the author
    // bound one: that binding is the whole point of the slider.
    float volume = obj.volume;
    if (runtime != nullptr && ! obj.volume_user.empty()) {
        if (const auto* bound = runtime->FindPropertyValue(obj.volume_user);
            bound != nullptr && bound->getType() == DynamicValue::UnderlyingType::Float) {
            volume = bound->getFloat();
        }
    }

    WPSoundStream::Config config;
    config.maxtime     = obj.maxtime;
    config.mintime     = obj.mintime;
    config.volume      = audio::ClampVolume(volume);
    config.muted       = obj.muted;
    config.startsilent = obj.startsilent;
    config.mode        = ParseSoundPlaybackMode(obj.playbackmode);

    auto stream = std::make_shared<WPSoundStream>(obj.sound, vfs, config);
    if (runtime != nullptr) {
        runtime->RegisterSoundLayer(obj.name, stream);
        BindVolumeProperty(*runtime, stream, obj.volume_user, obj.volume);
    }
    sm.MountStream(std::shared_ptr<audio::SoundStream>(stream));
}

void WPSoundParser::BindVolumeProperty(SceneRuntimeContext& runtime,
                                       std::weak_ptr<WPSoundStream> stream,
                                       std::string_view property, float authored_volume) {
    if (property.empty()) return;

    // The same binding every other slider-driven setting resolves, so the layer
    // sees the property exactly as a fresh load would: the authored volume while
    // the project declares no such property, the property's value once it does.
    const nlohmann::json setting { { "user", std::string(property) },
                                   { "value", authored_volume } };
    // The last value the property gave. Every property is refreshed whenever a
    // document is applied, so an unchanged one must not undo a volume a script
    // has set since.
    auto applied = std::make_shared<std::optional<float>>();
    runtime.RegisterDynamicValueListener(
        ResolveFloatSetting(runtime, setting),
        [stream = std::move(stream), applied](const DynamicValue& value) {
            if (value.getType() != DynamicValue::UnderlyingType::Float &&
                value.getType() != DynamicValue::UnderlyingType::Int) {
                return;
            }
            const float volume = value.getFloat();
            if (applied->has_value() && **applied == volume) return;
            *applied = volume;
            if (const auto live = stream.lock()) live->SetVolume(volume);
        });
}
