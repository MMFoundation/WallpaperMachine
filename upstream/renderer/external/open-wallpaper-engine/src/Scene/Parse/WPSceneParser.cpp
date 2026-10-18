// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#include "WPSceneParser.hpp"
#include "LayerParallax.hpp"
#include "WPJson.hpp"
#include "Scene/SceneIndexArray.h"

#include "Utils/String.h"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Core/Visitors.hpp"
#include "Core/StringHelper.hpp"
#include "Core/ArrayHelper.hpp"
#include "SpecTexs.hpp"
#include "Scene/SceneLayerReference.hpp"

#include "WPShaderParser.hpp"
#include "WPTexImageParser.hpp"
#include "WPParticleParser.hpp"
#include "WPSoundParser.hpp"
#include "WPMdlParser.hpp"

#include "Particle/WPParticleRawGener.h"
#include "Particle/ParticleSystem.h"

#include "WPShaderValueUpdater.hpp"
#include "Shader/TextureFormatCombos.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"
#include "Text/SystemFontResolver.hpp"
#include "Text/TextLayer.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPParticleObject.h"
#include "wpscene/WPSoundObject.h"
#include "wpscene/WPLightObject.hpp"
#include "wpscene/WPMiscObject.hpp"
#include "wpscene/WPScene.h"

#include "Fs/VFS.h"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"
#include "Scene/SceneBackendSelection.hpp"
#include "Shader/RustShaderBridge.hpp"

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <random>
#include <cmath>
#include <optional>
#include <regex>
#include <span>
#include <limits>
#include <variant>
#include "Utils/Linalg.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;

// CLEANROOM: the stubs below leave their parameters and helpers unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-function"

/// One entry of the object list that became a member of the layer tree.
struct ParsedLayer {
    std::size_t                entry { 0 };      // position in the `objects` array
    int32_t                    id { 0 };
    int32_t                    parent_id { -1 }; // as authored; -1 for none
    std::string                key;              // the name scripts and bindings use
    std::string                authored_name;
    std::string                attachment;
    std::shared_ptr<SceneNode> node;
    // A node that only carries a transform: a group, a shape, or the stand-in of
    // an entry whose typed object is not (or not yet) built.
    bool                       plain { true };
};

namespace
{

/// One material's shader, captured with the Metal program its settled compile
/// produced and everything a later plane variant of it would be compiled from.
///
/// The compile that settles a material's combos, default textures and texture
/// slots is the Metal compile: the stages of its last iteration are the program.
/// Turning them into the scene's program is deferred to the end of the parse,
/// because whether the scene is a candidate for this backend at all (a particle
/// emitter, a puppet, a video texture it cannot play) is only known once the
/// whole scene exists, and the inputs of the optional plane variant are
/// snapshots of what the settled compile was handed, which do not outlive
/// `LoadMaterial`.
struct PendingMetalTranslation {
    std::shared_ptr<SceneShader>      shader;
    std::string                       shader_name;
    std::string                       scene_id;
    /// What the settled compile was handed, before it merged its results in.
    std::vector<WPShaderUnit>         units;
    WPShaderInfo                      shader_info;
    std::vector<WPShaderTexInfo>      texinfos;
    /// The material's texture keys, in slot order, so the flush can ask the
    /// scene which slot is a video without re-deriving the list.
    std::vector<std::string>          texture_keys;
    /// What the settled compile produced.
    std::vector<shader::RustShaderMetalStage> stages;
    std::string                       reflection_json;
    /// Every include that compile read, for translating the same program again.
    WPShaderIncludeMap                includes;
};


/// Parsing is single-threaded per scene but several scenes may parse at once,
/// so the queue is per-thread rather than global.
thread_local std::vector<PendingMetalTranslation> g_pending_metal_translations;
thread_local const LayerObjectIndex* g_parse_layer_index { nullptr };
/// The shaders of this parse that could not be compiled, one sentence each, in
/// the order the parse met them. The layer or effect that wanted one is left out
/// of the scene (its material did not load), so the parse ends by handing these
/// to the scene, whose capability gate refuses it with the first as the reason:
/// a scene is never drawn with a part of it missing.
thread_local std::vector<std::string> g_shader_failures;

/// Records that `shader_name` could not be compiled, with the compiler's own
/// explanation when it has one (its first line, so a long diagnostic does not
/// become the panel's reason).
void NoteShaderFailure(std::string_view shader_name, std::string detail) {
    constexpr std::size_t kMaxDetail = 240;
    if (const auto line = detail.find('\n'); line != std::string::npos) detail.resize(line);
    if (detail.size() > kMaxDetail) detail.resize(kMaxDetail);
    std::string reason = "the shader '" + std::string(shader_name) + "' could not be translated to Metal";
    if (! detail.empty() && detail != "no shader error") reason += " (" + detail + ")";
    g_shader_failures.push_back(std::move(reason));
}

/// What the scene reports when the parse met shaders that did not compile.
std::string ShaderFailureReason() {
    if (g_shader_failures.empty()) return {};
    std::string reason = g_shader_failures.front();
    if (g_shader_failures.size() > 1) {
        reason += "; " + std::to_string(g_shader_failures.size() - 1) + " more shader" +
                  (g_shader_failures.size() == 2 ? "" : "s") + " failed too";
    }
    return reason;
}

/// Compiles one iteration of a material's shader to Metal, merging what the
/// compile learned into `units` and `shader_info`, and queues the program it
/// made (or, for a later iteration of the same shader, replaces the earlier
/// one). The inputs are copied before the compile consumes them, so the record
/// holds exactly what the compile saw rather than the state it left behind; the
/// last iteration to run is the one that settled. A failed compile leaves
/// nothing queued for the shader.
bool CompileAndQueueMetalProgram(const std::shared_ptr<SceneShader>& shader,
                                 std::string_view scene_id, std::string_view shader_name,
                                 std::span<WPShaderUnit> units, fs::VFS& vfs,
                                 WPShaderInfo* shader_info,
                                 std::span<const WPShaderTexInfo> texinfos,
                                 std::vector<std::string> texture_keys,
                                 std::string* reflection_json) {
    PendingMetalTranslation pending;
    pending.shader       = shader;
    pending.shader_name  = std::string(shader_name);
    pending.scene_id     = std::string(scene_id);
    pending.units.assign(units.begin(), units.end());
    pending.shader_info  = *shader_info;
    pending.texinfos.assign(texinfos.begin(), texinfos.end());
    pending.texture_keys = std::move(texture_keys);

    const bool replaces = ! g_pending_metal_translations.empty() &&
                          g_pending_metal_translations.back().shader == shader;
    if (! WPShaderParser::CompileToMslRust(scene_id,
                                           shader_name,
                                           units,
                                           pending.stages,
                                           vfs,
                                           shader_info,
                                           texinfos,
                                           &pending.reflection_json,
                                           std::nullopt,
                                           &pending.includes)) {
        if (replaces) g_pending_metal_translations.pop_back();
        NoteShaderFailure(shader_name, shader::LastRustShaderError());
        return false;
    }
    if (reflection_json != nullptr) *reflection_json = pending.reflection_json;
    if (replaces) {
        g_pending_metal_translations.back() = std::move(pending);
    } else {
        g_pending_metal_translations.push_back(std::move(pending));
    }
    return true;
}

/// The one material texture slot a direct NV12 variant could be compiled for,
/// or nothing.
///
/// Exactly one candidate, deliberately: two video slots in one material would
/// need a variant per combination, and this round compiles one extra program
/// per material, never a matrix of them. A slot the native video path itself
/// refuses -- a sprite sheet, a texture with no media -- is not a candidate
/// either, because that material is not going to reach this backend at all.
std::optional<uint32_t> ResolveVideoPlaneCandidate(const Scene& scene,
                                                   const std::vector<std::string>& texture_keys) {
    std::optional<uint32_t> candidate;
    for (usize slot = 0; slot < texture_keys.size(); ++slot) {
        const auto& key = texture_keys[slot];
        if (key.empty()) continue;
        const auto found = scene.textures.find(key);
        if (found == scene.textures.end() || ! found->second.isVideo) continue;
        if (! metal::MetalVideoTextureRejection(scene, key).empty()) return std::nullopt;
        if (candidate.has_value()) return std::nullopt;
        candidate = static_cast<uint32_t>(slot);
    }
    return candidate;
}

SceneMetalSlotKind ToSceneMetalSlotKind(shader::RustShaderMetalSlotKind kind) {
    switch (kind) {
    case shader::RustShaderMetalSlotKind::Texture: return SceneMetalSlotKind::Texture;
    case shader::RustShaderMetalSlotKind::Sampler: return SceneMetalSlotKind::Sampler;
    case shader::RustShaderMetalSlotKind::Buffer: break;
    }
    return SceneMetalSlotKind::Buffer;
}

/// Records what the direct plane-sampling variant of one already-translated
/// program would be compiled from, if this material has exactly one candidate
/// video slot.
///
/// Nothing is compiled here. The combos, the preprocessed units, the texture
/// info and the includes the ordinary translation read are all still available
/// at this point and nowhere else, so they are copied into a snapshot that owns
/// itself; whether the variant is ever wanted is a question for the renderer
/// and the user's setting, long after this parse has finished. A wallpaper must
/// not pay for an optional program before it has drawn a single frame.
void CaptureVideoPlaneInputs(Scene& scene, PendingMetalTranslation& request,
                             SceneMetalProgram& program, WPShaderIncludeMap includes) {
    const auto slot = ResolveVideoPlaneCandidate(scene, request.texture_keys);
    if (! slot.has_value()) return;

    auto inputs              = std::make_shared<SceneMetalVariantInputs>();
    inputs->scene_id         = request.scene_id;
    inputs->shader_name      = request.shader_name;
    inputs->units            = request.units;
    inputs->shader_info      = request.shader_info;
    inputs->texinfos         = request.texinfos;
    inputs->includes         = std::move(includes);
    inputs->nv12_plane_slot  = *slot;
    program.video_plane_inputs = std::move(inputs);
}

/// Attaches the queued programs to their shaders, if the scene is still a
/// candidate for this backend.
///
/// A program that cannot be used (no stages, no reflection) is recorded with its
/// error, which the capability gate turns into a user-readable reason for
/// holding the scene.
void FlushPendingMetalTranslations(Scene& scene) {
    auto pending = std::move(g_pending_metal_translations);
    g_pending_metal_translations.clear();
    g_parse_layer_index = nullptr;
    if (pending.empty()) return;
    if (! metal::SceneMetalStructuralRejection(scene).empty()) return;

    for (auto& request : pending) {
        if (request.shader == nullptr) continue;
        auto program = std::make_shared<SceneMetalProgram>();

        program->reflection_json = std::move(request.reflection_json);
        for (const auto& stage : request.stages) {
            SceneMetalStage out;
            out.kind             = stage.kind == ShaderType::FRAGMENT
                                       ? SceneMetalStageKind::Fragment
                                       : SceneMetalStageKind::Vertex;
            out.source           = stage.source;
            out.entry_point      = stage.entry_point;
            out.language_version = stage.language_version;
            out.bindings.reserve(stage.bindings.size());
            for (const auto& binding : stage.bindings) {
                out.bindings.push_back(SceneMetalBinding {
                    .name      = binding.name,
                    .set       = binding.set,
                    .binding   = binding.binding,
                    .slot_kind = ToSceneMetalSlotKind(binding.slot_kind),
                    .slot      = binding.slot,
                });
            }
            program->stages.push_back(std::move(out));
        }
        if (program->stages.empty() || program->reflection_json.empty()) {
            program->error = "metal translation produced no usable shader";
            LOG_ERROR("metal translation of '%s' failed: %s",
                      request.shader_name.c_str(),
                      program->error.c_str());
        } else {
            CaptureVideoPlaneInputs(scene, request, *program, std::move(request.includes));
            if (program->hasVideoPlaneCandidate()) {
                scene.metal_variant_candidates.push_back(program);
            }
        }
        // Stored either way: a recorded failure is what distinguishes "tried
        // and could not" from "never tried", and only the first is a fault in
        // the shader.
        request.shader->metal_program = std::move(program);
    }
}

} // namespace

struct ParseContext {
    std::shared_ptr<Scene>                                  scene;
    WPShaderValueUpdater*                                   shader_updater;
    i32                                                     ortho_w;
    i32                                                     ortho_h;
    fs::VFS*                                                vfs;
    std::unordered_map<int32_t, std::shared_ptr<SceneNode>> layer_nodes;
    std::unordered_map<std::string, uint32_t>               layer_name_counts;
    ShaderValueMap             global_base_uniforms;
    std::shared_ptr<SceneNode> effect_camera_node;
    std::shared_ptr<SceneNode> global_camera_node;
    std::shared_ptr<SceneNode> global_perspective_camera_node;
    std::unordered_map<int32_t, WPPuppetLayer>              layer_puppet_animations;
    /// Particle systems that have a prewarm to run, a child's before its parent's.
    /// It waits for the finished scene graph: the matrix a system is born by is
    /// its layer's world matrix, parent groups included, and a layer joins its
    /// group only once every object exists.
    std::vector<ParticleSubSystem*>                         pending_prewarms;
    std::unordered_set<int32_t>                             referenced_layer_ids;
    /// The layers of the tree, in the order the scene file declares them.
    std::vector<ParsedLayer>                                layers;
    /// Scene-event scripts waiting for the scene to be complete: source, owning layer key.
    std::vector<std::pair<std::string, std::string>>        scene_scripts;
    /// How many text layers carry each authored name.
    std::unordered_map<std::string, uint32_t>               text_name_counts;
    /// The card each text layer shows, for a composite registered only once
    /// a later consumer turns out to sample the layer.
    std::unordered_map<int32_t, TextLayerRenderFrame>       text_cards;

    bool                       uses_models { false };
    // `orthogonalprojection` present and not null. The scene is then projected
    // by that canvas, which is the space every 2D layer's geometry, origin and
    // alignment is authored in.
    bool                       is_ortho { true };
    // The canvas has a pixel size: particle files then default omitted keys in
    // pixel units.
    bool                       pixel_canvas { true };
};

