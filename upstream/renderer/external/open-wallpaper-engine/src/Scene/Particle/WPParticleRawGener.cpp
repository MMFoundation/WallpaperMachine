// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
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

namespace
{

namespace PM = ParticleModify;

/// The corner of each of a quad's four vertices in the texture: vertices 0..3.
constexpr std::array<std::array<float, 2>, 4> kCorners { { { 0.0f, 1.0f },
                                                           { 1.0f, 1.0f },
                                                           { 1.0f, 0.0f },
                                                           { 0.0f, 0.0f } } };

constexpr std::size_t kSpriteThin  = 16;
constexpr std::size_t kSpriteThick = 20;
constexpr std::size_t kRopeThin    = 24;
constexpr std::size_t kRopeThick   = 28;
constexpr std::size_t kMaxFloatsPerVertex = kRopeThick;

/// Where a mesh is written to and how much of it may be.
struct Target {
    SceneVertexArray* vertices { nullptr };
    SceneIndexArray*  indices { nullptr };
    std::size_t       floats { 0 };      // per vertex
    uint64_t          capacity { 0 };    // quads the vertices and the indices both hold
    uint64_t          quads { 0 };       // quads written so far
    uint64_t          wanted { 0 };      // quads asked for, written or not
    bool              thick { false };
};

/// Stores one quad of four vertices, `data` holding `floats` for each.
void StoreQuad(Target& t, const float* data) {
    t.vertices->SetVertexs(static_cast<std::size_t>(t.quads) * 4,
                           std::span<const float>(data, t.floats * 4));
    ++t.quads;
}

/// Extends the index data to name `quads` quads: vertices (0,1,3) and (1,2,3) of
/// each. Written once and only ever extended.
void ExtendIndices(SceneIndexArray& indices, uint64_t quads) {
    const bool wide = indices.Width() == SceneIndexWidth::UInt32;
    const uint64_t per_quad = wide ? 6u : 3u;
    uint64_t       written  = indices.DataCount() / per_quad;
    for (; written < quads; ++written) {
        const uint64_t base = written * 4;
        if (wide) {
            const std::array<uint32_t, 6> pattern { static_cast<uint32_t>(base),
                                                    static_cast<uint32_t>(base + 1),
                                                    static_cast<uint32_t>(base + 3),
                                                    static_cast<uint32_t>(base + 1),
                                                    static_cast<uint32_t>(base + 2),
                                                    static_cast<uint32_t>(base + 3) };
            indices.Assign(static_cast<std::size_t>(written * 6), pattern);
        } else {
            const std::array<uint16_t, 6> pattern { static_cast<uint16_t>(base),
                                                    static_cast<uint16_t>(base + 1),
                                                    static_cast<uint16_t>(base + 3),
                                                    static_cast<uint16_t>(base + 1),
                                                    static_cast<uint16_t>(base + 2),
                                                    static_cast<uint16_t>(base + 3) };
            indices.AssignHalf(static_cast<std::size_t>(written * 6), pattern);
        }
    }
}

double SmoothStep(double t) { return t * t * (3.0 - 2.0 * t); }

// --- sprites -----------------------------------------------------------------------

void WriteSprite(Target& t, const Particle& p, const Vector3d& anchor, float animation) {
    std::array<float, kMaxFloatsPerVertex * 4> quad;
    const float half = p.size / kParticleSizeOverEngine;
    for (std::size_t v = 0; v < 4; ++v) {
        float* out = quad.data() + v * t.floats;
        out[0]     = static_cast<float>(p.position.x() + anchor.x());
        out[1]     = static_cast<float>(p.position.y() + anchor.y());
        out[2]     = static_cast<float>(p.position.z() + anchor.z());
        out[3]     = 0.0f;
        out[4]     = kCorners[v][0];
        out[5]     = kCorners[v][1];
        out[6]     = p.rotation.z();
        out[7]     = half;
        out[8]     = p.color.x();
        out[9]     = p.color.y();
        out[10]    = p.color.z();
        out[11]    = p.alpha;
        std::size_t next = 12;
        if (t.thick) {
            out[12] = p.velocity.x();
            out[13] = p.velocity.y();
            out[14] = p.velocity.z();
            out[15] = animation;
            next    = 16;
        }
        out[next]     = p.rotation.x();
        out[next + 1] = p.rotation.y();
        out[next + 2] = 0.0f;
        out[next + 3] = 0.0f;
    }
    StoreQuad(t, quad.data());
}

void GenerateSprites(std::span<const std::unique_ptr<ParticleInstance>> instances, Target& t,
                     ParticleRawGenSpecOp& spec) {
    for (const auto& instance : instances) {
        if (! instance || instance->IsNoLiveParticle()) continue;
        const auto& bound  = instance->GetBoundedData();
        const Vector3d anchor { bound.pos.x(), bound.pos.y(), bound.pos.z() };
        for (const auto& p : instance->Particles()) {
            if (! PM::LifetimeOk(p)) continue;
            ++t.wanted;
            if (t.quads >= t.capacity) continue;
            float animation = p.lifetime;
            if (spec) spec(p, ParticleRawGenSpec { &animation });
            WriteSprite(t, p, anchor, animation);
        }
    }
}

// --- ropes -------------------------------------------------------------------------

/// One point of a rope strip: where it is and what it looks like there.
struct RopePoint {
    Vector3d position;
    Vector3d color;
    double   alpha;
    double   half;
};

RopePoint PointOf(const Particle& p, const Vector3d& anchor) {
    return { Vector3d { p.position.x() + anchor.x(), p.position.y() + anchor.y(),
                        p.position.z() + anchor.z() },
             Vector3d { p.color.x(), p.color.y(), p.color.z() }, p.alpha,
             static_cast<double>(p.size) / kParticleSizeOverEngine };
}

RopePoint Blend(const RopePoint& a, const RopePoint& b, double s) {
    return { Vector3d(a.position + (b.position - a.position) * s),
             Vector3d(a.color + (b.color - a.color) * s), a.alpha + (b.alpha - a.alpha) * s,
             a.half + (b.half - a.half) * s };
}

struct StripParams {
    uint32_t pieces { 1 };     // pieces drawn between two connected points
    float    uv_scale { 1.0f };
    bool     smoothing { false };
    float    length { 0.0f };  // the strip's length before the uv scale is applied
};

void WritePiece(Target& t, const Vector3d& start, double start_half, const Vector3d& end,
                double end_half, const Vector3d& control_a, const Vector3d& control_b,
                const RopePoint& from, const RopePoint& to, float encoded, float along) {
    std::array<float, kMaxFloatsPerVertex * 4> quad;
    for (std::size_t v = 0; v < 4; ++v) {
        float* out = quad.data() + v * t.floats;
        out[0]     = static_cast<float>(start.x());
        out[1]     = static_cast<float>(start.y());
        out[2]     = static_cast<float>(start.z());
        out[3]     = static_cast<float>(start_half);
        out[4]     = static_cast<float>(end.x());
        out[5]     = static_cast<float>(end.y());
        out[6]     = static_cast<float>(end.z());
        out[7]     = encoded;
        out[8]     = static_cast<float>(control_a.x());
        out[9]     = static_cast<float>(control_a.y());
        out[10]    = static_cast<float>(control_a.z());
        out[11]    = along;
        out[12]    = static_cast<float>(control_b.x());
        out[13]    = static_cast<float>(control_b.y());
        out[14]    = static_cast<float>(control_b.z());
        if (t.thick) {
            out[15] = static_cast<float>(end_half);
            out[16] = static_cast<float>(to.color.x());
            out[17] = static_cast<float>(to.color.y());
            out[18] = static_cast<float>(to.color.z());
            out[19] = static_cast<float>(to.alpha);
            out[20] = kCorners[v][0];
            out[21] = kCorners[v][1];
            out[22] = 0.0f;
            out[23] = 0.0f;
            out[24] = static_cast<float>(from.color.x());
            out[25] = static_cast<float>(from.color.y());
            out[26] = static_cast<float>(from.color.z());
            out[27] = static_cast<float>(from.alpha);
        } else {
            out[15] = static_cast<float>(end_half);
            out[16] = kCorners[v][0];
            out[17] = kCorners[v][1];
            out[18] = 0.0f;
            out[19] = 0.0f;
            out[20] = static_cast<float>(from.color.x());
            out[21] = static_cast<float>(from.color.y());
            out[22] = static_cast<float>(from.color.z());
            out[23] = static_cast<float>(from.alpha);
        }
    }
    StoreQuad(t, quad.data());
}

/// The tangent of a strip at point `i`: the difference of its neighbours, or the
/// chord to the one neighbour an end point has.
Vector3d TangentAt(const RopePoint* points, std::size_t count, std::size_t i) {
    if (i == 0) return points[1].position - points[0].position;
    if (i + 1 == count) return points[i].position - points[i - 1].position;
    return points[i + 1].position - points[i - 1].position;
}

/// Writes the pieces of one strip: each pair of consecutive points becomes
/// `pieces` pieces along a smooth curve through them, spaced by smoothstep.
void WriteStrip(Target& t, const RopePoint* points, std::size_t count, const StripParams& params) {
    if (count < 2) return;
    const uint32_t pieces      = std::max<uint32_t>(params.pieces, 1);
    const double   total       = static_cast<double>(count - 1) * pieces;
    const float    encoded     = EncodeRopeTrailLength(params.length, params.uv_scale);
    const bool     smooth_uv   = params.smoothing && total > 1.0;

    for (std::size_t i = 0; i + 1 < count; ++i) {
        const RopePoint& a     = points[i];
        const RopePoint& b     = points[i + 1];
        const Vector3d   chord = b.position - a.position;
        if (chord.norm() < 1.0e-6) {
            // No piece between coincident points; the strip's counting goes on.
            continue;
        }
        Vector3d tangent_a = TangentAt(points, count, i);
        Vector3d tangent_b = TangentAt(points, count, i + 1);
        if (tangent_a.norm() < 1.0e-12) tangent_a = chord;
        if (tangent_b.norm() < 1.0e-12) tangent_b = chord;
        const Vector3d ca = a.position + tangent_a * 0.15;
        const Vector3d cb = b.position - tangent_b * 0.15;

        const auto curve = [&](double s) -> Vector3d {
            const double u = 1.0 - s;
            return a.position * (u * u * u) + ca * (3.0 * u * u * s) + cb * (3.0 * u * s * s) +
                   b.position * (s * s * s);
        };
        const auto slope = [&](double s) -> Vector3d {
            const double u = 1.0 - s;
            return (ca - a.position) * (3.0 * u * u) + (cb - ca) * (6.0 * u * s) +
                   (b.position - cb) * (3.0 * s * s);
        };

        for (uint32_t j = 0; j < pieces; ++j) {
            ++t.wanted;
            if (t.quads >= t.capacity) continue;
            const double s0 = j == 0 ? 0.0 : SmoothStep(static_cast<double>(j) / pieces);
            const double s1 = j + 1 == pieces ? 1.0 : SmoothStep(static_cast<double>(j + 1) / pieces);
            const RopePoint from = Blend(a, b, s0);
            const RopePoint to   = Blend(a, b, s1);
            const Vector3d  start = j == 0 ? a.position : curve(s0);
            const Vector3d  end   = j + 1 == pieces ? b.position : curve(s1);
            // The piece's own tangents, scaled so the shader's curve through its
            // two ends is the stretch of the pair's curve between s0 and s1.
            const double    span = (s1 - s0) / 0.45;
            const Vector3d  ta   = slope(s0) * span;
            const Vector3d  tb   = slope(s1) * span;
            const double m = static_cast<double>(i) * pieces + j;
            double along = m;
            if (smooth_uv) along = SmoothStep(m / total) * total;
            WritePiece(t, start, from.half, end, to.half, end - ta, start + tb, from, to, encoded,
                       static_cast<float>(along));
        }
    }
}

void GenerateRopes(std::span<const std::unique_ptr<ParticleInstance>> instances, Target& t,
                   const ParticleRenderScale& scale) {
    thread_local std::vector<RopePoint> strip;
    StripParams params;
    params.pieces    = std::clamp<uint32_t>(scale.rope_subdivision, 1u, 64u);
    params.uv_scale  = RopeUvScaleOrOne(scale.uv_scale);
    params.smoothing = scale.uv_smoothing && ! scale.uv_scrolling;

    for (const auto& instance : instances) {
        if (! instance || instance->IsNoLiveParticle()) continue;
        const auto&    bound = instance->GetBoundedData();
        const Vector3d anchor { bound.pos.x(), bound.pos.y(), bound.pos.z() };
        strip.clear();
        for (const auto& p : instance->Particles()) {
            if (PM::LifetimeOk(p)) strip.push_back(PointOf(p, anchor));
        }
        if (strip.size() < 2) continue;
        const double points = static_cast<double>(strip.size() - 1) * params.pieces + 1.0;
        params.length       = scale.uv_scrolling ? static_cast<float>(t.capacity) + 1.0f
                                                 : static_cast<float>(points);
        WriteStrip(t, strip.data(), strip.size(), params);
    }
}

void GenerateRopeTrails(std::span<const std::unique_ptr<ParticleInstance>> instances, Target& t,
                        const ParticleRenderScale& scale) {
    thread_local std::vector<RopePoint> strip;
    StripParams params;
    params.pieces    = std::clamp<uint32_t>(scale.rope_subdivision, 1u, 64u);
    params.uv_scale  = RopeUvScaleOrOne(scale.uv_scale);
    params.smoothing = false;
    const double fraction = std::clamp(static_cast<double>(scale.trail_fraction), 0.0, 1.0);

    for (const auto& instance : instances) {
        if (! instance || instance->IsNoLiveParticle()) continue;
        const auto&    bound  = instance->GetBoundedData();
        const Vector3d anchor { bound.pos.x(), bound.pos.y(), bound.pos.z() };
        const auto     particles = instance->Particles();
        const auto     trails    = instance->Trails();
        for (std::size_t slot = 0; slot < particles.size() && slot < trails.size(); ++slot) {
            const Particle& p = particles[slot];
            if (! PM::LifetimeOk(p)) continue;
            const ParticleTrailHistory& history = trails[slot];
            const uint32_t              held    = history.Count();
            if (held == 0) continue;

            strip.clear();
            const RopePoint head = PointOf(p, anchor);
            strip.push_back(head);
            for (uint32_t age = 0; age < held; ++age) {
                RopePoint point = head;
                const auto& at  = history.At(age).position;
                point.position  = Vector3d { at.x(), at.y(), at.z() };
                strip.push_back(point);
            }
            // A full history gives its oldest point up to the newer one as the
            // period goes by, so the tail shrinks by what the head grew.
            if (held == history.Capacity() && held >= 2) {
                RopePoint& oldest = strip[strip.size() - 1];
                const RopePoint& newer = strip[strip.size() - 2];
                oldest.position = oldest.position + (newer.position - oldest.position) * fraction;
            }

            const double pieces   = params.pieces;
            const double subdivided = static_cast<double>(held) * pieces + 1.0;
            const double capacity = static_cast<double>(history.Capacity());
            if (scale.uv_scrolling) {
                params.length = static_cast<float>(params.pieces == 1 ? capacity : capacity * pieces);
            } else {
                params.length = static_cast<float>(params.pieces == 1 ? static_cast<double>(held)
                                                                      : subdivided);
            }
            WriteStrip(t, strip.data(), strip.size(), params);
        }
    }
}

} // namespace

