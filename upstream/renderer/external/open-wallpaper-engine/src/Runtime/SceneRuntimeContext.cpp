#include "Runtime/SceneRuntimeContext.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scene/include/Scene/Scene.h"
#include "Scene/include/Scene/SceneImageEffectLayer.h"
#include "Scene/include/Scene/SceneMaterial.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Scripting/ScriptEngine.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "WPSoundParser.hpp"

#include "Utils/Linalg.hpp"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <limits>
#include <sstream>
#include <vector>

// CLEANROOM: the stubs below leave their parameters unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"

namespace wallpaper
{

namespace
{
std::string NormalizeTemplatePath(std::string_view value) {
    // CLEANROOM RT27
    return {};
}

// Where the editor puts an asset imported from the Workshop: `models/bar.json`
// of item 123 lands at `models/workshop/123/bar.json`. Empty for anything that
// is not a numeric item id or already names a workshop folder.
std::string MakeWorkshopAssetPath(std::string_view asset_path, std::string_view workshop_id) {
    if (workshop_id.empty() ||
        ! std::all_of(workshop_id.begin(), workshop_id.end(), [](char c) {
            return c >= '0' && c <= '9';
        }))
        return {};

    const std::string normalized = NormalizeTemplatePath(asset_path);
    const std::size_t slash      = normalized.find('/');
    if (slash == std::string::npos || slash == 0 || slash + 1 >= normalized.size()) return {};

    const std::string folder = normalized.substr(0, slash + 1);
    const std::string rest   = normalized.substr(slash + 1);
    if (rest.starts_with("workshop/")) return {};
    return folder + "workshop/" + std::string(workshop_id) + "/" + rest;
}

bool SizeNearlyEqual(linalg::Vector2f lhs, linalg::Vector2f rhs, float tolerance) {
    // CLEANROOM RT21
    return false;
}

linalg::Vector2d CursorWorldToNdc(const CursorViewport& viewport, const linalg::Vector3f& cursor) {
    if (viewport.content_size.x() == 0.0f || viewport.content_size.y() == 0.0f) {
        return linalg::Vector2d { 0.0, 0.0 };
    }
    return linalg::Vector2d {
        2.0 * (static_cast<double>(cursor.x()) - viewport.content_origin.x()) /
                viewport.content_size.x() -
            1.0,
        2.0 * (static_cast<double>(cursor.y()) - viewport.content_origin.y()) /
                viewport.content_size.y() -
            1.0,
    };
}

template<typename ListT>
bool SortNodeInList(ListT& nodes, SceneNode* target, int index) {
    // CLEANROOM RT22
    return false;
}

// A value of another kind is a change even when both print alike.
bool ProjectPropertyValueChanged(const RuntimeScalarValue& previous,
                                 const RuntimeScalarValue& next) {
    if (previous.kind != next.kind) return true;
    switch (next.kind) {
    case RuntimeScalarValue::Kind::Bool: return previous.bool_value != next.bool_value;
    case RuntimeScalarValue::Kind::Float: return previous.float_value != next.float_value;
    case RuntimeScalarValue::Kind::String: return previous.string_value != next.string_value;
    }
    return false;
}

// The layer's alpha in a material that takes it: the `g_Color4` and `g_Alpha` every
// pass of the layer is given and, on the layer's own pass, its `g_UserAlpha`. An
// effect's is the effect's own opacity (`own_user_alpha`): it starts from the
// layer's authored alpha, the effect's own `alpha` replaces that, and either is
// left alone, or the layer's alpha would be applied again by every effect that has
// an alpha.
void ApplyMaterialAlpha(SceneMaterial& material, float alpha) {
    // CLEANROOM RT26
}

// The layer's colour times its brightness where the scene renders HDR, with the
// alpha `g_Color4` already holds.
void ApplyMaterialTint(SceneMaterial& material) {
    // CLEANROOM RT26
}

void ApplyMaterialColor(SceneMaterial& material, const linalg::Vector3f& color) {
    material.tint.color = { color.x(), color.y(), color.z() };
    material.customShader.constValues["g_Color"] =
        std::array<float, 3> { color.x(), color.y(), color.z() };
    ApplyMaterialTint(material);
}

void ApplyMaterialBrightness(SceneMaterial& material, float brightness) {
    material.tint.brightness = brightness;
    ApplyMaterialTint(material);
}

// The rotation `SceneNode::GetLocalTrans` applies to the layer's geometry:
// x first, then y, then z.
linalg::Matrix3f NodeRotationMatrix(const linalg::Vector3f& angles) {
    return (linalg::AngleAxisf(angles.z(), linalg::Vector3f::UnitZ()) *
            linalg::AngleAxisf(angles.y(), linalg::Vector3f::UnitY()) *
            linalg::AngleAxisf(angles.x(), linalg::Vector3f::UnitX()))
        .toRotationMatrix();
}

} // namespace

bool NodeHitMask::covers(float u, float v) const noexcept {
    if (width == 0 || height == 0 || ! std::isfinite(u) || ! std::isfinite(v)) return false;
    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f) return false;
    const auto x = std::min<uint32_t>(static_cast<uint32_t>(u * static_cast<float>(width)), width - 1);
    const auto y = std::min<uint32_t>(static_cast<uint32_t>(v * static_cast<float>(height)), height - 1);
    return alpha[static_cast<std::size_t>(y) * width + x] >= kOpaqueThreshold;
}

SceneRuntimeContext::SceneRuntimeContext(SceneRuntimeBootstrap bootstrap) {
    // CLEANROOM RT14
    m_script_engine = std::make_unique<ScriptEngine>();
    m_host_context  = std::make_unique<ScriptHostContext>();
}

SceneRuntimeContext::~SceneRuntimeContext() {
    // Scripts end while the layers and values they could still touch exist.
    TearDownScripts();
    // From here on the registry is going away with the other members, and a
    // scripted value destroyed with them has nothing to leave.
    m_scripted_value_registry.reset();
    StopTextWorker();
}

void SceneRuntimeContext::TearDownScripts() {
    // A `destroy()` may create layers, which can register more scripts: those
    // are never started, so only the ones present now are ended, by index.
    const auto value_count  = m_scripted_values.size();
    const auto script_count = m_scene_scripts.size();
    for (std::size_t index = 0; index < value_count; ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) value->Destroy();
    }
    for (std::size_t index = 0; index < script_count; ++index) {
        if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) script->Destroy();
    }
}

void SceneRuntimeContext::Tick(double frame_time) {
    // CLEANROOM RT15
}

ScriptEngine& SceneRuntimeContext::scriptEngine() { return *m_script_engine; }

const ScriptHostContext& SceneRuntimeContext::hostContext() const { return *m_host_context; }

const ProjectProperties& SceneRuntimeContext::defaultProjectProperties() const {
    // CLEANROOM RT14
    static const ProjectProperties neutral {};
    return neutral;
}

const ProjectProperties& SceneRuntimeContext::projectProperties() const {
    // CLEANROOM RT14
    static const ProjectProperties neutral {};
    return neutral;
}

std::vector<std::string> SceneRuntimeContext::ApplyProjectPropertyOverride(
    const ProjectProperties& override_properties) {
    // CLEANROOM RT16
    return {};
}

void SceneRuntimeContext::NoteLoadOnlyProperty(std::string_view name) {
    if (name.empty()) return;
    std::string key(name);
    if (m_load_only_properties.contains(key)) return;
    const auto found = m_project_properties.find(key);
    std::optional<RuntimeScalarValue> read_with;
    if (found != m_project_properties.end()) read_with = found->second;
    m_load_only_properties.emplace(std::move(key), std::move(read_with));
}

std::vector<std::string> SceneRuntimeContext::LoadOnlyProperties() const {
    std::vector<std::string> names;
    names.reserve(m_load_only_properties.size());
    for (const auto& entry : m_load_only_properties) names.push_back(entry.first);
    return names;
}

ProjectPropertyPreview SceneRuntimeContext::PreviewProjectPropertyOverride(
    const ProjectProperties& override_properties) {
    // CLEANROOM RT16
    return {};
}

std::vector<std::string> SceneRuntimeContext::ApplyProjectProperties(
    ProjectProperties next_properties) {
    // CLEANROOM RT16
    return {};
}

std::vector<std::string> SceneRuntimeContext::ResetProjectPropertyOverride() {
    return ApplyProjectPropertyOverride({});
}

void SceneRuntimeContext::AttachScene(Scene* scene) {
    // CLEANROOM RT14
}

void SceneRuntimeContext::SetCursorWorldPosition(const linalg::Vector3f& value) {
    // CLEANROOM RT17
}

void SceneRuntimeContext::SetCursorViewport(const CursorViewport& viewport) {
    if (! viewport.origin.allFinite() || ! viewport.size.allFinite()) return;
    if (! viewport.content_origin.allFinite() || ! viewport.content_size.allFinite()) return;
    if (viewport.size.x() == 0.0f || viewport.size.y() == 0.0f) return;
    m_cursor_viewport = viewport;
    UpdatePresentedMargins();
}

void SceneRuntimeContext::UpdatePresentedMargins() {
    // CLEANROOM RT17
}

/// Publishes the display's pixel resolution, which is what
/// `engine.screenResolution` means.
///
/// This used to be the cursor viewport's size, which is the region of the
/// scene's own world the window shows -- 2560x1080 scene units for a wallpaper
/// authored at that size, whatever display it is on. A script sizing itself
/// against the screen got the author's canvas back instead. The rasterization
/// size is not it either: internal quality may halve that, and a quality
/// setting must not move a layout.
void SceneRuntimeContext::SetScreenResolution(const linalg::Vector2f& resolution) {
    if (! resolution.allFinite()) return;
    if (resolution.x() <= 0.0f || resolution.y() <= 0.0f) return;
    // A new size is news to the scripts, which are told on the next tick.
    if (! SizeNearlyEqual(m_host_context->screen_resolution, resolution, 0.5f)) {
        m_screen_resize_pending = true;
    }
    m_host_context->screen_resolution = resolution;
}

void SceneRuntimeContext::SetLanguage(std::string_view language) {
    std::string normalized;
    normalized.reserve(language.size());
    for (const char character : language) {
        normalized.push_back(character == '_'
                                 ? '-'
                                 : static_cast<char>(std::tolower(static_cast<unsigned char>(character))));
    }
    if (normalized.empty()) normalized = "en-us";
    if (normalized == m_host_context->language) return;
    m_host_context->language = std::move(normalized);
    m_general_settings_pending = true;
}

const std::string& SceneRuntimeContext::Language() const { return m_host_context->language; }

void SceneRuntimeContext::SetCursorInput(float x, float y) {
    // CLEANROOM RT17
}

