#include "WPShaderValueUpdater.hpp"
#include "Utils/Linalg.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "Core/ArrayHelper.hpp"
#include "Utils/Algorism.h"
#include "Utils/TimeOfDay.hpp"

#include <iostream>
#include <chrono>
#include <ctime>
#include <numeric>
#include <vector>
#include <span>
#include <algorithm>
#include <cmath>

using namespace wallpaper;
using namespace wallpaper::linalg;

namespace
{

constexpr std::string_view G_NORMALMODEL            = "g_NormalModelMatrix";

constexpr std::string_view G_LPOINT_COLOR         = "g_LPoint_Color";
constexpr std::string_view G_LPOINT_ORIGIN        = "g_LPoint_Origin";
constexpr std::string_view G_LSPOT_COLOR          = "g_LSpot_Color";
constexpr std::string_view G_LSPOT_ORIGIN         = "g_LSpot_Origin";
constexpr std::string_view G_LSPOT_DIRECTION      = "g_LSpot_Direction";
constexpr std::string_view G_LSPOT_EXPONENT       = "g_LSpot_Exponent";
constexpr std::string_view G_LTUBE_COLOR          = "g_LTube_Color";
constexpr std::string_view G_LTUBE_ORIGINA        = "g_LTube_OriginA";
constexpr std::string_view G_LTUBE_ORIGINB        = "g_LTube_OriginB";
constexpr std::string_view G_LDIRECTIONAL_COLOR   = "g_LDirectional_Color";
constexpr std::string_view G_LDIRECTIONAL_DIRECTION = "g_LDirectional_Direction";
constexpr std::array       kLightingV1Uniforms {
    G_LPOINT_COLOR,  G_LPOINT_ORIGIN,  G_LSPOT_COLOR,        G_LSPOT_ORIGIN,
    G_LSPOT_DIRECTION, G_LSPOT_EXPONENT, G_LTUBE_COLOR,      G_LTUBE_ORIGINA,
    G_LTUBE_ORIGINB, G_LDIRECTIONAL_COLOR, G_LDIRECTIONAL_DIRECTION,
};

/// One frame's `LightingV1` uniform arrays, four floats per slot, laid out as
/// Wallpaper Engine fills them: each kind's visible lights in scene order, up
/// to the count the scene's light config compiled its shaders for, with unused
/// slots left zero.
struct LightingV1Arrays {
    std::vector<float> point_color, point_origin;
    std::vector<float> spot_color, spot_origin, spot_direction, spot_exponent;
    std::vector<float> tube_color, tube_origin_a, tube_origin_b;
    std::vector<float> directional_color, directional_direction;
};

/// A material that reads the screen behind a layer through its
/// model-view-projection matrix, which `composelayer.vert` turns into the screen
/// coordinate it samples: the first pass of a compose layer.
bool SamplesScreenBackground(const SceneMaterial& material) {
    return material.name == "composelayer";
}

void PutVec4(std::vector<float>& array, std::size_t slot, const Vector3d& xyz, float w) {
    array[slot * 4 + 0] = static_cast<float>(xyz.x());
    array[slot * 4 + 1] = static_cast<float>(xyz.y());
    array[slot * 4 + 2] = static_cast<float>(xyz.z());
    array[slot * 4 + 3] = w;
}

LightingV1Arrays PackLightingV1(const Scene& scene) {
    const auto&      config = scene.light_config;
    LightingV1Arrays arrays;
    for (auto* array : { &arrays.point_color, &arrays.point_origin }) array->assign(config.point * 4, 0.0f);
    for (auto* array : { &arrays.spot_color, &arrays.spot_origin, &arrays.spot_direction,
                         &arrays.spot_exponent })
        array->assign(config.spot * 4, 0.0f);
    for (auto* array : { &arrays.tube_color, &arrays.tube_origin_a, &arrays.tube_origin_b })
        array->assign(config.tube * 4, 0.0f);
    for (auto* array : { &arrays.directional_color, &arrays.directional_direction })
        array->assign(config.directional * 4, 0.0f);

    std::size_t point = 0, spot = 0, tube = 0, directional = 0;
    constexpr double kDegrees = 3.14159265358979323846 / 180.0;
    for (const auto& light : scene.lights) {
        if (light == nullptr || light->node() == nullptr || ! light->visible()) continue;
        auto* node = light->node();
        node->UpdateTrans();
        const Matrix4d  world  = node->ModelTrans();
        const Vector3d  origin = world.block<3, 1>(0, 3);
        // The light's own x axis, scale included, is the way a spot or
        // directional light points.
        const Vector3d  axis   = world.block<3, 1>(0, 0);
        const Vector3d  color  = (light->color() * light->intensity()).cast<double>();
        switch (light->type()) {
        case SceneLightType::Point:
            if (point >= config.point) break;
            PutVec4(arrays.point_color, point, color, light->radius());
            PutVec4(arrays.point_origin, point, origin, light->exponent());
            ++point;
            break;
        case SceneLightType::Spot:
            if (spot >= config.spot) break;
            PutVec4(arrays.spot_color, spot, color, light->radius());
            PutVec4(arrays.spot_origin, spot, origin,
                    static_cast<float>(std::cos(light->innerCone() * kDegrees)));
            PutVec4(arrays.spot_direction, spot, axis,
                    static_cast<float>(std::cos(light->outerCone() * kDegrees)));
            arrays.spot_exponent[spot * 4] = light->exponent();
            ++spot;
            break;
        case SceneLightType::Tube: {
            if (tube >= config.tube) break;
            const Vector4d far_end =
                world * light->controlPoint().cast<double>().homogeneous();
            PutVec4(arrays.tube_color, tube, color, light->radius());
            PutVec4(arrays.tube_origin_a, tube, origin, light->exponent());
            PutVec4(arrays.tube_origin_b, tube, far_end.head<3>(), 0.0f);
            ++tube;
            break;
        }
        case SceneLightType::Directional:
            if (directional >= config.directional) break;
            PutVec4(arrays.directional_color, directional, color, 1.0f);
            // Towards the light: it shines along its own x axis.
            PutVec4(arrays.directional_direction, directional, -axis, 0.0f);
            ++directional;
            break;
        case SceneLightType::Legacy: break;
        }
    }
    return arrays;
}

/// The legacy four-light packing: positions in `g_LightsPosition`, colours
/// premultiplied by intensity and radius squared in three vec4s, the fourth
/// light's channels in their w lanes.
struct LegacyLightArrays {
    std::array<float, 16> positions { 0 };
    std::array<float, 12> colors { 0 };
};

LegacyLightArrays PackLegacyLights(const Scene& scene) {
    // CLEANROOM SH58
    (void)scene;
    return LegacyLightArrays {};
}

uint64_t HashFloats(uint64_t hash, const float* values, std::size_t count) {
    const auto* bytes = reinterpret_cast<const unsigned char*>(values);
    for (std::size_t i = 0; i < count * sizeof(float); ++i) {
        hash = (hash ^ bytes[i]) * 0x100000001b3ULL;
    }
    return hash;
}

} // namespace

