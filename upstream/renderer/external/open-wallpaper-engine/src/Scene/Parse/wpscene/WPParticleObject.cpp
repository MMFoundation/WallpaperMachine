#include "WPParticleObject.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"
#include "Core/StringHelper.hpp"

#include <sstream>
#include <algorithm>
#include <cmath>

using namespace wallpaper::wpscene;

bool ParticleChild::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    // CLEANROOM PS20
    return false;
}

bool ParticleControlpoint::FromJson(const nlohmann::json& json) {
    // CLEANROOM PS21
    return false;
}

bool ParticleRender::FromJson(const nlohmann::json& json) {
    // CLEANROOM PS22
    return false;
}

bool Emitter::FromJson(const nlohmann::json& json) {
    // CLEANROOM PS23
    return false;
}

bool ParticleInstanceoverride::FromJosn(const nlohmann::json& json) {
    // CLEANROOM PS24
    return false;
}

bool Particle::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    // CLEANROOM PS25
    return false;
}

bool WPParticleObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    // CLEANROOM PS26
    return false;
}