namespace
{
/// The whole content of an asset file, empty when it is absent.
std::vector<uint8_t> ReadAssetBytes(fs::VFS& vfs, const std::string& path) {
    const std::string text = fs::GetFileContent(vfs, path);
    return std::vector<uint8_t>(text.begin(), text.end());
}

void MarkSceneRequiresAudioResponse(Scene* scene) {
    if (scene != nullptr && scene->runtime != nullptr) scene->runtime->MarkSceneRequiresAudioResponse();
}

/// A setting that a project property or a running script decides.
bool HasDynamicSetting(const nlohmann::json& value) { return wpscene::SettingIsDriven(value); }

/// A visibility only a reload changes: the authored value, or one of the
/// wallpaper's own properties, which reparse the scene when they change.
/// Anything handed to a script can change from one frame to the next.
bool VisibilitySettledBy(const nlohmann::json& setting) {
    return ! setting.is_object() || ! setting.contains("script");
}

/// Undoes what an object registered under its runtime name (the name, its node,
/// the scene scripts queued for it) unless the object is committed: an object
/// that fails to build leaves nothing behind, and a node of the same name that
/// was there before is put back.
class NodeRegistrationGuard {
public:
    NodeRegistrationGuard(SceneRuntimeContext* runtime, std::string name, SceneNode* node)
        : m_runtime(runtime), m_name(std::move(name)), m_node(node) {
        if (m_runtime != nullptr) m_memo = m_runtime->CaptureNodeRegistration(m_name);
    }
    NodeRegistrationGuard(const NodeRegistrationGuard&)            = delete;
    NodeRegistrationGuard& operator=(const NodeRegistrationGuard&) = delete;
    ~NodeRegistrationGuard() {
        if (! m_committed && m_runtime != nullptr) {
            m_runtime->RollbackNodeRegistration(m_name, m_node, m_memo);
        }
    }
    void Commit() { m_committed = true; }

private:
    SceneRuntimeContext*                                       m_runtime;
    std::string                                                m_name;
    SceneNode*                                                 m_node;
    std::shared_ptr<SceneRuntimeContext::LayerRegistrationMemo> m_memo;
    bool                                                       m_committed { false };
};

// CLEANROOM LS6: puppet attachments (registering a layer that hangs from a parent puppet's attachment point) are not built yet.

// Runs the prewarms the particle layers queued, now that every layer sits under
// its parent.
void PrewarmParticleSystems(ParseContext& context) {
    for (auto* system : context.pending_prewarms) system->Prewarm();
    context.pending_prewarms.clear();
}

/// The extent of a view of `canvas` units at `zoom`: the canvas divided by the
/// zoom, truncated to whole units, at least 1. A zoom that is not finite and
/// positive counts as 1.
int32_t ZoomedExtent(int32_t canvas, double zoom) {
    const double applied = std::isfinite(zoom) && zoom > 0.0 ? zoom : 1.0;
    const double units   = std::trunc(static_cast<double>(canvas) / applied);
    return static_cast<int32_t>(std::clamp(units, 1.0, 2147483647.0));
}

/// The extent of the offscreen targets an image layer draws into: its size
/// rounded to whole numbers, where an axis of 2 or less (or not finite) takes the
/// canvas's extent on that axis instead, at least 4.
std::array<int32_t, 2> ResolveImageRenderExtent(const wpscene::WPImageObject& object,
                                                const ParseContext&           context) {
    const std::array<int32_t, 2> canvas { context.ortho_w, context.ortho_h };
    std::array<int32_t, 2>       extent {};
    for (std::size_t axis = 0; axis < 2; ++axis) {
        const double size = object.size[axis];
        if (std::isfinite(size) && std::round(size) > 2.0) {
            extent[axis] = static_cast<int32_t>(std::min(std::round(size), 2147483647.0));
        } else {
            extent[axis] = std::max(4, canvas[axis]);
        }
    }
    return extent;
}

/// One axis of an effect buffer: the base divided by the buffer's integer scale
/// (0 reads as 1), rounded to the nearest whole number, at least 4.
int32_t ResolveRenderTargetDimension(float base_dimension, uint32_t scale) {
    const double divisor = scale == 0 ? 1.0 : static_cast<double>(scale);
    const double value   = std::isfinite(base_dimension) ? base_dimension / divisor : 0.0;
    return static_cast<int32_t>(std::clamp(std::round(value), 4.0, 2147483647.0));
}

// The format Wallpaper Engine gives an effect buffer. Float buffers hold signed
// values, such as a fluid simulation's velocity and pressure, which an 8-bit
// target would clamp at zero; the back-buffer formats follow the scene. A
// single- or two-channel float buffer takes the four-channel float target, the
// narrowest float format the renderer allocates.
TextureFormat EffectFboFormat(std::string_view format, bool hdr) {
    if (format == "r16f" || format == "rg1616f" || format == "rgba16161616f" ||
        format == "r32f" || format == "rg3232f" || format == "rgba32323232f") {
        return TextureFormat::RGBA16F;
    }
    if (format == "rgba8888" || format == "rgb888" || format == "rg88" || format == "r8") {
        return TextureFormat::RGBA8;
    }
    return hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
}

// An effect buffer with a `width`, `height` or `fit` of its own has a fixed
// size, as in Wallpaper Engine: its own size where given (else the layer's),
// shrunk so its longer side is at most `fit` with its aspect kept, then divided
// by `scale`. Wallpaper Engine ignores sizes above 4096. Without any of them
// the buffer follows the layer, scaled.
std::optional<std::array<int32_t, 2>> FixedEffectFboExtent(const wpscene::WPEffectFbo& fbo,
                                                           float layer_width,
                                                           float layer_height) {
    constexpr uint32_t kLargest = 4096;
    const bool own_width  = fbo.width > 0 && fbo.width <= kLargest;
    const bool own_height = fbo.height > 0 && fbo.height <= kLargest;
    const bool fits       = fbo.fit > 0 && fbo.fit <= kLargest;
    if (! own_width && ! own_height && ! fits) return std::nullopt;
    float width  = own_width ? static_cast<float>(fbo.width) : layer_width;
    float height = own_height ? static_cast<float>(fbo.height) : layer_height;
    if (fits && width > 0.0f && height > 0.0f) {
        const float fit = static_cast<float>(fbo.fit);
        if (width < height) {
            const float fitted = std::min(fit, height);
            width              = width / height * fitted;
            height             = fitted;
        } else {
            const float fitted = std::min(fit, width);
            height             = height / width * fitted;
            width              = fitted;
        }
    }
    return std::array { ResolveRenderTargetDimension(width, fbo.scale),
                        ResolveRenderTargetDimension(height, fbo.scale) };
}

// Whether, running on from just after pass `from` and round to the start of
// the next frame, the effect reads `fbo` before it draws into it.
bool EffectReadsBeforeWriting(const wpscene::WPImageEffect& effect, std::string_view fbo,
                              std::size_t from) {
    for (const auto& command : effect.commands) {
        if (command.source == fbo) return true;
    }
    const auto count = effect.passes.size();
    for (std::size_t step = 0; step < count; ++step) {
        const auto& pass = effect.passes[(from + step) % count];
        for (const auto& bind : pass.bind) {
            if (bind.name == fbo) return true;
        }
        if (pass.target == fbo) return false;
    }
    return false;
}

// An effect's `copy` and `swap` commands as copies between its buffers. A
// `swap` exchanges two buffers after a pass: the first then holds what was
// drawn into the second, and the second what the first held. When the effect
// draws into the second before it reads it again, that half of the exchange is
// never seen and one copy is the whole swap; otherwise it goes through a
// temporary buffer of the second's size.
void LowerEffectCommands(const wpscene::WPImageEffect& effect,
                         const std::unordered_map<std::string, std::string>& fbo_map, Scene& scene,
                         std::vector<SceneImageEffect::Command>& commands) {
    for (const auto& command : effect.commands) {
        const bool swap = command.command == "swap";
        if (command.command != "copy" && ! swap) {
            LOG_ERROR("Unknown effect command: %s", command.command.c_str());
            continue;
        }
        const auto target = fbo_map.find(command.target);
        const auto source = fbo_map.find(command.source);
        if (target == fbo_map.end() || source == fbo_map.end()) {
            LOG_ERROR("Unknown effect command dst or src: %s %s",
                      command.target.c_str(),
                      command.source.c_str());
            continue;
        }
        const auto copy = [&commands, &command](const std::string& dst, const std::string& src) {
            commands.push_back({ .cmd      = SceneImageEffect::CmdType::Copy,
                                 .dst      = dst,
                                 .src      = src,
                                 .afterpos = command.afterpos });
        };
        if (! swap) {
            copy(target->second, source->second);
            continue;
        }
        const auto after = static_cast<std::size_t>(std::max(0, command.afterpos));
        if (! EffectReadsBeforeWriting(effect, command.target, after)) {
            copy(source->second, target->second);
            continue;
        }
        const auto temporary = target->second + "_swap";
        scene.renderTargets[temporary] = scene.renderTargets.at(target->second);
        copy(temporary, source->second);
        copy(source->second, target->second);
        copy(target->second, temporary);
    }
}

// CLEANROOM LS8: the file-local helpers of this group were removed; the rewrite designs its own.

void AddParticleIndexArray(SceneMesh& mesh, uint32_t count) {
    const auto layout = PlanParticleIndexLayout(count);
    mesh.AddIndexArray(SceneIndexArray(count, layout.width));
}

// CLEANROOM LS9: the file-local helpers of this group were removed; the rewrite designs its own.

/// What the generators of one particle file read besides their own JSON.
ParticleParseContext MakeParticleParseContext(
    ParticleSubSystem& pSys, const wpscene::Particle& wp,
    const std::shared_ptr<const wpscene::ParticleInstanceoverride>& over, Scene* scene,
    bool pixel_canvas) {
    ParticleParseContext ctx;
    ctx.over  = over;
    ctx.spawn = pSys.SpawnContext();
    ctx.color = WPParticleParser::analyzeColorSources(wp.initializers, wp.operators);
    ctx.ortho = pixel_canvas;
    ctx.speed_override = wp.AppliesSpeedOverride();
    ctx.size_override  = wp.AppliesSizeOverride();
    if (scene != nullptr) {
        ctx.spectrum = [scene]() {
            return scene->runtime != nullptr ? scene->runtime->CurrentAudioSpectrumSnapshot()
                                             : audio::AudioSpectrumSnapshot {};
        };
        ctx.requires_audio = [scene]() { MarkSceneRequiresAudioResponse(scene); };
    }
    return ctx;
}
/// The blend mode a material's `blending` word names. `disabled` writes the
/// fragment as it is, like `normal`; a word outside the list reads as `normal`.
BlendMode ParseSceneBlendMode(std::string_view word) {
    if (word == "translucent") return BlendMode::Translucent;
    if (word == "additive") return BlendMode::Additive;
    if (word == "alphatocoverage") return BlendMode::AlphaToCoverage;
    if (word != "normal" && word != "disabled") {
        LOG_ERROR("unknown blending '%s', reading it as normal", std::string(word).c_str());
    }
    return BlendMode::Normal;
}

// Whether Wallpaper Engine draws an image layer among the ones sorted back to
// front, after the rest, in a scene that turns `transparentsorting` on. Its
// image object marks the layer for the sort unless the blending its material
// authors is the first entry of the blending enum, `normal`, or the fourth,
// `alphatocoverage`: the layers that blend, `translucent` and `additive`, sort;
// the others stay in scene order in the set drawn first. `Normal` also covers
// `disabled` and an unknown value, which it reads as the enum's first entry.
bool ImageLayerIsSorted(BlendMode authored) {
    return authored == BlendMode::Translucent || authored == BlendMode::Additive;
}

// Wallpaper Engine reads a pass's `depthtest`, `depthwrite` and `cullmode` as
// two-value enums ("disabled"/"enabled", "normal"/"nocull") and gives a value
// outside the list the list's first entry: no depth test, no depth write, back
// faces culled. There is no depth compare to choose; a depth-tested draw always
// compares the same way.
void ApplyMaterialDepth(SceneMaterial& material, const wpscene::WPMaterial& wpmat) {
    material.depth_test  = wpmat.depthtest == "enabled";
    material.depth_write = wpmat.depthwrite == "enabled";
}

CullMode ParseSceneCullMode(std::string_view value) {
    return value == "nocull" ? CullMode::None : CullMode::Back;
}

// `general.lightconfig` names how many lights of each kind lit shaders are
// compiled for. Wallpaper Engine packs each count into four bits; its shadow
// and cookie subsets are not drawn here, so those lights count as plain ones.
SceneLightConfig ParseSceneLightConfig(const nlohmann::json& config) {
    SceneLightConfig lights;
    if (! config.is_object()) return lights;
    const auto count = [&config](const char* key) -> uint32_t {
        const auto found = config.find(key);
        if (found == config.end() || ! found->is_number()) return 0;
        return static_cast<uint32_t>(std::clamp(found->get<double>(), 0.0, 15.0));
    };
    lights.point       = count("point");
    lights.spot        = count("spot");
    lights.tube        = count("tube");
    lights.directional = count("directional");
    return lights;
}

// CLEANROOM LS11: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS12: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS13: the file-local helpers of this group were removed; the rewrite designs its own.

bool AlignmentHasAnchorOffset(std::string_view align) {
    for (const auto edge : { "top", "bottom", "left", "right" }) {
        if (align.find(edge) != std::string_view::npos) return true;
    }
    return false;
}

// CLEANROOM LS14: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS15: the file-local helpers of this group were removed; the rewrite designs its own.

/// A layer another layer samples draws into a composite of its own, `extent`
/// texels, through a camera that frames the layer's card in its own texture
/// space: the card fills the target, and where the layer sits in the scene --
/// its transform, the scene camera, parallax -- does not reach the image.
/// `camera_node` puts that camera on the card's centre.
SceneCamera& RegisterLayerComposite(ParseContext& context, int32_t id, SceneNode& node,
                                    std::array<int32_t, 2> extent, bool clamp_uvs,
                                    std::shared_ptr<SceneNode> camera_node,
                                    TextureFilter filter = TextureFilter::LINEAR) {
    node.SetMustProduce(true);
    const auto key = LayerCompositeTargetKey(id);
    if (! context.scene->HasRenderTarget(key)) {
        // A consumer may tile a layer texture across a model (UVs far outside
        // 0..1). Clamping that smears the edge texels into solid bands; the
        // layer's own `clampuvs` decides, like a packaged texture's flag. A layer
        // that point-samples (`nointerpolation`) is read the same way.
        const auto wrap = clamp_uvs ? TextureWrap::CLAMP_TO_EDGE : TextureWrap::REPEAT;
        context.scene->renderTargets[key] = SceneRenderTarget {
            .width = extent[0], .height = extent[1], .allowReuse = true,
            .sample = { wrap, wrap, filter, filter },
            .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
    }
    auto camera = std::make_shared<SceneCamera>(extent[0], extent[1], -1.0f, 1.0f);
    camera->SetLayerLocal(true);
    camera->AttatchNode(std::move(camera_node));
    auto& registered = context.scene->cameras[LayerCompositeCameraKey(id)];
    registered = std::move(camera);
    return *registered;
}

/// An effect of layer `layer_id` naming the layer's own `_a` or `_b` composite
/// reads the chain's current buffer, `chain_input`, as `previous` does: the
/// layer's composite is what this chain is about to produce. A clock's outline
/// bound that way otherwise sampled an empty link every frame and drew nothing.
void BindOwnEffectChainInput(wpscene::WPMaterial& material, int32_t layer_id,
                             const std::string& chain_input) {
    for (auto& texture : material.textures) {
        if (IsOwnEffectChainInput(texture, layer_id)) texture = chain_input;
    }
}

/// The colour blend mode Wallpaper Engine draws additively onto the scene
/// instead of blending in the passthrough shader.
constexpr int32_t kAdditiveColorBlendMode = 31;

/// The pass that mixes a layer with the screen behind it for a colour blend
/// mode: Wallpaper Engine's passthrough material, `effectpassthrough`, with the
/// mode as its `BLENDMODE`. It is appended as the layer's last effect, writes
/// without blending, and a layer's own colour and alpha are already in what it
/// blends (the caller binds a white `g_Color4`). Image and text layers share it.
std::optional<wpscene::WPImageEffect> MakeColorBlendEffect(fs::VFS& vfs, int32_t color_blend_mode) {
    wpscene::WPImageEffect effect;
    wpscene::WPMaterial    material;
    nlohmann::json         json;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/materials/util/effectpassthrough.json"), json))
        return std::nullopt;
    material.FromJson(json);
    material.combos["BONECOUNT"] = 1;
    material.combos["BLENDMODE"] = color_blend_mode;
    material.blending            = "disabled";
    effect.materials.push_back(material);
    return effect;
}

/// The pass a layer's effect chain ends in so that scene fog falls on the layer
/// where it sits: Wallpaper Engine's passthrough material for a device that draws
/// fog, `effectpassthrough_4` (the generic image shader, which takes the scene's
/// fog like any pass). The chain before it runs in the layer's own card, from an
/// ortho camera and with no transform, where a point's distance from the eye is
/// its place in the card; this last pass is drawn at the layer's model matrix, so
/// the fog it measures is the layer's. It copies what the chain made, with a white
/// `g_Color4`: the layer's own colour and alpha are already in it. Without the
/// material (assets from before it) there is no pass, and the layer keeps its fog
/// where it was.
std::optional<wpscene::WPImageEffect> MakeFogCompositeEffect(fs::VFS& vfs) {
    wpscene::WPImageEffect effect;
    wpscene::WPMaterial    material;
    nlohmann::json         json;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/materials/util/effectpassthrough_4.json"), json))
        return std::nullopt;
    material.FromJson(json);
    material.combos["BONECOUNT"] = 1;
    effect.materials.push_back(material);
    return effect;
}

// Whether an effect is part of the chain a layer is built with: one that is
// visible, or one a script may switch on later. Wallpaper Engine keeps every
// effect of a layer and runs the ones its effect object says are visible.
bool EffectIsBuilt(const wpscene::WPImageEffect& effect) {
    return effect.visible || effect.scripted_visible;
}

/// The padding a text object's file gives, on each axis: capped at 512 pixels from above and not
/// floored, since Wallpaper Engine lets a negative padding take the card in around the text.
linalg::Vector2f AuthoredTextCardPadding(const wpscene::WPTextObject& obj) {
    constexpr float kMaxCardPadding = 512.0f;
    const auto lane = [=](float value) {
        return std::isfinite(value) ? std::min(value, kMaxCardPadding) : 0.0f;
    };
    return { lane(obj.padding[0]), lane(obj.padding[1]) };
}

/// Whether an effect is visible as the scene loads: a fixed one by its value (a property's is
/// resolved into it already), a scripted one by the value its script starts from.
bool EffectStartsVisible(const wpscene::WPImageEffect& effect) {
    return effect.scripted_visible ? InitialBoolSetting(effect.visible_setting) : effect.visible;
}

/// Whether an effect is one of the passes Wallpaper Engine counts for a text layer as the scene
/// loads: one that is visible, and has a pass to draw. The effects the chain is built with are
/// these (`EffectIsBuilt` and a material), and the runtime counts the visible ones among them
/// afresh as a script switches them, so the margin and the composite start from the same count.
bool EffectCountsForText(const wpscene::WPImageEffect& effect) {
    return ! effect.materials.empty() && EffectStartsVisible(effect);
}

/// Whether Wallpaper Engine keeps a text card's margin whatever its effects do: the layer
/// composites with a colour blend (any mode but none and "add") or an LED source, paints an
/// opaque background, or sits in a scene that enables distance fog or height fog (the renderer
/// then composites every text layer, to fog it).
bool TextCardIsPaddedRegardless(const wpscene::WPTextObject& obj, bool scene_fog) {
    const bool composites = (obj.colorBlendMode != 0 && obj.colorBlendMode != kAdditiveColorBlendMode) ||
                            obj.ledsource;
    return composites || obj.opaquebackground || scene_fog;
}

/// Whether Wallpaper Engine pads a text card as the scene loads: with `padding * 2` around
/// the text and the text inset by `padding`, on each axis. Besides the cases above that is
/// a layer that has a visible effect, which it counts afresh whenever an effect's visibility
/// changes (`SceneRuntimeContext::TextEffectGate`); a plain text layer has no margin whatever
/// its `padding` says.
bool TextCardIsPadded(const wpscene::WPTextObject& obj, bool scene_fog) {
    return TextCardIsPaddedRegardless(obj, scene_fog) ||
           std::any_of(obj.effects.begin(), obj.effects.end(), EffectCountsForText);
}

// CLEANROOM LS16: the file-local helpers of this group were removed; the rewrite designs its own.

// An effect a user property switches on or off is built only when the
// property's current value -- a preset or the user's choice, by the same rule
// as a layer's visibility -- says so. The scene file's value is the editor's
// default. It is decided here, when the scene loads: building every hidden
// effect would cost passes and memory, so a running scene holds the property at
// this value (SceneRuntimeContext::NoteLoadOnlyProperty) and a changed one
// takes a reload. An effect a script switches is built whatever its value, and
// follows the script while the scene runs (`RegisterScriptedEffectVisibility`).
void ResolveUserEffectVisibility(ParseContext& context,
                                 std::vector<wpscene::WPImageEffect>& effects,
                                 std::string_view runtime_name) {
    if (context.scene->runtime == nullptr) return;
    auto& runtime = *context.scene->runtime;
    for (auto& effect : effects) {
        if (effect.visible_setting.is_null() || effect.scripted_visible) continue;
        effect.visible =
            ResolveBoolSetting(runtime, effect.visible_setting, runtime_name)->getBool();
        runtime.NoteLoadOnlyProperty(UserPropertyName(effect.visible_setting));
    }
}

// Hands a built effect its visibility: fixed, or followed from the script that
// decides it.
void RegisterScriptedEffectVisibility(ParseContext& context,
                                      const wpscene::WPImageEffect& source,
                                      const std::shared_ptr<SceneImageEffect>& effect,
                                      std::string_view runtime_name) {
    effect->visible = source.visible;
    if (! source.scripted_visible || context.scene->runtime == nullptr) return;
    auto& runtime = *context.scene->runtime;
    runtime.RegisterEffectVisibility(
        effect, ResolveBoolSetting(runtime, source.visible_setting, runtime_name));
}

// The keys of a text object that are baked into the card's pixels when the layer
// is laid out: the outline, blur and shadow switches, sizes and opacity. A
// property bound to one is read once, as the scene loads, with the value the user
// has chosen rather than the editor's default in the scene file, and noted as
// load-only so a running scene holds it there (SceneRuntimeContext::
// NoteLoadOnlyProperty). A key a script drives keeps the scene file's value.
// (The colours are uniforms of the card's shader and follow their property live;
// the offset, `padding` and `spacing` are two-number keys, which no property type
// of a project can supply.)
void ResolveLoadTimeTextStyle(ParseContext& context, wpscene::WPTextObject& obj,
                              std::string_view runtime_name) {
    if (context.scene->runtime == nullptr) return;
    auto& runtime = *context.scene->runtime;
    const auto bound = [&](const char* key) -> const nlohmann::json* {
        const auto setting = obj.field_bindings.find(key);
        if (setting == obj.field_bindings.end() || ! setting->is_object() ||
            ! setting->contains("user") || setting->contains("script")) {
            return nullptr;
        }
        runtime.NoteLoadOnlyProperty(UserPropertyName(*setting));
        return &*setting;
    };
    for (const auto& [key, field] : { std::pair<const char*, bool*> { "outline", &obj.outline },
                                      { "blur", &obj.blur },
                                      { "dropshadow", &obj.dropshadow } }) {
        if (const auto* setting = bound(key)) {
            *field = ResolveBoolSetting(runtime, *setting, runtime_name)->getBool();
        }
    }
    for (const auto& [key, field] :
         { std::pair<const char*, float*> { "outlinethickness", &obj.outlinethickness },
           { "blursize", &obj.blursize },
           { "dropshadowsize", &obj.dropshadowsize },
           { "dropshadowopacity", &obj.dropshadowopacity } }) {
        if (const auto* setting = bound(key)) {
            *field = ResolveFloatSetting(runtime, *setting, runtime_name)->getFloat();
        }
    }
}

// CLEANROOM LS17: the file-local helpers of this group were removed; the rewrite designs its own.

/// Gives `node` the local translation, scale and angles that make its local matrix
/// `transform` (translation, then z, y and x rotations, then scale: the order
/// `SceneNode::LocalTransOf` composes). A mirrored matrix carries its mirror on x.
void SetNodeTransformFromMatrix(SceneNode& node, const Matrix4d& transform) {
    const auto at = [&transform](int row, int column) { return transform(row, column); };
    std::array<double, 3> scale {};
    for (int column = 0; column < 3; ++column) {
        scale[column] = std::sqrt(at(0, column) * at(0, column) + at(1, column) * at(1, column) +
                                  at(2, column) * at(2, column));
    }
    // The sign of the 3x3 part's determinant tells a mirror from a turn.
    const double det = at(0, 0) * (at(1, 1) * at(2, 2) - at(1, 2) * at(2, 1)) -
                       at(0, 1) * (at(1, 0) * at(2, 2) - at(1, 2) * at(2, 0)) +
                       at(0, 2) * (at(1, 0) * at(2, 1) - at(1, 1) * at(2, 0));
    if (det < 0.0) scale[0] = -scale[0];
    double rotation[3][3];
    for (int column = 0; column < 3; ++column) {
        for (int row = 0; row < 3; ++row) {
            rotation[row][column] = std::abs(scale[column]) > 1e-12 ? at(row, column) / scale[column]
                                                                    : (row == column ? 1.0 : 0.0);
        }
    }
    // R = Rz * Ry * Rx.
    const double sin_y = std::clamp(-rotation[2][0], -1.0, 1.0);
    double       x     = 0.0;
    double       y     = std::asin(sin_y);
    double       z     = 0.0;
    if (std::abs(sin_y) < 1.0 - 1e-9) {
        x = std::atan2(rotation[2][1], rotation[2][2]);
        z = std::atan2(rotation[1][0], rotation[0][0]);
    } else {
        x = std::atan2(-rotation[1][2], rotation[1][1]);
    }
    node.SetTranslate(Vector3f(static_cast<float>(at(0, 3)), static_cast<float>(at(1, 3)),
                               static_cast<float>(at(2, 3))));
    node.SetScale(Vector3f(static_cast<float>(scale[0]), static_cast<float>(scale[1]),
                           static_cast<float>(scale[2])));
    node.SetRotation(Vector3f(static_cast<float>(x), static_cast<float>(y), static_cast<float>(z)));
}

// CLEANROOM LS18: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS19: the file-local helpers of this group were removed; the rewrite designs its own.

nlohmann::json MaterialConstantSettingJson(const wpscene::WPConstantShaderValue& source) {
    // CLEANROOM LS19
    return {};
}

// Vector shader constants carry one curve per component, and an author can drive
// several of them from one timeline through `options.parent`. Both the curves and
// the relations are read per material pass: a corner of the same name in another
// pass is a different parameter and must never join this group.
struct MaterialConstantAnimationSource {
    std::array<ScalarAnimation, 4> components;
    std::size_t                    component_count { 0 };
    std::size_t                    first_curve { 4 };
    double                         last_frame { 0.0 };
    std::string                    parent_key;
};

std::unordered_map<std::string, MaterialConstantAnimationSource>
CollectMaterialConstantAnimations(const wpscene::WPMaterial& wpmat) {
    std::unordered_map<std::string, MaterialConstantAnimationSource> collected;
    for (const auto& [name, value] : wpmat.constantshadervalues) {
        if (! value.animation.is_object()) continue;
        if (value.value.empty() || value.value.size() > 4) continue;

        const auto                      setting = MaterialConstantSettingJson(value);
        MaterialConstantAnimationSource source;
        source.component_count = value.value.size();
        for (std::size_t index = 0; index < source.component_count; ++index) {
            auto curve = ResolveScalarAnimation(setting, index);
            if (! curve.has_value()) {
                // A component the author left unanimated keeps its own value.
                source.components[index].initial_value = value.value[index];
                continue;
            }
            if (source.first_curve == source.components.size()) source.first_curve = index;
            source.last_frame = std::max(source.last_frame, curve->keyframes.back().frame);
            source.components[index] = std::move(*curve);
        }
        if (source.first_curve == source.components.size()) continue;

        const auto options = value.animation.find("options");
        if (options != value.animation.end() && options->is_object()) {
            const auto parent = options->find("parent");
            if (parent != options->end() && parent->is_object()) {
                const auto key = parent->find("key");
                if (key != parent->end() && key->is_string()) {
                    source.parent_key = key->get<std::string>();
                }
            }
        }
        collected.emplace(name, std::move(source));
    }
    return collected;
}

// CLEANROOM LS20: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS21: the file-local helpers of this group were removed; the rewrite designs its own.

/// The four corners `point0` to `point3` of the first effect's first pass, in the
/// 0..1 square of the shape, if all four are there.
std::optional<std::array<linalg::Vector2f, 4>>
ShapeCornerPoints(const wpscene::WPShapeObject& obj) {
    if (obj.effects.empty() || obj.effects.front().materials.empty()) return std::nullopt;
    auto material = obj.effects.front().materials.front();
    if (! obj.effects.front().passes.empty()) material.MergePass(obj.effects.front().passes.front());
    std::array<linalg::Vector2f, 4> points;
    for (std::size_t index = 0; index < points.size(); ++index) {
        const auto value = material.constantshadervalues.find("point" + std::to_string(index));
        if (value == material.constantshadervalues.end() || value->second.value.size() < 2) {
            return std::nullopt;
        }
        points[index] = linalg::Vector2f(value->second.value[0], value->second.value[1]);
    }
    return points;
}

// CLEANROOM LS22: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS23: the file-local helpers of this group were removed; the rewrite designs its own.

bool ScriptHandlesCursor(std::string_view script) {
    return script.find("cursor") != std::string_view::npos;
}

bool SettingHandlesCursor(const nlohmann::json& setting) {
    // CLEANROOM LS23
    return false;
}

// True when any script bound to this image object can receive cursor events,
// so the layer needs a coverage mask for hit testing.
bool ImageObjectHandlesCursorEvents(const wpscene::WPImageObject& wpimgobj) {
    if (SettingHandlesCursor(wpimgobj.visible_setting) ||
        SettingHandlesCursor(wpimgobj.origin_setting) ||
        SettingHandlesCursor(wpimgobj.scale_setting) ||
        SettingHandlesCursor(wpimgobj.angles_setting) ||
        SettingHandlesCursor(wpimgobj.alpha_setting)) {
        return true;
    }
    for (const auto& [name, constant] : wpimgobj.material.constantshadervalues) {
        (void)name;
        if (ScriptHandlesCursor(constant.script)) return true;
    }
    for (const auto& effect : wpimgobj.effects) {
        for (const auto& material : effect.materials) {
            for (const auto& [name, constant] : material.constantshadervalues) {
                (void)name;
                if (ScriptHandlesCursor(constant.script)) return true;
            }
        }
    }
    return false;
}

// Alpha of one texel from the mip-0 payload, or 255 for formats without alpha.
uint8_t TexelAlpha(const ImageData& mip, TextureFormat format, i32 x, i32 y) {
    const auto* data = mip.data.get();
    switch (format) {
    case TextureFormat::RGBA8: {
        const isize offset = (static_cast<isize>(y) * mip.width + x) * 4 + 3;
        return offset < mip.size ? data[offset] : 0;
    }
    case TextureFormat::BC2: {
        // 16-byte blocks; the first 8 bytes hold sixteen 4-bit alphas.
        const isize blocks_per_row = (mip.width + 3) / 4;
        const isize block          = (static_cast<isize>(y) / 4) * blocks_per_row + x / 4;
        const isize offset         = block * 16 + ((y % 4) * 4 + (x % 4)) / 2;
        if (offset >= mip.size) return 0;
        const uint8_t pair = data[offset];
        const uint8_t nib  = (x % 2) == 0 ? (pair & 0x0F) : (pair >> 4);
        return static_cast<uint8_t>(nib * 17);
    }
    case TextureFormat::BC3: {
        // 16-byte blocks; the first 8 bytes are a DXT5 interpolated alpha block.
        const isize blocks_per_row = (mip.width + 3) / 4;
        const isize block          = (static_cast<isize>(y) / 4) * blocks_per_row + x / 4;
        const isize offset         = block * 16;
        if (offset + 8 > mip.size) return 0;
        const uint8_t a0 = data[offset];
        const uint8_t a1 = data[offset + 1];
        uint64_t      bits = 0;
        for (int i = 0; i < 6; ++i) bits |= static_cast<uint64_t>(data[offset + 2 + i]) << (8 * i);
        const unsigned index = static_cast<unsigned>((bits >> (3 * ((y % 4) * 4 + (x % 4)))) & 0x7);
        if (index == 0) return a0;
        if (index == 1) return a1;
        if (a0 > a1) {
            return static_cast<uint8_t>(((8 - index) * a0 + (index - 1) * a1) / 7);
        }
        if (index == 6) return 0;
        if (index == 7) return 255;
        return static_cast<uint8_t>(((6 - index) * a0 + (index - 1) * a1) / 5);
    }
    default:
        return 255;
    }
}

// Builds a coverage mask for an image object's albedo texture. Returns nullopt
// for textures the runtime should keep hit testing by rectangle: videos,
// sprite sheets, opaque formats and anything the parser cannot decode.
std::optional<NodeHitMask> BuildImageHitMask(ParseContext& context,
                                             const wpscene::WPImageObject& wpimgobj) {
    constexpr uint32_t kMaxMaskSide = 256;
    // Puppet meshes are cut-up sprites deformed by bones, not a card over the
    // albedo, so their authored rectangle stays the hit area.
    if (wpimgobj.material.textures.empty() || ! wpimgobj.puppet.empty()) return std::nullopt;
    const auto& texture_name = wpimgobj.material.textures[0];
    if (texture_name.empty() || IsSpecTex(texture_name)) return std::nullopt;
    const auto texture_iterator = context.scene->textures.find(texture_name);
    if (texture_iterator != context.scene->textures.end() &&
        (texture_iterator->second.isVideo || texture_iterator->second.isSprite)) {
        return std::nullopt;
    }
    const auto image = context.scene->imageParser->Parse(texture_name);
    if (image == nullptr || image->header.isVideo || image->header.isSprite ||
        image->slots.empty() || image->slots[0].mipmaps.empty()) {
        return std::nullopt;
    }
    const auto format = image->header.format;
    if (format != TextureFormat::RGBA8 && format != TextureFormat::BC2 &&
        format != TextureFormat::BC3) {
        return std::nullopt;
    }
    const auto& mip = image->slots[0].mipmaps[0];
    if (mip.data == nullptr || mip.width <= 0 || mip.height <= 0) return std::nullopt;
    // The authored image occupies the top-left mapWidth x mapHeight texels of
    // a possibly padded texture; card meshes only sample that region.
    const i32 map_width  = std::clamp<i32>(image->header.mapWidth, 1, mip.width);
    const i32 map_height = std::clamp<i32>(image->header.mapHeight, 1, mip.height);

    NodeHitMask mask;
    const i32 longest = std::max(map_width, map_height);
    const i32 step    = std::max<i32>(1, (longest + static_cast<i32>(kMaxMaskSide) - 1) /
                                          static_cast<i32>(kMaxMaskSide));
    mask.width  = static_cast<uint32_t>((map_width + step - 1) / step);
    mask.height = static_cast<uint32_t>((map_height + step - 1) / step);
    mask.alpha.resize(static_cast<std::size_t>(mask.width) * mask.height);
    for (uint32_t y = 0; y < mask.height; ++y) {
        const i32 texel_y = std::min<i32>(static_cast<i32>(y) * step + step / 2, map_height - 1);
        for (uint32_t x = 0; x < mask.width; ++x) {
            const i32 texel_x = std::min<i32>(static_cast<i32>(x) * step + step / 2, map_width - 1);
            mask.alpha[static_cast<std::size_t>(y) * mask.width + x] =
                TexelAlpha(mip, format, texel_x, texel_y);
        }
    }
    return mask;
}

// Binds each authored animation layer's visible/rate/blend to user properties
// (and scripts) so the shared puppet state follows the wallpaper settings. A
// script bound there is about that animation layer: its `thisObject` is it.
template <typename Object>
void BindPuppetAnimationLayerSettings(ParseContext& context, const std::string& runtime_name,
                                      const Object& wpimgobj,
                                      WPPuppetLayer layer) {
    auto& runtime = *context.scene->runtime;
    const auto count = std::min(wpimgobj.puppet_layer_settings.size(), layer.layerCount());
    for (std::size_t index = 0; index < count; ++index) {
        const auto& setting = wpimgobj.puppet_layer_settings[index];
        if (! setting.is_object()) continue;
        const i32 layer_index = static_cast<i32>(index);
        const auto is_dynamic = [](const nlohmann::json& value) {
            return value.is_object() && (value.contains("user") || value.contains("script"));
        };
        if (setting.contains("visible") && is_dynamic(setting.at("visible"))) {
            runtime.RegisterDynamicValueListener(
                ResolveBoolSetting(runtime, setting.at("visible"), runtime_name, layer_index),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setVisible(layer_index, value.getBool());
                });
        }
        if (setting.contains("rate") && is_dynamic(setting.at("rate"))) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting.at("rate"), runtime_name, layer_index),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setRate(layer_index, value.getFloat());
                });
        }
        if (setting.contains("blend") && is_dynamic(setting.at("blend"))) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting.at("blend"), runtime_name, layer_index),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setBlend(layer_index, value.getFloat());
                });
        }
    }
}