void WPShaderValueUpdater::FrameBegin() {
    for (auto& group : m_puppetAttachments) UpdatePuppetAttachments(group);
    if (const auto day_time = LocalTimeOfDay(m_wall_clock())) m_dayTime = *day_time;
    // Shaders see the cursor itself; only parallax eases towards it, as in
    // Wallpaper Engine: each frame it closes (1 - delay / 3) * 10 * frametime of
    // the remaining way, clamped to [0, 1], so a delay of zero (authored as
    // `cameraparallaxdelay: 0`) follows the cursor at once.
    m_mousePosLast = m_mousePos;
    m_mousePos     = m_mousePosInput;
    const std::array<float, 2> target { std::clamp(m_mousePosInput[0], 0.0f, 1.0f),
                                        std::clamp(m_mousePosInput[1], 0.0f, 1.0f) };
    double step = 1.0;
    if (m_parallax.delay > 0.0f) {
        step = std::clamp((1.0 - m_parallax.delay / 3.0) * 10.0 * m_scene->frameTime, 0.0, 1.0);
    }
    for (std::size_t axis = 0; axis < 2; ++axis) {
        m_parallaxPos[axis] = static_cast<float>(
            algorism::lerp(step, m_parallaxPos[axis], target[axis]));
    }
}

void WPShaderValueUpdater::FrameEnd() {}

