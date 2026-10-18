// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "WPParticleObject.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"
#include "Core/StringHelper.hpp"
#include "Interface/IParticleRawGener.h"

#include <sstream>
#include <algorithm>
#include <cmath>
#include <limits>
#include <string>

using namespace wallpaper::wpscene;

namespace
{

/// How deep a chain of child particle files may nest; a file that names itself
/// (or a cycle of files) stops here instead of recursing for ever.
constexpr int kMaxChildDepth = 8;

/// Counts the child entries being loaded on this thread. The guard unwinds on
/// every way out of `ParticleChild::FromJson`.
thread_local int t_child_depth = 0;

struct ChildDepthGuard {
    ChildDepthGuard() { ++t_child_depth; }
    ~ChildDepthGuard() { --t_child_depth; }
    ChildDepthGuard(const ChildDepthGuard&)            = delete;
    ChildDepthGuard& operator=(const ChildDepthGuard&) = delete;
};

/// The value a setting holds: the member `value` of a wrapper object, else the
/// setting itself.
const nlohmann::json& Unwrapped(const nlohmann::json& setting) {
    if (setting.is_object()) {
        const auto found = setting.find("value");
        if (found != setting.end()) return *found;
    }
    return setting;
}

bool HasDynamicSource(const nlohmann::json& setting) {
    return setting.is_object() && (setting.contains("script") || setting.contains("user"));
}

/// A vector setting as the scene object keys carry it: an array of at least three
/// numbers, one number for every component, or a string of space-separated
/// numbers where a component the string lacks keeps the value it had.
void ReadVec3Setting(const nlohmann::json& json, const char* key, std::array<float, 3>& out,
                     nlohmann::json& setting, bool* dynamic) {
    if (! json.is_object()) return;
    const auto found = json.find(key);
    if (found == json.end()) return;
    setting = *found;
    if (dynamic != nullptr) *dynamic = HasDynamicSource(setting);
    const nlohmann::json& source = Unwrapped(setting);
    try {
        if (source.is_array()) {
            if (source.size() < 3) return;
            std::array<float, 3> value {};
            for (std::size_t i = 0; i < 3; ++i) {
                if (! source[i].is_number()) return;
                value[i] = source[i].get<float>();
            }
            out = value;
        } else if (source.is_number()) {
            const float scalar = source.get<float>();
            out                = { scalar, scalar, scalar };
        } else if (source.is_string()) {
            std::istringstream stream(source.get<std::string>());
            for (std::size_t i = 0; i < 3; ++i) {
                float component {};
                if (! (stream >> component)) break;
                out[i] = component;
            }
        }
    } catch (const nlohmann::json::exception& e) {
        LOG_INFO("particle object: unreadable \"%s\": %s", key, e.what());
    }
}

/// A boolean the file may write as a boolean or as a number.
void ReadFlag(const nlohmann::json& json, const char* key, bool& out) {
    if (! json.is_object()) return;
    const auto found = json.find(key);
    if (found == json.end()) return;
    const nlohmann::json& value = Unwrapped(*found);
    if (value.is_boolean()) {
        out = value.get<bool>();
    } else if (value.is_number()) {
        out = value.get<double>() != 0.0;
    }
}

/// A non-negative whole number the file may write with a fraction.
uint32_t ClampedWhole(double value) {
    if (! std::isfinite(value) || value <= 0.0) return 0u;
    if (value >= static_cast<double>(std::numeric_limits<uint32_t>::max()))
        return std::numeric_limits<uint32_t>::max();
    return static_cast<uint32_t>(value);
}

/// A particle file or material named by the scene, read from the package.
bool LoadAssetJson(wallpaper::fs::VFS& vfs, const std::string& name, nlohmann::json& out) {
    if (name.empty()) return false;
    return PARSE_JSON(wallpaper::fs::GetFileContent(vfs, "/assets/" + name), out);
}

/// Control point numbers: 0..6 name themselves, anything else names the last.
wallpaper::i32 ClampControlpoint(wallpaper::i32 index) { return (index >= 0 && index <= 6) ? index : 7; }

} // namespace