// `input.cursorWorldPosition`. Wallpaper Engine unprojects the pointer through
// the scene camera at window depth 0.5, which its [-1, 1] depth remap turns
// into 0, and its perspective projection stores depth reversed (1 at the near
// plane, 0 at the far one): the script gets the cursor ray's point at the far
// plane, `farz` in front of the eye, in the same world as layer origins. A
// scene authored on a canvas gets canvas units with z = 0 (it hands over its
// 2D point whatever the camera). Wallpaper Engine unprojects when a script
// reads; this is worked out when the cursor is sampled, before the tick's
// scripts and camera shake move the camera, so it is the pose the last tick
// left. A camera with no usable view (a far plane or aspect that is not
// positive) keeps the canvas point rather than a made-up depth.
linalg::Vector3f SceneRuntimeContext::ScriptCursorWorldPosition() const {
    const SceneCamera* camera =
        m_scene != nullptr && m_scene->display_sized ? m_scene->activeCamera : nullptr;
    if (camera == nullptr || ! camera->IsPerspective()) return m_cursor_plane_position;
    const linalg::Vector2d ndc = CursorWorldToNdc(m_cursor_viewport, m_cursor_plane_position);
    const auto point = UnprojectNdcAtDepth(*camera, ndc.x(), ndc.y(), camera->FarClip());
    return point.has_value() ? linalg::Vector3f(point->cast<float>()) : m_cursor_plane_position;
}

void SceneRuntimeContext::SetCursorEnter(bool entered) {
    // CLEANROOM RT17
}

void SceneRuntimeContext::SetCursorButton(int button, bool pressed) {
    // CLEANROOM RT17
}

void SceneRuntimeContext::SetCursorButtons(uint32_t down, uint32_t pressed, uint32_t released) {
    // CLEANROOM RT17
}

void SceneRuntimeContext::BeginFrame() {
    // CLEANROOM RT17
}

void SceneRuntimeContext::StopTextWorker() {
    // CLEANROOM RT20
}

void SceneRuntimeContext::WaitForTextLayoutForTests() const {
    // CLEANROOM RT20
}

bool SceneRuntimeContext::TextLayoutInFlight() const {
    // CLEANROOM RT20
    return false;
}

bool SceneRuntimeContext::TextLayerIsBeingPrepared(const std::string& name) const {
    const auto node = m_nodes.find(name);
    if (node == m_nodes.end() || node->second == nullptr) return true;
    return node->second->EffectiveVisible() || node->second->MustProduce();
}

void SceneRuntimeContext::SetContentWakeHandler(std::function<void()> handler) {
    // CLEANROOM RT20
}

void SceneRuntimeContext::FitTextLayerComposite(SceneNode& node,
                                                const TextLayerRenderFrame& card) {
    if (m_scene == nullptr || card.size.x() <= 0.0f || card.size.y() <= 0.0f) return;
    const auto camera = m_scene->cameras.find(LayerCompositeCameraKey(node.ID()));
    if (camera == m_scene->cameras.end() || camera->second == nullptr ||
        camera->second->GetAttachedNode() == nullptr)
        return;
    camera->second->SetWidth(card.size.x());
    camera->second->SetHeight(card.size.y());
    camera->second->GetAttachedNode()->SetTranslate(
        linalg::Vector3f(card.center.x(), card.center.y(), 0.0f));
    camera->second->Update();
    // One texel per unit of the card with the fraction cut off, as at parse
    // time: a consumer may place the image by its size (`g_Texture1Resolution`),
    // so stretching a new card over the old target would show the text at
    // another scale. Only a card whose size in texels changed costs a new graph.
    const auto found = m_scene->renderTargets.find(LayerCompositeTargetKey(node.ID()));
    if (found == m_scene->renderTargets.end()) return;
    auto&      target = found->second;
    const auto [width, height] = TextCardTexelExtent(card.size);
    const auto current_width  = target.authored_width > 0 ? target.authored_width : target.width;
    const auto current_height = target.authored_height > 0 ? target.authored_height : target.height;
    if (current_width == width && current_height == height) return;
    target.width = target.authored_width = width;
    target.height = target.authored_height = height;
    MarkRenderTargetsResized("text-card-texels");
}

DynamicValue* SceneRuntimeContext::FindPropertyValue(std::string_view name) const {
    // CLEANROOM RT16
    return {};
}

void SceneRuntimeContext::RegisterScriptedValue(ScriptedDynamicValue* value) {
    // CLEANROOM RT14
}

void SceneRuntimeContext::UnregisterScriptedValue(ScriptedDynamicValue* value) {
    if (value == nullptr) return;
    // Slots are emptied, not erased: a tick that is walking the list keeps its indices.
    std::replace(m_scripted_values.begin(), m_scripted_values.end(), value,
                 static_cast<ScriptedDynamicValue*>(nullptr));
    m_scripted_value_cursor_inside.erase(value);
    for (auto& [button, held] : m_scripted_value_cursor_held) std::erase(held, value);
}

void SceneRuntimeContext::RegisterNode(std::string name, SceneNode* node) {
    // CLEANROOM RT22
}

void SceneRuntimeContext::RegisterLayerAlias(std::string authored_name, std::string runtime_name) {
    // The parser registers these in authored order. Duplicate names still
    // have independent binding keys; name lookup selects the first layer.
    m_layer_aliases.try_emplace(std::move(authored_name), std::move(runtime_name));
}

std::string SceneRuntimeContext::ResolveLayerName(std::string_view name) const {
    // CLEANROOM RT22
    return {};
}

void SceneRuntimeContext::UnregisterNode(std::string_view name) {
    // CLEANROOM RT22
}

void SceneRuntimeContext::RollbackNodeRegistration(
    std::string_view name,
    SceneNode* node,
    std::shared_ptr<const NodeRegistrationSnapshot> previous) {
    // CLEANROOM RT22
}

std::shared_ptr<SceneRuntimeContext::NodeRegistrationSnapshot>
SceneRuntimeContext::CaptureNodeRegistration(std::string_view name) const {
    // CLEANROOM RT22
    return std::make_shared<NodeRegistrationSnapshot>();
}

void SceneRuntimeContext::RegisterNodeSize(std::string name, linalg::Vector2f value) {
    // CLEANROOM RT22
}

void SceneRuntimeContext::RegisterNodeHitMask(std::string name, NodeHitMask mask) {
    if (name.empty() || mask.width == 0 || mask.height == 0 ||
        mask.alpha.size() != static_cast<std::size_t>(mask.width) * mask.height) {
        return;
    }
    m_node_hit_masks[std::move(name)] = std::move(mask);
}

void SceneRuntimeContext::RegisterPuppetLayer(std::string name, WPPuppetLayer layer) {
    if (name.empty() || ! layer.hasPuppet()) return;
    m_puppet_layers[std::move(name)] = std::move(layer);
}

WPPuppetLayer* SceneRuntimeContext::FindPuppetLayer(std::string_view name) {
    const auto iterator = m_puppet_layers.find(std::string(name));
    return iterator == m_puppet_layers.end() ? nullptr : &iterator->second;
}

double SceneRuntimeContext::PuppetAnimationControl(std::string_view layer_name,
                                                   std::string_view animation_layer,
                                                   std::string_view operation, double value,
                                                   bool has_value) {
    auto* puppet = FindPuppetLayer(layer_name);
    if (puppet == nullptr) return 0.0;
    // A question about the whole stack, answered before any one layer is named.
    if (operation == "layerCount") return static_cast<double>(puppet->layerCount());
    const i32 index = puppet->findLayer(animation_layer);
    // The stack index of the layer, which a listener is filed under.
    if (operation == "index") return static_cast<double>(index);
    if (index < 0) return 0.0;
    if (operation == "play") return puppet->play(index) ? 1.0 : 0.0;
    if (operation == "pause") return puppet->pause(index) ? 1.0 : 0.0;
    if (operation == "stop") return puppet->stop(index) ? 1.0 : 0.0;
    if (operation == "isPlaying") return puppet->isPlaying(index) ? 1.0 : 0.0;
    if (operation == "exists") return 1.0;
    if (operation == "frame") return puppet->frame(index);
    if (operation == "frameCount") return puppet->frameCount(index);
    if (operation == "fps") return puppet->fps(index);
    if (operation == "rate") return puppet->rate(index);
    if (operation == "blend") return puppet->blend(index);
    if (operation == "visible") return puppet->visible(index) ? 1.0 : 0.0;
    if (! has_value) return 0.0;
    if (operation == "setFrame") return puppet->setFrame(index, value) ? 1.0 : 0.0;
    if (operation == "setRate") return puppet->setRate(index, value) ? 1.0 : 0.0;
    if (operation == "setBlend") return puppet->setBlend(index, value) ? 1.0 : 0.0;
    if (operation == "setVisible") return puppet->setVisible(index, value != 0.0) ? 1.0 : 0.0;
    return 0.0;
}

std::string SceneRuntimeContext::PuppetAnimationLayerName(std::string_view layer_name,
                                                          std::string_view animation_layer) {
    auto* puppet = FindPuppetLayer(layer_name);
    return puppet != nullptr ? puppet->layerName(puppet->findLayer(animation_layer)) : std::string {};
}

void SceneRuntimeContext::RegisterLayerTemplate(std::string                template_path,
                                                std::shared_ptr<SceneNode> node,
                                                linalg::Vector2f            size) {
    // CLEANROOM RT27
}

void SceneRuntimeContext::SetLayerTemplateLoader(std::function<bool(std::string_view)> loader) {
    m_layer_template_loader = std::move(loader);
    m_failed_layer_templates.clear();
}

void SceneRuntimeContext::RegisterNodeVisibility(std::string name, SceneNode* node,
                                                 std::unique_ptr<DynamicValue> value) {
    // CLEANROOM RT24
}

void SceneRuntimeContext::RegisterEffectVisibility(std::shared_ptr<SceneImageEffect> effect,
                                                   std::unique_ptr<DynamicValue> value) {
    if (effect == nullptr || value == nullptr) return;
    // The value as the scene loads is what the first graph is built with, so
    // only a later switch asks for a rebuild.
    effect->visible = value->getBool();
    RegisterDynamicValueListener(std::move(value), [this, effect](const DynamicValue& current) {
        const bool visible = current.getBool();
        if (effect->visible == visible) return;
        effect->visible       = visible;
        MarkSceneGraphMutated("effect-visibility");
        // A text layer counts its visible effects: the switch may pad it or take its padding
        // away, and decides whether its glyphs are composited.
        for (const auto& [name, gate] : m_text_effect_gates) {
            if (std::find(gate.effects.begin(), gate.effects.end(), effect) != gate.effects.end()) {
                RefreshTextEffectGate(name);
            }
        }
    });
}

