// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#include <algorithm>
#include <stdexcept>
#include "SceneImageEffectLayer.h"
#include "SceneNode.h"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"

using namespace wallpaper;

namespace
{
bool IsPlaceholder(std::string_view name) {
    return sstart_with(name, WE_EFFECT_PPONG_PREFIX_A) || sstart_with(name, WE_EFFECT_PPONG_PREFIX_B) ||
           name == SpecTex_Default;
}

// Puts the authored name back wherever the chain had put a buffer name in its place.
void Restore(std::string& current, const std::string& authored) {
    if (IsPlaceholder(authored)) current = authored;
}

SceneMaterial* MaterialOf(SceneNode* node) {
    if (node == nullptr || node->Mesh() == nullptr) return nullptr;
    return node->Mesh()->Material();
}
} // namespace

SceneImageEffectLayer::SceneImageEffectLayer(SceneNode* node, float w, float h,
                                             std::string_view pingpong_a,
                                             std::string_view pingpong_b)
    : m_pingpong_a(pingpong_a),
      m_pingpong_b(pingpong_b),
      m_final_mesh(std::make_unique<SceneMesh>(MeshUpdate::Fixed)),
      m_final_node(std::make_unique<SceneNode>()) {
    // The owner and the extent are not used by anything the layer does.
    (void)node;
    (void)w;
    (void)h;
}

SceneImageEffectLayer::~SceneImageEffectLayer() = default;

void SceneImageEffectLayer::AddEffect(const std::shared_ptr<SceneImageEffect>& node) {
    m_effects.push_back(node);
}

std::size_t SceneImageEffectLayer::EffectCount() const { return m_effects.size(); }

std::shared_ptr<SceneImageEffect>& SceneImageEffectLayer::GetEffect(std::size_t index) {
    return m_effects.at(index);
}

const std::string& SceneImageEffectLayer::FirstTarget() const { return m_pingpong_a; }

SceneMesh& SceneImageEffectLayer::FinalMesh() const { return *m_final_mesh; }

SceneNode& SceneImageEffectLayer::FinalNode() const { return *m_final_node; }

SceneNode* SceneImageEffectLayer::ResolvedFinalRenderNode() const { return m_resolved_final; }

void SceneImageEffectLayer::SetFinalBlend(BlendMode m) { m_final_blend = m; }

void SceneImageEffectLayer::SetFinalMeshDynamic(MeshUpdate update) {
    auto fresh = std::make_unique<SceneMesh>(update);
    fresh->ChangeMeshDataFrom(*m_final_mesh);
    if (const SceneMaterial* material = m_final_mesh->Material(); material != nullptr) {
        fresh->AddMaterial(SceneMaterial(*material));
    }
    m_final_mesh = std::move(fresh);
}

void SceneImageEffectLayer::ResolveEffect(const SceneMesh& default_mesh,
                                          std::string_view effect_cam) {
    // 1. Record the authored names once, then put back every placeholder the last
    //    resolution replaced, so the same chain can be laid out again.
    for (const auto& effect : m_effects) {
        if (effect == nullptr) continue;
        std::size_t& recorded = m_recorded_commands[effect.get()];
        for (std::size_t i = 0; i < effect->commands.size(); ++i) {
            auto& command = effect->commands[i];
            if (i >= recorded) {
                command.authored_src = command.src;
                command.authored_dst = command.dst;
            } else {
                Restore(command.src, command.authored_src);
                Restore(command.dst, command.authored_dst);
            }
        }
        recorded = effect->commands.size();

        for (auto& pass : effect->nodes) {
            SceneMaterial* material = MaterialOf(pass.sceneNode.get());
            if (m_recorded_nodes.insert(&pass).second) {
                pass.authored_output = pass.output;
                pass.authored_textures.clear();
                if (material != nullptr) pass.authored_textures = material->textures;
                continue;
            }
            Restore(pass.output, pass.authored_output);
            if (material != nullptr) {
                const std::size_t n = std::min(material->textures.size(), pass.authored_textures.size());
                for (std::size_t i = 0; i < n; ++i) {
                    Restore(material->textures[i], pass.authored_textures[i]);
                }
            }
        }
    }

    // 2. Which effects take part.
    bool any_running = false;
    for (const auto& effect : m_effects) {
        if (effect != nullptr && ! effect->fallback && effect->visible) any_running = true;
    }
    for (const auto& effect : m_effects) {
        if (effect == nullptr) continue;
        effect->included = effect->fallback ? ! any_running : effect->visible;
    }

    // 3. Lay the included effects out over the two buffers; the buffers swap once
    //    per included effect.
    m_resolved_final = nullptr;
    SceneImageEffectNode* last_writer = nullptr;
    static const SceneNode identity;
    std::size_t            ordinal = 0;
    for (const auto& effect : m_effects) {
        if (effect == nullptr || ! effect->included) continue;
        const bool         even   = ordinal % 2 == 0;
        const std::string& input  = even ? m_pingpong_a : m_pingpong_b;
        const std::string& output = even ? m_pingpong_b : m_pingpong_a;
        ++ordinal;

        for (auto& command : effect->commands) {
            if (sstart_with(command.src, WE_EFFECT_PPONG_PREFIX_A)) command.src = input;
            if (sstart_with(command.dst, WE_EFFECT_PPONG_PREFIX_A)) command.dst = input;
        }
        for (auto& pass : effect->nodes) {
            SceneMaterial* material = MaterialOf(pass.sceneNode.get());
            if (material == nullptr) {
                if (! m_logged_missing_material) {
                    m_logged_missing_material = true;
                    LOG_ERROR("An effect pass has no material; the pass is skipped");
                }
                continue;
            }
            if (sstart_with(pass.output, WE_EFFECT_PPONG_PREFIX_B) || pass.output == SpecTex_Default) {
                pass.output = output;
            }
            for (auto& texture : material->textures) {
                if (sstart_with(texture, WE_EFFECT_PPONG_PREFIX_A)) texture = input;
            }
            if (pass.output == output) last_writer = &pass;

            SceneNode& node = *pass.sceneNode;
            material->blenmode = BlendMode::Normal;
            node.SetCamera(std::string(effect_cam));
            node.CopyTrans(identity);
            node.Mesh()->ChangeMeshDataFrom(default_mesh);
        }
    }

    // 4. The last pass that wrote the output buffer closes the chain onto the layer.
    if (last_writer == nullptr) return;
    SceneNode& node = *last_writer->sceneNode;
    last_writer->output = std::string(SpecTex_Default);
    if (node.Mesh()->UpdateDriver() != m_final_mesh->UpdateDriver()) {
        auto replacement = std::make_shared<SceneMesh>(m_final_mesh->UpdateDriver());
        replacement->AddMaterial(SceneMaterial(*node.Mesh()->Material()));
        node.AddMesh(std::move(replacement));
    }
    node.Mesh()->ChangeMeshDataFrom(*m_final_mesh);
    SceneMaterial& material = *node.Mesh()->Material();
    material.blenmode = (! any_running && m_idle_final_blend) ? *m_idle_final_blend : m_final_blend;
    if (m_final_depth) {
        material.depth_test  = m_final_depth->test;
        material.depth_write = m_final_depth->write;
    }
    node.SetCamera(m_final_camera);
    node.CopyTrans(*m_final_node);
    m_resolved_final = &node;
}