bool ParticleChild::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (t_child_depth >= kMaxChildDepth) {
        LOG_ERROR("particle child nests deeper than %d files; entry dropped", kMaxChildDepth);
        return false;
    }
    ChildDepthGuard guard;

    std::string file;
    GET_JSON_NAME_VALUE_NOWARN(json, "name", file);
    if (file.empty()) return false;
    nlohmann::json child_json;
    if (! LoadAssetJson(vfs, file, child_json)) {
        LOG_ERROR("can't load child particle json: %s", file.c_str());
        return false;
    }
    name = file;
    if (! obj.FromJson(child_json, vfs)) {
        LOG_ERROR("child particle '%s' is not a usable particle file", file.c_str());
        return false;
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "type", type);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxcount", maxcount);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpointstartindex", controlpointstartindex);
    GET_JSON_NAME_VALUE_NOWARN(json, "probability", probability);
    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "scale", scale);
    GET_JSON_NAME_VALUE_NOWARN(json, "angles", angles);
    return true;
}

bool ParticleControlpoint::FromJson(const nlohmann::json& json) {
    uint32_t raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", raw_flags);
    GET_JSON_NAME_VALUE_NOWARN(json, "offset", offset);
    flags = EFlags(raw_flags);
    return true;
}

bool ParticleRender::FromJson(const nlohmann::json& json) {
    // Every call starts from the member defaults, so one object can be read again.
    *this = ParticleRender {};
    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);

    const bool is_rope  = sstart_with(name, "rope");
    const bool is_trail = send_with(name, "trail");
    if (is_rope && is_trail) {
        length      = 1.0f;
        segments    = 4.0f;
        subdivision = 1.0f;
    } else if (is_rope) {
        subdivision = 4.0f;
        uvsmoothing = true;
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "length", length);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxlength", maxlength);
    GET_JSON_NAME_VALUE_NOWARN(json, "minlength", minlength);
    if (is_rope) {
        GET_JSON_NAME_VALUE_NOWARN(json, "subdivision", subdivision);
        subdivision = std::isfinite(subdivision) ? std::clamp(std::trunc(subdivision), 0.0f, 32.0f)
                                                 : 0.0f;
        if (is_trail) {
            GET_JSON_NAME_VALUE_NOWARN(json, "segments", segments);
            segments = std::isfinite(segments) ? std::clamp(std::trunc(segments), 2.0f, 32.0f)
                                               : 2.0f;
            length   = std::isfinite(length) ? std::max(length, 0.001f) : 0.001f;
        }
    }

    // The three uv settings may be bound to a property or a script; the raw
    // value goes to the scene loader, which follows it at run time.
    if (const auto found = json.is_object() ? json.find("uvscale") : json.end();
        json.is_object() && found != json.end()) {
        uvscale_setting = *found;
        float value { uvscale };
        if (GET_JSON_NAME_VALUE_NOWARN(json, "uvscale", value)) uvscale = RopeUvScaleOrOne(value);
    }
    if (json.is_object() && json.contains("uvscrolling")) uvscrolling_setting = json.at("uvscrolling");
    if (json.is_object() && json.contains("uvsmoothing")) uvsmoothing_setting = json.at("uvsmoothing");
    ReadFlag(json, "uvscrolling", uvscrolling);
    ReadFlag(json, "uvsmoothing", uvsmoothing);
    // Smoothing eases the strip position, which scrolling already owns; a trail
    // never smooths.
    if (uvscrolling || is_trail) uvsmoothing = false;
    return true;
}