void SceneRuntimeContext::RegisterTextEffectGate(std::string name, TextEffectGate gate) {
    if (name.empty()) return;
    m_text_effect_gates.insert_or_assign(name, std::move(gate));
    RefreshTextEffectGate(name);
}

void SceneRuntimeContext::RefreshTextEffectGate(const std::string& name) {
    const auto gate = m_text_effect_gates.find(name);
    if (gate == m_text_effect_gates.end()) return;
    const bool visible = std::any_of(gate->second.effects.begin(), gate->second.effects.end(),
                                     [](const auto& effect) { return effect->visible; });
    if (const auto layer = m_text_layers.find(name); layer != m_text_layers.end()) {
        layer->second.SetPaddingApplies(gate->second.padded_regardless || visible);
    }
    if (gate->second.composite != nullptr) gate->second.composite->update(visible ? 1.0f : 0.0f);
}

void SceneRuntimeContext::ApplyNodeVec3Animation(NodeVec3Binding& binding) {
    if (binding.animation == nullptr || binding.animation->playback == nullptr) return;
    const double frame = binding.animation->playback->frame;
    if (frame == binding.sampled_animation_frame) return;
    const auto value = binding.animation->Value();
    binding.value->update(linalg::Vector3f(value[0], value[1], value[2]));
    binding.sampled_animation_frame = frame;
}

void SceneRuntimeContext::ApplyMaterialColorAnimation(MaterialColorBinding& binding) {
    if (binding.animation == nullptr || binding.animation->playback == nullptr) return;
    const double frame = binding.animation->playback->frame;
    if (frame == binding.sampled_animation_frame) return;
    const auto value = binding.animation->Value();
    const linalg::Vector3f color(value[0], value[1], value[2]);
    for (const auto& weak : binding.materials) {
        if (const auto material = weak.lock()) ApplyMaterialColor(*material, color);
    }
    binding.sampled_animation_frame = frame;
}

void SceneRuntimeContext::RegisterNodeTranslate(std::string name, SceneNode* node,
                                                std::unique_ptr<DynamicValue> value,
                                                std::shared_ptr<const NodeVec3Animation> animation) {
    // CLEANROOM RT23
}

void SceneRuntimeContext::RegisterNodeScale(std::string name, SceneNode* node,
                                            std::unique_ptr<DynamicValue> value,
                                            std::shared_ptr<const NodeVec3Animation> animation) {
    // CLEANROOM RT23
}

void SceneRuntimeContext::RegisterNodeRotation(std::string name, SceneNode* node,
                                               std::unique_ptr<DynamicValue> value,
                                               std::shared_ptr<const NodeVec3Animation> animation) {
    // CLEANROOM RT23
}

void SceneRuntimeContext::RegisterTextLayer(std::string name, TextLayerState state) {
    // CLEANROOM RT25
}

void SceneRuntimeContext::RegisterTextLayer(std::string name, TextLayerState state,
                                            TextLayerLayout layout) {
    if (name.empty()) return;
    if (state.layer_key.empty()) state.layer_key = name;
    auto layer        = TextLayer(std::move(state), std::move(layout));
    RegisterNodeSize(name, layer.size());
    m_text_layers.insert_or_assign(std::move(name), std::move(layer));
}

void SceneRuntimeContext::RegisterTextValue(std::string name,
                                            std::unique_ptr<DynamicValue> value,
                                            bool apply_current_value) {
    // CLEANROOM RT25
}

void SceneRuntimeContext::RegisterMaterialConstant(
    std::shared_ptr<SceneMaterial> material, std::string name,
    std::unique_ptr<DynamicValue> value,
    std::shared_ptr<const MaterialConstantAnimation> animation) {
    // CLEANROOM RT26
}

void SceneRuntimeContext::RegisterSceneZoomAnimation(
    std::shared_ptr<ScalarAnimationPlayback> animation) {
    m_scene_zoom_animation = std::move(animation);
    ApplySceneZoomAnimation();
}

void SceneRuntimeContext::RegisterSceneZoom(std::unique_ptr<DynamicValue> zoom) {
    RegisterDynamicValueListener(std::move(zoom), [this](const DynamicValue& value) {
        ApplySceneZoom(value.getFloat());
    });
}

void SceneRuntimeContext::ApplySceneZoomAnimation() {
    if (m_scene_zoom_animation == nullptr) return;
    ApplySceneZoom(m_scene_zoom_animation->Value());
}

void SceneRuntimeContext::ApplySceneZoom(double zoom) {
    // CLEANROOM RT26
}

void SceneRuntimeContext::RegisterCameraShot(SceneNode* node, std::unique_ptr<DynamicValue> zoom,
                                             CameraShotTimeline timeline, bool origin_bound) {
    if (node == nullptr || zoom == nullptr) return;
    auto* raw = zoom.get();
    m_owned_values.push_back(std::move(zoom));
    m_camera_shots.push_back(CameraShotBinding {
        .node           = node,
        .zoom           = raw,
        .timeline       = std::move(timeline),
        .origin_pending = origin_bound,
    });
    ApplyCameraShots();
}

void SceneRuntimeContext::ApplyCameraShots() {
    if (m_scene == nullptr || m_camera_shots.empty()) return;

    double          zoom   = 1.0;
    linalg::Vector2f offset = linalg::Vector2f::Zero();
    for (auto& shot : m_camera_shots) {
        const auto& timeline = shot.timeline;
        const auto  sample   = [&timeline](const ScalarAnimation& curve) {
            const double frame = timeline.clock->frame;
            return curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
        };
        // The timeline moves the layer whether or not it is the shot shown, so
        // a shot revealed later picks up where its playhead stands, and a
        // script reading the layer's origin sees where the view is going.
        if (timeline.clock != nullptr &&
            std::any_of(timeline.origin.begin(), timeline.origin.end(),
                        [](const auto& curve) { return curve.has_value(); })) {
            linalg::Vector3f origin = timeline.origin_base;
            for (std::size_t index = 0; index < timeline.origin.size(); ++index) {
                const auto& curve = timeline.origin[index];
                if (! curve.has_value()) continue;
                origin[index] = (timeline.origin_relative ? timeline.origin_base[index] : 0.0f) +
                                sample(*curve);
            }
            shot.node->SetTranslate(origin);
        }
        if (! shot.node->EffectiveVisible()) continue;
        zoom = timeline.clock != nullptr && timeline.zoom.has_value() ? sample(*timeline.zoom)
                                                                      : shot.zoom->getFloat();
        offset = shot.origin_pending ? linalg::Vector2f(linalg::Vector2f::Zero())
                                     : linalg::Vector2f(shot.node->Translate().head<2>());
    }

    if (m_framed_camera_shot.has_value() && m_framed_camera_shot->first == zoom &&
        m_framed_camera_shot->second == offset) {
        return;
    }
    m_framed_camera_shot = std::make_pair(zoom, offset);
    m_scene->FrameCanvas(zoom, offset);
}

void SceneRuntimeContext::RegisterPerspectiveCameraShot(
    std::shared_ptr<SceneNode> node, SceneCamera* camera, double fov, CameraPathPlayback path) {
    if (!node || !camera || !m_scene) return;
    if (m_perspective_camera_groups.empty()) m_fallback_active_camera = m_scene->activeCamera;
    auto group = std::find_if(m_perspective_camera_groups.begin(), m_perspective_camera_groups.end(),
                             [camera](const auto& value) { return value.camera == camera; });
    if (group == m_perspective_camera_groups.end()) {
        m_perspective_camera_groups.push_back(
            { camera, camera->GetAttachedNode(), camera->Fov(), {} });
        group = std::prev(m_perspective_camera_groups.end());
    }
    group->shots.push_back({ std::move(node), fov, std::move(path), ++m_perspective_shot_count });
    ApplyPerspectiveCameraShots(0.0);
}

void SceneRuntimeContext::ApplyPerspectiveCameraShots(double seconds) {
    if (!m_scene || m_perspective_camera_groups.empty()) return;
    auto* active = m_fallback_active_camera;
    std::size_t last_order = 0;
    for (auto& group : m_perspective_camera_groups) {
        PerspectiveCameraShot* selected = nullptr;
        for (auto& shot : group.shots) {
            if (shot.node->EffectiveVisible()) selected = &shot;
        }
        const auto& node = selected ? selected->node : group.fallback_node;
        if (node && group.camera->GetAttachedNode() != node) group.camera->AttatchNode(node);
        group.camera->SetFov(selected ? selected->fov : group.fallback_fov);
        if (!selected) continue;
        selected->path.Advance(seconds);
        selected->path.Apply(*selected->node, *group.camera);
        if (selected->order > last_order) {
            last_order = selected->order;
            active = group.camera;
        }
    }
    m_scene->activeCamera = active;
}

void SceneRuntimeContext::RegisterCameraShake(std::unique_ptr<DynamicValue> enabled,
                                              std::unique_ptr<DynamicValue> amplitude,
                                              std::unique_ptr<DynamicValue> speed,
                                              std::unique_ptr<DynamicValue> roughness) {
    if (enabled == nullptr || amplitude == nullptr || speed == nullptr || roughness == nullptr) {
        return;
    }
    m_camera_shake.registered = true;
    RegisterDynamicValueListener(std::move(enabled), [this](const DynamicValue& value) {
        m_camera_shake.enabled = value.getBool();
    });
    RegisterDynamicValueListener(std::move(amplitude), [this](const DynamicValue& value) {
        m_camera_shake.amplitude = value.getFloat();
    });
    RegisterDynamicValueListener(std::move(speed), [this](const DynamicValue& value) {
        m_camera_shake.speed = value.getFloat();
    });
    RegisterDynamicValueListener(std::move(roughness), [this](const DynamicValue& value) {
        m_camera_shake.roughness = value.getFloat();
    });
}

// Wallpaper Engine's camera shake: t = speed^2 * time, the offset
// (cos t, sin 1.333t, sin t), its length raised to roughness^3 (unless that is
// about 0 or exactly 1), scaled by amplitude / 10, and in a 2D scene by a tenth
// of the canvas height with no depth. The eye and what it looks at move by it
// together.
void SceneRuntimeContext::ApplyCameraShake() {
    if (! m_camera_shake.registered || m_scene == nullptr || m_scene->activeCamera == nullptr) {
        return;
    }
    auto& camera = *m_scene->activeCamera;
    if (! m_camera_shake.enabled) {
        camera.SetShakeOffset(linalg::Vector3d::Zero());
        return;
    }
    const double t =
        double(m_camera_shake.speed) * m_camera_shake.speed * m_host_context->runtime_seconds;
    linalg::Vector3d offset(std::cos(t), std::sin(t * 1.333), std::sin(t));
    double amplitude = m_camera_shake.amplitude * 0.1;
    if (! camera.IsPerspective()) {
        offset.z() = 0.0;
        amplitude *= m_scene->ortho[1] * 0.1;
    }
    const double roughness = std::pow(double(m_camera_shake.roughness), 3.0);
    const double length    = offset.norm();
    if (roughness > 0.001 && roughness != 1.0 && length > 0.0) {
        offset *= std::pow(length, roughness) / length;
    }
    camera.SetShakeOffset(offset * amplitude);
}

