#include "WPParticleRawGener.h"

#include <algorithm>
#include <cmath>
#include <array>
#include <cstring>
#include <vector>
#include <limits>

#include "Utils/Linalg.hpp"

#include "Core/Literals.hpp"
#include "SpecTexs.hpp"
#include "ParticleModify.h"
#include "ParticleSystem.h"

#include "Utils/Logging.h"

using namespace wallpaper;
using namespace wallpaper::linalg;

void WPParticleRawGener::GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                                   SceneMesh& mesh, ParticleRawGenSpecOp& specOp,
                                   ParticleRenderScale render_scale,
                                   ParticleOverflowFlags& overflow_flags) {
    // CLEANROOM PS19
}
