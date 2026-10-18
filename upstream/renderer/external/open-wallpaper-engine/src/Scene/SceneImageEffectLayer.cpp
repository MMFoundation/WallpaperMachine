#include <algorithm>
#include "SceneImageEffectLayer.h"
#include "SceneNode.h"

using namespace wallpaper;

SceneImageEffectLayer::SceneImageEffectLayer(SceneNode* node, float w, float h,
                                             std::string_view pingpong_a,
                                             std::string_view pingpong_b) {
    // CLEANROOM SM12
    (void)node;
    (void)w;
    (void)h;
    (void)pingpong_a;
    (void)pingpong_b;
}

void SceneImageEffectLayer::AddEffect(const std::shared_ptr<SceneImageEffect>& node) {
    // CLEANROOM SM12
    (void)node;
}

std::size_t SceneImageEffectLayer::EffectCount() const {
    // CLEANROOM SM12
    return 0;
}

std::shared_ptr<SceneImageEffect>& SceneImageEffectLayer::GetEffect(std::size_t index) {
    // CLEANROOM SM12
    (void)index;
    static std::shared_ptr<SceneImageEffect> none;
    none.reset();
    return none;
}

const std::string& SceneImageEffectLayer::FirstTarget() const {
    // CLEANROOM SM12
    static const std::string none;
    return none;
}

SceneMesh& SceneImageEffectLayer::FinalMesh() const {
    // CLEANROOM SM12
    static SceneMesh none;
    return none;
}

SceneNode& SceneImageEffectLayer::FinalNode() const {
    // CLEANROOM SM12
    static SceneNode none;
    return none;
}

SceneNode* SceneImageEffectLayer::ResolvedFinalRenderNode() const {
    // CLEANROOM SM12
    return nullptr;
}

void SceneImageEffectLayer::SetFinalBlend(BlendMode m) {
    // CLEANROOM SM12
    (void)m;
}

void SceneImageEffectLayer::SetFinalMeshDynamic(MeshUpdate update) {
    // CLEANROOM SM14
    (void)update;
}

void SceneImageEffectLayer::ResolveEffect(const SceneMesh& default_mesh,
                                          std::string_view effect_cam) {
    // CLEANROOM SM13
    (void)default_mesh;
    (void)effect_cam;
}