void SceneRuntimeContext::RegisterSceneClearColor(std::unique_ptr<DynamicValue> value) {
    // CLEANROOM RT26
}

void SceneRuntimeContext::RegisterDynamicValueListener(
    std::unique_ptr<DynamicValue> value,
    std::function<void(const DynamicValue&)> callback) {
    // CLEANROOM RT26
}

void SceneRuntimeContext::RegisterNodeEffectFinal(std::string name,
                                                  SceneNode* node,
                                                  SceneImageEffectLayer* layer,
                                                  TextLayerRenderFrame target_frame) {
    // CLEANROOM RT23
}

void SceneRuntimeContext::RegisterMaterialAlphaAnimation(
    std::shared_ptr<SceneMaterial> material, std::shared_ptr<ScalarAnimationPlayback> animation) {
    // CLEANROOM RT26
}

void SceneRuntimeContext::BindMaterialAlpha(std::shared_ptr<SceneMaterial> material,
                                            std::unique_ptr<DynamicValue> value) {
    if (material == nullptr || value == nullptr) return;
    RegisterDynamicValueListener(std::move(value), [material](const DynamicValue& current) {
        ApplyMaterialAlpha(*material, current.getFloat());
    });
}

void SceneRuntimeContext::BindMaterialColor(std::string layer_name,
                                            std::vector<std::shared_ptr<SceneMaterial>> materials,
                                            std::unique_ptr<DynamicValue> value) {
    if (materials.empty() || value == nullptr) return;
    if (! layer_name.empty()) m_node_color[std::move(layer_name)] = value.get();
    RegisterDynamicValueListener(
        std::move(value), [materials = std::move(materials)](const DynamicValue& current) {
            const auto color = current.getVec3();
            for (const auto& material : materials) {
                if (material != nullptr) ApplyMaterialColor(*material, color);
            }
        });
}

void SceneRuntimeContext::BindMaterialBrightness(
    std::vector<std::shared_ptr<SceneMaterial>> materials, std::unique_ptr<DynamicValue> value) {
    if (value == nullptr) return;
    // A brightness nothing draws with (outside an HDR scene) is still the runtime's
    // to keep: a script drives it.
    if (materials.empty()) {
        m_owned_values.push_back(std::move(value));
        return;
    }
    RegisterDynamicValueListener(
        std::move(value), [materials = std::move(materials)](const DynamicValue& current) {
            const float brightness = current.getFloat();
            if (! std::isfinite(brightness)) return;
            for (const auto& material : materials) {
                if (material != nullptr) ApplyMaterialBrightness(*material, brightness);
            }
        });
}

void SceneRuntimeContext::RegisterMaterialColorAnimation(
    std::vector<std::shared_ptr<SceneMaterial>> materials,
    std::shared_ptr<const NodeVec3Animation> animation) {
    if (materials.empty() || animation == nullptr) return;
    MaterialColorBinding binding;
    for (const auto& material : materials) {
        if (material != nullptr) binding.materials.push_back(material);
    }
    binding.animation = std::move(animation);
    ApplyMaterialColorAnimation(binding);
    m_material_colors.push_back(std::move(binding));
}

std::shared_ptr<ScalarAnimationPlayback> SceneRuntimeContext::RegisterScalarAnimation(
    std::string_view layer_name, ScalarAnimation animation) {
    if (!animation.name.empty()) {
        for (const auto& binding : m_scalar_animations) {
            if (binding.layer_name == layer_name && binding.playback->animation.name == animation.name) {
                return binding.playback;
            }
        }
    }
    auto playback = std::make_shared<ScalarAnimationPlayback>();
    playback->playing = !animation.start_paused;
    playback->animation = std::move(animation);
    m_scalar_animations.push_back({ std::string(layer_name), playback });
    return playback;
}

ScalarAnimationPlayback* SceneRuntimeContext::FindScalarAnimation(
    std::string_view layer_name, std::string_view animation_name) const {
    for (const auto& binding : m_scalar_animations) {
        if (binding.layer_name == layer_name && binding.playback->animation.name == animation_name) {
            return binding.playback.get();
        }
    }
    return nullptr;
}

ScalarAnimationPlayback* SceneRuntimeContext::FindAnimationByName(
    std::string_view animation_name) const {
    if (animation_name.empty()) return nullptr;
    for (const auto& binding : m_scalar_animations) {
        if (binding.playback->animation.name == animation_name) return binding.playback.get();
    }
    return nullptr;
}

void SceneRuntimeContext::RegisterSceneScript(std::string script_source, std::string layer_name) {
    // CLEANROOM RT14
}

void SceneRuntimeContext::RegisterNodeVideoTexture(std::string name, std::string texture_key) {
    // CLEANROOM RT29
}

void SceneRuntimeContext::RegisterSoundLayer(std::string                    name,
                                             std::shared_ptr<WPSoundStream> stream) {
    // CLEANROOM RT29
}

std::size_t SceneRuntimeContext::sceneScriptCount() const {
    // CLEANROOM RT14
    return 0;
}

uint32_t SceneRuntimeContext::DescribeTimeAdvancingWork() const {
    // Mirrors `Tick` step for step. Anything `Tick` advances has to be
    // represented here, or a scene would be allowed to sleep through work it
    // still performs. The ordering below is deliberately the ordering of the
    // loops in `Tick`, so the two can be diffed by eye.
    uint32_t reasons = 0;

    for (const auto& [texture_key, playback] : m_video_texture_playback) {
        (void)texture_key;
        // A paused source, or one stopped by a zero rate, advances nothing.
        // That is the same condition `Tick` uses to skip it.
        if (playback.paused || playback.rate <= 0.0F) continue;
        reasons |= SceneDemandReason::Video;
        break;
    }

    // A playback that has stopped -- a single-play timeline past its end, one
    // that starts paused, one a script paused -- holds its value:
    // `ScalarAnimationPlayback::Advance` does nothing until something plays it
    // again, and only a script command does (`play`, `setFrame`), which keeps
    // its own reason. Counting every registered playback kept a scene whose
    // only motion was a camera intro awake for good after the intro ended.
    const auto advances = [](const std::shared_ptr<ScalarAnimationPlayback>& playback) {
        return playback != nullptr && playback->playing && playback->rate != 0.0;
    };
    if (std::any_of(m_scalar_animations.begin(), m_scalar_animations.end(),
                    [&advances](const ScalarAnimationBinding& binding) {
                        return advances(binding.playback);
                    }) ||
        advances(m_scene_zoom_animation) ||
        std::any_of(m_material_alpha.begin(), m_material_alpha.end(),
                    [&advances](const MaterialAlphaBinding& binding) {
                        return advances(binding.animation);
                    })) {
        reasons |= SceneDemandReason::Animation;
    }

    for (const auto& group : m_perspective_camera_groups) {
        const PerspectiveCameraShot* selected = nullptr;
        for (const auto& shot : group.shots) {
            if (shot.node->EffectiveVisible()) selected = &shot;
        }
        if (selected && !selected->path.empty()) reasons |= SceneDemandReason::Animation;
    }

    if (m_camera_shake.registered && m_camera_shake.enabled && m_camera_shake.amplitude != 0.0f &&
        m_camera_shake.speed != 0.0f) {
        reasons |= SceneDemandReason::Animation;
    }

    // Scripted values re-evaluate every tick and may read the clock, the
    // pointer or anything else the script engine exposes. Their bodies are not
    // analysed; their presence is the answer.
    if (! m_scripted_values.empty() || ! m_scene_scripts.empty()) {
        reasons |= SceneDemandReason::Script;
    }

    // A binding existing is not a reason to keep ticking; a binding whose value
    // moves by itself is. The parser registers a visibility binding for every
    // layer it produces, so reading the registries' emptiness made every scene
    // with a single image layer report `NodeBinding` forever -- and made this
    // whole analysis unable to answer "still" about anything the parser built.
    //
    // What can move a value is a closed set. `ScriptedDynamicValue` is the only
    // subclass of `DynamicValue` in this runtime, and it re-evaluates every
    // tick. Anything else moves only when something calls `update()` on it: a
    // user property write, a script propagating into it, or an animation
    // sampling into it -- each of which is either an event that requests its
    // own frame or is already represented by `Script` or `Animation` below.
    const auto advances_on_its_own = [](const DynamicValue* value) {
        return dynamic_cast<const ScriptedDynamicValue*>(value) != nullptr;
    };
    const auto any_binding_advances = [&advances_on_its_own](const auto& bindings) {
        return std::any_of(bindings.begin(), bindings.end(), [&](const auto& entry) {
            if constexpr (requires { entry.second.value; }) {
                return advances_on_its_own(entry.second.value);
            } else {
                return advances_on_its_own(entry.value);
            }
        });
    };

    // `m_node_effect_final` holds no value at all: `SyncEffectFinalNode`
    // mirrors a node onto its effect layer's final node, so it moves when the
    // node it mirrors moves and never on its own.
    if (any_binding_advances(m_node_visibility) || any_binding_advances(m_node_translate) ||
        any_binding_advances(m_node_scale) || any_binding_advances(m_node_rotation) ||
        std::any_of(m_material_constants.begin(),
                    m_material_constants.end(),
                    [&advances_on_its_own](const MaterialConstantBinding& binding) {
                        // An animation writes the constant on a timeline of its
                        // own, which is exactly the case the value pointer
                        // cannot describe.
                        return binding.animation != nullptr ||
                               advances_on_its_own(binding.value);
                    })) {
        reasons |= SceneDemandReason::NodeBinding;
    }

    if (any_binding_advances(m_text_values)) reasons |= SceneDemandReason::TextBinding;

    // Text whose layout is still being produced is work in flight, not a still
    // scene. Bounded by the worker finishing: a completed job clears the flag,
    // and the worker wakes the clock when the scene has already gone quiet.
    if (TextLayoutInFlight()) reasons |= SceneDemandReason::TextLayoutPending;

    if (! m_puppet_layers.empty()) reasons |= SceneDemandReason::Puppet;

    // A sound layer that has been released by its owner is gone; one that is
    // still held may be playing. Image stillness is not a licence to stop
    // audio the user asked for, and this analysis cannot yet prove a given
    // sound is independent of the tick, so its presence keeps the clock.
    for (const auto& [name, stream] : m_sound_layers) {
        (void)name;
        if (stream.expired()) continue;
        reasons |= SceneDemandReason::Sound;
        break;
    }

    return reasons;
}