// CLEANROOM LS24: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS25: the file-local helpers of this group were removed; the rewrite designs its own.

// The field of view of a scene with a perspective projection: a shot's own, else
// the scene's `fov`. `perspectiveoverridefov` belongs to a 2D scene's perspective
// layers (below) and plays no part here, whatever the package version.
float ResolvePerspectiveFov(const wpscene::WPSceneGeneral& general, float object_fov = 0.0f) {
    if (object_fov > 0.0f) return object_fov;
    if (general.fov > 0.0f) return general.fov;
    return 50.0f;
}

// The lens Wallpaper Engine puts in front of a 2D scene's perspective layers --
// particles and models with the `perspective` flag -- is the scene's
// `perspectiveoverridefov`, 95 degrees when the file leaves it out. `fov`
// belongs to scenes with a perspective projection and plays no part here.
// Every field of view is held between 0.1 and 179.9 degrees.
float ResolveCanvasPerspectiveFov(const wpscene::WPSceneGeneral& general) {
    constexpr float kDefaultFov = 95.0f;
    const float     fov = general.perspectiveoverridefov > 0.0f ? general.perspectiveoverridefov
                                                                : kDefaultFov;
    return std::clamp(fov, 0.1f, 179.9f);
}

void PlacePerspectiveCameraNode(SceneNode& node, const wpscene::WPSceneCamera& camera) {
    const Vector3d eye(camera.eye[0], camera.eye[1], camera.eye[2]);
    const Vector3d center(camera.center[0], camera.center[1], camera.center[2]);
    Vector3d       up(camera.up[0], camera.up[1], camera.up[2]);
    if (up.squaredNorm() < 1e-12) up = Vector3d::UnitY();

    Vector3d camDir = center - eye;
    if (camDir.squaredNorm() < 1e-12) camDir = -Vector3d::UnitZ();
    const Vector3d zAxis = -camDir.normalized();
    Vector3d       xAxis = up.cross(zAxis);
    if (xAxis.squaredNorm() < 1e-12) xAxis = Vector3d::UnitX();
    xAxis.normalize();
    const Vector3d yAxis = zAxis.cross(xAxis).normalized();

    Affine3d world = Affine3d::Identity();
    world.linear().col(0) = xAxis;
    world.linear().col(1) = yAxis;
    world.linear().col(2) = zAxis;
    world.translation()   = eye;
    SetNodeTransformFromMatrix(node, world.matrix());
}

