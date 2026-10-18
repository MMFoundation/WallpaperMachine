#include "ParticleSystem.h"
#include "Interface/IParticleRawGener.h"
#include "Core/Literals.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "ParticleModify.h"
#include "Scene/SceneMesh.h"
#include "Utils/Random.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cassert>
#include <cmath>

using namespace wallpaper;

void ParticleInstance::Refresh() {
    // CLEANROOM PS7
}

bool ParticleInstance::IsDeath() const { return m_is_death; }
void ParticleInstance::SetDeath(bool v) { m_is_death = v; };

bool ParticleInstance::IsNoLiveParticle() const { return m_no_live_particle; };
void ParticleInstance::SetNoLiveParticle(bool v) { m_no_live_particle = v; };

std::span<const Particle> ParticleInstance::Particles() const { return m_particles; };
std::vector<Particle>&    ParticleInstance::ParticlesVec() { return m_particles; };

std::span<const ParticleTrailHistory> ParticleInstance::Trails() const { return m_trails; };
std::vector<ParticleTrailHistory>&    ParticleInstance::TrailsVec() { return m_trails; };

ParticleInstance::BoundedData& ParticleInstance::GetBoundedData() { return m_bounded_data; }

ParticleSubSystem::ParticleSubSystem(ParticleSystem& p, std::shared_ptr<SceneMesh> sm,
                                     uint32_t maxcount, double rate, u32 maxcount_instance,
                                     double probability, SpawnType type,
                                     ParticleRawGenSpecOp specOp)
    : m_sys(p),
      m_mesh(sm),
      m_maxcount(maxcount),
      m_rate(rate),
      m_genSpecOp(specOp),
      m_time(0),
      m_maxcount_instance(maxcount_instance),
      m_probability(probability),
      m_spawn_type(type) {};

ParticleSubSystem::~ParticleSubSystem() = default;

void ParticleSubSystem::AddEmitter(ParticleEmittOp&& em) {
    m_emiters.emplace_back(std::move(em));
    ++m_ops_version;
}

void ParticleSubSystem::AddInitializer(ParticleInitOp&& ini) {
    m_initializers.emplace_back(std::move(ini));
    ++m_ops_version;
}

void ParticleSubSystem::AddOperator(ParticleOperatorOp&& op) { m_operators.emplace_back(op); }

std::span<const ParticleControlpoint> ParticleSubSystem::Controlpoints() const {
    return m_controlpoints;
}
std::span<ParticleControlpoint> ParticleSubSystem::Controlpoints() { return m_controlpoints; };

void ParticleSubSystem::SetOwnerNode(std::weak_ptr<SceneNode> node) {
    m_owner_node = std::move(node);
}

void ParticleSubSystem::SetRateMultiplier(std::function<double()> rate_multiplier) {
    m_rate_multiplier = std::move(rate_multiplier);
}

void ParticleSubSystem::SetRopeSubdivision(u32 subdivision) {
    m_rope_subdivision = std::max<u32>(1, subdivision);
}

void ParticleSubSystem::SetRopeUv(float scale, bool scrolling, bool smoothing) {
    m_uv_scale     = RopeUvScaleOrOne(scale);
    m_uv_scrolling = scrolling;
    m_uv_smoothing = smoothing;
    if (m_trail.enabled() && m_mesh != nullptr && m_mesh->Material() != nullptr) {
        auto& constValues = m_mesh->Material()->customShader.constValues;
        auto  it          = constValues.find("g_RenderVar0");
        if (it != constValues.end() && it->second.size() >= 4) {
            it->second[3] = EncodeRopeTrailLength(
                static_cast<float>(m_trail.samples) * static_cast<float>(m_rope_subdivision),
                m_uv_scale);
        }
    }
    if (m_mesh != nullptr) m_mesh->SetDirty();
}

void ParticleSubSystem::SetTrail(ParticleTrailConfig config) {
    m_trail       = config;
    m_trail_timer = 0.0;
}

float ParticleSubSystem::TrailPeriodFraction() const {
    if (! m_trail.enabled()) return 0;
    return static_cast<float>(std::clamp(m_trail_timer / m_trail.period, 0.0, 1.0));
}

ParticleSubSystem::SpawnType ParticleSubSystem::Type() const { return m_spawn_type; }

u32 ParticleSubSystem::MaxInstanceCount() const { return m_maxcount_instance; };

ParticleRenderScale ParticleSubSystem::RenderScale() const {
    // CLEANROOM PS8
    return {};
}

void ParticleSubSystem::UpdateMouseControlpoints() {
    // CLEANROOM PS9
}

void ParticleSubSystem::AddChild(std::unique_ptr<ParticleSubSystem>&& child) {
    child->m_parent_system = this;
    m_children.emplace_back(std::move(child));
}

void ParticleSubSystem::AddMirror(std::unique_ptr<ParticleSubSystem>&& mirror) {
    m_mirrors.emplace_back(std::move(mirror));
}

void ParticleSubSystem::GenerateFrom(const ParticleSubSystem& source) {
    if (! m_drawn) return;
    m_mesh->SetDirty();
    const auto owner = m_owner_node.lock();
    if (! owner || owner->EffectiveVisible() || owner->MustProduce()) {
        m_sys.gener->GenGLData(
            source.m_instances, *m_mesh, m_genSpecOp, RenderScale(), m_overflow_flags);
        m_mesh_rebuilt = true;
    } else {
        m_mesh_rebuilt = false;
    }
}