bool SceneRuntimeContext::HasNodeNamed(std::string_view name) const {
    // CLEANROOM RT22
    return false;
}

bool SceneRuntimeContext::HasSoundLayer(std::string_view name) const {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::PlaySoundLayer(std::string_view name) {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::PauseSoundLayer(std::string_view name) {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::StopSoundLayer(std::string_view name) {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::SoundLayerPlaying(std::string_view name) const {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::SetSoundLayerVolume(std::string_view name, float volume) {
    // CLEANROOM RT29
    return false;
}

float SceneRuntimeContext::SoundLayerVolume(std::string_view name) const {
    // CLEANROOM RT29
    return 0;
}

bool SceneRuntimeContext::SetSoundLayerMuted(std::string_view name, bool muted) {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::SoundLayerMuted(std::string_view name) const {
    // CLEANROOM RT29
    return false;
}

int SceneRuntimeContext::NodeSiblingIndex(std::string_view name) const {
    // CLEANROOM RT22
    return 0;
}

std::string SceneRuntimeContext::CreateLayerFromTemplate(std::string_view requested_template_path,
                                                         std::string_view current_layer_name,
                                                         std::string_view script_workshop_id) {
    // CLEANROOM RT27
    return {};
}

namespace
{
// Every node at or below `root`, `root` first.
std::vector<SceneNode*> SubtreeOf(SceneNode& root) {
    std::vector<SceneNode*> nodes { &root };
    for (std::size_t next = 0; next < nodes.size(); ++next) {
        for (const auto& child : nodes[next]->GetChildren()) nodes.push_back(child.get());
    }
    return nodes;
}
} // namespace

bool SceneRuntimeContext::DestroyLayer(std::string_view name, std::vector<std::string>* destroyed) {
    const auto created = m_script_created_layers.find(std::string(name));
    if (created == m_script_created_layers.end()) return false;
    const std::string key = *created;

    const auto registered = m_nodes.find(key);
    SceneNode* node       = registered != m_nodes.end() ? registered->second : nullptr;

    // The layer and every layer registered below it: the nodes under this one
    // are freed with it, so nothing may keep pointing at them.
    std::vector<std::string> doomed { key };
    if (node != nullptr && ! node->GetChildren().empty()) {
        const auto                                 subtree = SubtreeOf(*node);
        const std::unordered_set<const SceneNode*> below(subtree.begin() + 1, subtree.end());
        for (const auto& [layer_name, layer_node] : m_nodes) {
            if (layer_name != key && below.contains(layer_node)) doomed.push_back(layer_name);
        }
    }
    for (const auto& layer_name : doomed) {
        m_script_created_layers.erase(layer_name);
        // The name a script gave the layer goes with it.
        std::erase_if(m_layer_aliases,
                      [&layer_name](const auto& alias) { return alias.second == layer_name; });
        if (m_text_layers.contains(layer_name)) {
            m_retired_text_textures.push_back(TextTextureName(layer_name));
        }
        UnregisterNode(layer_name);
        if (destroyed != nullptr) destroyed->push_back(layer_name);
    }
    if (node == nullptr || node->Parent() == nullptr) return true;

    auto&      siblings = node->Parent()->GetChildren();
    const auto entry    = std::find_if(siblings.begin(), siblings.end(), [node](const auto& child) {
        return child.get() == node;
    });
    if (entry == siblings.end()) return true;
    m_retired_layers.push_back(*entry);
    siblings.erase(entry);
    MarkSceneGraphMutated("destroy-layer");
    return true;
}

void SceneRuntimeContext::ReleaseRetiredLayers() {
    if ((m_retired_layers.empty() && m_retired_text_textures.empty()) || m_scene_graph_mutated) {
        return;
    }
    // Their copies of the template's material bindings write to materials
    // nothing draws any more. A retired layer takes the layers below it along,
    // and each of those is forgotten too.
    std::unordered_set<const SceneMaterial*> materials;
    for (const auto& top : m_retired_layers) {
        for (SceneNode* node : SubtreeOf(*top)) {
            if (node->Mesh() != nullptr && node->Mesh()->MaterialSlotPtr() != nullptr) {
                materials.insert(node->Mesh()->MaterialSlotPtr().get());
            }
            if (m_scene != nullptr && m_scene->shaderValueUpdater != nullptr) {
                m_scene->shaderValueUpdater->ForgetNode(node);
            }
        }
    }
    std::erase_if(m_material_constants, [&materials](const MaterialConstantBinding& binding) {
        const auto material = binding.material.lock();
        return material != nullptr && materials.contains(material.get());
    });
    // The rasters of text layers that no longer exist.
    if (m_scene != nullptr) {
        auto* runtime_images = dynamic_cast<RuntimeImageSource*>(m_scene->imageParser.get());
        for (const auto& texture : m_retired_text_textures) {
            m_scene->textures.erase(texture);
            if (runtime_images != nullptr) runtime_images->RemoveImage(texture);
        }
    }
    m_retired_text_textures.clear();
    m_retired_layers.clear();
}

linalg::Vector3f SceneRuntimeContext::NodeColor(std::string_view name) const {
    const auto node = m_nodes.find(std::string(name));
    if (node == m_nodes.end() || node->second == nullptr || node->second->Mesh() == nullptr ||
        node->second->Mesh()->Material() == nullptr) return linalg::Vector3f::Ones();
    const auto& values = node->second->Mesh()->Material()->customShader.constValues;
    const auto color = values.find("g_Color");
    if (color == values.end() || color->second.size() < 3) return linalg::Vector3f::Ones();
    return linalg::Vector3f(color->second[0], color->second[1], color->second[2]);
}

bool SceneRuntimeContext::SetNodeColor(std::string_view name, const linalg::Vector3f& color) {
    // A colour bound to a property or a script takes what a script writes as
    // its value, as a script's visibility and origin writes do: the next
    // evaluation continues from it, where an `update()` that returns nothing
    // would otherwise put the old value straight back, and every material
    // that takes the layer's colour follows, not only the layer's own.
    if (const auto binding = m_node_color.find(std::string(name));
        binding != m_node_color.end() && binding->second != nullptr) {
        binding->second->update(color);
    }
    const auto node = m_nodes.find(std::string(name));
    if (node == m_nodes.end() || node->second == nullptr || node->second->Mesh() == nullptr ||
        node->second->Mesh()->Material() == nullptr) return false;
    ApplyMaterialColor(*node->second->Mesh()->Material(), color);
    return true;
}

bool SceneRuntimeContext::SortNode(std::string_view name, int index) {
    // CLEANROOM RT22
    return false;
}

bool SceneRuntimeContext::NodeVisible(std::string_view name) const {
    // CLEANROOM RT24
    return false;
}

std::string SceneRuntimeContext::NodeParentName(std::string_view name) const {
    // CLEANROOM RT22
    return {};
}

void SceneRuntimeContext::RegisterNodeAlpha(
    std::string name, std::vector<std::shared_ptr<SceneMaterial>> materials, float value) {
    std::erase(materials, nullptr);
    if (name.empty() || materials.empty()) return;
    m_node_alpha[std::move(name)] = NodeAlphaBinding { .materials = std::move(materials),
                                                       .value     = value };
}

void SceneRuntimeContext::RegisterNodeAlpha(std::string name,
                                            std::shared_ptr<SceneMaterial> material, float value) {
    RegisterNodeAlpha(std::move(name),
                      std::vector<std::shared_ptr<SceneMaterial>> { std::move(material) }, value);
}

std::optional<float> SceneRuntimeContext::NodeAlpha(std::string_view name) const {
    const auto iterator = m_node_alpha.find(std::string(name));
    if (iterator == m_node_alpha.end()) return std::nullopt;
    return iterator->second.value;
}

bool SceneRuntimeContext::SetNodeAlpha(std::string_view name, float value) {
    const auto iterator = m_node_alpha.find(std::string(name));
    if (iterator == m_node_alpha.end()) return false;
    if (iterator->second.value == value) return true;
    iterator->second.value = value;
    for (const auto& material : iterator->second.materials) ApplyMaterialAlpha(*material, value);
    return true;
}

bool SceneRuntimeContext::SetNodeVisible(std::string_view name, bool visible) {
    // CLEANROOM RT24
    return false;
}

bool SceneRuntimeContext::SetNodeTranslate(std::string_view name, const linalg::Vector3f& value) {
    // CLEANROOM RT23
    return false;
}

bool SceneRuntimeContext::SetNodeScale(std::string_view name, const linalg::Vector3f& value) {
    // CLEANROOM RT23
    return false;
}

bool SceneRuntimeContext::SetNodeAlignment(std::string_view name, std::string alignment) {
    // CLEANROOM RT23
    return false;
}

bool SceneRuntimeContext::SetNodeAnchorAlignment(std::string_view name, std::string alignment,
                                                 const linalg::Vector3f& origin) {
    // CLEANROOM RT23
    return false;
}

bool SceneRuntimeContext::SetNodeScreenAnchor(std::string_view name, TextScreenAnchor anchor) {
    // CLEANROOM RT23
    return false;
}

bool SceneRuntimeContext::SetNodeRotation(std::string_view name, const linalg::Vector3f& value) {
    // CLEANROOM RT23
    return false;
}

linalg::Vector3f SceneRuntimeContext::NodeTranslate(std::string_view name) const {
    // CLEANROOM RT23
    return linalg::Vector3f::Zero();
}

linalg::Vector3f SceneRuntimeContext::NodeScale(std::string_view name) const {
    // CLEANROOM RT23
    return linalg::Vector3f::Zero();
}

linalg::Matrix4d SceneRuntimeContext::NodeTransformMatrix(std::string_view name) const {
    // CLEANROOM RT23
    return linalg::Matrix4d::Identity();
}

linalg::Vector3f SceneRuntimeContext::NodeRotation(std::string_view name) const {
    // CLEANROOM RT23
    return linalg::Vector3f::Zero();
}

linalg::Vector2f SceneRuntimeContext::NodeSize(std::string_view name) const {
    // CLEANROOM RT22
    return linalg::Vector2f::Zero();
}

linalg::Vector2f SceneRuntimeContext::NodeBoxCentre(std::string_view name) const {
    // CLEANROOM RT22
    return linalg::Vector2f::Zero();
}

std::string SceneRuntimeContext::NodeText(std::string_view name) const {
    // CLEANROOM RT25
    return {};
}

bool SceneRuntimeContext::NodeTextDirty(std::string_view name) const {
    // CLEANROOM RT25
    return false;
}

std::optional<TextLayerState> SceneRuntimeContext::NodeTextState(std::string_view name) const {
    // CLEANROOM RT25
    return {};
}

std::optional<TextLayerLayout> SceneRuntimeContext::NodeTextLayout(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return std::nullopt;
    return iterator->second.layout();
}

bool SceneRuntimeContext::SetNodeText(std::string_view name, std::string text) {
    // CLEANROOM RT25
    return false;
}

SceneRuntimeContext::OwnTextWrite::OwnTextWrite(SceneRuntimeContext& runtime,
                                                const DynamicValue&  owner) noexcept
    : m_runtime(runtime), m_owner(owner), m_outer(runtime.m_own_text_write) {
    runtime.m_own_text_write = this;
}

SceneRuntimeContext::OwnTextWrite::~OwnTextWrite() {
    m_runtime.m_own_text_write = m_outer;
}

bool SceneRuntimeContext::ClearNodeTextDirty(std::string_view name) {
    // CLEANROOM RT25
    return false;
}

void SceneRuntimeContext::PumpTextLayerCache() {
    // CLEANROOM RT20
}

bool SceneRuntimeContext::SetNodeTextureFrame(std::string_view name, double frame) {
    // CLEANROOM RT30
    return false;
}

double SceneRuntimeContext::NodeTextureFrame(std::string_view name) const {
    return NodeTextureAnimationFrame(name);
}

double SceneRuntimeContext::NodeTextureAnimationFrame(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return 0.0;
    // The frame a script pinned, else the one the renderer last drew.
    return it->second->TextureFrame().value_or(it->second->TextureAnimationFrame().value_or(0.0));
}

namespace
{
// The sprite sheet a layer draws: the first texture of its material that is one.
const SceneTexture* SpriteSheetOf(const Scene* scene, SceneNode& node, std::string* key) {
    if (scene == nullptr || node.Mesh() == nullptr) return nullptr;
    const auto* material = node.Mesh()->Material();
    if (material == nullptr) return nullptr;
    for (const auto& texture : material->textures) {
        const auto found = scene->textures.find(texture);
        if (found == scene->textures.end() || found->second.spriteAnim.numFrames() == 0) continue;
        if (key != nullptr) *key = texture;
        return &found->second;
    }
    return nullptr;
}
} // namespace

std::optional<SceneRuntimeContext::TextureAnimationInfo>
SceneRuntimeContext::NodeTextureAnimation(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return std::nullopt;
    TextureAnimationInfo info;
    const auto* sheet = SpriteSheetOf(m_scene, *it->second, &info.name);
    if (sheet == nullptr) return std::nullopt;
    info.frame_count = sheet->spriteAnim.numFrames();
    for (std::size_t frame = 0; frame < info.frame_count; ++frame) {
        const float frametime = sheet->spriteAnim.FrameAt(frame).frametime;
        if (std::isfinite(frametime) && frametime > 0.0f) info.duration += frametime;
    }
    info.fps = info.duration > 0.0 ? static_cast<double>(info.frame_count) / info.duration : 0.0;
    return info;
}

bool SceneRuntimeContext::PlayNodeTextureAnimation(std::string_view name) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return false;
    // The sheet runs on from the frame it was left on, a pinned one included.
    it->second->ClearTextureFrame();
    it->second->SetTextureAnimationPaused(false);
    return true;
}

bool SceneRuntimeContext::PauseNodeTextureAnimation(std::string_view name) {
    // CLEANROOM RT30
    return false;
}

bool SceneRuntimeContext::StopNodeTextureAnimation(std::string_view name) {
    // CLEANROOM RT30
    return false;
}

bool SceneRuntimeContext::NodeTextureAnimationPlaying(std::string_view name) const {
    // CLEANROOM RT30
    return false;
}

bool SceneRuntimeContext::SetNodeTextureAnimationRate(std::string_view name, double rate) {
    // CLEANROOM RT30
    return false;
}

double SceneRuntimeContext::NodeTextureAnimationRate(std::string_view name) const {
    // CLEANROOM RT30
    return 0;
}

bool SceneRuntimeContext::NodeHasVideoTexture(std::string_view name) const {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::PlayNodeVideoTexture(std::string_view name) {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::NodeVideoTextureIsPlaying(std::string_view name) const {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::PauseNodeVideoTexture(std::string_view name) {
    // CLEANROOM RT29
    return false;
}

bool SceneRuntimeContext::SetNodeVideoTextureCurrentTime(std::string_view name, double seconds) {
    // CLEANROOM RT29
    return false;
}

double SceneRuntimeContext::NodeVideoTextureCurrentTime(std::string_view name) const {
    // CLEANROOM RT29
    return 0;
}

bool SceneRuntimeContext::SetNodeVideoTextureRate(std::string_view name, float rate) {
    // CLEANROOM RT29
    return false;
}

float SceneRuntimeContext::NodeVideoTextureRate(std::string_view name) const {
    // CLEANROOM RT29
    return 0;
}

double SceneRuntimeContext::NodeVideoTextureDuration(std::string_view name) const {
    // CLEANROOM RT29
    return 0;
}

void SceneRuntimeContext::SetVideoTextureDuration(std::string_view texture_key, double seconds) {
    // CLEANROOM RT29
}

video::VideoPlaybackState
SceneRuntimeContext::ResolveVideoPlaybackState(std::string_view texture_key,
                                               double fallback_scene_elapsed_seconds) const {
    // CLEANROOM RT29
    return {};
}

void SceneRuntimeContext::RefreshNodeTransformBindings(const std::string& name) {
    const auto node = m_nodes.find(name);
    const auto alignment = m_node_alignment.find(name);
    const auto size = m_node_size.find(name);
    const auto refresh = [&](auto& bindings) {
        const auto iterator = bindings.find(name);
        if (iterator == bindings.end()) return;
        auto& binding = iterator->second;
        binding.transform_node = node != m_nodes.end() ? node->second : nullptr;
        binding.alignment = alignment != m_node_alignment.end() ? &alignment->second : nullptr;
        binding.size = size != m_node_size.end() ? &size->second : nullptr;
    };
    refresh(m_node_translate);
    refresh(m_node_scale);
    refresh(m_node_rotation);
}

// Letterboxed presentations leave window area the wallpaper never draws. The
// cursor still maps to a scene coordinate there, extrapolated past the drawn
// image, so layers reaching beyond the canvas must not answer to those bars.
bool SceneRuntimeContext::CursorInsidePresentedContent() const {
    const auto& origin = m_cursor_viewport.content_origin;
    const auto& size   = m_cursor_viewport.content_size;
    if (size.x() <= 0.0f || size.y() <= 0.0f) return true;
    const auto& cursor = m_cursor_plane_position;
    return cursor.x() >= origin.x() && cursor.x() <= origin.x() + size.x() &&
           cursor.y() >= origin.y() && cursor.y() <= origin.y() + size.y();
}

void SceneRuntimeContext::SetNodeCursorTarget(std::string_view name, bool hittable, bool solid,
                                              bool disable_propagation) {
    if (name.empty()) return;
    m_node_cursor_targets[std::string(name)] = NodeCursorTarget {
        .hittable = hittable, .solid = solid, .blocks = disable_propagation,
    };
    if (disable_propagation) m_any_cursor_blocker = true;
}

std::optional<SceneRuntimeContext::NodeCursorTarget>
SceneRuntimeContext::NodeCursorTargetOf(std::string_view name) const {
    const auto target = m_node_cursor_targets.find(name);
    if (target == m_node_cursor_targets.end()) return std::nullopt;
    return target->second;
}

// Whether the cursor is over the layer's own rectangle. Wallpaper Engine tests
// nothing but that quad; a layer a script handles the cursor for also answers
// to its coverage mask, so a cut-out layer is only hit where it is drawn.
bool SceneRuntimeContext::CursorHitsLayerGeometry(std::string_view name) const {
    // CLEANROOM RT19
    return false;
}

std::optional<std::size_t> SceneRuntimeContext::NodeRank(std::string_view name) const {
    if (! m_node_rank_valid) {
        m_node_rank.clear();
        for (std::size_t rank = 0; rank < m_node_order.size(); ++rank) {
            m_node_rank.emplace(m_node_order[rank], rank);
        }
        m_node_rank_valid = true;
    }
    const auto found = m_node_rank.find(name);
    if (found == m_node_rank.end()) return std::nullopt;
    return found->second;
}

// Wallpaper Engine walks the layers from the front. A visible layer under the
// cursor that sets `disablepropagation` ends the walk there, so nothing behind
// it is visited, whether or not anything in front of it handles the cursor.
// The frontmost such layer is found once for the frame's cursor events; a layer
// is then out of the walk when it stands behind it.
std::optional<std::size_t> SceneRuntimeContext::FrontmostCursorBlocker() const {
    if (m_cursor_blocker_cached) return m_cursor_blocker_rank;
    m_cursor_blocker_cached = true;
    m_cursor_blocker_rank.reset();
    for (std::size_t rank = m_node_order.size(); rank-- > 0;) {
        const std::string& name   = m_node_order[rank];
        const auto         target = m_node_cursor_targets.find(std::string_view(name));
        if (target == m_node_cursor_targets.end() || ! target->second.blocks ||
            ! target->second.hittable || ! target->second.solid) {
            continue;
        }
        const auto node = m_nodes.find(name);
        if (node == m_nodes.end() || node->second == nullptr || ! node->second->EffectiveVisible()) {
            continue;
        }
        if (CursorHitsLayerGeometry(name)) {
            m_cursor_blocker_rank = rank;
            break;
        }
    }
    return m_cursor_blocker_rank;
}

bool SceneRuntimeContext::CursorBlockedByLayerInFront(std::string_view name) const {
    if (! m_any_cursor_blocker) return false;
    const auto blocker = FrontmostCursorBlocker();
    if (! blocker.has_value()) return false;
    const auto own = NodeRank(name);
    return own.has_value() && *own < *blocker;
}

SceneRuntimeContext::CursorVisit SceneRuntimeContext::VisitCursorLayer(std::string_view name) const {
    // A script of the scene itself, rather than of a layer, hears the cursor
    // wherever it is.
    if (name.empty()) return CursorVisit::Inside;
    if (! CursorInsidePresentedContent()) return CursorVisit::Outside;
    // Layers that are not solid, and objects of any kind but image, text and
    // model, are not tested for the cursor at all.
    if (const auto target = m_node_cursor_targets.find(name);
        target != m_node_cursor_targets.end() &&
        (! target->second.hittable || ! target->second.solid)) {
        return CursorVisit::Outside;
    }
    if (CursorBlockedByLayerInFront(name)) return CursorVisit::Skipped;
    return CursorHitsLayerGeometry(name) ? CursorVisit::Inside : CursorVisit::Outside;
}

bool SceneRuntimeContext::CursorHitsLayer(std::string_view name) const {
    return VisitCursorLayer(name) == CursorVisit::Inside;
}

SceneRuntimeContext::CursorVisit
SceneRuntimeContext::VisitScriptLayer(const ScriptedDynamicValue& value) const {
    return VisitCursorLayer(value.LayerName());
}

SceneRuntimeContext::CursorVisit
SceneRuntimeContext::VisitScriptLayer(const SceneScriptProgram& script) const {
    return VisitCursorLayer(script.LayerName());
}

// An authored timeline can name frames its layer's scripts react to. Handlers
// may create, hide or destroy layers, so every crossed marker is collected
// before any of them runs and the script lists are re-checked while dispatching.
void SceneRuntimeContext::DispatchPendingAnimationEvents() {
    struct QueuedEvent {
        std::string layer_name;
        std::string name;
        double      frame { 0.0 };
    };
    std::vector<QueuedEvent> events;
    for (auto& binding : m_scalar_animations) {
        if (binding.playback == nullptr || binding.playback->pending_events.empty()) continue;
        for (auto& event : binding.playback->pending_events) {
            events.push_back(QueuedEvent {
                .layer_name = binding.layer_name,
                .name       = std::move(event.name),
                .frame      = event.frame,
            });
        }
        binding.playback->pending_events.clear();
    }
    if (events.empty()) return;

    for (const auto& event : events) {
        for (std::size_t index = 0; index < m_scripted_values.size(); ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || value->LayerName() != event.layer_name) continue;
            value->DispatchAnimationEvent(*m_host_context, event.name, event.frame);
        }
        for (std::size_t index = 0; index < m_scene_scripts.size(); ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr || script->LayerName() != event.layer_name) continue;
            script->DispatchAnimationEvent(*m_host_context, event.name, event.frame);
        }
        // One shared global listener list, so it runs once per event whether or
        // not a scene script happens to be bound to this layer.
        m_script_engine->RunAnimationEventCallbacks(*m_host_context, event.name, event.frame);
    }
}

void SceneRuntimeContext::DispatchCursorClick(int button) {
    // CLEANROOM RT18
}

void SceneRuntimeContext::DispatchCursorDown(int button) {
    // CLEANROOM RT18
}

void SceneRuntimeContext::DispatchCursorEnter() {
    ForEachEventScript([&](auto* script) { script->DispatchCursorEnter(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorLeave() {
    ForEachEventScript([&](auto* script) { script->DispatchCursorLeave(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorMove() {
    ForEachEventScript([&](auto* script) { script->DispatchCursorMove(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorUp(int button) {
    // CLEANROOM RT18
}

bool SceneRuntimeContext::DispatchCursorFrameEvents(bool cursor_was_in_window) {
    // CLEANROOM RT18
    return false;
}

void SceneRuntimeContext::DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                        const linalg::Vector3f& text_color) {
    ForEachEventScript([&](auto* script) { script->DispatchMediaThumbnailChanged(primary_color, text_color); });
}

void SceneRuntimeContext::SetMediaIntegrationEnabled(bool enabled) {
    // CLEANROOM RT28
}

bool SceneRuntimeContext::MediaIntegrationEnabled() const {
    // CLEANROOM RT28
    return false;
}

void SceneRuntimeContext::DispatchMediaEventJson(std::string_view event_json) {
    // CLEANROOM RT28
}

void SceneRuntimeContext::NoteMediaEventTold(std::string_view event_json) {
    const auto parsed = nlohmann::json::parse(event_json, nullptr, false);
    if (! parsed.is_object()) return;
    const auto type = parsed.find("type");
    if (type == parsed.end() || ! type->is_string()) return;
    const auto& name = type->get_ref<const std::string&>();
    if (name == "mediaPlaybackChanged") m_media_playback_told = true;
    if (name == "mediaPropertiesChanged") m_media_properties_told = true;
}

// A scene starts in the state of a desktop with no player: no track and
// `PLAYBACK_STOPPED`. Media widgets are authored visible and hide themselves on
// that state, so a scene that was never told it would show every one of them,
// covers and mascots included, whenever media integration is off (the app's
// default) or no player runs. The state is the same one the app sends with
// integration on and nothing playing, and it names no one's music, so it does
// not wait for the user's consent: what a player really reports still does.
// Only the first tick says it, and only what no real event said before it.
void SceneRuntimeContext::DispatchIdleMediaState() {
    if (! m_media_idle_pending) return;
    m_media_idle_pending = false;
    constexpr std::string_view kIdleProperties =
        R"({"type":"mediaPropertiesChanged","title":"","artist":"","subTitle":"",)"
        R"("albumTitle":"","albumArtist":"","genres":"","contentType":"music"})";
    constexpr std::string_view kIdlePlayback = R"({"type":"mediaPlaybackChanged","state":0})";
    // In the order a relay with no player sends them.
    if (! m_media_properties_told) {
        ForEachEventScript([&](auto* script) { script->DispatchMediaEventJson(kIdleProperties); });
    }
    if (! m_media_playback_told) {
        ForEachEventScript([&](auto* script) { script->DispatchMediaEventJson(kIdlePlayback); });
    }
}

void SceneRuntimeContext::RequestUserShortcut(std::string_view property_name,
                                              std::string_view property_value) {
    // A wallpaper that asks on every cursor event while nothing drains would
    // otherwise grow this forever. Sixteen is far more than a user can press
    // between two host turns, and dropping the oldest keeps the newest press --
    // the one still being waited on -- rather than the stalest.
    constexpr std::size_t kMaxPendingRequests = 16;
    if (m_user_shortcut_requests.size() >= kMaxPendingRequests) {
        m_user_shortcut_requests.erase(m_user_shortcut_requests.begin());
    }
    m_user_shortcut_requests.emplace_back(std::string(property_name), std::string(property_value));
}

std::vector<std::pair<std::string, std::string>> SceneRuntimeContext::TakeUserShortcutRequests() {
    return std::exchange(m_user_shortcut_requests, {});
}

void SceneRuntimeContext::MarkSceneRequiresAudioResponse() {
    // Shader init and scripts may mark repeatedly; after the first time this
    // is a load, not a read-modify-write every thread contends on.
    if (m_scene_requires_audio_response.load(std::memory_order_acquire)) return;
    if (m_scene_requires_audio_response.exchange(true, std::memory_order_acq_rel)) return;
    std::function<void()> listener;
    {
        std::lock_guard lock(m_audio_requirement_mutex);
        listener = m_audio_requirement_listener;
    }
    if (listener) listener();
}

bool SceneRuntimeContext::SceneRequiresAudioResponse() const {
    return m_scene_requires_audio_response.load(std::memory_order_acquire);
}

void SceneRuntimeContext::SetAudioRequirementListener(std::function<void()> listener) {
    std::lock_guard lock(m_audio_requirement_mutex);
    m_audio_requirement_listener = std::move(listener);
}

void SceneRuntimeContext::SetAudioResponseEnabled(bool enabled) {
    m_audio_response_enabled.store(enabled, std::memory_order_release);
}

bool SceneRuntimeContext::AudioResponseEnabled() const {
    return m_audio_response_enabled.load(std::memory_order_acquire);
}

bool SceneRuntimeContext::AudioResponseActive() const {
    return AudioResponseEnabled() && SceneRequiresAudioResponse();
}

void SceneRuntimeContext::MarkSceneGraphMutated(const char* reason) {
    // CLEANROOM RT31
}

void SceneRuntimeContext::MarkRenderTargetsResized(const char* reason) {
    m_render_targets_resized = true;
    ++m_render_target_resize_reasons[reason];
}

bool SceneRuntimeContext::ConsumeRenderTargetResizeFlag() {
    const bool resized       = m_render_targets_resized;
    m_render_targets_resized = false;
    return resized;
}

bool SceneRuntimeContext::ConsumeSceneGraphMutationFlag() {
    // CLEANROOM RT31
    return false;
}

audio::AudioSpectrumSnapshot SceneRuntimeContext::CurrentAudioSpectrumSnapshot() const {
    // CLEANROOM RT31
    return {};
}

void SceneRuntimeContext::RecordScriptError(std::string message) {
    // CLEANROOM RT14
}

std::size_t SceneRuntimeContext::scriptErrorCount() const {
    // CLEANROOM RT14
    return 0;
}

const std::vector<std::string>& SceneRuntimeContext::scriptErrors() const {
    // CLEANROOM RT14
    static const std::vector<std::string> neutral {};
    return neutral;
}

void SceneRuntimeContext::ClearScriptErrors() {
    // CLEANROOM RT14
}

// ---------------------------------------------------------------------------
// Layers as scripts enumerate and address them.
// ---------------------------------------------------------------------------

namespace
{
// A template a script's `createLayer` copies from is loaded as a hidden layer
// of this name. It is never part of the scene.
bool IsHiddenTemplateName(const std::string& name) { return name.starts_with("__template:"); }
} // namespace

std::size_t SceneRuntimeContext::LayerCount() const {
    return static_cast<std::size_t>(std::count_if(
        m_node_order.begin(), m_node_order.end(),
        [](const std::string& name) { return ! IsHiddenTemplateName(name); }));
}

std::string SceneRuntimeContext::LayerNameAt(std::size_t index) const {
    for (const auto& name : m_node_order) {
        if (IsHiddenTemplateName(name)) continue;
        if (index-- == 0) return name;
    }
    return {};
}

int SceneRuntimeContext::LayerIndex(std::string_view name) const {
    const std::string key = ResolveLayerName(name);
    if (! m_nodes.contains(key) || IsHiddenTemplateName(key)) return -1;
    int index = 0;
    for (const auto& entry : m_node_order) {
        if (IsHiddenTemplateName(entry)) continue;
        if (entry == key) return index;
        ++index;
    }
    return -1;
}

bool SceneRuntimeContext::SortLayer(std::string_view name, int index) {
    const std::string key   = ResolveLayerName(name);
    const auto        found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr || IsHiddenTemplateName(key)) {
        return false;
    }

    bool      changed = false;
    const int current = LayerIndex(key);
    if (current < 0) return false;
    const int target = std::clamp(index, 0, std::max(0, static_cast<int>(LayerCount()) - 1));
    if (target != current) {
        // The layer ends up at `target`: before the one that stood there when it
        // moves toward the front, after it when it moves toward the back.
        const std::string anchor = LayerNameAt(static_cast<std::size_t>(target));
        std::erase(m_node_order, key);
        auto place = std::find(m_node_order.begin(), m_node_order.end(), anchor);
        if (target > current && place != m_node_order.end()) ++place;
        m_node_order.insert(place, key);
        changed = true;
    }

    // Draw order is the order among siblings. The layer goes right after the
    // nearest sibling that now precedes it in the layer order, or, with none,
    // right before the nearest one that follows. Siblings that are not layers
    // have no place in that order and stay where they are.
    SceneNode* node   = found->second;
    SceneNode* parent = node->Parent();
    if (parent == nullptr) return changed;
    const auto mine = static_cast<std::size_t>(
        std::find(m_node_order.begin(), m_node_order.end(), key) - m_node_order.begin());
    const SceneNode* earlier = nullptr;
    const SceneNode* later   = nullptr;
    for (std::size_t position = 0; position < m_node_order.size(); ++position) {
        const auto entry = m_nodes.find(m_node_order[position]);
        if (entry == m_nodes.end() || entry->second == nullptr || entry->second == node ||
            entry->second->Parent() != parent) {
            continue;
        }
        if (position < mine) {
            earlier = entry->second;
        } else if (later == nullptr) {
            later = entry->second;
        }
    }
    auto&      siblings = parent->GetChildren();
    const auto index_without_node = [&](const SceneNode* mate) {
        int at = 0;
        for (const auto& child : siblings) {
            if (child.get() == node) continue;
            if (child.get() == mate) return at;
            ++at;
        }
        return -1;
    };
    int desired = -1;
    if (earlier != nullptr) {
        const int at = index_without_node(earlier);
        if (at >= 0) desired = at + 1;
    } else if (later != nullptr) {
        desired = index_without_node(later);
    }
    if (desired >= 0 && SortNodeInList(siblings, node, desired)) {
        MarkSceneGraphMutated("sort-layer-relative");
        changed               = true;
    }
    return changed;
}

void SceneRuntimeContext::RegisterLayerAuthoredName(std::string runtime_name,
                                                    std::string authored_name) {
    if (runtime_name.empty() || ! m_nodes.contains(runtime_name)) return;
    m_layer_authored_names.insert_or_assign(std::move(runtime_name), std::move(authored_name));
}

std::string SceneRuntimeContext::LayerAuthoredName(std::string_view runtime_name) const {
    const auto found = m_layer_authored_names.find(std::string(runtime_name));
    return found != m_layer_authored_names.end() ? found->second : std::string(runtime_name);
}

void SceneRuntimeContext::SetLayerOrder(const std::vector<std::string>& names) {
    std::vector<std::string>        order;
    std::unordered_set<std::string> placed;
    order.reserve(m_node_order.size());
    for (const auto& name : names) {
        if (m_nodes.contains(name) && placed.insert(name).second) order.push_back(name);
    }
    for (const auto& name : m_node_order) {
        if (placed.insert(name).second) order.push_back(name);
    }
    m_node_order      = std::move(order);
    m_node_rank_valid = false;
}

void SceneRuntimeContext::RegisterLayerId(int32_t id, std::string name) {
    if (id == 0 || name.empty() || ! m_nodes.contains(name)) return;
    m_layer_ids.insert_or_assign(id, std::move(name));
}

std::string SceneRuntimeContext::LayerNameForId(int32_t id) const {
    const auto found = m_layer_ids.find(id);
    return found != m_layer_ids.end() && m_nodes.contains(found->second) ? found->second
                                                                          : std::string {};
}

void SceneRuntimeContext::RequestInitialLayerConfig() { m_initial_layer_config_requested = true; }

bool SceneRuntimeContext::InitialLayerConfigRequested() const {
    return m_initial_layer_config_requested;
}

void SceneRuntimeContext::SetInitialLayerConfigProvider(InitialLayerConfigProvider provider) {
    m_initial_layer_config_provider = std::move(provider);
}

std::string SceneRuntimeContext::InitialLayerConfigJson(std::string_view name) const {
    if (! m_initial_layer_config_provider) return {};
    const std::string key = ResolveLayerName(name);
    for (const auto& [id, layer] : m_layer_ids) {
        if (layer == key) return m_initial_layer_config_provider(id);
    }
    return {};
}

// ---------------------------------------------------------------------------
// Puppet animation layers: `addEndedCallback`.
// ---------------------------------------------------------------------------

void SceneRuntimeContext::DispatchPuppetLayerEvents() {
    if (m_puppet_layers.empty()) return;
    // A puppet nobody listens to is still drained, so its record stays small.
    std::vector<std::pair<std::string, i32>> ended;
    for (auto& [name, layer] : m_puppet_layers) {
        for (const i32 index : layer.takeFinishedLayers()) ended.emplace_back(name, index);
    }
    if (m_scripted_values.empty() && m_scene_scripts.empty()) return;
    // After collecting: a listener may play the layer again or create layers.
    for (const auto& [name, index] : ended) {
        m_script_engine->NotifyAnimationLayerEnded(*m_host_context, name, index);
    }
}

// ---------------------------------------------------------------------------
// Text layers: style a script changes, and layers a script creates.
// ---------------------------------------------------------------------------

namespace
{
// The fewest digits (at least six) that read back as the very same float, so a
// script that reads the size, adds a little and writes it again loses nothing.
std::string FormatPointSize(float value) {
    char buffer[32];
    for (int digits = 6; digits <= 9; ++digits) {
        std::snprintf(buffer, sizeof(buffer), "%.*g", digits, static_cast<double>(value));
        if (std::strtof(buffer, nullptr) == value) break;
    }
    return buffer;
}

// What `horizontalalign` and `verticalalign` may be set to: Wallpaper Engine
// registers them as enumerations, so anything else is not an alignment. (Whether
// its script setter turns a bad word away, or reads it as the scene file's reader
// does -- as the registry's first entry -- is not known.)
bool IsAlignmentWord(bool horizontal, std::string_view value) {
    return horizontal ? value == "left" || value == "center" || value == "right"
                      : value == "top" || value == "center" || value == "bottom";
}
} // namespace

std::optional<std::string> SceneRuntimeContext::NodeTextStyle(std::string_view name,
                                                              std::string_view property) const {
    const auto layer = m_text_layers.find(std::string(name));
    if (layer == m_text_layers.end()) return std::nullopt;
    const auto& state = layer->second.state();
    if (property == "font") return state.font_key;
    if (property == "pointsize") return FormatPointSize(state.point_size);
    if (property == "horizontalalign") {
        return std::string(TextHorizontalAlignWord(ParseTextHorizontalAlign(state.horizontal_align)));
    }
    if (property == "verticalalign") {
        return std::string(TextVerticalAlignWord(ParseTextVerticalAlign(state.vertical_align)));
    }
    return std::nullopt;
}

bool SceneRuntimeContext::SetNodeTextStyle(std::string_view name, std::string_view property,
                                           std::string_view value) {
    // CLEANROOM RT25
    return false;
}

void SceneRuntimeContext::SetTextFontResolver(TextFontResolver resolver) {
    m_text_font_resolver = std::move(resolver);
}

void SceneRuntimeContext::SetTextLayerFactory(TextLayerFactory factory) {
    m_text_layer_factory = std::move(factory);
}

std::string SceneRuntimeContext::CreateTextLayer(std::string_view config_json,
                                                 std::string_view current_layer_name) {
    if (! m_text_layer_factory || m_scene == nullptr || m_scene->sceneGraph == nullptr) return {};
    auto node = m_text_layer_factory(std::string(config_json), m_next_generated_text_id++);
    if (node == nullptr || node->Name().empty()) return {};
    const std::string name = node->Name();

    SceneNode* parent = nullptr;
    if (const auto current = m_nodes.find(std::string(current_layer_name));
        current != m_nodes.end() && current->second != nullptr) {
        parent = current->second->Parent();
    }
    if (parent != nullptr) {
        parent->AppendChild(node);
    } else {
        m_scene->sceneGraph->AppendChild(node);
    }
    m_script_created_layers.insert(name);
    MarkSceneGraphMutated("create-layer");
    return name;
}

// ---------------------------------------------------------------------------
// What `createLayer` and the layer properties change about a layer.
// ---------------------------------------------------------------------------

bool SceneRuntimeContext::NameLayer(std::string_view runtime_name, std::string authored_name) {
    const std::string key(runtime_name);
    if (authored_name.empty() || ! m_nodes.contains(key)) return false;
    RegisterLayerAlias(authored_name, key);
    // A name another layer already has stays that layer's: this one is then
    // still reached by the key it was registered under.
    return ResolveLayerName(authored_name) == key;
}

bool SceneRuntimeContext::SetNodeParent(std::string_view name, std::string_view parent_name) {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->sceneGraph == nullptr) {
        return false;
    }
    SceneNode* node       = found->second;
    SceneNode* new_parent = m_scene->sceneGraph.get();
    if (! parent_name.empty()) {
        const auto parent = m_nodes.find(ResolveLayerName(parent_name));
        if (parent == m_nodes.end() || parent->second == nullptr) return false;
        new_parent = parent->second;
    }
    // A layer cannot hang below itself or below something that hangs below it.
    for (const SceneNode* ancestor = new_parent; ancestor != nullptr; ancestor = ancestor->Parent()) {
        if (ancestor == node) return false;
    }
    SceneNode* old_parent = node->Parent();
    if (old_parent == nullptr) return false;
    if (old_parent == new_parent) return true;

    auto&      siblings = old_parent->GetChildren();
    const auto entry    = std::find_if(siblings.begin(), siblings.end(), [node](const auto& child) {
        return child.get() == node;
    });
    if (entry == siblings.end()) return false;
    auto owned = *entry;
    siblings.erase(entry);
    new_parent->AppendChild(std::move(owned));
    MarkSceneGraphMutated("reparent");
    return true;
}

bool SceneRuntimeContext::SetNodeSize(std::string_view name, const linalg::Vector2f& size) {
    // CLEANROOM RT22
    return false;
}

linalg::Vector2f SceneRuntimeContext::NodeParallaxDepth(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->shaderValueUpdater == nullptr) {
        return linalg::Vector2f::Zero();
    }
    const auto depth = m_scene->shaderValueUpdater->NodeParallaxDepth(found->second);
    return linalg::Vector2f(depth[0], depth[1]);
}

bool SceneRuntimeContext::SetNodeParallaxDepth(std::string_view name,
                                               const linalg::Vector2f& depth) {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->shaderValueUpdater == nullptr || ! depth.allFinite()) {
        return false;
    }
    // A graph built while the layer stood still has it as a pass that never
    // changes; one that starts following the cursor (or stops) needs a new one.
    if (m_scene->shaderValueUpdater->SetNodeParallaxDepth(found->second, depth.x(), depth.y())) {
        MarkSceneGraphMutated("parallax-depth");
    }
    return true;
}

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap) {
    // CLEANROOM RT14
    return {};
}

} // namespace wallpaper