// CLEANROOM LS27: the file-local helpers of this group were removed; the rewrite designs its own.

std::array<float, 4> HDRBloomBlend(float threshold, float feather) {
    const float knee = std::max(0.0f, threshold * feather);
    return { threshold, threshold - knee, 2.0f * knee, 0.25f / (knee + 1.0e-5f) };
}

// Wallpaper Engine's extraction strength: the scene's strength over one more
// than the scatter raised to the number of levels past the second.
float HDRBloomExtractionStrength(float strength, float scatter, int levels) {
    return strength / (std::pow(scatter, static_cast<float>(std::max(levels - 2, 0))) + 1.0f);
}

// As many half-size levels as the frame's shorter side allows, at most eight,
// and at most the scene's iterations.
int HDRBloomLevels(int iterations, int width, int height) {
    const int shorter = std::max(2, std::min(width, height));
    int available = 0;
    for (int k = 0; k < 8; ++k) {
        if ((shorter >> (k + 1)) >= 1) ++available;
    }
    return std::max(1, std::min(available, iterations));
}

/// The filter Wallpaper Engine gives the render targets of an image layer: points
/// when the layer asks (`nointerpolation`) or when the header of its primary
/// texture does, and linear otherwise. A layer with no texture of its own, a
/// composition layer, only has its own flag to go by. The header is read from the
/// texture's file, not from what an earlier layer happened to load, so the answer
/// does not depend on the order the layers are parsed in -- the composite of a
/// layer another layer reads is registered before its own material is loaded.
TextureFilter LayerRenderTargetFilter(const Scene& scene, const wpscene::WPImageObject& image) {
    if (image.nointerpolation) return TextureFilter::NEAREST;
    const auto& textures = image.material.textures;
    if (textures.empty() || textures.front().empty()) return TextureFilter::LINEAR;
    const auto& primary = textures.front();
    if (const auto texture = scene.textures.find(primary); texture != scene.textures.end()) {
        return texture->second.sample.magFilter == TextureFilter::NEAREST ? TextureFilter::NEAREST
                                                                          : TextureFilter::LINEAR;
    }
    // A render target or a link texture has no header; neither does a file that
    // could not be read, whose default sample is not a request for points.
    if (IsSpecTex(primary) || scene.imageParser == nullptr) return TextureFilter::LINEAR;
    const ImageHeader header = scene.imageParser->ParseHeader(primary);
    if (header.mapWidth <= 0 || header.mapHeight <= 0) return TextureFilter::LINEAR;
    return header.sample.magFilter == TextureFilter::NEAREST ? TextureFilter::NEAREST
                                                             : TextureFilter::LINEAR;
}