uint64_t WPShaderValueUpdater::LightStateHash(SceneNode* node, uint32_t material_slot) const {
    if (node == nullptr || m_scene == nullptr) return 0;
    const auto slots = m_nodeUniformInfoMap.find(node);
    if (slots == m_nodeUniformInfoMap.end()) return 0;
    auto it = slots->second.find(material_slot);
    if (it == slots->second.end()) it = slots->second.find(0);
    if (it == slots->second.end()) return 0;
    const auto& info = it->second;
    if (! info.has_LP && ! info.has_LCP && ! info.has_LIGHTS_V1) return 0;

    uint64_t hash = 0xcbf29ce484222325ULL;
    if (info.has_LP || info.has_LCP) {
        const auto legacy = PackLegacyLights(*m_scene);
        hash = HashFloats(hash, legacy.positions.data(), legacy.positions.size());
        hash = HashFloats(hash, legacy.colors.data(), legacy.colors.size());
    }
    if (info.has_LIGHTS_V1) {
        const auto lights = PackLightingV1(*m_scene);
        for (const auto* values : {
                 &lights.point_color, &lights.point_origin, &lights.spot_color, &lights.spot_origin,
                 &lights.spot_direction, &lights.spot_exponent, &lights.tube_color,
                 &lights.tube_origin_a, &lights.tube_origin_b, &lights.directional_color,
                 &lights.directional_direction }) {
            hash = HashFloats(hash, values->data(), values->size());
        }
    }
    // Zero is "reads no lights"; a material that does never hashes to it.
    return hash == 0 ? 1 : hash;
}

uint32_t WPShaderValueUpdater::FrameVaryingUniforms(SceneNode*, uint32_t,
                                                    const std::string&) const {
    // CLEANROOM SH51
    return frame_varying_uniform::kAll;
}

void WPShaderValueUpdater::RegisterPuppetAttachments(
    WPPuppetLayer layer, std::vector<PuppetAttachment> attachments) {
    auto& group = m_puppetAttachments.emplace_back(
        PuppetAttachmentGroup { std::move(layer), std::move(attachments) });
    UpdatePuppetAttachments(group);
}

void WPShaderValueUpdater::UpdatePuppetAttachments(PuppetAttachmentGroup& group) {
    const auto bones = group.layer.genFrame(m_scene->elapsingTime);
    for (const auto& attachment : group.attachments) {
        if (attachment.node == nullptr || attachment.bone_index >= bones.size()) continue;
        attachment.node->SetAttachmentTransform(
            (bones[attachment.bone_index] * attachment.bind_transform).matrix().cast<double>());
    }
}

void WPShaderValueUpdater::MouseInput(double, double) {
    // CLEANROOM SH52
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, const ExistsUniformOp& existsOp) {
    InitUniforms(pNode, 0, existsOp);
}

void WPShaderValueUpdater::InitUniforms(SceneNode*, uint32_t, const ExistsUniformOp&) {
    // CLEANROOM SH49
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* pNode, sprite_map_t& sprites,
                                          const UpdateUniformOp& updateOp) {
    UpdateUniforms(pNode, 0, sprites, updateOp);
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode*, uint32_t, sprite_map_t&,
                                          const UpdateUniformOp&) {
    // CLEANROOM SH50
}

