// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "WPParticleParser.hpp"
#include "Particle/ParticleEmitter.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include <random>
#include <memory>
#include <algorithm>
#include <cmath>
#include <optional>
#include <limits>
#include <sstream>
#include <mutex>
#include <string>
#include <unordered_set>

#include "Utils/Linalg.hpp"

#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Utils/Random.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;
namespace PM = ParticleModify;

namespace
{

inline Vector3f HsvToRgb(float h, float s, float v) {
    h -= std::floor(h);
    const float scaled = h * 6.0f;
    const int   sector = static_cast<int>(std::floor(scaled)) % 6;
    const float f      = scaled - std::floor(scaled);
    const float p      = v * (1.0f - s);
    const float q      = v * (1.0f - s * f);
    const float t      = v * (1.0f - s * (1.0f - f));
    switch (sector) {
    case 0: return { v, t, p };
    case 1: return { q, v, p };
    case 2: return { p, v, t };
    case 3: return { p, q, v };
    case 4: return { t, p, v };
    default: return { v, p, q };
    }
}

inline Vector3f ParseColorTriple(const nlohmann::json& j, const char* key,
                                 const Vector3f& fallback) {
    std::array<float, 3> value { fallback.x(), fallback.y(), fallback.z() };
    if (j.contains(key)) GET_JSON_NAME_VALUE_NOWARN(j, key, value);
    return { value[0], value[1], value[2] };
}

/// Logs a record the engine does not decode, once for each distinct name.
void LogInertOnce(const char* kind, const std::string& name) {
    static std::mutex                     lock;
    static std::unordered_set<std::string> seen;
    const std::string                     key = std::string(kind) + ":" + name;
    {
        std::lock_guard<std::mutex> guard(lock);
        if (! seen.insert(key).second) return;
    }
    LOG_INFO("particle %s \"%s\" is not decoded and does nothing", kind, name.c_str());
}

/// The response of an audio-driven emitter, operator or initializer: the
/// loudest of the selected bands, mapped through the bounds, smoothed, and
/// raised to the exponent. Zero for anything that is silent or not a number.
float AudioLevel(const audio::AudioSpectrumSnapshot& snapshot, u32 mode, i32 band_start,
                 i32 band_end, float low, float high, float exponent) {
    const std::array<float, 16>& bands =
        mode == 1 ? snapshot.left16 : (mode == 2 ? snapshot.right16 : snapshot.average16);
    const i32 first = std::clamp(band_start, 0, 15);
    const i32 last  = std::clamp(std::max(band_end, first), first, 15);
    float     volume = 0.0f;
    for (i32 i = first; i <= last; ++i) {
        const float band = bands[static_cast<std::size_t>(i)];
        if (! std::isfinite(band)) return 0.0f;
        volume = std::max(volume, band);
    }
    if (! (volume > 0.0f) || ! std::isfinite(low) || ! std::isfinite(high) ||
        ! std::isfinite(exponent))
        return 0.0f;
    float response = 0.0f;
    if (high > low) {
        response = std::clamp((volume - low) / (high - low), 0.0f, 1.0f);
    } else {
        response = volume > low ? 1.0f : 0.0f;
    }
    if (! (response > 0.0f)) return 0.0f;
    response = response * response * (3.0f - 2.0f * response);
    return std::pow(response, std::max(0.0f, exponent));
}

/// The level callable of an emitter record, or empty when it has no audio mode.
std::function<float()>
MakeAudioResponse(const wpscene::Emitter&                              wpe,
                  const std::function<audio::AudioSpectrumSnapshot()>& spectrum) {
    if (wpe.audioprocessingmode < 1 || wpe.audioprocessingmode > 3) return {};
    return [spectrum, mode = wpe.audioprocessingmode, start = wpe.audioprocessingfrequencystart,
            end = wpe.audioprocessingfrequencyend, low = wpe.audioprocessingbounds[0],
            high = wpe.audioprocessingbounds[1], exponent = wpe.audioprocessingexponent]() {
        if (! spectrum) return 0.0f;
        return AudioLevel(spectrum(), mode, start, end, low, high, exponent);
    };
}

ParticleEmitterTiming TimingOf(const wpscene::Emitter& wpe) {
    ParticleEmitterTiming timing;
    timing.delay               = wpe.delay;
    timing.duration            = wpe.duration;
    timing.periodic            = wpe.flags[wpscene::Emitter::FlagEnum::periodic];
    timing.minPeriodicDuration = wpe.minperiodicduration;
    timing.maxPeriodicDuration = wpe.maxperiodicduration;
    timing.minPeriodicDelay    = wpe.minperiodicdelay;
    timing.maxPeriodicDelay    = wpe.maxperiodicdelay;
    timing.maxToEmitPerPeriod  = wpe.maxtoemitperperiod;
    return timing;
}

} // namespace