/// How the pair of ping-pong targets an image layer's effects run through is
/// sampled by the passes that read them, the layer's last draw among them:
/// `LayerRenderTargetFilter`, and clamped or wrapped by `clampuvs`.
TextureSample LayerRenderTargetSample(const Scene& scene, const wpscene::WPImageObject& image) {
    const auto wrap   = image.clampuvs ? TextureWrap::CLAMP_TO_EDGE : TextureWrap::REPEAT;
    const auto filter = LayerRenderTargetFilter(scene, image);
    return { wrap, wrap, filter, filter };
}

void RegisterImageComposite(ParseContext& context, const wpscene::WPImageObject& object,
                             SceneNode& node) {
    RegisterLayerComposite(context, object.id, node, ResolveImageRenderExtent(object, context),
                           object.clampuvs, context.effect_camera_node,
                           LayerRenderTargetFilter(*context.scene, object));
}

// A scene setting bound to a user property takes the property's current value
// when the scene loads. Those that decide what the scene is built with -- the
// bloom passes, which passes follow the cursor -- are read only then, and a
// change to their property reloads the scene.
template <typename T>
void ResolveLoadOnlySceneSetting(SceneRuntimeContext& runtime, const nlohmann::json& setting,
                                 T& value) {
    if (! HasDynamicSetting(setting)) return;
    if constexpr (std::is_same_v<T, bool>) {
        value = ResolveBoolSetting(runtime, setting)->getBool();
    } else {
        value = ResolveFloatSetting(runtime, setting)->getFloat();
    }
    runtime.NoteLoadOnlyProperty(UserPropertyName(setting));
}

// CLEANROOM LS28: scene wind and gravity (`windenabled`, `winddirection`, `windstrength`, `gravitydirection`, `gravitystrength`) do not reach the particle systems yet.

/// Wallpaper Engine composes a layer from the flags and shader of its model, not
/// from the model's path. These are the editor's two models of that kind: the
/// composition layer, and the one that also tests depth.
bool IsComposeLayerModel(std::string_view image) {
    return image == "models/util/composelayer.json" ||
           image == "models/util/composelayer_depthtest.json";
}

// CLEANROOM LS29: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS30: the file-local helpers of this group were removed; the rewrite designs its own.

/// Puts the scene object's own control points over the preset's: a set
/// `controlpointN` replaces the preset's offset, a set `controlpointangleN`
/// turns the control point. Control points that follow the cursor keep their link.
void ApplyParticleOverrideControlpoints(const wpscene::ParticleInstanceoverride& over,
                                        std::span<ParticleControlpoint>          points) {
    if (! over.enabled) return;
    for (std::size_t i = 0; i < points.size() && i < 8; ++i) {
        auto& point = points[i];
        if (over.controlpointSet[i] && ! point.link_mouse) {
            point.base_offset = linalg::Vector3d(over.controlpoint[i][0],
                                                over.controlpoint[i][1],
                                                over.controlpoint[i][2]);
            // A pinned control point is carried into the layer's space each
            // step; any other is where the scene put it.
            if (! point.worldspace || i == 0) point.offset = point.base_offset;
        }
        if (over.controlpointangleSet[i]) {
            const auto& a = over.controlpointangle[i];
            point.rotation =
                (linalg::AngleAxisd(a[2], linalg::Vector3d::UnitZ()) *
                 linalg::AngleAxisd(a[1], linalg::Vector3d::UnitY()) *
                 linalg::AngleAxisd(a[0], linalg::Vector3d::UnitX()))
                    .toRotationMatrix();
            point.has_rotation = true;
        }
    }
}

// CLEANROOM LS31: the file-local helpers of this group were removed; the rewrite designs its own.

// CLEANROOM LS32: the file-local helpers of this group were removed; the rewrite designs its own.

std::shared_ptr<SceneNode> ReuseOrCreateLayerNode(ParseContext& context, int32_t id) {
    auto node_iterator = context.layer_nodes.find(id);
    if (node_iterator != context.layer_nodes.end() && node_iterator->second != nullptr) {
        return node_iterator->second;
    }
    return std::make_shared<SceneNode>();
}

// A camera layer's authored timeline. The editor links a shot's origin to its
// zoom (`options.parent`), and one playhead drives both, so the shot keeps a
// single clock: the zoom's when that is animated, else the first origin curve's.
// A relative origin timeline is an offset from the authored origin, which is
// how an intro can glide back to exactly where the shot rests.
SceneRuntimeContext::CameraShotTimeline ResolveCameraShotTimeline(
    SceneRuntimeContext& runtime, const wpscene::WPCameraObject& obj, std::string_view runtime_name) {
    SceneRuntimeContext::CameraShotTimeline timeline;
    timeline.zoom = ResolveScalarAnimation(obj.zoom_setting);
    // A scripted or user-bound origin already moves the layer every tick.
    if (! obj.dynamic_origin && obj.origin_setting.is_object()) {
        if (const auto animation = obj.origin_setting.find("animation");
            animation != obj.origin_setting.end() && animation->is_object()) {
            const auto relative      = animation->find("relative");
            timeline.origin_relative = relative != animation->end() && relative->is_boolean() &&
                                       relative->get<bool>();
            timeline.origin_base     = Vector3f(obj.origin.data());
            for (std::size_t index = 0; index < timeline.origin.size(); ++index) {
                auto curve = ResolveScalarAnimation(obj.origin_setting, index);
                // Before its first key a relative curve offsets by nothing.
                if (curve.has_value() && timeline.origin_relative) curve->initial_value = 0.0f;
                timeline.origin[index] = std::move(curve);
            }
        }
    }

    const ScalarAnimation* source     = timeline.zoom.has_value() ? &*timeline.zoom : nullptr;
    double                 last_frame = source != nullptr ? source->keyframes.back().frame : 0.0;
    for (const auto& curve : timeline.origin) {
        if (! curve.has_value()) continue;
        if (source == nullptr) source = &*curve;
        last_frame = std::max(last_frame, curve->keyframes.back().frame);
    }
    if (source != nullptr) {
        ScalarAnimation clock = *source;
        if (! (clock.length_frames > 0.0)) clock.length_frames = last_frame;
        timeline.clock = runtime.RegisterScalarAnimation(runtime_name, std::move(clock));
    }
    return timeline;
}

void ApplyDefaultDepthTarget(ParseContext& context) {
    auto* target = context.scene->FindRenderTarget(SpecTex_Default.data());
    if (target == nullptr) return;
    if (context.uses_models ||
        (context.scene->activeCamera != nullptr && context.scene->activeCamera->IsPerspective())) {
        target->withDepth = true;
    }
}

std::string LightRuntimeName(const ParseContext& context, const wpscene::WPLightObject& obj) {
    if (! obj.name.empty()) {
        const auto count = context.layer_name_counts.find(obj.name);
        if (count == context.layer_name_counts.end() || count->second == 0) return obj.name;
    }
    return "__we_light_" + std::to_string(obj.id);
}

bool HasDynamicVisible(const wpscene::WPModelObject& object) { return object.dynamic_visible; }

bool HasDynamicVisible(const wpscene::WPCameraObject& object) { return object.dynamic_visible; }

bool HasDynamicVisible(const wpscene::WPShapeObject& object) { return object.dynamic_visible; }

std::unordered_set<int32_t> CollectReachableDependencyIds(const nlohmann::json& objects,
                                                          const LayerObjectIndex& index,
                                                          fs::VFS& vfs) {
    return CollectReachableLayerIds(objects, index, &vfs);
}

// Every `script` string anywhere under `value`: a layer's properties, its
// effects' visibility and constants, a particle's overrides.
void CollectScriptSources(const nlohmann::json& value, std::vector<const std::string*>& out) {
    if (value.is_object()) {
        for (const auto& [key, child] : value.items()) {
            if (key == "script" && child.is_string()) {
                out.push_back(child.get_ptr<const std::string*>());
            } else {
                CollectScriptSources(child, out);
            }
        }
    } else if (value.is_array()) {
        for (const auto& child : value) CollectScriptSources(child, out);
    }
}

// The quoted strings of a script (single, double or backtick quotes, escapes
// skipped; comments are not told apart, which only ever adds names).
void CollectScriptStringLiterals(std::string_view source, std::unordered_set<std::string>& out) {
    for (std::size_t i = 0; i < source.size(); ++i) {
        const char quote = source[i];
        if (quote != '"' && quote != '\'' && quote != '`') continue;
        std::string literal;
        std::size_t j = i + 1;
        for (; j < source.size() && source[j] != quote && source[j] != '\n'; ++j) {
            if (source[j] == '\\' && j + 1 < source.size()) ++j;
            literal.push_back(source[j]);
        }
        if (j < source.size() && source[j] == quote) out.insert(std::move(literal));
        i = j;
    }
}

} // namespace

// A texture property carries whatever the editor or the picker wrote into it:
// an absolute path to the user's own picture, or a package-relative asset the
// author shipped. The loader addresses packaged textures by bare name, so the
// authored form is reduced to that name.
//
// The property stores the path, not a copy, so an absolute one is only taken
// when that file can actually be opened now: moved, deleted, or out of reach of
// the sandboxed lock-screen extension all leave the slot on the wallpaper's own
// texture instead of on a name that decodes to nothing.
std::optional<std::string> TexturePropertyTextureName(const std::string& value) {
    if (std::filesystem::path(value).is_absolute()) {
        if (! HostLooseAssetIsReadable(value)) return std::nullopt;
        return value;
    }
    std::string name = value;
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".tex") == 0) {
        name.erase(name.size() - 4);
    }
    constexpr std::string_view kMaterials { "materials/" };
    if (name.compare(0, kMaterials.size(), kMaterials) == 0) name.erase(0, kMaterials.size());
    if (name.empty()) return std::nullopt;
    return name;
}

std::string_view wallpaper::UserTexturePropertyName(const wpscene::WPUserTexture& user_texture) {
    // A typed slot (`system`, ...) names something the runtime supplies.
    return user_texture.type.empty() ? std::string_view(user_texture.name) : std::string_view {};
}

void wallpaper::ApplySystemUserTextures(std::vector<std::string>&                  textures,
                                        const std::vector<wpscene::WPUserTexture>& usertextures,
                                        const ProjectProperties*                   properties,
                                        RuntimeImageSource*                        covers) {
    for (std::size_t slot = 0; slot < usertextures.size(); ++slot) {
        const auto& user = usertextures[slot];
        if (user.name.empty() && user.type.empty()) continue;
        // The texture the slot already has: what an unreadable choice falls back to,
        // and what a cover slot shows until a cover arrives.
        const std::string authored = slot < textures.size() ? textures[slot] : std::string();

        if (wpscene::IsSystemUserTexture(user)) {
            if (textures.size() <= slot) textures.resize(slot + 1);
            textures[slot] = covers != nullptr ? covers->BindCoverSlot(user.name, authored) : user.name;
            continue;
        }
        // Any other typed entry names something this renderer does not supply.
        if (! user.type.empty()) continue;

        // A bare name is a project property of kind scene texture; without a table
        // to read it from, the authored texture stays.
        if (properties == nullptr) continue;
        const auto found = properties->find(user.name);
        if (found == properties->end() ||
            found->second.kind != RuntimeScalarValue::Kind::String) {
            continue;
        }
        const auto& value = found->second.asString();
        if (value.empty()) continue;
        if (auto name = TexturePropertyTextureName(value); name.has_value()) {
            if (textures.size() <= slot) textures.resize(slot + 1);
            textures[slot] = std::move(*name);
        }
    }
}

void wallpaper::LoadMaterialConstantShaderValues(SceneMaterial& material,
                                                 const wpscene::WPMaterial& wpmat,
                                                 const WPShaderInfo& info) {
    // CLEANROOM LS19
}

namespace
{
// What a layer made while the scene runs needs of the parse that built the scene.
struct LazyParseInputs {
    ShaderValueMap   globals;
    LayerObjectIndex index;
    bool             is_ortho { true };
    bool             uses_models { false };
};

ParseContext MakeLazyParseContext(const std::shared_ptr<Scene>& scene, fs::VFS& vfs,
                                  const LazyParseInputs& inputs) {
    ParseContext lazy {};
    lazy.scene                    = scene;
    lazy.vfs                      = &vfs;
    lazy.shader_updater           = static_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    lazy.ortho_w                  = scene->ortho[0];
    lazy.ortho_h                  = scene->ortho[1];
    lazy.global_base_uniforms     = inputs.globals;
    lazy.is_ortho                 = inputs.is_ortho;
    lazy.uses_models              = inputs.uses_models;
    lazy.effect_camera_node       = scene->cameras.at("effect")->GetAttachedNode();
    lazy.global_camera_node       = scene->cameras.at("global")->GetAttachedNode();
    lazy.global_perspective_camera_node =
        scene->cameras.at("global_perspective")->GetAttachedNode();
    return lazy;
}

// A parse that runs after the scene was built needs the shader compiler up and
// the layer index in place, and leaves both as it found them.
struct LazyShaderParseScope {
    const LayerObjectIndex* previous;
    explicit LazyShaderParseScope(const LayerObjectIndex& index) : previous(g_parse_layer_index) {
        g_parse_layer_index = &index;
        WPShaderParser::BeginShaderSession();
    }
    ~LazyShaderParseScope() {
        g_pending_metal_translations.clear();
        // A layer a script creates after the scene is drawing: its failure is the
        // script's (the layer is not made), never a reason to refuse the scene.
        g_shader_failures.clear();
        g_parse_layer_index = previous;
        WPShaderParser::EndShaderSession();
    }
};
} // namespace