void WPShaderValueUpdater::SetNodeData(void* nodeAddr, const WPShaderValueData& data) {
    SetNodeData(nodeAddr, 0, data);
}

void WPShaderValueUpdater::SetNodeData(void* nodeAddr, uint32_t material_slot,
                                       const WPShaderValueData& data) {
    // CLEANROOM SH53
    if (data.parallax_layer != nullptr) {
        auto& passes = m_parallaxPasses[data.parallax_layer];
        if (std::find(passes.begin(), passes.end(), nodeAddr) == passes.end()) {
            passes.push_back(nodeAddr);
        }
    }
}

// A layer a script made has no record here until it asks for a depth; then it
// gets the default one, which differs from a layer with no record only in
// following the cursor by the depth it was given. The layers below it that
// already have a record take the same depth, and a layer drawn through effects
// takes it on its effect passes alone; a layer with none is not given one. The
// answer says whether any record went from standing still to following the
// cursor or the reverse.
bool WPShaderValueUpdater::SetNodeParallaxDepth(SceneNode* node, float x, float y) {
    if (node == nullptr || ! std::isfinite(x) || ! std::isfinite(y)) return false;
    const bool follows = x != 0.0f || y != 0.0f;
    bool       changed = false;
    const auto write   = [&](WPShaderValueData& data) {
        const bool followed = data.parallaxDepth[0] != 0.0f || data.parallaxDepth[1] != 0.0f;
        changed             = changed || followed != follows;
        data.parallaxDepth  = { x, y };
    };
    const auto write_all = [&](void* key, bool create) {
        auto found = m_nodeDataMap.find(key);
        if (found == m_nodeDataMap.end()) {
            if (! create) return;
            found = m_nodeDataMap.emplace(key, Map<uint32_t, WPShaderValueData> {}).first;
        }
        if (found->second.empty()) found->second[0] = WPShaderValueData {};
        for (auto& [slot, data] : found->second) write(data);
    };
    std::vector<SceneNode*> pending { node };
    while (! pending.empty()) {
        SceneNode* layer = pending.back();
        pending.pop_back();
        // A layer drawn through effect passes has its depth on them, and only
        // there: its own node draws the first pass into the layer's target, which
        // stays where it is, so the record it holds (the parser leaves its depth
        // at zero) is neither given nor written one.
        const auto passes     = m_parallaxPasses.find(layer);
        const bool has_passes = passes != m_parallaxPasses.end() && ! passes->second.empty();
        if (has_passes) {
            for (void* pass : passes->second) write_all(pass, false);
        } else {
            write_all(layer, layer == node);
        }
        for (const auto& child : layer->GetChildren()) pending.push_back(child.get());
    }
    return changed;
}

// A layer drawn through effects holds its depth on the passes, not on its own
// node, so those are asked first.
std::array<float, 2> WPShaderValueUpdater::NodeParallaxDepth(const SceneNode* node) const {
    const auto depth_of = [this](void* key) -> std::optional<std::array<float, 2>> {
        const auto slots = m_nodeDataMap.find(key);
        if (slots == m_nodeDataMap.end() || slots->second.empty()) return std::nullopt;
        const auto first = slots->second.find(0);
        return (first != slots->second.end() ? first->second : slots->second.begin()->second)
            .parallaxDepth;
    };
    if (const auto passes = m_parallaxPasses.find(node); passes != m_parallaxPasses.end()) {
        for (void* pass : passes->second) {
            if (const auto depth = depth_of(pass)) return *depth;
        }
    }
    return depth_of(const_cast<SceneNode*>(node)).value_or(std::array<float, 2> { 0.0f, 0.0f });
}

void WPShaderValueUpdater::ForgetNode(SceneNode* node) {
    m_nodeDataMap.erase(node);
    m_nodeUniformInfoMap.erase(node);
    m_parallaxPasses.erase(node);
}

void WPShaderValueUpdater::SetTexelSize(float, float) {
    // CLEANROOM SH54
}