bool Emitter::FromJson(const nlohmann::json& json) {
    id = 0;
    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "rate", rate);
    GET_JSON_NAME_VALUE_NOWARN(json, "instantaneous", instantaneous);
    GET_JSON_NAME_VALUE_NOWARN(json, "speedmin", speedmin);
    GET_JSON_NAME_VALUE_NOWARN(json, "speedmax", speedmax);
    GET_JSON_NAME_VALUE_NOWARN(json, "directions", directions);
    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "distancemin", distancemin);
    GET_JSON_NAME_VALUE_NOWARN(json, "distancemax", distancemax);
    GET_JSON_NAME_VALUE_NOWARN(json, "cone", cone);

    GET_JSON_NAME_VALUE_NOWARN(json, "sign", sign);
    for (auto& axis : sign) axis = (axis > 0) - (axis < 0);

    GET_JSON_NAME_VALUE_NOWARN(json, "controlpoint", controlpoint);
    if (controlpoint >= 8) LOG_ERROR("emitter names control point %d; using 7", controlpoint);
    controlpoint = ClampControlpoint(controlpoint);

    uint32_t raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", raw_flags);
    flags = EFlags(raw_flags);

    GET_JSON_NAME_VALUE_NOWARN(json, "delay", delay);
    GET_JSON_NAME_VALUE_NOWARN(json, "duration", duration);
    GET_JSON_NAME_VALUE_NOWARN(json, "minperiodicduration", minperiodicduration);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxperiodicduration", maxperiodicduration);
    GET_JSON_NAME_VALUE_NOWARN(json, "minperiodicdelay", minperiodicdelay);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxperiodicdelay", maxperiodicdelay);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxtoemitperperiod", maxtoemitperperiod);

    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingmode", audioprocessingmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingbounds", audioprocessingbounds);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingexponent", audioprocessingexponent);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingfrequencystart", audioprocessingfrequencystart);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingfrequencyend", audioprocessingfrequencyend);
    return true;
}

bool ParticleInstanceoverride::FromJosn(const nlohmann::json& json) {
    enabled = true;
    if (! json.is_object()) return true;

    // A field bound to a project property keeps the property's name.
    static const char* const kBindable[] = { "alpha", "size", "lifetime", "rate", "speed",
                                             "count", "color", "colorn", "brightness" };
    const auto note_binding = [&](const std::string& key) {
        const auto found = json.find(key);
        if (found == json.end() || ! found->is_object()) return;
        const auto user = found->find("user");
        if (user != found->end() && user->is_string()) bindings[key] = user->get<std::string>();
    };
    for (const char* key : kBindable) note_binding(key);
    for (std::size_t i = 0; i < 8; ++i) {
        note_binding("controlpoint" + std::to_string(i));
        note_binding("controlpointangle" + std::to_string(i));
    }

    for (std::size_t i = 0; i < 8; ++i) {
        std::array<float, 3> value {};
        if (GET_JSON_NAME_VALUE_NOWARN(json, "controlpoint" + std::to_string(i), value)) {
            controlpoint[i]    = value;
            controlpointSet[i] = true;
        }
        std::array<float, 3> angle {};
        if (GET_JSON_NAME_VALUE_NOWARN(json, "controlpointangle" + std::to_string(i), angle)) {
            controlpointangle[i]    = angle;
            controlpointangleSet[i] = true;
        }
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "brightness", brightness);
    GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
    GET_JSON_NAME_VALUE_NOWARN(json, "size", size);
    GET_JSON_NAME_VALUE_NOWARN(json, "lifetime", lifetime);
    GET_JSON_NAME_VALUE_NOWARN(json, "rate", rate);
    GET_JSON_NAME_VALUE_NOWARN(json, "speed", speed);
    GET_JSON_NAME_VALUE_NOWARN(json, "count", count);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);

    // `colorn` is the same override on a 0..1 scale and only counts without `color`.
    const auto color_key = json.find("color");
    if (color_key != json.end() && ! color_key->is_null()) {
        if (GET_JSON_NAME_VALUE_NOWARN(json, "color", color)) overColor = true;
    } else if (GET_JSON_NAME_VALUE_NOWARN(json, "colorn", colorn)) {
        overColorn = true;
    }
    return true;
}