void WPParticleRawGener::GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                                   SceneMesh& mesh, ParticleRawGenSpecOp& specOp,
                                   ParticleRenderScale render_scale,
                                   ParticleOverflowFlags& overflow_flags) {
    if (mesh.VertexCount() == 0 || mesh.IndexCount() == 0) return;
    auto& vertices = mesh.GetVertexArray(0);
    auto& indices  = mesh.GetIndexArray(0);

    const bool rope_trail = vertices.GetOption(WE_PRENDER_ROPETRAIL);
    const bool rope       = rope_trail || vertices.GetOption(WE_PRENDER_ROPE);
    const bool thick      = vertices.GetOption(WE_CB_THICK_FORMAT);
    const std::size_t expected = rope ? (thick ? kRopeThick : kRopeThin)
                                      : (thick ? kSpriteThick : kSpriteThin);
    if (vertices.OneSize() != expected) {
        LOG_ERROR("particle mesh has %zu floats per vertex where its renderer writes %zu; nothing "
                  "is drawn",
                  static_cast<std::size_t>(vertices.OneSize()), expected);
        indices.SetDrawIndexCount(0);
        return;
    }

    Target target;
    target.vertices = &vertices;
    target.indices  = &indices;
    target.floats   = expected;
    target.thick    = thick;
    target.capacity = std::min<uint64_t>(indices.QuadCapacity(), vertices.CapacitySize() / (expected * 4));

    if (rope_trail) GenerateRopeTrails(instances, target, render_scale);
    else if (rope) GenerateRopes(instances, target, render_scale);
    else GenerateSprites(instances, target, specOp);

    // What did not fit is dropped and said once; the latch clears when the
    // count fits again.
    if (target.wanted > target.capacity) {
        if (rope) {
            if (! overflow_flags.rope_capacity) {
                overflow_flags.rope_capacity = true;
                LOG_ERROR("rope needs %llu pieces but its mesh holds %llu; the rest are not drawn",
                          static_cast<unsigned long long>(target.wanted),
                          static_cast<unsigned long long>(target.capacity));
            }
        } else if (! overflow_flags.index) {
            overflow_flags.index = true;
            LOG_ERROR("particles need %llu quads but the mesh holds %llu; the rest are not drawn",
                      static_cast<unsigned long long>(target.wanted),
                      static_cast<unsigned long long>(target.capacity));
        }
    } else {
        if (rope && target.wanted < target.capacity) overflow_flags.rope_capacity = false;
        if (! rope) overflow_flags.index = false;
    }

    uint64_t draw = 0;
    if (! CheckedMulU64(target.quads, 6, draw)) {
        indices.SetDrawIndexCount(0);
        return;
    }
    ExtendIndices(indices, target.quads);
    indices.SetDrawIndexCount(static_cast<std::size_t>(draw));
}
