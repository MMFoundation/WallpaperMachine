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
    // CLEANROOM PS30
    return [](std::vector<Particle>&, std::vector<ParticleInitOp>&, uint32_t, double,
              std::span<const ParticleControlpoint>) {};
}