namespace
{
// ---------------------------------------------------------------------------
// Entries of the object list: what each is, whether it is built, what it is
// called (R31 to R35, R75, R87, R112).
// ---------------------------------------------------------------------------

enum class EntryKind
{
    Ignored,
    Group,
    Image,
    Particle,
    Sound,
    Light,
    Text,
    Model,
    Camera,
    Shape,
};

/// What becomes of an entry: nothing, a transform-only node, or a typed object
/// (which owns a node of its own, or none for a sound).
enum class Admission
{
    Skip,
    Node,
    Object,
};

struct EntryPlan {
    EntryKind   kind { EntryKind::Ignored };
    Admission   admission { Admission::Skip };
    int32_t     id { 0 };
    bool        placeholder { false }; // a node standing in for a typed object that has children
    std::string key;
};

/// A script that only registers scene events: it exports no `update` and calls
/// `engine.on(`, `scene.on(` or `thisScene.on(`. It is run once, as a scene script
/// of its layer, rather than attached to the value it was written on.
bool IsSceneEventScript(std::string_view source) {
    if (ExportsFunction(source, "update")) return false;
    for (const std::string_view call : { "engine.on(", "scene.on(", "thisScene.on(" }) {
        if (source.find(call) != std::string_view::npos) return true;
    }
    return false;
}

/// Queues the scene-event scripts among the bindings of a layer.
void QueueSceneScripts(ParseContext& context, const nlohmann::json& bindings,
                       const std::string& key) {
    if (! bindings.is_object()) return;
    for (const auto& [name, binding] : bindings.items()) {
        const auto script = binding.find("script");
        if (script == binding.end() || ! script->is_string()) continue;
        const auto& source = script->get_ref<const std::string&>();
        if (IsSceneEventScript(source)) context.scene_scripts.emplace_back(source, key);
    }
}

/// The member `key` of an entry when it is there and not `null`.
const nlohmann::json* NonNullMember(const nlohmann::json& entry, const char* key) {
    const auto found = entry.find(key);
    return found == entry.end() || found->is_null() ? nullptr : &*found;
}

EntryKind ClassifyEntry(const nlohmann::json& entry) {
    if (! entry.is_object()) return EntryKind::Ignored;
    if (const auto* image = NonNullMember(entry, "image"); image != nullptr && image->is_string()) {
        return EntryKind::Image;
    }
    if (NonNullMember(entry, "particle") != nullptr) return EntryKind::Particle;
    if (NonNullMember(entry, "sound") != nullptr) return EntryKind::Sound;
    if (NonNullMember(entry, "light") != nullptr) return EntryKind::Light;
    if (NonNullMember(entry, "text") != nullptr) return EntryKind::Text;
    if (NonNullMember(entry, "model") != nullptr) return EntryKind::Model;
    if (NonNullMember(entry, "camera") != nullptr) return EntryKind::Camera;
    // A kind key that holds nothing usable makes the entry neither a group nor a
    // typed object.
    for (const char* key : { "image", "particle", "sound", "light", "text", "model", "camera" }) {
        if (entry.contains(key)) return EntryKind::Ignored;
    }
    const auto shape = entry.find("shape");
    return shape != entry.end() && shape->is_string() ? EntryKind::Shape : EntryKind::Group;
}

/// `visible` is plainly false: the boolean, or a wrapper whose `value` is false
/// with neither a property nor a script to change it.
bool StaticallyHidden(const nlohmann::json& entry) {
    const auto found = entry.find("visible");
    if (found == entry.end()) return false;
    if (found->is_boolean()) return ! found->get<bool>();
    if (! found->is_object() || wpscene::VisibilityIsBound(*found)) return false;
    const auto value = found->find("value");
    return value != found->end() && value->is_boolean() && ! value->get<bool>();
}

int32_t EntryId(const nlohmann::json& entry) {
    int32_t id = 0;
    if (const auto found = entry.find("id"); found != entry.end()) wpscene::ReadInt32(*found, id);
    return id;
}

/// What the scripts of the object list could reach: the quoted strings of every
/// script anywhere in it.
std::unordered_set<std::string> ScriptLiterals(const nlohmann::json& objects) {
    std::unordered_set<std::string> literals;
    std::vector<const std::string*> sources;
    CollectScriptSources(objects, sources);
    for (const auto* source : sources) CollectScriptStringLiterals(*source, literals);
    return literals;
}

/// Whether a statically hidden entry is built anyway: a script sits inside it, a
/// script names it by a quoted literal, or (for an image) another built image
/// reads its picture.
bool RetainedWhileHidden(EntryKind kind, const nlohmann::json& entry, int32_t id,
                         const std::unordered_set<int32_t>&     reachable,
                         const std::unordered_set<std::string>& literals) {
    if (kind == EntryKind::Image && id != 0 && reachable.contains(id)) return true;
    std::vector<const std::string*> sources;
    CollectScriptSources(entry, sources);
    if (! sources.empty()) return true;
    if (const auto name = entry.find("name");
        name != entry.end() && name->is_string() && ! name->get_ref<const std::string&>().empty()) {
        return literals.contains(name->get<std::string>());
    }
    return false;
}

/// Decides, for every entry, what is built and what is called.
std::vector<EntryPlan> PlanEntries(ParseContext& context, const nlohmann::json& objects,
                                   const LayerObjectIndex& index) {
    std::vector<EntryPlan> plans(objects.size());
    std::unordered_set<int32_t> parent_ids;
    for (const auto& entry : objects) {
        int32_t parent = 0;
        if (entry.is_object()) {
            if (const auto found = entry.find("parent");
                found != entry.end() && wpscene::ReadInt32(*found, parent)) {
                parent_ids.insert(parent);
            }
        }
    }
    const auto reachable = CollectReachableLayerIds(objects, index, context.vfs);
    const auto literals  = ScriptLiterals(objects);

    for (std::size_t at = 0; at < objects.size(); ++at) {
        const auto& entry = objects[at];
        auto&       plan  = plans[at];
        plan.kind         = ClassifyEntry(entry);
        if (plan.kind == EntryKind::Ignored) continue;
        plan.id            = EntryId(entry);
        const bool has_id  = plan.id != 0;
        const bool has_kids = has_id && parent_ids.contains(plan.id);
        const bool hidden  = StaticallyHidden(entry);
        switch (plan.kind) {
        case EntryKind::Group:
        case EntryKind::Shape: plan.admission = has_id ? Admission::Node : Admission::Skip; break;
        case EntryKind::Sound: plan.admission = hidden ? Admission::Skip : Admission::Object; break;
        case EntryKind::Light:
            // A light that is statically hidden is dropped whatever binds its
            // visibility; its children still keep their parent.
            if (hidden) plan.admission = has_kids ? Admission::Node : Admission::Skip;
            else plan.admission = Admission::Object;
            break;
        case EntryKind::Text: plan.admission = has_id ? Admission::Object : Admission::Skip; break;
        default:
            if (! has_id) {
                plan.admission = Admission::Skip;
            } else if (! hidden || RetainedWhileHidden(plan.kind, entry, plan.id, reachable, literals)) {
                plan.admission = Admission::Object;
            } else {
                plan.admission = has_kids ? Admission::Node : Admission::Skip;
            }
            break;
        }
        plan.placeholder = has_kids && plan.admission == Admission::Object &&
                           (plan.kind == EntryKind::Text || plan.kind == EntryKind::Model ||
                            plan.kind == EntryKind::Camera);
        if (plan.admission == Admission::Node && plan.kind != EntryKind::Group &&
            plan.kind != EntryKind::Shape) {
            plan.placeholder = true;
        }
    }

    // Names. Entries of every kind but text and light are counted together; a
    // text layer is counted apart.
    std::unordered_map<std::string, uint32_t> counted;
    for (std::size_t at = 0; at < objects.size(); ++at) {
        const auto& plan = plans[at];
        if (plan.admission == Admission::Skip || plan.kind == EntryKind::Sound ||
            plan.kind == EntryKind::Light) {
            continue;
        }
        const auto name = objects[at].find("name");
        if (name == objects[at].end() || ! name->is_string()) continue;
        const auto& text = name->get_ref<const std::string&>();
        if (text.empty()) continue;
        if (plan.kind == EntryKind::Text) {
            ++context.text_name_counts[text];
        } else if (plan.admission == Admission::Object || plan.kind == EntryKind::Group ||
                   plan.kind == EntryKind::Shape) {
            ++counted[text];
        }
    }
    context.layer_name_counts = counted;

    for (std::size_t at = 0; at < objects.size(); ++at) {
        auto& plan = plans[at];
        if (plan.admission == Admission::Skip) continue;
        std::string authored;
        if (const auto name = objects[at].find("name"); name != objects[at].end() && name->is_string()) {
            authored = name->get<std::string>();
        }
        const auto count_of = [&](const std::unordered_map<std::string, uint32_t>& table) {
            const auto found = table.find(authored);
            return found == table.end() ? 0u : found->second;
        };
        const std::string id_text = std::to_string(plan.id);
        switch (plan.kind) {
        case EntryKind::Text:
            plan.key = ! authored.empty() && count_of(counted) == 0 &&
                               count_of(context.text_name_counts) <= 1
                           ? authored
                           : "__we_text_" + id_text;
            break;
        case EntryKind::Light:
            plan.key = ! authored.empty() && count_of(counted) == 0 ? authored
                                                                    : "__we_light_" + id_text;
            break;
        case EntryKind::Sound: plan.key = authored; break;
        default:
            plan.key = ! authored.empty() && count_of(counted) <= 1 ? authored
                                                                    : "__we_layer_" + id_text;
            break;
        }
    }
    return plans;
}

// ---------------------------------------------------------------------------
// The layer tree (R38 to R43, R75 to R78, R87).
// ---------------------------------------------------------------------------

/// The node of an entry that only carries a transform, registered under its key
/// with its bindings. `animate` is false for the stand-in of a typed object, whose
/// own loader registers the timelines.
std::shared_ptr<SceneNode> MakePlainLayerNode(ParseContext& context, const nlohmann::json& entry,
                                              const EntryPlan& plan, bool animate) {
    wpscene::WPMiscObjectBase base;
    base.FromCommonJson(entry);
    auto node = std::make_shared<SceneNode>(Vector3f(base.origin.data()),
                                            Vector3f(base.scale.data()),
                                            Vector3f(base.angles.data()), plan.key);
    node->ID() = plan.id;
    // A parse with no property table has no runtime: nothing is bound, and every
    // value keeps what the file says.
    bool visible = base.visible;
    if (auto* runtime_ptr = context.scene->runtime.get(); runtime_ptr != nullptr) {
        auto& runtime = *runtime_ptr;
        runtime.RegisterNode(plan.key, node.get());
        runtime.RegisterLayerId(plan.id, plan.key);
        if (const auto name = entry.find("name"); name != entry.end() && name->is_string()) {
            const auto& authored = name->get_ref<const std::string&>();
            if (authored != plan.key) {
                runtime.RegisterLayerAuthoredName(plan.key, authored);
                // Name lookup answers with the first declaration of a shared name.
                if (! authored.empty()) runtime.RegisterLayerAlias(authored, plan.key);
            }
        }
        RegisterNodeTransformSettings(runtime, node.get(), plan.key, base.origin_setting,
                                      base.scale_setting, base.angles_setting, animate);
        QueueSceneScripts(context, base.field_bindings, plan.key);

        // Visibility: the authored flag, or the value a property or script gives it,
        // which the runtime then keeps following. A hidden node that only a reload can
        // change costs the render graph nothing.
        if (base.dynamic_visible) {
            auto value = ResolveBoolSetting(runtime, base.visible_setting, plan.key);
            visible    = value->getBool();
            runtime.RegisterNodeVisibility(plan.key, node.get(), std::move(value));
        }
    }
    node->SetVisible(visible);
    node->SetVisibilitySettled(VisibilitySettledBy(base.visible_setting));
    return node;
}

/// The authored setting, or a literal standing in for a key the file leaves out.
nlohmann::json SettingOrValue(const nlohmann::json& setting, const nlohmann::json& literal) {
    return setting.is_null() ? literal : setting;
}

bool LoadSoundEntry(ParseContext& context, const nlohmann::json& entry, audio::SoundManager& sm);

/// Makes the node of an entry and puts it in the tree record. A light without an
/// id hangs from the scene's root and answers to no id.
ParsedLayer& AddLayer(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                      const EntryPlan& plan, bool animate, bool plain) {
    ParsedLayer layer;
    layer.entry = at;
    layer.id    = plan.id;
    layer.key   = plan.key;
    if (const auto name = entry.find("name"); name != entry.end() && name->is_string()) {
        layer.authored_name = name->get<std::string>();
    }
    if (plan.id != 0) {
        if (const auto parent = entry.find("parent"); parent != entry.end()) {
            wpscene::ReadInt32(*parent, layer.parent_id);
        }
    }
    if (const auto attachment = entry.find("attachment");
        attachment != entry.end() && attachment->is_string()) {
        layer.attachment = attachment->get<std::string>();
    }
    layer.node  = MakePlainLayerNode(context, entry, plan, animate);
    layer.plain = plain;
    if (plan.id != 0) context.layer_nodes[plan.id] = layer.node;
    context.layers.push_back(std::move(layer));
    return context.layers.back();
}

/// How the cursor treats a layer the pointer can never hit: groups, lights and
/// the stand-ins of typed objects.
void SetUnhittable(ParseContext& context, const std::string& key, bool solid = false,
                   bool disable_propagation = false) {
    if (context.scene->runtime != nullptr) {
        context.scene->runtime->SetNodeCursorTarget(key, false, solid, disable_propagation);
    }
}

/// A light: a member of the tree with no picture of its own. Its colour, radius,
/// exponent and intensity follow their bindings; its cones and control point are
/// fixed at load (R100 to R102).
bool LoadLightEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                    const EntryPlan& plan) {
    wpscene::WPLightObject light;
    if (! light.FromJson(entry, *context.vfs)) return false;
    auto* runtime_ptr = context.scene->runtime.get();
    auto& layer       = AddLayer(context, at, entry, plan, true, true);
    SetUnhittable(context, plan.key);

    auto source = std::make_unique<SceneLight>(ParseSceneLightType(light.light),
                                               Vector3f(light.color.data()), light.radius,
                                               light.intensity);
    source->setExponent(light.exponent);
    source->setCones(light.innercone, light.outercone);
    source->setControlPoint(Vector3f(light.controlpoint.data()));
    source->setNode(layer.node);
    SceneLight* raw = source.get();
    if (runtime_ptr == nullptr) {
        context.scene->lights.push_back(std::move(source));
        return true;
    }
    auto& runtime = *runtime_ptr;

    const auto follow_float = [&](const nlohmann::json& setting, auto apply) {
        if (! HasDynamicSetting(setting)) return;
        auto value = ResolveFloatSetting(runtime, setting, plan.key);
        apply(value->getFloat());
        runtime.RegisterDynamicValueListener(std::move(value), [apply](const DynamicValue& now) {
            apply(now.getFloat());
        });
    };
    follow_float(light.radius_setting, [raw](float value) { raw->setRadius(value); });
    follow_float(light.exponent_setting, [raw](float value) { raw->setExponent(value); });
    if (HasDynamicSetting(light.color_setting)) {
        auto value = ResolveVec3Setting(runtime, light.color_setting, plan.key);
        raw->setColor(value->getVec3());
        runtime.RegisterDynamicValueListener(std::move(value), [raw](const DynamicValue& now) {
            raw->setColor(now.getVec3());
        });
    }
    // An intensity that a property or script drives is live; a timeline on it
    // plays on the clock of its own, when nothing else writes the value.
    if (HasDynamicSetting(light.intensity_setting)) {
        follow_float(light.intensity_setting, [raw](float value) { raw->setIntensity(value); });
    } else if (auto animation = ResolveScalarAnimation(light.intensity_setting);
               animation.has_value()) {
        raw->setIntensityAnimation(runtime.RegisterScalarAnimation(plan.key, std::move(*animation)));
    }
    context.scene->lights.push_back(std::move(source));
    return true;
}