bool Particle::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (! json.is_object() || ! json.contains("emitter")) {
        LOG_ERROR("particle file has no emitter key");
        return false;
    }

    std::string material_path;
    GET_JSON_NAME_VALUE_NOWARN(json, "material", material_path);
    nlohmann::json material_json;
    if (! LoadAssetJson(vfs, material_path, material_json)) {
        LOG_ERROR("can't load particle material json: %s", material_path.c_str());
        return false;
    }
    material.FromJson(material_json);

    // The list-valued keys: absent or null is an empty list.
    const auto list_of = [&json](const char* key) -> const nlohmann::json* {
        const auto found = json.find(key);
        return (found != json.end() && found->is_array()) ? &*found : nullptr;
    };

    emitters.clear();
    if (const auto* list = list_of("emitter")) {
        for (const auto& entry : *list) {
            Emitter emitter;
            emitter.FromJson(entry);
            emitters.push_back(std::move(emitter));
        }
    }

    initializers.clear();
    if (const auto* list = list_of("initializer")) {
        initializers.assign(list->begin(), list->end());
    }
    operators.clear();
    if (const auto* list = list_of("operator")) {
        operators.assign(list->begin(), list->end());
    }

    renderers.clear();
    if (const auto* list = list_of("renderer")) {
        for (const auto& entry : *list) {
            ParticleRender renderer;
            renderer.FromJson(entry);
            renderers.push_back(std::move(renderer));
        }
    } else {
        ParticleRender sprite;
        sprite.FromJson(nlohmann::json { { "name", "sprite" } });
        renderers.push_back(std::move(sprite));
    }

    controlpoints.clear();
    if (const auto* list = list_of("controlpoint")) {
        for (const auto& entry : *list) {
            ParticleControlpoint point;
            point.FromJson(entry);
            controlpoints.push_back(std::move(point));
        }
    }

    children.clear();
    if (const auto* list = list_of("children")) {
        for (const auto& entry : *list) {
            ParticleChild child;
            if (child.FromJson(entry, vfs)) children.push_back(std::move(child));
        }
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "animationmode", animationmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "sequencemultiplier", sequencemultiplier);
    if (json.contains("maxcount")) {
        double count { static_cast<double>(maxcount) };
        if (GET_JSON_NAME_VALUE_NOWARN(json, "maxcount", count)) maxcount = ClampedWhole(count);
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "starttime", starttime);
    uint32_t raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", raw_flags);
    flags = EFlags(raw_flags);
    return true;
}

bool WPParticleObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    id = 0;
    GET_JSON_NAME_VALUE_NOWARN(json, "particle", particle);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if (json.is_object() && json.contains("visible")) {
        visible_setting = json.at("visible");
        dynamic_visible = HasDynamicSource(visible_setting);
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
    ReadVec3Setting(json, "origin", origin, origin_setting, &dynamic_origin);
    ReadVec3Setting(json, "angles", angles, angles_setting, nullptr);
    ReadVec3Setting(json, "scale", scale, scale_setting, nullptr);
    GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);
    ParseDependencies(json, dependencies);

    if (json.is_object()) {
        const auto found = json.find("instanceoverride");
        if (found != json.end() && found->is_object()) instanceoverride.FromJosn(*found);
    }

    nlohmann::json particle_json;
    if (! LoadAssetJson(vfs, particle, particle_json)) {
        LOG_ERROR("can't load particle json: %s", particle.c_str());
        return false;
    }
    if (! particleObj.FromJson(particle_json, vfs)) {
        LOG_ERROR("particle '%s' is not a usable particle file", particle.c_str());
        return false;
    }
    if (json.is_object()) AbsorbFieldBindings(json, field_bindings);
    return true;
}
