#include "ParticleEmitter.h"
#include "ParticleModify.h"
#include "Utils/Algorism.h"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Utils/Random.hpp"

#include "Utils/Linalg.hpp"
#include <random>
#include <array>
#include <tuple>
#include <cmath>
#include <cstring>

using namespace wallpaper;

ParticleEmittOp ParticleBoxEmitterArgs::MakeEmittOp(ParticleBoxEmitterArgs a) {
    // CLEANROOM PS17
    return [](std::vector<Particle>&, std::vector<ParticleInitOp>&, u32, double,
              std::span<const ParticleControlpoint>) {};
}

ParticleEmittOp ParticleSphereEmitterArgs::MakeEmittOp(ParticleSphereEmitterArgs a) {
    // CLEANROOM PS18
    return [](std::vector<Particle>&, std::vector<ParticleInitOp>&, u32, double,
              std::span<const ParticleControlpoint>) {};
}