ParticleInstance* ParticleSubSystem::QueryNewInstance() {
    // CLEANROOM PS10
    return nullptr;
}

void ParticleSubSystem::BindInstance(ParticleInstance& inst) {
    if (inst.BoundVersion() == m_ops_version) return;
    inst.Emitters()    = m_emiters;
    inst.Initializers() = m_initializers;
    inst.SetBoundVersion(m_ops_version);
}

std::optional<ParticleSubSystem::WorldFrame> ParticleSubSystem::OwnerWorldFrame() const {
    const auto owner = m_owner_node.lock();
    if (! owner) return std::nullopt;
    owner->UpdateTrans();
    const linalg::Matrix4d model = owner->ModelTrans();
    WorldFrame            frame;
    frame.linear = model.topLeftCorner<3, 3>();
    frame.origin = model.topRightCorner<3, 1>();
    return frame;
}

void ParticleSubSystem::UpdateControlpoints() {
    // CLEANROOM PS11
}

void ParticleSubSystem::KeepWorldPositions() {
    // CLEANROOM PS12
}

void ParticleSubSystem::Advance(double dt) {
    // CLEANROOM PS13
}

void ParticleSubSystem::AdvanceInstance(ParticleInstance& inst, double dt, double time,
                                        bool record_trail) {
    // CLEANROOM PS14
}

namespace
{
/// Wallpaper Engine's prewarm step: 0.05 s, or 0.2 s once a particle file
/// holds 500 or more particles.
constexpr double PrewarmStepSeconds(u32 maxcount) { return maxcount < 500 ? 0.05 : 0.2; }
/// Upper bound on the steps one prewarm simulates. A start time of hours would
/// otherwise cost minutes at load; a system that emits without end is in the
/// same state after the bound as after the full run, so the remaining time is
/// only added to the system clock.
constexpr int kMaxPrewarmSteps = 6000;
} // namespace

void ParticleSubSystem::PrewarmInstance(ParticleInstance& inst) {
    if (m_starttime <= 0.0) return;
    const double dt    = PrewarmStepSeconds(m_maxcount);
    double       timer = 0.0;
    double       trail_timer = 0.0;
    double       elapsed     = 0.0;
    int          steps       = 0;
    do {
        bool record_trail = false;
        if (m_trail.enabled()) {
            trail_timer += dt;
            if (trail_timer >= m_trail.period) {
                record_trail = true;
                trail_timer  = std::fmod(trail_timer, m_trail.period);
            }
        }
        AdvanceInstance(inst, dt, m_time + elapsed + dt, record_trail);
        elapsed += dt;
        timer += dt;
        ++steps;
    } while (timer < m_starttime && steps < kMaxPrewarmSteps);
}

void ParticleSubSystem::Prewarm() {
    if (m_spawn_type != SpawnType::STATIC || m_starttime <= 0.0) return;
    const double dt = PrewarmStepSeconds(m_maxcount);
    // WE runs `t = 0; do { step; t += dt } while (t < starttime)`.
    const double wanted_steps = std::max(1.0, std::ceil(m_starttime / dt));
    const int    steps = static_cast<int>(std::min<double>(wanted_steps, kMaxPrewarmSteps));
    const double skipped = (wanted_steps - steps) * dt;

    std::function<void(ParticleSubSystem&)> add_time = [&](ParticleSubSystem& sys) {
        sys.m_time += skipped;
        for (auto& child : sys.m_children) {
            if (child->m_spawn_type != SpawnType::STATIC) add_time(*child);
        }
    };
    std::function<void(ParticleSubSystem&)> step = [&](ParticleSubSystem& sys) {
        sys.Advance(dt);
        for (auto& child : sys.m_children) {
            if (child->m_spawn_type != SpawnType::STATIC) step(*child);
        }
    };
    for (int i = 0; i < steps; ++i) step(*this);
    if (skipped > 0.0) add_time(*this);
    // A script or a timeline can still place the layer after the parse: the
    // first frame sets the matrix the particles are kept against, so the
    // prewarmed ones are not carried away from it.
    m_have_prev_model = false;
    // The mesh is built by the first frame that draws it.
    m_mesh_rebuilt = false;
}

void ParticleSubSystem::Emitt() {
    // CLEANROOM PS15
}

void ParticleSubSystem::RebuildMesh() {
    if (m_drawn && ! m_mesh_rebuilt && m_sys.gener != nullptr && m_mesh != nullptr) {
        const auto owner = m_owner_node.lock();
        // Still hidden, and nothing samples it: the mesh is not read this
        // frame. A missing owner is rebuilt, matching Emitt.
        if (! owner || owner->EffectiveVisible() || owner->MustProduce()) {
            m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale(), m_overflow_flags);
            m_mesh_rebuilt = true;
        }
    }
    // A mirror reads this subsystem's instances; the mesh it skipped while
    // hidden is rebuilt from what the simulation holds now.
    for (auto& mirror : m_mirrors) {
        if (! mirror->m_mesh_rebuilt) mirror->GenerateFrom(*this);
    }
    for (auto& child : m_children) child->RebuildMesh();
}

void ParticleSystem::Emitt() {
    // CLEANROOM PS16
}

void ParticleSystem::RebuildVisibleMeshes() {
    for (auto& el : subsystems) {
        el->RebuildMesh();
    }
}