/// A camera object. In a scene projected by its canvas it only frames the canvas
/// (R27, R93); in a perspective scene it is a shot of the camera it names, which
/// the last visible one poses (R26, R89 to R98).
bool LoadCameraEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                     const EntryPlan& plan, const wpscene::WPSceneGeneral& general) {
    wpscene::WPCameraObject camera;
    if (! camera.FromJson(entry, *context.vfs)) return false;
    auto& scene       = *context.scene;
    auto* runtime_ptr = scene.runtime.get();
    const bool canvas = context.is_ortho;
    auto& layer       = AddLayer(context, at, entry, plan, ! canvas, true);
    SetUnhittable(context, plan.key, camera.solid, camera.disablepropagation);

    if (canvas && runtime_ptr == nullptr) {
        // No runtime to re-decide it each tick: the shot frames the canvas as it is
        // authored, when it is visible.
        if (layer.node->EffectiveVisible() && std::isfinite(camera.zoom) && camera.zoom > 0.0f) {
            scene.FrameCanvas(camera.zoom, Vector2f(camera.origin[0], camera.origin[1]));
        }
        return true;
    }
    if (canvas) {
        auto& runtime = *runtime_ptr;
        auto zoom = ResolveFloatSetting(runtime, SettingOrValue(camera.zoom_setting, camera.zoom),
                                        plan.key);
        runtime.RegisterCameraShot(layer.node.get(), std::move(zoom),
                                   ResolveCameraShotTimeline(runtime, camera, plan.key),
                                   camera.dynamic_origin);
        return true;
    }

    // The camera the shot addresses: the scene's own for an empty name or
    // `default`, else one of that name made on first sight.
    auto own = scene.cameras.at("global_perspective");
    std::shared_ptr<SceneCamera> target = own;
    if (! camera.camera.empty() && camera.camera != "default") {
        auto found = scene.cameras.find(camera.camera);
        if (found == scene.cameras.end()) {
            auto named = std::make_shared<SceneCamera>(*own);
            named->AttatchNode(own->GetAttachedNode());
            // Born with the field of view its first shot resolves to.
            named->SetFov(ResolvePerspectiveFov(general, camera.fov));
            found = scene.cameras.emplace(camera.camera, std::move(named)).first;
        }
        target = found->second;
    }
    target->LockFov(true);

    if (runtime_ptr == nullptr) {
        // The last visible shot poses its camera, and that camera projects the scene.
        if (layer.node->EffectiveVisible()) {
            target->AttatchNode(layer.node);
            target->SetFov(ResolvePerspectiveFov(general, camera.fov));
            target->Update();
            scene.activeCamera = target.get();
        }
        return true;
    }
    auto& runtime = *runtime_ptr;
    CameraPathPlayback path;
    if (! camera.path.empty()) {
        nlohmann::json document;
        if (PARSE_JSON(fs::GetFileContent(*context.vfs, "/assets/" + camera.path), document)) {
            path = CameraPathPlayback(ParseCameraPaths(document), camera.queuemode);
        }
    }
    runtime.RegisterPerspectiveCameraShot(layer.node, target.get(),
                                          ResolvePerspectiveFov(general, camera.fov),
                                          std::move(path));
    return true;
}

/// Builds the entries in the order the file declares them: the plain node of a
/// group, a shape or a stand-in, and the typed object an entry carries. Layers are
/// registered with the runtime in this order, which is the order scripts count
/// them in.
void BuildLayers(ParseContext& context, const wpscene::WPSceneGeneral& general,
                 const nlohmann::json& objects, const std::vector<EntryPlan>& plans,
                 audio::SoundManager& sm) {
    for (std::size_t at = 0; at < objects.size(); ++at) {
        const auto& plan  = plans[at];
        const auto& entry = objects[at];
        if (plan.admission == Admission::Skip) continue;
        const bool plain = plan.admission == Admission::Node;
        const bool typed_node = plan.kind == EntryKind::Light || plan.kind == EntryKind::Camera;
        if (plain || (plan.placeholder && ! typed_node)) {
            AddLayer(context, at, entry, plan, plain, true);
            SetUnhittable(context, plan.key);
        }
        if (plain) continue;
        bool built = true;
        switch (plan.kind) {
        case EntryKind::Sound: built = LoadSoundEntry(context, entry, sm); break;
        case EntryKind::Light: built = LoadLightEntry(context, at, entry, plan); break;
        case EntryKind::Camera: built = LoadCameraEntry(context, at, entry, plan, general); break;
        default:
            LOG_ERROR("object %d (%s) is not built: its kind is not loaded by this parser yet",
                      plan.id, plan.key.c_str());
            break;
        }
        if (! built) {
            LOG_ERROR("object %d (%s) could not be built", plan.id, plan.key.c_str());
        }
    }
}

/// Hangs every layer under its parent, once all of them exist: roots under the
/// scene's root, children under theirs, both in file order. A parent that is
/// absent, is no member of the tree, appears under more than one entry, is the
/// layer itself or is part of a cycle makes the layer a root.
void AttachLayers(ParseContext& context) {
    auto&             layers = context.layers;
    const std::size_t count  = layers.size();
    std::unordered_map<int32_t, std::size_t> slot_of;
    std::unordered_set<int32_t>              ambiguous;
    for (std::size_t at = 0; at < count; ++at) {
        if (layers[at].id == 0) continue;
        if (! slot_of.emplace(layers[at].id, at).second) ambiguous.insert(layers[at].id);
    }
    constexpr std::size_t    kNone = static_cast<std::size_t>(-1);
    std::vector<std::size_t> parent(count, kNone);
    for (std::size_t at = 0; at < count; ++at) {
        const int32_t wanted = layers[at].parent_id;
        if (wanted == 0 || wanted == layers[at].id || ambiguous.contains(wanted)) continue;
        const auto found = slot_of.find(wanted);
        if (found != slot_of.end()) parent[at] = found->second;
    }
    // Cycles, found without recursion: walk each unvisited chain, and when it runs
    // into a link of its own walk, every member of that loop becomes a root.
    std::vector<uint8_t> state(count, 0); // 0 new, 1 on the current walk, 2 settled
    for (std::size_t start = 0; start < count; ++start) {
        if (state[start] != 0) continue;
        std::vector<std::size_t> walk;
        std::size_t              at = start;
        while (at != kNone && state[at] == 0) {
            state[at] = 1;
            walk.push_back(at);
            at = parent[at];
        }
        if (at != kNone && state[at] == 1) {
            const auto loop = std::find(walk.begin(), walk.end(), at);
            for (auto member = loop; member != walk.end(); ++member) parent[*member] = kNone;
        }
        for (const auto member : walk) state[member] = 2;
    }
    for (std::size_t at = 0; at < count; ++at) {
        auto& holder = parent[at] == kNone ? context.scene->sceneGraph : layers[parent[at]].node;
        holder->AppendChild(layers[at].node);
    }
}

// ---------------------------------------------------------------------------
// Typed objects: sounds are the only kind this stage builds.
// ---------------------------------------------------------------------------

bool LoadSoundEntry(ParseContext& context, const nlohmann::json& entry, audio::SoundManager& sm) {
    wpscene::WPSoundObject sound;
    if (! sound.FromJson(entry, *context.vfs)) {
        LOG_ERROR("sound object has no list of sounds");
        return false;
    }
    WPSoundParser::Parse(sound, *context.vfs, sm, context.scene->runtime.get());
    return true;
}

// ---------------------------------------------------------------------------
// Scene settings and cameras (R12 to R30, R79 to R88, R111, R113).
// ---------------------------------------------------------------------------

void SetGlobalUniform(ParseContext& context, const char* name, std::initializer_list<float> lanes) {
    const std::vector<float> values(lanes);
    context.global_base_uniforms[name] = ShaderValue(values.data(), values.size());
}

/// floor(extent / divisor), at least 1.
int32_t FractionOf(int32_t extent, int32_t divisor) { return std::max(1, extent / divisor); }

/// A camera at `translate` under the scene's root, with its own node.
std::shared_ptr<SceneNode> AddCameraNode(ParseContext& context, SceneCamera& camera,
                                         const Vector3f& translate) {
    auto node = std::make_shared<SceneNode>(translate, Vector3f(1.0f, 1.0f, 1.0f),
                                            Vector3f(0.0f, 0.0f, 0.0f));
    context.scene->sceneGraph->AppendChild(node);
    camera.AttatchNode(node);
    return node;
}

/// The cameras of the scene and the targets every scene has (R111, R113).
void BuildCamerasAndTargets(ParseContext& context, const wpscene::WPScene& wp, double zoom) {
    auto&       scene   = *context.scene;
    const auto& general = wp.general;
    const i32   width   = context.ortho_w;
    const i32   height  = context.ortho_h;
    const Vector3f centre(static_cast<float>(width) * 0.5f, static_cast<float>(height) * 0.5f, 0.0f);

    // Targets first: every parse registers them before any object is built.
    const i32  frame_w = std::max(1, width);
    const i32  frame_h = std::max(1, height);
    const auto format  = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
    auto&      targets = scene.renderTargets;
    targets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width           = frame_w,
        .height          = frame_h,
        .authored_width  = frame_w,
        .authored_height = frame_h,
        .bind            = { .enable = true, .screen = true },
        .format          = format,
    };
    uint32_t mip_levels = 1;
    for (i32 side = std::max(frame_w, frame_h); side > 1; side /= 2) ++mip_levels;
    targets[std::string(WE_MIP_MAPPED_FRAME_BUFFER)] = SceneRenderTarget {
        .width        = frame_w,
        .height       = frame_h,
        .has_mipmap   = true,
        .mipmap_level = mip_levels,
        .bind         = { .enable = true, .name = std::string(SpecTex_Default) },
        .format       = format,
    };
    targets["_rt_shadowAtlas"] =
        SceneRenderTarget { .width = frame_w, .height = frame_h, .allowReuse = true };
    scene.renderTargetAliases["_alias_lightCookie"] = "_rt_shadowAtlas";
    for (const auto& [name, divisor] :
         { std::pair<const char*, i32> { "_rt_4FrameBuffer", 4 }, { "_rt_8FrameBuffer", 8 },
           { "_rt_Bloom", 8 } }) {
        targets[name] = SceneRenderTarget { .width      = FractionOf(frame_w, divisor),
                                            .height     = FractionOf(frame_h, divisor),
                                            .allowReuse = true,
                                            .format     = format };
    }

    // The screen space of effect passes: 2 by 2 units, depth -1 to 1.
    auto effect = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    context.effect_camera_node = AddCameraNode(context, *effect, Vector3f::Zero());
    effect->Update();
    scene.cameras["effect"] = effect;

    // The framed canvas view: the canvas over the starting zoom.
    auto global = std::make_shared<SceneCamera>(ZoomedExtent(width, zoom),
                                                ZoomedExtent(height, zoom), -5000.0f, 5000.0f);
    context.global_camera_node = AddCameraNode(context, *global, centre);
    global->Update();
    scene.cameras["global"] = global;

    // The camera of fullscreen layers: the authored canvas, never the zoomed view.
    auto fullscreen = std::make_shared<SceneCamera>(std::max(1, width), std::max(1, height),
                                                    -5000.0f, 5000.0f);
    AddCameraNode(context, *fullscreen, centre);
    fullscreen->Update();
    scene.cameras[std::string(FullscreenLayerCamera)] = fullscreen;

    std::shared_ptr<SceneCamera> perspective;
    if (context.is_ortho) {
        // The lens perspective layers of a canvas scene look through.
        perspective = std::make_shared<SceneCamera>(static_cast<float>(global->Aspect()), 5.0f,
                                                    15000.0f, ResolveCanvasPerspectiveFov(general));
        context.global_perspective_camera_node = AddCameraNode(context, *perspective, centre);
        FitCanvasPerspective(*perspective, *global);
        perspective->Update();
        scene.activeCamera = global.get();
    } else {
        // The scene's own camera, placed by the `camera` block.
        const float far_plane = general.farz + std::max(1.0f, std::abs(general.farz) * 0.001f);
        perspective           = std::make_shared<SceneCamera>(
            static_cast<float>(width) / static_cast<float>(std::max(1, height)), general.nearz,
            far_plane, ResolvePerspectiveFov(general));
        perspective->LockFov(true);
        context.global_perspective_camera_node =
            AddCameraNode(context, *perspective, Vector3f::Zero());
        PlacePerspectiveCameraNode(*context.global_perspective_camera_node, wp.camera);
        perspective->Update();
        scene.activeCamera = perspective.get();
    }
    scene.cameras["global_perspective"] = perspective;
}