ParticleColorDefinition
WPParticleParser::analyzeColorSources(const std::vector<nlohmann::json>& initializers,
                                      const std::vector<nlohmann::json>& operators) {
    ParticleColorDefinition def;
    bool                    from_initializer = false;
    for (const auto& ini : initializers) {
        if (! ini.is_object() || ! ini.contains("name")) continue;
        std::string name;
        GET_JSON_NAME_VALUE_NOWARN(ini, "name", name);
        if (name == "colorrandom") {
            const Vector3f lo = ParseColorTriple(ini, "min", Vector3f::Zero()) / 255.0f;
            const Vector3f hi = ParseColorTriple(ini, "max", Vector3f::Constant(255.0f)) / 255.0f;
            def.defaultColor  = (lo + hi) * 0.5f;
            def.hasColor      = true;
            from_initializer  = true;
        } else if (name == "hsvcolorrandom") {
            float huemin { 0.0f }, huemax { 1.0f }, satmin { 0.5f }, satmax { 1.0f };
            float valmin { 0.5f }, valmax { 1.0f };
            GET_JSON_NAME_VALUE_NOWARN(ini, "huemin", huemin);
            GET_JSON_NAME_VALUE_NOWARN(ini, "huemax", huemax);
            GET_JSON_NAME_VALUE_NOWARN(ini, "saturationmin", satmin);
            GET_JSON_NAME_VALUE_NOWARN(ini, "saturationmax", satmax);
            GET_JSON_NAME_VALUE_NOWARN(ini, "valuemin", valmin);
            GET_JSON_NAME_VALUE_NOWARN(ini, "valuemax", valmax);
            def.defaultColor = HsvToRgb(
                (huemin + huemax) * 0.5f, (satmin + satmax) * 0.5f, (valmin + valmax) * 0.5f);
            def.hasColor     = true;
            from_initializer = true;
        } else if (name == "colorlist") {
            def.hasColor     = true;
            from_initializer = true;
            if (ini.contains("colors")) {
                const auto& colors = ini.at("colors");
                std::string text;
                if (colors.is_string()) {
                    text = colors.get<std::string>();
                } else if (colors.is_array() && ! colors.empty() && colors.front().is_string()) {
                    text = colors.front().get<std::string>();
                }
                std::istringstream stream(text);
                float              r = 1.0f, g = 1.0f, b = 1.0f;
                if (stream >> r >> g >> b) def.defaultColor = { r, g, b };
                else def.defaultColor = { 1.0f, 1.0f, 1.0f };
            } else {
                def.defaultColor = { 1.0f, 1.0f, 1.0f };
            }
        }
    }
    for (const auto& op : operators) {
        if (! op.is_object() || ! op.contains("name")) continue;
        std::string name;
        GET_JSON_NAME_VALUE_NOWARN(op, "name", name);
        if (name == "colorchange") {
            def.hasColor = true;
            if (! from_initializer) {
                def.defaultColor = ParseColorTriple(op, "startvalue", Vector3f::Ones());
            }
        }
    }
    return def;
}


ParticleInitOp WPParticleParser::genParticleInitOp(const nlohmann::json& wpj) {
    return genParticleInitOp(wpj, ParticleParseContext {});
}

ParticleInitOp WPParticleParser::genParticleInitOp(const nlohmann::json&        wpj,
                                                   const ParticleParseContext&  ctx) {
    // CLEANROOM PS27
    return [](Particle&, double) {};
}

ParticleInitOp WPParticleParser::genOverrideInitOp(
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over, ParticleColorDefinition def,
    bool speed_override, bool size_override) {
    // CLEANROOM PS28
    return [](Particle&, double) {};
}

ParticleOperatorOp
WPParticleParser::genParticleOperatorOp(
    const nlohmann::json&                                   wpj,
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over) {
    ParticleParseContext ctx;
    ctx.over = std::move(over);
    return genParticleOperatorOp(wpj, ctx);
}

ParticleOperatorOp WPParticleParser::genParticleOperatorOp(const nlohmann::json&       wpj,
                                                           const ParticleParseContext& ctx) {
    // CLEANROOM PS29
    return [](const ParticleInfo&) {};
}

ParticleEmittOp WPParticleParser::genParticleEmittOp(
    const wpscene::Emitter& wpe, bool sort,
    std::shared_ptr<const wpscene::ParticleInstanceoverride> override,
    std::function<audio::AudioSpectrumSnapshot()>            audio_spectrum,
    std::shared_ptr<ParticleSpawnContext>                    spawn) {
    std::shared_ptr<const float> count;
    if (override) count = std::shared_ptr<const float>(override, &override->count);

    if (wpe.name == "boxrandom") {
        ParticleBoxEmitterArgs a;
        a.directions      = wpe.directions;
        a.minDistance     = wpe.distancemin;
        a.maxDistance     = wpe.distancemax;
        a.emitSpeed       = wpe.rate;
        a.orgin           = wpe.origin;
        a.one_per_frame   = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        a.sort            = sort;
        a.instantaneous   = wpe.instantaneous;
        a.minSpeed        = wpe.speedmin;
        a.maxSpeed        = wpe.speedmax;
        a.controlpoint    = wpe.controlpoint;
        a.countMultiplier = std::move(count);
        a.audioResponse   = MakeAudioResponse(wpe, audio_spectrum);
        a.timing          = TimingOf(wpe);
        a.spawn           = std::move(spawn);
        return ParticleBoxEmitterArgs::MakeEmittOp(std::move(a));
    }
    if (wpe.name == "sphererandom") {
        ParticleSphereEmitterArgs a;
        a.directions      = wpe.directions;
        a.minDistance     = wpe.distancemin[0];
        a.maxDistance     = wpe.distancemax[0];
        a.emitSpeed       = wpe.rate;
        a.orgin           = wpe.origin;
        a.sign            = wpe.sign;
        a.one_per_frame   = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        a.sort            = sort;
        a.instantaneous   = wpe.instantaneous;
        a.minSpeed        = wpe.speedmin;
        a.maxSpeed        = wpe.speedmax;
        a.controlpoint    = wpe.controlpoint;
        a.countMultiplier = std::move(count);
        a.audioResponse   = MakeAudioResponse(wpe, audio_spectrum);
        a.timing          = TimingOf(wpe);
        a.cone            = wpe.cone;
        a.spawn           = std::move(spawn);
        return ParticleSphereEmitterArgs::MakeEmittOp(std::move(a));
    }
    // Any other emitter (one stock file has `layerimage`) never emits.
    LogInertOnce("emitter", wpe.name);
    return [](std::vector<Particle>&, std::vector<ParticleInitOp>&, uint32_t, double,
              std::span<const ParticleControlpoint>) {};
}
