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
#include <cmath>
#include <limits>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <utility>

using namespace wallpaper;

PlaybackMode wallpaper::ParseSoundPlaybackMode(std::string_view value) {
    (void)value;
    return PlaybackMode::Loop; // CLEANROOM MV47
}

WPSoundStream::WPSoundStream(const std::vector<std::string>& paths, fs::VFS& vfs, Config config)
    : WPSoundStream(std::vector<StreamFactory> {}, config) {
    (void)paths;
    (void)vfs; // CLEANROOM MV48
}

WPSoundStream::WPSoundStream(std::vector<StreamFactory> factories, Config config) {
    (void)factories;
    (void)config; // CLEANROOM MV49
    if (m_config.random_seed) m_random.seed(*m_config.random_seed);
}

WPSoundStream::~WPSoundStream() = default;

uint64_t WPSoundStream::NextPcmData(void* data, uint32_t frame_count) {
    (void)data;
    (void)frame_count;
    return 0; // CLEANROOM MV50
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
    // CLEANROOM MV51
}

void WPSoundStream::Play() {
    // CLEANROOM MV52
}

void WPSoundStream::Pause() {
    // CLEANROOM MV53
}

void WPSoundStream::Stop() {
    // CLEANROOM MV54
}

bool WPSoundStream::IsPlaying() const {
    return false; // CLEANROOM MV55
}

void WPSoundStream::SetVolume(float volume) {
    (void)volume; // CLEANROOM MV56
}

float WPSoundStream::Volume() const {
    return 1.0f; // CLEANROOM MV57
}

void WPSoundStream::SetMuted(bool muted) {
    (void)muted; // CLEANROOM MV58
}

bool WPSoundStream::Muted() const {
    return false; // CLEANROOM MV59
}

void WPSoundStream::Switch() {
    // CLEANROOM MV60
}

std::size_t WPSoundStream::LoopIndex() {
    return 0; // CLEANROOM MV61
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

    (void)vfs;
    (void)sm;
    (void)volume; // CLEANROOM MV62
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