/// Every setting of the `general` block that reaches the scene or its runtime
/// (R12 to R19, R59, R64): colours, light budget, fog, camera shake and parallax.
void ApplySceneSettings(ParseContext& context, const wpscene::WPScene& wp) {
    auto&       scene   = *context.scene;
    auto* const runtime_ptr = scene.runtime.get();
    const auto& general = wp.general;

    scene.clearEnabled = general.clearenabled;
    scene.clearColor   = general.clearcolor;
    if (runtime_ptr != nullptr && general.dynamic_clearcolor) {
        runtime_ptr->RegisterSceneClearColor(
            ResolveVec3Setting(*runtime_ptr, general.clearcolor_setting));
    }
    scene.light_config = ParseSceneLightConfig(general.lightconfig);
    scene.fog_distance = general.fogdistance;
    scene.fog_height   = general.fogheight;
    scene.opaque_first = general.transparentsorting && ! context.is_ortho;

    SetGlobalUniform(context, "g_LightAmbientColor",
                     { general.ambientcolor[0], general.ambientcolor[1], general.ambientcolor[2] });
    SetGlobalUniform(context, "g_LightSkylightColor",
                     { general.skylightcolor[0], general.skylightcolor[1], general.skylightcolor[2] });
    SetGlobalUniform(context, "g_FogDistanceColor",
                     { general.fogdistancecolor[0], general.fogdistancecolor[1],
                       general.fogdistancecolor[2] });
    SetGlobalUniform(context, "g_FogDistanceParams",
                     { general.fogdistancestart, general.fogdistanceend - general.fogdistancestart,
                       general.fogdistancestartdensity,
                       general.fogdistanceenddensity - general.fogdistancestartdensity });
    SetGlobalUniform(context, "g_FogHeightColor",
                     { general.fogheightcolor[0], general.fogheightcolor[1],
                       general.fogheightcolor[2] });
    SetGlobalUniform(context, "g_FogHeightParams",
                     { general.fogheightstart, general.fogheightend - general.fogheightstart,
                       general.fogheightstartdensity,
                       general.fogheightenddensity - general.fogheightstartdensity });

    // The shake of the camera: static, or following its properties.
    if (runtime_ptr != nullptr &&
        (general.camerashake || HasDynamicSetting(general.camerashake_setting))) {
        auto& runtime = *runtime_ptr;
        runtime.RegisterCameraShake(
            ResolveBoolSetting(runtime,
                               SettingOrValue(general.camerashake_setting, general.camerashake)),
            ResolveFloatSetting(runtime, SettingOrValue(general.camerashakeamplitude_setting,
                                                        general.camerashakeamplitude)),
            ResolveFloatSetting(runtime, SettingOrValue(general.camerashakespeed_setting,
                                                        general.camerashakespeed)),
            ResolveFloatSetting(runtime, SettingOrValue(general.camerashakeroughness_setting,
                                                        general.camerashakeroughness)));
    }

    // Parallax: the switch, amount and mouse influence are read once; the delay follows.
    WPCameraParallax parallax;
    parallax.enable         = general.cameraparallax;
    parallax.amount         = general.cameraparallaxamount;
    parallax.delay          = general.cameraparallaxdelay;
    parallax.mouseinfluence = general.cameraparallaxmouseinfluence;
    parallax.canvas_scene   = context.is_ortho;
    if (runtime_ptr != nullptr) {
        auto& runtime = *runtime_ptr;
        ResolveLoadOnlySceneSetting(runtime, general.cameraparallax_setting, parallax.enable);
        ResolveLoadOnlySceneSetting(runtime, general.cameraparallaxamount_setting, parallax.amount);
        ResolveLoadOnlySceneSetting(runtime, general.cameraparallaxmouseinfluence_setting,
                                    parallax.mouseinfluence);
        if (HasDynamicSetting(general.cameraparallaxdelay_setting)) {
            auto value     = ResolveFloatSetting(runtime, general.cameraparallaxdelay_setting);
            parallax.delay = value->getFloat();
            auto* updater  = context.shader_updater;
            runtime.RegisterDynamicValueListener(std::move(value), [updater](const DynamicValue& now) {
                auto current  = updater->CameraParallax();
                current.delay = now.getFloat();
                updater->SetCameraParallax(current);
            });
        }
    }
    context.shader_updater->SetCameraParallax(parallax);
}

/// The scene's zoom: where it starts, and what keeps it going. A playable timeline
/// on the zoom plays even when a property is named too, and the property then
/// only supplies the start; otherwise a bound zoom follows its property.
struct SceneZoomPlan {
    double                         start { 1.0 };
    std::unique_ptr<DynamicValue>  bound;
    std::optional<ScalarAnimation> animation;
};

SceneZoomPlan PlanSceneZoom(ParseContext& context, const wpscene::WPSceneGeneral& general) {
    SceneZoomPlan plan;
    plan.start = general.zoom;
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr) return plan;
    plan.animation = ResolveScalarAnimation(general.zoom_setting);
    if (HasDynamicSetting(general.zoom_setting)) {
        plan.bound = ResolveFloatSetting(*runtime, general.zoom_setting);
        plan.start = plan.bound->getFloat();
    }
    return plan;
}

/// Hands the zoom to the runtime; the cameras it frames exist by now.
void InstallSceneZoom(ParseContext& context, SceneZoomPlan plan) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr) return;
    if (plan.animation.has_value()) {
        runtime->RegisterSceneZoomAnimation(
            runtime->RegisterScalarAnimation("", std::move(*plan.animation)));
    } else if (plan.bound != nullptr) {
        runtime->RegisterSceneZoom(std::move(plan.bound));
    }
}

/// The canvas of the scene (R21, R88): the authored size, the largest image layer
/// for an `auto` projection, and the fallback of 1920 by 1080 for the rest.
std::array<int32_t, 2> ResolveCanvas(ParseContext& context, const wpscene::WPSceneGeneral& general,
                                     const nlohmann::json&         objects,
                                     const std::vector<EntryPlan>& plans) {
    if (! general.isOrtho || ! general.orthogonalprojection.auto_) {
        return { general.orthogonalprojection.width, general.orthogonalprojection.height };
    }
    std::array<int32_t, 2> largest { 0, 0 };
    int64_t                best = -1;
    for (std::size_t at = 0; at < objects.size(); ++at) {
        if (plans[at].kind != EntryKind::Image || plans[at].admission != Admission::Object) continue;
        wpscene::WPImageObject image;
        if (! image.FromJson(objects[at], *context.vfs)) continue;
        const auto side = [](float value) {
            return std::isfinite(value) ? static_cast<int32_t>(std::clamp(value, 0.0f, 2.0e9f)) : 0;
        };
        const std::array<int32_t, 2> size { side(image.size[0]), side(image.size[1]) };
        const int64_t                area = static_cast<int64_t>(size[0]) * size[1];
        if (area > best) {
            best    = area;
            largest = size;
        }
    }
    return largest;
}

/// The thread-local state of one parse: nothing from an earlier parse is left in
/// it, and nothing of this one remains once it ends, however it ends.
struct ParseSession {
    ParseSession() {
        g_pending_metal_translations.clear();
        g_shader_failures.clear();
        g_parse_layer_index = nullptr;
        WPShaderParser::BeginShaderSession();
    }
    ~ParseSession() {
        g_pending_metal_translations.clear();
        g_shader_failures.clear();
        g_parse_layer_index = nullptr;
        WPShaderParser::EndShaderSession();
    }
};

std::shared_ptr<Scene> ParseSceneDocument(const SceneParseRequest& request, const std::string& buf,
                                          fs::VFS& vfs, audio::SoundManager& sm) {
    nlohmann::json json;
    if (! PARSE_JSON(buf, json) || ! json.is_object()) {
        LOG_ERROR("the scene file is not a JSON document with an object at its top");
        return nullptr;
    }
    const auto objects_found = json.find("objects");
    if (objects_found == json.end() || ! objects_found->is_array()) {
        LOG_ERROR("the scene file has no list of objects");
        return nullptr;
    }
    auto& objects = *objects_found;
    ParseSession session;

    wpscene::WPScene wp;
    wp.FromJson(json, request.pkg_version);
    const auto& general = wp.general;
    // Parented layers ride the outermost parent's parallax depth.
    ResolveLayerParallax(objects);

    auto scene           = std::make_shared<Scene>();
    scene->scene_id      = request.scene_id;
    scene->project_path  = request.project_path;
    scene->sceneGraph    = std::make_shared<SceneNode>();
    scene->imageParser   = std::make_unique<RuntimeImageSource>(std::make_unique<WPTexImageParser>(&vfs));
    scene->shaderValueUpdater = std::make_unique<WPShaderValueUpdater>(scene.get());
    scene->paritileSys   = std::make_unique<ParticleSystem>(*scene);
    scene->resolution    = CurrentSceneResolution();
    scene->display_sized = ! general.isOrtho;

    ParseContext context {};
    context.scene          = scene;
    context.vfs            = &vfs;
    context.shader_updater = static_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    context.is_ortho       = general.isOrtho;
    context.pixel_canvas   = general.pixelCanvas;

    const LayerObjectIndex index = BuildLayerObjectIndex(objects);
    g_parse_layer_index          = &index;
    const auto plans             = PlanEntries(context, objects, index);

    const auto canvas = ResolveCanvas(context, general, objects, plans);
    context.ortho_w   = canvas[0];
    context.ortho_h   = canvas[1];
    scene->ortho[0]   = canvas[0];
    scene->ortho[1]   = canvas[1];
    // The extent layout and the cursor map against: the unzoomed canvas, latched.
    scene->scene_extent[0] = std::max(1, canvas[0]);
    scene->scene_extent[1] = std::max(1, canvas[1]);

    SceneRuntimeBootstrap bootstrap;
    bootstrap.canvas_width  = canvas[0];
    bootstrap.canvas_height = canvas[1];
    if (request.project_properties != nullptr) bootstrap.project_properties = *request.project_properties;
    if (request.authored_project_properties != nullptr) {
        bootstrap.authored_project_properties = *request.authored_project_properties;
    }
    // Without a property table there is nothing to bind to, and no runtime.
    if (request.project_properties != nullptr) {
        scene->runtime = std::make_unique<SceneRuntimeContext>(std::move(bootstrap));
        scene->runtime->AttachScene(scene.get());
    }

    // What decides how the scene is built is read once, as it loads.
    bool bloom = general.bloom;
    if (scene->runtime != nullptr) {
        ResolveLoadOnlySceneSetting(*scene->runtime, general.bloom_setting, bloom);
    }
    scene->hdr = general.hdr && bloom;

    ApplySceneSettings(context, wp);
    auto zoom = PlanSceneZoom(context, general);
    BuildCamerasAndTargets(context, wp, zoom.start);
    InstallSceneZoom(context, std::move(zoom));

    BuildLayers(context, general, objects, plans, sm);
    AttachLayers(context);

    ApplyDefaultDepthTarget(context);
    PrewarmParticleSystems(context);

    // Layers that read other layers' pictures, and whether that is legal.
    const auto refs = CollectLayerTextureRefs(objects, index, &vfs);
    for (const auto& ref : refs) scene->layer_texture_sources.insert(ref.source_id);
    scene->layer_texture_error = ClassifyLayerTextureReferences(refs, index);

    FlushPendingMetalTranslations(*scene);
    scene->shader_compile_error = ShaderFailureReason();

    // Scene scripts start last, once every layer, id and hook they may use exists,
    // in the order the file declares their layers.
    auto scripts = std::move(context.scene_scripts);
    if (scene->runtime != nullptr) {
        for (auto& [source, key] : scripts) {
            scene->runtime->RegisterSceneScript(std::move(source), std::move(key));
        }
    }
    return scene;
}

} // namespace

std::shared_ptr<Scene> WPSceneParser::Parse(const SceneParseRequest& request,
                                            const std::string& buf, fs::VFS& vfs,
                                            audio::SoundManager& sm) {
    return ParseSceneDocument(request, buf, vfs, sm);
}

std::shared_ptr<Scene> WPSceneParser::Parse(std::string_view scene_id, const std::string& buf,
                                            fs::VFS& vfs, audio::SoundManager& sm) {
    SceneParseRequest request;
    request.scene_id = std::string(scene_id);
    return ParseSceneDocument(request, buf, vfs, sm);
}
